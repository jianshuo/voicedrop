import Foundation

/// 后台上传通道：录音与标签边车的 PUT 走系统级 background URLSession。
///
/// 为什么必须是 background session（2026-08-04 根因）：录完音立刻锁屏/装兜里，
/// 前台 URLSession 只有 beginBackgroundTask 的 ~30s 缓冲，第一枪没打完就随进程
/// 挂起一起冻结——文件躺在本地队列里没人再试，直到用户下次打开 App 才补传。
/// 实测 8/1–8/3 每条录音的「录完→服务端落地」延迟恰好等于「下次打开 App 的间隔」
/// （22 分钟～2 小时），与文件大小无关。background session 把传输交给系统守护
/// 进程：锁屏、切后台、进程被杀，上传照样完成；完成事件在进程复活后经
/// AppDelegate 的 handleEventsForBackgroundURLSession 回放到本 delegate。
///
/// 收尾（删本地文件 / 埋点 / UI 状态）全部集中在 delegate 的 finish 路径且幂等——
/// 无论完成时进程一直活着（upload() 的 await 正常返回）还是隔世重启（await 早已
/// 不在，只有 delegate 回放），本地状态都收敛到同一结果。
///
/// 重试语义：background session 自己等网络、自己重传（resource 窗口内），所以
/// 进程内不再有「3 次尝试 + 退避 sleep」；服务器真拒绝（4xx/5xx）→ 文件留盘，
/// 交给下一次 drain 触发点（前台刷新 / 联网恢复 / 下次录音）重新入队。
final class BackgroundTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// 随任务持久化的元数据（taskDescription JSON）——进程隔世重启后收尾全靠它。
    struct Job: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case audio, tags }
        let kind: Kind
        let localPath: String    // Documents 相对路径（容器绝对路径每次安装会变，绝不能存绝对路径）
        let remoteName: String   // PUT /files/api/upload/<remoteName>
        let sizeKB: Int
        let queuedAt: Double     // drain 进门时刻 epoch（口径 2 的排队锚）
        let transferAt: Double   // 任务入队时刻 epoch（耗时锚）
        let networkType: String  // 入队时的网络类型（完成时可能已变，取入队值）

        /// 本地文件 → Documents 相对路径。按路径组件找 "Documents" 锚点切尾巴，
        /// 不做前缀字符串比较（/var 与 /private/var 符号链接会失配）。
        nonisolated static func localPath(for file: URL) -> String? {
            let comps = file.standardizedFileURL.pathComponents
            guard let i = comps.lastIndex(of: "Documents"), i + 1 < comps.count else { return nil }
            return comps[(i + 1)...].joined(separator: "/")
        }

        @MainActor var localURL: URL { AudioRecorder.documentsDir.appending(path: localPath) }

        func encoded() -> String? {
            guard let d = try? JSONEncoder().encode(self) else { return nil }
            return String(data: d, encoding: .utf8)
        }

        nonisolated static func decode(_ s: String?) -> Job? {
            guard let s, let d = s.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Job.self, from: d)
        }
    }

    static let shared = BackgroundTransfer()
    static let sessionIdentifier = "com.wangjianshuo.VoiceDrop.upload"

    /// 系统在后台把我们拉起来回放完成事件时给的收尾回调：事件放完必须调用，
    /// 系统才给这次唤醒记账收尾。由 PushRegistrar 存进来。
    @MainActor static var relaunchCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false          // 用户显式动作的产物，别等系统挑「好时机」
        cfg.sessionSendsLaunchEvents = true  // 进程死了也要为完成事件复活我们
        cfg.timeoutIntervalForRequest = 120
        // 整体窗口：系统在此期限内自己等网、自己重试。到期仍失败→文件还在盘上，
        // 下一次 drain 触发点重新入队，永不丢。
        cfg.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // taskIdentifier ↔ 本地路径的去重登记 + 进程存活期等结果的续体。锁保护
    //（delegate 在 session 队列回，upload() 在 MainActor 调）。
    private let lock = NSLock()
    private var taskByPath: [String: Int] = [:]
    private var waiters: [Int: [CheckedContinuation<Bool, Never>]] = [:]

    /// App 启动即调：建 session（delegate 就位，上一条命没送完的任务的完成事件
    /// 才有人收），并把仍在飞的任务登记进去重表。getAllTasks 异步返回，极早期的
    /// enqueue 理论上可能与它错过而重复入队——PUT 幂等，代价只是一次冗余传输。
    func activate() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            for t in tasks where t.state == .running || t.state == .suspended {
                if let job = Job.decode(t.taskDescription) {
                    self.taskByPath[job.localPath] = t.taskIdentifier
                }
            }
            self.lock.unlock()
        }
    }

    /// 是否有该本地文件的任务仍在飞（音频成功后决定要不要删边车用）。
    func isInFlight(localPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return taskByPath[localPath] != nil
    }

    /// 入队一个 PUT；进程存活期间 await 它真正完成（挂起后系统续传，收尾由
    /// delegate 幂等执行，await 在进程复活后跟着返回）。同一文件已在飞则挂到
    /// 现有任务上等，不重复入队。文件已不在盘上 = 早已收尾 → 立即成功。
    func upload(file: URL, remoteName: String, contentType: String, bearer: String,
                kind: Job.Kind, networkType: String = "未知",
                enqueuedAt: Date = Date()) async -> Bool {
        guard let localPath = Job.localPath(for: file) else { return false }
        guard FileManager.default.fileExists(atPath: file.path) else { return true }

        // NSLock 裸 lock()/unlock() 在 async 上下文不可用（Swift 6）——一律走
        // withLock 的同步闭包（闭包内不 await，锁绝不跨挂起点）。
        if let existing = lock.withLock({ taskByPath[localPath] }) {
            return await join(existing, file: file)
        }

        var req = URLRequest(url: API.filesBase.appending(path: "upload").appending(path: remoteName))
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
        let job = Job(kind: kind, localPath: localPath, remoteName: remoteName,
                      sizeKB: Int(bytes / 1024),
                      queuedAt: enqueuedAt.timeIntervalSince1970,
                      transferAt: Date().timeIntervalSince1970,
                      networkType: networkType)

        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = job.encoded()

        let lostTo: Int? = lock.withLock {
            if let existing = taskByPath[localPath] { return existing }
            taskByPath[localPath] = task.taskIdentifier
            return nil
        }
        if let lostTo {
            // 并发入队输了：清掉元数据再取消（delegate 见 job=nil 直接忽略），挂到赢家上等。
            task.taskDescription = nil
            task.cancel()
            return await join(lostTo, file: file)
        }

        return await withCheckedContinuation { c in
            lock.withLock { waiters[task.taskIdentifier, default: []].append(c) }
            task.resume()
        }
    }

    /// 挂到一个已在飞的任务上等它的结果。
    private func join(_ id: Int, file: URL) async -> Bool {
        await withCheckedContinuation { c in
            let joined = lock.withLock { () -> Bool in
                guard taskByPath.values.contains(id) else { return false }
                waiters[id, default: []].append(c)
                return true
            }
            // 等到锁前任务已收尾——文件被删 = 成功。
            if !joined { c.resume(returning: !FileManager.default.fileExists(atPath: file.path)) }
        }
    }

    // MARK: - URLSessionTaskDelegate（session 队列，nonisolated）

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let job = Job.decode(task.taskDescription)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && (200..<300).contains(status)
        let errorText = error?.localizedDescription

        lock.lock()
        let conts = waiters.removeValue(forKey: task.taskIdentifier) ?? []
        if let job, taskByPath[job.localPath] == task.taskIdentifier {
            taskByPath.removeValue(forKey: job.localPath)
        }
        lock.unlock()

        // 收尾先于续体：upload() 的 await 返回时，删盘/埋点/UI 状态已经落定。
        Task { @MainActor in
            if let job { Self.finish(job: job, ok: ok, status: status, errorText: errorText) }
            for c in conts { c.resume(returning: ok) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.relaunchCompletion?()
            Self.relaunchCompletion = nil
        }
    }

    /// 幂等收尾——进程死活两条路都汇到这里。
    @MainActor
    private static func finish(job: Job, ok: Bool, status: Int, errorText: String?) {
        switch job.kind {
        case .audio:
            Uploader.shared.finishAudioTransfer(job: job, ok: ok, status: status, errorText: errorText)
        case .tags:
            // 成功删本地边车；失败留盘，随音频的下一次 drain 一起重新入队。
            if ok { try? FileManager.default.removeItem(at: job.localURL) }
        }
    }
}

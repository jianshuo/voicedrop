import Foundation
import Observation
import Network

/// Uploads recordings to jianshuo.dev/files via the R2-backed PUT API.
/// The Documents directory IS the pending queue: a `VoiceDrop-*.m4a` file that
/// still exists has not been uploaded. On success the file is deleted.
///
/// Resilience — why a finalized take never gets stuck on 正在上传 anymore:
/// - the PUT itself runs on **BackgroundTransfer 的 background URLSession**：
///   录完立刻锁屏/装兜里，传输由系统守护进程接管完成，进程被杀也照样送达
///   （2026-08-04 根因：前台 URLSession 的第一枪随挂起冻结后，文件要等用户
///   下次打开 App 才补传——延迟 22 分钟～2 小时，与文件大小无关）；
/// - background session 在 resource 窗口内自己等网自己重试；服务器真拒绝的
///   失败把文件留在盘上，下一次 drain 触发点重新入队 — it is never lost;
/// - `drainPending` no longer aborts the queue on the first failure, so one
///   stubborn take can't wedge everything queued behind it;
/// - an `NWPathMonitor` re-drains the queue the moment connectivity returns.
///
/// 单例：完成事件可能在 App 隔世重启后由 BackgroundTransfer 回放，收尾
/// （删本地/埋点/UI 状态）必须路由到唯一实例。
@MainActor
@Observable
final class Uploader {

    static let shared = Uploader()

    private(set) var pendingCount: Int = 0
    private(set) var pending: [URL] = []      // local takes still queued (observable)
    private(set) var justUploaded: [String] = []  // uploaded, awaiting server confirmation
    private(set) var lastError: String?

    /// Per-user bearer: the Sign-in-with-Apple session if present, else the
    /// anonymous iCloud-Keychain token. Uploads land in this user's own
    /// `users/<id>/` space — never the shared master namespace.
    private var token: String { AuthStore.shared.bearer }

    var hasValidToken: Bool { !token.isEmpty }

    // Serialise drains: the foreground refresh, the reachability monitor and the
    // post-record refresh can all call drainPending — without this they raced,
    // and a slow/failing head-of-queue take could let later small takes jump it
    // while never resolving itself. `drainAgain` runs one more pass if a new
    // trigger arrived mid-drain.
    private var isDraining = false
    private var drainAgain = false

    // Reachability — retry the queue when the network comes back after an outage.
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    // 埋点用的当前网络类型（WiFi/蜂窝/…），由 pathMonitor 随路径变化更新。
    private var networkType = "未知"

    private init() {
        refreshPending()
        startNetworkMonitor()
        // 上次会话没传完的照片（离线/被杀）在启动时接着传。
        Task { await PhotoUploadQueue.shared.drain() }
    }

    // MARK: - Reachability

    /// Re-drain when connectivity transitions from down → up (not on every tick).
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let type: String
            if path.usesInterfaceType(.wifi) { type = "WiFi" }
            else if path.usesInterfaceType(.cellular) { type = "蜂窝" }
            else if path.usesInterfaceType(.wiredEthernet) { type = "有线" }
            else { type = online ? "其他" : "离线" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBackOnline = online && !self.isOnline
                self.isOnline = online
                self.networkType = type
                if cameBackOnline, PhotoUploadQueue.shared.hasPending { await PhotoUploadQueue.shared.drain() }
                if cameBackOnline, self.pendingCount > 0 { await self.drainPending() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vd.uploader.netmon"))
    }

    // MARK: - Queue

    func pendingFiles() -> [URL] {
        let dir = AudioRecorder.documentsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { RecordingName.isRecordingFile($0.lastPathComponent) }
            .filter { Self.isUploadable($0) }   // skip 0-byte / moov-less junk so it can't block the queue
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A finalized AAC/MP4 take has a `moov` atom and real payload. A file read
    /// mid-recording (or a 0-byte stub) lacks it and is unplayable — never PUT it.
    static func isUploadable(_ url: URL) -> Bool {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
            size > 1024,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return false }
        // moov atom 在 AVFoundation finalize 的 m4a 里只在文件头或尾——首尾各扫
        // 512KB 即可，别为存在性检查全文件扫描（每次 pendingFiles/refresh 都要跑，
        // 长录音是可观的本地 CPU）。
        let probe = 512 * 1024
        let moov = Data("moov".utf8)
        if data.count <= probe * 2 { return data.range(of: moov) != nil }
        return data.range(of: moov, in: 0..<probe) != nil
            || data.range(of: moov, in: (data.count - probe)..<data.count) != nil
    }

    /// name (VoiceDrop-*.m4a) → its pending tags, read from the local sidecars.
    /// Keeps an in-flight take visible on its tag page through 上传→待处理 (the
    /// entry outlives the sidecar file so 待处理 optimistic rows still match).
    private(set) var pendingTagsByName: [String: [String]] = [:]

    func refreshPending() {
        pending = pendingFiles(); pendingCount = pending.count
        for url in pending {
            if let data = try? Data(contentsOf: Self.tagsSidecarURL(for: url)),
               let tags = try? JSONDecoder().decode([String].self, from: data), !tags.isEmpty {
                pendingTagsByName[url.lastPathComponent] = tags
            }
        }
    }

    /// Drop optimistic 待处理 entries the server has now confirmed in its list.
    func dropConfirmed(_ names: Set<String>) {
        justUploaded.removeAll { names.contains($0) }
        // The server list now owns these rows (tags come from the R2 sidecar / doc).
        for n in names { pendingTagsByName[n] = nil }
    }

    /// Move an uploaded take out of the pending scan but keep it on disk
    /// (Documents/uploaded/) — used when "上传后删除本地" is off.
    static func keepLocal(_ url: URL) {
        let dir = documentsDir.appending(path: "uploaded")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    private static var documentsDir: URL { AudioRecorder.documentsDir }

    // MARK: 标签侧车 —— tag 页发起的录音，挖出的文章缺省带该页标签

    /// Local sidecar next to a queued take: Documents/<stem>.tags.json = ["标签"].
    /// Queued and uploaded WITH the take (as articles/<stem>.tags, BEFORE the
    /// audio — the audio's arrival is what triggers mining), so the miner folds
    /// the tag into the article doc at 成文 time.
    static func tagsSidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("tags.json")
    }

    static func writeTagsSidecar(for audio: URL, tags: [String]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        try? data.write(to: tagsSidecarURL(for: audio))
    }

    /// Best-effort: queue the local tags sidecar (if any) onto the background
    /// session. 成功后 delegate 删本地边车；失败留盘，随音频的下一次 drain 再来。
    private func enqueueTagsSidecar(for audio: URL) {
        let local = Self.tagsSidecarURL(for: audio)
        guard FileManager.default.fileExists(atPath: local.path) else { return }
        let stem = audio.deletingPathExtension().lastPathComponent
        let tok = token, net = networkType
        // 独立 Task：失败 return 路径的隐式取消不该掐断边车 PUT。
        Task {
            _ = await BackgroundTransfer.shared.upload(
                file: local, remoteName: "articles/\(stem).tags",
                contentType: "application/json", bearer: tok, kind: .tags, networkType: net)
        }
    }

    func upload(_ url: URL, enqueuedAt: Date = Date()) async -> Bool {
        guard hasValidToken else {
            lastError = String(localized: "请先用 Apple 登录")
            return false
        }
        guard Self.isUploadable(url) else {
            lastError = String(localized: "录音文件损坏，已跳过上传")
            return false
        }
        // 照片并行赶路，不再阻塞音频（2026-08-03：串行照片队列曾把弱网录音上传拖到
        // 中位 214s）。晚到照片有服务端双保险：挖矿写盘前 fresh 重列 + 照片 PUT poke
        // Miner DO 的 backfillSessionPhotos（成文后也能补标记）。
        Task { await PhotoUploadQueue.shared.drain() }
        // tags 边车与音频并行（消费点在成文时刻——ASR 之后分钟级，几百字节永远先到）。
        enqueueTagsSidecar(for: url)
        // 音频 PUT 进后台会话：锁屏/切走/杀进程都由系统续传。await 等的是真完成
        //（收尾在 finishAudioTransfer，进程隔世重启时由 delegate 回放走同一路径）。
        let ok = await BackgroundTransfer.shared.upload(
            file: url, remoteName: url.lastPathComponent, contentType: "audio/mp4",
            bearer: token, kind: .audio, networkType: networkType, enqueuedAt: enqueuedAt)
        refreshPending()
        return ok
    }

    /// 音频传输收尾（BackgroundTransfer delegate 唯一入口，幂等）：删本地/留副本、
    /// 清边车、乐观行、埋点。进程死活两条路都走这里。
    func finishAudioTransfer(job: BackgroundTransfer.Job, ok: Bool, status: Int, errorText: String?) {
        let url = job.localURL
        let 耗时秒 = Int((Date().timeIntervalSince1970 - job.transferAt).rounded())
        if ok {
            // Drop from the queue. If the user wants a local copy kept, move it
            // into an `uploaded/` subdir (outside the VoiceDrop-* scan) instead.
            if Prefs.shared.deleteLocalAfterUpload {
                try? FileManager.default.removeItem(at: url)
            } else {
                Self.keepLocal(url)
            }
            // The audio is up — this take won't be drained again. 边车若已送达或
            // 不存在就清掉本地副本；仍在飞的留给它自己的收尾（成功即删）。
            let sidecar = Self.tagsSidecarURL(for: url)
            if let p = BackgroundTransfer.Job.localPath(for: sidecar),
               !BackgroundTransfer.shared.isInFlight(localPath: p) {
                try? FileManager.default.removeItem(at: sidecar)
            }
            // Keep showing this take — now as 待处理 — until the server list
            // lists it, so the row changes badge in place instead of vanishing
            // then re-appearing half a second later.
            if !justUploaded.contains(url.lastPathComponent) {
                justUploaded.append(url.lastPathComponent)
            }
            lastError = nil
            refreshPending()
            Analytics.capture("录音上传完成", [
                "尝试次数": 1,
                // 口径 3（2026-08-04 后台会话）：耗时秒 = 入队→系统送达，含挂起期——
                // 即用户体感的「录完到传完」。排队秒沿用口径 2（drain 内排在前面的音频）。
                "耗时秒": 耗时秒,
                "排队秒": Int((job.transferAt - job.queuedAt).rounded()),
                "文件KB": job.sizeKB,
                "网络类型": job.networkType,
                "口径": 3,
            ])
        } else if status == 401 || status == 403 {
            // Auth 4xx is the server rejecting the request — re-enqueueing won't
            // change the outcome until the token changes; the file stays on disk.
            lastError = String(localized: "token 失效（HTTP \(status)）")
            Analytics.capture("录音上传失败", ["原因": "token失效", "网络类型": job.networkType, "口径": 3])
        } else {
            // 服务器拒绝（4xx/5xx）或 resource 窗口耗尽——文件留盘，下一次 drain
            // 触发点（前台刷新/联网恢复/下次录音）重新入队。
            lastError = errorText ?? String(localized: "上传失败 HTTP \(status)")
            Analytics.capture("录音上传失败", [
                "原因": status > 0 ? "HTTP\(status)" : "网络中断",
                "耗时秒": 耗时秒,
                "文件KB": job.sizeKB,
                "网络类型": job.networkType,
                "口径": 3,
            ])
        }
    }

    /// Uploads every pending file. A failure no longer aborts the queue — we skip
    /// the stuck take and keep going, so one bad file can't wedge the rest; the
    /// skipped file stays on disk and is retried on the next drain. Serialised so
    /// concurrent triggers can't race.
    @discardableResult
    func drainPending() async -> Bool {
        if isDraining { drainAgain = true; return pendingCount == 0 }
        isDraining = true
        defer { isDraining = false }

        repeat {
            drainAgain = false
            let drainStart = Date()   // 口径 2 排队秒的锚：排在前面的音频吃掉的等待
            for file in pendingFiles() {
                _ = await upload(file, enqueuedAt: drainStart)
            }
            refreshPending()
        } while drainAgain && pendingCount > 0

        return pendingCount == 0
    }
}

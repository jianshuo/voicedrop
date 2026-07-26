import Foundation

/// 可重连 WebSocket 基座：建连（bearer + receive 循环）、25s 心跳、断线 1.5s
/// 退避重连、goingAway 关闭，全部收口在这里。之前 ArticleAgentSession /
/// LibraryCommandSession / StatusSession 各手抄一份且已漂移——25s 心跳只有文章
/// 侧有（库级连接被 NAT 掐死后要等下次说话才发现）、重连延迟 1.5s/3s 不一、
/// 双 socket 防护只有 StatusSession 记得——现在三边共用这一个，各自只写 handle()。
@MainActor
final class AgentSocket {
    /// 每条下行文本帧（string 帧或可转 UTF-8 的 data 帧）。
    var onMessage: ((String) -> Void)?
    /// socket 每次就绪（首连与自动重连都触发）——调用方在这里重发未确认队列。
    var onOpen: (() -> Void)?
    /// 建连/重连时取到空 bearer——身份没了，重试无意义，socket 停在关闭态。
    /// 调用方用它把 UI 置为「未登录」（旧版每次 openSocket 都查一遍 token 的等价物）。
    var onAuthLost: (() -> Void)?

    /// 生命周期是一个比特：closed。初始为 true（从未连过），connect → false，
    /// disconnect / onAuthLost → true。active 只是它的取反视图——不要再引入
    /// 第二个标志位，正是 closed/active 两个近似互补的字段让「orphan reconnect
    /// 复活」这类 bug 有了藏身处。
    private var closed = true
    var active: Bool { !closed }

    /// 代际计数：connect()/disconnect() 各自 +1。所有延迟动作（reconnect 的
    /// 1.5s 睡眠）持有发起时的代数，醒来后代数不对就直接作废——否则 disconnect
    /// 后紧跟 connect 会把 closed 翻回 false，一个断连前排下的 reconnect 醒来
    /// 就会拆掉刚建好的健康连接。
    private var generation = 0

    private var task: URLSessionWebSocketTask?
    /// 跨重连复用同一个 URLSession（连接池/队列只建一次）；disconnect 才销毁。
    private var session: URLSession?
    private var heartbeat: Task<Void, Never>?
    private var url: URL?
    /// 每次建连现取 token（不缓存）——账号切换 adoptToken 后重连要用新身份。
    private var bearerProvider: @MainActor () -> String = { "" }

    func connect(url: URL, bearer: @escaping @MainActor () -> String) {
        // 幂等：已在同一目标上活跃就不重开（LibraryView 的 .task 会随视图重建
        // 反复调 connect()）。换 url（例如换文章的 stem）才算真的要重连。
        if active, self.url == url { return }
        self.url = url
        bearerProvider = bearer
        closed = false
        generation += 1
        openSocket()
    }

    private func openSocket() {
        guard let url, !closed else { return }
        let bearer = bearerProvider()
        guard !bearer.isEmpty else {
            // 身份没了（正常流程不会走到；防御销号/异常清空）：停在关闭态并上报，
            // 而不是拿空 token 每 1.5s 撞一次服务端。
            closed = true
            generation += 1
            onAuthLost?()
            return
        }
        // 先杀旧 task 再开新——保证任何路径下同时最多一条活 socket。
        task?.cancel(with: .goingAway, reason: nil)
        var req = URLRequest(url: url)
        req.setBearer(bearer)
        let s = session ?? URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        startHeartbeat(t)
        onOpen?()
    }

    /// JSON payload → string 帧。发送失败不当用户错误——调用方把 item 留在
    /// 队列里，重连路径自会重发；onFailure 只用来让状态机保持 working。
    /// 没有活连接 / 序列化失败也走 onFailure（静默吞帧过一次审查，别再来）。
    func send(_ payload: [String: Any], onFailure: (@MainActor () -> Void)? = nil) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            onFailure?()
            return
        }
        task.send(.string(str)) { err in
            guard err != nil else { return }
            Task { @MainActor in onFailure?() }
        }
    }

    private func receive() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            Task { @MainActor in
                // 代际守卫：openSocket 开新前会 cancel 旧 task，旧 task 挂起的 receive
                // 会以 .failure 迟到落地——不挡掉就会 reconnect 再杀掉健康的新连接，
                // 形成永久 1.5s 重连循环。只有「当前这条」socket 的回调才算数。
                guard let self, self.task === t else { return }
                switch result {
                case .failure:
                    if !self.closed { self.reconnect() }
                case .success(let message):
                    switch message {
                    case .string(let str): self.onMessage?(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.onMessage?(str) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    /// 25s WebSocket 心跳（2026-07-25）：国内运营商 NAT/中间设备对空闲加密长连接
    /// 的回收在几十秒级，Cloudflare 边缘对空闲 WS 也有 ~100s 掐线——两条指令之间
    /// 纯静默的连接大概率已死，下次说话才发现（再等 1.5s 重连）。心跳既保活，也
    /// 把死连接提前暴露：ping 失败立刻走既有 reconnect 路径。旧 task 的心跳在开
    /// 新 socket / disconnect 时取消；`self.task === t` 的代际检查防止旧心跳操作
    /// 新连接。
    private func startHeartbeat(_ t: URLSessionWebSocketTask) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled, let self, !self.closed, self.task === t else { return }
                let dead = await Self.ping(t)
                guard !Task.isCancelled, !self.closed, self.task === t else { return }
                if dead { self.reconnect(); return }
            }
        }
    }

    /// sendPing 的回调在 URLSession 的后台队列上执行——绝不能把 @MainActor 闭包
    /// 递进去（运行时隔离断言直接崩，见 2026-07 Cathier 同款坑）。nonisolated
    /// static 包一层，用 continuation 把结果拉回调用方的 actor 上下文。
    nonisolated private static func ping(_ t: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            t.sendPing { err in cont.resume(returning: err != nil) }
        }
    }

    private func reconnect() {
        guard !closed else { return }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // 代数变了 = 睡眠期间发生过 disconnect/connect，这次重连作废。
            if !self.closed, self.generation == gen { self.openSocket() }
        }
    }

    /// 关闭连接；url/bearerProvider 保留，下次 connect 重来。
    func disconnect() {
        closed = true
        generation += 1
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

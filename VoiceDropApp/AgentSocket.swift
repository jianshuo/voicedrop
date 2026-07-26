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

    /// true 从 connect 起到 disconnect 止（重连空窗期间也算）——给 scenePhase
    /// 驱动的幂等 connect() 用：已连就不再开第二条。旧 StatusSession 靠
    /// `guard task == nil` 防双 socket，但 reconnect 的 3 秒延迟里 task 正是 nil，
    /// 还是会开出两条（每条消息收两遍、配对码 sheet 被顶掉）；active 覆盖整个
    /// 会话生命周期，没有这个空窗。
    private(set) var active = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false
    private var heartbeat: Task<Void, Never>?
    private var url: URL?
    /// 每次建连现取 token（不缓存）——账号切换 adoptToken 后重连要用新身份。
    private var bearerProvider: @MainActor () -> String = { "" }

    func connect(url: URL, bearer: @escaping @MainActor () -> String) {
        self.url = url
        bearerProvider = bearer
        closed = false
        active = true
        openSocket()
    }

    private func openSocket() {
        guard let url, !closed else { return }
        // 先杀旧连接再开新——保证任何路径下同时最多一条活 socket。
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        var req = URLRequest(url: url)
        req.setBearer(bearerProvider())
        let s = URLSession(configuration: .default)
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
    func send(_ payload: [String: Any], onFailure: (@MainActor () -> Void)? = nil) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { err in
            guard err != nil else { return }
            Task { @MainActor in onFailure?() }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !self.closed { self.openSocket() }
        }
    }

    /// 关闭连接；url/bearerProvider 保留，下次 connect 重来。
    func disconnect() {
        closed = true
        active = false
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

extension ArticleDoc {
    /// WS 帧里的 `article` 字段 → ArticleDoc。JSON-null 到达时是 NSNull（非 nil
    /// 但不是合法顶层 JSON 对象）；直接 `data(withJSONObject:)` 会抛 ObjC 异常，
    /// `try?` 接不住 → abort()。先用 isValidJSONObject 挡掉（库级命令
    /// merge/delete 场景 article 常为 null）。
    static func fromWire(_ any: Any?) -> ArticleDoc? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(ArticleDoc.self, from: d)
    }
}

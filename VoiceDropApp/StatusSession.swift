import Foundation
import Observation

/// Maintains a persistent WebSocket to wss://jianshuo.dev/agent/status and
/// delivers real-time mining status updates to the app. The Worker miner pushes a
/// notification at each phase of a recording, so the UI can flip between
/// 待处理 / 听录音 / 挖文章 / 已成文 / 无语音 without polling.
@MainActor
@Observable
final class StatusSession {
    var onPhase: ((String, String) -> Void)?   // (stem, phase) — phase ∈ {asr, mining}
    var onDone: ((String) -> Void)?            // stem that finished (ready or empty)
    var onLinkRequest: ((String, String, String) -> Void)?  // (pairingId, code, pubkey)
    var onLinkRelease: ((String) -> Void)?                  // pairingId

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var closed = false

    private let base = API.agentWS + "/status"

    func connect() {
        guard task == nil else { return }   // already connected or connecting
        closed = false
        open()
    }

    private func open() {
        // reconnect() 会先把 task 设为 nil，再睡 3 秒才调 open()。这 3 秒里 task 正是 nil，
        // 所以 connect()（scenePhase → .active）的 `guard task == nil` 会放行、开出一条 socket；
        // 3 秒后那个延迟的 open() 再开第二条，直接覆盖 task 而不取消前一条 —— 两条活 socket、
        // 每条消息收两遍。重复的 link_request 会让 present() 造出新 UUID 的 Pending，
        // .sheet(item:) 的身份在展示途中被换掉 → 强制 dismiss + 重新 present。
        // 这就是「4 位码显示出来、然后 App 崩了」最可能的成因。
        guard task == nil else { return }

        let token = AuthStore.shared.bearer
        guard !token.isEmpty, let url = URL(string: base) else { return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        let s = URLSession(configuration: .default)
        urlSession = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .failure:
                    self.reconnect()
                case .success(let message):
                    switch message {
                    case .string(let str): self.handle(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "link_request" {
            guard let pid = obj["pairingId"] as? String,
                  let code = obj["code"] as? String,
                  let pubkey = obj["pubkey"] as? String else { return }
            onLinkRequest?(pid, code, pubkey)
            return
        }
        if type == "link_release" {
            if let pid = obj["pairingId"] as? String { onLinkRelease?(pid) }
            return
        }

        guard type == "status_update",
              let stem = obj["stem"] as? String,
              let status = obj["status"] as? String else { return }
        switch status {
        case "asr", "mining": onPhase?(stem, status)
        case "processing": onPhase?(stem, "mining")   // legacy single-phase signal
        case "ready", "empty": onDone?(stem)
        default: break
        }
    }

    private func reconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        guard !closed else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !self.closed { self.open() }
        }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }
}

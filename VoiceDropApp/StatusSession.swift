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

    /// 连接生命周期（建连/25s 心跳/重连/关闭）全在基座里。防双 socket 的家法
    ///（原来的 `guard task == nil`，reconnect 空窗里会漏——「4 位码显示出来、
    /// 然后 App 崩了」的成因）由基座的 active 标志 + 开新前先杀旧统一兜住。
    private let socket = AgentSocket()

    private let base = API.agentWS + "/status"

    func connect() {
        // 幂等由基座负责（同 url 活跃即 no-op）——不要在这层再加 guard，
        // 三个 session 的防双开契约必须只有一份。
        guard !AuthStore.shared.bearer.isEmpty, let url = URL(string: base) else { return }
        socket.onMessage = { [weak self] in self?.handle($0) }
        socket.connect(url: url) { AuthStore.shared.bearer }
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

    func disconnect() {
        socket.disconnect()
    }
}

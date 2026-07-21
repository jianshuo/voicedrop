import Foundation

/// WebSocket client for the Realtime AI 采访员 — connects to OUR Cloudflare relay
/// (`/agent/realtime/relay`), which forwards to OpenAI server-side. The phone never
/// touches OpenAI: users in China can't reach api.openai.com, and OPENAI_API_KEY
/// stays in the worker. Auth is the same `req.setBearer(AuthStore.bearer)` as
/// StatusSession/VoiceEdit. The worker injects the interviewer `session.update`,
/// so this client only streams audio + drives responses. Billing is server-side
/// (the relay meters `response.done.usage`) — nothing to report from here.
///
/// Event names verified live 2026-07-08 against the deployed relay:
///   receive: input_audio_buffer.speech_started / .speech_stopped,
///            response.output_audio.delta (AI voice, base64 PCM16 24k)
///   send:    input_audio_buffer.append / .clear / response.create / response.cancel
@MainActor
final class RealtimeSession {
    // .degraded = 可恢复的掉线（跨境弱网等）→ 调用方静默重连。
    // .unavailable = 服务端硬拒绝（OpenAI 余额/配额耗尽等）→ 重连无益，调用方停手 + 提示。
    enum State: String { case idle, connecting, live, degraded, unavailable }

    // Callbacks injected by RealtimeInterviewer.
    var onAudioDelta: ((Data) -> Void)?      // decoded PCM16 24k mono bytes of AI speech
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onResponseCreated: (() -> Void)?     // AI started a turn (used to set "AI speaking" → mute uplink)
    var onResponseDone: (() -> Void)?        // AI finished a turn (clear "AI speaking" → resume uplink)
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var closed = false
    // 一旦收到服务端硬拒绝（配额/计费）就置位：随后的 socket 关闭 receive .failure 不再
    // 退回 .degraded 触发重连，保持 .unavailable 终态。每次新连接重置。
    private var fatal = false
    // Connection generation. The interview is now toggled on/off repeatedly within one
    // recording, so a CANCELLED task's pending receive-completion can land AFTER the
    // next connect() has reset `closed` — without this token the stale .failure would
    // mark the healthy new connection .degraded (and a stale .success could arm a
    // second receive loop on the new task).
    private var generation = 0

    func connect() {
        guard task == nil else { return }
        generation += 1
        closed = false
        fatal = false
        state = .connecting
        let token = AuthStore.shared.bearer
        // fmt=pcmu 向 relay 声明本包上行是 G.711 μ-law @8kHz（EngineRecorder 的 tee）；
        // relay 据此配置 OpenAI 输入格式。不带参数的旧包保持 24k PCM16 不受影响。
        guard !token.isEmpty, let url = URL(string: "\(API.agentWS)/realtime/relay?fmt=pcmu") else { state = .degraded; return }
        var req = URLRequest(url: url)
        req.setBearer(token)                                  // handshake header, same as StatusSession
        let s = URLSession(configuration: .default)
        urlSession = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive(generation)
        state = .live
    }

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation, !self.closed else { return }
                switch result {
                case .failure:
                    // 区分「可恢复掉线」与「服务端硬拒绝」：后者重连只会风暴，置终态 .unavailable。
                    // 硬拒绝信号：已由 error 事件置 fatal，或 WS 关闭帧带 1013/配额原因（OpenAI
                    // 额度耗尽经 relay 原样透传 close code+reason）。
                    if self.fatal || self.isFatalClose() {
                        self.fatal = true
                        self.state = .unavailable
                    } else {
                        self.state = .degraded        // relay/network dropped — recording continues (caller guarantees)
                    }
                case .success(let message):
                    switch message {
                    case .string(let str): self.handle(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    @unknown default: break
                    }
                    self.receive(gen)
                }
            }
        }
    }

    private func handle(_ str: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started": onSpeechStarted?()
        case "input_audio_buffer.speech_stopped": onSpeechStopped?()
        case "response.created":
            onResponseCreated?()
        case "response.output_audio.delta":
            if let b64 = obj["delta"] as? String, let d = Data(base64Encoded: b64) { onAudioDelta?(d) }
        case "response.done":
            onResponseDone?()
        case "error":
            // OpenAI 先发 error 事件、再关 WS。若是配额/计费类硬错误，立刻置终态——
            // 不等 socket 关闭，也不让随后的 .failure 退回 .degraded 触发重连。
            let err = obj["error"] as? [String: Any]
            let blob = [err?["code"], err?["type"], err?["message"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            if Self.isFatalReason(blob) { fatal = true; state = .unavailable }
        default:
            // First-connect: log unhandled types to confirm names against the live relay.
            break
        }
    }

    /// WS 关闭帧是否代表服务端硬拒绝（OpenAI 额度/计费耗尽）。1013=try-again-later，
    /// OpenAI 配额耗尽正是用它关闭；relay 原样透传 code+reason，reason 里带
    /// "insufficient_quota"。
    private func isFatalClose() -> Bool {
        if task?.closeCode.rawValue == 1013 { return true }
        if let d = task?.closeReason, let s = String(data: d, encoding: .utf8), Self.isFatalReason(s) { return true }
        return false
    }

    private static func isFatalReason(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("insufficient_quota") || t.contains("exceeded_current_quota")
            || t.contains("account_deactivated") || t.contains("billing")
    }

    // MARK: - Send

    func appendAudio(_ pcm16le24k: Data) {
        guard !pcm16le24k.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16le24k.base64EncodedString()])
    }

    func createResponse(maxTokens: Int = 120) {
        send(["type": "response.create", "response": ["max_output_tokens": maxTokens]])
    }

    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    /// Drop whatever partial speech is sitting in OpenAI's input buffer. Called by the
    /// half-duplex gate right before re-opening the mic: muting often cuts the speaker
    /// off MID-UTTERANCE, and that truncated segment would otherwise be closed by the
    /// first post-unmute (silent) audio — semantic_vad reads "speech then stopped" and
    /// auto-fires ANOTHER response with the user having said nothing new.
    func clearInputBuffer() {
        send(["type": "input_audio_buffer.clear"])
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    func disconnect() {
        generation += 1        // invalidate any in-flight receive completion of this task
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .idle
    }
}

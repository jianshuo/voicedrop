import Foundation
import Observation

/// Orchestrates a recording session with an ON-DEMAND AI interviewer overlay.
///
/// ARCHITECTURE (2026-07-08, "采访 = 录音的可叠加旁路"): recording and the interview
/// are decoupled. `start()` starts ONLY the `EngineRecorder` (two-engine, no VPIO —
/// VPIO gave 0 mic buffers on this device) — that's the sacred main path, writing the
/// m4a from the tap unconditionally. The AI interview is a SIDE-PATH the user toggles
/// on/off mid-recording via the 采访 button: `toggleInterview()` connects/disconnects
/// the relay WS. The tap's PCM tee feeds the relay only while the interview is active;
/// the file write never depends on any of this.
///
/// Turn-taking is SERVER/PROMPT-driven: the worker configures `semantic_vad` +
/// `create_response:true` + `interrupt_response:false`, and the interviewer
/// instructions tell the model to stay silent and only interject when the speaker
/// is stuck. No app-side timer here.
///
/// HALF-DUPLEX (no AEC): the AI's loudspeaker leaks into the mic, so while the AI is
/// speaking we PAUSE the uplink (mute) and resume only after response.done AND the
/// playback has drained + a short echo tail — otherwise the model hears its own tail
/// and loops. AI audio in the recording is acceptable (user-confirmed).
///
/// Each toggle-on → toggle-off is an independent relay session; the worker settles
/// billing on WS close.
@MainActor
@Observable
final class RealtimeInterviewer: RecordingBackend {
    let engine = EngineRecorder()
    let session = RealtimeSession()

    /// The interview side-path is currently on (relay connected or connecting).
    private(set) var interviewActive = false
    /// 本段录音里采访是否用过（哪怕已关掉）——录音完成事件的属性。
    private(set) var interviewWasUsed = false
    private var interviewStartedAt: Date?
    private(set) var connState: RealtimeSession.State = .idle

    // Half-duplex state — see class comment.
    private var aiSpeaking = false
    private var aiTurnEnded = false          // OpenAI finished GENERATING (response.done)
    private var resumeTask: Task<Void, Never>?
    private var muteWatchdog: Task<Void, Never>?

    // Auto-reconnect: 跨境弱网（北京→Cloudflare）下 relay WS 会掉线;掉线不该等于
    // 整段采访报废——指数退避静默重连（1/2/4…s,最多 6 次）,连回即恢复。录音不受影响。
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    var onInterrupted: ((AudioRecorder.Recording) -> Void)? {
        get { engine.onInterrupted }
        set {
            guard let handler = newValue else { engine.onInterrupted = nil; return }
            engine.onInterrupted = { [weak self] take in
                // 来电/Siri 中断走 engine 级 stop,这里补上采访侧的收尾:立刻断 relay
                // (worker 在 WS close 时结算这段计费),别让计费表跟着中断悬空地走。
                if let self, self.interviewActive { self.stopInterview() }
                handler(take)
            }
        }
    }

    /// Start RECORDING only (sacred). The interview is NOT connected here — the user
    /// toggles it with the 采访 button. Throws only if recording can't start.
    func start() throws {
        wireCallbacks()
        try engine.start()
    }

    /// 采访 button: toggle the AI side-path. Recording is never touched.
    func toggleInterview() {
        if interviewActive { stopInterview() } else { startInterview() }
    }

    private func startInterview() {
        guard engine.isRecording else { return }
        interviewActive = true
        interviewWasUsed = true
        interviewStartedAt = Date()
        Analytics.capture("采访开启")
        aiSpeaking = false
        aiTurnEnded = false
        engine.teeEnabled = true  // Sink starts producing 24k PCM only from here on
        session.connect()       // best-effort; failure = degraded badge, recording continues
    }

    private func stopInterview() {
        interviewActive = false
        if let began = interviewStartedAt {
            Analytics.capture("采访结束", ["时长秒": Int(Date().timeIntervalSince(began))])
            interviewStartedAt = nil
        }
        engine.teeEnabled = false // Sink stops the resample/tee — plain recording pays nothing
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempt = 0
        resumeTask?.cancel(); resumeTask = nil
        muteWatchdog?.cancel(); muteWatchdog = nil
        aiSpeaking = false
        aiTurnEnded = false
        engine.stopAIPlayback()   // silence any in-flight AI speech immediately
        session.disconnect()      // worker settles this segment's billing on close
    }

    /// Silent exponential-backoff reconnect while the interview is toggled on.
    /// Gives up after 6 attempts (~1 min) and leaves the degraded badge — the user
    /// can still toggle off/on manually, and the recording was never touched.
    private func scheduleReconnect() {
        guard interviewActive, reconnectTask == nil, reconnectAttempt < 6 else { return }
        let delay = Double(1 << reconnectAttempt)          // 1,2,4,8,16,32s
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.interviewActive, self.connState == .degraded else { return }
            // Fresh half-duplex slate: any in-flight AI turn died with the old socket.
            self.aiSpeaking = false
            self.aiTurnEnded = false
            self.session.disconnect()
            self.session.connect()
        }
    }

    private func wireCallbacks() {
        session.onStateChange     = { [weak self] s in
            guard let self else { return }
            self.connState = s
            if s == .live { self.reconnectAttempt = 0 }
            if s == .degraded { self.scheduleReconnect() }
            if s == .unavailable {
                // 服务端硬拒绝（OpenAI 额度/计费耗尽）：重连只会风暴，就地停手。停上行
                // tee（不再为死连接缓冲/计费），取消重连，保留 .unavailable 终态让录音界面
                // 显示「采访暂不可用」。录音全程不受影响；用户可手动点「采访」关掉旁路。
                self.reconnectTask?.cancel(); self.reconnectTask = nil
                self.reconnectAttempt = 0
                self.engine.teeEnabled = false
                self.aiSpeaking = false; self.aiTurnEnded = false
                self.engine.stopAIPlayback()
                Analytics.capture("采访不可用")
            }
        }
        session.onResponseCreated = { [weak self] in self?.beginAiTurn() }             // AI about to speak
        session.onAudioDelta      = { [weak self] pcm in
            guard let self, self.interviewActive else { return }   // toggle-off: drop late audio
            self.beginAiTurn(); self.engine.playAI(pcm)
        }
        session.onResponseDone    = { [weak self] in self?.aiTurnEnded = true; self?.tryResume() }
        engine.onPlaybackDrained  = { [weak self] in self?.tryResume() }               // AI audio finished PLAYING
        engine.onPCM              = { [weak self] pcm in
            // The tee feeds the AI ONLY while interviewing and the AI isn't speaking
            // (half-duplex). The m4a write happened before this callback, always.
            guard let self, self.interviewActive, !self.aiSpeaking else { return }
            self.session.appendAudio(pcm)
        }
    }

    private func beginAiTurn() {
        guard interviewActive else { return }
        resumeTask?.cancel(); resumeTask = nil
        aiSpeaking = true
        aiTurnEnded = false
        // Safety: never stay muted forever if a done/drain signal is somehow missed.
        muteWatchdog?.cancel()
        muteWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.openMic()
        }
    }

    /// Re-open the uplink. Clears OpenAI's input buffer FIRST: the mute likely cut the
    /// speaker off mid-utterance, and that stale half-segment would be closed by the
    /// first fresh audio — semantic_vad reads it as a finished turn and auto-fires yet
    /// another response, chaining into the "AI 自顾自说个不停" loop.
    private func openMic() {
        if interviewActive { session.clearInputBuffer() }
        aiSpeaking = false
    }

    /// Resume the uplink ONLY after the AI has finished generating (response.done)
    /// AND its audio has finished playing (playback drained), plus a short echo tail.
    private func tryResume() {
        guard aiSpeaking, aiTurnEnded, engine.isPlaybackIdle else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))   // room echo tail
            guard !Task.isCancelled else { return }
            self?.muteWatchdog?.cancel()
            self?.openMic()
        }
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        if interviewActive { stopInterview() }
        return engine.stop()
    }

    // Proxy the recording UI state to the engine.
    var isRecording: Bool { engine.isRecording }
    var elapsed: TimeInterval { engine.elapsed }
    var level: Double { engine.level }
    var startDate: Date? { engine.startDate }
}

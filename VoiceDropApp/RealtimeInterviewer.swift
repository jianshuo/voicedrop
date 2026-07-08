import Foundation
import Observation

/// Orchestrates a realtime AI-interviewer recording session: owns the
/// `EngineRecorder` (two-engine, no VPIO — VPIO gave 0 mic buffers on iOS 26 / this
/// device after exhaustive attempts) and the `RealtimeSession` (relay WS). Wires mic
/// PCM → relay and AI audio → speaker.
///
/// Turn-taking is SERVER/PROMPT-driven (2026-07-08): the worker configures
/// `semantic_vad` + `create_response:true` + `interrupt_response:false`, and the
/// interviewer instructions tell the model to stay silent and only interject a brief
/// question when the speaker is stuck. No app-side timer / rate-limit here.
///
/// HALF-DUPLEX (no AEC): the AI's loudspeaker leaks into the mic, so while the AI is
/// speaking we PAUSE the mic uplink (mute) and resume after a short echo tail — this
/// stops the model hearing its own voice (which would loop or cut its turn short).
/// Trade-off: you can't barge-in mid-AI-turn, but AI turns are short (<5 s). AI audio
/// in the recording is acceptable (user-confirmed).
///
/// Recording is sacred: `engine.start()` runs first; the relay is best-effort and any
/// failure just degrades (recording continues). Billing is server-side.
@MainActor
@Observable
final class RealtimeInterviewer {
    let engine = EngineRecorder()
    let session = RealtimeSession()

    private(set) var connState: RealtimeSession.State = .idle

    /// One-line diagnostics for the on-screen overlay (realtime mode).
    var debugLine: String {
        "tap \(engine.tapBuffers) · WS \(connState.rawValue) · 语音 \(session.speechEvents) · AI音 \(session.audioDeltas)"
            + (engine.engineError.map { " · ⚠️\($0)" } ?? "")
    }

    // Half-duplex: no AEC on device (VPIO killed the tap), so the AI's loudspeaker leaks
    // into the mic. To stop the model from hearing itself (and either looping or cutting
    // its own turn short), we PAUSE the mic uplink while the AI is speaking, then resume
    // after a short tail so the room echo has died down. This loses true barge-in, but the
    // AI's turns are short (<5 s) and this is the only reliable capture path on-device.
    private var aiSpeaking = false
    private var aiTurnEnded = false          // OpenAI finished GENERATING (response.done)
    private var resumeTask: Task<Void, Never>?
    private var muteWatchdog: Task<Void, Never>?

    var onInterrupted: ((AudioRecorder.Recording) -> Void)? {
        get { engine.onInterrupted }
        set { engine.onInterrupted = newValue }
    }

    /// Start recording (sacred) + connect the relay. Throws only if RECORDING can't
    /// start — the relay never throws here (failure = degraded, recording continues).
    func start() throws {
        EngineRecorder.trace("interviewer.start(): wiring callbacks")
        session.onStateChange     = { [weak self] s in self?.connState = s }
        session.onResponseCreated = { [weak self] in self?.beginAiTurn() }             // AI about to speak
        session.onAudioDelta      = { [weak self] pcm in self?.beginAiTurn(); self?.engine.playAI(pcm) }
        session.onResponseDone    = { [weak self] in self?.aiTurnEnded = true; self?.tryResume() }
        engine.onPlaybackDrained  = { [weak self] in self?.tryResume() }               // AI audio finished PLAYING
        engine.onPCM              = { [weak self] pcm in
            guard let self, !self.aiSpeaking else { return }   // half-duplex: don't feed the AI its own echo
            self.session.appendAudio(pcm)
        }

        EngineRecorder.trace("interviewer.start(): engine.start() BEGIN")
        try engine.start()      // if this throws, nothing else has run — no AI, no relay
        EngineRecorder.trace("interviewer.start(): engine.start() END → session.connect()")
        session.connect()       // best-effort
        EngineRecorder.trace("interviewer.start(): session.connect() returned (recording live)")
    }

    private func beginAiTurn() {
        resumeTask?.cancel(); resumeTask = nil
        aiSpeaking = true
        aiTurnEnded = false
        // Safety: never stay muted forever if a done/drain signal is somehow missed.
        muteWatchdog?.cancel()
        muteWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.aiSpeaking = false
        }
    }

    /// Resume the mic uplink ONLY after the AI has finished generating (response.done)
    /// AND its audio has finished playing out of the loudspeaker (playback drained),
    /// plus a short echo tail. Resuming on response.done alone let the still-playing AI
    /// audio re-enter the mic → OpenAI heard itself → non-stop looping.
    private func tryResume() {
        guard aiSpeaking, aiTurnEnded, engine.isPlaybackIdle else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))   // room echo tail
            guard !Task.isCancelled else { return }
            self?.muteWatchdog?.cancel()
            self?.aiSpeaking = false
        }
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        resumeTask?.cancel(); resumeTask = nil
        muteWatchdog?.cancel(); muteWatchdog = nil
        session.disconnect()    // worker settles billing on close
        return engine.stop()
    }

    // Proxy the recording UI state to the engine.
    var isRecording: Bool { engine.isRecording }
    var elapsed: TimeInterval { engine.elapsed }
    var level: Double { engine.level }
}

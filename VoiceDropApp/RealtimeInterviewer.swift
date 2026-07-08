import Foundation
import Observation

/// Orchestrates a realtime AI-interviewer recording session: owns the
/// `EngineRecorder` (single full-duplex engine with AEC) and the `RealtimeSession`
/// (relay WS). Wires mic PCM → relay and AI audio → speaker.
///
/// Turn-taking is now fully SERVER/PROMPT-driven (2026-07-08): the worker configures
/// `semantic_vad` + `create_response:true` + `interrupt_response:true`, and the
/// interviewer instructions tell the model to stay silent and only interject a brief
/// question when the speaker is stuck. So there is NO app-side timer / rate-limit /
/// barge-in logic here — the app just streams mic up and plays AI down. AEC keeps the
/// AI's own voice out of the mic, so the model hears only the user (real barge-in via
/// interrupt_response; no echo self-interruption).
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
    private var resumeTask: Task<Void, Never>?

    var onInterrupted: ((AudioRecorder.Recording) -> Void)? {
        get { engine.onInterrupted }
        set { engine.onInterrupted = newValue }
    }

    /// Start recording (sacred) + connect the relay. Throws only if RECORDING can't
    /// start — the relay never throws here (failure = degraded, recording continues).
    func start() throws {
        session.onStateChange     = { [weak self] s in self?.connState = s }
        session.onResponseCreated = { [weak self] in self?.muteUplink() }              // AI about to speak
        session.onAudioDelta      = { [weak self] pcm in self?.muteUplink(); self?.engine.playAI(pcm) }
        session.onResponseDone    = { [weak self] in self?.resumeUplinkAfterTail() }   // AI finished
        engine.onPCM              = { [weak self] pcm in
            guard let self, !self.aiSpeaking else { return }   // half-duplex: don't feed the AI its own echo
            self.session.appendAudio(pcm)
        }

        try engine.start()      // if this throws, nothing else has run — no AI, no relay
        session.connect()       // best-effort
    }

    private func muteUplink() { resumeTask?.cancel(); resumeTask = nil; aiSpeaking = true }

    private func resumeUplinkAfterTail() {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))   // let the loudspeaker echo tail dissipate
            guard !Task.isCancelled else { return }
            self?.aiSpeaking = false
        }
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        resumeTask?.cancel(); resumeTask = nil
        session.disconnect()    // worker settles billing on close
        return engine.stop()
    }

    // Proxy the recording UI state to the engine.
    var isRecording: Bool { engine.isRecording }
    var elapsed: TimeInterval { engine.elapsed }
    var level: Double { engine.level }
}

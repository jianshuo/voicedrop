import Foundation
@preconcurrency import AVFoundation
import Observation

/// AVAudioEngine recording backend, used ONLY in realtime (AI) mode. Produces the
/// SAME staging `recording-<ts>.m4a` (AAC mono, `Prefs.recorderSettings`) as
/// `AudioRecorder`, so promote/upload downstream is unchanged. Additionally:
///   • tees the mic PCM (resampled to 24 kHz Int16) to `onPCM` for the AI uplink,
///   • enables voice-processing AEC so the AI's loudspeaker audio is cancelled out
///     of the mic before it's written to the file (keeps the recording clean),
///   • plays AI audio via an `AVAudioPlayerNode` routed through the engine mixer,
///     so the AEC reference signal is present.
///
/// The mic tap runs on a realtime audio thread, NOT the main actor — so the file
/// write + resample live in a `@unchecked Sendable` `Sink` (mirrors `VoiceEdit`'s
/// `VolcAudioStreamer`); only `level`/`onPCM` hop back to the main actor.
///
/// DEVICE-VERIFY (Task 2/3 gate, simulator ≠ device):
///   1) the .m4a is valid, glitch-free, equivalent to AudioRecorder's;
///   2) AEC actually keeps AI voice out of the file;
///   3) AI playback is intelligible. Iterate on a real phone.
@MainActor
@Observable
final class EngineRecorder: RecordingBackend {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var startDate: Date?
    var onInterrupted: ((AudioRecorder.Recording) -> Void)?

    /// Mic PCM teed for the AI uplink: mono Int16 little-endian @ 24 kHz.
    var onPCM: ((Data) -> Void)?

    static let aiRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sink: Sink?
    private var currentURL: URL?
    private var startInstant: Date?
    private var tickTask: Task<Void, Never>?
    private var playerFormat: AVAudioFormat?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    static func ensurePermission() async -> Bool { await AudioRecorder.ensurePermission() }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)      // AEC/AGC/NS; must precede wiring

        // AI playback path THROUGH the engine (gives voice-processing the reference).
        engine.attach(player)
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        playerFormat = mixerFormat
        engine.connect(player, to: engine.mainMixerNode, format: mixerFormat)

        // Open the AAC file; install the tap in the file's processingFormat so
        // `write(from:)` matches directly (the engine converts mic → that format).
        let now = Date()
        let url = AudioRecorder.stagingURL(start: now)
        let file = try AVAudioFile(forWriting: url, settings: Prefs.shared.recorderSettings)
        let s = Sink(file: file, aiRate: EngineRecorder.aiRate)
        s.onTee = { [weak self] pcm, lvl in
            Task { @MainActor in self?.level = lvl; self?.onPCM?(pcm) }
        }
        sink = s
        currentURL = url
        startInstant = now

        input.installTap(onBus: 0, bufferSize: 4096, format: file.processingFormat, block: s.makeTapBlock())
        engine.prepare()
        try engine.start()
        player.play()

        startDate = now
        isRecording = true
        elapsed = 0
        startTicking()
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        guard isRecording, let url = currentURL, let start = startInstant else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
        sink = nil                    // release/close the file
        stopTicking()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = AudioRecorder.Recording(url: url, start: start, duration: elapsed)
        currentURL = nil
        startInstant = nil
        startDate = nil
        return take
    }

    /// Play a chunk of AI speech (mono Int16 LE @ 24 kHz) through the engine.
    func playAI(_ pcm16le24k: Data) {
        guard isRecording, let outFormat = playerFormat,
              let buffer = EngineRecorder.makeBuffer(fromInt16: pcm16le24k, inRate: EngineRecorder.aiRate, outFormat: outFormat)
        else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Interruption / ticking (mirror AudioRecorder)

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in if let take = self.stop() { self.onInterrupted?(take) } }
    }

    private func startTicking() {
        let start = startInstant ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
    private func stopTicking() { tickTask?.cancel(); tickTask = nil }

    // MARK: - Audio-thread sink (owns the file; @unchecked Sendable like VolcAudioStreamer)

    private final class Sink: @unchecked Sendable {
        private let file: AVAudioFile
        private let aiRate: Double
        var onTee: (@Sendable (Data, Double) -> Void)?
        init(file: AVAudioFile, aiRate: Double) { self.file = file; self.aiRate = aiRate }

        func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let self else { return }
                try? self.file.write(from: buffer)                       // SACRED: file first
                if let pcm = EngineRecorder.resampleToInt16(buffer, outRate: self.aiRate), !pcm.isEmpty {
                    self.onTee?(pcm, EngineRecorder.rms(buffer))         // best-effort tee
                }
            }
        }
    }

    // MARK: - DSP (hand-rolled linear interpolation, mirrors VoiceEdit; no AVAudioConverter)

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return Double(max(0, min(1, (db + 50) / 50)))
    }

    nonisolated static func resampleToInt16(_ buffer: AVAudioPCMBuffer, outRate: Double) -> Data? {
        let inRate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        guard inRate > 0, frames > 0, chans > 0 else { return nil }
        let outFrames = max(1, Int(Double(frames) * outRate / inRate))
        var out = [Int16]()
        out.reserveCapacity(outFrames)
        if let ch = buffer.floatChannelData {
            for i in 0..<outFrames {
                let pos = Double(i) * inRate / outRate
                let a = min(frames - 1, Int(pos)), b = min(frames - 1, Int(pos) + 1)
                let frac = Float(pos - Double(a))
                var mixed: Float = 0
                for c in 0..<chans { let cur = ch[c][a]; mixed += cur + (ch[c][b] - cur) * frac }
                let mono = max(-1, min(1, mixed / Float(chans)))
                out.append(Int16((mono * Float(Int16.max)).rounded()))
            }
        } else if let ch = buffer.int16ChannelData {
            for i in 0..<outFrames {
                let pos = Double(i) * inRate / outRate
                let a = min(frames - 1, Int(pos)), b = min(frames - 1, Int(pos) + 1)
                let frac = Float(pos - Double(a))
                var mixed: Float = 0
                for c in 0..<chans { mixed += Float(ch[c][a]) + (Float(ch[c][b]) - Float(ch[c][a])) * frac }
                out.append(Int16(clamping: Int((mixed / Float(chans)).rounded())))
            }
        } else { return nil }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func makeBuffer(fromInt16 data: Data, inRate: Double, outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inCount = data.count / MemoryLayout<Int16>.size
        guard inCount > 0, let ch0 = outFormat.channelCount as AVAudioChannelCount?, ch0 > 0 else { return nil }
        let samples = data.withUnsafeBytes { raw -> [Int16] in Array(raw.bindMemory(to: Int16.self)) }
        let outRate = outFormat.sampleRate
        let outFrames = max(1, Int(Double(inCount) * outRate / inRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outFrames)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(outFrames)
        let chans = Int(outFormat.channelCount)
        for i in 0..<outFrames {
            let pos = Double(i) * inRate / outRate
            let a = min(inCount - 1, Int(pos)), b = min(inCount - 1, Int(pos) + 1)
            let frac = Float(pos - Double(a))
            let v = (Float(samples[a]) + (Float(samples[b]) - Float(samples[a])) * frac) / Float(Int16.max)
            for c in 0..<chans { ch[c][i] = v }
        }
        return buf
    }
}

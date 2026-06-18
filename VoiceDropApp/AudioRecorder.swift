import Foundation
import AVFoundation
import Observation

/// Wraps AVAudioRecorder. Records mono AAC into Documents/VoiceDrop-<timestamp>.m4a,
/// exposes a live elapsed time, and handles audio-session interruptions
/// (e.g. an incoming call) by finalizing the current recording.
///
/// The file is named VoiceDrop-<start-timestamp>.m4a up front (so it's already a
/// valid queue entry if the app is killed mid-recording). At stop, ContentView
/// renames it to the enriched name (duration + weekday + place) before upload.
@MainActor
@Observable
final class AudioRecorder {

    /// A finished take, handed to ContentView for enrichment + upload.
    struct Recording: Sendable {
        let url: URL
        let start: Date
        let duration: TimeInterval
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "无法开始录音" }
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var startDate: Date?
    private var tickTask: Task<Void, Never>?

    /// Called when a recording is finalized by an external interruption.
    var onInterrupted: ((Recording) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - Permission

    static func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    static var isDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    // MARK: - Recording

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true)

        let now = Date()
        let url = Self.provisionalURL(start: now)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record() else { throw RecorderError.couldNotStart }

        recorder = rec
        currentURL = url
        startDate = now
        isRecording = true
        elapsed = 0
        startTicking()
    }

    /// Stops recording and returns the finished take (nil if not recording).
    @discardableResult
    func stop() -> Recording? {
        guard isRecording, let url = currentURL, let start = startDate else { return nil }
        recorder?.stop()
        recorder = nil
        stopTicking()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = Recording(url: url, start: start, duration: elapsed)
        currentURL = nil
        startDate = nil
        return take
    }

    // MARK: - Interruption

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        Task { @MainActor in
            if let take = self.stop() {
                self.onInterrupted?(take)
            }
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        let start = startDate ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - File naming

    /// Provisional name = VoiceDrop-<start timestamp>.m4a. Already a valid queue
    /// entry; renamed to the enriched name at stop.
    static func provisionalURL(start: Date) -> URL {
        let name = "VoiceDrop-\(RecordingName.timestamp(start)).m4a"
        return documentsDir.appending(path: name)
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

import Foundation

/// Shared interface so RecordSession can drive either recording backend without a
/// mid-session switch: `AudioRecorder` (default, AVAudioRecorder — untouched) or
/// `EngineRecorder` (AVAudioEngine, only in realtime/AI mode). The backend is chosen
/// at record START (normal red-key tap vs. the realtime trigger) and never switched,
/// so recording is never interrupted. Both produce the same `AudioRecorder.Recording`
/// → identical promote/upload downstream.
@MainActor
protocol RecordingBackend: AnyObject {
    var isRecording: Bool { get }
    var elapsed: TimeInterval { get }
    var level: Double { get }
    var startDate: Date? { get }
    var onInterrupted: ((AudioRecorder.Recording) -> Void)? { get set }
    func start() throws
    @discardableResult func stop() -> AudioRecorder.Recording?
}

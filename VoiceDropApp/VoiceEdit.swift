import SwiftUI
import Speech
import AVFoundation
import Observation

/// Apple on-device speech recognition wrapped for SwiftUI. Streams mic audio into
/// SFSpeechRecognizer and publishes a live partial transcript. zh-CN locale.
@MainActor
@Observable
final class SpeechDictation {
    var transcript = ""
    var isRecording = false
    var authorized: Bool? = nil      // nil = not asked yet
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Ask for speech + mic permission. Sets `authorized`. The speech callback is
    /// run via a NON-isolated helper: SFSpeechRecognizer delivers it on a background
    /// queue, and a main-actor-isolated closure would trap under Swift 6.
    func requestAuth() async {
        let speech = await Self.requestSpeechAuth()
        let mic = await AVAudioApplication.requestRecordPermission()
        let ok = speech == .authorized && mic
        authorized = ok
        if !ok { error = "需要在设置里允许语音识别和麦克风权限。" }
    }

    nonisolated private static func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    func start() {
        guard authorized == true, !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else { error = "语音识别暂不可用。"; return }
        transcript = ""; error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = false   // allow Apple cloud ASR (better zh-CN accuracy)
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // The tap fires on the realtime audio thread; the result handler on a
            // Speech background queue. Both are @Sendable so they DON'T inherit this
            // class's @MainActor isolation (which would trap off-main under Swift 6).
            nonisolated(unsafe) let tapReq = req
            let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                tapReq.append(buffer)
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
            engine.prepare()
            try engine.start()
            isRecording = true

            let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, err in
                let text = result?.bestTranscription.formattedString   // String? — Sendable
                let done = err != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stop() }
                }
            }
            task = recognizer.recognitionTask(with: req, resultHandler: resultHandler)
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

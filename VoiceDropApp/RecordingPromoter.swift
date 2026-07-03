import Foundation

/// THE single "finish a recording" step: rename the staging take to its enriched,
/// self-describing filename (fallback to a basic name if the move fails), then
/// archive to iCloud when enabled. Was copy-pasted in RecordSession.promote and
/// Community.promote (the reply path), which drifted in their fallback handling.
enum RecordingPromoter {
    /// Move `take` to its final on-disk URL and (best-effort) archive it. Returns the
    /// URL the file actually ended up at — callers attach any extra metadata to that.
    @MainActor
    static func promote(_ take: AudioRecorder.Recording, place: String?) async -> URL {
        let finalName = RecordingName.make(start: take.start, duration: take.duration, place: place)
        var url = AudioRecorder.documentsDir.appending(path: finalName)
        do {
            try FileManager.default.moveItem(at: take.url, to: url)
        } catch {
            // Enriched move failed — try a basic name; if even that fails, keep the
            // staging file (it still exists on disk) so nothing is lost.
            let basic = AudioRecorder.documentsDir.appending(path: "VoiceDrop-\(RecordingName.timestamp(take.start)).m4a")
            url = (try? FileManager.default.moveItem(at: take.url, to: basic)) != nil ? basic : take.url
        }
        if Prefs.shared.iCloudBackup {
            let toArchive = url
            await Task.detached { ICloudArchive.save(toArchive) }.value
        }
        return url
    }
}

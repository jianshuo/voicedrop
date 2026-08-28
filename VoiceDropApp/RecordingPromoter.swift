import Foundation

/// THE single "finish a recording" step: rename the staging take to its enriched,
/// self-describing filename (fallback to a basic name if the move fails), then
/// archive to iCloud when enabled. Was copy-pasted in RecordSession.promote and
/// Community.promote (the reply path), which drifted in their fallback handling.
enum RecordingPromoter {
    /// 不足这个时长的录音产不出文章——不进上传队列，直接丢弃。
    static let minDuration: TimeInterval = 4

    /// 正在等待地理富名改名的文件名（内存态）。Uploader 的 pendingFiles 扫描跳过
    /// 它们：无地名文件一落盘就进扫描域，若此刻被 drain 领走，随后的改富名并不会
    /// 让那次上传失败——BackgroundTransfer 的 URLSession 在任务创建时已拷走文件，
    /// 上传照样成功，收尾 removeItem 删旧路径静默失败，富名文件随后被当作新录音
    /// 再传一遍：同一 take 服务端建两个文档、挖出两篇文章（2026-08-28 实锤）。
    /// 内存态是有意的：进程在窗口期被杀，集合随之蒸发，下次启动按盘上现名正常
    /// 上传——最坏只丢地名，录音 never lost，也永不双传。
    @MainActor private static var enrichHolds: Set<String> = []
    @MainActor static func isHeldForEnrichment(_ name: String) -> Bool { enrichHolds.contains(name) }

    /// Move `take` to its final on-disk URL and (best-effort) archive it. Returns the
    /// URL the file actually ended up at — callers attach any extra metadata to that.
    /// A take shorter than `minDuration` is deleted here and returns nil, so no
    /// caller path (stop / interruption / onDisappear / community reply) can upload it.
    ///
    /// ⚠️ 文件移动必须发生在任何 await 之前（2026-08-26 review bug①）：stop() 返回
    /// 时 moov 已写完、文件完好，但 staging 名（`recording-*`）上传队列不认——若先
    /// await 地理编码（最坏 ~3s）再移动，这个窗口里进程被杀，录音就成了永久孤儿。
    /// 所以 place 改成闭包：先落无地名的正式名（立刻进入上传队列可见域），拿到
    /// 地名后再改富名；改名失败保持无地名，只丢地名、不丢录音。
    @MainActor
    static func promote(_ take: AudioRecorder.Recording, place: @MainActor () async -> String?) async -> URL? {
        guard take.duration >= minDuration else {
            try? FileManager.default.removeItem(at: take.url)
            return nil
        }
        let bareName = RecordingName.make(start: take.start, duration: take.duration, place: nil)
        var url = AudioRecorder.documentsDir.appending(path: bareName)
        do {
            try FileManager.default.moveItem(at: take.url, to: url)
        } catch {
            // Bare move failed — try a basic name; if even that fails, keep the
            // staging file (it still exists on disk) so nothing is lost.
            let basic = AudioRecorder.documentsDir.appending(path: "VoiceDrop-\(RecordingName.timestamp(take.start)).m4a")
            url = (try? FileManager.default.moveItem(at: take.url, to: basic)) != nil ? basic : take.url
        }
        // 文件已安全，地理标注只是文件名的锦上添花。挂住这次 take：改富名结束前
        // 不让 drain 领走（否则无地名、带地名各传一次——见 enrichHolds 注释）。
        // moveItem 与 insert 之间没有 await，主线程上原子，drain 不可能插队。
        let heldName = url.lastPathComponent
        enrichHolds.insert(heldName)
        if let placeTag = await place(), !placeTag.isEmpty, url != take.url {
            let enriched = AudioRecorder.documentsDir.appending(
                path: RecordingName.make(start: take.start, duration: take.duration, place: placeTag))
            if (try? FileManager.default.moveItem(at: url, to: enriched)) != nil { url = enriched }
        }
        enrichHolds.remove(heldName)
        if Prefs.shared.iCloudBackup {
            let toArchive = url
            await Task.detached { ICloudArchive.save(toArchive) }.value
        }
        return url
    }
}

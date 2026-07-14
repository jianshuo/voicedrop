import Foundation
import Observation
import Network
import UIKit

/// Uploads recordings to jianshuo.dev/files via the R2-backed PUT API.
/// The Documents directory IS the pending queue: a `VoiceDrop-*.m4a` file that
/// still exists has not been uploaded. On success the file is deleted.
///
/// Resilience — why a finalized take never gets stuck on 正在上传 anymore:
/// - each PUT holds a short **background-task assertion**, so an upload kicked
///   off in the foreground (e.g. right after recording) can finish even if the
///   user immediately locks the screen or switches apps — iOS no longer kills
///   the request the instant we leave the foreground;
/// - transient failures (network blip, timeout, task-cancelled-on-suspend, 5xx)
///   are **retried with backoff** in-call; a take that still fails is left on
///   disk for the next drain — it is never lost;
/// - `drainPending` no longer aborts the queue on the first failure, so one
///   stubborn take can't wedge everything queued behind it;
/// - an `NWPathMonitor` re-drains the queue the moment connectivity returns.
@MainActor
@Observable
final class Uploader {

    private(set) var pendingCount: Int = 0
    private(set) var pending: [URL] = []      // local takes still queued (observable)
    private(set) var justUploaded: [String] = []  // uploaded, awaiting server confirmation
    private(set) var lastError: String?

    private let baseURL = API.filesBase

    /// Per-user bearer: the Sign-in-with-Apple session if present, else the
    /// anonymous iCloud-Keychain token. Uploads land in this user's own
    /// `users/<id>/` space — never the shared master namespace.
    private var token: String { AuthStore.shared.bearer }

    var hasValidToken: Bool { !token.isEmpty }

    // Serialise drains: the foreground refresh, the reachability monitor and the
    // post-record refresh can all call drainPending — without this they raced,
    // and a slow/failing head-of-queue take could let later small takes jump it
    // while never resolving itself. `drainAgain` runs one more pass if a new
    // trigger arrived mid-drain.
    private var isDraining = false
    private var drainAgain = false

    // Reachability — retry the queue when the network comes back after an outage.
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true

    // Keeps a just-started upload alive briefly after the app leaves the
    // foreground, so short voice memos still finish instead of being cancelled.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        refreshPending()
        startNetworkMonitor()
    }

    // MARK: - Reachability

    /// Re-drain when connectivity transitions from down → up (not on every tick).
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBackOnline = online && !self.isOnline
                self.isOnline = online
                if cameBackOnline, self.pendingCount > 0 { await self.drainPending() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vd.uploader.netmon"))
    }

    // MARK: - Queue

    func pendingFiles() -> [URL] {
        let dir = AudioRecorder.documentsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { RecordingName.isRecordingFile($0.lastPathComponent) }
            .filter { Self.isUploadable($0) }   // skip 0-byte / moov-less junk so it can't block the queue
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A finalized AAC/MP4 take has a `moov` atom and real payload. A file read
    /// mid-recording (or a 0-byte stub) lacks it and is unplayable — never PUT it.
    static func isUploadable(_ url: URL) -> Bool {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
            size > 1024,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return false }
        return data.range(of: Data("moov".utf8)) != nil
    }

    /// name (VoiceDrop-*.m4a) → its pending tags, read from the local sidecars.
    /// Keeps an in-flight take visible on its tag page through 上传→待处理 (the
    /// entry outlives the sidecar file so 待处理 optimistic rows still match).
    private(set) var pendingTagsByName: [String: [String]] = [:]

    func refreshPending() {
        pending = pendingFiles(); pendingCount = pending.count
        for url in pending {
            if let data = try? Data(contentsOf: Self.tagsSidecarURL(for: url)),
               let tags = try? JSONDecoder().decode([String].self, from: data), !tags.isEmpty {
                pendingTagsByName[url.lastPathComponent] = tags
            }
        }
    }

    /// Drop optimistic 待处理 entries the server has now confirmed in its list.
    func dropConfirmed(_ names: Set<String>) {
        justUploaded.removeAll { names.contains($0) }
        // The server list now owns these rows (tags come from the R2 sidecar / doc).
        for n in names { pendingTagsByName[n] = nil }
    }

    /// Move an uploaded take out of the pending scan but keep it on disk
    /// (Documents/uploaded/) — used when "上传后删除本地" is off.
    static func keepLocal(_ url: URL) {
        let dir = documentsDir.appending(path: "uploaded")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    private static var documentsDir: URL { AudioRecorder.documentsDir }

    // MARK: - Background-task assertion

    private func beginBG() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "vd.upload") { [weak self] in
            self?.endBG()
        }
    }

    private func endBG() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Upload

    /// Uploads one file, retrying transient failures with backoff. Returns true
    /// and removes the local file on success; on persistent failure the file is
    /// left on disk (still 正在上传) for the next drain — it is never lost.
    @discardableResult
    // MARK: 标签侧车 —— tag 页发起的录音，挖出的文章缺省带该页标签

    /// Local sidecar next to a queued take: Documents/<stem>.tags.json = ["标签"].
    /// Queued and uploaded WITH the take (as articles/<stem>.tags, BEFORE the
    /// audio — the audio's arrival is what triggers mining), so the miner folds
    /// the tag into the article doc at 成文 time.
    static func tagsSidecarURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("tags.json")
    }

    static func writeTagsSidecar(for audio: URL, tags: [String]) {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        try? data.write(to: tagsSidecarURL(for: audio))
    }

    /// Best-effort: push the local tags sidecar (if any) to R2 and remove it on
    /// success. A failure keeps the local file — the next drain retries it.
    private func uploadTagsSidecar(for audio: URL) async {
        let local = Self.tagsSidecarURL(for: audio)
        guard let data = try? Data(contentsOf: local) else { return }
        let stem = audio.deletingPathExtension().lastPathComponent
        let endpoint = baseURL
            .appending(path: "upload")
            .appending(path: "articles")
            .appending(path: "\(stem).tags")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 30
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (200..<300).contains(resp.httpStatusCode) {
            try? FileManager.default.removeItem(at: local)
        }
    }

    func upload(_ url: URL) async -> Bool {
        guard hasValidToken else {
            lastError = String(localized: "请先用 Apple 登录")
            return false
        }
        guard Self.isUploadable(url) else {
            lastError = String(localized: "录音文件损坏，已跳过上传")
            return false
        }
        // Tag sidecar rides in front of the audio (mining triggers on the audio).
        await uploadTagsSidecar(for: url)
        let endpoint = baseURL
            .appending(path: "upload")
            .appending(path: url.lastPathComponent)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        beginBG()
        defer { endBG() }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: url)
                let code = resp.httpStatusCode
                if (200..<300).contains(code) {
                    // Drop from the queue. If the user wants a local copy kept,
                    // move it into an `uploaded/` subdir (outside the VoiceDrop-*
                    // scan) instead.
                    if Prefs.shared.deleteLocalAfterUpload {
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        Self.keepLocal(url)
                    }
                    // The audio is up — this take won't be drained again, so a
                    // still-lingering tags sidecar has no retry left. Drop it.
                    try? FileManager.default.removeItem(at: Self.tagsSidecarURL(for: url))
                    // Keep showing this take — now as 待处理 — until the server
                    // list lists it, so the row changes badge in place instead of
                    // vanishing then re-appearing half a second later.
                    if !justUploaded.contains(url.lastPathComponent) {
                        justUploaded.append(url.lastPathComponent)
                    }
                    lastError = nil
                    refreshPending()
                    Analytics.capture("录音上传完成", ["尝试次数": attempt])
                    return true
                }
                // Auth / other 4xx is the server rejecting THIS request — a retry
                // won't change the outcome, so stop immediately.
                if code == 401 || code == 403 {
                    lastError = String(localized: "token 失效（HTTP \(code)）")
                    Analytics.capture("录音上传失败", ["原因": "token失效"])
                    return false
                }
                if (400..<500).contains(code) {
                    lastError = String(localized: "上传失败 HTTP \(code)")
                    Analytics.capture("录音上传失败", ["原因": "HTTP\(code)"])
                    return false
                }
                // 5xx, or 0 (no HTTP response) — transient; fall through to retry.
                lastError = String(localized: "上传失败 HTTP \(code)")
            } catch {
                // Network blip / timeout / task cancelled on app suspension.
                lastError = error.localizedDescription
            }
            if attempt < maxAttempts {
                // 1.5s, then 3s.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        Analytics.capture("录音上传失败", ["原因": "重试耗尽"])
        return false
    }

    /// Uploads every pending file. A failure no longer aborts the queue — we skip
    /// the stuck take and keep going, so one bad file can't wedge the rest; the
    /// skipped file stays on disk and is retried on the next drain. Serialised so
    /// concurrent triggers can't race.
    @discardableResult
    func drainPending() async -> Bool {
        if isDraining { drainAgain = true; return pendingCount == 0 }
        isDraining = true
        defer { isDraining = false }

        repeat {
            drainAgain = false
            for file in pendingFiles() {
                _ = await upload(file)
            }
            refreshPending()
        } while drainAgain && pendingCount > 0

        return pendingCount == 0
    }
}

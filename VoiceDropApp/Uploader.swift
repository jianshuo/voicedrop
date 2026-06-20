import Foundation
import Observation

/// Uploads recordings to jianshuo.dev/files via the R2-backed PUT API.
/// The Documents directory IS the pending queue: a `VoiceDrop-*.m4a` file that
/// still exists has not been uploaded. On success the file is deleted.
@MainActor
@Observable
final class Uploader {

    private(set) var pendingCount: Int = 0
    private(set) var lastError: String?

    /// Base URL is public (not a secret), so it's hardcoded.
    private let baseURL = URL(string: "https://jianshuo.dev/files/api")!

    /// Per-user bearer: the Sign-in-with-Apple session if present, else the
    /// anonymous iCloud-Keychain token. Uploads land in this user's own
    /// `users/<id>/` space — never the shared master namespace.
    private var token: String { AuthStore.shared.bearer }

    var hasValidToken: Bool { !token.isEmpty }

    init() { refreshPending() }

    // MARK: - Queue

    func pendingFiles() -> [URL] {
        let dir = AudioRecorder.documentsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("VoiceDrop-") && $0.pathExtension == "m4a" }
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

    func refreshPending() { pendingCount = pendingFiles().count }

    // MARK: - Upload

    /// Uploads one file. Returns true and deletes the file on success.
    @discardableResult
    func upload(_ url: URL) async -> Bool {
        guard hasValidToken else {
            lastError = "请先用 Apple 登录"
            return false
        }
        guard Self.isUploadable(url) else {
            lastError = "录音文件损坏，已跳过上传"
            return false
        }
        let endpoint = baseURL
            .appending(path: "upload")
            .appending(path: url.lastPathComponent)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")

        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: url)
            guard let http = resp as? HTTPURLResponse else {
                lastError = "无响应"
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = http.statusCode == 401 || http.statusCode == 403
                    ? "token 失效（HTTP \(http.statusCode)）"
                    : "上传失败 HTTP \(http.statusCode)"
                return false
            }
            try? FileManager.default.removeItem(at: url)
            lastError = nil
            refreshPending()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Uploads every pending file in order. Returns true if the queue is empty
    /// afterwards (everything uploaded).
    @discardableResult
    func drainPending() async -> Bool {
        for file in pendingFiles() {
            if await upload(file) == false { break }
        }
        refreshPending()
        return pendingCount == 0
    }
}

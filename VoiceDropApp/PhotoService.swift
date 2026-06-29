import Foundation

/// THE single place for scene-photo HTTP I/O. Download and upload were each
/// copy-pasted in two stores (LibraryStore / CommunityStore / RecordSession),
/// already drifting in URL encoding. Centralize so the endpoint, auth, and
/// encoding live once.
enum PhotoService {
    /// Download a photo by its FULL R2 key via the public `/photo/<key>` endpoint
    /// (no auth — the one photo URL the app, community, and web pages all use).
    static func data(fullKey: String) async -> Data? {
        guard !fullKey.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/photo/\(fullKey.urlPathEncoded)")
        else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            return resp.isOK ? data : nil
        } catch { return nil }
    }

    /// PUT JPEG bytes to a relative key (within the bearer's own scope). Returns the
    /// relative key on success, nil otherwise.
    @discardableResult
    static func upload(data: Data, relKey: String, bearer: String) async -> String? {
        guard !bearer.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/upload/\(relKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? relKey : nil
        } catch { return nil }
    }
}

import Foundation
import UIKit

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
        let body = Self.squareJPEG(data) ?? data
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? relKey : nil
        } catch { return nil }
    }

    /// Center-crop image data to a 1:1 square, re-encoded as JPEG. Returns nil on failure
    /// (caller falls back to the original bytes). Photos are square everywhere in the app
    /// (article tiles are 1:1) and AI edits follow the input aspect ratio, so squaring at
    /// upload keeps both the stored photo and its edited version 1:1.
    static func squareJPEG(_ data: Data, quality: CGFloat = 0.9) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        if side <= 0 { return nil }
        let x = (img.size.width - side) / 2
        let y = (img.size.height - side) / 2
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = img.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let out = renderer.image { _ in
            // draw the upright image shifted so the centered square lands at (0,0)
            img.draw(in: CGRect(x: -x, y: -y, width: img.size.width, height: img.size.height))
        }
        return out.jpegData(compressionQuality: quality)
    }
}

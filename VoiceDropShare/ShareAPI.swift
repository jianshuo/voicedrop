import Foundation

// Upload / API client for the Share Extension's 接受分享 flow. Every request
// reuses the SAME symbols the extension already ships with (`Networking.swift`
// is compiled into this target too, see project.yml): `AppGroup.sharedBearer`,
// `AppGroup.uploadBase`, `API.filesBase`, `API.agentBase`, `URLRequest.setBearer`,
// `URLResponse.isOK`. No duplicate helpers here.

/// One item of the user's 写作风格 training corpus, as returned by
/// `GET <filesBase>/style/dataset`.
struct DatasetItem: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let source: String
    let collectedAt: String
    let chars: Int
}

enum ShareAPI {
    private static func authed(_ url: URL, _ method: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setBearer(AppGroup.sharedBearer)
        return r
    }

    /// PUT a file straight from disk to `…/files/api/upload/<name>`. `name` may
    /// contain `/` (e.g. `photos/<ts>/<i>-<rand>.jpg`) — `appendingPathComponent`
    /// preserves each `/`-separated segment as a real path segment (verified: it
    /// does NOT percent-encode the slash), so a multi-segment key lands correctly.
    static func putFile(_ file: URL, name: String, contentType: String) async -> Bool {
        var r = authed(AppGroup.uploadBase.appendingPathComponent(name), "PUT")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        guard let (_, resp) = try? await URLSession.shared.upload(for: r, fromFile: file) else { return false }
        return resp.isOK
    }

    /// PUT in-memory data to `…/files/api/upload/<name>`. Same multi-segment
    /// `name` handling as `putFile`.
    static func putData(_ data: Data, name: String, contentType: String) async -> Bool {
        var r = authed(AppGroup.uploadBase.appendingPathComponent(name), "PUT")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        guard let (_, resp) = try? await URLSession.shared.upload(for: r, from: data) else { return false }
        return resp.isOK
    }

    /// Add one item to the user's 写作风格 training corpus.
    static func collectStyle(type: String, title: String, text: String, source: String) async -> Bool {
        var r = authed(API.filesBase.appendingPathComponent("style/collect"), "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["type": type, "title": title, "text": text, "source": source])
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return resp.isOK
    }

    /// The user's collected 写作风格 corpus items (for a review/manage sheet).
    static func fetchDataset() async -> [DatasetItem] {
        guard let (d, resp) = try? await URLSession.shared.data(for: authed(API.filesBase.appendingPathComponent("style/dataset"), "GET")),
              resp.isOK else { return [] }
        struct R: Decodable { let items: [DatasetItem] }
        return (try? JSONDecoder().decode(R.self, from: d))?.items ?? []
    }

    /// Kick the agent worker to extract/update the user's 文风 from the
    /// collected corpus. `clearAfter` empties the dataset once extraction succeeds.
    static func extractStyle(clearAfter: Bool) async -> Bool {
        var r = authed(API.agentBase.appendingPathComponent("style/extract"), "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["clearAfter": clearAfter])
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return resp.isOK
    }

    /// Clear the collected 写作风格 corpus without extracting.
    static func deleteDataset() async -> Bool {
        guard let (_, resp) = try? await URLSession.shared.data(for: authed(API.filesBase.appendingPathComponent("style/dataset"), "DELETE")) else { return false }
        return resp.isOK
    }

    /// Fire-and-forget: ask the Miner DO to process any pending audio now.
    static func triggerMine() async {
        _ = try? await URLSession.shared.data(for: authed(API.agentBase.appendingPathComponent("mine/trigger"), "POST"))
    }

    /// The user's current 写作风格 text (`GET /style`, same route
    /// `VoiceDropApp/SettingsView.swift`'s `SettingsStore.load()` reads — this
    /// mirrors it, not shared since that store pulls in app-only dependencies).
    /// Returns nil on failure or when no style has been saved yet, so callers can
    /// fall back to a neutral label instead of a stale/fake one.
    static func fetchStyleText() async -> String? {
        guard let (d, resp) = try? await URLSession.shared.data(for: authed(API.filesBase.appendingPathComponent("style"), "GET")),
              resp.isOK else { return nil }
        struct R: Decodable { let style: String? }
        guard let style = (try? JSONDecoder().decode(R.self, from: d))?.style, !style.isEmpty else { return nil }
        return style
    }
}

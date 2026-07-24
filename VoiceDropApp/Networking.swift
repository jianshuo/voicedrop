import Foundation

// Small networking helpers shared by every API caller (Library, Community,
// Settings, Uploader, AgentSession, …). Single source of truth: the bearer-auth
// header, the HTTP success check, and URL-path percent-encoding each lived as
// copy-pasted boilerplate in 30 / 24 / 8 spots. Change here once.

extension URLRequest {
    /// Set the `Authorization: Bearer <token>` header.
    mutating func setBearer(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

extension URLResponse {
    /// HTTP status code, or 0 if this isn't an HTTP response. Named `httpStatusCode`
    /// (not `statusCode`) to avoid colliding with HTTPURLResponse.statusCode.
    var httpStatusCode: Int { (self as? HTTPURLResponse)?.statusCode ?? 0 }
    /// True for a 2xx HTTP response.
    var isOK: Bool { (200..<300).contains(httpStatusCode) }
}

extension String {
    /// Percent-encode for use as a URL path segment, falling back to self.
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

/// THE single source of truth for every backend host/URL. Was hardcoded as
/// `URL(string: "https://jianshuo.dev/…")!` in ~14 spots across the app (and the
/// Share Extension) — point the app at a staging host by editing only `host` here.
/// Compiled into BOTH targets (this file is in VoiceDropShare too).
enum API {
    /// 国内入口（腾讯 EdgeOne，备案域名 voicedrop.cn）：所有 HTTP API 从这里进
    /// （2026-07-24 切换）。EO 境内边缘接入 + EO 跨境回源通道，比国内用户直连
    /// CF anycast 稳得多。/files/* 由 EO 边缘函数透传；/agent/*、/reco/* 由 EO
    /// 规则引擎改写源站到 jianshuo.dev 的 zone 级 worker 路由
    /// （见 jianshuo.dev repo: infra/voicedrop-cn-edgeone/README.md）。
    static let host = "voicedrop.cn"
    /// CF 直连主机，只剩两类用途——
    /// 1) WebSocket（/agent/edit、/status、/asr、/realtime）：EO 边缘函数的 WS
    ///    透传未验证，不赌；
    /// 2) /cdn-cgi/image/ 缩略图边缘缩放（PhotoService）：CF 专有，EO 无等价物。
    static let cfHost = "jianshuo.dev"
    /// 照片原图专用主机：走 voicedrop.cn（腾讯 EdgeOne 国内边缘缓存），国内用户
    /// 读原图命中境内节点、不跨洋回源 WNAM。照片是公开、写后不变、可长缓存的
    /// （源站对 200 发 max-age=1y immutable，EdgeOne cache-rules 对 /files/api/photo/*
    /// FollowOrigin 缓存），所以切到 CDN 安全且是数量级提速。
    /// 缩略图走 CF 的 /cdn-cgi/image/ 边缘缩放，EdgeOne 无等价物，留在 cfHost。
    static let photoHost = "voicedrop.cn"
    static let filesBase = URL(string: "https://\(host)/files/api")!   // Files API (articles, files, photos, share, wechat, community)
    static let photoBase = URL(string: "https://\(photoHost)/files/api")!  // 照片原图（EdgeOne 国内缓存）
    static let agentBase = URL(string: "https://\(host)/agent")!       // Agent worker (mine trigger, usage, link REST)
    static let recoBase  = URL(string: "https://\(host)/reco")!        // Reco worker (ranking, engagement)
    static let agentWS   = "wss://\(cfHost)/agent"                      // WebSocket base: append /edit, /status, /asr (+ query)
    static let agentLink = URL(string: "https://\(host)/agent/link")!  // DeviceLink REST (start / verify / …)
    /// Public share / community page for a share id. 分享页走 voicedrop.cn
    ///（.cn 域名，微信内打开不弹提示）。
    static func sharePage(_ id: String) -> URL { URL(string: "https://voicedrop.cn/\(id)")! }
}

/// Cross-process bridge between the VoiceDrop app and its Share Extension. The
/// two run in separate sandboxes; the App Group is the only channel they share.
/// We mirror just the bearer token here (not the Keychain itself) so the
/// extension can upload as the same user without any Keychain migration risk.
/// Compiled into BOTH targets.
enum AppGroup {
    static let id = "group.com.wangjianshuo.VoiceDrop"

    /// Same R2-backed upload endpoint the in-app `Uploader` PUTs to (derived from API).
    static let uploadBase = API.filesBase.appendingPathComponent("upload")

    private static let bearerKey = "bearer"
    private static var store: UserDefaults? { UserDefaults(suiteName: id) }

    /// Called by the app whenever its anon token loads or changes.
    static func publishBearer(_ token: String) { store?.set(token, forKey: bearerKey) }

    /// Read by the extension at upload time. Empty until the app has run once.
    static var sharedBearer: String { store?.string(forKey: bearerKey) ?? "" }
}

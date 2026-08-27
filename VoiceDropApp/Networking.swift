import Foundation
import os

// Small networking helpers shared by every API caller (Library, Community,
// Settings, Uploader, AgentSession, …). Single source of truth: the bearer-auth
// header, the HTTP success check, and URL-path percent-encoding each lived as
// copy-pasted boilerplate in 30 / 24 / 8 spots. Change here once.

/// Marketing version + build number, read once from Info.plist. Sent with every
/// API request so the server can gate features by client build generically
/// (e.g. reco only mixes book cards into the feed for builds that can open them)
/// instead of growing per-feature capability flags.
enum ClientVersion {
    static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let build = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String ?? "0"
}

extension URLRequest {
    /// Set the `Authorization: Bearer <token>` header, plus the client version
    /// headers (`X-VD-Version` / `X-VD-Build`) every API caller sends.
    mutating func setBearer(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        setValue(ClientVersion.short, forHTTPHeaderField: "X-VD-Version")
        setValue(ClientVersion.build, forHTTPHeaderField: "X-VD-Build")
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
    /// 国内入口（腾讯 EdgeOne，备案域名 voicedrop.cn）：国内用户的 HTTP API 从这里进
    /// （2026-07-24 切换）。EO 境内边缘接入 + EO 跨境回源通道，比国内用户直连
    /// CF anycast 稳得多。/files/* 由 EO 边缘函数透传；/agent/*、/reco/* 由 EO
    /// 规则引擎改写源站到 jianshuo.dev 的 zone 级 worker 路由
    /// （见 jianshuo.dev repo: infra/voicedrop-cn-edgeone/README.md）。
    static let cnHost = "voicedrop.cn"
    /// CF 直连主机——非中国区用户的 HTTP API 主机（海外走 EO 是绕道中国，
    /// 直连 CF 才是就近）。另两类用途不分线路恒走 CF：
    /// 1) WebSocket（/agent/edit、/status、/asr、/realtime）：EO 边缘函数的 WS
    ///    透传未验证，不赌；
    /// 2) /cdn-cgi/image/ 缩略图边缘缩放（PhotoService）：CF 专有，EO 无等价物。
    static let cfHost = "jianshuo.dev"
    /// 当前 HTTP API 主机：中国区 = voicedrop.cn（EO），其他区 = jianshuo.dev（CF）。
    /// 由 App Store 商店区域决定（APIRoute，启动时取 Storefront，见下）。
    static var host: String { APIRoute.currentHost }
    /// 照片原图与 API 同线路：国内命中 EO 境内边缘缓存（源站对 200 发
    /// max-age=1y immutable，EO cache-rules 对 /files/api/photo/* FollowOrigin），
    /// 海外直接命中 CF 边缘缓存。缩略图走 CF 的 /cdn-cgi/image/（恒 cfHost）。
    static var photoHost: String { APIRoute.currentHost }
    static var filesBase: URL { URL(string: "https://\(host)/files/api")! }   // Files API (articles, files, photos, share, wechat, community)
    static var photoBase: URL { URL(string: "https://\(photoHost)/files/api")! }  // 照片原图（就近边缘缓存）
    static var agentBase: URL { URL(string: "https://\(host)/agent")! }       // Agent worker (mine trigger, usage, link REST)
    static var recoBase:  URL { URL(string: "https://\(host)/reco")! }        // Reco worker (ranking, engagement)
    static let agentWS   = "wss://\(cfHost)/agent"                      // WebSocket base: append /edit, /status, /asr (+ query)
    static var agentLink: URL { URL(string: "https://\(host)/agent/link")! }  // DeviceLink REST (start / verify / …)
    /// 公开网页前缀，随线路走：voicedrop.cn/<path> ≡ jianshuo.dev/voicedrop/<path>
    /// （EO 边缘函数的去前缀映射，见 infra/voicedrop-cn-edgeone/README.md）。
    /// 用于 App 自己消费的公开页（书架 JSON / 书页 WKWebView / 隐私政策等）。
    static var publicWebBase: String {
        host == cnHost ? "https://\(cnHost)" : "https://\(cfHost)/voicedrop"
    }
    /// Public share / community page for a share id. 分享页是发给别人的，**恒走
    /// voicedrop.cn**（.cn 域名微信内打开不弹提示，接收者大概率在国内）——
    /// 不随 APIRoute 切换。邀请链接、微信 universal link 同理，各自写死 .cn。
    static func sharePage(_ id: String) -> URL { URL(string: "https://voicedrop.cn/\(id)")! }
    /// 写书/修书服务（Tokyo VPS 上的 Agent 服务，lab.jianshuo.dev）。单一主机、无
    /// 国内镜像，不参与线路切换——但常量必须收口在这（曾散在 BookWritingSheet /
    /// BookReviseSheet 三处硬编码），换域名/迁服务只改这一行。
    static let bookAPIBase = URL(string: "https://lab.jianshuo.dev/api/book")!
}

/// 线路选择（2026-08-25 起只按 App Store 商店区域，竞速探测已整体移除）：
/// 中国区（CHN，或拿不到 storefront——模拟器/设备未登录商店账号）→ voicedrop.cn
///（腾讯 EO 境内边缘）；其他区 → 直连 jianshuo.dev（CF）。TestFlight 和 Xcode
/// 直装读到的都是设备当前登录的 App Store 账号的区域。判定简单、可预期、
/// 不随网络波动横跳；storefront 持久化在 App Group，Share Extension 直接沿用。
enum APIRoute {
    static let storefrontKey = "api.route.storefront"
    private static var store: UserDefaults? { UserDefaults(suiteName: AppGroup.id) }
    /// 进程内缓存：URL 构建是高频路径（列表滚动逐张照片），别每次开 UserDefaults。
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var currentHost: String {
        cache.withLock { h in
            if let h { return h }
            let sf = store?.string(forKey: storefrontKey)
            let v = (sf == nil || sf == "CHN") ? API.cnHost : API.cfHost
            h = v
            return v
        }
    }

    /// App 启动时记录商店区域（StoreKit Storefront.countryCode，如 CHN/USA）。
    static func noteStorefront(_ code: String) {
        store?.set(code, forKey: storefrontKey)
        cache.withLock { $0 = nil }   // 换商店账号后下次取值即生效
    }
}

// MARK: - Authed request helpers

/// 全 App ~74 处「URLRequest + setBearer + JSONDecoder + isOK」四到六行样板的收口
///（VoiceDropShare/ShareAPI.swift 的 authed() 早就这么做了，主 App 补齐）。
/// 增量迁移：新调用一律走这里，存量逐个搬。Compiled into BOTH targets.
extension API {
    /// Build a bearer-authed request. `json` non-nil → JSON body + Content-Type.
    static func authed(_ url: URL, method: String = "GET", bearer: String,
                       json: [String: Any]? = nil, timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setBearer(bearer)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        if let timeout { req.timeoutInterval = timeout }
        return req
    }

    /// GET + decode；网络失败 / 非 2xx / 解码失败一律 nil（调用方只关心有没有）。
    static func get<T: Decodable>(_ url: URL, bearer: String, timeout: TimeInterval? = nil) async -> T? {
        let req = authed(url, bearer: bearer, timeout: timeout)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Fire a mutation, report 2xx success only.
    @discardableResult
    static func send(_ url: URL, method: String = "POST", bearer: String,
                     json: [String: Any]? = nil) async -> Bool {
        let req = authed(url, method: method, bearer: bearer, json: json)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return resp.isOK
    }
}

/// Cross-process bridge between the VoiceDrop app and its Share Extension. The
/// two run in separate sandboxes; the App Group is the only channel they share.
/// We mirror just the bearer token here (not the Keychain itself) so the
/// extension can upload as the same user without any Keychain migration risk.
/// Compiled into BOTH targets.
enum AppGroup {
    static let id = "group.com.wangjianshuo.VoiceDrop"

    /// Same R2-backed upload endpoint the in-app `Uploader` PUTs to (derived from
    /// API; computed —— 随 APIRoute 线路切换，别用 let 把首次访问的 host 冻住).
    static var uploadBase: URL { API.filesBase.appendingPathComponent("upload") }

    private static let bearerKey = "bearer"
    private static var store: UserDefaults? { UserDefaults(suiteName: id) }

    /// Called by the app whenever its anon token loads or changes.
    static func publishBearer(_ token: String) { store?.set(token, forKey: bearerKey) }

    /// Read by the extension at upload time. Empty until the app has run once.
    static var sharedBearer: String { store?.string(forKey: bearerKey) ?? "" }
}

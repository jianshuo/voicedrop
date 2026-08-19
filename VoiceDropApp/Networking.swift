import Foundation
import os

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
    /// 国内入口（腾讯 EdgeOne，备案域名 voicedrop.cn）：国内用户的 HTTP API 从这里进
    /// （2026-07-24 切换）。EO 境内边缘接入 + EO 跨境回源通道，比国内用户直连
    /// CF anycast 稳得多。/files/* 由 EO 边缘函数透传；/agent/*、/reco/* 由 EO
    /// 规则引擎改写源站到 jianshuo.dev 的 zone 级 worker 路由
    /// （见 jianshuo.dev repo: infra/voicedrop-cn-edgeone/README.md）。
    static let cnHost = "voicedrop.cn"
    /// CF 直连主机——海外用户的 HTTP API 主机（2026-08-19 起自动切换，见 APIRoute；
    /// 海外走 EO 是绕道中国，直连 CF 才是就近）。另两类用途不分线路恒走 CF：
    /// 1) WebSocket（/agent/edit、/status、/asr、/realtime）：EO 边缘函数的 WS
    ///    透传未验证，不赌；
    /// 2) /cdn-cgi/image/ 缩略图边缘缩放（PhotoService）：CF 专有，EO 无等价物。
    static let cfHost = "jianshuo.dev"
    /// 当前 HTTP API 主机：国内 = voicedrop.cn（EO），海外 = jianshuo.dev（CF）。
    /// 由 APIRoute 竞速探测决定，App 启动/回前台时更新（见下）。
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
}

/// 国内/海外线路自动切换（2026-08-19）。国内用户走 voicedrop.cn（腾讯 EO 境内
/// 边缘），海外用户直连 jianshuo.dev（Cloudflare），不再绕道中国。
///
/// 判定 = 竞速探测：并发 HEAD 两个入口的落地页，谁快用谁；挑战方须快 150ms
/// 以上才换线（迟滞防抖，避免边界网络反复横跳）；单边失败直接用活的那边，
/// 双边失败维持现状。结果持久化在 App Group UserDefaults——Share Extension
/// 不探测，直接沿用主 App 的判定；未探测过的冷启动默认 voicedrop.cn（老行为）。
///
/// 探测时机（主 App，见 VoiceDropApp.swift）：每次冷启动 + 回前台（≥30 分钟
/// 一次节流）。切换只影响之后新建的请求；已入队的 background URLSession 任务
/// 按入队时的 URL 跑完，无碍。
enum APIRoute {
    static let hostKey = "api.route.host"
    static let probedAtKey = "api.route.probedAt"
    /// 挑战方须比现任快出这么多才换线（秒）。
    static let hysteresis: TimeInterval = 0.15

    private static var store: UserDefaults? { UserDefaults(suiteName: AppGroup.id) }
    /// 进程内缓存：URL 构建是高频路径（列表滚动逐张照片），别每次开 UserDefaults。
    private static let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var currentHost: String {
        cache.withLock { h in
            if let h { return h }
            let v = store?.string(forKey: hostKey) == API.cfHost ? API.cfHost : API.cnHost
            h = v
            return v
        }
    }

    struct ProbeResult {
        let host: String        // 判定后的当前主机
        let switched: Bool      // 本次探测是否换了线
        let cnMs: Int?          // voicedrop.cn 时延（nil = 失败/超时）
        let cfMs: Int?          // jianshuo.dev 时延
    }

    /// 竞速探测并落盘判定。主 App 专用（Extension 生命周期太短，不探测）。
    @discardableResult
    static func probe() async -> ProbeResult {
        async let cnT = measure(URL(string: "https://\(API.cnHost)/")!)
        async let cfT = measure(URL(string: "https://\(API.cfHost)/voicedrop/")!)
        let (cn, cf) = await (cnT, cfT)
        let incumbent = currentHost
        let winner = pick(incumbent: incumbent, cn: cn, cf: cf)
        store?.set(winner, forKey: hostKey)
        store?.set(Date().timeIntervalSince1970, forKey: probedAtKey)
        cache.withLock { $0 = winner }
        return ProbeResult(host: winner, switched: winner != incumbent,
                           cnMs: cn.map { Int($0 * 1000) }, cfMs: cf.map { Int($0 * 1000) })
    }

    /// 距上次探测超过 maxAge 才真探（回前台的节流入口）；没到点返回 nil。
    @discardableResult
    static func probeIfDue(maxAge: TimeInterval = 1800) async -> ProbeResult? {
        let last = store?.double(forKey: probedAtKey) ?? 0
        guard Date().timeIntervalSince1970 - last > maxAge else { return nil }
        return await probe()
    }

    /// 纯判定函数（单测覆盖 APIRouteTests）：nil = 该线路探测失败。
    static func pick(incumbent: String, cn: TimeInterval?, cf: TimeInterval?) -> String {
        switch (cn, cf) {
        case (nil, nil): return incumbent          // 全挂：别乱动，等下次
        case (.some, nil): return API.cnHost       // 只有一边活：用活的
        case (nil, .some): return API.cfHost
        case let (.some(c), .some(f)):
            let (incT, chT) = incumbent == API.cnHost ? (c, f) : (f, c)
            guard chT + hysteresis < incT else { return incumbent }
            return incumbent == API.cnHost ? API.cfHost : API.cnHost
        }
    }

    /// HEAD 一次落地页，量到首个响应的耗时；非 2xx/超时/断网 → nil。
    /// ephemeral + 禁缓存：量的是真实网络，不是 URLCache。
    private static func measure(_ url: URL) async -> TimeInterval? {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let start = Date()
        guard let (_, resp) = try? await session.data(for: req), resp.isOK else { return nil }
        return Date().timeIntervalSince(start)
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

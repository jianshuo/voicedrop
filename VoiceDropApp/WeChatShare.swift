import UIKit
import WechatOpenSDK

// MARK: - 微信 OpenSDK 封装
//
// 开放平台移动应用「VoiceDrop」（已过审）：AppID wx1573f936967f5420，
// Universal Link https://voicedrop.cn/（AASA 的 /* 规则天然覆盖微信回调路径）。
// 启动时 register()；onOpenURL / onContinueUserActivity 先经 handle() 问一遍
// SDK——是微信回调就地消化，返回 false 才轮到 AppRouter 当普通深链处理。
// 分享走 shareWebpage()：好友/朋友圈弹微信原生确认页，链接卡片带封面缩略图。
final class WeChatShare: NSObject, WXApiDelegate, @unchecked Sendable {   // 无状态，仅回调转埋点
    static let shared = WeChatShare()
    static let appID = "wx1573f936967f5420"
    static let universalLink = "https://voicedrop.cn/"

    static func register() {
        WXApi.registerApp(appID, universalLink: universalLink)
    }

    static var isInstalled: Bool { WXApi.isWXAppInstalled() }

    /// wx…:// scheme 回跳（旧通道兜底）。true = 微信的，调用方不用再管。
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased().hasPrefix("wx") == true else { return false }
        return WXApi.handleOpen(url, delegate: shared)
    }

    /// Universal link 回跳（主通道）。true = 微信的，调用方不用再管。
    @discardableResult
    static func handle(_ activity: NSUserActivity) -> Bool {
        WXApi.handleOpenUniversalLink(activity, delegate: shared)
    }

    /// 分享网页卡片：好友出可点链接卡片，朋友圈出链接动态。缩略图按微信
    /// 32KB 上限自动缩到 300px + 降质压缩。
    static func shareWebpage(url: URL, title: String, description: String, thumb: UIImage?, timeline: Bool) {
        let webpage = WXWebpageObject()
        webpage.webpageUrl = url.absoluteString
        let msg = WXMediaMessage()
        msg.title = title
        msg.description = description
        msg.mediaObject = webpage
        if let thumb, let data = thumbData(thumb) { msg.thumbData = data }
        let req = SendMessageToWXReq()
        req.bText = false
        req.message = msg
        req.scene = Int32(timeline ? WXSceneTimeline.rawValue : WXSceneSession.rawValue)
        WXApi.send(req)
    }

    // MARK: - 小程序卡片（仅好友场景；朋友圈不支持小程序卡，调用方继续走网页卡）
    //
    // 小程序「VoiceDrop」（houleixx/voicedrop-mini，AppID wxedfbd113b545b4f6）。
    // 原始 ID 与安卓 BuildConfig.VOICEDROP_MINI_PROGRAM_ORIGINAL_ID 同值；
    // 三类页面 path 规则与安卓 WechatShareContent / 小程序自身 sharePayload 一字不差。
    // 低版本微信收到卡片自动回落 webpageUrl，网页兜底永远带着。
    static let miniProgramUserName = "gh_451de6440ef4"

    /// 分享链接末段的公开 shareId（voicedrop.cn/<token>）；不合规则返回 nil，
    /// 调用方退回网页卡。与安卓 WechatShareContent.publicShareId 同规则。
    static func publicShareId(_ url: URL) -> String? {
        let id = url.lastPathComponent
        return id.range(of: "^[A-Za-z0-9_-]{6,16}$", options: .regularExpression) != nil ? id : nil
    }

    static func sharedArticlePath(shareId: String, section: Int) -> String {
        "pages/shared-article/index?shareId=\(qEnc(shareId))&section=\(max(0, section))&fromShare=1"
    }

    static func communityPath(shareId: String, section: Int) -> String {
        "pages/community-detail/index?shareId=\(qEnc(shareId))&section=\(max(0, section))&fromShare=1"
    }

    /// 小程序 book-reader 页 sharePayload 的同款 path；chapterURL 传当前章节网页
    /// 地址（对应 &page=，小程序阅读器会直接翻到那一页）。
    static func bookReaderPath(slug: String, title: String, main: String, author: String,
                               cover: Bool, coverAt: Int64, chapterURL: URL? = nil) -> String {
        var p = "/pages/book-reader/index?slug=\(qEnc(slug))&title=\(qEnc(title))&main=\(qEnc(main))"
            + "&author=\(qEnc(author))&cover=\(cover ? "1" : "0")&coverAt=\(coverAt)"
        if let chapterURL { p += "&page=\(qEnc(chapterURL.absoluteString))" }
        return p
    }

    /// 好友场景发小程序卡片：大图卡（hdImageData ≤128KB），微信里点开直接进小程序。
    static func shareMiniProgram(webpageUrl: URL, path: String, title: String,
                                 description: String, thumb: UIImage?) {
        let mini = WXMiniProgramObject()
        mini.webpageUrl = webpageUrl.absoluteString
        mini.userName = miniProgramUserName
        mini.path = path
        mini.miniProgramType = .release
        if let thumb, let hd = hdThumbData(thumb) { mini.hdImageData = hd }
        let msg = WXMediaMessage()
        msg.title = title
        msg.description = description
        msg.mediaObject = mini
        if let thumb, let data = thumbData(thumb) { msg.thumbData = data }
        let req = SendMessageToWXReq()
        req.bText = false
        req.message = msg
        req.scene = Int32(WXSceneSession.rawValue)
        WXApi.send(req)
    }

    private static func qEnc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .init(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    /// 小程序卡大图 ≤ 128KB（比链接卡 32KB 宽松）：长边 500px，再逐级降质。
    private static func hdThumbData(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 500
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in stride(from: 0.9, through: 0.3, by: -0.15) {
            if let data = resized.jpegData(compressionQuality: quality), data.count < 128_000 {
                return data
            }
        }
        return resized.jpegData(compressionQuality: 0.2)
    }

    /// 文章卡片的描述行：正文开头自然截 44 字——真实内容当钩子，好过任何口号；
    /// 微信好友卡片描述约显示一行半，44 字刚好占满又不被拦腰截断。
    static func excerpt(_ body: String?, fallback: String) -> String {
        guard let body else { return fallback }
        let plain = ArticleBody.stripMarkers(body)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !plain.isEmpty else { return fallback }
        return plain.count <= 44 ? plain : String(plain.prefix(44)) + "……"
    }

    /// 缩略图 ≤ 32KB：先等比缩到长边 300px，再从 0.8 逐级降 JPEG 质量。
    private static func thumbData(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 300
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in stride(from: 0.8, through: 0.2, by: -0.2) {
            if let data = resized.jpegData(compressionQuality: quality), data.count < 32_000 {
                return data
            }
        }
        return resized.jpegData(compressionQuality: 0.1)
    }

    // MARK: WXApiDelegate — 分享结果只埋点，不打断用户（微信侧已有完整 UI 反馈）

    func onResp(_ resp: BaseResp) {
        guard resp is SendMessageToWXResp else { return }
        Analytics.capture("微信分享回执", ["errCode": Int(resp.errCode)])
    }

    func onReq(_ req: BaseReq) {}
}

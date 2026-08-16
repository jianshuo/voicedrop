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

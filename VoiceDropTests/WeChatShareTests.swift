import XCTest
import UIKit
@testable import VoiceDrop

// 微信 OpenSDK 冒烟测试：完整走一遍分享代码路径（注册 → 组 WXMediaMessage +
// 缩略图 → WXApi.send）。静态库若缺 -ObjC 之类链接参数，category 方法会在
// 运行时报 unrecognized selector 直接崩——这个测试就是抓这种崩的。
final class WeChatShareTests: XCTestCase {

    @MainActor
    func testShareWebpagePathDoesNotCrash() {
        WeChatShare.register()
        _ = WeChatShare.isInstalled
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        WeChatShare.shareWebpage(url: URL(string: "https://voicedrop.cn/books/test/")!,
                                 title: "《测试书》— 王建硕",
                                 description: "VoiceDrop 图书馆 · 点开即读",
                                 thumb: thumb, timeline: false)
        WeChatShare.shareWebpage(url: URL(string: "https://voicedrop.cn/books/test/")!,
                                 title: "《测试书》— 王建硕",
                                 description: "VoiceDrop 图书馆 · 点开即读",
                                 thumb: nil, timeline: true)
    }
}

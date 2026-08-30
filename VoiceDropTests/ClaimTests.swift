import XCTest
@testable import VoiceDrop

// 一生一次领 320 算力（写一本书）：两处纯逻辑——
//   1) 落地页 voicedrop.cn/book/ 与 voicedrop://claim 的路由解析
//   2) 服务端 /agent/usage/claim 的响应 → 界面该显示什么（ClaimOutcome）
// 设计 spec：docs/superpowers/specs/2026-08-30-book320-claim-design.md
@MainActor
final class ClaimTests: XCTestCase {

    // MARK: - 路由

    // 落地页的按钮走纯 HTTP：voicedrop.cn 上的页面指向 jianshuo.dev/voicedrop/book
    // （跨域才触发 universal link——iOS 不给同域链接拉 App），反之亦然。
    func testCrossDomainHttpLinkOpensClaim() {
        let r = AppRouter()
        r.handle(URL(string: "https://jianshuo.dev/voicedrop/book")!)
        XCTAssertEqual(r.pending, .claim)

        let r2 = AppRouter()
        r2.handle(URL(string: "https://voicedrop.cn/book")!)
        XCTAssertEqual(r2.pending, .claim)
    }

    // 领取不再有自定义 scheme：HTTP 已经够了，别留第二条入口。
    func testNoCustomSchemeForClaim() {
        let r = AppRouter()
        r.handle(URL(string: "voicedrop://claim")!)
        XCTAssertEqual(r.pending, .recordings)
    }

    func testUniversalLinkBookPageRoutesToClaim() {
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/book")!), .claim)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/book/")!), .claim)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://www.voicedrop.cn/book/")!), .claim)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://jianshuo.dev/voicedrop/book/")!), .claim)
    }

    // 书架是 /books（复数），领取页是 /book（单数）——一字之差不能串。
    func testBooksShelfRouteUnaffected() {
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/books")!), .books)
        let single = URL(string: "https://voicedrop.cn/books/my-first-book/")!
        XCTAssertEqual(AppRouter.universalLink(single), .web(single))
    }

    func testDeeperBookPathFallsBackToWeb() {
        let deep = URL(string: "https://voicedrop.cn/book/faq")!
        XCTAssertEqual(AppRouter.universalLink(deep), .web(deep))
    }

    // MARK: - 响应 → 界面状态

    func testGrantedCarriesNewBalance() {
        let out = ClaimOutcome.from(status: 200, json: ["ok": true, "granted_suanli": 320, "suanli": 520])
        XCTAssertEqual(out, .granted(newBalance: 520))
    }

    func testAlreadyClaimedIsNotAnError() {
        let out = ClaimOutcome.from(status: 200, json: ["ok": true, "already": true, "granted_suanli": 0, "suanli": 200])
        XCTAssertEqual(out, .already(balance: 200))
    }

    func testNeedsSigninMapsToTheRightProvider() {
        XCTAssertEqual(ClaimOutcome.from(status: 403, json: ["error": "needs_apple_signin"]),
                       .needsSignin(wechat: false))
        XCTAssertEqual(ClaimOutcome.from(status: 403, json: ["error": "needs_wechat_signin"]),
                       .needsSignin(wechat: true))
    }

    func testServerTroubleIsFailedNotSilentSuccess() {
        XCTAssertEqual(ClaimOutcome.from(status: 503, json: ["error": "degraded"]), .failed)
        XCTAssertEqual(ClaimOutcome.from(status: 401, json: nil), .failed)
        XCTAssertEqual(ClaimOutcome.from(status: 200, json: nil), .failed)
    }
}

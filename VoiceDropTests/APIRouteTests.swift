import XCTest
@testable import VoiceDrop

// 国内/海外线路自动切换（APIRoute）的纯判定函数 pick：
// 竞速谁快用谁 + 150ms 迟滞防抖 + 单边失败用活边 + 双边失败守现状。
final class APIRouteTests: XCTestCase {

    private let cn = API.cnHost   // voicedrop.cn
    private let cf = API.cfHost   // jianshuo.dev

    // MARK: - 失败分支

    func testBothFailedKeepsIncumbent() {
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: nil, cf: nil), cn)
        XCTAssertEqual(APIRoute.pick(incumbent: cf, cn: nil, cf: nil), cf)
    }

    func testSingleSurvivorWinsRegardlessOfIncumbent() {
        // 只有 cn 活 → cn，即使现任是 cf
        XCTAssertEqual(APIRoute.pick(incumbent: cf, cn: 2.0, cf: nil), cn)
        // 只有 cf 活 → cf，即使现任是 cn
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: nil, cf: 2.0), cf)
    }

    // MARK: - 双活竞速 + 迟滞

    func testClearWinnerSwitches() {
        // 海外：cf 明显快 → 从 cn 切到 cf
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: 1.2, cf: 0.3), cf)
        // 回国：cn 明显快 → 从 cf 切回 cn
        XCTAssertEqual(APIRoute.pick(incumbent: cf, cn: 0.3, cf: 1.2), cn)
    }

    func testHysteresisPreventsFlapping() {
        // 挑战方只快 100ms（< 150ms 迟滞）→ 不换
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: 0.50, cf: 0.40), cn)
        XCTAssertEqual(APIRoute.pick(incumbent: cf, cn: 0.40, cf: 0.50), cf)
        // 现任更快 → 更不换
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: 0.30, cf: 0.90), cn)
        // 恰好差 150ms（不严格小于）→ 不换；过了才换
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: 0.55, cf: 0.40), cn)
        XCTAssertEqual(APIRoute.pick(incumbent: cn, cn: 0.56, cf: 0.40), cf)
    }

    // MARK: - 派生 URL 跟随主机

    func testPublicWebBaseMapsPathPrefix() {
        // 两个主机的公开页前缀映射（EO 去前缀规则）：
        // voicedrop.cn/<path> ≡ jianshuo.dev/voicedrop/<path>
        if API.host == cn {
            XCTAssertEqual(API.publicWebBase, "https://voicedrop.cn")
        } else {
            XCTAssertEqual(API.publicWebBase, "https://jianshuo.dev/voicedrop")
        }
        // API 类路径两边同形，只换主机
        XCTAssertEqual(API.filesBase.absoluteString, "https://\(API.host)/files/api")
        XCTAssertEqual(API.agentBase.absoluteString, "https://\(API.host)/agent")
    }

    func testShareLinksStayOnCn() {
        // 分享链接是发给别人的，恒走 .cn，不随线路切换
        XCTAssertEqual(API.sharePage("Ab3xK9_p2Q").absoluteString, "https://voicedrop.cn/Ab3xK9_p2Q")
    }
}

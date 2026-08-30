import XCTest
@testable import VoiceDrop

// 写书页「算力不够」这一刻推不推升档、推哪一档。纯逻辑不打网络。
//
// 两种人看得到升档：①订着主档、当月额度烧光（再买同一档 StoreKit 只回「你已
// 订阅」，唯一能再花钱的路就是升档）；②还没订、且缺口大过主档每月发放量
// （写一本书 320，主档才 200 —— 订了也照样写不成）。
// 三个否决项：售卖开关关着、已在顶档、那档商品苹果拉不到（ASC 没建/没过审）。
final class BookUpsellTierTests: XCTestCase {

    private let main = StoreService.tiers[0]          // 200/月
    private let pro  = StoreService.tiers[1]          // 2000/月
    private let sellAll: (String) -> Bool = { _ in true }

    private func decide(enabled: Bool = true, active: Bool, activeProductID: String? = nil,
                        subSuanli: Double = 0, shortOf: Int? = 132,
                        sellable: ((String) -> Bool)? = nil) -> StoreService.Tier? {
        BookWritingSheet.upsellTier(enabled: enabled, active: active,
                                    activeProductID: activeProductID, subSuanli: subSuanli,
                                    shortOf: shortOf, sellable: sellable ?? sellAll)
    }

    // MARK: 档位表本身（与服务端 usage.js SUB_PRODUCTS 对齐）

    func testTierTableMatchesServer() {
        XCTAssertEqual(main.suanli, 200)
        XCTAssertEqual(pro.suanli, 2000)
        XCTAssertTrue(main.id.hasSuffix("monthly_19_9"))
        XCTAssertTrue(pro.id.hasSuffix("monthly_199_99"))
        XCTAssertEqual(StoreService.proID, pro.id)
    }

    // MARK: 订着的人

    func testSubscribedAndDryGetsUpgrade() {
        // 正是这次报的现场：订着主档、本月 200 烧光、余额不够写书
        XCTAssertEqual(decide(active: true, activeProductID: main.id, subSuanli: 0)?.id, pro.id)
    }

    func testSubscribedWithQuotaLeftIsNotUpsold() {
        // 当月还有额度 → 不骚扰（他只是这本书差一点，加油/邀请就够）
        XCTAssertNil(decide(active: true, activeProductID: main.id, subSuanli: 50))
    }

    func testTopTierSubscriberHasNothingToSell() {
        // 已经在顶档还烧光 → 无货可卖，界面该给管理订阅而不是假装能买
        XCTAssertNil(decide(active: true, activeProductID: pro.id, subSuanli: 0))
    }

    // MARK: 没订的人

    func testUnsubscribedBigGapJumpsToTopTier() {
        // 缺口 320 > 主档 200：订主档也写不成，直说高档
        XCTAssertEqual(decide(active: false, shortOf: 320)?.id, pro.id)
    }

    func testUnsubscribedSmallGapKeepsMainTierOnly() {
        // 缺口 132 < 主档 200：主档就够，不越级推贵的
        XCTAssertNil(decide(active: false, shortOf: 132))
    }

    func testNoGapNoUpsell() {
        XCTAssertNil(decide(active: false, shortOf: nil))
    }

    // MARK: 否决项

    func testSalesSwitchOffSellsNothing() {
        XCTAssertNil(decide(enabled: false, active: true, activeProductID: main.id, subSuanli: 0))
        XCTAssertNil(decide(enabled: false, active: false, shortOf: 320))
    }

    func testUnavailableProductIsNotOffered() {
        // ASC 还没建/没过审 → 商品拉不到，绝不摆一个点了必败的按钮
        XCTAssertNil(decide(active: true, activeProductID: main.id, subSuanli: 0,
                            sellable: { _ in false }))
    }
}

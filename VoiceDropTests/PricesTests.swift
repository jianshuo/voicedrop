import XCTest
@testable import VoiceDrop

// 价目表的日缓存：什么时候该去拉、远端数据怎么收、脏数据怎么挡。纯逻辑不打网络。
//
// 立场：展示价晚一天无所谓（扣费真源在服务端，402 会带权威的 need_suanli），
// 但绝不能因为拿不到价钱就显示 0 或崩掉——所以每一条失败路径都得退回旧值/兜底。
final class PricesTests: XCTestCase {

    private let day = Prices.ttl

    // MARK: 兜底

    func testFallbackMatchesServerPrice() {
        // 和服务端 usage.js 的 BOOK_SUANLI 对齐；改价时这里跟着改一次。
        XCTAssertEqual(Prices.fallback.book, 160)
        XCTAssertEqual(Prices.fallback.bookRevise, 40)
    }

    // MARK: 什么时候拉

    func testNoCacheIsAlwaysStale() {
        XCTAssertTrue(Prices.isStale(nil, now: 0))
        XCTAssertTrue(Prices.isStale(nil, now: 1_000_000))
    }

    func testFreshWithinOneDayThenStale() {
        let table = Prices.Table(book: 160, bookRevise: 40, fetchedAt: 1000)
        XCTAssertFalse(Prices.isStale(table, now: 1000))            // 刚拉完
        XCTAssertFalse(Prices.isStale(table, now: 1000 + day))      // 正好一天，还不算过期
        XCTAssertTrue(Prices.isStale(table, now: 1000 + day + 1))   // 过了一天
    }

    // MARK: 远端数据怎么收

    func testMergeTakesRemotePrice() {
        let merged = Prices.merge(remote: .init(book: 123, book_revise: 45),
                                  previous: Prices.fallback, now: 777)
        XCTAssertEqual(merged?.book, 123)
        XCTAssertEqual(merged?.bookRevise, 45)
        XCTAssertEqual(merged?.fetchedAt, 777)
    }

    func testMergeKeepsPreviousReviseWhenRemoteOmitsIt() {
        let previous = Prices.Table(book: 160, bookRevise: 99, fetchedAt: 0)
        let merged = Prices.merge(remote: .init(book: 200, book_revise: nil), previous: previous, now: 1)
        XCTAssertEqual(merged?.book, 200)
        XCTAssertEqual(merged?.bookRevise, 99)
    }

    func testMergeRejectsGarbage() {
        // nil / 缺 book / 0 / 负数 → 一律不收，调用方沿用旧值
        XCTAssertNil(Prices.merge(remote: nil, previous: Prices.fallback, now: 1))
        XCTAssertNil(Prices.merge(remote: .init(book: nil, book_revise: 40), previous: Prices.fallback, now: 1))
        XCTAssertNil(Prices.merge(remote: .init(book: 0, book_revise: 40), previous: Prices.fallback, now: 1))
        XCTAssertNil(Prices.merge(remote: .init(book: -5, book_revise: 40), previous: Prices.fallback, now: 1))
    }

    // MARK: 存取

    func testSaveThenLoadRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PricesTests.\(UUID().uuidString)"))
        XCTAssertNil(Prices.load(defaults))
        let table = Prices.Table(book: 321, bookRevise: 21, fetchedAt: 5)
        Prices.save(table, to: defaults)
        XCTAssertEqual(Prices.load(defaults), table)
    }

    func testLoadRejectsStoredZeroPrice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PricesTests.\(UUID().uuidString)"))
        Prices.save(Prices.Table(book: 0, bookRevise: 40, fetchedAt: 5), to: defaults)
        XCTAssertNil(Prices.load(defaults), "存进去的脏价钱当没有，读的人拿兜底")
    }
}

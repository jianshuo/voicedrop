import XCTest
@testable import VoiceDrop

// 书架筛选（ShelfFilter）与搜索（ShelfSearch）的纯逻辑：
// 筛选 = 全部 / 我的 / 类目；搜索先看书名/主副题/作者/类目，再落到章节索引。
final class ShelfSearchTests: XCTestCase {

    private func book(_ slug: String, title: String, sub: String = "", author: String? = nil,
                      mine: Bool? = nil, category: String? = nil) -> ShelfBook {
        ShelfBook(slug: slug, title: title, main: title, sub: sub, c: "#000", c2: "#000",
                  cover: false, coverAt: nil, chapters: 3, author: author, hidden: nil, mine: mine,
                  category: category)
    }

    private func entry(_ slug: String, sub: String = "", intro: String = "",
                       toc: [(String, String)] = []) -> BooksShelfStore.SearchEntry {
        .init(slug: slug, sub: sub, intro: intro,
              toc: toc.map { BooksShelfStore.SearchEntry.Chapter(t: $0.0, b: $0.1) })
    }

    // MARK: 筛选

    func testFilterAllMineCategory() {
        let a = book("a", title: "熵", mine: true, category: "科学")
        let b = book("b", title: "钱", category: "投资")
        let c = book("c", title: "无类目")
        XCTAssertEqual([a, b, c].filter { ShelfFilter.all.matches($0) }.map(\.slug), ["a", "b", "c"])
        XCTAssertEqual([a, b, c].filter { ShelfFilter.mine.matches($0) }.map(\.slug), ["a"])
        XCTAssertEqual([a, b, c].filter { ShelfFilter.category("投资").matches($0) }.map(\.slug), ["b"])
    }

    func testPresentCategoriesFollowFixedOrderAndSkipEmpty() {
        let books = [book("a", title: "x", category: "故事"), book("b", title: "y", category: "科学"),
                     book("c", title: "z", category: ""), book("d", title: "w", category: "科学")]
        XCTAssertEqual(ShelfFilter.present(in: books), ["科学", "故事"])
        XCTAssertEqual(ShelfFilter.present(in: []), [])
    }

    // MARK: 搜索

    func testEmptyQueryHitsEverything() {
        XCTAssertEqual(ShelfSearch.hit(book("a", title: "熵"), query: "  ", index: nil), "")
    }

    func testDirectFieldsHitWithoutIndex() {
        let b = book("a", title: "熵：为什么一切都在变乱", sub: "一个工程师摸得到的无序", author: "金子", category: "科学")
        XCTAssertEqual(ShelfSearch.hit(b, query: "变乱", index: nil), "")
        XCTAssertEqual(ShelfSearch.hit(b, query: "无序", index: nil), "")
        XCTAssertEqual(ShelfSearch.hit(b, query: "金子", index: nil), "")
        XCTAssertEqual(ShelfSearch.hit(b, query: "科学", index: nil), "")
        XCTAssertNil(ShelfSearch.hit(b, query: "咖啡", index: nil))
    }

    func testChapterHitReturnsChapterTitle() {
        let b = book("a", title: "熵")
        let e = entry("a", sub: "副题", intro: "先想想一副新牌",
                      toc: [("第一章 · 一副新牌", "用洗牌讲无序"), ("第三章 · 麦克斯韦的小妖", "信息就是能量")])
        XCTAssertEqual(ShelfSearch.hit(b, query: "小妖", index: e), "第三章 · 麦克斯韦的小妖")
        XCTAssertEqual(ShelfSearch.hit(b, query: "洗牌", index: e), "第一章 · 一副新牌")   // brief 命中也报章题
        XCTAssertEqual(ShelfSearch.hit(b, query: "新牌", index: e), "")                    // 导读命中 = 直接命中
        XCTAssertNil(ShelfSearch.hit(b, query: "咖啡", index: e))
    }

    func testCaseInsensitiveASCII() {
        let b = book("a", title: "About SwiftUI")
        XCTAssertEqual(ShelfSearch.hit(b, query: "swiftui", index: nil), "")
    }
}

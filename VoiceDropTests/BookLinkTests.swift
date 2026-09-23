import XCTest
@testable import VoiceDrop

// 书链接 → 内置阅读器：voicedrop.cn/books/<slug>/ 与 jianshuo.dev/voicedrop/books/<slug>/
// 都要路由成 .book，而不是 .web（站内 Safari）。2026-09-22 之前单本书故意走 .web，
// 用户点开书链接看到的是浏览器而不是 BookReaderView。
@MainActor
final class BookLinkTests: XCTestCase {

    func testBookRootRoutesToReader() {
        let cn = URL(string: "https://voicedrop.cn/books/dudu-koala-quarrel/")!
        XCTAssertEqual(AppRouter.universalLink(cn), .book(slug: "dudu-koala-quarrel", url: cn))
        let cf = URL(string: "https://jianshuo.dev/voicedrop/books/dudu-koala-quarrel/")!
        XCTAssertEqual(AppRouter.universalLink(cf), .book(slug: "dudu-koala-quarrel", url: cf))
        let www = URL(string: "https://www.voicedrop.cn/books/dudu-koala-quarrel")!   // 无尾斜杠同样认
        XCTAssertEqual(AppRouter.universalLink(www), .book(slug: "dudu-koala-quarrel", url: www))
    }

    func testBookChapterKeepsChapterURL() {
        // 章节页也归到这本书，阅读器从该章节页开始（url 原样带过去）。
        let ch = URL(string: "https://voicedrop.cn/books/dudu-koala-quarrel/chapter-03.html")!
        XCTAssertEqual(AppRouter.universalLink(ch), .book(slug: "dudu-koala-quarrel", url: ch))
    }

    func testBookAssetPathsStayWeb() {
        // 封面图 / PDF / print 视图不是「读书」，别拿阅读器壳子去套一张图。
        for path in ["/books/dudu-koala-quarrel/cover.jpg", "/books/dudu-koala-quarrel/print",
                     "/books/dudu-koala-quarrel/book.pdf", "/books/audiobook/dudu-koala-quarrel/01"] {
            let u = URL(string: "https://voicedrop.cn" + path)!
            XCTAssertEqual(AppRouter.universalLink(u), .web(u), path)
        }
    }

    func testCommunityAndManualRouteNatively() {
        // 网站的社区宣传页 / 使用手册页，App 里都有原生对应物。
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/community/")!), .community)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://jianshuo.dev/voicedrop/community")!), .community)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/help/manual/")!), .manual)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://jianshuo.dev/voicedrop/help/manual/")!), .manual)
        // 帮助中心首页没有原生页，照旧站内 Safari。
        let help = URL(string: "https://voicedrop.cn/help/")!
        XCTAssertEqual(AppRouter.universalLink(help), .web(help))
    }

    func testShelfRootStillNativeTab() {
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/books/")!), .books)
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://jianshuo.dev/voicedrop/books")!), .books)
    }

    func testBookSlugMalformedFallsBackToWeb() {
        // slug 只认 [A-Za-z0-9_-]：带点/编码的怪路径不冒充书，站内 Safari 兜底。
        let odd = URL(string: "https://voicedrop.cn/books/..%2Fetc/")!
        XCTAssertEqual(AppRouter.universalLink(odd), .web(odd))
    }

    func testUnknownHostStillIgnored() {
        XCTAssertNil(AppRouter.universalLink(URL(string: "https://example.com/books/dudu-koala-quarrel/")!))
    }
}

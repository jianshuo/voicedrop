import XCTest
@testable import VoiceDrop

// 社区搜索的纯过滤逻辑（CommunitySearch.filter）——标题/作者/预览三字段
// 不分大小写包含匹配；空查询原样返回。
final class CommunitySearchTests: XCTestCase {

    private func post(id: String, author: String? = nil, title: String? = nil,
                      preview: String? = nil) -> CommunityPost {
        CommunityPost(shareId: id, author: author, title: title,
                      firstSharedAt: nil, updatedAt: nil, count: nil,
                      mine: nil, replyTo: nil, preview: preview)
    }

    func testEmptyQueryReturnsAll() {
        let posts = [post(id: "a", title: "早晨的雾"), post(id: "b", title: "上海咖啡馆")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: ""), posts)
        XCTAssertEqual(CommunitySearch.filter(posts, query: "   "), posts)
    }

    func testMatchesTitle() {
        let posts = [post(id: "a", title: "早晨的雾"), post(id: "b", title: "上海咖啡馆")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "咖啡").map(\.shareId), ["b"])
    }

    func testMatchesAuthor() {
        let posts = [post(id: "a", author: "王建硕", title: "雾"),
                     post(id: "b", author: "匿名", title: "咖啡")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "建硕").map(\.shareId), ["a"])
    }

    func testMatchesPreview() {
        let posts = [post(id: "a", title: "无题", preview: "今天走到外滩看日出"),
                     post(id: "b", title: "无题2", preview: "在家写代码")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "外滩").map(\.shareId), ["a"])
    }

    func testCaseInsensitiveASCII() {
        let posts = [post(id: "a", title: "About SwiftUI"), post(id: "b", title: "关于安卓")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "swiftui").map(\.shareId), ["a"])
    }

    func testNilFieldsNeverMatchNorCrash() {
        let posts = [post(id: "a"), post(id: "b", title: "有标题")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "标题").map(\.shareId), ["b"])
    }

    func testQueryIsTrimmed() {
        let posts = [post(id: "a", title: "早晨的雾")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: " 雾 ").map(\.shareId), ["a"])
    }

    func testNoMatchReturnsEmpty() {
        let posts = [post(id: "a", title: "早晨的雾")]
        XCTAssertTrue(CommunitySearch.filter(posts, query: "不存在的词").isEmpty)
    }

    func testPreservesOrder() {
        let posts = [post(id: "1", title: "雾一"), post(id: "2", title: "雾二"),
                     post(id: "3", title: "别的"), post(id: "4", title: "雾四")]
        XCTAssertEqual(CommunitySearch.filter(posts, query: "雾").map(\.shareId), ["1", "2", "4"])
    }
}

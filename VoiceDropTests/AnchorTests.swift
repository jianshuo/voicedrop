import XCTest
@testable import VoiceDrop

// 锚点协议 T3：EditAnchor 的 wireDict 编码形状 + EditRequest 持久化（带/不带 anchor）round-trip。
// wireDict 键名必须与服务端严格一致：image → type/key；line → type/line/text。
final class AnchorTests: XCTestCase {

    // MARK: - wireDict 形状

    func testImageAnchorWireDictShape() {
        let a = EditAnchor.image(key: "photos/2026-07-13-120000/5-x9q.jpg")
        let d = a.wireDict
        XCTAssertEqual(d["type"] as? String, "image")
        XCTAssertEqual(d["key"] as? String, "photos/2026-07-13-120000/5-x9q.jpg")
        XCTAssertNil(d["line"])
        XCTAssertNil(d["text"])
    }

    func testLineAnchorWireDictShape() {
        let a = EditAnchor.line(7, text: "今天在咖啡馆看到一位老先生")
        let d = a.wireDict
        XCTAssertEqual(d["type"] as? String, "line")
        XCTAssertEqual(d["line"] as? Int, 7)
        XCTAssertEqual(d["text"] as? String, "今天在咖啡馆看到一位老先生")
        XCTAssertNil(d["key"])
    }

    // MARK: - EditAnchor 编解码 round-trip（persist 落盘用的纯逻辑）

    func testImageAnchorCodableRoundTrip() throws {
        let a = EditAnchor.image(key: "photos/x/1-a.jpg")
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(EditAnchor.self, from: data)
        XCTAssertEqual(decoded, a)
    }

    func testLineAnchorCodableRoundTrip() throws {
        let a = EditAnchor.line(3, text: "整行原文")
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(EditAnchor.self, from: data)
        XCTAssertEqual(decoded, a)
    }

    // MARK: - PersistedEdit round-trip（磁盘队列），带 anchor / 不带 anchor

    func testPersistedEditRoundTripsWithImageAnchor() throws {
        let p = PersistedEdit(id: "id-1", text: "把这张照片重画成水彩", articleIndex: 1,
                               anchor: .image(key: "photos/x/1-a.jpg"))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersistedEdit.self, from: data)
        XCTAssertEqual(decoded, p)
        XCTAssertEqual(decoded.anchor, .image(key: "photos/x/1-a.jpg"))
    }

    func testPersistedEditRoundTripsWithLineAnchor() throws {
        let p = PersistedEdit(id: "id-2", text: "把这段改短一点", articleIndex: 0,
                               anchor: .line(7, text: "今天在咖啡馆看到一位老先生"))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersistedEdit.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    func testPersistedEditRoundTripsWithoutAnchor() throws {
        let p = PersistedEdit(id: "id-3", text: "随便改改", articleIndex: 0, anchor: nil)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PersistedEdit.self, from: data)
        XCTAssertEqual(decoded, p)
        XCTAssertNil(decoded.anchor)
    }

    /// 老磁盘队列（升级前落盘，JSON 里压根没有 anchor 键）恢复不炸，anchor 解出 nil。
    func testPersistedEditDecodesOldDiskFormatMissingAnchorKey() throws {
        let oldJSON = """
        {"id":"old-1","text":"老版本存的编辑","articleIndex":2}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedEdit.self, from: oldJSON)
        XCTAssertEqual(decoded.id, "old-1")
        XCTAssertEqual(decoded.text, "老版本存的编辑")
        XCTAssertEqual(decoded.articleIndex, 2)
        XCTAssertNil(decoded.anchor)
    }

    // MARK: - EditRequest.anchor 默认 nil（init 不传 = 现状行为）

    @MainActor
    func testEditRequestAnchorDefaultsToNil() {
        let req = ArticleAgentSession.EditRequest(text: "hello")
        XCTAssertNil(req.anchor)
    }

    @MainActor
    func testEditRequestCarriesAnchor() {
        let req = ArticleAgentSession.EditRequest(text: "hello", anchor: .image(key: "k"))
        XCTAssertEqual(req.anchor, .image(key: "k"))
    }
}

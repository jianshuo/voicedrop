import XCTest
@testable import VoiceDrop

/// 文章专属封面 `photos/<sessionTs>/cover.jpg` 的 key 约定（RecordingName.coverKey
/// 是单一真源；Recording.coverJpgKey 从 stem 解析 sessionTs 后委托给它）。
final class RecordingCoverTests: XCTestCase {

    func testCoverKeyLayout() {
        XCTAssertEqual(RecordingName.coverKey(sessionTs: "2026-08-13-091500"),
                       "photos/2026-08-13-091500/cover.jpg")
    }

    func testRecordingCoverJpgKeyParsesSessionTs() {
        let rec = Recording(audioName: "VoiceDrop-2026-08-13-091500-3m20s-Wed-morning-Shanghai-Xuhui.m4a",
                            uploaded: "", hasArticles: true, isEmpty: false,
                            articleTitle: nil, tags: nil, coverPhotoKey: nil)
        XCTAssertEqual(rec.coverJpgKey, "photos/2026-08-13-091500/cover.jpg")
    }

    func testRecordingCoverJpgKeyNilForUnparseableStem() {
        let rec = Recording(audioName: "random-file.m4a",
                            uploaded: "", hasArticles: true, isEmpty: false,
                            articleTitle: nil, tags: nil, coverPhotoKey: nil)
        XCTAssertNil(rec.coverJpgKey)
    }

    /// cover.jpg 与场景照片同一目录——同一 sessionTs 下互不冲突（照片名是
    /// `<offset>-<rand>.jpg`，永远不叫 cover.jpg）。
    func testCoverKeySharesPhotoDirectory() {
        let ts = "2026-08-13-091500"
        let photo = RecordingName.photoKey(sessionTs: ts, offset: 5)
        let cover = RecordingName.coverKey(sessionTs: ts)
        XCTAssertTrue(photo.hasPrefix("photos/\(ts)/"))
        XCTAssertTrue(cover.hasPrefix("photos/\(ts)/"))
        XCTAssertFalse(photo.hasSuffix("cover.jpg"))
    }
}

import XCTest
@testable import VoiceDrop

// PhotoUploadQueue 纯逻辑：pending 文件路径 → relKey 还原。
// pending 文件按 relKey 原样存子目录（…/pending-photos/photos/<ts>/<名>.jpg），
// relKey 取路径末三段——不做前缀字符串比较（/var 与 /private/var 符号链接会失配）。
final class PhotoUploadQueueTests: XCTestCase {

    func testRelKeyFromPendingFilePath() {
        let f = URL(fileURLWithPath: "/private/var/mobile/Documents/pending-photos/photos/2026-07-01-101010/3-a1b.jpg")
        XCTAssertEqual(PhotoUploadQueue.relKey(forPendingFile: f),
                       "photos/2026-07-01-101010/3-a1b.jpg")
    }

    func testRelKeySurvivesVarPrivateVarDifference() {
        let a = URL(fileURLWithPath: "/var/mobile/Documents/pending-photos/photos/2026-07-01-101010/9-c2d.jpg")
        let b = URL(fileURLWithPath: "/private/var/mobile/Documents/pending-photos/photos/2026-07-01-101010/9-c2d.jpg")
        XCTAssertEqual(PhotoUploadQueue.relKey(forPendingFile: a),
                       PhotoUploadQueue.relKey(forPendingFile: b))
    }

    func testRelKeyMatchesPhotoKeyLayout() {
        // RecordingName.photoKey 的产物存进 pending 目录后必须原样还原。
        let relKey = RecordingName.photoKey(sessionTs: "2026-07-01-101010", offset: 42)
        let file = URL(fileURLWithPath: "/x/pending-photos").appending(path: relKey)
        XCTAssertEqual(PhotoUploadQueue.relKey(forPendingFile: file), relKey)
    }
}

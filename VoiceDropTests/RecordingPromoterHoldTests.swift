import XCTest
@testable import VoiceDrop

/// enrichHolds 防双传契约（2026-08-28 根因）：promote 先落无地名文件名、再 await
/// 地理编码改富名；这个窗口里 drain 若领走旧名，后台会话照样传成功，富名文件又被
/// 当新录音再传一遍——同一 take 两个文档、两篇文章。所以：地理编码期间该文件必须
/// 处于 hold（pendingFiles 扫描跳过），promote 返回后必须已放行。
@MainActor
final class RecordingPromoterHoldTests: XCTestCase {

    func testTakeIsHeldDuringGeocodeAndReleasedAfter() async throws {
        let prevBackup = Prefs.shared.iCloudBackup
        Prefs.shared.iCloudBackup = false          // 不让测试真去碰 iCloud 归档
        defer { Prefs.shared.iCloudBackup = prevBackup }

        let start = Date()
        let staging = AudioRecorder.documentsDir.appending(path: "recording-hold-test.m4a")
        try Data(repeating: 0, count: 2048).write(to: staging)
        let take = AudioRecorder.Recording(url: staging, start: start, duration: 60)
        let bareName = RecordingName.make(start: start, duration: 60, place: nil)

        var heldDuringGeocode = false
        let finalURL = await RecordingPromoter.promote(take) {
            // 正处在地理编码窗口：无地名文件在盘上，但必须对 drain 不可见
            heldDuringGeocode = RecordingPromoter.isHeldForEnrichment(bareName)
            return "TestPlace"
        }
        defer { if let finalURL { try? FileManager.default.removeItem(at: finalURL) } }

        XCTAssertTrue(heldDuringGeocode, "地理编码期间必须 hold，否则 drain 会领走旧名造成双传")
        XCTAssertFalse(RecordingPromoter.isHeldForEnrichment(bareName), "promote 返回后必须放行")
        XCTAssertEqual(finalURL?.lastPathComponent,
                       RecordingName.make(start: start, duration: 60, place: "TestPlace"))
    }

    func testTooShortTakeNeverHolds() async throws {
        let start = Date()
        let staging = AudioRecorder.documentsDir.appending(path: "recording-short-test.m4a")
        try Data(repeating: 0, count: 128).write(to: staging)
        let take = AudioRecorder.Recording(url: staging, start: start, duration: 1)

        let finalURL = await RecordingPromoter.promote(take) { XCTFail("太短的录音不该走到地理编码"); return nil }

        XCTAssertNil(finalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "太短的 take 应被删除")
        XCTAssertFalse(RecordingPromoter.isHeldForEnrichment(RecordingName.make(start: start, duration: 1, place: nil)))
    }
}

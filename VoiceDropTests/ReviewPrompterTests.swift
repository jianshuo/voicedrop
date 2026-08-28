import XCTest
@testable import VoiceDrop

/// ReviewPrompter.shouldFire 的闸门契约：里程碑/留存闸、会话无错、60 天冷却、
/// 每版本一次。时机（10 秒停留、离开取消）是运行态行为，这里锁的是决策纯函数。
final class ReviewPrompterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fire(open: Int, milestone: Bool = true, err: Bool = false,
                      lastTs: Double = 0, ver: String = "1.14", lastVer: String = "") -> Bool {
        ReviewPrompter.shouldFire(openCount: open, requireMilestone: milestone, sessionError: err,
                                  now: now, lastTs: lastTs, version: ver, lastVersion: lastVer)
    }

    func testMilestonesOnly() {
        XCTAssertFalse(fire(open: 1))
        XCTAssertFalse(fire(open: 2))
        XCTAssertTrue(fire(open: 3))
        XCTAssertFalse(fire(open: 4))
        XCTAssertTrue(fire(open: 10))
        XCTAssertTrue(fire(open: 30))
        XCTAssertFalse(fire(open: 31))
    }

    func testPublishTriggerNeedsRetentionGateNotMilestone() {
        XCTAssertFalse(fire(open: 2, milestone: false))   // 留存闸：不足 3 篇不弹
        XCTAssertTrue(fire(open: 3, milestone: false))
        XCTAssertTrue(fire(open: 7, milestone: false))    // 事件型：不卡里程碑
    }

    func testSessionErrorBlocksEverything() {
        XCTAssertFalse(fire(open: 3, err: true))
        XCTAssertFalse(fire(open: 10, milestone: false, err: true))
    }

    func testCooldown60Days() {
        let recent = now.timeIntervalSince1970 - ReviewPrompter.cooldown + 3600   // 59 天多
        XCTAssertFalse(fire(open: 10, lastTs: recent))
        let old = now.timeIntervalSince1970 - ReviewPrompter.cooldown - 3600      // 60 天整之外
        XCTAssertTrue(fire(open: 10, lastTs: old))
    }

    func testOncePerVersion() {
        XCTAssertFalse(fire(open: 10, ver: "1.14", lastVer: "1.14"))
        XCTAssertTrue(fire(open: 10, ver: "1.15", lastVer: "1.14"))
    }
}

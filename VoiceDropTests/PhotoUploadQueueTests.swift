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

// drain 行为（经 uploadImpl 注入，不打网络）：并发上限 / 无退避 / 失败留盘 / 成功删盘。
@MainActor
final class PhotoUploadQueueDrainTests: XCTestCase {

    /// 线程安全的 stub 记录器（uploadImpl 在并发任务里跑，不能直接碰测试状态）。
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private(set) var peak = 0
        private(set) var attempts: [String] = []
        var failing: Set<String> = []
        func begin(_ relKey: String) {
            lock.lock(); inFlight += 1; peak = max(peak, inFlight); attempts.append(relKey); lock.unlock()
        }
        func end() { lock.lock(); inFlight -= 1; lock.unlock() }
        func shouldFail(_ relKey: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failing.contains(relKey) }
    }

    private var savedImpl: (@Sendable (Data, String, String) async -> String?)!

    override func setUp() {
        super.setUp()
        savedImpl = PhotoUploadQueue.uploadImpl
        // 清掉环境里可能残留的 pending 照片，别让别的用例互相污染。
        Self.wipePending()
    }

    override func tearDown() {
        PhotoUploadQueue.uploadImpl = savedImpl
        Self.wipePending()
        super.tearDown()
    }

    private static func wipePending() {
        let dir = AudioRecorder.documentsDir.appending(path: "pending-photos")
        try? FileManager.default.removeItem(at: dir)
    }

    private func seed(_ n: Int, ts: String = "2026-08-03-120000") -> [String] {
        var keys: [String] = []
        for i in 0..<n {
            let relKey = "photos/\(ts)/\(i)-t\(i).jpg"
            let dir = AudioRecorder.documentsDir.appending(path: "pending-photos")
            let file = dir.appending(path: relKey)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("JPEG".utf8).write(to: file)
            keys.append(relKey)
        }
        return keys
    }

    func testConcurrencyCappedAtMax() async {
        let probe = Probe()
        PhotoUploadQueue.uploadImpl = { _, relKey, _ in
            probe.begin(relKey)
            try? await Task.sleep(nanoseconds: 20_000_000)   // 20ms 撑开并发窗口
            probe.end()
            return "ok"
        }
        _ = seed(8)
        await PhotoUploadQueue.shared.drain()
        XCTAssertEqual(probe.attempts.count, 8)
        XCTAssertLessThanOrEqual(probe.peak, PhotoUploadQueue.maxConcurrent)
        XCTAssertGreaterThan(probe.peak, 1)                  // 真的并行了
        XCTAssertFalse(PhotoUploadQueue.shared.hasPending)   // 成功全删盘
    }

    func testFailureKeptOnDiskOthersUploaded() async {
        let probe = Probe()
        let keys = seed(3)
        probe.failing = [keys[1]]
        PhotoUploadQueue.uploadImpl = { _, relKey, _ in
            probe.begin(relKey); probe.end()
            return probe.shouldFail(relKey) ? nil : "ok"
        }
        await PhotoUploadQueue.shared.drain()
        let dir = AudioRecorder.documentsDir.appending(path: "pending-photos")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: keys[1]).path))   // 失败留盘
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: keys[0]).path))  // 成功删盘
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: keys[2]).path))
    }

    func testNoBackoffSleep() async {
        // 全部失败 × 8 张：每张只试一次、无退避 sleep → 整个 drain 必须秒级完成。
        // 旧实现（3 次尝试 + 1.5s/3s sleep）在这里要 >30s。
        let probe = Probe()
        let keys = seed(8)
        probe.failing = Set(keys)
        PhotoUploadQueue.uploadImpl = { _, relKey, _ in probe.begin(relKey); probe.end(); return nil }
        let t0 = Date()
        await PhotoUploadQueue.shared.drain()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertEqual(probe.attempts.count, 8)              // 每张恰好一次
        XCTAssertTrue(PhotoUploadQueue.shared.hasPending)    // 全部留盘等下次 drain
    }

    func testEmptyFileRemovedWithoutUpload() async {
        let probe = Probe()
        PhotoUploadQueue.uploadImpl = { _, relKey, _ in probe.begin(relKey); probe.end(); return "ok" }
        let dir = AudioRecorder.documentsDir.appending(path: "pending-photos")
        let empty = dir.appending(path: "photos/2026-08-03-120000/0-e0.jpg")
        try? FileManager.default.createDirectory(at: empty.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        await PhotoUploadQueue.shared.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))   // 空文件直接清
        XCTAssertTrue(probe.attempts.isEmpty)                                // 不为它打网络
    }
}

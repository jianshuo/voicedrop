import XCTest
@testable import VoiceDrop

// BackgroundTransfer.Job 纯逻辑：taskDescription 元数据的编解码 + 本地路径锚定。
// 进程隔世重启后的收尾（删本地文件/埋点）全靠这份 JSON 还原，所以 roundtrip
// 必须无损；localPath 必须存 Documents 相对路径（容器绝对路径每次安装都变）。
@MainActor
final class BackgroundTransferJobTests: XCTestCase {

    func testLocalPathAnchorsOnDocuments() {
        let f = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC/Documents/VoiceDrop-2026-08-03-215712-0m22s.m4a")
        XCTAssertEqual(BackgroundTransfer.Job.localPath(for: f),
                       "VoiceDrop-2026-08-03-215712-0m22s.m4a")
    }

    func testLocalPathSurvivesVarPrivateVarDifference() {
        let a = URL(fileURLWithPath: "/var/mobile/X/Documents/a.m4a")
        let b = URL(fileURLWithPath: "/private/var/mobile/X/Documents/a.m4a")
        XCTAssertEqual(BackgroundTransfer.Job.localPath(for: a),
                       BackgroundTransfer.Job.localPath(for: b))
    }

    func testLocalPathKeepsSubdirectories() {
        let f = URL(fileURLWithPath: "/var/m/Documents/pending-photos/photos/2026-08-03-215712/5-abc.jpg")
        XCTAssertEqual(BackgroundTransfer.Job.localPath(for: f),
                       "pending-photos/photos/2026-08-03-215712/5-abc.jpg")
    }

    func testLocalPathNilOutsideDocuments() {
        XCTAssertNil(BackgroundTransfer.Job.localPath(for: URL(fileURLWithPath: "/tmp/x.m4a")))
        // "Documents" 是最后一段（其下没有文件）也不算
        XCTAssertNil(BackgroundTransfer.Job.localPath(for: URL(fileURLWithPath: "/var/m/Documents")))
    }

    func testJobEncodeDecodeRoundtrip() {
        let job = BackgroundTransfer.Job(
            kind: .audio, localPath: "VoiceDrop-2026-08-03-215712-0m22s.m4a",
            remoteName: "VoiceDrop-2026-08-03-215712-0m22s.m4a", sizeKB: 110,
            queuedAt: 1_785_766_000.5, transferAt: 1_785_766_003.25, networkType: "蜂窝")
        let decoded = BackgroundTransfer.Job.decode(job.encoded())
        XCTAssertEqual(decoded?.kind, .audio)
        XCTAssertEqual(decoded?.localPath, job.localPath)
        XCTAssertEqual(decoded?.remoteName, job.remoteName)
        XCTAssertEqual(decoded?.sizeKB, 110)
        XCTAssertEqual(decoded?.queuedAt ?? 0, job.queuedAt, accuracy: 0.001)
        XCTAssertEqual(decoded?.transferAt ?? 0, job.transferAt, accuracy: 0.001)
        XCTAssertEqual(decoded?.networkType, "蜂窝")
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(BackgroundTransfer.Job.decode(nil))
        XCTAssertNil(BackgroundTransfer.Job.decode(""))
        XCTAssertNil(BackgroundTransfer.Job.decode("not json"))
    }

    func testTagsSidecarRemoteNameDerivation() {
        // 边车远端名 = articles/<音频 stem>.tags —— 与 miner 的消费点约定一致。
        let audio = URL(fileURLWithPath: "/var/m/Documents/VoiceDrop-2026-08-03-215712-0m22s.m4a")
        let sidecar = Uploader.tagsSidecarURL(for: audio)
        XCTAssertEqual(sidecar.lastPathComponent, "VoiceDrop-2026-08-03-215712-0m22s.tags.json")
        XCTAssertEqual(BackgroundTransfer.Job.localPath(for: sidecar),
                       "VoiceDrop-2026-08-03-215712-0m22s.tags.json")
    }
}

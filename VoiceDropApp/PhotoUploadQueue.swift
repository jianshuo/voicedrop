import Foundation
import UIKit

/// 录音期间拍的照片一张都不能丢：拍完先落盘（Documents/pending-photos/<relKey>），
/// 上传成功才删除——对齐音频 Uploader 的韧性（后台保活 + 退避重试 + 失败留盘等
/// 下次 drain）。此前 RecordSession 的照片上传是单次 fire-and-forget：拍完立刻锁屏
/// 任务被杀、或一次网络抖动，照片就永久没了。
///
/// 照片永远先于音频上传（Uploader.upload 开头先 drain 本队列）：音频的到达才触发
/// 挖矿，照片先到位，挖矿就一定看得见。晚到的照片还有服务端兜底（miner 写盘前
/// fresh 重列 session 照片补标记），双保险。
@MainActor
final class PhotoUploadQueue {
    static let shared = PhotoUploadQueue()

    private static var dir: URL {
        let d = AudioRecorder.documentsDir.appending(path: "pending-photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// pending 文件按 relKey 原样存子目录（pending-photos/photos/<ts>/<名>.jpg），
    /// 扫描时从路径末三段直接还原 relKey——不依赖前缀字符串比较（/var 与
    /// /private/var 符号链接会让前缀失配）。
    nonisolated static func relKey(forPendingFile file: URL) -> String {
        file.pathComponents.suffix(3).joined(separator: "/")
    }

    private static func pendingFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension.lowercased() == "jpg" { out.append(u) }
        // 文件名以录音内秒数开头 → 字典序 ≈ 拍摄顺序
        return out.sorted { $0.path < $1.path }
    }

    var hasPending: Bool { !Self.pendingFiles().isEmpty }

    /// 落盘 + 立即尝试上传。relKey = "photos/<sessionTs>/<offset>-<rand>.jpg"。
    /// 落盘一定发生在任何网络尝试之前——进程被杀也只是推迟，不是丢失。
    func enqueue(data: Data, relKey: String) {
        let file = Self.dir.appending(path: relKey)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        Task { await drain() }
    }

    // drain 全量串行化：并发触发（enqueue / 音频上传前 / 联网恢复）时后来者等同一个
    // 任务真正跑完再返回——音频上传前的 drain 必须是"照片确实都试过了"，不能是
    // "已有 drain 在跑，直接放行"（那会让音频抢在照片前面，挖矿就看不见图）。
    private var current: Task<Void, Never>?
    private var runAgain = false

    func drain() async {
        if let t = current { runAgain = true; await t.value; return }
        // current 的清空放在任务体内：与 runDrain 最后一次 runAgain 检查之间没有
        // await（MainActor 上原子），迟到的 drain 要么赶上本轮 repeat、要么开新任务，
        // 不存在"标了 runAgain 却没人跑"的窗口。
        let t = Task { await runDrain(); current = nil }
        current = t
        await t.value
    }

    private func runDrain() async {
        beginBG()
        defer { endBG() }
        repeat {
            runAgain = false
            for file in Self.pendingFiles() {
                guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                    try? FileManager.default.removeItem(at: file)   // 空/坏文件不许堵队列
                    continue
                }
                let relKey = Self.relKey(forPendingFile: file)
                var uploaded = false
                for attempt in 1...3 {
                    if await PhotoService.upload(data: data, relKey: relKey, bearer: AuthStore.shared.bearer) != nil {
                        uploaded = true
                        if attempt > 1 { Analytics.capture("照片重试上传成功", ["尝试次数": attempt]) }
                        break
                    }
                    if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
                }
                if uploaded {
                    try? FileManager.default.removeItem(at: file)
                } else {
                    Analytics.capture("照片上传失败留队", ["key": relKey])
                }
                // 失败留盘：下一次 drain（音频上传前 / 联网恢复 / 下次启动）重试。
            }
        } while runAgain
    }

    // MARK: - 后台保活（同 Uploader）：拍完照立刻锁屏/切走，上传也能收尾。

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBG() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "vd.photo-upload") { [weak self] in
            self?.endBG()
        }
    }

    private func endBG() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}

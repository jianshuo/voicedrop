import Foundation
import UIKit

/// 录音期间拍的照片一张都不能丢：拍完先落盘（Documents/pending-photos/<relKey>），
/// 上传成功才删除——对齐音频 Uploader 的韧性（后台保活 + 失败留盘等下次 drain）。
/// 此前 RecordSession 的照片上传是单次 fire-and-forget：拍完立刻锁屏
/// 任务被杀、或一次网络抖动，照片就永久没了。
///
/// 照片与音频并行上传（2026-08-03 起不再阻塞音频——弱网下串行照片队列曾把录音
/// 上传拖到中位 214s）。「一张不丢」由服务端双保险兜底：挖矿写盘前 fresh 重列
/// session 照片补标记；照片 PUT 落盘还会 poke Miner DO 的 backfillSessionPhotos，
/// 文章已成文后才到的照片也会被补进正文。尽早传仍有价值：赶在挖矿前到位的照片
/// 由模型做图文编排，晚到的只能程序化补在文末。
///
/// drain 内部并发 maxConcurrent 张、每张每次 drain 只试一次、无退避 sleep——
/// 失败留盘交给下一次 drain 触发点（启动 / 联网恢复 / enqueue / 音频上传前 /
/// 前台刷新）。
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

    // drain 串行化外壳：并发触发（enqueue / 音频上传前 / 联网恢复）合并进同一个
    // 任务——保护「同一文件不被两个 drain 并发 PUT」（文件内的照片彼此并行）。
    private var current: Task<Void, Never>?
    private var runAgain = false

    /// 同时在飞的照片 PUT 数上限。弱网下并发太高会挤压同时在传的音频，1 行可调。
    nonisolated static let maxConcurrent = 3

    /// 上传实现，可注入（单测替换掉真网络；默认 = PhotoService.upload）。
    nonisolated(unsafe) static var uploadImpl: @Sendable (Data, String, String) async -> String? =
        { data, relKey, bearer in await PhotoService.upload(data: data, relKey: relKey, bearer: bearer) }

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
            let bearer = AuthStore.shared.bearer
            let t0 = Date()
            var files = Self.pendingFiles()[...]
            let total = files.count
            var failed = 0
            // 滑动窗口并发：始终 ≤ maxConcurrent 张在飞。每张本次只试一次、无退避
            // sleep——弱网下 N 张 × 重试 × sleep 曾线性堵死排在后面的一切；失败留盘，
            // 重试交给下一次 drain 触发点。
            await withTaskGroup(of: (URL, Bool).self) { group in
                var inFlight = 0
                func pump() {
                    while inFlight < Self.maxConcurrent, let file = files.popFirst() {
                        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                            try? FileManager.default.removeItem(at: file)   // 空/坏文件不许堵队列
                            continue
                        }
                        let relKey = Self.relKey(forPendingFile: file)
                        inFlight += 1
                        group.addTask { (file, await Self.uploadImpl(data, relKey, bearer) != nil) }
                    }
                }
                pump()
                for await (file, ok) in group {
                    inFlight -= 1
                    if ok {
                        try? FileManager.default.removeItem(at: file)
                    } else {
                        failed += 1
                        Analytics.capture("照片上传失败留队", ["key": Self.relKey(forPendingFile: file)])
                    }
                    pump()
                }
            }
            if total > 0 {
                Analytics.capture("照片队列清空", [
                    "张数": total, "失败": failed,
                    "耗时秒": Int(Date().timeIntervalSince(t0).rounded()),
                    "并发": Self.maxConcurrent,
                ])
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

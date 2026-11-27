import Foundation
import Observation
import UIKit
import WebKit

// 书的「下载到本地」（2026-11-27）：把一本书存到 App 里，断网也能看、能听；有动画版的一并能播。
//
// **一套内容、一套路径、一套机制**：
//   - 存什么：服务端的文件清单（GET /books/<slug>/?format=files）列出这本书的文件夹里有什么
//     ——网页、封面、插图、动画版（video/ 子目录）——App 照清单按原路径原样取回来，再加上每章
//     的有声书。「一本书由哪些文件组成」只在服务端回答，这里不解析任何页面。
//   - 存的是线上原样的那一份：同一个页面、同一个「听本章」播放器、同一个动画版，没有「离线版」。
//   - 怎么读：阅读器用自定义协议 `vdbook://offline/books/<slug>/…` 打开，页面里发出的每个请求
//     （相对链接的章节页、`../<slug>/_src/book.json`、`../audiobook/<slug>/<章>`、`video/…`）
//     落到和线上一样的路径上，由 BookOfflineSchemeHandler 从本地文件应答。线上怎么取，本地就怎么给。
//
// 落盘布局（Application Support/OfflineBooks/<slug>/）= 线上这本书文件夹的镜像：
//   index.html  intro.html  01.html …  cover.jpg  p01.jpg …  video/…  _src/book.json
//   audio/01.mp3 …      —— 每章有声书（线上地址是 /books/audiobook/<slug>/01，不在书的文件夹里）
//   manifest.json       —— 下载记录（有它才算下载完成）

// MARK: - 纯逻辑（路径映射 / 解析），单测覆盖

enum BookOfflineLayout {
    static let scheme = "vdbook"
    static let host = "offline"

    /// slug / 文件名段只认这些字符——路径是拼出来落盘的，必须先验。
    static func isSafeSegment(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != "..", s.count <= 120 else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// 这本书的本地根页：vdbook://offline/books/<slug>/
    static func rootURL(slug: String) -> URL? {
        guard isSafeSegment(slug) else { return nil }
        return URL(string: "\(scheme)://\(host)/books/\(slug)/")
    }

    /// 线上地址（voicedrop.cn/books/<slug>/… 或 jianshuo.dev/voicedrop/books/<slug>/…）→ 同一路径的本地地址。
    /// 不是这本书的地址返回 nil。
    static func localURL(forPublic url: URL, slug: String) -> URL? {
        guard isSafeSegment(slug), let r = url.path.range(of: "/books/") else { return nil }
        var tail = String(url.path[r.lowerBound...])           // "/books/<slug>/…"
        if tail == "/books/\(slug)" { tail += "/" }
        guard tail.hasPrefix("/books/\(slug)/") else { return nil }
        return URL(string: "\(scheme)://\(host)\(tail)")
    }

    /// 本地地址 → 线上地址（分享出去的必须是别人打得开的链接）。base = API.publicWebBase。
    static func publicURL(forLocal url: URL, base: String) -> URL? {
        guard url.scheme == scheme else { return nil }
        return URL(string: base + url.path)
    }

    enum Target: Equatable {
        case file(String)   // 相对 OfflineBooks 根目录的文件路径
        case shelf          // 页面顶栏的「书架」链接（../）——退出阅读器
        case invalid
    }

    /// 请求路径 → 本地文件。与线上路由一一对应：
    ///   /books/                         → 书架
    ///   /books/<slug>/                  → <slug>/index.html
    ///   /books/<slug>/<文件…>           → <slug>/<文件…>
    ///   /books/<slug>/video/            → <slug>/video/index.html（目录路径补 index.html，同线上）
    ///   /books/audiobook/<slug>/<章>    → <slug>/audio/<章>.mp3
    static func target(forPath path: String) -> Target {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.first == "books" else { return .invalid }
        if comps.count == 1 { return .shelf }
        guard comps.dropFirst().allSatisfy(isSafeSegment) else { return .invalid }
        if comps[1] == "audiobook" {
            guard comps.count == 4 else { return .invalid }
            return .file("\(comps[2])/audio/\(comps[3]).mp3")
        }
        // 目录路径（尾斜杠，或最后一段不带扩展名）→ 补 index.html，与线上路由同一条规则。
        let rel = comps.dropFirst().joined(separator: "/")
        if path.hasSuffix("/") || !(comps.last ?? "").contains(".") { return .file(rel + "/index.html") }
        return .file(rel)
    }

    /// 清单里的相对路径能不能落盘：每一段都得是安全的文件名（路径来自网络，必须先验）。
    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.isEmpty && parts.count <= 6 && parts.allSatisfy(isSafeSegment)
    }

    /// `Range: bytes=a-b / a- / -n` → 要回的字节区间；其余（含越界、多段）返回 nil = 回整个文件。
    /// <audio> 拖进度条、边读边播全靠 206。
    static func byteRange(_ header: String?, size: Int) -> Range<Int>? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = h.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let a = String(spec[..<dash]), b = String(spec[spec.index(after: dash)...])
        if a.isEmpty {
            guard let n = Int(b), n > 0 else { return nil }
            return (size - min(n, size))..<size
        }
        guard let start = Int(a), start >= 0, start < size else { return nil }
        if b.isEmpty { return start..<size }
        guard let end = Int(b), end >= start else { return nil }
        return start..<(min(end, size - 1) + 1)
    }

    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "json": return "application/json"
        case "mp3": return "audio/mpeg"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        // 动画版用到的：字体、矢量图、口播 / 配乐、视频片段
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "svg": return "image/svg+xml"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "txt", "srt", "vtt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 本地书库

struct BookOfflineManifest: Codable, Equatable, Sendable {
    let slug: String
    let title: String
    let downloadedAt: Date
    let bytes: Int
    let files: Int          // 镜像下来的文件数（网页、图片、动画版的文件）
    let audio: Int          // 下到的 mp3 数
    let audioMissing: Int   // 没下到的 mp3 数（合成失败 / 超时）；联网时这些章仍可在线听
}

@MainActor
@Observable
final class BookOfflineStore {
    static let shared = BookOfflineStore()

    private(set) var manifests: [String: BookOfflineManifest] = [:]
    /// 正在下载的书 → 进度 0…1。
    private(set) var progress: [String: Double] = [:]

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "OfflineBooks", directoryHint: .isDirectory)
    }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        // 书是随时能重下的公开内容，别占用户的 iCloud 备份额度。
        var dir = Self.root
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        for slug in (try? fm.contentsOfDirectory(atPath: Self.root.path)) ?? [] {
            let f = Self.root.appending(path: slug).appending(path: "manifest.json")
            if let d = try? Data(contentsOf: f), let m = try? JSONDecoder().decode(BookOfflineManifest.self, from: d) {
                manifests[slug] = m
            }
        }
    }

    func isDownloaded(_ slug: String) -> Bool { manifests[slug] != nil }
    func isDownloading(_ slug: String) -> Bool { progress[slug] != nil }

    enum Outcome: Equatable { case done(BookOfflineManifest), failed(String), busy }

    /// 下载（或重新下载）一本书。先下到 <slug>.downloading，全部就绪才整体换上——
    /// 中途失败、被杀都不会留下半本书；失败后再点会接着用已经下好的文件。
    @discardableResult
    func download(slug: String, title: String) async -> Outcome {
        guard BookOfflineLayout.isSafeSegment(slug) else { return .failed(String(localized: "这本书下载不了")) }
        guard progress[slug] == nil else { return .busy }
        progress[slug] = 0
        // 切到后台也给一段时间把手头的文件收完（系统给的宽限，到点就停，下次接着下）。
        let bg = UIApplication.shared.beginBackgroundTask(withName: "book-offline-\(slug)")
        defer {
            progress[slug] = nil
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        do {
            let m = try await BookOfflineDownloader.run(
                slug: slug, title: title, base: API.publicWebBase, root: Self.root
            ) { [weak self] p in
                Task { @MainActor in if self?.progress[slug] != nil { self?.progress[slug] = p } }
            }
            manifests[slug] = m
            return .done(m)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func remove(_ slug: String) {
        guard BookOfflineLayout.isSafeSegment(slug) else { return }
        manifests[slug] = nil
        let fm = FileManager.default
        try? fm.removeItem(at: Self.root.appending(path: slug))
        try? fm.removeItem(at: Self.root.appending(path: slug + ".downloading"))
    }
}

// MARK: - 下载器（不碰主线程）

enum BookOfflineError: LocalizedError {
    case http(String, Int), emptyBook
    var errorDescription: String? {
        switch self {
        case .http(let what, let code): return String(localized: "下载失败：\(what)（\(code)）")
        case .emptyBook: return String(localized: "这本书还没有可下载的章节")
        }
    }
}

enum BookOfflineDownloader {
    /// 有声书首播要现场合成（一章约一分钟、边合成边流），所以单请求给足时间；
    /// 并发压低——实测几十路同时合成会把语音合成接口压超限，返回空文件。
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData   // 存下来的必须是此刻线上的版本
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 1200
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()
    private static let audioConcurrency = 3
    private static let fileConcurrency = 6

    /// 服务端的文件清单（见 functions/voicedrop/books 的 filesJSON）。
    struct FileList: Decodable, Sendable {
        struct Item: Decodable, Sendable { let path: String; let size: Int }
        let files: [Item]
        let audio: [String]
    }

    static func run(slug: String, title: String, base: String, root: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> BookOfflineManifest {
        let fm = FileManager.default
        let work = root.appending(path: slug + ".downloading", directoryHint: .isDirectory)
        try fm.createDirectory(at: work.appending(path: "audio"), withIntermediateDirectories: true)
        let bookBase = "\(base)/books/\(slug)/"

        // 1. 这本书由哪些文件组成：问服务端，不自己猜。
        let listData = try await fetch(bookBase + "?format=files", what: String(localized: "文件清单"))
        guard let list = try? JSONDecoder().decode(FileList.self, from: listData) else { throw BookOfflineError.emptyBook }
        let files = list.files.filter { BookOfflineLayout.isSafeRelativePath($0.path) }
        let stems = list.audio.filter(BookOfflineLayout.isSafeSegment)
        guard files.contains(where: { $0.path == "index.html" }) else { throw BookOfflineError.emptyBook }

        // 进度按字节算（动画版的口播一个文件就几十 MB）；每章有声书大小事先不知道，按 3MB 估。
        let audioGuess = 3_000_000
        let total = Double(files.reduce(0) { $0 + max($1.size, 1) } + stems.count * audioGuess)
        let counter = Counter()
        let advance: @Sendable (Int) -> Void = { progress(min(0.99, Double(counter.add($0)) / max(total, 1))) }

        // 2. 照清单镜像。网页缺一页算失败（书不完整不算下载好）；其余文件（图片、动画版）尽力而为。
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = files.makeIterator()
            func add() {
                guard let f = it.next() else { return }
                group.addTask {
                    let ok = await mirror(bookBase + f.path, to: work.appending(path: f.path), expectSize: f.size)
                    advance(max(f.size, 1))
                    if !ok, f.path.hasSuffix(".html"), !f.path.contains("/") { throw BookOfflineError.http(f.path, 0) }
                }
            }
            for _ in 0..<fileConcurrency { add() }
            while try await group.next() != nil { add() }
        }

        // 3. 每章有声书。没播过的章节服务端会现场合成并缓存（别人以后听也直接有）。
        var missing = 0
        await withTaskGroup(of: Bool.self) { group in
            var it = stems.makeIterator()
            func add() {
                guard let stem = it.next() else { return }
                group.addTask {
                    let ok = await mirror("\(base)/books/audiobook/\(slug)/\(stem)",
                                          to: work.appending(path: "audio/\(stem).mp3"), expectSize: nil, minSize: 20_000, tries: 3)
                    advance(audioGuess)
                    return ok
                }
            }
            for _ in 0..<audioConcurrency { add() }
            while let ok = await group.next() { if !ok { missing += 1 }; add() }
        }

        // 4. 记账 + 整体换上。
        let manifest = BookOfflineManifest(slug: slug, title: title, downloadedAt: Date(), bytes: directorySize(work),
                                           files: files.count, audio: stems.count - missing, audioMissing: missing)
        try JSONEncoder().encode(manifest).write(to: work.appending(path: "manifest.json"), options: .atomic)
        let final = root.appending(path: slug, directoryHint: .isDirectory)
        if fm.fileExists(atPath: final.path) { _ = try fm.replaceItemAt(final, withItemAt: work) }
        else { try fm.moveItem(at: work, to: final) }
        progress(1)
        return manifest
    }

    private static func fetch(_ url: String, what: String) async throws -> Data {
        guard let u = URL(string: url) else { throw BookOfflineError.http(what, 0) }
        var last = 0
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            if let (data, resp) = try? await session.data(from: u) {
                last = resp.httpStatusCode
                if resp.isOK { return data }
                if last == 404 { break }   // 没有就是没有，别重试
            }
        }
        throw BookOfflineError.http(what, last)
    }

    /// 把一个线上地址原样存成一个本地文件：下到临时文件再搬（大文件不进内存）。
    /// 上次没下完留下的同名文件：大小对得上（或无从比对但够大）就接着用。失败返回 false。
    private static func mirror(_ url: String, to dest: URL, expectSize: Int?, minSize: Int = 1, tries: Int = 3) async -> Bool {
        let fm = FileManager.default
        let have = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
        // 网页经服务端注入（播放器等）后比清单里的原始大小大，不比大小，有就算。
        let isPage = dest.pathExtension.lowercased().hasPrefix("htm")
        if have >= minSize, isPage || expectSize == nil || have == expectSize { return true }
        guard let u = URL(string: url) else { return false }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        for attempt in 0..<tries {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }
            guard let (tmp, resp) = try? await session.download(from: u) else { continue }
            guard resp.isOK else { try? fm.removeItem(at: tmp); if resp.httpStatusCode == 404 { return false }; continue }
            let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
            guard size >= minSize else { try? fm.removeItem(at: tmp); continue }   // 语音合成被压超限时会回空文件
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: tmp, to: dest)) != nil { return true }
        }
        return false
    }

    private static func directorySize(_ dir: URL) -> Int {
        var total = 0
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        return total
    }

    /// 并发任务共用的已完成字节数。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ k: Int) -> Int { lock.lock(); defer { lock.unlock() }; n += k; return n }
    }
}

// MARK: - vdbook:// —— 让线上原样的页面从本地文件应答

final class BookOfflineSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let headers = ["Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        func respond(_ status: Int, _ extra: [String: String] = [:], _ body: Data = Data()) {
            let h = headers.merging(extra) { $1 }
            guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h) else { return }
            task.didReceive(resp)
            if !body.isEmpty { task.didReceive(body) }
            task.didFinish()
        }
        guard case .file(let rel) = BookOfflineLayout.target(forPath: url.path) else { return respond(404) }
        let file = BookOfflineStore.root.appending(path: rel)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else {
            // 本地没有（比如那一章的音频没下到）：如实回 404——播放器的 HEAD 探测据此判断「没有现成的」。
            return respond(404)
        }
        var meta = ["Content-Type": BookOfflineLayout.mimeType(forPath: rel), "Accept-Ranges": "bytes"]
        if task.request.httpMethod == "HEAD" {
            meta["Content-Length"] = String(size)
            return respond(200, meta)
        }
        if let range = BookOfflineLayout.byteRange(task.request.value(forHTTPHeaderField: "Range"), size: size),
           let fh = try? FileHandle(forReadingFrom: file) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(range.lowerBound))
            let data = (try? fh.read(upToCount: range.count)) ?? Data()
            meta["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            meta["Content-Length"] = String(data.count)
            return respond(206, meta, data)
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return respond(404) }
        meta["Content-Length"] = String(data.count)
        respond(200, meta, data)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

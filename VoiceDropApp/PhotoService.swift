import Foundation
import UIKit

/// THE single place for scene-photo HTTP I/O. Download and upload were each
/// copy-pasted in two stores (LibraryStore / CommunityStore / RecordSession),
/// already drifting in URL encoding. Centralize so the endpoint, auth, and
/// encoding live once.
enum PhotoService {
    /// Decoded-image cache, keyed by full R2 key. Photo keys are immutable content
    /// addresses (an AI edit mints a NEW key, it never rewrites the old one), so a
    /// hit can be trusted forever — no TTL, no revalidation. NSCache evicts under
    /// memory pressure on its own; cost is the decoded bitmap size, not the JPEG size.
    // NSCache is documented thread-safe; it just isn't marked Sendable.
    nonisolated(unsafe) private static let decodedCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 128 << 20   // ~128MB of decoded pixels (~20 张 1080p 图)
        return c
    }()

    // ── 磁盘缓存（Caches/photo-cache/）───────────────────────────────────────────
    // 内存缓存活不过冷启动——列表两百多个封面图标每次启动全量重下，国内直连
    // Cloudflare 的窄带宽一张 140KB 原图就要 1s+，这是「图标特别慢」的主凶。
    // key 不可变（同上），下载成功的 JPEG 字节落盘即可信一辈子；放 Caches/ 系统
    // 存储紧张时可整体回收，自己再加一道 512MB 的粗剪。
    nonisolated(unsafe) private static let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "photo-cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trimIfOversized(dir)
        return dir
    }()

    private static func diskURL(_ cacheKey: String) -> URL {
        diskDir.appending(path: cacheKey.replacingOccurrences(of: "/", with: "_"))
    }

    /// 启动时一次性粗剪：超过 512MB 就按修改时间删最旧的一半。O(文件数)，几百个
    /// 文件毫秒级；不追求精确 LRU——这是缓存，删错了顶多重下一次。
    private static func trimIfOversized(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = files.compactMap {
            guard let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return ($0, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        guard entries.reduce(0, { $0 + $1.size }) > 512 << 20 else { return }
        entries.sort { $0.mtime < $1.mtime }
        for e in entries.prefix(entries.count / 2) { try? fm.removeItem(at: e.url) }
    }

    // ── 服务端缩图（Cloudflare Image Transformations）──────────────────────────
    // 列表 42pt 图标、社区瀑布流卡片不需要 1200px 原图。缩图在 Cloudflare 边缘
    // 现场做（/cdn-cgi/image/<参数>/<同域路径>，结果缓存在边缘）——客户端零缩图
    // 代码、零 .thumb 文件，iOS/安卓/网页/AI 生成图一条路。zone 侧需要开启
    // Images Transformations 开关；没开时该 URL 404 → 记进 missing 集（免得每次
    // 滚动重试探测）→ 回退原图，行为无损。
    nonisolated(unsafe) private static var thumbMissing = Set<String>()
    private static let thumbLock = NSLock()
    // NSLock 的 lock()/unlock() 在 async 上下文不可用（Swift 6），withLock 的同步函数可以。
    private static func thumbMissed(_ k: String) -> Bool { thumbLock.withLock { thumbMissing.contains(k) } }
    private static func markThumbMissed(_ k: String) { thumbLock.withLock { _ = thumbMissing.insert(k) } }

    /// 边缘缩图 URL：长边 512px、质量 60（原格式输出，UIImage 直接解）。
    private static func transformURL(_ fullKey: String) -> URL? {
        URL(string: "https://\(API.cfHost)/cdn-cgi/image/width=512,quality=60/files/api/photo/\(fullKey.urlPathEncoded)")
    }

    /// Fetch + decode a photo, front-loaded by the in-process image cache: a repeat
    /// visit to an article renders its photos instantly instead of re-downloading.
    /// `ignoringLocalCache` skips the cache READ (a retry must probe the network) but
    /// a successful fetch is always written back.
    /// `preferThumb`: 展示尺寸小（列表图标/卡片）时先取边缘缩图，失败回退原图。
    static func image(fullKey: String, ignoringLocalCache: Bool = false, preferThumb: Bool = false) async -> UIImage? {
        if preferThumb, !fullKey.isEmpty {
            let cacheKey = fullKey + "#w512"
            if !thumbMissed(cacheKey) {
                if !ignoringLocalCache, let hit = decodedCache.object(forKey: cacheKey as NSString) { return hit }
                if let ui = await fetchDecoded(url: transformURL(fullKey), cacheKey: cacheKey,
                                               ignoringLocalCache: ignoringLocalCache) { return ui }
                markThumbMissed(cacheKey)   // zone 未开转换 / 单图转换失败 → 本次会话不再探测
            }
        }
        if !ignoringLocalCache, let hit = decodedCache.object(forKey: fullKey as NSString) { return hit }
        guard let d = await data(fullKey: fullKey, ignoringLocalCache: ignoringLocalCache),
              let ui = UIImage(data: d) else { return nil }
        let px = ui.size.width * ui.size.height * ui.scale * ui.scale
        decodedCache.setObject(ui, forKey: fullKey as NSString, cost: Int(px * 4))
        return ui
    }

    /// 下载 + 解码 + 双层缓存（磁盘字节 / 内存位图）——preferThumb 的边缘缩图路径用。
    private static func fetchDecoded(url: URL?, cacheKey: String, ignoringLocalCache: Bool) async -> UIImage? {
        let file = diskURL(cacheKey)
        var bytes: Data?
        if !ignoringLocalCache, let d = try? Data(contentsOf: file), !d.isEmpty { bytes = d }
        if bytes == nil {
            guard let url else { return nil }
            var req = URLRequest(url: url)
            if ignoringLocalCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
            guard let (d, resp) = try? await URLSession.shared.data(for: req), resp.isOK, !d.isEmpty else { return nil }
            try? d.write(to: file, options: .atomic)   // 只缓存成功响应——失败绝不落盘
            bytes = d
        }
        guard let bytes, let ui = UIImage(data: bytes) else { return nil }
        let px = ui.size.width * ui.size.height * ui.scale * ui.scale
        decodedCache.setObject(ui, forKey: cacheKey as NSString, cost: Int(px * 4))
        return ui
    }

    /// Download a photo by its FULL R2 key via the public `/photo/<key>` endpoint
    /// (no auth — the one photo URL the app, community, and web pages all use).
    ///
    /// `ignoringLocalCache` exists because CFNetwork can pin a failed response for a
    /// URL despite the server's `no-store` (seen 2026-07-09: an AI photo's 制作中-window
    /// miss stuck forever while Safari showed the same URL fine). Retry attempts MUST
    /// bypass the local cache or a cached failure can never self-heal. It also skips
    /// the disk-cache READ; a successful fetch is always written back.
    static func data(fullKey: String, ignoringLocalCache: Bool = false) async -> Data? {
        guard !fullKey.isEmpty else { return nil }
        let file = diskURL(fullKey)
        if !ignoringLocalCache, let d = try? Data(contentsOf: file), !d.isEmpty { return d }
        // 原图走 photoBase（voicedrop.cn / EdgeOne 国内边缘缓存），不走跨洋的 jianshuo.dev。
        guard let url = URL(string: "\(API.photoBase.absoluteString)/photo/\(fullKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        if ignoringLocalCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK, !data.isEmpty else { return nil }
            try? data.write(to: file, options: .atomic)   // 只缓存成功响应——失败绝不落盘
            return data
        } catch { return nil }
    }

    /// PUT JPEG bytes to a relative key (within the bearer's own scope). Returns the
    /// relative key on success, nil otherwise. 缩图不在客户端做——多端各自实现太脆，
    /// 展示面用 Cloudflare 边缘转换（见 transformURL）。
    @discardableResult
    static func upload(data: Data, relKey: String, bearer: String) async -> String? {
        guard !bearer.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/upload/\(relKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // 原样直传：进这里的字节都已被来源路径正确处理（拍照=方图 ≤1080、相册
        // 导入=原比例长边 ≤1440）。以前这里会再裁一次 1:1，把导入保住的长宽比
        // 又剪掉——显示端 PhotoTile 本就按真实比例自适应，不需要方图。
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? relKey : nil
        } catch { return nil }
    }
}

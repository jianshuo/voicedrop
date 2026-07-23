import Foundation

/// 落盘快照的唯一工具（SWR「先旧后新」的存储层）：Caches 目录（磁盘紧张 iOS 自动清）、
/// 读同步（init/开页用）、写异步。家法三条：成功才覆盖写；坏文件当没有；不做失效
/// 逻辑——下次成功加载自然覆盖。
enum DiskCache {
    /// 所有写走同一条串行队列：①JSON 编码不占主线程；②同名文件两次快速写不会
    /// 乱序（后写的必然后落盘——UserDefaults 时代的同步顺序语义保住，否则「保存
    /// 编辑→刷新」两次写被调度器倒序会让旧快照压过新的）。
    private static let io = DispatchQueue(label: "vd.diskcache", qos: .utility)

    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // 带子目录的名字（如 "article-doc-cache/x.json"）自动建目录。
        let target = dir.appending(path: name)
        if name.contains("/") {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        return target
    }

    static func loadData(_ name: String) -> Data? {
        try? Data(contentsOf: url(name))
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        loadData(name).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func saveData(_ data: Data, _ name: String) {
        let target = url(name)
        io.async { try? data.write(to: target, options: .atomic) }
    }

    static func save<T: Encodable & Sendable>(_ value: T, _ name: String) {
        let target = url(name)
        io.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    /// 销号与身份切换（adoptToken 设备互联登录、重置匿名身份）必须调用：这些快照
    /// 全是按当前身份拉的私有数据（录音列表、文章正文、社区 mine/已赞、照片），
    /// 不清掉会在新身份下复活上一个身份的内容。走 io.sync——排在所有在途写之后，
    /// 保证 wipe 之后不会有迟到的写把旧数据又落回来。
    static func wipe() {
        io.sync {
            let fm = FileManager.default
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            for name in ["recordings-list-cache.json", "community-feed-cache.json",
                         "prompts-cache.json", "prompt-market-cache.json",
                         "article-meta-cache.json", "article-doc-cache",
                         "community-post-cache", "photo-cache"] {
                try? fm.removeItem(at: caches.appending(path: name))
            }
        }
    }
}

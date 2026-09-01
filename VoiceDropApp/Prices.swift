import Foundation

/// 价目表 — 一天从服务端拉一次，其余时候读本地缓存。
///
/// 价钱的真源在服务端（`agent/src/usage.js` 的 `BOOK_SUANLI`），扣费也只发生在
/// 那边：余额不够时 `POST /api/book` 回 402，body 带权威的 `need_suanli`。所以
/// App 这头管的只是**展示价**——它不必和服务端时刻一致，一天一次足够，页面永远
/// 拿缓存立刻渲染，过期了才在后台补一次。
///
/// `fallback` 是从没拉到过时（首次安装 / 断网）用的兜底；改价时顺手跟着改一次，
/// 但就算忘了改也只是「显示的价钱旧一天」，扣费不会错。
enum Prices {
    struct Table: Codable, Equatable {
        var book: Int          // 写一本书
        var bookRevise: Int    // 修一轮
        var fetchedAt: Double  // 上次拉到的时刻（秒）
    }

    /// 服务端 GET /agent/usage/prices 的形状（只取用得上的字段）。
    struct Remote: Decodable {
        let book: Int?
        let book_revise: Int?
    }

    static let fallback = Table(book: 160, bookRevise: 40, fetchedAt: 0)
    static let ttl: TimeInterval = 24 * 3600
    static let defaultsKey = "voicedrop.prices.v1"

    // MARK: 纯逻辑（可测，不碰网络也不碰磁盘）

    /// 该不该去拉：没缓存、或缓存过了一天。
    static func isStale(_ table: Table?, now: Double) -> Bool {
        guard let table else { return true }
        return now - table.fetchedAt > ttl
    }

    /// 远端数据 → 可用的价目。脏数据（缺字段、0、负数）一律拒收，返回 nil = 沿用旧值。
    static func merge(remote: Remote?, previous: Table, now: Double) -> Table? {
        guard let book = remote?.book, book > 0 else { return nil }
        let revise = (remote?.book_revise).flatMap { $0 > 0 ? $0 : nil } ?? previous.bookRevise
        return Table(book: book, bookRevise: revise, fetchedAt: now)
    }

    // MARK: 存取

    static func load(_ defaults: UserDefaults = .standard) -> Table? {
        guard let data = defaults.data(forKey: defaultsKey),
              let table = try? JSONDecoder().decode(Table.self, from: data),
              table.book > 0 else { return nil }
        return table
    }

    static func save(_ table: Table, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// 当前展示价：有缓存用缓存，没有用兜底。永远同步返回，不等网络。
    static var current: Table { load() ?? fallback }
    static var book: Int { current.book }
    static var bookRevise: Int { current.bookRevise }

    /// 过期了才拉一次。失败一律吞掉——展示价拿不到不该影响任何流程。
    /// 返回值 = 拉完之后的当前价目（没拉也返回现价，调用方可以直接用）。
    @discardableResult
    static func refreshIfNeeded(now: Double = Date().timeIntervalSince1970,
                                defaults: UserDefaults = .standard) async -> Table {
        let previous = load(defaults) ?? fallback
        guard isStale(load(defaults), now: now) else { return previous }
        let remote: Remote? = await API.get(API.agentBase.appending(path: "usage/prices"), bearer: "")
        guard let next = merge(remote: remote, previous: previous, now: now) else { return previous }
        save(next, to: defaults)
        return next
    }
}

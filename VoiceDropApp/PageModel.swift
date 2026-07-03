import Foundation

// MARK: - 白名单枚举（越界回落默认值，绝不抛错）

enum PageAlign: String, Equatable {
    case leading, center, trailing
    static func from(_ s: Any?) -> PageAlign { (s as? String).flatMap(PageAlign.init(rawValue:)) ?? .leading }
}

enum PageWeight: String, Equatable {
    case regular, medium, semibold, bold
    static func from(_ s: Any?) -> PageWeight { (s as? String).flatMap(PageWeight.init(rawValue:)) ?? .regular }
}

enum PageAction: String, Equatable {
    case record, openArticles, openCommunity, openSettings, openNote
    static func from(_ s: Any?) -> PageAction? { (s as? String).flatMap(PageAction.init(rawValue:)) }
}

enum PageBlock: String, Equatable {
    case recordButton, articleList, communityFeed, notePlaceholder
    static func from(_ s: Any?) -> PageBlock? { (s as? String).flatMap(PageBlock.init(rawValue:)) }
}

enum PageColorToken: String, Equatable {
    case ink, secondary, faint, accent, recordRed, greenDone, amberPending
    static func from(_ s: Any?) -> PageColorToken { (s as? String).flatMap(PageColorToken.init(rawValue:)) ?? .ink }
}

enum PageIcons {
    /// SF Symbol 白名单。新增图标只能往这里加。
    static let allowed: Set<String> = [
        "doc.text", "person.2", "mic", "mic.circle", "brain", "lightbulb",
        "square.grid.2x2", "star", "bookmark", "waveform", "house", "gearshape",
        "pencil", "tray", "bubble.left.and.bubble.right"
    ]
    static func sanitize(_ s: Any?) -> String? {
        guard let n = s as? String, allowed.contains(n) else { return nil }
        return n
    }
}

// MARK: - 节点

indirect enum PageNode: Equatable {
    case vstack(spacing: Double, padding: Double, align: PageAlign, children: [PageNode])
    case hstack(spacing: Double, padding: Double, align: PageAlign, children: [PageNode])
    case grid(columns: Int, spacing: Double, children: [PageNode])
    case spacer(size: Double?)
    case text(value: String, size: Double, weight: PageWeight, color: PageColorToken, align: PageAlign)
    case image(source: String, aspect: Double?, corner: Double)
    case card(title: String, subtitle: String?, icon: String?, tint: PageColorToken, tap: PageAction)
    case embed(block: PageBlock)
    case unknown

    /// v1 封闭词表。root 的 type 不在这里 → 整份文档按损坏处理（decode 返回 nil）；
    /// 在词表里但必填字段非法 → 节点降级 `.unknown`（渲染为空，不作废文档）。
    static let knownTypes: Set<String> = ["vstack", "hstack", "grid", "spacer", "text", "image", "card", "embed"]

    /// 把任意 JSON 值递归解析成节点。无法识别 → `.unknown`（永不抛错）。
    static func parse(_ any: Any?) -> PageNode {
        guard let dict = any as? [String: Any], let type = dict["type"] as? String else { return .unknown }
        func num(_ k: String, _ d: Double) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? d }
        func optNum(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
        func kids() -> [PageNode] { (dict["children"] as? [Any])?.map(PageNode.parse) ?? [] }

        switch type {
        case "vstack":
            return .vstack(spacing: num("spacing", 12), padding: num("padding", 0),
                           align: .from(dict["align"]), children: kids())
        case "hstack":
            return .hstack(spacing: num("spacing", 12), padding: num("padding", 0),
                           align: .from(dict["align"]), children: kids())
        case "grid":
            let cols = max(1, min(4, (dict["columns"] as? NSNumber)?.intValue ?? 2))
            return .grid(columns: cols, spacing: num("spacing", 12), children: kids())
        case "spacer":
            return .spacer(size: optNum("size"))
        case "text":
            return .text(value: (dict["value"] as? String) ?? "", size: num("size", 17),
                         weight: .from(dict["weight"]), color: .from(dict["color"]),
                         align: .from(dict["align"]))
        case "image":
            guard let src = dict["source"] as? String, !src.isEmpty else { return .unknown }
            return .image(source: src, aspect: optNum("aspect"), corner: num("corner", 8))
        case "card":
            guard let tap = PageAction.from(dict["tap"]) else { return .unknown }
            return .card(title: (dict["title"] as? String) ?? "",
                         subtitle: dict["subtitle"] as? String,
                         icon: PageIcons.sanitize(dict["icon"]),
                         tint: .from(dict["tint"]), tap: tap)
        case "embed":
            guard let block = PageBlock.from(dict["block"]) else { return .unknown }
            return .embed(block: block)
        default:
            return .unknown
        }
    }
}

// MARK: - 文档

struct PageDocument: Equatable {
    var schema: Int
    var version: Int
    var root: PageNode

    /// 解码 + 校验。结构性损坏（非对象 / 无 root / root 类型不在词表）→ nil，交给调用方回退。
    static func decode(_ data: Data) -> PageDocument? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootAny = obj["root"] else { return nil }
        guard let rootDict = rootAny as? [String: Any],
              let type = rootDict["type"] as? String, PageNode.knownTypes.contains(type) else { return nil }
        return PageDocument(schema: (obj["schema"] as? NSNumber)?.intValue ?? 1,
                            version: (obj["version"] as? NSNumber)?.intValue ?? 1,
                            root: PageNode.parse(rootAny))
    }
}

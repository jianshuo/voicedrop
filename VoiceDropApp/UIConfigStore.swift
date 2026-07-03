import Foundation
import Observation

// 服务端下发的 UI 配置（GET /agent/ui-config）——按页面命名空间组织的菜单配置文档。
// v1 只消费 pages["voice-editor"].longpress.image / .text 两节（长按配图/段落的菜单）。
// spec: docs/superpowers/specs/2026-07-04-longpress-actions-menu-design.md
//
// 兜底链：本次拉取 → 上次缓存（UserDefaults）→ 内置默认（与服务端 DEFAULT_UI_CONFIG
// 内容一致）。任何一环失败都静默落到下一环——长按永远有菜单。

// MARK: - 配置模型（Codable 自动忽略未知 JSON 字段；未知 type 由渲染器跳过）

struct UIMenuNode: Codable, Identifiable {
    let id: String
    let label: String
    let type: String?
    let children: [UIMenuNode]?
    let instruction: String?
}

struct UIMenuConfig: Codable {
    /// 组的数组：组间渲染分隔线（原生 contextMenu 的 Section 语义）。
    let groups: [[UIMenuNode]]
}

struct UILongpressConfig: Codable {
    let image: UIMenuConfig?
    let text: UIMenuConfig?
}

struct UIPageConfig: Codable {
    let longpress: UILongpressConfig?
}

struct UIConfigDoc: Codable {
    let schema: Int
    let pages: [String: UIPageConfig]
}

// MARK: - Store

@MainActor
@Observable
final class UIConfigStore {
    static let shared = UIConfigStore()

    private(set) var doc: UIConfigDoc

    private static let cacheKey = "uiConfigCache.v1"
    /// 客户端支持的最高 schema；服务端下发更高版本 → 保留现值（老客户端兼容新配置）。
    private static let maxSchema = 1

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(UIConfigDoc.self, from: data),
           cached.schema <= Self.maxSchema {
            doc = cached
        } else {
            doc = Self.builtin
        }
    }

    /// 文章详情页出现时拉一次。失败/schema 过高一律静默保留现值。
    func refresh() async {
        var req = URLRequest(url: API.agentBase.appendingPathComponent("ui-config"))
        req.setBearer(AuthStore.shared.bearer)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let fresh = try? JSONDecoder().decode(UIConfigDoc.self, from: data),
              fresh.schema <= Self.maxSchema
        else { return }
        doc = fresh
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    func imageMenu(page: String) -> UIMenuConfig? { doc.pages[page]?.longpress?.image }
    func textMenu(page: String) -> UIMenuConfig? { doc.pages[page]?.longpress?.text }

    /// 占位符替换：subs 的 key 不带花括号（如 ["KEY": relKey]）。
    static func fill(_ instruction: String, _ subs: [String: String]) -> String {
        var s = instruction
        for (k, v) in subs { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return s
    }

    // MARK: 内置默认（与 agent worker src/ui-config.js DEFAULT_UI_CONFIG 内容一致）

    static let builtin = UIConfigDoc(schema: 1, pages: [
        "voice-editor": UIPageConfig(longpress: UILongpressConfig(
            image: UIMenuConfig(groups: [[
                UIMenuNode(id: "style", label: "图片风格", type: "submenu", children: [
                    UIMenuNode(id: "cartoon", label: "卡通", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）重画成宫崎骏动画的手绘卡通风格，构图和主体不变，正文其他内容都不要动。"),
                    UIMenuNode(id: "ad", label: "广告", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）重新设计成一则商品广告。请从专业设计师的角度，结合本篇文章的内容和受众，打造一个精致、洗练的视觉设计。整体风格要现代、极简，不使用文字，可以加一些别的代替文字的元素。请通过合理的版式构成，最大限度地突出商品的魅力。正文其他内容都不要动。"),
                    UIMenuNode(id: "watercolor", label: "水彩", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）重画成通透的水彩画风格，构图和主体不变，正文其他内容都不要动。"),
                    UIMenuNode(id: "sketch", label: "素描", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）重画成铅笔素描风格，构图和主体不变，正文其他内容都不要动。"),
                    UIMenuNode(id: "oil", label: "油画", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）重画成古典油画风格，构图和主体不变，正文其他内容都不要动。"),
                    UIMenuNode(id: "film", label: "胶片", type: nil, children: nil,
                               instruction: "把这张图（[[photo:{{KEY}}]]）调成胶片摄影的质感和色调，构图和主体不变，正文其他内容都不要动。"),
                ], instruction: nil),
            ]]),
            text: UIMenuConfig(groups: [[
                UIMenuNode(id: "rewrite", label: "改写这段", type: "submenu", children: [
                    UIMenuNode(id: "concise", label: "更简洁", type: nil, children: nil,
                               instruction: "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更简洁，意思不变，正文其他行都不要动。"),
                    UIMenuNode(id: "casual", label: "更口语", type: nil, children: nil,
                               instruction: "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更口语、像平时说话，意思不变，正文其他行都不要动。"),
                    UIMenuNode(id: "formal", label: "更书面", type: nil, children: nil,
                               instruction: "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更书面、更正式，意思不变，正文其他行都不要动。"),
                    UIMenuNode(id: "expand", label: "扩写一点", type: nil, children: nil,
                               instruction: "把第{{LINE}}行（开头是\"{{QUOTE}}\"）扩写一点，补充细节但别啰嗦，正文其他行都不要动。"),
                ], instruction: nil),
            ], [
                UIMenuNode(id: "insert", label: "插入图片", type: "submenu", children: [
                    UIMenuNode(id: "wechat-cover", label: "公众号题图", type: nil, children: nil,
                               instruction: "给这篇文章画一张微信公众号题图，放在文章最前面。画面为 2.45:1 的横幅比例。主视觉不要用泛泛的机器人形象或模糊的科技背景，要用具体的物件表达文章主题，比如提示词卡片、设计画布、图片生成面板、封面草稿。题图上的中文主标题从文章标题提炼，必须清晰可读，最好 6 到 10 个汉字。构图要适合公众号封面：大标题放左侧，主视觉放右侧，四周留足安全边距。风格：成熟的新媒体编辑部封面，干净、精致、实用，不要廉价营销海报感。避免：乱码文字、过多小字、真实品牌 logo、纯氛围壁纸、厚重的蓝紫渐变。正文其他内容都不要动。"),
                ], instruction: nil),
            ]])
        )),
    ])
}

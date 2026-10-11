import SwiftUI

// 阅读字号（2026-10-11）：社区文章、分享文章、书架里的书读起来字偏小。
// 一个全局档位存 UserDefaults，三处共用：
//   - 社区帖 / 分享文章：MarkdownTextBlock 把档位注入 \.readingScale，MarkdownRowView 按比例放大
//   - 书（WKWebView 网页书）：pageZoom = 档位（等同浏览器缩放，会重排不会横滚）
// 自己文章的详情页不跟——那里的 InlineParagraphEditor 与 16pt 正文逐像素对齐，
// 第N行定位也依赖这套排版，动它得一起动编辑器。

enum ReadingFont {
    static let key = "readingFontScale"
    struct Level: Sendable { let label: String; let scale: Double }
    static let levels: [Level] = [
        Level(label: String(localized: "小"), scale: 0.9),
        Level(label: String(localized: "标准"), scale: 1.0),
        Level(label: String(localized: "大"), scale: 1.15),
        Level(label: String(localized: "特大"), scale: 1.3),
        Level(label: String(localized: "超大"), scale: 1.5),
    ]

    static func label(for scale: Double) -> String {
        levels.first(where: { abs($0.scale - scale) < 0.001 })?.label ?? String(localized: "标准")
    }
}

private struct ReadingScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    /// 阅读正文的字号倍率；默认 1（文章详情页等不注入的地方保持原样）。
    var readingScale: Double {
        get { self[ReadingScaleKey.self] }
        set { self[ReadingScaleKey.self] = newValue }
    }
}

/// ⋯ 菜单里的「字号」子菜单：点一档立即生效，全局记住。
struct ReadingFontMenu: View {
    @AppStorage(ReadingFont.key) private var scale = 1.0

    var body: some View {
        Menu {
            Picker(selection: $scale) {
                ForEach(ReadingFont.levels, id: \.scale) { Text($0.label).tag($0.scale) }
            } label: { EmptyView() }
            .pickerStyle(.inline)
        } label: {
            Label("字号", systemImage: "textformat.size")
        }
    }
}

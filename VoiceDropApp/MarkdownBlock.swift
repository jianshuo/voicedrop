import SwiftUI

// 正文的块级 Markdown 支持（2026-08-11）。此前正文只走
// AttributedString(.inlineOnlyPreservingWhitespace)，**粗体**、`代码`、[链接] 能渲染，
// 但 #/## 标题、- 列表、1. 有序列表、> 引用、--- 分隔线都原样露出井号等符号。
// 这里按「一行一个 block」分类（与 bodyRows 的第N行切分天然对齐），编辑时仍编辑
// 原始 Markdown 文本——渲染是甜头，数据一个字不动。

/// 单行块级 Markdown 分类。纯逻辑、可单测；输入是已 trim 过的一行。
enum MarkdownBlock {
    enum Kind: Equatable {
        case h1, h2, h3          // #### 及更深统一按 h3 渲染
        case bullet              // - / * / +
        case ordered(String)     // "1." 的 "1"；支持 1. / 1) / 1、
        case quote               // > 引用（多级 > 压平为一级）
        case divider             // --- / *** / ___（3 个及以上）
        case plain
    }

    /// 把一行拆成（块类型, 去掉语法前缀后的内容）。认不出就原样当 plain。
    static func classify(_ line: String) -> (kind: Kind, content: String) {
        // 标题：#{1,6} + 空白。`#话题` 这种没空格的不算标题。
        if line.hasPrefix("#") {
            let hashes = line.prefix(while: { $0 == "#" })
            let rest = line.dropFirst(hashes.count)
            if hashes.count <= 6, let first = rest.first, first == " " || first == "\t" {
                let content = rest.trimmingCharacters(in: .whitespaces)
                switch hashes.count {
                case 1: return (.h1, content)
                case 2: return (.h2, content)
                default: return (.h3, content)
                }
            }
            return (.plain, line)
        }
        // 分隔线：整行只有同一种符号（- * _）且 ≥3 个，允许中间空格（`- - -`）。
        let solid = line.replacingOccurrences(of: " ", with: "")
        if solid.count >= 3, let c = solid.first, "-*_".contains(c), solid.allSatisfy({ $0 == c }) {
            return (.divider, "")
        }
        // 无序列表：- / * / + 加空白。
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            if let next = rest.first, next == " " || next == "\t" {
                return (.bullet, rest.trimmingCharacters(in: .whitespaces))
            }
        }
        // 有序列表：数字(≤3位) + [.)、] + 空白或行尾后还有内容。
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if let sep = rest.first, ".)、".contains(sep) {
                let after = rest.dropFirst()
                if after.first == " " || after.first == "\t" || (sep == "、" && !after.isEmpty) {
                    return (.ordered(String(digits)), after.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        // 引用：> 开头，多级压平。
        if line.hasPrefix(">") {
            var rest = Substring(line)
            while rest.first == ">" {
                rest = rest.dropFirst()
                while rest.first == " " { rest = rest.dropFirst() }
            }
            return (.quote, rest.trimmingCharacters(in: .whitespaces))
        }
        return (.plain, line)
    }

    /// 行内 Markdown（**粗体**、*斜体*、`代码`、[链接]）→ AttributedString；失败退回原文。
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    }
}

/// 一行正文的渲染视图：块级样式（标题/列表/引用/分隔线）套行内 Markdown。
/// `attributed` 由调用方注入以复用各自的解析缓存（RecordingDetailView 有
/// BodyParseCache）；不传就现场解析。
struct MarkdownRowView: View {
    let text: String
    var attributed: (String) -> AttributedString = MarkdownBlock.inline

    var body: some View {
        let (kind, content) = MarkdownBlock.classify(text)
        switch kind {
        case .h1:
            Text(attributed(content))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.inkRead).lineSpacing(6)
        case .h2:
            Text(attributed(content))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.inkRead).lineSpacing(6)
        case .h3:
            Text(attributed(content))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.inkRead).lineSpacing(7)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(attributed(content))
                    .font(.system(size: 16)).foregroundStyle(Theme.bodyRead).lineSpacing(9)
            }
        case .ordered(let n):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Text(attributed(content))
                    .font(.system(size: 16)).foregroundStyle(Theme.bodyRead).lineSpacing(9)
            }
        case .quote:
            Text(attributed(content))
                .font(.system(size: 16)).foregroundStyle(Theme.metaRead).lineSpacing(9)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent.opacity(0.45)).frame(width: 3)
                }
        case .divider:
            Rectangle().fill(Theme.borderRead)
                .frame(height: 1).frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .plain:
            Text(attributed(text))
                .font(.system(size: 16)).foregroundStyle(Theme.bodyRead).lineSpacing(9)
        }
    }
}

/// 多行文本段（照片标记之间的一整段）→ 逐行块级渲染。社区帖子用；
/// 文章详情页有自己的 bodyRows 逐行结构，直接用 MarkdownRowView。
struct MarkdownTextBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownRowView(text: line)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

import SwiftUI

// 内置使用手册（设置「其他」→「使用手册」）。内容源 = bundle 里的 HelpManual.md
//（真源在 jianshuo.dev repo voicedrop/help/manual/manual.md，网页版改了 cp 一份过来）。
// 不走 WebView：ManualParser 把 markdown 解析成块，SwiftUI 按 Theme 原生排版，
// 离线可读、配色和 App 一致。

// MARK: - 解析（纯逻辑，可单测）

enum ManualBlock: Equatable {
    case title(String)                          // # 大标题（全文一个）
    case chapter(String)                        // ## 章
    case section(String)                        // ### 节
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case table(header: [String], rows: [[String]])
    case code(String)
}

enum ManualParser {
    static func parse(_ md: String) -> [ManualBlock] {
        var blocks: [ManualBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var tableLines: [[String]] = []
        var codeLines: [String] = []
        var inCode = false

        // 分类 flush：进入某一类块时只清掉「别的」类，同类连续行才能积成一个块。
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
        }
        func flushNumbered() {
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }
        func flushTable() {
            if !tableLines.isEmpty {
                blocks.append(.table(header: tableLines[0], rows: Array(tableLines.dropFirst())))
                tableLines = []
            }
        }
        func flushAll() { flushParagraph(); flushBullets(); flushNumbered(); flushTable() }

        for rawLine in md.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = []; inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") { flushAll(); inCode = true; continue }
            if line.isEmpty { flushAll(); continue }
            if line.hasPrefix("### ") { flushAll(); blocks.append(.section(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { flushAll(); blocks.append(.chapter(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flushAll(); blocks.append(.title(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // 分隔行（|---|---|）跳过
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { continue }
                flushParagraph(); flushBullets(); flushNumbered()
                tableLines.append(cells)
                continue
            }
            if line.hasPrefix("- ") {
                flushParagraph(); flushNumbered(); flushTable()
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let r = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph(); flushBullets(); flushTable()
                numbered.append(String(line[r.upperBound...]))
                continue
            }
            paragraph.append(line)
        }
        flushAll()
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }
}

// MARK: - 内容源

enum HelpManual {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "HelpManual", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }()
}

// MARK: - Sheet

struct HelpManualSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let blocks = ManualParser.parse(HelpManual.text)

    /// 章节跳转条：全部 ## 章标题 + 它们在 blocks 里的下标。
    private var chapters: [(index: Int, title: String)] {
        blocks.enumerated().compactMap { i, b in
            if case .chapter(let t) = b { return (i, shortChapter(t)) } else { return nil }
        }
    }

    /// 「第 1 章 第一次上手」→「第一次上手」（章号在跳转条里省掉）
    private func shortChapter(_ t: String) -> String {
        if let r = t.range(of: #"^第\s*\d+\s*章\s*"#, options: .regularExpression) {
            return String(t[r.upperBound...])
        }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("使用手册").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("完成") { dismiss() }
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chapters, id: \.index) { ch in
                            Button {
                                withAnimation { proxy.scrollTo("blk\(ch.index)", anchor: .top) }
                            } label: {
                                Text(ch.title)
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(Theme.tileNeutral, in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 10)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                            blockView(block).id("blk\(i)")
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 50)
                }
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func blockView(_ block: ManualBlock) -> some View {
        switch block {
        case .title(let t):
            Text(t).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
                .padding(.top, 4)
        case .chapter(let t):
            Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                .padding(.top, 18)
        case .section(let t):
            Text(t).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 8)
        case .paragraph(let t):
            inlineText(t)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("·").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.faint)
                        inlineText(item)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
                        inlineText(item)
                    }
                }
            }
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Theme.dividerInCard)
                    tableRow(row, isHeader: false)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderChrome, lineWidth: 1))
        case .code(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.bodyInk)
                    .padding(12)
            }
            .background(Theme.tileNeutral, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                inlineText(cell, size: 14, weight: isHeader ? .semibold : .regular)
                    .frame(width: i == 0 && cells.count > 1 ? 78 : nil, alignment: .leading)
            }
            if cells.count > 1 { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }

    /// 行内 markdown（**加粗**、[链接](url)、`代码`）→ AttributedString；解析失败退回原文。
    private func inlineText(_ s: String, size: CGFloat = 15.5, weight: Font.Weight = .regular) -> Text {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a).font(.system(size: size, weight: weight)).foregroundStyle(Theme.bodyInk)
        }
        return Text(s).font(.system(size: size, weight: weight)).foregroundStyle(Theme.bodyInk)
    }
}

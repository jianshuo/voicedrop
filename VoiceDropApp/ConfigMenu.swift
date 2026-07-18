import SwiftUI
import UIKit

// 长按操作菜单 —— 自绘覆盖层，视觉照设计稿 Long Press Actions.dc.html（方向 2a+2b）：
// 暖纸菜单卡（#FAF6EF·圆角13·组间 7pt 厚分隔）、被按元素抬起带大投影、submenu 原位
// 替换 + 顶部灰底返回行。系统 .contextMenu 改不了这些视觉，所以全部自绘；菜单结构仍由
// PromptStore（PromptLogic.menuConfig 过滤结果）驱动——submenu 递归、未知 type/缺
// instruction 的节点静默跳过。

// MARK: - 菜单配置模型（PromptStore 的输出契约；原属已删除的旧长按菜单配置 store，
// 挪到这里紧挨着唯一的消费方——渲染器）

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

    /// 占位符替换：subs 的 key 不带花括号（如 ["KEY": relKey]）。
    static func fill(_ instruction: String, _ subs: [String: String]) -> String {
        var s = instruction
        for (k, v) in subs { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return s
    }
}

/// 一次长按呈现：被按元素（图/段落）+ 它的 global frame + 菜单配置 + 占位符替换。
struct LongpressPresentation: Identifiable {
    enum Anchor {
        case image(UIImage)
        case text(String)
    }
    let id = UUID()
    let anchor: Anchor
    let frame: CGRect            // 被按元素的 global frame（呈现时换算成 overlay 本地坐标）
    let menu: UIMenuConfig
    let fill: (String) -> String
    /// (成品指令文本, 被点菜单项的 id)。id 随 WS 上行做出图溯源；本地行不经过这里。
    let onPick: (String, String?) -> Void
    var localRows: [LongpressLocalRow] = []   // 客户端本地行（拷贝），追加为最后一组
}

/// 客户端本地菜单行（不进服务端配置、不走网络）。
struct LongpressLocalRow: Identifiable {
    let id = UUID()
    let label: String
    let systemImage: String
    let action: () -> Void
}

struct LongpressMenuOverlay: View {
    let model: LongpressPresentation
    let dismiss: () -> Void

    /// 2b：当前进入的 submenu（nil = 一级）。整张卡原位替换，不叠层。
    @State private var openSubmenu: UIMenuNode?

    // —— 设计稿色板（Long Press Actions.dc.html）——
    private let paper    = Color(red: 250/255, green: 246/255, blue: 239/255)  // #FAF6EF
    private let ink      = Color(red: 42/255,  green: 37/255,  blue: 33/255)   // #2A2521
    private let hairline = Color(red: 239/255, green: 231/255, blue: 217/255)  // #EFE7D9
    private let thickSep = Color(red: 241/255, green: 235/255, blue: 224/255)  // #F1EBE0
    private let hintText = Color(red: 167/255, green: 159/255, blue: 147/255)  // #A79F93
    private let chevTint = Color(red: 184/255, green: 174/255, blue: 158/255)  // #B8AE9E
    private let backInk  = Color(red: 107/255, green: 99/255,  blue: 87/255)   // #6B6357
    private let backSep  = Color(red: 232/255, green: 223/255, blue: 205/255)  // #E8DFCD

    private let menuWidth: CGFloat = 240
    private let rowHeight: CGFloat = 48
    private let backRowHeight: CGFloat = 42

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let anchor = CGRect(x: model.frame.minX - origin.x, y: model.frame.minY - origin.y,
                                width: model.frame.width, height: model.frame.height)
            ZStack(alignment: .topLeading) {
                // 压暗 scrim（正文的模糊由父视图做）——点空白处收起
                ink.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                liftedAnchor(anchor)
                    .allowsHitTesting(false)

                menuCard
                    .frame(width: menuWidth)
                    .offset(menuOffset(in: geo.size, anchor: anchor))
            }
        }
        .onAppear { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    // MARK: 被按元素抬起（0 24px 60px rgba(42,37,33,.4) 的大投影）

    @ViewBuilder
    private func liftedAnchor(_ rect: CGRect) -> some View {
        switch model.anchor {
        case .image(let img):
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: ink.opacity(0.4), radius: 30, x: 0, y: 24)
                .offset(x: rect.minX, y: rect.minY)
        case .text(let t):
            // 段落抬起成一张纸卡（原文在底下已被模糊压暗）
            Text(t)
                .font(.system(size: 16)).foregroundStyle(ink)
                .lineSpacing(9)
                .padding(12)
                .frame(width: rect.width + 24, alignment: .topLeading)
                .background(paper, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: ink.opacity(0.35), radius: 24, x: 0, y: 18)
                .offset(x: rect.minX - 12, y: rect.minY - 12)
        }
    }

    // MARK: 菜单卡定位：优先贴在元素下方 12pt，放不下翻到上方，横向钳在屏内

    private func menuOffset(in size: CGSize, anchor: CGRect) -> CGSize {
        let h = estimatedHeight
        let below = anchor.maxY + 12
        let y: CGFloat
        if below + h <= size.height - 16 {
            y = below
        } else {
            y = max(16, anchor.minY - 12 - h)
        }
        let x = min(max(16, anchor.minX), max(16, size.width - menuWidth - 16))
        return CGSize(width: x, height: y)
    }

    private var renderableGroups: [[UIMenuNode]] {
        model.menu.groups
            .map { $0.filter { node in
                (node.type == "submenu" && !(node.children ?? []).isEmpty) || node.instruction != nil
            } }
            .filter { !$0.isEmpty }
    }

    private var estimatedHeight: CGFloat {
        if let sub = openSubmenu {
            return backRowHeight + CGFloat((sub.children ?? []).count) * rowHeight
        }
        let groups = renderableGroups
        let rows = groups.reduce(0) { $0 + $1.count } + model.localRows.count
        let seps = max(0, groups.count - 1) + (model.localRows.isEmpty ? 0 : 1)
        return CGFloat(rows) * rowHeight + CGFloat(seps) * 7
    }

    // MARK: 菜单卡

    private var menuCard: some View {
        VStack(spacing: 0) {
            if let sub = openSubmenu {
                submenuLevel(sub)
            } else {
                rootLevel
            }
        }
        .background(paper.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: ink.opacity(0.32), radius: 22, x: 0, y: 18)
        .animation(.easeOut(duration: 0.16), value: openSubmenu?.id)
    }

    @ViewBuilder
    private var rootLevel: some View {
        let groups = renderableGroups
        ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
            if gi > 0 { thickSep.frame(height: 7) }
            ForEach(Array(group.enumerated()), id: \.element.id) { i, node in
                nodeRow(node, isLast: i == group.count - 1)
            }
        }
        if !model.localRows.isEmpty {
            if !groups.isEmpty { thickSep.frame(height: 7) }
            ForEach(Array(model.localRows.enumerated()), id: \.element.id) { i, row in
                localRow(row, isLast: i == model.localRows.count - 1)
            }
        }
    }

    @ViewBuilder
    private func submenuLevel(_ sub: UIMenuNode) -> some View {
        backRow(sub)
        let children = (sub.children ?? []).filter {
            ($0.type == "submenu" && !($0.children ?? []).isEmpty) || $0.instruction != nil
        }
        ForEach(Array(children.enumerated()), id: \.element.id) { i, node in
            nodeRow(node, isLast: i == children.count - 1)
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: UIMenuNode, isLast: Bool) -> some View {
        if node.type == "submenu", let children = node.children, !children.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { openSubmenu = node }
            } label: {
                HStack(spacing: 11) {
                    Text(node.label).font(.system(size: 15.5)).foregroundStyle(ink)
                    Spacer(minLength: 8)
                    Text(childrenPreview(children))
                        .font(.system(size: 12.5)).foregroundStyle(hintText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(chevTint)
                }
                .padding(.horizontal, 16)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { if !isLast { hairline.frame(height: 1) } }
        } else if let instruction = node.instruction {
            Button {
                model.onPick(model.fill(instruction), node.id)
                dismiss()
            } label: {
                HStack {
                    Text(node.label).font(.system(size: 15.5)).foregroundStyle(ink)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { if !isLast { hairline.frame(height: 1) } }
        }
    }

    private func localRow(_ row: LongpressLocalRow, isLast: Bool) -> some View {
        Button {
            row.action()
            dismiss()
        } label: {
            HStack(spacing: 11) {
                Text(row.label).font(.system(size: 15.5)).foregroundStyle(ink)
                Spacer(minLength: 8)
                Image(systemName: row.systemImage)
                    .font(.system(size: 14)).foregroundStyle(backInk)
            }
            .padding(.horizontal, 16)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if !isLast { hairline.frame(height: 1) } }
    }

    private func backRow(_ node: UIMenuNode) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { openSubmenu = nil }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(backInk)
                Text(node.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(backInk)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: backRowHeight)
            .background(thickSep)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { backSep.frame(height: 1) }
    }

    private func childrenPreview(_ children: [UIMenuNode]) -> String {
        let labels = children.map(\.label)
        let head = labels.prefix(2).joined(separator: " · ")
        return labels.count > 2 ? head + "…" : head
    }
}

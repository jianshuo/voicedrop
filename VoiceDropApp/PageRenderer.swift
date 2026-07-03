import SwiftUI

// MARK: - 纯映射（白名单 token → SwiftUI 值）

extension PageColorToken {
    var color: Color {
        switch self {
        case .ink: Theme.ink
        case .secondary: Theme.secondary
        case .faint: Theme.faint
        case .accent: Theme.accent
        case .recordRed: Theme.recordRed
        case .greenDone: Theme.greenDone
        case .amberPending: Theme.amberPending
        }
    }
}
extension PageWeight {
    var swiftUI: Font.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
}
extension PageAlign {
    var horizontal: HorizontalAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
    var frameAlignment: Alignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
    var textAlignment: TextAlignment { switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing } }
}

// MARK: - 渲染上下文（embed 桥 + 动作回调）

struct PageContext {
    let articleList: AnyView
    let communityFeed: AnyView
    let recordButton: AnyView
    let notePlaceholder: AnyView
    let loadPhoto: (String) async -> Data?
    let onTap: (PageAction) -> Void
}

// MARK: - 递归渲染器

struct PageRenderer: View {
    let node: PageNode
    let ctx: PageContext
    var body: some View { Self.render(node, ctx) }

    @MainActor static func render(_ n: PageNode, _ ctx: PageContext) -> AnyView {
        switch n {
        case let .vstack(spacing, padding, align, children):
            return AnyView(VStack(alignment: align.horizontal, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            }.padding(padding).frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .hstack(spacing, padding, align, children):
            return AnyView(HStack(spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            }.padding(padding).frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .grid(columns, spacing, children):
            let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            return AnyView(LazyVGrid(columns: cols, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, c in render(c, ctx) }
            })

        case let .spacer(size):
            if let size { return AnyView(Spacer().frame(height: size)) }
            return AnyView(Spacer())

        case let .text(value, size, weight, color, align):
            return AnyView(Text(value)
                .font(.system(size: size, weight: weight.swiftUI))
                .foregroundStyle(color.color)
                .multilineTextAlignment(align.textAlignment)
                .frame(maxWidth: .infinity, alignment: align.frameAlignment))

        case let .image(source, aspect, corner):
            return AnyView(PageImage(source: source, aspect: aspect, corner: corner, loadPhoto: ctx.loadPhoto))

        case let .card(title, subtitle, icon, tint, tap):
            return AnyView(Button { ctx.onTap(tap) } label: {
                HStack(spacing: 13) {
                    if let icon {
                        RoundedRectangle(cornerRadius: Theme.R.card).fill(tint.color.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay(Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint.color))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
                }
                .padding(.vertical, 14).padding(.horizontal, 15)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
                .cardChromeShadow()
            }.buttonStyle(.plain))

        case let .embed(block):
            switch block {
            case .articleList: return ctx.articleList
            case .communityFeed: return ctx.communityFeed
            case .recordButton: return ctx.recordButton
            case .notePlaceholder: return ctx.notePlaceholder
            }

        case .unknown:
            return AnyView(EmptyView())
        }
    }
}

/// `image` 节点：`asset:<name>` 用 bundle 图，`photo:<relKey>` 通过 ctx.loadPhoto 异步拉。
private struct PageImage: View {
    let source: String
    let aspect: Double?
    let corner: Double
    let loadPhoto: (String) async -> Data?
    @State private var data: Data?

    var body: some View {
        Group {
            if source.hasPrefix("asset:") {
                Image(String(source.dropFirst("asset:".count))).resizable().scaledToFill()
            } else if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.tileNeutral)
            }
        }
        .aspectRatio(aspect ?? 1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task {
            guard source.hasPrefix("photo:"), data == nil else { return }
            data = await loadPhoto(String(source.dropFirst("photo:".count)))
        }
    }
}

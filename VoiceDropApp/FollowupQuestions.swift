import SwiftUI
import Observation

// 追问（follow-up questions）：成文后 AI 针对文章最薄处追问 1–3 题。缺省收起——
// 只在原「按住 说话 修改」条右侧多一个星标按钮；点开后追问信息（题号/跳过/
// 问题/进度）把原 push-to-talk 包裹起来，按住的还是原来那个条，松手立刻按
// 普通指令发出（走现有编辑队列 UI），没有专门的等待态。
// 问题本体是服务端 doc 顶层 sidecar（ArticleDoc.questions），不进正文、不进版本。

/// 追问的页面状态机。视图注入 `patch`（状态回写服务器，fire-and-forget）。
/// 回答就是一条普通编辑指令——发出的那一刻标 answered 并翻题；织入落地后的
/// 正文高亮走成文页统一的编辑落地 diff（BodyDiff），这里不再管。
@MainActor
@Observable
final class FollowupState {
    enum Sheet { case expanded, collapsed, dismissed }

    private(set) var all: [FollowupQuestion] = []
    var sheet: Sheet = .dismissed
    var currentId: String?

    var patch: ((String, String) -> Void)?     // (questionId, status) → PATCH

    private static let maxAgeMs: Double = 7 * 24 * 3600 * 1000   // 7 天未答自动消失

    /// doc 加载/重挖后同步。缺省收起：有未答题只亮星标，绝不自动铺开。
    func load(_ doc: ArticleDoc?) {
        let now = Date().timeIntervalSince1970 * 1000
        all = (doc?.questions ?? []).filter { q in
            guard let t = q.createdAt else { return true }
            return now - t < Self.maxAgeMs
        }
        currentId = all.first { $0.status == "pending" }?.id
        sheet = all.contains { $0.status == "pending" } ? .collapsed : .dismissed
    }

    /// 编辑落地（onUpdate）带回的 doc 也可能带来新追问（语音「再追问我几个」→
    /// 服务端 add_followups 追加）。以服务端为基线合并，但本地已推进的状态
    /// （answered/skipped 的 PATCH 可能还在路上）不回退；出现新的未答题且整组
    /// 已收场时，重新亮出星标（不自动铺开）。
    func merge(_ doc: ArticleDoc?) {
        guard let doc else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let localStatus = Dictionary(all.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        all = (doc.questions ?? []).filter { q in
            guard let t = q.createdAt else { return true }
            return now - t < Self.maxAgeMs
        }.map { q in
            var q = q
            if q.status == "pending", let s = localStatus[q.id], s != "pending" { q.status = s }
            return q
        }
        let hasPending = all.contains { $0.status == "pending" }
        if currentId == nil { currentId = all.first { $0.status == "pending" }?.id }
        if hasPending, sheet == .dismissed { sheet = .collapsed }
        if !hasPending, sheet != .dismissed {
            withAnimation(.easeInOut(duration: 0.25)) { sheet = .dismissed }
        }
    }

    // ── 每篇文章各自的题组 ─────────────────────────────────────────────────────
    func questions(for articleIndex: Int) -> [FollowupQuestion] {
        all.filter { ($0.articleIndex ?? 0) == articleIndex }
    }
    func pendingCount(for articleIndex: Int) -> Int {
        questions(for: articleIndex).filter { $0.status == "pending" }.count
    }
    func current(for articleIndex: Int) -> FollowupQuestion? {
        let qs = questions(for: articleIndex)
        if let id = currentId, let q = qs.first(where: { $0.id == id && $0.status == "pending" }) { return q }
        return qs.first { $0.status == "pending" }
    }
    /// 「追问 N/M」的 N（当前题在本篇题组里的序号，1-based）。
    func ordinal(of q: FollowupQuestion, in articleIndex: Int) -> Int {
        (questions(for: articleIndex).firstIndex { $0.id == q.id } ?? 0) + 1
    }

    // ── 动作 ──────────────────────────────────────────────────────────────────
    /// 跳过当前题：进度段保持灰色，翻下一题；没有下一题就整个收掉。
    func skip(articleIndex: Int) {
        guard let q = current(for: articleIndex) else { return }
        setStatus(q.id, "skipped")
        advance(articleIndex: articleIndex)
    }

    /// 口述回答已作为普通指令发出：当场标 answered、翻题。之后的进展就是普通
    /// 发信息 UI（队列气泡/正在改），织入段落的高亮由统一的编辑落地 diff 负责。
    func answerSent(_ q: FollowupQuestion, articleIndex: Int) {
        setStatus(q.id, "answered")
        advance(articleIndex: articleIndex)
    }

    private func setStatus(_ id: String, _ status: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].status = status
        patch?(id, status)
    }

    private func advance(articleIndex: Int) {
        if let next = questions(for: articleIndex).first(where: { $0.status == "pending" }) {
            currentId = next.id
            return
        }
        currentId = nil
        // 全部答完或全部跳过 → 包裹收掉、星标移除，回到普通说话条。
        withAnimation(.easeInOut(duration: 0.25)) { sheet = .dismissed }
    }

}

// ── 正文 diff：编辑落地后「哪些行变了」──────────────────────────────────────────
// 语音修改、追问织入、插图……一切经 onUpdate 落地的编辑共用：新正文里内容在旧
// 正文中不存在的行 = 变动行，荧光高亮几秒。按内容集合比（不按位置），行的插入/
// 删除引起的整体位移不会误报；删除类操作没有落点，自然不高亮。
enum BodyDiff {
    /// 返回新正文里的变动行号集合。行号 = 非空 trimmed 行的连续序号
    /// （照片标记也占号），与成文页 bodyRows 的第N行一致。
    static func changedRows(old: String, new: String) -> Set<Int> {
        func rows(_ s: String) -> [String] {
            s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let oldSet = Set(rows(old))
        var out = Set<Int>()
        for (i, row) in rows(new).enumerated() where !oldSet.contains(row) {
            out.insert(i + 1)
        }
        return out
    }
}

// ── 展开态：追问信息把原 push-to-talk 包裹起来 ─────────────────────────────────
// pill 由 PushToTalkBar 原样传入——按住它说话就是回答，手势/队列/转写气泡全是
// 原来那套。这里只负责裹一层卡片：把手 + 追问 N/M + 跳过 + 问题 + 进度条。

struct FollowupWrap: View {
    let state: FollowupState
    let articleIndex: Int
    let pill: AnyView
    let onCollapse: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let qs = state.questions(for: articleIndex)
        let q = state.current(for: articleIndex)
        VStack(alignment: .leading, spacing: 0) {
            // 拖动把手（36×4，下滑 = 收起回星标）
            RoundedRectangle(cornerRadius: 2).fill(Theme.fuHandle)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)

            if let q {
                HStack {
                    Text("追问 \(state.ordinal(of: q, in: articleIndex))/\(qs.count)")
                        .font(.system(size: 12, weight: .bold)).kerning(1.5)
                        .foregroundStyle(Theme.fuAmber)
                    Spacer()
                    Button { state.skip(articleIndex: articleIndex) } label: {
                        Text("跳过").font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                            .padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)

                Text(q.text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.inkRead)
                    .lineSpacing(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                pill.padding(.top, 12)

                // 分段进度条：每题一段，绿=已答，橙=当前，灰=未答/跳过。
                // 段宽弹性（≤16pt）：题少时是设计稿的 16×4，题多（十几个以上）
                // 自动收窄挤进一行，绝不把卡片撑宽。
                HStack(spacing: 5) {
                    ForEach(qs) { seg in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(seg.status == "answered" ? Theme.fuGreen
                                  : (seg.id == q.id ? Theme.accent : Theme.fuBorder))
                            .frame(height: 4)
                            .frame(minWidth: 3, maxWidth: 16)
                    }
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .background(Theme.fuCardBG, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.fuBorder, lineWidth: 1))
        .shadow(color: Color(.sRGB, red: 60/255, green: 48/255, blue: 30/255, opacity: 0.14), radius: 15, x: 0, y: 10)
        .offset(y: max(dragOffset, 0))
        .gesture(
            DragGesture()
                .onChanged { v in dragOffset = v.translation.height }
                .onEnded { v in
                    if v.translation.height > 40 { dragOffset = 0; onCollapse() }
                    else { withAnimation(.spring(duration: 0.3)) { dragOffset = 0 } }
                }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// ── 收起态：说话条右端的星标按钮 ────────────────────────────────────────────────

struct FollowupStarButton: View {
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                RoundedRectangle(cornerRadius: 8).stroke(Theme.fuStarBorder, lineWidth: 1)
                FourPointStar()
                    .stroke(Theme.fuStarStroke, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    .frame(width: 20, height: 20)
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if remaining > 0 {
                    Text("\(remaining)")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
    }
}

/// 四角星（sparkle 形）：四段二次贝塞尔往中心收腰。
struct FourPointStar: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let top = CGPoint(x: r.midX, y: r.minY)
        let right = CGPoint(x: r.maxX, y: r.midY)
        let bottom = CGPoint(x: r.midX, y: r.maxY)
        let left = CGPoint(x: r.minX, y: r.midY)
        var p = Path()
        p.move(to: top)
        p.addQuadCurve(to: right, control: c)
        p.addQuadCurve(to: bottom, control: c)
        p.addQuadCurve(to: left, control: c)
        p.addQuadCurve(to: top, control: c)
        p.closeSubpath()
        return p
    }
}

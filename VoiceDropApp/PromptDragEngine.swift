import Foundation
import CoreGraphics

// Prompt Manager 第 6 轮拖拽（6a/6b，Task 1）：纯逻辑落点判定引擎，不 import SwiftUI——只认
// Foundation/CoreGraphics，方便在 VoiceDropTests 里直接喂手指 Y 坐标断言，不用起真实视图树。
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-drag-6a6d.md Task 1（6a/6b）；
// 6c（folder 张口悬停）/6d（展开/拖出落点区）留给 Task 2，`DropTarget` 已经把
// `.intoGroup`/`.outOfGroup` 两个 case 都算好了，Task 2 只是给它们接 UI。
//
// **数据流**：PromptManagerView 编辑态用 PreferenceKey 把每一行当前的屏幕帧收集进
// `[RowFrame]`；手指拖着 ≡ 手柄移动时，每一帧把 (fingerY, rows, draggedID, draggedKind, draft)
// 丢给 `dropIndex`，纯函数算出这一刻该落在哪；View 只管照着结果画缝隙/张口，松手时把同一个
// `DropTarget` 喂给 `apply` 落地成新树（内部委托 `PromptLogic.moving*` 系列，Task 7 已测）。
//
// **两级封顶（folder 不能拖进 folder）在 apply 里兜底，dropIndex 不特判**：dropIndex 面对
// "拖的是一个 folder、手指悬停在另一个 folder 标题上"，本来就不产出 `.intoGroup`（见
// dropIndex 内注释——落到顶层重排分支，这正是设计稿"两级封顶不高亮不接受"的几何落地）；
// `apply` 仍然独立防一层——就算 View 层不小心拼出一个两个 folder 的 `.intoGroup`，也不会
// 落地（`PromptLogic.movingIntoGroup` 本来就在业务层拒绝，见其文档注释）。两处独立防御，
// 互不依赖，任何一处以后改坏了另一处兜底。

/// 编辑态一行当前的屏幕帧——由 PromptManagerView 的 PreferenceKey 收集，喂给 `PromptDragEngine`。
struct RowFrame: Equatable {
    enum Kind: Equatable {
        case action
        case groupTitle
        case child(parent: String)
    }

    let id: String
    let frame: CGRect
    let kind: Kind
}

/// 落点归属的层级——顶层数组，还是某个 folder 的 children 数组。
enum Scope: Equatable {
    case topLevel
    case group(String)
}

/// 手指此刻的落点判定结果。
/// `.reorder` 的 `index` 是"排除被拖行本身之后，这一 scope 还剩几行、其中几行中点在
/// 手指上方"——即插入到该 scope 剩余行里的第几位；`apply` 负责把它换算成
/// `PromptLogic.moving`/`movingWithinGroup` 要的"移除前基准位"（SwiftUI onMove 语义）。
enum DropTarget: Equatable {
    case reorder(index: Int, scope: Scope)
    case intoGroup(id: String)
    case outOfGroup(parent: String)
    case none
}

enum PromptDragEngine {

    /// 手指 Y 坐标 → 这一刻的落点。纯几何判定，两级封顶等业务规则留给 `apply`。
    ///
    /// 判定顺序：
    /// 1. 手指落在某个 folder 标题帧内（且不是被拖行自己）——
    ///    - 拖的是组内行（`.child(parent:)`）且这个 folder 正是它自己的父组 → `.none`
    ///      （放回原组标题=无操作，避免"拖出来又立刻收回同一个组"这种抖动被当成一次移动）。
    ///    - 拖的是普通动作（`.action`）→ `.intoGroup(那个 folder 的 id)`。
    ///    - 拖的本身是个 folder（`.groupTitle`）→ 两级封顶，不产出 `.intoGroup`，往下走顶层
    ///      重排分支（folder 悬停在另一个 folder 标题上，几何上就是"顶层排到那个位置"）。
    /// 2. 拖的是组内行且手指越出该组的帧范围（该组标题帧 ∪ 该组当前渲染的所有子行帧的
    ///    并集 minY...maxY）→ `.outOfGroup(parent:)`。
    /// 3. 否则：在与被拖行同一 scope 的候选行（顶层行，或同组兄弟行；已排除被拖行自己）里，
    ///    数手指上方有几个候选行的中点——就是插入 index。
    ///
    /// `items` 目前的判定不需要用到（几何全从 `rows` 读出即可）——保留在签名里给 Task 2
    /// （folder 存在性等更细的业务判断）用，避免那时又要改一次签名。
    static func dropIndex(
        fingerY: CGFloat,
        rows: [RowFrame],
        draggedID: String,
        draggedKind: RowFrame.Kind,
        items: [PromptNode]
    ) -> DropTarget {
        if let hoveredTitle = rows.first(where: { row in
            guard case .groupTitle = row.kind, row.id != draggedID else { return false }
            return fingerY >= row.frame.minY && fingerY <= row.frame.maxY
        }) {
            switch draggedKind {
            case .child(let parent):
                if parent == hoveredTitle.id { return .none }
                return .intoGroup(id: hoveredTitle.id)
            case .action:
                return .intoGroup(id: hoveredTitle.id)
            case .groupTitle:
                break // 两级封顶：不产出 intoGroup，落到下面按顶层重排算
            }
        }

        if case .child(let parent) = draggedKind {
            let groupRows = rows.filter { row in
                switch row.kind {
                case .groupTitle: return row.id == parent
                case .child(let p): return p == parent
                case .action: return false
                }
            }
            guard let spanMinY = groupRows.map(\.frame.minY).min(),
                  let spanMaxY = groupRows.map(\.frame.maxY).max() else {
                return .none
            }
            if fingerY < spanMinY || fingerY > spanMaxY {
                return .outOfGroup(parent: parent)
            }
            let siblings = rows
                .filter { row in
                    if case .child(let p) = row.kind { return p == parent && row.id != draggedID }
                    return false
                }
                .sorted { $0.frame.midY < $1.frame.midY }
            let index = siblings.filter { $0.frame.midY < fingerY }.count
            return .reorder(index: index, scope: .group(parent))
        }

        let candidates = rows
            .filter { row in
                switch row.kind {
                case .action, .groupTitle: return row.id != draggedID
                case .child: return false
                }
            }
            .sorted { $0.frame.midY < $1.frame.midY }
        let index = candidates.filter { $0.frame.midY < fingerY }.count
        return .reorder(index: index, scope: .topLevel)
    }

    /// 落点 → 新树。全部委托给已测的 `PromptLogic.moving*` 系列；`.reorder` 的
    /// "排除自己之后的插入位置"需要换算成那几个函数要的 `toTop`/`toChild`
    /// （SwiftUI onMove 的"移除前基准位"语义，`moving` 内部再按位置关系减一次）。
    /// `.intoGroup` 且拖的是 group → nil（`PromptLogic.movingIntoGroup` 内部拒绝）；
    /// `.none` → nil。
    static func apply(_ target: DropTarget, draggedID: String, items: [PromptNode]) -> [PromptNode]? {
        switch target {
        case .none:
            return nil

        case .intoGroup(let groupID):
            return PromptLogic.movingIntoGroup(items, actionID: draggedID, groupID: groupID)

        case .outOfGroup(let parent):
            guard let groupIndex = items.firstIndex(where: { $0.id == parent && $0.type == "group" }) else { return nil }
            return PromptLogic.movingOutOfGroup(items, childID: draggedID, toTopIndex: groupIndex + 1)

        case .reorder(let index, let scope):
            switch scope {
            case .topLevel:
                guard let fromTop = items.firstIndex(where: { $0.id == draggedID }) else { return nil }
                let toTop = index + (index >= fromTop ? 1 : 0)
                return PromptLogic.moving(items, fromTop: fromTop, toTop: toTop)

            case .group(let groupID):
                guard let groupIndex = items.firstIndex(where: { $0.id == groupID && $0.type == "group" }),
                      let fromChild = items[groupIndex].children?.firstIndex(where: { $0.id == draggedID }) else { return nil }
                let toChild = index + (index >= fromChild ? 1 : 0)
                return PromptLogic.movingWithinGroup(items, groupID: groupID, fromChild: fromChild, toChild: toChild)
            }
        }
    }
}

import XCTest
@testable import VoiceDrop

// Prompt Manager 第 6 轮拖拽（6a/6b）—— Task 1：DragEngine 纯逻辑单测，TDD 先行（红→绿）。
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-drag-6a6d.md Task 1 Step 1。
//
// 固定 fixture：顶层 [A, G1{C1, C2}, B, G2{}]（G2 空组），行帧按 stackedRows 从 y=0
// 依次堆叠（行高固定 60/50，数值本身不重要，只要能算中点）。
final class PromptDragEngineTests: XCTestCase {

    // MARK: - Fixture

    private func makeItems() -> [PromptNode] {
        let c1 = PromptNode(id: "C1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"])
        let c2 = PromptNode(id: "C2", type: "action", label: "C2", origin: "user", prompt: "p", appliesTo: ["text"])
        let a = PromptNode(id: "A", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"])
        let b = PromptNode(id: "B", type: "action", label: "B", origin: "user", prompt: "p", appliesTo: ["text"])
        let g1 = PromptNode(id: "G1", type: "group", label: "G1", origin: "user", children: [c1, c2])
        let g2 = PromptNode(id: "G2", type: "group", label: "G2", origin: "user", children: [])
        return [a, g1, b, g2]
    }

    /// 顶层 [A(0-60), G1(60-120), C1(120-170), C2(170-220), B(220-280), G2(280-340)]——
    /// G1 展开渲染（子行紧跟标题行）。
    private func makeRows() -> [RowFrame] {
        stackedRows([
            ("A", 60, .action),
            ("G1", 60, .groupTitle),
            ("C1", 50, .child(parent: "G1")),
            ("C2", 50, .child(parent: "G1")),
            ("B", 60, .action),
            ("G2", 60, .groupTitle),
        ])
    }

    private func stackedRows(_ specs: [(id: String, height: CGFloat, kind: RowFrame.Kind)]) -> [RowFrame] {
        var y: CGFloat = 0
        var rows: [RowFrame] = []
        for spec in specs {
            rows.append(RowFrame(id: spec.id, frame: CGRect(x: 0, y: y, width: 320, height: spec.height), kind: spec.kind))
            y += spec.height
        }
        return rows
    }

    // MARK: - 顶层重排（含极端）

    func testTopLevelDragToVeryTopIsIndexZero() {
        let target = PromptDragEngine.dropIndex(fingerY: 5, rows: makeRows(), draggedID: "B", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .reorder(index: 0, scope: .topLevel))
    }

    func testTopLevelDragToVeryBottomIsCandidatesCount() {
        // 候选（排除 A 自己）= [G1, B, G2] —— 3 个，最底 index 应等于 3。
        let target = PromptDragEngine.dropIndex(fingerY: 1000, rows: makeRows(), draggedID: "A", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .reorder(index: 3, scope: .topLevel))
    }

    func testTopLevelDragToMiddleIndex() {
        // 候选（排除 A）= [G1(mid90), B(mid250), G2(mid310)]；fingerY=200 → 只有 G1 在上方 → index 1。
        let target = PromptDragEngine.dropIndex(fingerY: 200, rows: makeRows(), draggedID: "A", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .reorder(index: 1, scope: .topLevel))
    }

    func testApplyTopLevelReorderMovesActionRightAfterGroup() {
        let moved = PromptDragEngine.apply(.reorder(index: 1, scope: .topLevel), draggedID: "A", items: makeItems())
        XCTAssertEqual(moved?.map(\.id), ["G1", "A", "B", "G2"])
        // children 原样保留
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C1", "C2"])
    }

    func testApplyTopLevelDragGroupItselfReorders() {
        // 拖的是 G1 本身，落到最末尾（index = 候选数，排除 G1）。
        let items = makeItems()
        let target = PromptDragEngine.dropIndex(fingerY: 1000, rows: makeRows(), draggedID: "G1", draggedKind: .groupTitle, items: items)
        XCTAssertEqual(target, .reorder(index: 3, scope: .topLevel))
        let moved = PromptDragEngine.apply(target, draggedID: "G1", items: items)
        XCTAssertEqual(moved?.map(\.id), ["A", "B", "G2", "G1"])
    }

    // MARK: - 组内重排

    func testWithinGroupReorderMovesChildAfterSibling() {
        // 拖 C1，手指落在 C2 中点之后（span 60-220 内，200 > C2.midY=195）→ index 1。
        let target = PromptDragEngine.dropIndex(fingerY: 200, rows: makeRows(), draggedID: "C1", draggedKind: .child(parent: "G1"), items: makeItems())
        XCTAssertEqual(target, .reorder(index: 1, scope: .group("G1")))

        let moved = PromptDragEngine.apply(target, draggedID: "C1", items: makeItems())
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C2", "C1"])
    }

    func testWithinGroupDragToTopOfGroupIsIndexZero() {
        // 拖 C2 到组内最上方（span 内、C1 上方）。
        let target = PromptDragEngine.dropIndex(fingerY: 125, rows: makeRows(), draggedID: "C2", draggedKind: .child(parent: "G1"), items: makeItems())
        XCTAssertEqual(target, .reorder(index: 0, scope: .group("G1")))
        let moved = PromptDragEngine.apply(target, draggedID: "C2", items: makeItems())
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C2", "C1"])
    }

    // MARK: - 手指落 folder 标题帧 → intoGroup

    func testFingerOnGroupTitleProducesIntoGroupForTopLevelAction() {
        let target = PromptDragEngine.dropIndex(fingerY: 90, rows: makeRows(), draggedID: "A", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .intoGroup(id: "G1"))
    }

    func testApplyIntoGroupMovesActionToGroupChildrenEnd() {
        let moved = PromptDragEngine.apply(.intoGroup(id: "G1"), draggedID: "A", items: makeItems())
        XCTAssertEqual(moved?.map(\.id), ["G1", "B", "G2"])
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C1", "C2", "A"])
    }

    func testFingerOnEmptyGroupTitleProducesIntoGroup() {
        let target = PromptDragEngine.dropIndex(fingerY: 310, rows: makeRows(), draggedID: "A", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .intoGroup(id: "G2"))
        let moved = PromptDragEngine.apply(target, draggedID: "A", items: makeItems())
        XCTAssertEqual(moved?.first(where: { $0.id == "G2" })?.children?.map(\.id), ["A"])
    }

    // MARK: - 拖 group 悬停 group：dropIndex 不产出 intoGroup + apply 独立拒绝（两级封顶）

    func testDraggedGroupHoveringAnotherGroupTitleDoesNotProduceIntoGroup() {
        // 拖的是 G1，手指落在 G2 的标题帧上——两级封顶：不应该是 .intoGroup，落到顶层重排。
        let target = PromptDragEngine.dropIndex(fingerY: 310, rows: makeRows(), draggedID: "G1", draggedKind: .groupTitle, items: makeItems())
        if case .intoGroup = target {
            XCTFail("dragging a group onto another group's title must never produce .intoGroup, got \(target)")
        }
    }

    func testApplyIntoGroupWithGroupDraggedReturnsNilRegardlessOfHowTargetWasBuilt() {
        // apply 独立防一层：就算 View 层真拼出一个 .intoGroup(group, group) 也不落地。
        let moved = PromptDragEngine.apply(.intoGroup(id: "G2"), draggedID: "G1", items: makeItems())
        XCTAssertNil(moved)
    }

    // MARK: - 组内行拖出组边界 → outOfGroup

    func testChildDraggedBelowGroupSpanProducesOutOfGroup() {
        let target = PromptDragEngine.dropIndex(fingerY: 250, rows: makeRows(), draggedID: "C1", draggedKind: .child(parent: "G1"), items: makeItems())
        XCTAssertEqual(target, .outOfGroup(parent: "G1"))
    }

    func testChildDraggedAboveGroupSpanProducesOutOfGroup() {
        let target = PromptDragEngine.dropIndex(fingerY: 20, rows: makeRows(), draggedID: "C1", draggedKind: .child(parent: "G1"), items: makeItems())
        XCTAssertEqual(target, .outOfGroup(parent: "G1"))
    }

    func testApplyOutOfGroupInsertsRightAfterParentGroupAtTopLevel() {
        let moved = PromptDragEngine.apply(.outOfGroup(parent: "G1"), draggedID: "C1", items: makeItems())
        XCTAssertEqual(moved?.map(\.id), ["A", "G1", "C1", "B", "G2"])
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C2"])
    }

    // MARK: - 组内行拖到自己组的标题 = no-op

    func testChildDraggedOntoOwnGroupTitleIsNoOp() {
        let target = PromptDragEngine.dropIndex(fingerY: 90, rows: makeRows(), draggedID: "C1", draggedKind: .child(parent: "G1"), items: makeItems())
        XCTAssertEqual(target, .none)
        XCTAssertNil(PromptDragEngine.apply(target, draggedID: "C1", items: makeItems()))
    }

    // MARK: - 单行组：拖动自己怎么落都是原地不动

    func testSingleRowGroupDragStaysInPlace() {
        var items = makeItems()
        items[1].children = [items[1].children![0]] // G1 只剩 C1
        let rows = stackedRows([
            ("A", 60, .action),
            ("G1", 60, .groupTitle),
            ("C1", 50, .child(parent: "G1")),
            ("B", 60, .action),
            ("G2", 60, .groupTitle),
        ])
        let target = PromptDragEngine.dropIndex(fingerY: 145, rows: rows, draggedID: "C1", draggedKind: .child(parent: "G1"), items: items)
        XCTAssertEqual(target, .reorder(index: 0, scope: .group("G1")))
        let moved = PromptDragEngine.apply(target, draggedID: "C1", items: items)
        XCTAssertEqual(moved?.first(where: { $0.id == "G1" })?.children?.map(\.id), ["C1"])
    }

    // MARK: - apply 后 flattenIDs 无重复无丢失

    func testApplySequencePreservesFlattenIDsUniquenessAndCompleteness() {
        let original = makeItems()
        let before = PromptLogic.flattenIDs(original)

        var current = original
        let steps: [DropTarget] = [
            .reorder(index: 1, scope: .topLevel),   // 拖 A 到 G1 之后
        ]
        for step in steps {
            guard let moved = PromptDragEngine.apply(step, draggedID: "A", items: current) else {
                XCTFail("apply unexpectedly returned nil for \(step)")
                return
            }
            current = moved
        }

        // 再拖一次 B 到 G1 里
        guard let afterIntoGroup = PromptDragEngine.apply(.intoGroup(id: "G1"), draggedID: "B", items: current) else {
            XCTFail("intoGroup apply returned nil")
            return
        }
        current = afterIntoGroup

        // 再把 C2 拖出 G1
        guard let afterOutOfGroup = PromptDragEngine.apply(.outOfGroup(parent: "G1"), draggedID: "C2", items: current) else {
            XCTFail("outOfGroup apply returned nil")
            return
        }
        current = afterOutOfGroup

        let after = PromptLogic.flattenIDs(current)
        XCTAssertEqual(Set(before), Set(after), "no id should be lost or duplicated across a sequence of drag operations")
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(Set(after).count, after.count, "flattenIDs must contain no duplicates after apply")
    }

    // MARK: - dropIndex 对不存在的 draggedID 也要给出确定性结果（不崩）

    func testDropIndexWithUnknownDraggedIDStillDeterministic() {
        let target = PromptDragEngine.dropIndex(fingerY: 10, rows: makeRows(), draggedID: "ghost", draggedKind: .action, items: makeItems())
        XCTAssertEqual(target, .reorder(index: 0, scope: .topLevel))
    }
}

import SwiftUI

// Prompt Manager Phase 2（iOS）—— 3c 底部 sheet：新建动作 / 新建分组。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 5
//
// 这个 sheet 本身不碰 store：两条路都只是把「要新建的东西」交给调用方
// （PromptManagerView）决定怎么处理——「新建动作」交回一份还没进 store.items 的草稿
// PromptNode，由调用方关掉 sheet 后 push 到 PromptEditView（CREATE 模式，保存时才真的
// append + PUT）；「新建分组」交回名字字符串，调用方直接 `store.add(...)`（分组不需要
// 编辑页，只有名字）。

struct PromptNewSheet: View {
    var onNewAction: (PromptNode) -> Void
    var onNewGroup: (String) -> Void

    @State private var showGroupAlert = false
    @State private var groupName = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("新建").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 6)

            VStack(spacing: 13) {
                optionRow(tileBG: Color(hex: "EAF1EC"), symbol: "pencil", tileFG: Theme.greenDone,
                          title: String(localized: "新建动作"), subtitle: String(localized: "一条提示词指令")) {
                    let draft = PromptNode(id: PromptLogic.newUserID(), type: "action", label: "",
                                            origin: "user", prompt: "", appliesTo: ["text", "image"])
                    onNewAction(draft)
                }
                optionRow(tileBG: Color(hex: "F1ECE3"), symbol: "folder", tileFG: Color(hex: "7A6E5C"),
                          title: String(localized: "新建分组"), subtitle: String(localized: "收纳几个动作，菜单里成二级子菜单")) {
                    groupName = ""
                    showGroupAlert = true
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .background(Theme.appBG.ignoresSafeArea())
        .alert(String(localized: "新建分组"), isPresented: $showGroupAlert) {
            TextField(String(localized: "分组名字"), text: $groupName)
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "创建")) {
                let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                onNewGroup(name)
            }
        }
    }

    private func optionRow(tileBG: Color, symbol: String, tileFG: Color, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tileBG)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tileFG))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                settingsChevron
            }
            .padding(15)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderChrome, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

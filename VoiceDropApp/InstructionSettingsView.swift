import SwiftUI
import Observation

// 设置 → AI 指令：逐条自定义长按菜单背后的指令（图片风格 / 改写 / 公众号题图…）。
// 服务端真源 GET/PUT /agent/ui-config/custom（users/<sub>/ui-config.json 稀疏覆盖）：
// 指令/名称留空 = 用缺省值（内置 ← 全局调优版）；「在菜单中隐藏」把该条从长按菜单
// 里拿掉（可随时恢复）。保存后刷新 UIConfigStore，长按菜单立即生效。

struct InstructionItem: Identifiable, Decodable {
    let id: String
    let label: String
    let defaultText: String
    var override: String?
    var customLabel: String?
    var hidden: Bool

    /// 菜单实际会用的文本 / 名称。
    var effective: String { override ?? defaultText }
    var effectiveLabel: String { customLabel ?? label }
    var isCustomized: Bool { override != nil || customLabel != nil }

    enum CodingKeys: String, CodingKey { case id, label, defaultText = "default", override, customLabel, hidden }
}

@MainActor
@Observable
final class InstructionCustomStore {
    var items: [InstructionItem] = []
    var loading = false
    var error: String?

    private var token: String { AuthStore.shared.bearer }

    func load() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        loading = true; error = nil
        defer { loading = false }
        struct R: Decodable { let items: [InstructionItem] }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("ui-config/custom"))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { error = "加载失败"; return }
            items = try JSONDecoder().decode(R.self, from: data).items
        } catch { self.error = "加载失败" }
    }

    /// 单条全量状态：instruction / label 空串 = 恢复缺省；hidden = 从菜单隐藏。
    func save(id: String, instruction: String, label: String, hidden: Bool) async -> Bool {
        guard !token.isEmpty else { return false }
        struct P: Encodable { let id: String; let instruction: String; let label: String; let hidden: Bool }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("ui-config/custom"))
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(P(id: id, instruction: instruction, label: label, hidden: hidden))
        guard let (_, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return false }
        if let i = items.firstIndex(where: { $0.id == id }) {
            let trimmedIns = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            items[i].override = trimmedIns.isEmpty ? nil : instruction
            items[i].customLabel = trimmedLabel.isEmpty ? nil : String(trimmedLabel.prefix(20))
            items[i].hidden = hidden
        }
        // 长按菜单吃的是合并后的 ui-config——保存后立刻刷新，本次会话即生效。
        await UIConfigStore.shared.refresh()
        return true
    }
}

// MARK: - 列表页

struct InstructionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = InstructionCustomStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text("AI 指令").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("长按菜单里每个动作的名字和指令都可以改成你自己的说法。留空即恢复默认；不想要的可以从菜单里隐藏。")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 2)

                    if store.loading && store.items.isEmpty {
                        HStack { Spacer(); ProgressView().tint(Theme.accent).padding(.top, 40); Spacer() }
                    } else if let err = store.error, store.items.isEmpty {
                        Text(err).font(.system(size: 14)).foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                    } else {
                        SettingsCard {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { i, item in
                                NavigationLink { InstructionEditView(store: store, itemID: item.id) } label: {
                                    SettingsRow(tileBG: item.hidden ? Theme.tileNeutral : (item.isCustomized ? Theme.accentSoft : Theme.tileNeutral),
                                                symbol: item.hidden ? "eye.slash" : (item.isCustomized ? "wand.and.stars" : "text.quote"),
                                                tileFG: item.hidden ? Theme.faint : (item.isCustomized ? Theme.accent : Theme.secondary),
                                                title: rowTitle(item),
                                                subtitle: item.hidden ? "已从菜单隐藏" : String(item.effective.prefix(40))) {
                                        HStack(spacing: 8) {
                                            if !item.hidden && item.isCustomized {
                                                Text("已自定义").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                                            }
                                            settingsChevron
                                        }
                                    }
                                    .opacity(item.hidden ? 0.55 : 1)
                                }.buttonStyle(.plain)
                                if i < store.items.count - 1 { settingsRowDivider }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.load() }
    }

    /// 改过名的行显示「新名字（原名）」，一眼看出对应关系。
    private func rowTitle(_ item: InstructionItem) -> String {
        guard let custom = item.customLabel else { return item.label }
        let parts = item.label.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let prefix = parts.count > 1 ? parts.dropLast().joined(separator: " · ") + " · " : ""
        return "\(prefix)\(custom)"
    }
}

// MARK: - 编辑页

struct InstructionEditView: View {
    @Environment(\.dismiss) private var dismiss
    let store: InstructionCustomStore
    let itemID: String

    @State private var draft = ""
    @State private var nameDraft = ""
    @State private var hiddenDraft = false
    @State private var saving = false
    @State private var failed = false
    @FocusState private var editorFocused: Bool

    private var item: InstructionItem? { store.items.first { $0.id == itemID } }
    private var dirty: Bool {
        draft != (item?.override ?? "") || nameDraft != (item?.customLabel ?? "") || hiddenDraft != (item?.hidden ?? false)
    }
    /// 默认名（label 的最后一段，去掉父菜单前缀）。
    private var defaultName: String {
        guard let l = item?.label else { return "" }
        return l.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? l
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text(item?.label ?? "指令").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                Button {
                    Task {
                        saving = true; failed = false
                        let ok = await store.save(id: itemID, instruction: draft, label: nameDraft, hidden: hiddenDraft)
                        saving = false
                        if ok { dismiss() } else { failed = true }
                    }
                } label: {
                    if saving { ProgressView().tint(.white).frame(width: 52, height: 34) }
                    else { Text("保存").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 52, height: 34) }
                }
                .background(dirty ? Theme.accent : Theme.faint, in: RoundedRectangle(cornerRadius: 9))
                .disabled(!dirty || saving)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if failed {
                        Text("保存失败，请重试").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("菜单里的名字").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        TextField(defaultName, text: $nameDraft)
                            .font(.system(size: 15)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).frame(height: 44)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        Text("留空 = 使用默认名「\(defaultName)」").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("我的指令").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        TextEditor(text: $draft)
                            .font(.system(size: 15)).foregroundStyle(Theme.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                            .padding(10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .focused($editorFocused)
                        HStack {
                            Text("留空 = 使用默认指令").font(.system(size: 12)).foregroundStyle(Theme.faint)
                            Spacer()
                            if !draft.isEmpty || !nameDraft.isEmpty {
                                Button {
                                    draft = ""; nameDraft = ""
                                } label: {
                                    Text("恢复默认").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("在菜单中隐藏").font(.system(size: 15)).foregroundStyle(Theme.ink)
                            Text("长按菜单里不再出现这一项，可随时恢复").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        Toggle("", isOn: $hiddenDraft).labelsHidden().tint(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认指令").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                        Text(item?.defaultText ?? "")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.tileNeutral.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        if draft.isEmpty {
                            Text("当前生效的就是默认指令。想微调可以长按上方文本框，把默认指令粘贴进去再改。")
                                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            draft = item?.override ?? ""
            nameDraft = item?.customLabel ?? ""
            hiddenDraft = item?.hidden ?? false
        }
    }
}

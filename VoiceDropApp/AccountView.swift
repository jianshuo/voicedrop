import SwiftUI
import UIKit

/// 账户详情 — the anonymous identity, its keys, data counts, and reset.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore()
    @State private var idCopied = false
    @State private var tokenCopied = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String? = nil
    @State private var showTokenInput = false
    @State private var tokenInput = ""
    @State private var tokenInputError = false

    private var auth: AuthStore { AuthStore.shared }
    private var recordingCount: Int { store.recordings.count }
    private var minedCount: Int { store.recordings.filter(\.hasArticles).count }

    private var maskedToken: String {
        let t = auth.bearer
        guard t.count > 16 else { return t }
        return "\(t.prefix(10))••••••\(t.suffix(4))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text("账户").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identityCard
                    group(String(localized: "数据")) { dataCard }
                    group(String(localized: "转移与同步")) { transferCard }
                    group(String(localized: "账户管理")) { deleteCard }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Analytics.screen("账户") }
        .task { await store.load() }
        .confirmationDialog("永久删除账户？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { Task { await deleteAccount() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除你的全部数据：云端录音、文章、照片、设置、社区分享和 Apple 登录绑定，本机数据也会清空。此操作不可恢复。")
        }
        .alert("删除失败", isPresented: .init(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Theme.R.tile).fill(Theme.inkTile).frame(width: 46, height: 46)
                    .overlay(Image(systemName: "checkmark.shield.fill").font(.system(size: 20)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("账户").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("在这台设备上自动生成，不需要用户名或密码。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle().fill(Theme.dividerInCard).frame(height: 1)

            keyField(label: String(localized: "你的 ID"), value: auth.anonId, masked: false, copied: idCopied) {
                UIPasteboard.general.string = auth.anonId
                idCopied = true
                Task { try? await Task.sleep(nanoseconds: 1_800_000_000); idCopied = false }
            }

            keyField(label: String(localized: "访问令牌"), value: maskedToken, masked: true, copied: tokenCopied) {
                UIPasteboard.general.string = auth.bearer
                tokenCopied = true
                Task { try? await Task.sleep(nanoseconds: 1_800_000_000); tokenCopied = false }
            }

            // Adopt an existing account by pasting its anon_… token (copied from
            // the other device's 账户 page). Switches this device to that account.
            Button { tokenInput = ""; showTokenInput = true } label: {
                Label("输入访问令牌（切换到已有账号）", systemImage: "key.horizontal")
                    .font(.system(size: 14)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .alert("输入访问令牌", isPresented: $showTokenInput) {
                TextField("anon_…", text: $tokenInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("切换") { adoptPastedToken() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("粘贴另一台设备「账户 → 访问令牌」复制的 anon_ 令牌，本机将切换到该账号（当前身份会被替换）。")
            }
            .alert("令牌无效", isPresented: $tokenInputError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请粘贴以 anon_ 开头的完整访问令牌。")
            }

            Rectangle().fill(Theme.dividerInCard).frame(height: 1)

            if auth.isAuthenticated {
                HStack {
                    Label("已用 Apple 登录", systemImage: "applelogo")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("退出登录") { auth.signOut() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await auth.signInWithApple() }
                } label: {
                    Label("用 Apple 登录（同步设备 · 参与社区）", systemImage: "applelogo")
                        .font(.system(size: 15)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
    }

    private func keyField(label: String, value: String, masked: Bool, copied: Bool, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.sectionLabel)
            HStack(spacing: 10) {
                Text(value).font(.system(size: masked ? 14 : 15, design: .monospaced))
                    .foregroundStyle(masked ? Theme.secondary : Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        if masked { Text(copied ? String(localized: "已复制") : String(localized: "复制")).font(.system(size: 13, weight: .semibold)) }
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 11).padding(.horizontal, 13)
            .background(Theme.appBG, in: RoundedRectangle(cornerRadius: Theme.R.input))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }

    // MARK: Data

    private var dataCard: some View {
        SettingsCard {
            dataRow(String(localized: "录音"), String(localized: "\(recordingCount) 条"), trailingChevron: false)
            settingsRowDivider
            dataRow(String(localized: "成文"), String(localized: "\(minedCount) 篇"), trailingChevron: false)
        }
    }

    private func dataRow(_ title: String, _ value: String, trailingChevron: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            if trailingChevron { settingsChevron }
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
    }

    // MARK: Transfer / sync

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                HStack {
                    Text("iCloud 钥匙串同步").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Theme.greenDone).frame(width: 6, height: 6)
                        Text("已开启").font(.system(size: 13)).foregroundStyle(Theme.greenDone)
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 15)
            }
            Text("换新机时，登录同一 Apple 账户即可自动恢复；ID 随 iCloud 钥匙串备份。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }


    /// Paste-in login: adopt the token, refresh everything this view shows,
    /// and tell the library to reload (same signal the device-link flow sends).
    private func adoptPastedToken() {
        let t = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("anon_"), t.count >= 20 else { tokenInputError = true; return }
        auth.adoptToken(t)
        NotificationCenter.default.post(name: .vdDidAdoptAccount, object: nil)
        Task { await store.load() }
    }

    // MARK: Delete account (Apple 5.1.1(v))

    /// In-app account deletion: the server erases everything under this user
    /// (recordings, articles, photos, settings, community posts, share links,
    /// Apple binding), then we wipe local state and mint a brand-new empty
    /// anonymous identity.
    private var deleteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                Button { showDeleteConfirm = true } label: {
                    HStack {
                        Text("删除账户").font(.system(size: 16)).foregroundStyle(Color(red: 1, green: 0.23, blue: 0.19))
                        Spacer()
                        if deleting { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, 14).padding(.horizontal, 15)
                }
                .buttonStyle(.plain)
                .disabled(deleting)
            }
            Text("永久删除云端与本机的全部数据（录音、文章、照片、设置、社区分享、Apple 登录绑定），不可恢复。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func deleteAccount() async {
        deleting = true
        defer { deleting = false }
        var req = URLRequest(url: API.filesBase.appending(path: "account").appending(path: "delete"))
        req.httpMethod = "POST"
        req.setBearer(auth.bearer)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else {
                deleteError = String(localized: "服务器返回 \(resp.httpStatusCode)，请稍后再试。")
                return
            }
        } catch {
            deleteError = error.localizedDescription
            return
        }
        // Server side is gone — wipe everything local, then start a fresh
        // empty identity so the app behaves like a brand-new install.
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
        DiskCache.wipe()   // Caches 里的快照（录音列表/文章 doc/feed/照片）也是「本机数据」，一并清
        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
        }
        auth.signOut()          // drop the Apple session JWT
        auth.resetAnonymous()   // brand-new anon token (also re-published to the Share Extension)
        dismiss()
    }

    @ViewBuilder private func group<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionLabel(label)
            content()
        }
    }
}

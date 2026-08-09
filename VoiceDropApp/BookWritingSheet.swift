import SwiftUI

// MARK: - 写书（实验功能）— 关于 → 实验功能 → 写书

/// 把一个词 / 一句话 / 一篇文章交给 lab.jianshuo.dev 上的常驻 Claude agent，
/// 用 wjs-voicedrop-writing-book skill 长成一本书：一个 agent 写大纲、每章一个
/// subagent 写正文、独立评审过稿后增量发布到公开书架 voicedrop.cn/books/。
///
/// 契约（2026-08-10 起 fire-and-forget）：`POST lab.jianshuo.dev/api/book`
/// `{seed}` + VoiceDrop 用户 bearer（服务端拿它去 jianshuo.dev whoami 验真，
/// App 零内置密钥；该路径豁免 Caddy basic_auth）。202 = 任务已在服务器后台
/// 开跑——**提交完就可以关 App**，10–30 分钟后书出现在公开书架。
/// 409 = 服务器正在写另一本（全局串行，1 核小机器）。
struct BookWritingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var seed = ""
    @State private var sending = false
    @State private var submitted = false
    @State private var errorText: String?
    @FocusState private var seedFocused: Bool

    private static let booksURL = URL(string: "https://voicedrop.cn/books/")!
    private static let bookAPI = URL(string: "https://lab.jianshuo.dev/api/book")!

    private var trimmedSeed: String { seed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !trimmedSeed.isEmpty && !sending && !submitted }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if submitted {
                        submittedSection
                    } else {
                        introSection
                        inputSection
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 30)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Button("关闭") { dismiss() }
                .font(.system(size: 16)).foregroundStyle(Theme.secondary)
            Spacer()
            Text("写书").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button(sending ? String(localized: "提交中…") : String(localized: "开写")) { start() }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(canStart ? Theme.accent : Theme.faint)
                .disabled(!canStart)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给一个词、一句话，或贴一整篇文章，AI 会把它长成一本书：先写大纲，再每章一个写手并行写正文（费曼式白话），独立评审过稿一章、发布一章。")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("点「开写」提交后就可以关掉 App——书在服务器上继续写，通常 10–30 分钟后出现在公开书架。")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                Link(destination: Self.booksURL) {
                    SettingsRow(tileBG: Theme.tileNeutral, symbol: "books.vertical", tileFG: Theme.secondary,
                                title: String(localized: "公开书架"), subtitle: String(localized: "voicedrop.cn/books · 已出版的书都在这")) { settingsChevron }
                }.buttonStyle(.plain)
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if seed.isEmpty {
                    Text("书的种子：一个词、一句话，或一整篇文章……")
                        .font(.system(size: 16)).foregroundStyle(Theme.faint)
                        .padding(.top, 22).padding(.leading, 20)
                }
                TextEditor(text: $seed)
                    .font(.system(size: 16)).foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .focused($seedFocused)
                    .padding(.vertical, 14).padding(.horizontal, 15)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.accent, lineWidth: 1.5))

            if let err = errorText {
                Text(err).font(.system(size: 13)).foregroundStyle(Theme.recordRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var submittedSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Theme.greenDone)
            Text("开始写了！").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("现在可以关掉 App。书通常 10–30 分钟写完，过稿一章、上架一章——过会儿去公开书架看。")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: Self.booksURL) {
                Text("打开公开书架")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.vertical, 12).padding(.horizontal, 24)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }

    private func start() {
        guard canStart else { return }
        seedFocused = false
        sending = true; errorText = nil
        Analytics.capture("写书发起")
        let seedText = trimmedSeed
        Task {
            defer { sending = false }
            var req = URLRequest(url: Self.bookAPI)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(AuthStore.shared.bearer)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["seed": seedText])
            req.timeoutInterval = 30
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
                case 202:
                    submitted = true
                    Analytics.capture("写书已受理")
                case 409:
                    errorText = String(localized: "服务器正在写另一本书，等它写完再来（通常 10–30 分钟）。")
                case 401:
                    errorText = String(localized: "身份校验没过，请稍后重试。")
                case let code:
                    errorText = String(localized: "服务器返回 \(code)，请稍后重试。")
                }
            } catch {
                errorText = String(localized: "没连上服务器：\(error.localizedDescription)")
            }
        }
    }
}

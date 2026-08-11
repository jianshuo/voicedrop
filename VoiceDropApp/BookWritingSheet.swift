import SwiftUI

// MARK: - 写书 — 「写书」tab 图书馆第一格（BooksShelfView）弹出

/// 把一个「中心思想」交给 lab.jianshuo.dev 上的常驻 Claude agent，用
/// wjs-voicedrop-writing-book skill 长成一本书：建筑师拆大纲、每章一个写手并行
/// 写正文（费曼式白话）、独立评审过稿一章发一章，增量上架到「写书」书架
/// （voicedrop.cn/books/）。**署名 = 设置里的「名字」**（lab 用提交者 bearer 拉
/// CLAUDE.json profile.name；没填就不署名）。
///
/// 契约（fire-and-forget + 计费制）：`POST lab.jianshuo.dev/api/book` `{seed}` +
/// 用户 bearer。lab 转手调 agent worker `/agent/usage/book-charge` 一口价扣
/// **320 算力**，扣成功即 202 开写——提交完就可以关 App。402 = 算力不足（带
/// need_suanli/suanli），401 = token 无效。
///
/// 2026-08-11 重设计：去掉公开书架入口（书架就是身后的 tab）；320 算力做成
/// 价签 hero + 实时余额；算力不够时给两条攒法（请朋友「加油」/ 邀请安装）——
/// 数字来自 `GET /agent/referral/link` 的 suanliFeedAuthor / suanliInviter 现价。
struct BookWritingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var seed = ""
    @State private var sending = false
    @State private var submitted = false
    @State private var errorText: String?
    @FocusState private var seedFocused: Bool

    // 价签与攒算力数据（进场拉一次；拉不到就只显示价目、CTA 交给服务端判）
    @State private var balance: Double?
    @State private var feedSuanli = 0      // 别人给我的文章加油一次 ≈ 得多少算力
    @State private var inviteSuanli = 0    // 邀请一人安装 ≈ 得多少算力
    @State private var inviteURL: URL?

    private static let bookAPI = URL(string: "https://lab.jianshuo.dev/api/book")!
    private static let price = 320   // 展示用价目；扣费真源在服务端（402 会带权威数字）

    private var trimmedSeed: String { seed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shortOf: Int? {
        guard let b = balance else { return nil }
        let gap = Double(Self.price) - b
        return gap > 0 ? Int(gap.rounded(.up)) : nil
    }
    private var canStart: Bool { !trimmedSeed.isEmpty && !sending && !submitted && shortOf == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if submitted {
                        submittedSection
                    } else {
                        priceHero
                        // 算力不够时，攒法紧跟价签——用户第一眼要的是「怎么办」。
                        if shortOf != nil { earnSection }
                        seedSection
                        pipelineSection
                        if let err = errorText {
                            Text(err).font(.system(size: 13)).foregroundStyle(Theme.recordRed)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 30)
            }
            if !submitted { bottomBar }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await loadNumbers() }
    }

    private var header: some View {
        HStack {
            Button("关闭") { dismiss() }
                .font(.system(size: 16)).foregroundStyle(Theme.secondary)
            Spacer()
            Text("写书").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Text("关闭").font(.system(size: 16)).hidden()   // 平衡布局，让标题居中
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    // MARK: 价签 hero — 320 算力顶格明示 + 实时余额

    private var priceHero: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 20)).foregroundStyle(Theme.amber)
                    Text("\(Self.price)").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("算力").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                Text("写一本书的价钱，提交时一次扣清")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.metaChrome)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let b = balance {
                    Text("\(Int(b.rounded()))")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(shortOf == nil ? Theme.greenDone : Theme.recordRed)
                    Text("你现在的算力").font(.system(size: 12.5)).foregroundStyle(Theme.metaChrome)
                } else {
                    ProgressView().tint(Theme.faint)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: Theme.R.primary))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Color(hex: "EBD9B8"), lineWidth: 1))
    }

    // MARK: 中心思想

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("中心思想").font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.sectionLabel)
            Text("一句话说清这本书要讲明白的那一个问题或主张。想法越聚焦，书越好看；也可以贴一整篇文章当种子。")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                if seed.isEmpty {
                    Text("比如：为什么一切都在变乱？\n或：钱不脏，是我一直躲着它。")
                        .font(.system(size: 16)).foregroundStyle(Theme.faint)
                        .padding(.top, 22).padding(.leading, 20)
                }
                TextEditor(text: $seed)
                    .font(.system(size: 16)).foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .focused($seedFocused)
                    .padding(.vertical, 14).padding(.horizontal, 15)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.accent, lineWidth: 1.5))
        }
    }

    // MARK: 怎么写成 — 流水线四步

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么写成").font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.sectionLabel)
            SettingsCard {
                pipelineRow("1", "拆大纲", "AI 建筑师把中心思想拆成一环扣一环的章节")
                settingsRowDivider
                pipelineRow("2", "并行写", "每章一个写手，费曼式大白话，名词当场讲人话")
                settingsRowDivider
                pipelineRow("3", "独立评审", "另一个 AI 只看成稿挑错，不过就打回重写")
                settingsRowDivider
                pipelineRow("4", "上你的架", "过一章发一章到「写书」书架，署你的名字（设置里的「名字」）")
            }
        }
    }

    private func pipelineRow(_ n: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 13) {
            Text(n).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.R.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    // MARK: 算力不够 — 两条攒法（数字 = 服务端现价）

    private var earnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("算力不够？").font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.sectionLabel)
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let gap = shortOf {
                        Text("还差 \(gap) 算力。两条来路：")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    earnRow(symbol: "hands.clap.fill",
                            title: feedSuanli > 0
                                ? String(localized: "请朋友给你的文章「加油」——一次约得 \(feedSuanli) 算力\(feedTimesHint)")
                                : String(localized: "请朋友给你的文章「加油」——作者每次都得算力"),
                            sub: String(localized: "把文章分享到 VD社区或发给朋友，读的人点「加油」你就进账"))
                    earnRow(symbol: "person.2.fill",
                            title: inviteSuanli > 0
                                ? String(localized: "邀请朋友装 VoiceDrop——装一个约得 \(inviteSuanli) 算力\(inviteTimesHint)")
                                : String(localized: "邀请朋友装 VoiceDrop——每装一个你都得算力"),
                            sub: String(localized: "朋友通过你的链接安装，双方都到账"))
                    if let url = inviteURL {
                        ShareLink(item: url, message: Text("我在用 VoiceDrop 口述成文，装这个我们都得算力：")) {
                            Text("把邀请链接发给朋友")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 14)
            }
        }
    }

    /// 「≈ 再来 N 次/个就够」——只有差额和现价都知道才说，绝不编数字。
    private var feedTimesHint: String {
        guard let gap = shortOf, feedSuanli > 0 else { return "" }
        let n = Int((Double(gap) / Double(feedSuanli)).rounded(.up))
        return String(localized: "（约 \(n) 次就够）")
    }
    private var inviteTimesHint: String {
        guard let gap = shortOf, inviteSuanli > 0 else { return "" }
        let n = Int((Double(gap) / Double(inviteSuanli)).rounded(.up))
        return String(localized: "（约 \(n) 个就够）")
    }

    private func earnRow(symbol: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.amber)
                .frame(width: 30, height: 30)
                .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: Theme.R.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 底部 CTA

    private var bottomBar: some View {
        VStack(spacing: 9) {
            Button { start() } label: {
                Text(ctaLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(canStart ? Theme.accent : Theme.faint,
                                in: RoundedRectangle(cornerRadius: Theme.R.primary))
            }
            .disabled(!canStart)
            .accentButtonShadow()
            Text("提交后就可以关 App · 10–30 分钟写完，出现在「写书」书架")
                .font(.system(size: 12.5)).foregroundStyle(Theme.metaChrome)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.appBG)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderChrome).frame(height: 1) }
    }

    private var ctaLabel: String {
        if sending { return String(localized: "提交中…") }
        if let gap = shortOf { return String(localized: "算力不够 · 还差 \(gap)") }
        return String(localized: "开始写书 · \(Self.price) 算力")
    }

    private var submittedSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Theme.greenDone)
            Text("开始写了！").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("现在可以关掉 App。书通常 10–30 分钟写完，过稿一章、上架一章——写好就出现在「写书」书架上，下拉刷新就能看到。")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { dismiss() } label: {
                Text("好")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.vertical, 12).padding(.horizontal, 40)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }

    // MARK: 数据

    /// 余额 + 「加油/邀请值多少算力」现价。任何一路失败都静默——价签区退化成
    /// 只显示价目，CTA 不因此上锁（扣费真源永远在服务端）。
    private func loadNumbers() async {
        let token = AuthStore.shared.bearer
        guard !token.isEmpty else { return }
        struct Balance: Decodable { let suanli: Double }
        struct Invite: Decodable {
            let url: String?
            let suanliInviter: Double?
            let suanliFeedAuthor: Double?
        }
        async let b: Balance? = API.get(API.agentBase.appending(path: "usage/balance"), bearer: token)
        async let i: Invite? = API.get(API.agentBase.appending(path: "referral/link"), bearer: token)
        if let b = await b { balance = b.suanli }
        if let i = await i {
            inviteSuanli = Int((i.suanliInviter ?? 0).rounded())
            feedSuanli = Int((i.suanliFeedAuthor ?? 0).rounded())
            inviteURL = i.url.flatMap(URL.init(string:))
        }
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
                let (data, resp) = try await URLSession.shared.data(for: req)
                switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
                case 202:
                    submitted = true
                    Analytics.capture("写书已受理")
                case 402:
                    // body: {error:"no-credit", need_suanli, suanli} — 以服务端为准刷新本地余额
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let have = (body?["suanli"] as? Double) ?? 0
                    balance = have
                    errorText = String(localized: "算力不足：写一本书要 \(Self.price) 算力，你现在有 \(Int(have.rounded()))。往上看两条攒法。")
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

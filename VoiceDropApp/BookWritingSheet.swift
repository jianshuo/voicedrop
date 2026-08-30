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
    /// 「扩展成一本书」入口（文章详情 ⋯ 菜单）：带上一篇文章当种子。文章内容
    /// 不进编辑框（防误删），编辑框变成「补充要求（可选）」；提交时 seed =
    /// 要求 + 文章标题/正文（去掉照片等标记，服务端 20000 字上限内截断）。
    var seedArticle: (title: String, body: String)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var seed = ""
    @State private var sending = false
    @State private var submitted = false
    @State private var errorText: String?
    @FocusState private var seedFocused: Bool

    // 署名：进场拉一次 profile.name。nil = 没拉到（网络失败/没登录，不打扰照常提交，
    // 服务端有啥署啥）；"" = 确认没设置 → 提交前弹一次输入框，存进 profile.name。
    @State private var authorName: String?
    @State private var askName = false
    @State private var nameAsked = false   // 本次 sheet 只问一次；留空确认后不再拦
    @State private var nameDraft = ""
    @State private var showManageSubs = false   // 订着但本月烧光时的系统订阅面板

    // 价签与攒算力数据（进场拉一次；拉不到就只显示价目、CTA 交给服务端判）
    @State private var balance: Double?
    @State private var feedSuanli = 0      // 别人给我的文章加油一次 ≈ 得多少算力
    @State private var inviteSuanli = 0    // 邀请一人安装 ≈ 得多少算力
    @State private var inviteURL: URL?
    // 第三条来路：包月订阅（售卖开关关着或已订阅就不出现）
    @ObservedObject private var store = StoreService.shared

    private static let bookAPI = API.bookAPIBase
    private static let price = 320   // 展示用价目；扣费真源在服务端（402 会带权威数字）

    private var trimmedSeed: String { seed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shortOf: Int? {
        guard let b = balance else { return nil }
        let gap = Double(Self.price) - b
        return gap > 0 ? Int(gap.rounded(.up)) : nil
    }
    private var canStart: Bool { (!trimmedSeed.isEmpty || seedArticle != nil) && !sending && !submitted && shortOf == nil }

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
        .manageSubscriptionsSheet(isPresented: $showManageSubs)
        .task { await loadNumbers() }
        .alert(String(localized: "署上你的名字"), isPresented: $askName) {
            TextField(String(localized: "作者名"), text: $nameDraft)
            Button(String(localized: "好了，开写")) { Task { await saveNameThenStart() } }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text("书会署这个名字上架，以后在设置 → 名字里随时可改。留空则不署名。")
        }
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
            Text(seedArticle == nil ? "中心思想" : "补充要求（可选）")
                .font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.sectionLabel)
            if let a = seedArticle {
                // 文章种子卡：标题 + 开头一行，提醒「内容已带上」
                VStack(alignment: .leading, spacing: 5) {
                    Label("《\(a.title)》已作为种子", systemImage: "doc.text")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(a.body.replacingOccurrences(of: "\n", with: " ").prefix(60) + "……")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                Text("可以补充这本书往哪儿写：比如“写成给孩子的绘本”“扩成一本科普书”“沿着文中第三点展开”。不填就由写书代理自己定。")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("一句话说清这本书要讲明白的那一个问题或主张。想法越聚焦，书越好看；也可以贴一整篇文章当种子。")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                if seed.isEmpty {
                    Text(seedArticle == nil
                         ? "比如：为什么一切都在变乱？\n或：钱不脏，是我一直躲着它。"
                         : "比如：写成给孩子的绘本。（可留空）")
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

    // MARK: 算力不够 — 攒法（加油 / 邀请，数字 = 服务端现价；开着售卖开关再加第三条：包月订阅）

    /// 订阅这条路显示条件：售卖开关开着且还没订（订着的人不能再买同一个订阅，
    /// StoreKit 只会回「你已订阅」）。
    private var showSubscribePath: Bool { store.enabled && !store.active }

    /// 订着、但本月这份额度已经烧光——此前这一档什么都不显示：`showSubscribePath`
    /// 因 active 关掉，于是「算力不够怎么办」只剩加油/邀请两条，付费的路整条消失，
    /// 用户看到的就是「买都没得买」。这里把这个状态明说出来。
    private var showSubscribedDryPath: Bool { store.active && store.subSuanli <= 0 }

    /// 升档（upsell）——正是「钱不够」这一刻该出现的那条路。两种人看得到：
    /// ①订着主档、当月已烧光：再买同一档 StoreKit 只会回「你已订阅」，唯一能
    /// 再花钱的路就是升档；②还没订、且缺口大过主档每月发放量（写一本书 320，
    /// 主档才 200）：订了也照样写不成，不如直说更高的那档。
    /// 三个前提缺一不可：售卖开关开着、还有更高的档、那一档苹果真能拿到商品
    /// （ASC 没建/没过审就拿不到，宁可不显示也不摆一个点了必败的按钮）。
    private var upsellTier: StoreService.Tier? {
        Self.upsellTier(enabled: store.enabled, active: store.active,
                        activeProductID: store.activeProductID, subSuanli: store.subSuanli,
                        shortOf: shortOf, sellable: { store.product($0) != nil })
    }

    /// 抽成纯函数好锁契约（同 shouldAskAuthorName 的家法）：`sellable` = 这个
    /// 商品 ID 苹果那边真拉得到（ASC 没建/没过审就拉不到 → 不推）。
    static func upsellTier(enabled: Bool, active: Bool, activeProductID: String?,
                           subSuanli: Double, shortOf: Int?,
                           tiers: [StoreService.Tier] = StoreService.tiers,
                           sellable: (String) -> Bool) -> StoreService.Tier? {
        guard enabled, let lowest = tiers.first else { return nil }
        let next: StoreService.Tier?
        if active {
            // 订着：只有当月烧光才推，且只推「再往上一档」；已在顶档 = 无货可卖。
            guard subSuanli <= 0, let cur = tiers.firstIndex(where: { $0.id == activeProductID }),
                  cur + 1 < tiers.count else { return nil }
            next = tiers[cur + 1]
        } else {
            // 没订：只有当主档那点额度根本盖不住缺口时才越级推最高档。
            guard let gap = shortOf, gap > lowest.suanli else { return nil }
            next = tiers.last
        }
        guard let tier = next, sellable(tier.id) else { return nil }
        return tier
    }

    private var earnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("算力不够？").font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(Theme.sectionLabel)
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let gap = shortOf {
                        Text(pathsLead(gap))
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
                    if showSubscribePath {
                        earnRow(symbol: "arrow.triangle.2.circlepath",
                                title: String(localized: "订阅包月算力——\(store.product?.displayPrice ?? "¥19.9")/月，每月自动充入 200 算力"),
                                sub: String(localized: "当月没用完月底清零，随时可在系统「订阅」里取消"))
                    }
                    if showSubscribedDryPath {
                        earnRow(symbol: "bolt.badge.clock",
                                title: String(localized: "你的包月算力本月已用完（每月 \(store.monthlySuanli)）"),
                                sub: renewHint)
                    }
                    if let tier = upsellTier {
                        earnRow(symbol: "arrow.up.circle.fill",
                                title: store.active
                                    ? String(localized: "升级到 \(tierPrice(tier))/月——每月 \(tier.suanli) 算力，立刻到账")
                                    : String(localized: "订阅 \(tierPrice(tier))/月——每月 \(tier.suanli) 算力，够写 \(tier.suanli / Self.price) 本书"),
                                sub: store.active
                                    ? String(localized: "同一订阅按比例补差价，当月额度立刻换成 \(tier.suanli)；随时可降回")
                                    : String(localized: "主档每月 \(StoreService.tiers[0].suanli) 算力还不够写一本书（\(Self.price)），这档一次就够"))
                    }
                    if let url = inviteURL {
                        ShareLink(item: url, message: Text("我在用 VoiceDrop 口述成文，装这个我们都得算力：")) {
                            Text("把邀请链接发给朋友")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                    }
                    if showSubscribePath {
                        Button {
                            Task { await store.purchase(); await loadNumbers() }
                        } label: {
                            Text(store.purchasing ? String(localized: "购买中…") : String(localized: "订阅包月算力"))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                        .disabled(store.purchasing)
                    }
                    if let tier = upsellTier {
                        Button {
                            Task { await store.purchase(tier.id); await loadNumbers() }
                        } label: {
                            Text(store.purchasing ? String(localized: "购买中…")
                                 : store.active ? String(localized: "升级到每月 \(tier.suanli) 算力")
                                                : String(localized: "订阅每月 \(tier.suanli) 算力"))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                        .disabled(store.purchasing)
                    } else if showSubscribedDryPath {
                        // 已经在顶档了，没得再卖——只给管理入口，别装作还能买。
                        Button { showManageSubs = true } label: {
                            Text("管理订阅")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                        .buttonStyle(.plain)
                    }
                    if let err = store.lastError {
                        Text(err).font(.system(size: 12.5)).foregroundStyle(Theme.recordRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 14)
            }
        }
    }

    /// 「还差 N 算力。X 条来路：」——X 得跟下面真显示出来的行数一致，别数错。
    private func pathsLead(_ gap: Int) -> String {
        let n = 2 + (showSubscribePath ? 1 : 0) + (upsellTier != nil ? 1 : 0)
        switch n {
        case 4:  return String(localized: "还差 \(gap) 算力。四条来路：")
        case 3:  return String(localized: "还差 \(gap) 算力。三条来路：")
        default: return String(localized: "还差 \(gap) 算力。两条来路：")
        }
    }

    /// 档位价格永远用 StoreKit 的本地化价（自动跟随店面货币）；商品还没拉到时
    /// 用「档」字带过，绝不在界面上写死一个人民币数字。
    private func tierPrice(_ tier: StoreService.Tier) -> String {
        store.product(tier.id)?.displayPrice ?? String(localized: "更高一档")
    }

    /// 续费提示：日期拿得到才说具体哪天到账，拿不到就只说会自动到账——不编日期。
    private var renewHint: String {
        if let d = store.expiresDate {
            return String(localized: "\(DateFormatter.zh("M月d日").string(from: d)) 续费时自动充入下一个月的额度；也可在系统「订阅」里查看或调整")
        }
        return String(localized: "下次续费时自动充入下一个月的额度；也可在系统「订阅」里查看或调整")
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
        await store.refresh()   // 售卖开关/订阅态/本地化价格——决定第三条来路显不显示
        let token = AuthStore.shared.bearer
        guard !token.isEmpty else { return }
        struct Balance: Decodable { let suanli: Double }
        struct Invite: Decodable {
            let url: String?
            let suanliInviter: Double?
            let suanliFeedAuthor: Double?
        }
        struct StyleR: Decodable { let name: String? }
        async let b: Balance? = API.get(API.agentBase.appending(path: "usage/balance"), bearer: token)
        async let i: Invite? = API.get(API.agentBase.appending(path: "referral/link"), bearer: token)
        async let s: StyleR? = API.get(API.filesBase.appending(path: "style"), bearer: token)
        if let b = await b { balance = b.suanli }
        if let i = await i {
            inviteSuanli = Int((i.suanliInviter ?? 0).rounded())
            feedSuanli = Int((i.suanliFeedAuthor ?? 0).rounded())
            inviteURL = i.url.flatMap(URL.init(string:))
        }
        if let s = await s { authorName = s.name ?? "" }
    }

    /// 提交前要不要先问作者名：只有「拉到了 profile 且名字确实为空」才问一次。
    /// 拉不到（nil，网络失败/没登录）不打扰——服务端有啥署啥，与老行为一致。
    static func shouldAskAuthorName(loadedName: String?) -> Bool { loadedName == "" }

    /// 输入框「好了，开写」：填了名字先存进 profile.name（PUT /style，与设置页同一端点），
    /// 存好再提交；留空 = 不署名照常开写。本地 authorName 同步置位，本次 sheet 不再问。
    private func saveNameThenStart() async {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var req = URLRequest(url: API.filesBase.appending(path: "style"))
            req.httpMethod = "PUT"
            req.setBearer(AuthStore.shared.bearer)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.upload(
                for: req, from: (try? JSONEncoder().encode(["name": trimmed])) ?? Data())
            Analytics.capture("写书补署名")
        }
        if !trimmed.isEmpty { authorName = trimmed }
        nameAsked = true   // 留空确认 = 明确选了不署名，别再拦第二次
        start()
    }

    private func start() {
        guard canStart else { return }
        if !nameAsked, Self.shouldAskAuthorName(loadedName: authorName) {
            nameDraft = ""
            askName = true
            return
        }
        seedFocused = false
        sending = true; errorText = nil
        Analytics.capture("写书发起")
        var seedText = trimmedSeed
        if let a = seedArticle {
            let ask = seedText.isEmpty ? "" : "写书要求：\(seedText)\n\n"
            seedText = ask + "以下这篇文章是种子素材，把它扩展成一本完整的书：\n\n《\(a.title)》\n\n" + String(a.body.prefix(18000))
        }
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
                    errorText = String(localized: "算力不足：写一本书要 \(Self.price) 算力，你现在有 \(Int(have.rounded()))。往上看攒法。")
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

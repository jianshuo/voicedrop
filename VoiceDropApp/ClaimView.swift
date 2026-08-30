import SwiftUI

/// 一生一次领 320 算力——正好是写一本书的一口价。
///
/// 入口：落地页 voicedrop.cn/book/ 上的按钮（`voicedrop://claim`），或在别处
/// 点到那条链接（universal link `/book` → `.claim`，见 AppRouter）。
/// 服务端：`POST /agent/usage/claim`——实名闸门 + mint 表唯一键去重都在
/// `agent/src/claim.js`，那儿的文件头有完整设计说明。
/// 设计 spec：docs/superpowers/specs/2026-08-30-book320-claim-design.md

/// 服务端响应 → 界面该显示什么。纯函数，可单测（ClaimTests）。
enum ClaimOutcome: Equatable {
    case granted(newBalance: Double)   // 领到了
    case already(balance: Double)      // 这辈子已经领过
    case needsSignin(wechat: Bool)     // 得先登录（iOS 走 Apple，安卓走微信）
    case failed                        // 其余一律算失败，绝不假装领到了

    static func from(status: Int, json: [String: Any]?) -> ClaimOutcome {
        guard let json else { return .failed }
        if status == 403 {
            return .needsSignin(wechat: (json["error"] as? String) == "needs_wechat_signin")
        }
        guard status == 200, json["ok"] as? Bool == true else { return .failed }
        let balance = num(json["suanli"]) ?? 0
        return json["already"] as? Bool == true ? .already(balance: balance) : .granted(newBalance: balance)
    }

    /// JSONSerialization 给的是 NSNumber，测试里的字面量是 Swift Int/Double——都收。
    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

struct ClaimView: View {
    /// 领完点「去写书」：由 LibraryView 关掉本页并切到书架 tab。
    var onWriteBook: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var claimed = false          // 服务端说的：这辈子领没领过
    @State private var balance: Double?
    @State private var working = false
    @State private var justGranted = false      // 本次会话刚领到（决定庆祝态）
    @State private var errorText: String?

    private static let suanli = 320             // 与服务端 BOOK_SUANLI 同源；GET 会带回真值
    @State private var amount = ClaimView.suanli

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                if loading {
                    ProgressView().padding(.top, 20)
                } else if justGranted || claimed {
                    doneCard
                } else {
                    pitchCard
                    claimButton
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 32)
        }
        .navigationTitle("领算力写书")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadState() }
    }

    // MARK: 组件

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 30)).foregroundStyle(Theme.amber)
                .frame(width: 62, height: 62)
                .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: Theme.R.tile))
            Text("\(amount) 算力").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
            Text("正好写一本书").font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 10)
    }

    private var pitchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("sparkles", "一句话就够", "说个想法，AI 替你把整本书写出来——目录、章节、插图都有")
            row("gift.fill", "领了就是你的", "写不写、什么时候写都随你")
            row("clock.fill", "90 天内有效", "别攒着，攒着就过期了")
        }
        .padding(15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.tile))
    }

    private var doneCard: some View {
        VStack(spacing: 10) {
            Text(justGranted ? "到账了" : "你已经领过了")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            if let balance {
                Text("当前算力 \(Int(balance.rounded()))")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            Text(justGranted ? "去写你的第一本书吧" : "这笔算力已经在你账上了")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { onWriteBook() } label: {
                Text("去写书")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.tile))
    }

    private var claimButton: some View {
        Button { Task { await claim() } } label: {
            Text(working ? "领取中…" : "领取 \(amount) 算力")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
        }
        .disabled(working)
    }

    private func row(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.amber)
                .frame(width: 30, height: 30)
                .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: Theme.R.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 网络

    private static var endpoint: URL { API.agentBase.appending(path: "usage/claim") }

    /// 进页面先问服务端：领过没有、能不能领、现在多少算力。
    /// 失败静默——按钮照常可点，真源永远在服务端那一次 POST。
    private func loadState() async {
        defer { loading = false }
        struct State: Decodable {
            let suanli: Double?; let claimed: Bool?; let suanli_balance: Double?
        }
        guard let s: State = await API.get(Self.endpoint, bearer: AuthStore.shared.bearer) else { return }
        if let n = s.suanli { amount = Int(n.rounded()) }
        claimed = s.claimed ?? false
        balance = s.suanli_balance
    }

    /// 领。403 就地拉起 Apple 登录再重试一次——与社区分享同一套握手
    /// （Community.withAppleRetry 的注释解释了为什么只重试一次）。
    private func claim() async {
        working = true; errorText = nil
        defer { working = false }
        var outcome = await post()
        if case .needsSignin = outcome {
            await AuthStore.shared.signInWithApple()
            guard AuthStore.shared.isAuthenticated else {
                errorText = String(localized: "领取要先登录，确认是本人才送")
                return
            }
            outcome = await post()
        }
        switch outcome {
        case .granted(let bal):
            justGranted = true; claimed = true; balance = bal
            Analytics.capture("领书算力", ["结果": "到账", "算力": amount])
        case .already(let bal):
            claimed = true; balance = bal
            Analytics.capture("领书算力", ["结果": "已领过"])
        case .needsSignin:
            errorText = String(localized: "领取要先登录，确认是本人才送")
            Analytics.capture("领书算力", ["结果": "需登录"])
        case .failed:
            errorText = String(localized: "没领成，过会儿再试试")
            Analytics.capture("领书算力", ["结果": "失败"])
        }
    }

    private func post() async -> ClaimOutcome {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setBearer(AuthStore.shared.bearer)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failed }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ClaimOutcome.from(status: status, json: json ?? nil)
    }
}

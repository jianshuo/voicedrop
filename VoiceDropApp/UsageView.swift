import SwiftUI

private struct Balance: Decodable { let suanli: Double; let spent_suanli: Double }
private struct LedgerResp: Decodable { let entries: [Entry] }
private struct Entry: Decodable, Identifiable {
    var id: Int { ts }
    let ts: Int; let kind: String; let reason: String; let suanli: Double; let balance_suanli: Double
}

/// 算力 ↔ 篇 estimate — single source so the 设置 list row and this page agree.
/// A mine costs ~9 算力 (see the 明细 −9.1 / −8.4 entries), so 612 ≈ 68 篇.
enum Suanli {
    static let perArticle = 9.0
    static func articles(_ balance: Double) -> Int { max(0, Int((balance / perArticle).rounded(.down))) }
}

// MARK: - 算力 (per Settings.dc.html「算力 · 点开后看明细」)

struct UsageView: View {
    @State private var balance: Double = 0
    @State private var spent: Double = 0
    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var showSubAlert = false
    private var token: String { AuthStore.shared.bearer }

    /// granted = balance + spent (balance = 累计获赠 − 已用), exact from the two numbers.
    private var granted: Double { balance + spent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroCard
                subscriptionCard
                if !grantBuckets.isEmpty {
                    section("算力来源") { SettingsCard { bucketRows } }
                }
                section("明细") { SettingsCard { ledgerRows } }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
        }
        .background(Theme.appBG.ignoresSafeArea())
        .navigationTitle("算力")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("包月订阅即将上线", isPresented: $showSubAlert) {
            Button("好") {}
        } message: {
            Text("包月算力还在开发中，敬请期待。现在的算力来自注册与活动赠送，足够日常使用。")
        }
    }

    // MARK: 余额 hero（深色渐变）

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("剩余算力").font(.system(size: 13)).tracking(1).foregroundStyle(Color(hex: "C9BFAE"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(balance.rounded()))").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                Text("≈ \(Suanli.articles(balance)) 篇").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: "E2B871"))
            }
            .padding(.top, 6)
            Text(loaded ? "累计获赠 \(Int(granted.rounded())) · 已用 \(Int(spent.rounded()))" : "加载中…")
                .font(.system(size: 12.5)).foregroundStyle(Color(hex: "C9BFAE")).padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.inkHeroTop, Theme.inkHeroBot], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(colors: [Theme.amber.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 66))
                .frame(width: 132, height: 132).offset(x: 22, y: -32)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 包月订阅卡（即将上线）

    private var subscriptionCard: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                settingsTile(Theme.amberSoft, "bolt.fill", Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("包月算力").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("每月 200 算力 · 月底清零 · 随时可取消")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("¥19.9").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("/月").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            Button { showSubAlert = true } label: {
                Text("包月订阅 · 即将上线")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.amber.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "EBD9B8"), lineWidth: 1))
    }

    // MARK: 算力来源（分桶：从 ledger 的 grant 记录归类汇总，真实数据）

    private struct Bucket: Identifiable { let title: String; let total: Double; var id: String { title } }
    private var grantBuckets: [Bucket] {
        var sums: [String: Double] = [:]
        for e in entries where e.kind == "grant" {
            let key: String
            if e.reason == "signup" { key = "注册赠送" }
            else if e.reason.hasPrefix("campaign:") { key = "活动赠送" }
            else if e.reason == "monthly" || e.reason == "subscription" { key = "包月发放" }
            else { key = label(e) }
            sums[key, default: 0] += e.suanli
        }
        let order = ["包月发放", "活动赠送", "注册赠送"]
        return sums.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? 99, ib = order.firstIndex(of: b.key) ?? 99
            return ia == ib ? a.key < b.key : ia < ib
        }.map { Bucket(title: $0.key, total: $0.value) }
    }

    @ViewBuilder private var bucketRows: some View {
        let buckets = grantBuckets
        ForEach(Array(buckets.enumerated()), id: \.element.id) { i, b in
            HStack {
                Text(b.title).font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(b.total.rounded()))").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            .padding(.vertical, 14).padding(.horizontal, 15)
            if i < buckets.count - 1 { settingsRowDivider }
        }
    }

    // MARK: 明细

    @ViewBuilder private var ledgerRows: some View {
        if entries.isEmpty {
            Text(loaded ? "暂无记录" : "加载中…")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16).padding(.horizontal, 15)
        } else {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(e)).font(.system(size: 15)).foregroundStyle(Theme.ink)
                        Text(timeText(e)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text("\(e.kind == "grant" ? "+" : "−")\(fmt(e.suanli))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(e.kind == "grant" ? Theme.greenDone : Theme.accent)
                }
                .padding(.vertical, 13).padding(.horizontal, 15)
                if i < entries.count - 1 { settingsRowDivider }
            }
        }
    }

    // MARK: helpers

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionLabel(title)
            content()
        }
    }

    private func label(_ e: Entry) -> String {
        switch e.reason {
        case "signup": return "注册赠送"
        case "asr": return "语音转写"
        case "mine": return "挖文章"
        case "edit": return "语音修改"
        default: return e.reason.hasPrefix("campaign:") ? "活动赠送" : e.reason
        }
    }
    private func fmt(_ s: Double) -> String { s < 10 ? String(format: "%.1f", s) : String(Int(s.rounded())) }

    private func timeText(_ e: Entry) -> String {
        // ledger ts is epoch milliseconds (server writes Date.now())
        DateFormatter.zh("yyyy年M月d日 HH:mm").string(from: Date(timeIntervalSince1970: Double(e.ts) / 1000))
    }

    private func load() async {
        async let b: Balance? = fetch("\(API.agentBase.absoluteString)/usage/balance")
        async let l: LedgerResp? = fetch("\(API.agentBase.absoluteString)/usage/ledger?limit=50")
        if let b = await b { balance = b.suanli; spent = b.spent_suanli }
        if let l = await l { entries = l.entries }
        loaded = true
    }
    private func fetch<T: Decodable>(_ urlStr: String) async -> T? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url); req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

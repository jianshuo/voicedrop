import SwiftUI

private struct Balance: Decodable { let suanli: Double; let spent_suanli: Double }
private struct LedgerResp: Decodable { let entries: [Entry] }
private struct Entry: Decodable, Identifiable {
    var id: Int { ts }
    let ts: Int; let kind: String; let reason: String; let suanli: Double; let balance_suanli: Double
}

struct UsageView: View {
    @State private var balance: Double = 0
    @State private var spent: Double = 0
    @State private var entries: [Entry] = []
    private var token: String { AuthStore.shared.bearer }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(balance.rounded())) 算力").font(.system(size: 34, weight: .bold))
                    Text("累计消费 \(Int(spent.rounded())) 算力").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            } footer: {
                Text("算力是 VoiceDrop 送你的免费额度，无现金价值、不可提现。处理录音和语音修改会按真实成本消耗算力。")
            }
            Section("明细") {
                ForEach(entries) { e in
                    HStack {
                        Text(label(e)).font(.subheadline)
                        Spacer()
                        Text("\(e.kind == "grant" ? "+" : "−")\(fmt(e.suanli)) 算力")
                            .foregroundStyle(e.kind == "grant" ? .green : .primary)
                    }
                }
                if entries.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("算力")
        .task { await load() }
    }

    private func label(_ e: Entry) -> String {
        switch e.reason {
        case "signup": return "新用户赠送"
        case "asr": return "语音转写"
        case "mine": return "挖文章"
        case "edit": return "语音修改"
        default: return e.reason.hasPrefix("campaign:") ? "活动赠送" : e.reason
        }
    }
    private func fmt(_ s: Double) -> String { s < 10 ? String(format: "%.1f", s) : String(Int(s.rounded())) }

    private func load() async {
        async let b: Balance? = fetch("https://jianshuo.dev/agent/usage/balance")
        async let l: LedgerResp? = fetch("https://jianshuo.dev/agent/usage/ledger?limit=50")
        if let b = await b { balance = b.suanli; spent = b.spent_suanli }
        if let l = await l { entries = l.entries }
    }
    private func fetch<T: Decodable>(_ urlStr: String) async -> T? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url); req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

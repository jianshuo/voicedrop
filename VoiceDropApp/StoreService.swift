import Foundation
import StoreKit

/// 苹果自动续期订阅（¥19.9/月 → 每月 200 算力）。StoreKit 2。
///
/// 到账链路是双保险：App Store 服务器通知（服务端 /agent/iap/notifications）是主路，
/// 这里的 claim（购买回调 + Transaction.updates + 启动时 currentEntitlements 逐笔回传）
/// 是兜底路——服务端按 transaction_id 幂等，重复 claim 不会重复发钱。
@MainActor
final class StoreService: ObservableObject {
    static let shared = StoreService()
    /// 产品 ID 里写死价格（monthly_19_9 = ¥19.9/月主档，monthly_199_99 = ¥199.99/月高档）
    /// ——服务端按档位表（usage.js SUB_PRODUCTS）发放对应算力，两边必须对齐。各国售价
    /// 在 ASC 按店面定，ID 只是内部档位记号；界面价格永远用 product.displayPrice
    /// （自动本地货币），绝不在 UI 里写死数字。
    struct Tier: Identifiable, Hashable {
        let id: String
        let suanli: Int      // 每月发放算力（与服务端 SUB_PRODUCTS 同值）
    }
    /// 从低到高。同一个 ASC 订阅组 → 升降档由 StoreKit 按比例补差价，不必先退订。
    static let tiers: [Tier] = [
        Tier(id: "com.wangjianshuo.VoiceDrop.sub.monthly_19_9", suanli: 200),
        Tier(id: "com.wangjianshuo.VoiceDrop.sub.monthly_199_99", suanli: 2000),
    ]
    static let monthlyID = tiers[0].id            // 主档（默认购买/展示）
    static let proID = tiers[tiers.count - 1].id  // 高档（升档 upsell）
    static func tier(_ id: String?) -> Tier? { tiers.first { $0.id == id } }

    /// 主档商品（老调用点沿用）；全部档位在 productsByID 里。
    @Published var product: Product?
    @Published var productsByID: [String: Product] = [:]
    func product(_ id: String) -> Product? { productsByID[id] }
    @Published var active = false
    /// 售卖开关（服务端 R2 config/iap.json，零部署启停）。false = 算力页不显示订阅卡；
    /// 已订阅用户（active）不受开关影响，永远能看到管理入口。
    @Published var enabled = false
    @Published var expiresDate: Date?
    @Published var purchasing = false
    @Published var lastError: String?
    /// 本月订阅桶还剩多少算力 / 每月发放量（服务端 /iap/status 一直在给，之前客户端丢掉了）。
    /// 订着但本月已烧光（active && subSuanli == 0）是一种要单独说话的状态——
    /// 既不能再卖同一个订阅，也不该假装「每月自动到账」就完事。
    @Published var subSuanli: Double = 0
    @Published var monthlySuanli: Int = 200
    /// 当前订着哪一档（服务端 iap_sub.product_id）——决定还能不能升档。
    @Published var activeProductID: String?

    /// 还能升的下一档：订着的档在 tiers 里往上还有东西就是它；没订/已在顶档 = nil。
    var upgradeTier: Tier? {
        guard active, let cur = Self.tiers.firstIndex(where: { $0.id == activeProductID }) else { return nil }
        return cur + 1 < Self.tiers.count ? Self.tiers[cur + 1] : nil
    }

    private var updatesTask: Task<Void, Never>?

    /// App 启动时调一次：挂 Transaction.updates 监听（续费/别台设备购买都从这来），
    /// 并把当前有效订阅逐笔 claim 一遍（服务端幂等，漏发的月份在这里补上）。
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            for await update in Transaction.updates {
                await handle(update)
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        if productsByID.count < Self.tiers.count { await loadProducts() }
        await syncEntitlements()
        await loadStatus()
    }

    /// 一次把所有档位拉回来（ASC 里还没建/还没过审的档位苹果不返回，就少一条，
    /// 界面按「拿不到就不推这档」降级——绝不显示一个点了必失败的按钮）。
    private func loadProducts() async {
        guard let list = try? await Product.products(for: Self.tiers.map(\.id)) else { return }
        productsByID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        product = productsByID[Self.monthlyID]
    }

    /// 买指定档（默认主档）。同一订阅组内买高档 = 升档，StoreKit 自动按比例补差价。
    func purchase(_ productID: String = StoreService.monthlyID) async {
        guard !purchasing else { return }
        purchasing = true
        lastError = nil
        defer { purchasing = false }
        do {
            if productsByID[productID] == nil { await loadProducts() }
            guard let product = productsByID[productID] else {
                lastError = String(localized: "商品加载失败，请稍后再试"); return
            }
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await claim(txn)
                    await txn.finish()
                    Analytics.capture("订阅购买完成")
                }
            case .userCancelled:
                break
            case .pending:
                lastError = String(localized: "购买待确认，完成后算力自动到账")
            @unknown default:
                break
            }
        } catch {
            lastError = String(localized: "购买失败，请稍后再试")
        }
        await loadStatus()
    }

    /// 「恢复购买」：换机/重装后把 Apple ID 名下的订阅同步回来再逐笔 claim。
    func restore() async {
        try? await AppStore.sync()
        await syncEntitlements()
        await loadStatus()
    }

    private func syncEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, Self.tier(txn.productID) != nil {
                await claim(txn)
            }
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = result, Self.tier(txn.productID) != nil else { return }
        await claim(txn)
        await txn.finish()
        await loadStatus()
    }

    private struct ClaimResp: Decodable { let ok: Bool?; let granted: Bool?; let suanli: Int? }

    private func claim(_ txn: Transaction) async {
        var req = URLRequest(url: API.agentBase.appending(path: "iap/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setBearer(AuthStore.shared.bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["transaction_id": String(txn.id)])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let r = try? JSONDecoder().decode(ClaimResp.self, from: data) else { return }
        if r.granted == true { Analytics.capture("订阅算力到账", ["算力": r.suanli ?? 0]) }
    }

    private struct Status: Decodable {
        let active: Bool; let enabled: Bool?; let expires_date: Int?
        let sub_suanli: Double?; let monthly_suanli: Int?; let product_id: String?
    }

    func loadStatus() async {
        var req = URLRequest(url: API.agentBase.appending(path: "iap/status"))
        req.setBearer(AuthStore.shared.bearer)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return }
        active = s.active
        enabled = s.enabled ?? false
        expiresDate = s.expires_date.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        subSuanli = s.sub_suanli ?? 0
        monthlySuanli = s.monthly_suanli ?? 200
        activeProductID = s.product_id
    }
}

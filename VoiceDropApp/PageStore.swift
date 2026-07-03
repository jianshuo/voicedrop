import Foundation
import Observation

/// 拉取并持有用户的自定义首页树。`tree == nil` 表示没有自定义页 —— 渲染层回退到
/// 现有原生首页（零回归）。解码/回退的决策抽成纯函数 `resolveTree` 以便单测。
@MainActor
@Observable
final class PageStore {
    var tree: PageNode?       // nil → 原生默认首页
    var loading = false

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }
    private var lastGood: PageNode?

    /// 纯决策：给定 HTTP 状态 + 响应体 + 上一份好的树，决定新的 (tree, lastGood)。
    nonisolated static func resolveTree(status: Int, data: Data, lastGood: PageNode?) -> (tree: PageNode?, lastGood: PageNode?) {
        if status == 404 { return (nil, lastGood) }                                  // 无自定义页 / 被重置 → 原生
        guard (200..<300).contains(status) else { return (lastGood, lastGood) }      // 瞬时错误 → 保上一份
        if let doc = PageDocument.decode(data) { return (doc.root, doc.root) }       // 正常 → 采用
        return (lastGood, lastGood)                                                  // 坏 JSON → 保上一份（无则 nil→原生）
    }

    func load() async {
        guard !token.isEmpty else { tree = nil; return }
        loading = true; defer { loading = false }
        guard let url = URL(string: "\(base.absoluteString)/download/page.json") else { return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let r = Self.resolveTree(status: resp.httpStatusCode, data: data, lastGood: lastGood)
            tree = r.tree; lastGood = r.lastGood
        } catch {
            let r = Self.resolveTree(status: 0, data: Data(), lastGood: lastGood)     // 网络异常按瞬时错误
            tree = r.tree; lastGood = r.lastGood
        }
    }
}

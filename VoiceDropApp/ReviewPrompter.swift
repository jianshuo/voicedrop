import Foundation

/// 评分弹窗时机：只在用户第 3 / 10 / 30 次打开挖出来的文章（看到成果的高兴时刻）
/// 才触发系统评分请求。系统自身还有一年最多 3 次的硬性节流，这里只负责挑时机。
enum ReviewPrompter {
    private static let countKey = "review.articleOpens"
    private static let milestones: Set<Int> = [3, 10, 30]

    /// 每次打开一篇有成文的录音时调用；到达里程碑时延迟 2 秒执行 `request`
    /// （让读者先落到正文里，不打断打开瞬间）。
    static func articleOpened(_ request: @escaping @MainActor () -> Void) {
        let d = UserDefaults.standard
        let n = d.integer(forKey: countKey) + 1
        d.set(n, forKey: countKey)
        guard milestones.contains(n) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            request()
        }
    }
}

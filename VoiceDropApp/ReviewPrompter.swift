import Foundation

/// 评分弹窗时机——三发子弹全打在「这东西真好用」的情绪峰值上。
///
/// 触发时刻（挑时机）：
/// ① 打开有成文的录音并**停留满 10 秒**（正在读自己的作品，而不是刚点开）——
///    第 3/10/30 次打开才候选：第 1 篇还半信半疑，第 3 篇还在用的人已认可价值；
/// ② 公众号推送成功（作品到了作者真正的舞台）。
///
/// 闸门（防打偏）：本次会话出过用户可见的错误一律不弹；两次真实请求间隔 ≥60 天；
/// 同一 marketing 版本最多请求一次。系统另有一年最多弹 3 次的硬性节流——
/// 这里的职责只是把稀缺的调用挑在对的时刻，别在启动/出错/任务中途浪费。
enum ReviewPrompter {
    private static let countKey = "review.articleOpens"
    private static let lastTsKey = "review.lastRequestTs"
    private static let lastVersionKey = "review.lastRequestVersion"
    private static let milestones: Set<Int> = [3, 10, 30]
    static let dwellSeconds: Double = 10
    static let cooldown: TimeInterval = 60 * 24 * 3600   // 60 天

    /// 本次会话是否出过用户可见的错误（上传失败、转写/成文失败等）。
    /// 出过错这一程就免谈——弹了是找差评。进程重启自动清零（内存态，有意）。
    @MainActor private(set) static var sessionHadError = false
    @MainActor static func noteError() { sessionHadError = true }

    @MainActor private static var dwellTask: Task<Void, Never>?

    /// 纯决策函数（单测锚点）：里程碑 & 无错 & 冷却期外 & 本版本未弹过。
    /// `requireMilestone` false = 事件型触发（公众号成功），只要求 openCount ≥ 3 的留存闸。
    static func shouldFire(openCount: Int, requireMilestone: Bool, sessionError: Bool,
                           now: Date, lastTs: Double, version: String, lastVersion: String) -> Bool {
        if sessionError { return false }
        if requireMilestone {
            guard milestones.contains(openCount) else { return false }
        } else {
            guard openCount >= 3 else { return false }
        }
        guard now.timeIntervalSince1970 - lastTs >= cooldown else { return false }
        return version != lastVersion
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    @MainActor private static func fire(_ request: @escaping @MainActor () -> Void) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: lastTsKey)
        d.set(appVersion, forKey: lastVersionKey)
        request()
    }

    @MainActor private static func gate(requireMilestone: Bool) -> Bool {
        let d = UserDefaults.standard
        return shouldFire(openCount: d.integer(forKey: countKey),
                          requireMilestone: requireMilestone,
                          sessionError: sessionHadError,
                          now: Date(),
                          lastTs: d.double(forKey: lastTsKey),
                          version: appVersion,
                          lastVersion: d.string(forKey: lastVersionKey) ?? "")
    }

    /// 每次打开一篇有成文的录音时调用。计数 +1；若达到候选条件，启动 10 秒
    /// 停留计时——读满 10 秒（还没离开）才真正请求；提前离开由 articleClosed 取消。
    @MainActor static func articleOpened(_ request: @escaping @MainActor () -> Void) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: countKey) + 1, forKey: countKey)
        guard gate(requireMilestone: true) else { return }
        dwellTask?.cancel()
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(dwellSeconds))
            guard !Task.isCancelled, gate(requireMilestone: true) else { return }
            fire(request)
        }
    }

    /// 文章详情页关闭时调用：取消未满的停留计时（没读完不算峰值）。
    @MainActor static func articleClosed() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// 公众号推送成功后调用（成功 toast 之后的高光一秒）。
    @MainActor static func wechatPublished(_ request: @escaping @MainActor () -> Void) {
        guard gate(requireMilestone: false) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard gate(requireMilestone: false) else { return }
            fire(request)
        }
    }
}

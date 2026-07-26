import Foundation

/// 销号事务（Apple 5.1.1(v)）：服务端删光该用户名下所有数据，然后把本机清成
/// 全新安装状态。步骤缺一不可——漏清一处就会让新身份「复活」旧数据。
/// 从 AccountView 外提：不可逆流程不该住在 View 的 private func 里，
/// 收在这里才有被测试的可能（fm/defaults 都留了注入口）。
@MainActor
enum AccountService {
    /// 返回 nil = 成功；否则是直接给用户看的错误文案（此时本机数据未动）。
    static func deleteAccount(auth: AuthStore = .shared) async -> String? {
        var req = URLRequest(url: API.filesBase.appending(path: "account").appending(path: "delete"))
        req.httpMethod = "POST"
        req.setBearer(auth.bearer)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else {
                return String(localized: "服务器返回 \(resp.httpStatusCode)，请稍后再试。")
            }
        } catch {
            return error.localizedDescription
        }
        // Server side is gone — wipe everything local, then start a fresh
        // empty identity so the app behaves like a brand-new install.
        wipeLocalState()
        auth.signOut()          // drop the Apple session JWT
        auth.resetAnonymous()   // brand-new anon token (also re-published to the Share Extension)
        return nil
    }

    /// 清空本机三处存储：Documents（录音/侧车）、Caches 快照、UserDefaults 全域。
    static func wipeLocalState(fileManager fm: FileManager = .default,
                               defaults: UserDefaults = .standard) {
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
        DiskCache.wipe()   // Caches 里的快照（录音列表/文章 doc/feed/照片）也是「本机数据」，一并清
        if let bid = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bid)
        }
    }
}

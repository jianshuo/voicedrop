import Foundation
import Observation
import Security

/// Holds the per-user session token minted by jianshuo.dev/files after a
/// "Sign in with Apple" exchange. The token is the bearer credential for this
/// user's own `users/<sub>/` space — it is NOT a device id and NOT the old
/// shared master token.
///
/// Stored in the Keychain with iCloud Keychain sync on, so reinstalling or
/// switching to a new device recovers the same account (and therefore the same
/// recordings) without re-uploading anything.
@MainActor
@Observable
final class AuthStore {
    static let shared = AuthStore()

    private(set) var session: String?
    var lastError: String?
    var isAuthenticated: Bool { session != nil }

    /// Where the session is exchanged. Public URL, not a secret.
    private let authURL = URL(string: "https://jianshuo.dev/files/api/auth/apple")!

    private let service = "dev.jianshuo.voicedrop"
    private let account = "session"

    private init() { session = keychainLoad() }

    /// Exchange a Sign-in-with-Apple identity token for a long-lived session JWT.
    /// On success the session is persisted and `isAuthenticated` flips true.
    func exchange(identityToken: String) async {
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["identityToken": identityToken])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "登录失败（服务器拒绝）"
                return
            }
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = obj["session"] as? String, !token.isEmpty
            else {
                lastError = "登录失败（无效响应）"
                return
            }
            keychainSave(token)
            session = token
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        keychainDelete()
        session = nil
    }

    // MARK: - Keychain (synchronizable = iCloud Keychain)

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }

    private func keychainSave(_ value: String) {
        let data = Data(value.utf8)
        var q = baseQuery()
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private func keychainLoad() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = kCFBooleanTrue!
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func keychainDelete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

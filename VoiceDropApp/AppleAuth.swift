import Foundation
import Observation
import Security
import CryptoKit
import AuthenticationServices
import UIKit

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
    private(set) var anonToken: String = ""
    var lastError: String?
    var isAuthenticated: Bool { session != nil }

    /// The bearer used for uploads: the signed-in session if present, else the
    /// anonymous iCloud-Keychain token (zero-login; same Apple ID -> same token
    /// across devices and reinstalls). Always non-empty.
    var bearer: String { session ?? anonToken }

    /// The user-facing identity string — exactly the server's storage prefix
    /// (`users/<anonId>/`). Safe to show and share: it's a one-way hash of the
    /// secret, not the secret itself. Lets the owner pin "which folder is me".
    var anonId: String {
        let hex = SHA256.hash(data: Data(anonToken.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "anon-" + String(hex.prefix(32))
    }

    /// Where the session is exchanged. Public URL, not a secret.
    private let authURL = URL(string: "https://jianshuo.dev/files/api/auth/apple")!

    private var appleCoordinator: AppleSignInCoordinator?

    private let service = "dev.jianshuo.voicedrop"
    private let sessionAccount = "session"
    private let anonAccount = "anon-id"

    private init() {
        session = keychainLoad(account: sessionAccount)
        anonToken = loadOrCreateAnon()
    }

    /// A stable per-user secret with no login. Stored in the iCloud-synced
    /// Keychain, so the same Apple ID recovers the same token on every device.
    private func loadOrCreateAnon() -> String {
        if let existing = keychainLoad(account: anonAccount), !existing.isEmpty { return existing }
        let token = "anon_" + randomHex(32)
        keychainSave(token, account: anonAccount)
        return token
    }

    private func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Exchange a Sign-in-with-Apple identity token for a long-lived session JWT.
    /// On success the session is persisted and `isAuthenticated` flips true.
    func exchange(identityToken: String) async {
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(anonToken)", forHTTPHeaderField: "Authorization")
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
            keychainSave(token, account: sessionAccount)
            session = token
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        keychainDelete(account: sessionAccount)
        session = nil
    }

    /// Present the system Sign-in-with-Apple sheet, then exchange the identity
    /// token for a session JWT bound to this user's existing anon box.
    func signInWithApple() async {
        defer { appleCoordinator = nil }
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.fullName]
        do {
            let auth = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorization, Error>) in
                let c = AppleSignInCoordinator(cont)
                appleCoordinator = c
                let ctrl = ASAuthorizationController(authorizationRequests: [req])
                c.controller = ctrl
                ctrl.delegate = c
                ctrl.presentationContextProvider = c
                ctrl.performRequests()
            }
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastError = "登录失败（无身份令牌）"; return
            }
            await exchange(identityToken: idToken)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reset the anonymous identity: mint a brand-new token. The old
    /// `users/<id>/` space (recordings + articles) becomes unreachable — this is
    /// irreversible. Used by the account page's 重置身份.
    func resetAnonymous() {
        let token = "anon_" + randomHex(32)
        keychainSave(token, account: anonAccount)
        anonToken = token
    }

    // MARK: - Keychain (synchronizable = iCloud Keychain)

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }

    private func keychainSave(_ value: String, account: String) {
        let data = Data(value.utf8)
        var q = baseQuery(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private func keychainLoad(account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = kCFBooleanTrue!
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

// MARK: - Sign-in-with-Apple coordinator

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding, @unchecked Sendable {
    let cont: CheckedContinuation<ASAuthorization, Error>
    var controller: ASAuthorizationController?
    init(_ cont: CheckedContinuation<ASAuthorization, Error>) { self.cont = cont }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) { cont.resume(returning: authorization) }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { cont.resume(throwing: error) }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

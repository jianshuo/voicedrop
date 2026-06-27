import Foundation
import CryptoKit

// MARK: - End-to-end crypto for device-link (X25519 -> HKDF-SHA256 -> AES-GCM).
// The server only relays pubkey + the {epk, sealed} blob — never the plaintext token.
enum DeviceLinkCrypto {
    private static let salt = Data("voicedrop-device-link/v1".utf8)
    private static let info = Data("anon-token".utf8)

    // New device: ephemeral keypair; pubB64 is sent in /agent/link/start.
    static func newKeypair() -> (priv: Curve25519.KeyAgreement.PrivateKey, pubB64: String) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return (priv, b64url(priv.publicKey.rawRepresentation))
    }

    // New device: decrypt the blob from the old device into the anon_… token.
    static func decrypt(epkB64: String, sealedB64: String, priv: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        let epk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: b64urlDecode(epkB64))
        let shared = try priv.sharedSecretFromKeyAgreement(with: epk)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(combined: b64urlDecode(sealedB64))
        return String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self)
    }

    // Old device: encrypt its anon_… token to the new device's public key.
    static func encrypt(token: String, toPubB64 pub: String) throws -> (epkB64: String, sealedB64: String) {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let newPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: b64urlDecode(pub))
        let shared = try eph.sharedSecretFromKeyAgreement(with: newPub)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data(token.utf8), using: key)
        return (b64url(eph.publicKey.rawRepresentation), b64url(sealed.combined!))
    }

    // base64url helpers (no padding)
    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func b64urlDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t) ?? Data()
    }

    #if DEBUG
    // One-shot round-trip self-check; call from app launch in DEBUG, confirm console, then remove.
    static func selfTest() {
        let (priv, pub) = newKeypair()
        do {
            let (epk, sealed) = try encrypt(token: "anon_roundtrip_demo", toPubB64: pub)
            let out = try decrypt(epkB64: epk, sealedB64: sealed, priv: priv)
            print("DeviceLinkCrypto.selfTest:", out == "anon_roundtrip_demo" ? "OK" : "FAIL")
        } catch { print("DeviceLinkCrypto.selfTest ERROR:", error) }
    }
    #endif
}

import SwiftUI

// MARK: - Old-device side: show the 4-digit code, then release the token on link_release.
@MainActor
@Observable
final class DeviceLinkResponder {
    struct Pending: Identifiable { let id = UUID(); let pairingId: String; let code: String; let pubkey: String }
    var pending: Pending?
    var status: String = ""   // transient toast text after release/cancel

    private let base = URL(string: "https://jianshuo.dev/agent/link")!

    func present(pairingId: String, code: String, pubkey: String) {
        pending = Pending(pairingId: pairingId, code: code, pubkey: pubkey)
        status = ""
    }

    // Fired when the new device entered the correct code (server pushed link_release).
    func release(pairingId: String) {
        guard let p = pending, p.pairingId == pairingId else { return }
        Task {
            do {
                let (epk, sealed) = try DeviceLinkCrypto.encrypt(token: AuthStore.shared.anonToken, toPubB64: p.pubkey)
                try await post("complete", body: ["pairingId": pairingId, "blob": ["epk": epk, "sealed": sealed]])
                status = "已在新设备登录"
            } catch {
                status = "登录失败"
            }
            pending = nil
        }
    }

    func cancel() {
        guard let p = pending else { return }
        let pid = p.pairingId
        pending = nil
        Task { try? await post("cancel", body: ["pairingId": pid]) }
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.setBearer(AuthStore.shared.bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard resp.isOK else { throw URLError(.badServerResponse) }
    }
}

struct DeviceLinkApprovalSheet: View {
    @Bindable var responder: DeviceLinkResponder
    let pending: DeviceLinkResponder.Pending

    var body: some View {
        VStack(spacing: 22) {
            Text("有新设备想登录你的账号").font(.system(size: 18, weight: .semibold))
            Text("在新设备上输入下面的验证码").font(.system(size: 14)).foregroundStyle(.secondary)
            Text(pending.code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(8)
            Text("不是你本人操作？点「不是我」。").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(role: .destructive) { responder.cancel() } label: {
                Text("不是我").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .presentationDetents([.height(320)])
    }
}

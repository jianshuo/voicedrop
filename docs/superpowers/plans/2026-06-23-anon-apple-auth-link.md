# Anonymous-first auth with Apple linked second key — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Sign-in-with-Apple a stronger key bound to the user's existing anonymous data box, required only to *post* to the community — keeping the core app zero-login.

**Architecture:** A session JWT stops meaning "`users/<sub>/`" and instead carries the **bound scope** + an `apple:true` flag. On first Apple sign-in the server aliases `apple:<sub>` → the caller's current anon scope (no data moves). The community write routes require `apple:true`. The same JWT changes are mirrored in the separate `voicedrop-agent` Worker.

**Tech Stack:** Cloudflare Pages Functions (JS, Web Crypto), Cloudflare Worker + Durable Objects (`agent/`), SwiftUI iOS app, R2 (`jianshuo-dev-files`).

## Global Constraints

- Two copies of `mintSession`/`verifySession`/`hmacSign` exist — `functions/files/api/[[path]].js` **and** `agent/src/index.js`. JWT-format changes MUST be made identically in both.
- `SESSION_SECRET` must be **byte-identical** on the Pages project and the `voicedrop-agent` Worker, or JWTs verify on one and 401 on the other.
- No automated test harness exists in these repos; verification is **`wrangler pages dev` + `curl`** (server), `node` round-trips (pure crypto helpers), and **iOS Simulator** (app). Follow that pattern — do not introduce jest/XCTest scaffolding.
- Anonymous tokens (`anon_…`) and temp tokens are unchanged: they always resolve `apple:false`.
- JWT lifetime stays 365 days (existing `mintSession`).
- App bundle id `com.wangjianshuo.VoiceDrop`; the **Sign in with Apple** capability must be in `VoiceDropApp/VoiceDrop.entitlements`.

---

### Task 1: Pages — JWT carries `{scope, apple}` instead of `sub`

**Files:**
- Modify: `~/code/jianshuo.dev/functions/files/api/[[path]].js` — `mintSession` (~449), `verifySession` (~457), scope-resolution block (~53–77).

**Interfaces:**
- Produces: `mintSession(scope, apple, secret) -> Promise<string>` (JWT payload `{scope, apple, iat, exp}`); `verifySession(tokenStr, secret) -> Promise<{scope, apple} | null>`.

- [ ] **Step 1: Establish current behavior (the "failing test")**

Run a node round-trip against the *current* helpers to capture the old shape:
```bash
cd ~/code/jianshuo.dev && node --input-type=module -e '
import { webcrypto as crypto } from "node:crypto"; globalThis.crypto ??= crypto;
const b64url=s=>Buffer.from(s).toString("base64url");
const bytesToB64url=b=>Buffer.from(b).toString("base64url");
async function hmacSign(d,sec){const k=await crypto.subtle.importKey("raw",new TextEncoder().encode(sec),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return bytesToB64url(new Uint8Array(await crypto.subtle.sign("HMAC",k,new TextEncoder().encode(d))));}
const now=Math.floor(Date.now()/1000);
const h=b64url(JSON.stringify({alg:"HS256",typ:"JWT"})), p=b64url(JSON.stringify({sub:"X",iat:now,exp:now+10}));
console.log("old payload has sub:", JSON.parse(Buffer.from(p,"base64url")).sub);
'
```
Expected now: `old payload has sub: X`. After this task the payload will carry `scope`/`apple`, not `sub`.

- [ ] **Step 2: Change `mintSession` signature + payload**

Replace:
```js
async function mintSession(sub, secret) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64url(JSON.stringify({ sub, iat: now, exp: now + 365 * 24 * 3600 }));
  const sig = await hmacSign(`${h}.${p}`, secret);
  return `${h}.${p}.${sig}`;
}
```
with:
```js
async function mintSession(scope, apple, secret) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64url(JSON.stringify({ scope, apple: !!apple, iat: now, exp: now + 365 * 24 * 3600 }));
  const sig = await hmacSign(`${h}.${p}`, secret);
  return `${h}.${p}.${sig}`;
}
```

- [ ] **Step 3: Change `verifySession` to return `{scope, apple}`**

Replace the tail of `verifySession`:
```js
  if (!payload.sub) return null;
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return payload.sub;
```
with:
```js
  if (!payload.scope) return null;
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return { scope: payload.scope, apple: !!payload.apple };
```

- [ ] **Step 4: Update the scope-resolution block**

In the auth block (~53–77), change the declarations and the session branch. Replace:
```js
  let scope = null; // null = unauthorized, '' = admin/full bucket, 'users/<id>/' = user
  let readonly = false;
```
with:
```js
  let scope = null; // null = unauthorized, '' = admin/full bucket, 'users/<id>/' = user
  let readonly = false;
  let apple = false; // true only for an Apple-verified session JWT (community write gate)
```
Then replace:
```js
    const sub = env.SESSION_SECRET ? await verifySession(token, env.SESSION_SECRET) : null;
    if (sub) {
      // Signed-in (Sign in with Apple) user.
      scope = `users/${sanitizeSeg(sub)}/`;
    } else {
```
with:
```js
    const sess = env.SESSION_SECRET ? await verifySession(token, env.SESSION_SECRET) : null;
    if (sess) {
      // Signed-in (Sign in with Apple) user — scope is carried in the JWT.
      scope = sess.scope;
      apple = sess.apple;
    } else {
```

- [ ] **Step 5: Verify round-trip with the new shape**

```bash
cd ~/code/jianshuo.dev && node --input-type=module -e '
import { webcrypto as crypto } from "node:crypto"; globalThis.crypto ??= crypto;
const b64url=s=>Buffer.from(s).toString("base64url");
const bytesToB64url=b=>Buffer.from(b).toString("base64url");
const b64urlToString=s=>Buffer.from(s,"base64url").toString();
function timingSafeEqual(a,b){if(a.length!==b.length)return false;let r=0;for(let i=0;i<a.length;i++)r|=a.charCodeAt(i)^b.charCodeAt(i);return r===0;}
async function hmacSign(d,sec){const k=await crypto.subtle.importKey("raw",new TextEncoder().encode(sec),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return bytesToB64url(new Uint8Array(await crypto.subtle.sign("HMAC",k,new TextEncoder().encode(d))));}
async function mintSession(scope,apple,secret){const now=Math.floor(Date.now()/1000);const h=b64url(JSON.stringify({alg:"HS256",typ:"JWT"}));const p=b64url(JSON.stringify({scope,apple:!!apple,iat:now,exp:now+10}));return `${h}.${p}.${await hmacSign(`${h}.${p}`,secret)}`;}
async function verifySession(t,sec){const[h,p,s]=t.split(".");if(!timingSafeEqual(s,await hmacSign(`${h}.${p}`,sec)))return null;const pl=JSON.parse(b64urlToString(p));if(!pl.scope)return null;return{scope:pl.scope,apple:!!pl.apple};}
const jwt=await mintSession("users/anon-abc/",true,"S");
console.log(JSON.stringify(await verifySession(jwt,"S")));
console.log("tamper:", await verifySession(jwt.slice(0,-2)+"xx","S"));
'
```
Expected: `{"scope":"users/anon-abc/","apple":true}` then `tamper: null`.

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev && git add "functions/files/api/[[path]].js"
git commit -m "auth: session JWT carries {scope, apple} instead of sub"
```

---

### Task 2: Pages — `auth/apple` binds (aliases) Apple identity to the anon scope

**Files:**
- Modify: `~/code/jianshuo.dev/functions/files/api/[[path]].js` — the `auth/apple` handler (~31–47); add helper `resolveAnonScope(token)` near the other helpers.

**Interfaces:**
- Consumes: `mintSession(scope, apple, secret)` (Task 1), `verifyAppleIdentityToken`, `sha256hex`, `sanitizeSeg`.
- Produces: binding records `links/apple-<sub>.json = {scope, linkedAt}` and `<scope>ACCOUNT.json = {appleSub, linkedAt}`; response `{ session, scope }`.

- [ ] **Step 1: Add a pure `anonScopeFromToken` helper (testable)**

Add near `sha256hex` (~487):
```js
// The users/anon-<hash>/ scope an anon token maps to (mirrors the inline anon logic).
async function anonScopeFromToken(token) {
  if (!token || !token.startsWith('anon_') || token.length < 20) return null;
  const id = (await sha256hex(token)).slice(0, 32);
  return `users/anon-${id}/`;
}
```

- [ ] **Step 2: Rewrite the `auth/apple` handler to bind-or-resolve**

Replace:
```js
    const session = await mintSession(sub, env.SESSION_SECRET);
    return json({ session, sub });
```
with:
```js
    // Bind (alias) this Apple identity to a data box. If we've seen this sub,
    // reuse its bound scope; otherwise bind it to the caller's current anon box
    // (no data moves) or a fresh users/<sub>/ if they have none.
    const linkKey = `links/apple-${sanitizeSeg(sub)}.json`;
    let scope = null;
    const existing = await env.FILES.get(linkKey);
    if (existing) {
      try { scope = JSON.parse(await existing.text()).scope; } catch {}
    }
    if (!scope) {
      const callerAnon = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      scope = (await anonScopeFromToken(callerAnon)) || `users/${sanitizeSeg(sub)}/`;
      const now = Date.now();
      await env.FILES.put(linkKey, JSON.stringify({ scope, linkedAt: now }),
        { httpMetadata: { contentType: 'application/json' } });
      await env.FILES.put(`${scope}ACCOUNT.json`, JSON.stringify({ appleSub: sub, linkedAt: now }),
        { httpMetadata: { contentType: 'application/json' } });
    }
    const session = await mintSession(scope, true, env.SESSION_SECRET);
    return json({ session, scope });
```

- [ ] **Step 3: Verify the binding logic locally (mock Apple verify)**

`verifyAppleIdentityToken` needs a real Apple token, so verify the *binding* against local R2 with a temporary shim. Start a local dev server:
```bash
cd ~/code/jianshuo.dev && npx wrangler pages dev . --port 8788 &
sleep 4
```
Seed an anon box, then drive the binding by calling the same R2 + helper logic via a one-off route is overkill — instead assert the two records appear after a real sign-in in Task 8's app verification. For now, statically verify the handler compiles:
```bash
node --check "functions/files/api/[[path]].js" && echo "syntax OK"
kill %1 2>/dev/null
```
Expected: `syntax OK`. (Full bind verification is in Task 8 — it requires a real Apple token.)

- [ ] **Step 4: Commit**

```bash
cd ~/code/jianshuo.dev && git add "functions/files/api/[[path]].js"
git commit -m "auth/apple: alias Apple identity to the caller's anon scope (bind, no migrate)"
```

---

### Task 3: Pages — community write routes require `apple:true`

**Files:**
- Modify: `~/code/jianshuo.dev/functions/files/api/[[path]].js` — `community/share` handler (~251) and `community/unshare` handler (~302).

**Interfaces:**
- Consumes: `apple` from the scope-resolution block (Task 1).
- Produces: `403 {error:"needs_apple_signin"}` for anon callers on share/unshare.

- [ ] **Step 1: Gate `community/share`**

Right after its existing `if (!scope) return json({ error: 'admin cannot share' }, 403);`, add:
```js
    if (!apple) return json({ error: 'needs_apple_signin' }, 403);
```

- [ ] **Step 2: Gate `community/unshare`**

In the `community/unshare` handler, right after its `if (!scope) …` guard (mirror the same line), add:
```js
    if (!apple) return json({ error: 'needs_apple_signin' }, 403);
```

- [ ] **Step 3: Verify with curl against the deployed function (after a later deploy) — for now, syntax + read-stays-open**

```bash
cd ~/code/jianshuo.dev && node --check "functions/files/api/[[path]].js" && echo "syntax OK"
```
Expected: `syntax OK`. Live check (post-deploy, Task 5): an anon-token `POST /files/api/community/share/articles/x.json` → `403 needs_apple_signin`; `GET /files/api/community/list` with the same anon token → still `200`.

- [ ] **Step 4: Commit**

```bash
cd ~/code/jianshuo.dev && git add "functions/files/api/[[path]].js"
git commit -m "community: require Apple-verified session to share/unshare (read stays open)"
```

---

### Task 4: Worker — mirror the JWT/scope change in `voicedrop-agent`

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/index.js` — `verifySession` (~ the copy in this file) and `resolveScope` (~347).

**Interfaces:**
- Produces: `verifySession -> {scope, apple} | null`; `resolveScope` returns the JWT's `scope`.

- [ ] **Step 1: Change the worker's `verifySession`**

Replace its tail:
```js
  if (!payload.sub) return null;
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return payload.sub;
```
with:
```js
  if (!payload.scope) return null;
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return { scope: payload.scope, apple: !!payload.apple };
```

- [ ] **Step 2: Update `resolveScope` to read the session scope**

In `resolveScope`, replace:
```js
  if (env.SESSION_SECRET) {
    const sub = await verifySession(token, env.SESSION_SECRET);
    if (sub) return `users/${sanitizeSeg(sub)}/`;
  }
```
with:
```js
  if (env.SESSION_SECRET) {
    const sess = await verifySession(token, env.SESSION_SECRET);
    if (sess) return sess.scope;
  }
```

- [ ] **Step 3: Verify syntax**

```bash
cd ~/code/jianshuo.dev/agent && node --check src/index.js && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/index.js
git commit -m "agent: mirror session JWT {scope, apple} change from the files API"
```

---

### Task 5: Ops — rotate `SESSION_SECRET` on both, then deploy Pages + Worker

**Files:** none (secrets + deploy).

**Interfaces:** Consumes Tasks 1–4. Produces a working deployed auth surface.

- [ ] **Step 1: Generate one fresh secret**

```bash
openssl rand -hex 32 | tee /tmp/vd_session_secret
```

- [ ] **Step 2: Set it on Pages + Worker (identical value)**

```bash
cd ~/code/jianshuo.dev && cat /tmp/vd_session_secret | tr -d '\n' | npx wrangler pages secret put SESSION_SECRET --project-name jianshuo-dev
cd ~/code/jianshuo.dev/agent && cat /tmp/vd_session_secret | tr -d '\n' | npx wrangler secret put SESSION_SECRET
```
Expected: two `✨ Success! Uploaded secret SESSION_SECRET`.

- [ ] **Step 3: Deploy both**

```bash
cd ~/code/jianshuo.dev && npx wrangler pages deploy . --project-name jianshuo-dev
cd ~/code/jianshuo.dev/agent && npx wrangler deploy
```
Expected: both report a successful deployment URL.

- [ ] **Step 4: Live verify the community gate is active**

```bash
ANON="anon_$(openssl rand -hex 16)"
echo "share with anon (expect 403 needs_apple_signin):"
curl -s -o /dev/null -w "%{http_code}\n" -X POST "https://jianshuo.dev/files/api/community/share/articles/none.json" -H "Authorization: Bearer $ANON"
echo "community list with anon (expect 200):"
curl -s -o /dev/null -w "%{http_code}\n" "https://jianshuo.dev/files/api/community/list" -H "Authorization: Bearer $ANON"
rm -f /tmp/vd_session_secret
```
Expected: `403` then `200`.

- [ ] **Step 5: Commit (none — secrets are out-of-tree). Record the rotation in the IT log.**

Append a `2026-06-23` entry to `~/Library/Mobile Documents/com~apple~CloudDocs/我的重要文档/我的账户和密码/IT基础设施-更改记录.html` noting `SESSION_SECRET` rotated on Pages `jianshuo-dev` + Worker `voicedrop-agent` (value in `/tmp/vd_session_secret` was deleted; store it in the vault if you want it recorded).

---

### Task 6: App — send the anon token on exchange + prefer the JWT bearer

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/AppleAuth.swift` — `exchange(identityToken:)`.

**Interfaces:**
- Consumes: `auth/apple` now reads `Authorization: Bearer <anonToken>` to bind (Task 2).
- Produces: after `exchange`, `session` resolves to the **same** scope as the anon box.

- [ ] **Step 1: Send the anon token so the server can bind to the existing box**

In `exchange(identityToken:)`, after `req.setValue("application/json", forHTTPHeaderField: "Content-Type")`, add:
```swift
        req.setValue("Bearer \(anonToken)", forHTTPHeaderField: "Authorization")
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head
```
Expected: `** BUILD SUCCEEDED **`. (`bearer` already prefers `session` over `anonToken`, so no change needed there.)

- [ ] **Step 3: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/AppleAuth.swift
git commit -m "auth: send anon token on Apple exchange so the server binds the existing box"
```

---

### Task 7: App — Sign-in-with-Apple UI flow + Settings entry

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/VoiceDrop.entitlements` (add the capability), `~/code/voicedrop/VoiceDropApp/AppleAuth.swift` (add a sign-in coordinator), `~/code/voicedrop/VoiceDropApp/AccountView.swift` or `SettingsView.swift` (add the 用 Apple 登录 button).

**Interfaces:**
- Produces: `AuthStore.signInWithApple() async` — runs `ASAuthorizationController`, extracts `identityToken`, calls `exchange`.

- [ ] **Step 1: Add the Sign in with Apple entitlement**

Ensure `VoiceDrop.entitlements` contains:
```xml
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
```
(And confirm the capability is enabled for the App ID in the Apple Developer portal / signing config.)

- [ ] **Step 2: Add a sign-in coordinator to `AuthStore`**

Append to `AuthStore` (it's `@MainActor`):
```swift
    /// Present the system Sign-in-with-Apple sheet, then exchange the identity
    /// token for a session JWT bound to this user's existing anon box.
    func signInWithApple() async {
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.fullName]
        do {
            let auth = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorization, Error>) in
                let c = AppleSignInCoordinator(cont)
                appleCoordinator = c
                let ctrl = ASAuthorizationController(authorizationRequests: [req])
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
        appleCoordinator = nil
    }
```
Add a stored property to `AuthStore`: `private var appleCoordinator: AppleSignInCoordinator?` and `import AuthenticationServices` at the top of the file. Then add the coordinator type at file scope:
```swift
private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let cont: CheckedContinuation<ASAuthorization, Error>
    init(_ cont: CheckedContinuation<ASAuthorization, Error>) { self.cont = cont }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) { cont.resume(returning: authorization) }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { cont.resume(throwing: error) }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
```

- [ ] **Step 3: Add the 用 Apple 登录 entry in the account UI**

In the account section (`AccountView.swift` or `SettingsView.swift`'s 账户 block), add — shown only when `!AuthStore.shared.isAuthenticated`:
```swift
Button { Task { await AuthStore.shared.signInWithApple() } } label: {
    Label("用 Apple 登录（同步设备 · 参与社区）", systemImage: "applelogo")
}
```
And when authenticated, show `已用 Apple 登录` + a 退出登录 button calling `AuthStore.shared.signOut()`.

- [ ] **Step 4: Build**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/AppleAuth.swift VoiceDropApp/VoiceDrop.entitlements VoiceDropApp/AccountView.swift VoiceDropApp/SettingsView.swift
git commit -m "auth: Sign-in-with-Apple sheet + 账户 entry (optional, for cross-device)"
```

---

### Task 8: App — community boundary triggers sign-in, then retries

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/Community.swift` — `share(_:)` and `unshare(_:)`; `~/code/voicedrop/VoiceDropApp/RecordingDetailView.swift` — the 分享到 VD社区 action's toast/explainer.

**Interfaces:**
- Consumes: server `403 {error:"needs_apple_signin"}` (Task 3); `AuthStore.shared.signInWithApple()` (Task 7).
- Produces: a transparent "sign in once, then the share goes through" UX.

- [ ] **Step 1: Make `CommunityStore.share` handle the 403 → sign in → retry**

In `Community.swift`, change `share(_ rec:)` so a `403` body of `needs_apple_signin` triggers Apple sign-in and one retry. Replace the request/response block with:
```swift
    func share(_ rec: Recording) async -> Bool {
        guard !token.isEmpty, rec.hasArticles else { return false }
        if await postShare(rec) { return true }
        // Not Apple-verified yet → sign in once and retry.
        if needsAppleSignIn {
            await AuthStore.shared.signInWithApple()
            guard AuthStore.shared.isAuthenticated else { return false }
            return await postShare(rec)
        }
        return false
    }

    private var needsAppleSignIn = false

    private func postShare(_ rec: Recording) async -> Bool {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "share").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { needsAppleSignIn = false; return true }
            needsAppleSignIn = (code == 403) &&
                ((try? JSONDecoder().decode([String:String].self, from: data))?["error"] == "needs_apple_signin")
            return false
        } catch { return false }
    }
```
(`token` reads `AuthStore.shared.bearer`, which flips to the JWT after sign-in.)

- [ ] **Step 2: Mirror the same retry in `unshare(_:)`**

Apply the identical "try → if `needs_apple_signin` sign in → retry once" wrapper to `unshare(_ shareId:)`.

- [ ] **Step 3: Add the one-line explainer at the boundary**

In `RecordingDetailView.swift`'s `shareToCommunity()`, before calling `community.share`, if `!AuthStore.shared.isAuthenticated` show a toast `"分享到社区需要用 Apple 登录，确认你是同一个人"` (the sheet then appears via the retry path).

- [ ] **Step 4: Build**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: End-to-end verification (device/simulator + R2)**

1. Fresh anon user records → mines an article. Tap **分享到 VD社区** → Apple sheet appears → complete → the post appears, authored by the 名字, `mine=true`.
2. Confirm no data moved: `curl -s "https://jianshuo.dev/files/api/list" -H "Authorization: Bearer <the JWT from the app>"` lists the **same** recordings the anon user had (the JWT resolves to `users/anon-X/`).
3. Confirm bindings exist (admin token): `links/apple-<sub>.json` and `users/anon-X/ACCOUNT.json` are present.
4. Reading the community while logged out / anon still returns `200`.
5. Apple JWT works on the agent worker: the app's live 处理中 status + voice editing function while signed in.

- [ ] **Step 6: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/Community.swift VoiceDropApp/RecordingDetailView.swift
git commit -m "community: sign in with Apple at the share boundary, then retry transparently"
```

---

## Notes for the implementer

- Do Tasks 1→5 (server/worker/secrets) before the app tasks — the app's end-to-end check depends on the deployed gate.
- Tasks 1 and 4 are the *same* JWT change in two files; keep them byte-identical.
- `verifyAppleIdentityToken` can't be exercised without a real Apple token, so the binding's full proof lives in Task 8 (real sign-in). Tasks 2–3 verify syntax + the read-open/write-gated behavior with anon tokens only.
- The app already stores both `anonToken` and `session` in the iCloud-synced Keychain and `bearer` already prefers `session`; we are only adding the *sign-in trigger* and the *bind* wiring.

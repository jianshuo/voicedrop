# 设备配对：新设备登录老账号 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一台新设备通过「输入老账号 6 位短码 → 老设备弹 4 位验证码 → 新设备输码」把老账号的 `anon_…` 密钥端到端加密搬到本机，从而登录老账号。

**Architecture:** 复用现有 `StatusHub` WebSocket 长链接做推送；新增一个轻量 per-pairing `LinkBroker` Durable Object 暂存配对状态并把密文中转给新设备；全部业务逻辑抽到纯模块 `agent/src/devicelink.js`（vitest TDD），DO 与路由是薄壳。token 用 X25519+AES-GCM 端到端加密，服务器只过公钥与密文。

**Tech Stack:** Cloudflare Worker（Durable Objects, R2）+ vitest；iOS SwiftUI + CryptoKit（Curve25519 / HKDF / AES.GCM）；xcodegen。

## Global Constraints

- **两个 repo**：Worker 改动在 `~/code/jianshuo.dev`（Phase 1）；iOS 改动在 `~/code/voicedrop`（Phase 2）。每个 commit 看清 cwd。
- **测试命令**：`cd ~/code/jianshuo.dev/agent && npm test`（= `vitest run`）。单文件：`npx vitest run test/devicelink.test.js`。改动前后都要跑、确保无回归。
- **无 DO 测试基建**：仓库用纯 vitest，从不直接测 Durable Object / Worker `fetch`。所有可测逻辑放进 `agent/src/devicelink.js` 纯函数；`LinkBroker` DO 和 `/agent/link/*` 路由是薄壳，**不写自动化测试**，靠 Task 7 deploy 冒烟 + Phase 2 iOS 手测验证。
- **标识**：6 位 = `sha256(anon_token)` 前 6 位十六进制，**大小写不敏感**，比对前 `toLowerCase()`。
- **协议常量**（写在 `devicelink.js`）：`CODE_TTL_MS = 120000`、`MAX_ATTEMPTS = 5`、`MAX_MATCH = 10`。
- **端到端加密**：X25519 → HKDF-SHA256（`salt="voicedrop-device-link/v1"`、`info="anon-token"`、32 字节）→ AES-GCM。`blob = { epk:<b64url 老设备临时公钥>, sealed:<b64url AES.GCM.combined（nonce+ct+tag）> }`。服务器只过 `pubkey`（start→link_request）和 `blob`（complete→link_ready），不解密、不持久（除 complete→ready 的瞬时中转）。
- **放行鉴权**：`/agent/link/complete` 必须 `callerScope === releasingScope`，否则 403。
- **DO 注册**：`agent/wrangler.jsonc` 加 binding + migration（`new_sqlite_classes`），文件是 **JSONC（带注释）**，编辑要保留注释。
- **部署**：Worker `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`；iOS 加新文件后跑 `xcodegen generate` 再 build；推 `main` → GitHub Actions → TestFlight。部署由用户确认后执行。
- **本期不实现**：CLI / headless 分身登录（spec §11）。
- **iOS 构建命令**：下文用 `-scheme VoiceDrop` + `name=iPhone 15`，请先用 `xcodebuild -list -project VoiceDrop.xcodeproj`（确认 scheme 名）和 `xcrun simctl list devices available`（确认机型）按本机实际替换。`VoiceDrop.xcodeproj` 由 xcodegen 本地生成、**未入库**，所有 `git add` **不要**加它。
- **已知延后项（不在本期）**：spec §7 的「/start 按 IP+token 限流」未实现——Worker 现无 KV 计数基建。本计划只做最小闸门（start/verify/complete 必须带有效 bearer，complete 还强制 scope 匹配）。真正的速率限制留作后续（加一个 KV 计数器）。
- **canonical spec**：`~/code/voicedrop/docs/superpowers/specs/2026-06-27-device-link-pairing-design.md`。

---

# Phase 1 — Worker（`~/code/jianshuo.dev`，TDD）

### Task 1: `devicelink.js` 常量 + `genDistinctCodes` + `buildBroadcastMessage`

**Files:**
- Create: `agent/src/devicelink.js`
- Test: `agent/test/devicelink.test.js`

**Interfaces:**
- Produces:
  - `CODE_TTL_MS=120000`, `MAX_ATTEMPTS=5`, `MAX_MATCH=10`
  - `genDistinctCodes(n: number, randInt?: (max:number)=>number): string[]` — n 个互不相同的 4 位零填充码
  - `buildBroadcastMessage(body: object): object` — `body.payload ?? {type:"status_update",stem,status}`

- [ ] **Step 1: Write the failing test**

Create `agent/test/devicelink.test.js`:

```js
import { describe, it, expect } from "vitest";
import { genDistinctCodes, buildBroadcastMessage, CODE_TTL_MS, MAX_ATTEMPTS, MAX_MATCH } from "../src/devicelink.js";

describe("constants", () => {
  it("are the agreed protocol values", () => {
    expect(CODE_TTL_MS).toBe(120000);
    expect(MAX_ATTEMPTS).toBe(5);
    expect(MAX_MATCH).toBe(10);
  });
});

describe("genDistinctCodes", () => {
  it("returns n distinct 4-digit zero-padded codes even when the rng collides", () => {
    // rng yields: 7,7,7,42 -> must skip the dup 7s and still produce 2 distinct
    const seq = [7, 7, 7, 42];
    let i = 0;
    const codes = genDistinctCodes(2, () => seq[i++]);
    expect(codes).toEqual(["0007", "0042"]);
    expect(new Set(codes).size).toBe(2);
  });
});

describe("buildBroadcastMessage", () => {
  it("passes an explicit payload through verbatim", () => {
    const p = { type: "link_request", pairingId: "x", code: "0001", pubkey: "k" };
    expect(buildBroadcastMessage({ payload: p })).toEqual(p);
  });
  it("falls back to the legacy status_update shape (back-compat)", () => {
    expect(buildBroadcastMessage({ stem: "s1", status: "ready" }))
      .toEqual({ type: "status_update", stem: "s1", status: "ready" });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: FAIL — `Failed to resolve import "../src/devicelink.js"`.

- [ ] **Step 3: Write minimal implementation**

Create `agent/src/devicelink.js`:

```js
// Device-link pairing — pure logic (no Durable Object, no I/O except injected env.FILES).
// The LinkBroker DO and /agent/link/* routes in index.js are thin shells over these.
import { timingSafeEqual } from "../../functions/lib/auth.js";

export const CODE_TTL_MS = 120000; // 2 min
export const MAX_ATTEMPTS = 5;
export const MAX_MATCH = 10;

function defaultRandInt(max) {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return buf[0] % max;
}

// n distinct 4-digit zero-padded codes. randInt injectable for deterministic tests.
export function genDistinctCodes(n, randInt = defaultRandInt) {
  if (n > 10000) throw new Error("cannot make more than 10000 distinct 4-digit codes");
  const set = new Set();
  while (set.size < n) set.add(String(randInt(10000)).padStart(4, "0"));
  return [...set];
}

// StatusHub broadcast payload: explicit payload wins; else legacy status_update shape.
export function buildBroadcastMessage(body) {
  return body.payload ?? { type: "status_update", stem: body.stem, status: body.status };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: PASS (3 files of assertions green).

- [ ] **Step 5: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/devicelink.js agent/test/devicelink.test.js
git commit -m "feat(agent): device-link pure helpers — codes + broadcast message builder"
```

---

### Task 2: `resolveMatchingScopes` — R2 前缀解析匹配账号

**Files:**
- Modify: `agent/src/devicelink.js`
- Test: `agent/test/devicelink.test.js`

**Interfaces:**
- Consumes: `env.FILES.list({prefix})` → `{objects:[{key}]}`（见 `agent/test/fakes.js`）
- Produces: `resolveMatchingScopes(env, prefix: string, max?=MAX_MATCH): Promise<string[]>` — 返回去重后的 `users/anon-<32hex>/` scope 数组；prefix 非 6 位十六进制 → `[]`

- [ ] **Step 1: Write the failing test**

Append to `agent/test/devicelink.test.js`:

```js
import { resolveMatchingScopes } from "../src/devicelink.js";
import { fakeEnv } from "./fakes.js";

describe("resolveMatchingScopes", () => {
  const H1 = "7f3a9c" + "0".repeat(26); // two distinct 32-hex hashes sharing prefix 7f3a9c
  const H2 = "7f3a9c" + "1".repeat(26);
  const OTHER = "abcdef" + "0".repeat(26);

  it("dedups to distinct user scopes that share the 6-hex prefix", async () => {
    const env = fakeEnv({
      [`users/anon-${H1}/articles/a.json`]: "{}",
      [`users/anon-${H1}/VoiceDrop-x.m4a`]: "{}",
      [`users/anon-${H2}/articles/b.json`]: "{}",
      [`users/anon-${OTHER}/articles/c.json`]: "{}",
    });
    const scopes = await resolveMatchingScopes(env, "7F3A9C"); // case-insensitive
    expect(scopes.sort()).toEqual([`users/anon-${H1}/`, `users/anon-${H2}/`]);
  });

  it("returns [] for a malformed prefix", async () => {
    expect(await resolveMatchingScopes(fakeEnv(), "xyz")).toEqual([]);
    expect(await resolveMatchingScopes(fakeEnv(), "7f3a9")).toEqual([]);
  });

  it("returns [] when nothing matches", async () => {
    const env = fakeEnv({ [`users/anon-${OTHER}/articles/c.json`]: "{}" });
    expect(await resolveMatchingScopes(env, "7f3a9c")).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: FAIL — `resolveMatchingScopes is not a function`.

- [ ] **Step 3: Write minimal implementation**

Append to `agent/src/devicelink.js`:

```js
// List objects under users/anon-<6hex> and dedup the distinct users/anon-<32hex>/ scopes.
// (Derived from object keys — works with both real R2 and the Map-backed test fake,
// and avoids depending on R2 list delimiter support.)
export async function resolveMatchingScopes(env, prefix, max = MAX_MATCH) {
  if (!/^[0-9a-fA-F]{6}$/.test(prefix || "")) return [];
  const p = prefix.toLowerCase();
  const { objects } = await env.FILES.list({ prefix: "users/anon-" + p });
  const scopes = new Set();
  for (const o of objects) {
    const m = o.key.match(/^(users\/anon-[0-9a-f]{32}\/)/);
    if (m) scopes.add(m[1]);
    if (scopes.size >= max) break;
  }
  return [...scopes];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: PASS.

- [ ] **Step 5: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/devicelink.js agent/test/devicelink.test.js
git commit -m "feat(agent): device-link prefix resolver over R2 keys"
```

---

### Task 3: 配对状态机 `createPairing` / `verifyPairing` / `completePairing` / `isExpired`

**Files:**
- Modify: `agent/src/devicelink.js`
- Test: `agent/test/devicelink.test.js`

**Interfaces:**
- Produces:
  - `createPairing({pubkey, entries, now, ttlMs?}): State` — `State = {createdAt,ttlMs,attempts,status,pubkey,entries,releasingScope,blob}`，`entries=[{scope,code}]`，`status` 初值 `"pending"`
  - `isExpired(state, now): boolean`
  - `verifyPairing(state, code, now): {state, result}` — result: `{ok:true,scope}` | `{ok:false,remaining,dead}` | `{ok:false,expired:true}` | `{ok:false,dead:true}`
  - `completePairing(state, callerScope, blob, now): {state, result}` — result: `{ok:true}` | `{ok:false,error:"not_verified"|"forbidden"|...}` | `{ok:false,expired:true}`

- [ ] **Step 1: Write the failing test**

Append to `agent/test/devicelink.test.js`:

```js
import { createPairing, verifyPairing, completePairing, isExpired } from "../src/devicelink.js";

const ENTRIES = [{ scope: "users/anon-aaa/", code: "1234" }, { scope: "users/anon-bbb/", code: "5678" }];
function fresh(now = 1000) { return createPairing({ pubkey: "PK", entries: ENTRIES, now }); }

describe("createPairing", () => {
  it("starts pending with zero attempts and the agreed ttl", () => {
    const s = fresh();
    expect(s.status).toBe("pending");
    expect(s.attempts).toBe(0);
    expect(s.ttlMs).toBe(120000);
    expect(s.releasingScope).toBe(null);
    expect(s.blob).toBe(null);
  });
});

describe("verifyPairing", () => {
  it("wrong code decrements remaining, stays pending", () => {
    const { state, result } = verifyPairing(fresh(), "0000", 2000);
    expect(result).toEqual({ ok: false, remaining: 4, dead: false });
    expect(state.status).toBe("pending");
    expect(state.attempts).toBe(1);
  });

  it("correct code -> verified + releasingScope = that entry's scope", () => {
    const { state, result } = verifyPairing(fresh(), "5678", 2000);
    expect(result).toEqual({ ok: true, scope: "users/anon-bbb/" });
    expect(state.status).toBe("verified");
    expect(state.releasingScope).toBe("users/anon-bbb/");
  });

  it("dies after MAX_ATTEMPTS wrong tries", () => {
    let s = fresh();
    let r;
    for (let i = 0; i < 5; i++) ({ state: s, result: r } = verifyPairing(s, "0000", 2000));
    expect(r.dead).toBe(true);
    expect(s.status).toBe("dead");
    // a 6th attempt is rejected as dead
    expect(verifyPairing(s, "1234", 2000).result).toEqual({ ok: false, dead: true });
  });

  it("rejects once expired", () => {
    const { result } = verifyPairing(fresh(1000), "1234", 1000 + 120001);
    expect(result).toEqual({ ok: false, expired: true });
  });
});

describe("completePairing", () => {
  function verified() { return verifyPairing(fresh(), "1234", 2000).state; } // releasingScope = aaa
  it("ok when caller scope matches releasingScope", () => {
    const { state, result } = completePairing(verified(), "users/anon-aaa/", { epk: "e", sealed: "s" }, 3000);
    expect(result).toEqual({ ok: true });
    expect(state.status).toBe("done");
    expect(state.blob).toEqual({ epk: "e", sealed: "s" });
  });
  it("forbidden when caller scope differs", () => {
    expect(completePairing(verified(), "users/anon-bbb/", {}, 3000).result)
      .toEqual({ ok: false, error: "forbidden" });
  });
  it("rejects when not yet verified", () => {
    expect(completePairing(fresh(), "users/anon-aaa/", {}, 3000).result)
      .toEqual({ ok: false, error: "not_verified" });
  });
});

describe("isExpired", () => {
  it("true past ttl", () => {
    expect(isExpired(fresh(1000), 1000 + 120001)).toBe(true);
    expect(isExpired(fresh(1000), 1000 + 1)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: FAIL — `createPairing is not a function`.

- [ ] **Step 3: Write minimal implementation**

Append to `agent/src/devicelink.js`:

```js
export function createPairing({ pubkey, entries, now, ttlMs = CODE_TTL_MS }) {
  return { createdAt: now, ttlMs, attempts: 0, status: "pending", pubkey, entries, releasingScope: null, blob: null };
}

export function isExpired(s, now) {
  return now - s.createdAt > s.ttlMs;
}

export function verifyPairing(s, code, now) {
  if (isExpired(s, now)) return { state: { ...s, status: "expired" }, result: { ok: false, expired: true } };
  if (s.status !== "pending") return { state: s, result: { ok: false, dead: true } };
  const attempts = s.attempts + 1;
  const entry = s.entries.find((e) => timingSafeEqual(e.code, String(code)));
  if (!entry) {
    const dead = attempts >= MAX_ATTEMPTS;
    return {
      state: { ...s, attempts, status: dead ? "dead" : "pending" },
      result: { ok: false, remaining: Math.max(0, MAX_ATTEMPTS - attempts), dead },
    };
  }
  return {
    state: { ...s, attempts, status: "verified", releasingScope: entry.scope },
    result: { ok: true, scope: entry.scope },
  };
}

export function completePairing(s, callerScope, blob, now) {
  if (isExpired(s, now)) return { state: { ...s, status: "expired" }, result: { ok: false, expired: true } };
  if (s.status !== "verified") return { state: s, result: { ok: false, error: "not_verified" } };
  if (callerScope !== s.releasingScope) return { state: s, result: { ok: false, error: "forbidden" } };
  return { state: { ...s, status: "done", blob }, result: { ok: true } };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/devicelink.test.js`
Expected: PASS.

- [ ] **Step 5: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/devicelink.js agent/test/devicelink.test.js
git commit -m "feat(agent): device-link pairing state machine (verify/complete/expire)"
```

---

### Task 4: `StatusHub` 广播泛化（接 `buildBroadcastMessage`）

**Files:**
- Modify: `agent/src/index.js`（`StatusHub` class，约 297-304 行）

**Interfaces:**
- Consumes: `buildBroadcastMessage(body)`（Task 1）
- Produces: `StatusHub` `/broadcast` 现在转发 `body.payload`（若有），否则旧的 `status_update` 形状

- [ ] **Step 1: Add the import**

In `agent/src/index.js`, the existing device-link import will be added in Task 6; for now extend the top imports. Find line 23:

```js
import { verifySession, anonScopeFromToken } from "../../functions/lib/auth.js";
```

Add immediately after it:

```js
import { buildBroadcastMessage } from "./devicelink.js";
```

- [ ] **Step 2: Generalize the broadcast block**

In `StatusHub.fetch`, replace this exact block:

```js
    if (request.method === "POST" && url.pathname.endsWith("/broadcast")) {
      const body = await request.json();
      const msg = JSON.stringify({ type: "status_update", stem: body.stem, status: body.status });
      for (const ws of this.state.getWebSockets()) {
        try { ws.send(msg); } catch (_) {}
      }
      return new Response("ok");
    }
```

with:

```js
    if (request.method === "POST" && url.pathname.endsWith("/broadcast")) {
      const body = await request.json();
      const msg = JSON.stringify(buildBroadcastMessage(body));
      for (const ws of this.state.getWebSockets()) {
        try { ws.send(msg); } catch (_) {}
      }
      return new Response("ok");
    }
```

- [ ] **Step 3: Verify the full suite still passes (back-compat)**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS — all existing tests green (the `status_update` path is unchanged because `/agent/notify` sends `{stem,status}` with no `payload`, which `buildBroadcastMessage` maps to the legacy shape; that mapping is covered by Task 1's test).

- [ ] **Step 4: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/index.js
git commit -m "refactor(agent): StatusHub broadcast forwards arbitrary payloads (back-compat)"
```

---

### Task 5: `LinkBroker` Durable Object + wrangler 绑定/迁移

**Files:**
- Modify: `agent/src/index.js`（新增 `export class LinkBroker`，建议放在 `Miner` 类之后）
- Modify: `agent/wrangler.jsonc`（binding + migration v4）

**Interfaces:**
- Consumes: `createPairing`/`verifyPairing`/`completePairing`（Task 3），`CODE_TTL_MS`
- Produces: DO 类 `LinkBroker`，按 `idFromName(pairingId)` 寻址；HTTP ops `{op:"create"|"verify"|"complete"|"cancel", ...}`；WS upgrade = 新设备等待通道，DO 在 complete 时推 `{type:"link_ready",blob}`，alarm 到期推 `{type:"link_expired"}`，cancel 推 `{type:"link_cancelled"}`

- [ ] **Step 1: Extend the device-link import in index.js**

Replace the line added in Task 4 Step 1:

```js
import { buildBroadcastMessage } from "./devicelink.js";
```

with:

```js
import { buildBroadcastMessage, createPairing, verifyPairing, completePairing, resolveMatchingScopes, genDistinctCodes, CODE_TTL_MS } from "./devicelink.js";
```

- [ ] **Step 2: Add the `LinkBroker` DO class**

In `agent/src/index.js`, after the closing `}` of `export class Miner { ... }` (around line 333), add:

```js
// ---------------------------------------------------------------------------
// LinkBroker: per-pairing Durable Object (idFromName(pairingId)). Holds the
// pairing state and the NEW device's wait-socket. Self-expires via alarm().
// All decision logic lives in devicelink.js — this is a thin shell.
// ---------------------------------------------------------------------------
export class LinkBroker {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    // New device's wait-socket.
    if (request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server);
      const s = await this.state.storage.get("pairing");
      if (s && s.blob) { try { server.send(JSON.stringify({ type: "link_ready", blob: s.blob })); } catch (_) {} }
      return new Response(null, { status: 101, webSocket: client });
    }

    const body = await request.json().catch(() => ({}));
    const now = Date.now();

    if (body.op === "create") {
      const s = createPairing({ pubkey: body.pubkey, entries: body.entries, now, ttlMs: CODE_TTL_MS });
      await this.state.storage.put("pairing", s);
      await this.state.storage.setAlarm(now + CODE_TTL_MS);
      return Response.json({ ok: true });
    }

    const s = await this.state.storage.get("pairing");
    if (!s) return Response.json({ ok: false, error: "not_found" }, { status: 404 });

    if (body.op === "verify") {
      const { state, result } = verifyPairing(s, body.code, now);
      await this.state.storage.put("pairing", state);
      return Response.json(result);
    }

    if (body.op === "complete") {
      const { state, result } = completePairing(s, body.callerScope, body.blob, now);
      await this.state.storage.put("pairing", state);
      if (result.ok) {
        for (const ws of this.state.getWebSockets()) {
          try { ws.send(JSON.stringify({ type: "link_ready", blob: body.blob })); } catch (_) {}
        }
      }
      return Response.json(result, { status: result.ok ? 200 : 403 });
    }

    if (body.op === "cancel") {
      if (!s.entries.some((e) => e.scope === body.callerScope)) {
        return Response.json({ ok: false, error: "forbidden" }, { status: 403 });
      }
      for (const ws of this.state.getWebSockets()) {
        try { ws.send(JSON.stringify({ type: "link_cancelled" })); } catch (_) {}
      }
      await this.state.storage.delete("pairing");
      return Response.json({ ok: true });
    }

    return new Response("bad op", { status: 400 });
  }

  async alarm() {
    for (const ws of this.state.getWebSockets()) {
      try { ws.send(JSON.stringify({ type: "link_expired" })); } catch (_) {}
    }
    await this.state.storage.delete("pairing");
  }

  webSocketMessage(_ws, _msg) {}
  webSocketClose(_ws) {}
  webSocketError(_ws) {}
}
```

- [ ] **Step 3: Register the DO in wrangler.jsonc**

In `agent/wrangler.jsonc`, add the binding to the `durable_objects.bindings` array (after the `Miner` line):

```jsonc
      { "name": "Miner",         "class_name": "Miner"         },
      { "name": "LinkBroker",    "class_name": "LinkBroker"    }
```

and add a new migration entry to the `migrations` array (after `v3`):

```jsonc
    { "tag": "v3", "new_sqlite_classes": ["Miner"] },
    { "tag": "v4", "new_sqlite_classes": ["LinkBroker"] }
```

(Remember to add the comma after the previous array element where needed; keep the JSONC comments intact.)

- [ ] **Step 4: Confirm it parses + suite still green**

Run: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy --dry-run 2>&1 | tail -5`
Expected: a dry-run that completes without a config/parse error (it should list the bindings incl. `LinkBroker`). If `--dry-run` needs auth, at minimum it must not error on config parse.

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (no regression — this task adds code but doesn't change existing paths).

- [ ] **Step 5: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/index.js agent/wrangler.jsonc
git commit -m "feat(agent): LinkBroker durable object + wrangler binding/migration"
```

---

### Task 6: `/agent/link/*` 路由（start/socket/verify/complete/cancel）

**Files:**
- Modify: `agent/src/index.js`（default `fetch` 路由块；新增 `randomId` 辅助）

**Interfaces:**
- Consumes: `resolveScope`（index.js 现有），`resolveMatchingScopes`/`genDistinctCodes`（Task 1/2），`env.LinkBroker`/`env.StatusHub`
- Produces: HTTP/WS endpoints under `/agent/link/`

- [ ] **Step 1: Add a `randomId` helper**

In `agent/src/index.js`, next to `sanitizeName` (around line 438), add:

```js
function randomId() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}
```

- [ ] **Step 2: Add the routes**

In the default `fetch` handler, immediately BEFORE the final `return new Response("not found", { status: 404 });`, insert:

```js
    // ── /agent/link/* ── device-link pairing (new device logs into old account) ──
    if (url.pathname === "/agent/link/start") {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
      const tok = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      if (!(await resolveScope(tok, env))) return new Response("unauthorized", { status: 401 });
      const { prefix, pubkey } = await request.json().catch(() => ({}));
      if (!/^[0-9a-fA-F]{6}$/.test(prefix || "") || !pubkey) return new Response("bad request", { status: 400 });
      const scopes = await resolveMatchingScopes(env, prefix);
      if (scopes.length === 0) return Response.json({ ok: false, reason: "no_match" });
      const codes = genDistinctCodes(scopes.length);
      const entries = scopes.map((scope, i) => ({ scope, code: codes[i] }));
      const pairingId = randomId();
      const broker = env.LinkBroker.get(env.LinkBroker.idFromName(pairingId));
      await broker.fetch(new Request("https://link/op", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ op: "create", pubkey, entries }),
      }));
      for (const { scope, code } of entries) {
        const hub = env.StatusHub.get(env.StatusHub.idFromName("status:" + scope));
        await hub.fetch(new Request("https://status-hub/broadcast", {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ payload: { type: "link_request", pairingId, code, pubkey } }),
        }));
      }
      return Response.json({ ok: true, pairingId, matchCount: scopes.length });
    }

    if (url.pathname === "/agent/link/socket") {
      if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
      const pairingId = url.searchParams.get("pairingId") || "";
      if (!/^[0-9a-f]{32}$/.test(pairingId)) return new Response("bad request", { status: 400 });
      const broker = env.LinkBroker.get(env.LinkBroker.idFromName(pairingId));
      return broker.fetch(request);
    }

    if (url.pathname === "/agent/link/verify") {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
      const tok = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      if (!(await resolveScope(tok, env))) return new Response("unauthorized", { status: 401 });
      const { pairingId, code } = await request.json().catch(() => ({}));
      if (!/^[0-9a-f]{32}$/.test(pairingId || "") || !/^\d{4}$/.test(code || "")) return new Response("bad request", { status: 400 });
      const broker = env.LinkBroker.get(env.LinkBroker.idFromName(pairingId));
      const r = await broker.fetch(new Request("https://link/op", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ op: "verify", code }),
      }));
      const result = await r.json();
      if (result.ok) {
        const hub = env.StatusHub.get(env.StatusHub.idFromName("status:" + result.scope));
        await hub.fetch(new Request("https://status-hub/broadcast", {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ payload: { type: "link_release", pairingId } }),
        }));
      }
      // never leak the matched scope to the new device
      return Response.json({ ok: !!result.ok, remaining: result.remaining, dead: result.dead, expired: result.expired });
    }

    if (url.pathname === "/agent/link/complete") {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
      const tok = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const caller = await resolveScope(tok, env);
      if (!caller) return new Response("unauthorized", { status: 401 });
      const { pairingId, blob } = await request.json().catch(() => ({}));
      if (!/^[0-9a-f]{32}$/.test(pairingId || "") || !blob) return new Response("bad request", { status: 400 });
      const broker = env.LinkBroker.get(env.LinkBroker.idFromName(pairingId));
      const r = await broker.fetch(new Request("https://link/op", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ op: "complete", callerScope: caller, blob }),
      }));
      return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
    }

    if (url.pathname === "/agent/link/cancel") {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
      const tok = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const caller = await resolveScope(tok, env);
      if (!caller) return new Response("unauthorized", { status: 401 });
      const { pairingId } = await request.json().catch(() => ({}));
      if (!/^[0-9a-f]{32}$/.test(pairingId || "")) return new Response("bad request", { status: 400 });
      const broker = env.LinkBroker.get(env.LinkBroker.idFromName(pairingId));
      const r = await broker.fetch(new Request("https://link/op", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ op: "cancel", callerScope: caller }),
      }));
      return new Response(await r.text(), { status: r.status, headers: { "content-type": "application/json" } });
    }
```

- [ ] **Step 3: Verify suite still passes**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (routes are untested by the harness per Global Constraints, but nothing existing should break).

- [ ] **Step 4: Commit** (repo: `~/code/jianshuo.dev`)

```bash
cd ~/code/jianshuo.dev
git add agent/src/index.js
git commit -m "feat(agent): /agent/link/* pairing routes (start/socket/verify/complete/cancel)"
```

---

### Task 7: 部署 Worker + 冒烟测试（集成闸门，iOS 之前必过）

**Files:** none (deploy + verify)

- [ ] **Step 1: Deploy（用户确认后执行）**

```bash
cd ~/code/jianshuo.dev/agent && npx wrangler deploy
```
Expected: 输出包含新增的 migration `v4` 应用、绑定列表含 `LinkBroker`。

- [ ] **Step 2: Smoke — `no_match` 路径（不需要真账号）**

```bash
curl -sS -X POST https://jianshuo.dev/agent/link/start \
  -H "Authorization: Bearer anon_zzzzzzzzzzzzzzzzzzzzzzzzzzzz" \
  -H 'content-type: application/json' \
  -d '{"prefix":"abcdef","pubkey":"AAAA"}'
```
Expected: `{"ok":false,"reason":"no_match"}`（前提：没有 `users/anon-abcdef…` 账号）。若返回 `{"ok":true,"pairingId":...}` 说明恰好有匹配账号，也算通。

- [ ] **Step 3: Smoke — 鉴权 & 入参校验**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://jianshuo.dev/agent/link/start \
  -H 'content-type: application/json' -d '{"prefix":"abcdef","pubkey":"AAAA"}'
# Expected: 401  (no bearer)

curl -s -o /dev/null -w "%{http_code}\n" -X POST https://jianshuo.dev/agent/link/start \
  -H "Authorization: Bearer anon_zzzzzzzzzzzzzzzzzzzzzzzzzzzz" \
  -H 'content-type: application/json' -d '{"prefix":"xyz","pubkey":"AAAA"}'
# Expected: 400  (bad prefix)
```

- [ ] **Step 4: Confirm no regression on existing endpoints**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://jianshuo.dev/agent/mine/trigger \
  -H "Authorization: Bearer anon_zzzzzzzzzzzzzzzzzzzzzzzzzzzz"
# Expected: 202 (queued) — proves the deploy didn't break routing
```

- [ ] **Step 5: (no commit — deploy only)**

---

# Phase 2 — iOS（`~/code/voicedrop`，实现 + 手测；无单测基建）

> 前置：Phase 1 已部署（Task 7 通过）。Phase 2 每个 task 末尾在 `~/code/voicedrop` 提交。

### Task 8: `DeviceLink.swift` — 端到端加密 `DeviceLinkCrypto`

**Files:**
- Create: `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`

**Interfaces:**
- Produces:
  - `DeviceLinkCrypto.newKeypair() -> (priv: Curve25519.KeyAgreement.PrivateKey, pubB64: String)`
  - `DeviceLinkCrypto.decrypt(epkB64:String, sealedB64:String, priv:Curve25519.KeyAgreement.PrivateKey) throws -> String`
  - `DeviceLinkCrypto.encrypt(token:String, toPubB64:String) throws -> (epkB64:String, sealedB64:String)`

- [ ] **Step 1: Create the file with the crypto enum**

Create `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate the Xcode project (new file)**

Run: `cd ~/code/voicedrop && xcodegen generate`
Expected: `Created project at .../VoiceDrop.xcodeproj` (DeviceLink.swift auto-included via project.yml globs).

- [ ] **Step 3: Manually verify the crypto round-trips**

Temporarily call `DeviceLinkCrypto.selfTest()` from the app's entry (e.g. in `VoiceDropApp.init()` or `RootView.task`), build & run in the simulator, and confirm the console prints `DeviceLinkCrypto.selfTest: OK`. Then remove the temporary call.

Run: `cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit** (repo: `~/code/voicedrop`)

```bash
cd ~/code/voicedrop
git add VoiceDropApp/DeviceLink.swift
git commit -m "feat(ios): DeviceLinkCrypto — X25519+AES-GCM for device-link"
```

---

### Task 9: `AuthStore.adoptToken(_:)`

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/AppleAuth.swift`（紧挨现有 `resetAnonymous()`，约 159-163 行）

**Interfaces:**
- Consumes: 现有 private `keychainSave(_:account:)` + `anonAccount`
- Produces: `AuthStore.shared.adoptToken(_ token: String)` — 把传入 token 写进 iCloud 钥匙串并替换内存身份

- [ ] **Step 1: Add the method**

In `AppleAuth.swift`, directly after the existing `resetAnonymous()` method:

```swift
    func resetAnonymous() {
        let token = "anon_" + randomHex(32)
        keychainSave(token, account: anonAccount)
        anonToken = token
    }
```

add:

```swift
    /// Adopt an anon_… token received from another device (device-link login).
    /// Overwrites the local anon identity in the iCloud Keychain; `anonId`/`bearer`
    /// recompute automatically (computed properties on an @Observable).
    func adoptToken(_ token: String) {
        guard token.hasPrefix("anon_"), token.count >= 20 else { return }
        session = nil
        keychainDelete(account: sessionAccount)
        keychainSave(token, account: anonAccount)
        anonToken = token
    }
```

- [ ] **Step 2: Build**

Run: `cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit** (repo: `~/code/voicedrop`)

```bash
cd ~/code/voicedrop
git add VoiceDropApp/AppleAuth.swift
git commit -m "feat(ios): AuthStore.adoptToken for device-link login"
```

---

### Task 10: 老设备侧 — `StatusSession` 收 link 消息 + 审批卡

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/StatusSession.swift`
- Modify: `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`（加 `DeviceLinkResponder` + `DeviceLinkApprovalSheet`）
- Modify: `~/code/voicedrop/VoiceDropApp/LibraryView.swift`（接线 + present sheet）

**Interfaces:**
- Consumes: `DeviceLinkCrypto.encrypt`（Task 8），`AuthStore.shared.anonToken`
- Produces:
  - `StatusSession.onLinkRequest: ((_ pairingId:String,_ code:String,_ pubkey:String)->Void)?`
  - `StatusSession.onLinkRelease: ((_ pairingId:String)->Void)?`
  - `DeviceLinkResponder`（`@MainActor @Observable`）：`present(pairingId:code:pubkey:)`、`release(pairingId:)`、`cancel()`，`pending` 驱动 sheet
  - `DeviceLinkApprovalSheet(responder:)`

- [ ] **Step 1: Add the two closures + dispatch in StatusSession**

In `StatusSession.swift`, add two stored properties next to the existing `onPhase`/`onDone`:

```swift
    var onPhase: ((String, String) -> Void)?   // (stem, phase) — phase ∈ {asr, mining}
    var onDone: ((String) -> Void)?            // stem that finished (ready or empty)
    var onLinkRequest: ((String, String, String) -> Void)?  // (pairingId, code, pubkey)
    var onLinkRelease: ((String) -> Void)?                  // pairingId
```

Replace the existing `handle(_:)` body's early-guard so it branches on `type` BEFORE the `status_update` guard. Replace:

```swift
    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "status_update",
              let stem = obj["stem"] as? String,
              let status = obj["status"] as? String else { return }
        switch status {
        case "asr", "mining": onPhase?(stem, status)
        case "processing": onPhase?(stem, "mining")   // legacy single-phase signal
        case "ready", "empty": onDone?(stem)
        default: break
        }
    }
```

with:

```swift
    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "link_request" {
            guard let pid = obj["pairingId"] as? String,
                  let code = obj["code"] as? String,
                  let pubkey = obj["pubkey"] as? String else { return }
            onLinkRequest?(pid, code, pubkey)
            return
        }
        if type == "link_release" {
            if let pid = obj["pairingId"] as? String { onLinkRelease?(pid) }
            return
        }

        guard type == "status_update",
              let stem = obj["stem"] as? String,
              let status = obj["status"] as? String else { return }
        switch status {
        case "asr", "mining": onPhase?(stem, status)
        case "processing": onPhase?(stem, "mining")   // legacy single-phase signal
        case "ready", "empty": onDone?(stem)
        default: break
        }
    }
```

- [ ] **Step 2: Add `DeviceLinkResponder` + approval sheet to DeviceLink.swift**

Append to `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`:

```swift
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
        _ = try await URLSession.shared.data(for: req)
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
```

- [ ] **Step 3: Wire it in LibraryView**

In `LibraryView.swift`, add state next to the existing `@State private var statusSession = StatusSession()` (line 13):

```swift
    @State private var statusSession = StatusSession()
    @State private var linkResponder = DeviceLinkResponder()
```

In the existing `.task { ... }` (lines 80–89), add the two closures alongside `onPhase`/`onDone`:

```swift
            statusSession.onPhase = { stem, phase in store.markPhase(stem: stem, phase: phase) }
            statusSession.onDone = { stem in store.markDone(stem: stem) }
            statusSession.onLinkRequest = { pid, code, pubkey in linkResponder.present(pairingId: pid, code: code, pubkey: pubkey) }
            statusSession.onLinkRelease = { pid in linkResponder.release(pairingId: pid) }
            statusSession.connect()
            await refresh()
```

Add a `.sheet` on the same view (next to other modifiers on the `LibraryView` body — match the existing modifier placement):

```swift
        .sheet(item: $linkResponder.pending) { p in
            DeviceLinkApprovalSheet(responder: linkResponder, pending: p)
        }
```

- [ ] **Step 4: Regenerate (no new files, but safe) + build**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** (repo: `~/code/voicedrop`)

```bash
cd ~/code/voicedrop
git add VoiceDropApp/StatusSession.swift VoiceDropApp/DeviceLink.swift VoiceDropApp/LibraryView.swift
git commit -m "feat(ios): old-device side — receive link_request/release + approval sheet"
```

---

### Task 11: 新设备侧 — `DeviceLinkStore` + 输入界面 + 账户入口

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`（加 `DeviceLinkStore` + `DeviceLinkView`）
- Modify: `~/code/voicedrop/VoiceDropApp/AccountView.swift`（加「登录已有账号」按钮 + sheet）

**Interfaces:**
- Consumes: `DeviceLinkCrypto.newKeypair`/`decrypt`（Task 8），`AuthStore.shared.adoptToken`（Task 9），`AuthStore.shared.bearer`
- Produces:
  - `DeviceLinkStore`（`@MainActor @Observable`）：`phase ∈ {.enterId,.enterCode,.working,.done,.error}`，`start(prefix:)`、`submit(code:)`、`reset()`
  - `DeviceLinkView()` — 输入 6 位 → 输入 4 位 → 完成

- [ ] **Step 1: Add `DeviceLinkStore` + `DeviceLinkView`**

Append to `~/code/voicedrop/VoiceDropApp/DeviceLink.swift`:

```swift
// MARK: - New-device side: enter old account's 6-hex, then the 4-digit code, adopt the token.
@MainActor
@Observable
final class DeviceLinkStore: NSObject, URLSessionWebSocketDelegate {
    enum Phase { case enterId, enterCode, working, done, error }
    var phase: Phase = .enterId
    var message: String = ""

    private let httpBase = URL(string: "https://jianshuo.dev/agent/link")!
    private var priv: Curve25519.KeyAgreement.PrivateKey?
    private var pairingId: String?
    private var ws: URLSessionWebSocketTask?

    func reset() { ws?.cancel(); ws = nil; priv = nil; pairingId = nil; phase = .enterId; message = "" }

    // Step 1: send the 6-hex prefix + ephemeral pubkey; open the wait-socket.
    func start(prefix: String) {
        let hex = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.range(of: "^[0-9a-f]{6}$", options: .regularExpression) != nil else {
            message = "请输入 6 位代码（设置→账户里那串）"; return
        }
        phase = .working; message = ""
        let (p, pub) = DeviceLinkCrypto.newKeypair()
        priv = p
        Task {
            do {
                let r = try await postJSON("start", ["prefix": hex, "pubkey": pub])
                if (r["ok"] as? Bool) != true {
                    message = (r["reason"] as? String) == "no_match" ? "没找到这个账号，确认老设备设置页的 6 位码" : "发起失败"
                    phase = .error; return
                }
                guard let pid = r["pairingId"] as? String else { phase = .error; message = "发起失败"; return }
                pairingId = pid
                openSocket(pairingId: pid)
                phase = .enterCode
            } catch { phase = .error; message = "网络错误" }
        }
    }

    // Step 2: submit the 4-digit code shown on the old device.
    func submit(code: String) {
        guard let pid = pairingId, code.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else {
            message = "请输入 4 位验证码"; return
        }
        phase = .working; message = ""
        Task {
            do {
                let r = try await postJSON("verify", ["pairingId": pid, "code": code])
                if (r["ok"] as? Bool) == true {
                    message = "正在接收账号…"   // wait for link_ready on the socket
                } else if (r["dead"] as? Bool) == true || (r["expired"] as? Bool) == true {
                    phase = .error; message = "验证已失效，请重新发起"
                } else {
                    let rem = r["remaining"] as? Int ?? 0
                    phase = .enterCode; message = "验证码不对，还可试 \(rem) 次"
                }
            } catch { phase = .error; message = "网络错误" }
        }
    }

    private func openSocket(pairingId: String) {
        var comps = URLComponents(string: "wss://jianshuo.dev/agent/link/socket")!
        comps.queryItems = [URLQueryItem(name: "pairingId", value: pairingId)]
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: comps.url!)
        ws = task
        task.resume()
        receive()
    }

    private func receive() {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let msg) = result {
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ s: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "link_ready":
            guard let blob = o["blob"] as? [String: Any],
                  let epk = blob["epk"] as? String, let sealed = blob["sealed"] as? String,
                  let priv = self.priv else { phase = .error; message = "解密失败"; return }
            do {
                let token = try DeviceLinkCrypto.decrypt(epkB64: epk, sealedB64: sealed, priv: priv)
                AuthStore.shared.adoptToken(token)
                NotificationCenter.default.post(name: .vdDidAdoptAccount, object: nil)
                phase = .done; message = "登录成功"
                ws?.cancel(); ws = nil
            } catch { phase = .error; message = "解密失败" }
        case "link_cancelled": phase = .error; message = "对方已拒绝"
        case "link_expired": phase = .error; message = "已超时，请重新发起"
        default: break
        }
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: httpBase.appending(path: path))
        req.httpMethod = "POST"
        req.setBearer(AuthStore.shared.bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

extension Notification.Name { static let vdDidAdoptAccount = Notification.Name("VDDidAdoptAccount") }

struct DeviceLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeviceLinkStore()
    @State private var idInput = ""
    @State private var codeInput = ""

    var body: some View {
        VStack(spacing: 20) {
            switch store.phase {
            case .enterId, .working where store.message.isEmpty:
                Text("登录已有账号").font(.system(size: 20, weight: .semibold))
                Text("在老设备「设置 → 账户」看到的 6 位代码").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("6 位代码", text: $idInput)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.system(size: 22, design: .monospaced)).multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                Button("继续") { store.start(prefix: idInput) }.buttonStyle(.borderedProminent)
            case .enterCode:
                Text("输入验证码").font(.system(size: 20, weight: .semibold))
                Text("老设备上弹出的 4 位验证码").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("4 位", text: $codeInput)
                    .keyboardType(.numberPad).font(.system(size: 28, design: .monospaced))
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                Button("验证") { store.submit(code: codeInput) }.buttonStyle(.borderedProminent)
            case .working:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("登录成功").font(.system(size: 18, weight: .semibold))
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            case .error:
                Image(systemName: "xmark.circle.fill").font(.system(size: 40)).foregroundStyle(.red)
                Button("重试") { codeInput = ""; idInput = ""; store.reset() }.buttonStyle(.bordered)
            }
            if !store.message.isEmpty { Text(store.message).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}
```

- [ ] **Step 2: Add the entry button in AccountView**

In `~/code/voicedrop/VoiceDropApp/AccountView.swift`, add a state flag near the top of the view struct:

```swift
    @State private var showDeviceLink = false
```

Below the existing Apple sign-in / sign-out block (around AccountView.swift:85–103), add an entry button:

```swift
            Button { showDeviceLink = true } label: {
                Label("登录已有账号", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(.bordered)
```

And attach the sheet on the AccountView body (next to its other modifiers, or at the end of the outer container):

```swift
        .sheet(isPresented: $showDeviceLink) { DeviceLinkView() }
```

- [ ] **Step 3: Refresh library after adoption (LibraryView)**

In `LibraryView.swift`, inside the existing `.task { ... }` (after `await refresh()`), nothing is needed; instead add an `.onReceive` modifier on the body to reload when an account is adopted:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .vdDidAdoptAccount)) { _ in
            Task { await refresh() }
        }
```

- [ ] **Step 4: Regenerate + build**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** (repo: `~/code/voicedrop`)

```bash
cd ~/code/voicedrop
git add VoiceDropApp/DeviceLink.swift VoiceDropApp/AccountView.swift VoiceDropApp/LibraryView.swift
git commit -m "feat(ios): new-device device-link flow (DeviceLinkStore + view + account entry)"
```

---

### Task 12: 端到端手测（两台设备/模拟器）

**Files:** none

- [ ] **Step 1: 准备两个实例**

在两台模拟器/设备上装当前 build。设备 A = 老账号（有录音）；设备 B = 新装、空账号。在 A 上「设置 → 账户」记下 6 位短码。

- [ ] **Step 2: Happy path**

B：设置 → 账户 →「登录已有账号」→ 输入 A 的 6 位 → 继续。
A：应弹出审批卡，显示一个 4 位验证码。
B：输入该 4 位 → 验证。
预期：B 显示「登录成功」，返回列表后**看到 A 的录音/文章**；A 显示「已在新设备登录」。

- [ ] **Step 3: 错码 / 失效**

重走到 B 的输码界面，连输 5 个错码 → 预期最终「验证已失效，请重新发起」；A 的卡 2 分钟后自动消失（link_expired）。

- [ ] **Step 4: no_match**

B 输入一个不存在的 6 位（如 `000000`，假设无此账号）→ 预期「没找到这个账号…」。

- [ ] **Step 5: 「不是我」**

重发起到 A 弹卡，A 点「不是我」→ 预期 B 收到「对方已拒绝」，且 B 无法再用该 pairing 完成。

- [ ] **Step 6: 更新 STATE.md**

在 `~/code/voicedrop/STATE.md` 增补一节「设备配对登录（device-link）」，记录：`/agent/link/*` 路由、`LinkBroker` DO、`StatusHub` 广播泛化、E2E blob 形状、CLI 分身为未来扩展（spec §11）。Commit（repo `~/code/voicedrop`）：

```bash
cd ~/code/voicedrop
git add STATE.md
git commit -m "docs: STATE.md — device-link pairing login"
```

---

## 部署清单（实现完成后，用户确认执行）

1. Worker：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`（Task 7 已首发；如 Phase 2 期间改过 Worker 需再发）。
2. iOS：推 `~/code/voicedrop` `main` → GitHub Actions → TestFlight。
3. 无 Pages 改动。

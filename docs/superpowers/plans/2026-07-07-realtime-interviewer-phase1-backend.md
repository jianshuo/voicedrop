# Realtime AI 采访员 · Phase 1（后端）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `voicedrop-agent` worker 加两个端点——`POST /agent/realtime/session`（用 `OPENAI_API_KEY` 向 OpenAI mint 临时 realtime 凭证，key 不下发设备）与 `POST /agent/realtime/usage`（按官方费率把上报的 token 折算算力、扣费记账，允许扣成负数）——作为 iOS Phase 2 要调的后端契约。

**Architecture:** 新增 `agent/src/realtime.js`（两个端点 + 采访员 instructions + session 配置），`agent/src/usage.js` 加 realtime 费率与 `realtimeCostUY` 折算（复用既有 `FX=7.3`/`RATE=23` 口径），`agent/src/index.js` 导出 `resolveScope` 并把 `handleRealtimeRoute` 接进 fetch 分发。计费复用既有 `usage_store` 的 `debit`（本就支持透支为负桶）。

**Tech Stack:** Cloudflare Worker (ESM JS)、vitest、D1(`env.USAGE`)、`test/fakes.js` 的 `fakeD1`/`usageSql`/`fakeFetch`；外部 OpenAI Realtime API（模型 `gpt-realtime-2.1`）。

## Global Constraints

- **换算口径（用户定）**：`1 USD = 7.3 RMB`（`FX`），`23 算力/元`（`RATE`）⇒ `1 USD ≈ 167.9 算力`。UY = 微元；`costUY = Math.ceil(usd × FX × 1e6)`（与既有 `claudeCostUY` 同式）。
- **计费不追求精确 + 允许负数**：直接信 app 上报的 token 数折算扣费；`debit` 本就在无活桶时开负 overdraft 桶，**不设下限、不拦截**。
- **mint 不拦余额**：`/agent/realtime/session` 不查余额、不 402。
- **费率($/1M token)**：audio_in **32** / audio_in_cached **0.40** / audio_out **64** / text_in **4** / text_in_cached **0.40** / text_out **24**。
- **模型**：`gpt-realtime-2.1`；`reasoning.effort:"low"`；`output_modalities:["audio"]`；`turn_detection: server_vad, create_response:false`（app 侧控制何时 `response.create`）。
- **OPENAI_API_KEY 只在 worker**：设为 `voicedrop-agent` 的 wrangler secret，绝不进 GitHub、绝不下发设备。
- **认证**：realtime 端点用现有用户 token（`resolveScope`）；无效 token → 401。
- **scoped commit**：只提交 `agent/…` 路径，绝不 `git add -A`；仓库里有无关的 `voicedrop/` 改动不许碰。
- **测试命令**：`cd agent && npx vitest run <file>`；全量 `npx vitest run`。代码根 `~/code/jianshuo.dev/agent/`。
- **外部 schema 未定死处**：`/v1/realtime/client_secrets` 的确切请求体嵌套随 OpenAI 演进——Task 4 部署前用真 curl 核实并微调 `buildSessionConfig()`；单测用 `fakeFetch` 只验**我们的转发逻辑**（URL、Bearer、响应透传），不验 OpenAI schema。

---

### Task 1: realtime 费率折算 + 账单文案（`usage.js`）

**Files:**
- Modify: `agent/src/usage.js`（加 `REALTIME_PRICE`、`realtimeCostUY`；`REASON_ZH` 加 `realtime`）
- Test: `agent/test/realtime-cost.test.js`

**Interfaces:**
- Consumes: 既有 `FX`(=7.3)、`REASON_ZH`、`reasonZH`（同文件）。
- Produces: `export const REALTIME_PRICE`（$/token）；`export function realtimeCostUY(usage)` → 整数 UY（微元）；`REASON_ZH.realtime`。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/realtime-cost.test.js
import { describe, it, expect } from "vitest";
import { realtimeCostUY, REALTIME_PRICE, reasonZH, uyToSuanli } from "../src/usage.js";

describe("realtimeCostUY", () => {
  it("1M audio_out token = $64 → UY = ceil(64*7.3*1e6)", () => {
    expect(realtimeCostUY({ audio_out: 1_000_000 })).toBe(Math.ceil(64 * 7.3 * 1e6));
  });
  it("1M text_in token = $4 → UY = ceil(4*7.3*1e6)", () => {
    expect(realtimeCostUY({ text_in: 1_000_000 })).toBe(Math.ceil(4 * 7.3 * 1e6));
  });
  it("分档累加：audio_in + audio_out", () => {
    const uy = realtimeCostUY({ audio_in: 500_000, audio_out: 250_000 });
    const usd = 500_000 * REALTIME_PRICE.audio_in + 250_000 * REALTIME_PRICE.audio_out;
    expect(uy).toBe(Math.ceil(usd * 7.3 * 1e6));
  });
  it("1 USD ≈ 167.9 算力（口径自洽）", () => {
    // $1 = 1e6 text_in tokens? 不——直接构造 $1：text_out 1/24*1e6 太绕，改用已知 UY
    expect(Math.round(uyToSuanli(Math.ceil(1 * 7.3 * 1e6)) * 10) / 10).toBe(167.9);
  });
  it("缺字段/非法值当 0，不抛", () => {
    expect(realtimeCostUY({})).toBe(0);
    expect(realtimeCostUY({ audio_in: -5, text_out: "x" })).toBe(0);
  });
  it("reasonZH 认得 realtime", () => {
    expect(reasonZH("realtime")).toBe("AI 采访");
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/realtime-cost.test.js`
Expected: FAIL（`realtimeCostUY`/`REALTIME_PRICE` 未导出）。

- [ ] **Step 3: 在 `usage.js` 加费率与折算**

在 `usage.js` 里 `claudeCostUY` 附近加（复用同文件的 `FX`）：

```js
// OpenAI Realtime (gpt-realtime-2.1) 官方费率，USD per token。跟官方更新只改这里。
export const REALTIME_PRICE = {
  audio_in:        32 / 1e6,
  audio_in_cached: 0.40 / 1e6,
  audio_out:       64 / 1e6,
  text_in:         4 / 1e6,
  text_in_cached:  0.40 / 1e6,
  text_out:        24 / 1e6,
};

// usage: { audio_in, audio_in_cached, audio_out, text_in, text_in_cached, text_out }（token 数）
// → 微元(UY)，与 claudeCostUY 同式：ceil(usd × FX × 1e6)。缺字段/非法 → 0。
export function realtimeCostUY(usage = {}) {
  const p = REALTIME_PRICE;
  const n = (k) => { const v = Number(usage && usage[k]); return Number.isFinite(v) && v > 0 ? v : 0; };
  const usd =
    n("audio_in") * p.audio_in + n("audio_in_cached") * p.audio_in_cached + n("audio_out") * p.audio_out +
    n("text_in") * p.text_in + n("text_in_cached") * p.text_in_cached + n("text_out") * p.text_out;
  return Math.ceil(usd * FX * 1e6);
}
```

在 `REASON_ZH` 对象里加一行：`realtime: "AI 采访",`

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/realtime-cost.test.js`
Expected: PASS（6 用例）。

- [ ] **Step 5: 全量确认无回归**

Run: `cd agent && npx vitest run`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/usage.js agent/test/realtime-cost.test.js
git commit -m "feat(realtime): realtime 费率折算 realtimeCostUY + 账单文案"
```

---

### Task 2: `POST /agent/realtime/session` — mint 临时凭证（`realtime.js`）

**Files:**
- Create: `agent/src/realtime.js`
- Modify: `agent/src/index.js`（`resolveScope` 加 `export`；fetch 分发接入 `handleRealtimeRoute`）
- Test: `agent/test/realtime-route.test.js`

**Interfaces:**
- Consumes: `bearerToken`（`../../functions/lib/auth.js`）、`resolveScope`（`./index.js`，本任务改成 export）；`globalThis.fetch`（测试用 `fakeFetch` 拦 OpenAI）。
- Produces: `export const INTERVIEWER_INSTRUCTIONS`；`export function buildSessionConfig()`；`export async function handleRealtimeRoute(url, request, env)` → `Response` 或 `null`（非 `/agent/realtime/` 前缀返回 null）。

- [ ] **Step 1: 写失败测试（session 部分）**

```js
// agent/test/realtime-route.test.js
import { describe, it, expect, afterEach } from "vitest";
import { handleRealtimeRoute } from "../src/realtime.js";
import { fakeFetch } from "./fakes.js";

const TOK = "anon_unittesttoken_abcdefghijklmnop";
const req = (path, { method = "POST", token = TOK, body } = {}) =>
  new Request("https://jianshuo.dev" + path, {
    method,
    headers: { ...(token ? { Authorization: "Bearer " + token } : {}), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
const U = (p) => new URL("https://jianshuo.dev" + p);
const origFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = origFetch; });

describe("POST /agent/realtime/session", () => {
  it("mint：用 OPENAI_API_KEY 调 client_secrets 并透传凭证", async () => {
    globalThis.fetch = fakeFetch({
      "POST https://api.openai.com/v1/realtime/client_secrets": () =>
        ({ ok: true, status: 200, body: { id: "sess_abc", client_secret: { value: "ek_xyz", expires_at: 1234 }, expires_at: 1234 } }),
    });
    const env = { SESSION_SECRET: "", OPENAI_API_KEY: "sk-test" };
    const r = await handleRealtimeRoute(U("/agent/realtime/session"), req("/agent/realtime/session"), env);
    expect(r.status).toBe(200);
    const j = await r.json();
    expect(j.session_id).toBe("sess_abc");
    expect(j.client_secret).toBeTruthy();
    // 断言确实带了 Bearer OPENAI_API_KEY
    const call = globalThis.fetch.calls.find((c) => c.url.includes("/realtime/client_secrets"));
    expect(call.headers.Authorization).toBe("Bearer sk-test");
  });
  it("无 token → 401", async () => {
    const r = await handleRealtimeRoute(U("/agent/realtime/session"), req("/agent/realtime/session", { token: null }), { SESSION_SECRET: "" });
    expect(r.status).toBe(401);
  });
  it("没配 OPENAI_API_KEY → 503", async () => {
    const r = await handleRealtimeRoute(U("/agent/realtime/session"), req("/agent/realtime/session"), { SESSION_SECRET: "" });
    expect(r.status).toBe(503);
  });
  it("OpenAI 失败 → 502", async () => {
    globalThis.fetch = fakeFetch({ "POST https://api.openai.com/v1/realtime/client_secrets": () => ({ ok: false, status: 500, body: {} }) });
    const r = await handleRealtimeRoute(U("/agent/realtime/session"), req("/agent/realtime/session"), { SESSION_SECRET: "", OPENAI_API_KEY: "sk-test" });
    expect(r.status).toBe(502);
  });
  it("非 realtime 前缀 → null", async () => {
    expect(await handleRealtimeRoute(U("/agent/other"), req("/agent/other"), {})).toBeNull();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/realtime-route.test.js`
Expected: FAIL（`realtime.js` 不存在）。

- [ ] **Step 3: `index.js` 导出 `resolveScope`**

把 `agent/src/index.js:1207` 的 `async function resolveScope(token, env) {` 改成 `export async function resolveScope(token, env) {`（其余不动）。`resolveScope` 是 hoisted async 函数，realtime.js 循环 import 它安全（只在请求时调用）。

- [ ] **Step 4: 写 `agent/src/realtime.js`（session 端点）**

```js
// src/realtime.js — Realtime AI 采访员后端：mint 临时凭证 + usage 计费。
// OPENAI_API_KEY 只在 worker，向 OpenAI mint 短时 client_secret 下发给 app。
import { bearerToken } from "../../functions/lib/auth.js";
import { resolveScope } from "./index.js";

const J = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

// 采访员系统提示词（spec D）。app 侧只在 ≥5s 停顿+限流时才 response.create。
export const INTERVIEWER_INSTRUCTIONS =
  "你是一位老练的媒体采访者。你认真听、真正理解对方说的核心。只用一句话、不超过 5 秒的简短追问，" +
  "扣住他刚说的关键点，目的是帮他更容易接着往下说。绝不打断、不评论、不总结、不寒暄、不重复他的话。语气自然、克制。";

// mint 请求体。turn_detection 用 server_vad 但 create_response:false——只借它的
// speech_started/stopped 事件，何时发 response.create 由 app 控制（限流）。
// 注意：/v1/realtime/client_secrets 的确切嵌套随 OpenAI 演进，部署前用真 curl 核实（见 plan Task 4）。
export function buildSessionConfig() {
  return {
    model: "gpt-realtime-2.1",
    instructions: INTERVIEWER_INSTRUCTIONS,
    output_modalities: ["audio"],
    audio: {
      input:  { format: "pcm16", turn_detection: { type: "server_vad", silence_duration_ms: 500, create_response: false, interrupt_response: false } },
      output: { format: "pcm16", voice: "cedar" },
    },
    reasoning: { effort: "low" },
  };
}

export async function handleRealtimeRoute(url, request, env) {
  if (!url.pathname.startsWith("/agent/realtime/")) return null;
  const tok = bearerToken(request);
  const scope = await resolveScope(tok, env);
  if (!scope) return J({ error: "unauthorized" }, 401);

  if (url.pathname === "/agent/realtime/session" && request.method === "POST") {
    if (!env.OPENAI_API_KEY) return J({ error: "realtime unavailable" }, 503);
    let resp;
    try {
      resp = await globalThis.fetch("https://api.openai.com/v1/realtime/client_secrets", {
        method: "POST",
        headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify(buildSessionConfig()),
      });
    } catch { resp = null; }
    if (!resp || !resp.ok) return J({ error: "openai-unavailable", status: resp?.status || 0 }, 502);
    const data = await resp.json();
    return J({ client_secret: data.client_secret ?? null, expires_at: data.expires_at ?? null, session_id: data.id ?? null });
  }

  return J({ error: "not found" }, 404);
}
```

- [ ] **Step 5: 把 `handleRealtimeRoute` 接进 `index.js` 分发**

在 `index.js` 顶部 import 区加：`import { handleRealtimeRoute } from "./realtime.js";`
在 fetch 分发里找到调用 `handleUsageRoute(` 的那处（`grep -n "handleUsageRoute(" src/index.js`），在其紧邻处加：

```js
    const rt = await handleRealtimeRoute(url, request, env);
    if (rt) return rt;
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd agent && npx vitest run test/realtime-route.test.js`
Expected: session 5 用例 PASS。

- [ ] **Step 7: 全量确认无回归**

Run: `cd agent && npx vitest run`
Expected: 全绿（既有 index/usage 测试不受 export 改动影响）。

- [ ] **Step 8: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/realtime.js agent/src/index.js agent/test/realtime-route.test.js
git commit -m "feat(realtime): /agent/realtime/session mint 临时凭证 + 采访员 session 配置"
```

---

### Task 3: `POST /agent/realtime/usage` — 折算算力扣费（`realtime.js`）

**Files:**
- Modify: `agent/src/realtime.js`（在 `handleRealtimeRoute` 里加 usage 分支）
- Test: `agent/test/realtime-route.test.js`（追加 usage 用例）

**Interfaces:**
- Consumes: `realtimeCostUY`、`uyToSuanli`（`./usage.js`，Task 1）；`ensureAccount`、`debit`、`balanceUY`（`./usage_store.js`）；`fakeD1`/`usageSql`（测试）。
- Produces: `/agent/realtime/usage` 返回 `{ ok, charged_suanli, balance_suanli }`。

- [ ] **Step 1: 追加失败测试**

```js
// 追加到 agent/test/realtime-route.test.js
import { fakeD1, usageSql } from "./fakes.js";
import { grantBucket } from "../src/usage_store.js";
const SQL = usageSql();

describe("POST /agent/realtime/usage", () => {
  it("按费率扣费：1M text_in = $4 → 扣 ceil(4*7.3*1e6) UY，余额下降", async () => {
    const db = fakeD1(SQL);
    await grantBucket(db, "users/anon-", 1_000_000_000, "test", null, Date.now()); // 先充足额（scope 见下）
    const env = { SESSION_SECRET: "", USAGE: db };
    const r = await handleRealtimeRoute(U("/agent/realtime/usage"),
      req("/agent/realtime/usage", { body: { session_id: "sess_abc", usage: { text_in: 1_000_000 } } }), env);
    expect(r.status).toBe(200);
    const j = await r.json();
    expect(j.ok).toBe(true);
    expect(j.charged_suanli).toBeGreaterThan(0);
  });
  it("余额不足也扣（允许为负）", async () => {
    const env = { SESSION_SECRET: "", USAGE: fakeD1(usageSql()) }; // 空账户
    const r = await handleRealtimeRoute(U("/agent/realtime/usage"),
      req("/agent/realtime/usage", { body: { usage: { audio_out: 2_000_000 } } }), env);
    expect(r.status).toBe(200);
    const j = await r.json();
    expect(j.balance_suanli).toBeLessThan(0); // 透支为负
  });
  it("坏 body → 400", async () => {
    const env = { SESSION_SECRET: "", USAGE: fakeD1(usageSql()) };
    const r = await handleRealtimeRoute(U("/agent/realtime/usage"), req("/agent/realtime/usage", { body: { nope: 1 } }), env);
    expect(r.status).toBe(400);
  });
  it("无 USAGE 绑定 → 降级 200", async () => {
    const r = await handleRealtimeRoute(U("/agent/realtime/usage"), req("/agent/realtime/usage", { body: { usage: { text_in: 1 } } }), { SESSION_SECRET: "" });
    expect(r.status).toBe(200);
  });
});
```

注：`grantBucket`/扣费用的 `scope` 必须与 `resolveScope("anon_unittesttoken_abcdefghijklmnop")` 实际返回的 scope 一致。实现前先在测试里 `console.log(await resolveScope(TOK, {SESSION_SECRET:""}))` 取真值，把上面 `"users/anon-"` 换成该真值（形如 `users/anon-<hash>/`）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/realtime-route.test.js`
Expected: usage 用例 FAIL（还没有 usage 分支，命中 404）。

- [ ] **Step 3: 在 `realtime.js` 加 usage 分支**

在 `handleRealtimeRoute` 的 `return J({ error: "not found" }, 404);` 之前插入，并在文件顶部补 import：

```js
import { realtimeCostUY, uyToSuanli } from "./usage.js";
import { ensureAccount, debit, balanceUY } from "./usage_store.js";
const r1 = (n) => Math.round(n * 10) / 10;
```

分支：

```js
  if (url.pathname === "/agent/realtime/usage" && request.method === "POST") {
    let body; try { body = await request.json(); } catch { body = null; }
    if (!body || typeof body.usage !== "object" || !body.usage) return J({ error: "expected {usage}" }, 400);
    if (!env.USAGE) return J({ ok: true, degraded: true });
    const now = Date.now();
    await ensureAccount(env.USAGE, scope, now);
    const costUY = realtimeCostUY(body.usage);
    const detail = { session_id: body.session_id || null, usage: body.usage };
    await debit(env.USAGE, scope, costUY, "realtime", detail, now); // debit 对 <=0 自动早返回；无桶时开负 overdraft
    const bal = await balanceUY(env.USAGE, scope, now);
    return J({ ok: true, charged_suanli: r1(uyToSuanli(costUY)), balance_suanli: r1(uyToSuanli(bal)) });
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/realtime-route.test.js`
Expected: session + usage 全 PASS。

- [ ] **Step 5: 全量确认无回归**

Run: `cd agent && npx vitest run`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/realtime.js agent/test/realtime-route.test.js
git commit -m "feat(realtime): /agent/realtime/usage 折算算力扣费（允许透支为负）"
```

---

### Task 4: 配 secret + 核实 OpenAI 请求体 + 部署 + 验证

**Files:** 无新增。

- [ ] **Step 1: 全量测试**

Run: `cd agent && npx vitest run`
Expected: 全绿。

- [ ] **Step 2: 用真 curl 核实 `/v1/realtime/client_secrets` 请求体**（部署前必做）

用用户提供的真实 `OPENAI_API_KEY`，本地 curl 一次，确认 `buildSessionConfig()` 的字段/嵌套被接受、响应里 `id`/`client_secret`/`expires_at` 字段名正确：
```bash
curl -sS https://api.openai.com/v1/realtime/client_secrets \
  -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"gpt-realtime-2.1","instructions":"test","output_modalities":["audio"],"audio":{"input":{"format":"pcm16","turn_detection":{"type":"server_vad","silence_duration_ms":500,"create_response":false}},"output":{"format":"pcm16","voice":"cedar"}},"reasoning":{"effort":"low"}}' | python3 -m json.tool
```
若字段名/嵌套与响应不符，改 `buildSessionConfig()` 与 session 端点的响应字段映射（`data.id`/`data.client_secret`/`data.expires_at`），跑 `npx vitest run test/realtime-route.test.js` 保持绿，补一个 commit。

- [ ] **Step 3: 配 OPENAI_API_KEY 为 worker secret**（用户确认目标后执行）

```bash
cd ~/code/jianshuo.dev/agent
printf %s "$OPENAI_API_KEY" | CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler secret put OPENAI_API_KEY
```
（值走 stdin 不落命令行；只在 worker，不进 GitHub。）

- [ ] **Step 4: 部署**（先确认 origin/main 无他人新提交，wrangler 整包覆盖）

```bash
cd ~/code/jianshuo.dev && git fetch origin main -q && git log --oneline HEAD..origin/main
# 若无输出（不落后）再部署：
cd agent && CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler deploy 2>&1 | tail -6
```

- [ ] **Step 5: 线上验证鉴权 + mint 活性**

```bash
# 无 token → 401（端点已部署且鉴权）
curl -s -o /dev/null -w "unauth=%{http_code}\n" -X POST https://jianshuo.dev/agent/realtime/session
# 带 app 用户 token → 应返回 client_secret（或 OpenAI 侧错误码），证明 key 已配、转发通
curl -s -X POST https://jianshuo.dev/agent/realtime/session -H "Authorization: Bearer <一个真实 app 用户 token>" | python3 -m json.tool
```
Expected: 无 token 401；带 token 返回 `{client_secret, expires_at, session_id}`。

- [ ] **Step 6: 收尾提交（若 Step 2 有调整且未提交）**

```bash
cd ~/code/jianshuo.dev && git add agent/ && git commit -m "fix(realtime): 对齐 client_secrets 请求体/响应字段" || true
```

---

## Self-Review

- **Spec coverage**：`/agent/realtime/session` mint（Task 2）✓；`/agent/realtime/usage` 折算扣费（Task 3）✓；换算口径 7.3×23（Task 1，Global Constraints）✓；不精确/允许负数/不拦 mint（Task 1/2/3，用 `debit` 天然透支）✓；官方费率表（Task 1）✓；采访员 instructions + turn_detection create_response:false（Task 2）✓；OPENAI_API_KEY 只在 worker（Task 4 secret）✓；认证 resolveScope + 401（Task 2）✓。Phase 2（iOS 音频/WS/UI/上报）不在本计划，spec 已标。
- **Placeholder scan**：无 TODO/占位。唯一外部不确定点（client_secrets 确切请求体）以 Task 4 Step 2 的真 curl 核实兜住，且单测边界明确只验转发逻辑——非占位，是刻意的测试边界。
- **Type consistency**：`realtimeCostUY(usage)→UY:int`、`handleRealtimeRoute(url,request,env)→Response|null`、`buildSessionConfig()→object`、`debit(db,scope,uy,"realtime",detail,now)`、`balanceUY`/`uyToSuanli` 跨任务一致。
- **风险**：`resolveScope` 改 export 可能影响 index.js——Task 2 Step 7 全量测试守。测试里 anon scope 真值需运行时取（Task 3 Step 1 注明）。

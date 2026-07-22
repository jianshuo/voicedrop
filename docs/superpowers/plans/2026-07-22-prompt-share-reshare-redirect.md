# 导入件再分享溯源转发（prompt 不变码不变）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 导入的提示词一字未改再分享时，不铸新码，转发原作者的魔法数字（奖励/曝光归原作者）；改过或原分享已关才铸自己的码。

**Architecture:** 全部改动在 jianshuo.dev repo。`POST /agent/prompt-share` 铸码前加转发判定（比对 `shares/<importedFrom>` 活跃副本的 instruction）；索引里用 `borrowed:true` 条目记录转发状态（D1 `prompt_shares` 加 `borrowed` 列 + code 唯一索引改 partial unique）；DELETE 对 borrowed 条目只删索引不碰原作者分享；prompt-market 候选 SQL 排除 borrowed 行。

**Tech Stack:** Cloudflare Worker（voicedrop-agent）、D1（voicedrop-core，migrations-core/）、R2、vitest + better-sqlite3（fakeD1）。

**Spec:** `voicedrop/docs/superpowers/specs/2026-07-22-prompt-share-reshare-redirect-design.md`

## Global Constraints

- 工作目录：jianshuo.dev repo 的 worktree `.claude/worktrees/magic-code-grow`（已在 main 最新之上）。
- 测试命令：`cd agent && npx vitest run`（全量必须 0 fail 才能部署）。
- commit message 结尾带：
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` 和
  `Claude-Session: https://claude.ai/code/session_01LpvAYbZqPDRtKayf2NMf7c`
- 部署顺序硬约束：**先 `wrangler d1 migrations apply voicedrop-core --remote`，再 `wrangler deploy`**（新 SQL 引用 `borrowed` 列，旧库没有会全线 catch 降级）。
- 老行为不变量：自有码「一条指令一辈子一个码」、幂等重开、日上限、写穿刷新逻辑全部保持。

---

### Task 1: D1 migration 0004（borrowed 列 + partial unique）

**Files:**
- Create: `agent/migrations-core/0004_prompt_shares_borrowed.sql`
- Modify: `agent/test/fakes.js`（`coreSql()` 拼上 0004）
- Test: `agent/test/prompt-share-redirect.test.js`（新建，先只放 schema 测试）

**Interfaces:**
- Produces: `prompt_shares.borrowed INTEGER NOT NULL DEFAULT 0`；`idx_prompt_shares_code` 变为 `UNIQUE ... WHERE borrowed = 0`。后续 Task 的 SQL 都依赖此列存在。

- [ ] **Step 1: 写失败测试**（新建 `agent/test/prompt-share-redirect.test.js`）

```js
// test/prompt-share-redirect.test.js — 导入件再分享溯源转发（spec 2026-07-22）。
import { vi, describe, it, expect } from "vitest";
vi.mock("agents", () => ({ Agent: class Agent {}, getAgentByName: async () => ({}) }));
import { fakeEnv, fakeD1, coreSql } from "./fakes.js";

describe("migration 0004: prompt_shares.borrowed", () => {
  it("borrowed 行可与原作者行同码共存；自有码（borrowed=0）唯一性保持", () => {
    const d = fakeD1(coreSql());
    const ins = (sub, item, code, borrowed) =>
      d.prepare("INSERT INTO prompt_shares (user_sub, item_id, code, created_at, borrowed) VALUES (?,?,?,?,?)")
        .bind(sub, item, code, "2026-07-22T00:00:00.000Z", borrowed).run();
    ins("users/a/", "p_1", "4563", 0);            // 原作者自有码
    ins("users/b/", "p_2", "4563", 1);            // 导入者 borrowed 行，同码 OK
    expect(() => ins("users/c/", "p_3", "4563", 0)).toThrow(); // 自有码撞唯一
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: FAIL（`no such column: borrowed`）

- [ ] **Step 3: 写 migration**（`agent/migrations-core/0004_prompt_shares_borrowed.sql`）

```sql
-- 0004: 导入件再分享溯源转发（spec 2026-07-22-prompt-share-reshare-redirect）。
-- borrowed=1 = 「导入件转发原码」的开关状态行：code 指向原作者的码，本人没铸过码。
-- code 唯一性只对自有码成立——borrowed 行与原作者行同码共存，唯一索引改 partial。
ALTER TABLE prompt_shares ADD COLUMN borrowed INTEGER NOT NULL DEFAULT 0;
DROP INDEX idx_prompt_shares_code;
CREATE UNIQUE INDEX idx_prompt_shares_code ON prompt_shares(code) WHERE borrowed = 0;
```

同时改 `agent/test/fakes.js` 的 `coreSql()`：

```js
export function coreSql() {
  const f = (name) => readFileSync(fileURLToPath(new URL("../migrations-core/" + name, import.meta.url)), "utf8");
  return f("0001_core.sql") + "\n" + f("0002_articles_recordings.sql") + "\n" + f("0003_identity_push_reports.sql") + "\n" + f("0004_prompt_shares_borrowed.sql");
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agent/migrations-core/0004_prompt_shares_borrowed.sql agent/test/fakes.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): D1 migration 0004 — prompt_shares.borrowed + code 唯一索引改 partial"
```

---

### Task 2: core-db 读写带 borrowed + coreDeletePromptShare

**Files:**
- Modify: `functions/lib/core-db.js`（coreLoadPromptShares / coreUpsertPromptShare / coreMintedToday，新增 coreDeletePromptShare）
- Modify: `agent/src/prompt-share.js`（loadIndex 自愈回填透传 borrowed；import 行加 coreDeletePromptShare）
- Test: `agent/test/prompt-share-redirect.test.js`

**Interfaces:**
- Produces:
  - `coreLoadPromptShares(env, scope)` → `{byItem: {itemId: {code, createdAt, borrowed?: true}}}`（borrowed 仅在为真时出现）
  - `coreUpsertPromptShare(env, scope, itemId, code, createdAt, borrowed = false)` → boolean
  - `coreDeletePromptShare(env, scope, itemId)` → boolean（删行；borrowed 关分享专用）
  - `coreMintedToday` 只数 `borrowed=0` 的行

- [ ] **Step 1: 写失败测试**（追加到 `agent/test/prompt-share-redirect.test.js`）

```js
import { coreLoadPromptShares, coreUpsertPromptShare, coreDeletePromptShare, coreMintedToday } from "../../functions/lib/core-db.js";

describe("core-db borrowed 读写", () => {
  const envWithCore = () => { const e = fakeEnv(); e.CORE = fakeD1(coreSql()); return e; };
  const today = new Date().toISOString().slice(0, 10);

  it("upsert(borrowed=true) → load 带 borrowed:true；默认 upsert 不带", async () => {
    const e = envWithCore();
    await coreUpsertPromptShare(e, "users/b/", "p_1", "4563", "2026-07-22T00:00:00.000Z", true);
    await coreUpsertPromptShare(e, "users/b/", "p_2", "7654", "2026-07-22T00:00:00.000Z");
    const { byItem } = await coreLoadPromptShares(e, "users/b/");
    expect(byItem.p_1).toEqual({ code: "4563", createdAt: "2026-07-22T00:00:00.000Z", borrowed: true });
    expect(byItem.p_2).toEqual({ code: "7654", createdAt: "2026-07-22T00:00:00.000Z" });
  });
  it("同一 item 从 borrowed 升级为自有码：upsert 覆盖清掉 borrowed", async () => {
    const e = envWithCore();
    await coreUpsertPromptShare(e, "users/b/", "p_1", "4563", "2026-07-22T00:00:00.000Z", true);
    await coreUpsertPromptShare(e, "users/b/", "p_1", "8888", "2026-07-22T01:00:00.000Z");
    const { byItem } = await coreLoadPromptShares(e, "users/b/");
    expect(byItem.p_1).toEqual({ code: "8888", createdAt: "2026-07-22T01:00:00.000Z" });
  });
  it("coreDeletePromptShare 删行", async () => {
    const e = envWithCore();
    await coreUpsertPromptShare(e, "users/b/", "p_1", "4563", "2026-07-22T00:00:00.000Z", true);
    await coreDeletePromptShare(e, "users/b/", "p_1");
    const { byItem } = await coreLoadPromptShares(e, "users/b/");
    expect(byItem.p_1).toBeUndefined();
  });
  it("coreMintedToday 不数 borrowed 行", async () => {
    const e = envWithCore();
    await coreUpsertPromptShare(e, "users/b/", "p_1", "4563", `${today}T00:00:00.000Z`, true);
    await coreUpsertPromptShare(e, "users/b/", "p_2", "7654", `${today}T00:00:00.000Z`);
    expect(await coreMintedToday(e, "users/b/", today)).toBe(1);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: FAIL（coreDeletePromptShare 未导出 / borrowed 未落列）

- [ ] **Step 3: 实现**（`functions/lib/core-db.js` 四处）

coreLoadPromptShares 的 SELECT 与组装行改为：

```js
    const r = await d.prepare(
      "SELECT item_id, code, created_at, borrowed FROM prompt_shares WHERE user_sub=?"
    ).bind(scope).all();
    const byItem = {};
    for (const row of r.results || []) {
      byItem[row.item_id] = { code: row.code, createdAt: row.created_at, ...(row.borrowed ? { borrowed: true } : {}) };
    }
```

coreUpsertPromptShare 整函数改为：

```js
export async function coreUpsertPromptShare(env, scope, itemId, code, createdAt, borrowed = false) {
  const d = db(env);
  if (!d) return false;
  try {
    await d.prepare(
      "INSERT INTO prompt_shares (user_sub, item_id, code, created_at, borrowed) VALUES (?,?,?,?,?) " +
      "ON CONFLICT(user_sub, item_id) DO UPDATE SET code=excluded.code, created_at=excluded.created_at, borrowed=excluded.borrowed"
    ).bind(scope, itemId, String(code), createdAt, borrowed ? 1 : 0).run();
    return true;
  } catch (e) { console.error("[core-db] upsertPromptShare:", e && e.message); return false; }
}
```

coreMintedToday 的 SQL 改为（borrowed 行不占日上限——转发不是铸码）：

```js
      "SELECT COUNT(*) AS n FROM prompt_shares WHERE user_sub=? AND created_at LIKE ? AND borrowed=0"
```

coreRekeyPromptShare 之后新增：

```js
/// borrowed 条目关分享 = 删行（自有码关分享不删行——索引保留、同码复活，是另一条路；
/// spec 2026-07-22 §5）。
export async function coreDeletePromptShare(env, scope, itemId) {
  const d = db(env);
  if (!d) return false;
  try {
    await d.prepare("DELETE FROM prompt_shares WHERE user_sub=? AND item_id=?").bind(scope, itemId).run();
    return true;
  } catch (e) { console.error("[core-db] deletePromptShare:", e && e.message); return false; }
}
```

`agent/src/prompt-share.js` 两处：import 行加 `coreDeletePromptShare`；loadIndex 的自愈回填行改为透传 borrowed：

```js
      if (e && e.code) await coreUpsertPromptShare(env, scope, itemId, e.code, e.createdAt || new Date().toISOString(), !!e.borrowed);
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd agent && npx vitest run`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add functions/lib/core-db.js agent/src/prompt-share.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): core-db prompt_shares 读写带 borrowed + coreDeletePromptShare"
```

---

### Task 3: effectiveLeaf 透传 importedFrom（不进写穿副本）

**Files:**
- Modify: `agent/src/prompt-share.js`（effectiveLeaf 返回值）
- Test: `agent/test/prompt-share-redirect.test.js`

**Interfaces:**
- Consumes: `resolveList` 的 action 节点自带 `importedFrom`（prompts.js 已透传，`sanitizeStoredItems` 白名单已含该字段）。
- Produces: `effectiveLeaf(env, scope, itemId)` 返回对象新增可选字段 `importedFrom`（仅导入件有）。`sharedDocFor` 按字段挑选写穿，**importedFrom 不得写进 `shares/<码>`**。

- [ ] **Step 1: 写失败测试**（追加。测试经由公开路由观察：分享一个带 importedFrom 但**改过正文**的条目 → 铸自有码，且写穿副本里没有 importedFrom 字段）

```js
import { hmacSign, b64url } from "../../functions/lib/auth.js";
import { handlePromptShareRoutes } from "../src/prompt-share.js";
import worker from "../src/index.js";

const SECRET = "test-secret";
async function tok(scope) {
  const h = b64url(JSON.stringify({ alg: "HS256" }));
  const p = b64url(JSON.stringify({ scope, apple: true }));
  return `${h}.${p}.${await hmacSign(`${h}.${p}`, SECRET)}`;
}
const IMPORTER = "users/anon-importer1/";
function env2(seed = {}) { const e = fakeEnv(seed); e.SESSION_SECRET = SECRET; return e; }
// 原作者 other-author 的活跃分享副本（写穿格式，与 prompt-share.js sharedDocFor 对齐）
const ORIGIN_CODE = "4563";
const originDoc = (over = {}) => JSON.stringify({
  type: "prompt", sub: "other-author", itemId: "p_origin1",
  label: "更毒舌", instruction: "把它改得更毒舌，观点不变。", appliesTo: ["text"],
  importCount: 5, createdAt: "2026-07-20T00:00:00.000Z", updatedAt: "2026-07-20T00:00:00.000Z", ...over,
});
async function putTree(e, items) {
  const req = new Request("https://jianshuo.dev/agent/prompts", {
    method: "PUT",
    headers: { Authorization: `Bearer ${await tok(IMPORTER)}`, "content-type": "application/json" },
    body: JSON.stringify({ items }),
  });
  return worker.fetch(req, e);
}
async function share(e, id) {
  const req = new Request("https://jianshuo.dev/agent/prompt-share", {
    method: "POST",
    headers: { Authorization: `Bearer ${await tok(IMPORTER)}` },
    body: JSON.stringify({ id }),
  });
  return handlePromptShareRoutes(new URL(req.url), req, e);
}
async function unshare(e, id) {
  const req = new Request(`https://jianshuo.dev/agent/prompt-share/${encodeURIComponent(id)}`, {
    method: "DELETE", headers: { Authorization: `Bearer ${await tok(IMPORTER)}` },
  });
  return handlePromptShareRoutes(new URL(req.url), req, e);
}
// 导入件（改过正文版）：importedFrom 在、正文与 originDoc 不同
const editedImport = { id: "p_imp1", type: "action", label: "更毒舌", prompt: "改得更毒舌，再加点阴阳怪气。", appliesTo: ["text"], importedFrom: ORIGIN_CODE };

describe("effectiveLeaf importedFrom 透传", () => {
  it("改过正文的导入件分享 → 铸自有码；写穿副本无 importedFrom 字段", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [editedImport]);
    const r = await share(e, "p_imp1");
    expect(r.status).toBe(200);
    const j = await r.json();
    expect(j.code).not.toBe(ORIGIN_CODE);
    expect(j.original).toBeUndefined();
    const doc = JSON.parse(e.FILES._store.get(`shares/${j.code}`));
    expect(doc.sub).toBe("anon-importer1");
    expect(doc.importedFrom).toBeUndefined();
  });
});
```

- [ ] **Step 2: 跑测试确认现状**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: 此用例 PASS（现状本来就铸新码）——它此刻是**行为锚**；Task 4 改判定逻辑后它守住「改过 → 自有码」不回归。若 FAIL 说明理解有误，停下来查。

- [ ] **Step 3: 实现 effectiveLeaf 透传**（`agent/src/prompt-share.js`，effectiveLeaf 的 return 加一行）

```js
  return {
    label: hit.label, instruction: hit.prompt,
    appliesTo: hit.appliesTo,
    ...(hit.kind !== undefined ? { kind: hit.kind } : {}),
    ...(typeof hit.importedFrom === "string" && hit.importedFrom ? { importedFrom: hit.importedFrom } : {}),
    ...(entry.groupPath?.length ? { groupPath: entry.groupPath } : {}),
  };
```

- [ ] **Step 4: 全量回归**

Run: `cd agent && npx vitest run`
Expected: 全部 PASS（sharedDocFor 按字段挑选，importedFrom 不会漏进副本——Step 1 的断言已在守）

- [ ] **Step 5: Commit**

```bash
git add agent/src/prompt-share.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): effectiveLeaf 透传 importedFrom（写穿副本不带）"
```

---

### Task 4: POST 转发判定（核心）

**Files:**
- Modify: `agent/src/prompt-share.js`（handlePromptShareRoutes 的 POST 段）
- Test: `agent/test/prompt-share-redirect.test.js`

**Interfaces:**
- Consumes: Task 2 的 `coreUpsertPromptShare(..., borrowed)`、Task 3 的 `leaf.importedFrom`、既有 `resolvePromptShare` / `readProfileName` / `promptShareId`。
- Produces: 转发响应 `{code, url, created:false, sharing:true, original:true, author, communityShareId}`；索引 borrowed 条目 `{code, createdAt, borrowed:true}`（D1+R2 双轨）。铸码路径把 borrowed 条目当「无码」并替换。

- [ ] **Step 1: 写失败测试**（追加）

```js
describe("溯源转发（POST）", () => {
  // 未改导入件：正文与 originDoc 完全一致
  const cleanImport = { id: "p_imp2", type: "action", label: "随便改名也行", prompt: "把它改得更毒舌，观点不变。", appliesTo: ["text"], importedFrom: ORIGIN_CODE };

  it("未改导入件 → 返回原码 original:true；不写穿原副本；不占 mintLog；索引落 borrowed", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [cleanImport]);
    const j = await (await share(e, "p_imp2")).json();
    expect(j.code).toBe(ORIGIN_CODE);
    expect(j.original).toBe(true);
    expect(j.created).toBe(false);
    expect(j.sharing).toBe(true);
    expect(j.url).toBe(`https://voicedrop.cn/${ORIGIN_CODE}`);
    expect(typeof j.author).toBe("string");
    const origin = JSON.parse(e.FILES._store.get(`shares/${ORIGIN_CODE}`));
    expect(origin.sub).toBe("other-author");        // 副本没被写穿成导入者
    expect(origin.importCount).toBe(5);
    const idx = JSON.parse(e.FILES._store.get(`${IMPORTER}prompt-shares.json`));
    expect(idx.byItem.p_imp2).toMatchObject({ code: ORIGIN_CODE, borrowed: true });
    expect(idx.mintLog).toHaveLength(0);            // 不占日上限
  });
  it("幂等重放：再 POST 一次仍返回原码，副本仍是原作者的", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [cleanImport]);
    await share(e, "p_imp2");
    const j2 = await (await share(e, "p_imp2")).json();
    expect(j2.code).toBe(ORIGIN_CODE);
    expect(j2.original).toBe(true);
    expect(JSON.parse(e.FILES._store.get(`shares/${ORIGIN_CODE}`)).sub).toBe("other-author");
  });
  it("原分享已关 → 正常铸自有码", async () => {
    const e = env2(); // 不 seed shares/<原码>
    await putTree(e, [cleanImport]);
    const j = await (await share(e, "p_imp2")).json();
    expect(j.code).not.toBe(ORIGIN_CODE);
    expect(j.original).toBeUndefined();
    expect(j.created).toBe(true);
    expect(JSON.parse(e.FILES._store.get(`shares/${j.code}`)).sub).toBe("anon-importer1");
  });
  it("原作者后来改了原件（快照不再等同）→ 铸自有码", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc({ instruction: "原作者升级过的正文。" }) });
    await putTree(e, [cleanImport]);
    const j = await (await share(e, "p_imp2")).json();
    expect(j.code).not.toBe(ORIGIN_CODE);
    expect(j.created).toBe(true);
  });
  it("borrowed 之后导入者改了正文再 POST → 铸自有码替换 entry", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [cleanImport]);
    await share(e, "p_imp2");                        // 先转发
    await putTree(e, [{ ...cleanImport, prompt: "我自己改过的版本。" }]);
    const j = await (await share(e, "p_imp2")).json();
    expect(j.code).not.toBe(ORIGIN_CODE);
    expect(j.created).toBe(true);
    const idx = JSON.parse(e.FILES._store.get(`${IMPORTER}prompt-shares.json`));
    expect(idx.byItem.p_imp2.code).toBe(j.code);
    expect(idx.byItem.p_imp2.borrowed).toBeUndefined();
    expect(JSON.parse(e.FILES._store.get(`shares/${ORIGIN_CODE}`)).sub).toBe("other-author"); // 原副本始终没动
  });
  it("带 CORE 时 borrowed 行落 D1 且不占 coreMintedToday", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    e.CORE = fakeD1(coreSql());
    await putTree(e, [cleanImport]);
    await share(e, "p_imp2");
    const { byItem } = await coreLoadPromptShares(e, IMPORTER);
    expect(byItem.p_imp2).toMatchObject({ code: ORIGIN_CODE, borrowed: true });
    const today = new Date().toISOString().slice(0, 10);
    expect(await coreMintedToday(e, IMPORTER, today)).toBe(0);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: 「未改导入件」等用例 FAIL（现状铸新码）

- [ ] **Step 3: 实现**（`agent/src/prompt-share.js` POST 段）

在 `const existing = idx.byItem[itemId];` 之后、`let code = existing?.code;` 之前插入转发判定，并把铸码起点改为「自有码」：

```js
  const existing = idx.byItem[itemId];

  // 溯源转发（spec 2026-07-22-prompt-share-reshare-redirect）：还没有自有码（无 entry
  // 或 entry 只是 borrowed）且条目是导入件 → 与原码活跃副本比 instruction 严格相等。
  // 一致 = 同一作品：递原作者的码出去——不铸码、不写穿、不占日上限，索引记
  // borrowed 条目（开关状态要能持久）。改过 / 原分享已关 → 掉下去走正常铸码，
  // borrowed 条目被自有码替换。一旦铸过自有码，永远不再进这里（一辈子一个码）。
  const ownEntry = existing && !existing.borrowed ? existing : null;
  if (!ownEntry && leaf.importedFrom) {
    const origin = await resolvePromptShare(env, leaf.importedFrom);
    if (origin && origin.instruction === leaf.instruction) {
      if (!existing || existing.code !== origin.code) {
        const createdAt = new Date().toISOString();
        idx.byItem[itemId] = { code: origin.code, createdAt, borrowed: true };
        await coreUpsertPromptShare(env, scope, itemId, origin.code, createdAt, true);
        try {
          const r2idx = await loadIndexR2(env, scope);
          r2idx.byItem[itemId] = { code: origin.code, createdAt, borrowed: true };
          await env.FILES.put(indexKey(scope), JSON.stringify(r2idx, null, 2));
        } catch (e) { console.error("[prompt-share] r2 index write failed:", e && e.message); }
      }
      let author = "";
      try { author = (await readProfileName(env, `users/${origin.sub}/`, { fallback: "none" })) || ""; } catch { /* 无名不影响转发 */ }
      const communityShareId = await promptShareId(origin.code, env.SESSION_SECRET);
      return J({ code: origin.code, url: `https://voicedrop.cn/${origin.code}`, created: false, sharing: true, original: true, author, communityShareId });
    }
  }

  let code = ownEntry?.code;
  let created = false;
```

同段还有两处引用 `existing` 的地方改为 `ownEntry`（borrowed 条目不能把它的 createdAt/旧副本语义带进自有码路径）：

写穿行 `await env.FILES.put(...)` 里的 `existing?.createdAt` → `ownEntry?.createdAt`。

`if (!created)` 的 importCount 保留段条件不变（created 逻辑已隔离，borrowed→铸码时 created=true 自然跳过旧副本读取）。

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd agent && npx vitest run`
Expected: 全部 PASS（尤其 prompt-share.test.js 既有用例 0 回归）

- [ ] **Step 5: Commit**

```bash
git add agent/src/prompt-share.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): 导入件再分享溯源转发——未改正文返回原码，奖励归原作者"
```

---

### Task 5: DELETE 的 borrowed 分支 + shareStates 联动

**Files:**
- Modify: `agent/src/prompt-share.js`（handlePromptShareRoutes 的 DELETE 段）
- Test: `agent/test/prompt-share-redirect.test.js`

**Interfaces:**
- Consumes: Task 2 的 `coreDeletePromptShare`。
- Produces: borrowed 条目 DELETE → 只删自己索引（D1 行 + R2 entry），`shares/<原码>` 与原作者社区帖不动；响应 `{ok:true, code:<原码>, sharing:false}`。

- [ ] **Step 1: 写失败测试**（追加）

```js
import { shareStates } from "../src/prompt-share.js";

describe("borrowed 条目 DELETE / shareStates", () => {
  const cleanImport = { id: "p_imp3", type: "action", label: "更毒舌", prompt: "把它改得更毒舌，观点不变。", appliesTo: ["text"], importedFrom: ORIGIN_CODE };

  it("DELETE borrowed → 原作者副本完好；自己索引 entry 消失；再 POST 重新转发", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [cleanImport]);
    await share(e, "p_imp3");
    const r = await unshare(e, "p_imp3");
    const j = await r.json();
    expect(j.sharing).toBe(false);
    expect(e.FILES._store.get(`shares/${ORIGIN_CODE}`)).toBeTruthy();   // 原作者分享没被删
    const idx = JSON.parse(e.FILES._store.get(`${IMPORTER}prompt-shares.json`));
    expect(idx.byItem.p_imp3).toBeUndefined();
    const j2 = await (await share(e, "p_imp3")).json();                 // 再开 → 重新转发
    expect(j2.code).toBe(ORIGIN_CODE);
    expect(j2.original).toBe(true);
  });
  it("DELETE borrowed 连 D1 行一起删", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    e.CORE = fakeD1(coreSql());
    await putTree(e, [cleanImport]);
    await share(e, "p_imp3");
    await unshare(e, "p_imp3");
    const { byItem } = await coreLoadPromptShares(e, IMPORTER);
    expect(byItem.p_imp3).toBeUndefined();
  });
  it("shareStates：borrowed 条目 sharing 随 shares/<原码> 存活联动", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    await putTree(e, [cleanImport]);
    await share(e, "p_imp3");
    let st = await shareStates(e, IMPORTER);
    expect(st.p_imp3).toEqual({ shareCode: ORIGIN_CODE, sharing: true });
    e.FILES._store.delete(`shares/${ORIGIN_CODE}`);   // 原作者关分享
    st = await shareStates(e, IMPORTER);
    expect(st.p_imp3).toEqual({ shareCode: ORIGIN_CODE, sharing: false });
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: DELETE 用例 FAIL（现状会把 `shares/<原码>` 删掉 / 索引 entry 还在）

- [ ] **Step 3: 实现**（DELETE 段开头加 borrowed 分支）

```js
  if (isDelete) {
    const itemId = decodeURIComponent(url.pathname.slice("/agent/prompt-share/".length));
    const { byItem } = await loadIndex(env, scope);
    const entry = byItem[itemId];
    // borrowed（转发原码）关分享：只删自己的索引条目——shares/<码> 是原作者的分享
    // 本体绝不能碰，也没有自己的帖可撤。删行后再开 = 重新走转发判定（spec §5）。
    if (entry && entry.borrowed) {
      await coreDeletePromptShare(env, scope, itemId);
      try {
        const r2idx = await loadIndexR2(env, scope);
        delete r2idx.byItem[itemId];
        await env.FILES.put(indexKey(scope), JSON.stringify(r2idx, null, 2));
      } catch (e) { console.error("[prompt-share] r2 index write failed:", e && e.message); }
      return J({ ok: true, code: entry.code, sharing: false });
    }
    const code = entry?.code;
    if (code) {
      // ……（既有逻辑原样保留：删 shares/<码> + retractPromptPost）
```

（shareStates 无需改——entry.code 即原码，`CODE_RE` 4–16 位已放行，head 探活天然联动。Step 1 的用例是行为锚。）

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd agent && npx vitest run`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add agent/src/prompt-share.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): borrowed 条目关分享只删自己索引，绝不碰原作者分享"
```

---

### Task 6: prompt-market 候选排除 borrowed 行

**Files:**
- Modify: `agent/src/prompt-market.js`（候选 SQL）
- Test: `agent/test/prompt-share-redirect.test.js`

**Interfaces:**
- Consumes: migration 0004 的 `borrowed` 列（生产部署顺序：先 migration 后 deploy，见 Global Constraints）。
- Produces: 市场列表同一个码只出现一次（原作者那条）。

- [ ] **Step 1: 写失败测试**（追加）

```js
import { handlePromptMarket } from "../src/prompt-market.js";

describe("prompt-market 排除 borrowed 行", () => {
  it("原作者一行 + 导入者 borrowed 行同码 → 市场只出一条", async () => {
    const e = env2({ [`shares/${ORIGIN_CODE}`]: originDoc() });
    e.CORE = fakeD1(coreSql());
    const ins = (sub, item, code, borrowed) =>
      e.CORE.prepare("INSERT INTO prompt_shares (user_sub, item_id, code, created_at, borrowed) VALUES (?,?,?,?,?)")
        .bind(sub, item, code, "2026-07-22T00:00:00.000Z", borrowed).run();
    ins("users/other-author/", "p_origin1", ORIGIN_CODE, 0);
    ins(IMPORTER, "p_imp9", ORIGIN_CODE, 1);
    const req = new Request("https://jianshuo.dev/agent/prompt-market", {
      headers: { Authorization: `Bearer ${await tok(IMPORTER)}` },
    });
    const r = await handlePromptMarket(new URL(req.url), req, e);
    const { items } = await r.json();
    expect(items.filter((i) => i.code === ORIGIN_CODE)).toHaveLength(1);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share-redirect.test.js`
Expected: FAIL（同码出现两次）

- [ ] **Step 3: 实现**（候选 SQL 加 WHERE）

```js
    const rows = (await env.CORE.prepare(
      "SELECT ps.code, ps.user_sub, ps.created_at, COALESCE(ss.import_count, 0) AS imports " +
      "FROM prompt_shares ps LEFT JOIN share_stats ss ON ss.code = ps.code " +
      "WHERE COALESCE(ps.borrowed, 0) = 0 " +   // borrowed 行是转发状态不是作品，同码去重（spec 2026-07-22 §6）
      "ORDER BY ps.created_at DESC LIMIT 500"
    ).all()).results || [];
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd agent && npx vitest run`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add agent/src/prompt-market.js agent/test/prompt-share-redirect.test.js
git commit -m "feat(voicedrop): prompt-market 候选排除 borrowed 行（同码不重复展示）"
```

---

### Task 7: 回归 + 上线（migration → Worker → Pages → 验证 → push main）

**Files:**
- 无新改动；纯发布。

- [ ] **Step 1: 全量回归（agent + mcp）**

Run: `cd agent && npx vitest run && cd ../mcp && npx vitest run`
Expected: 两套全 PASS

- [ ] **Step 2: 合 origin/main（voicedrop-agent 部署纪律）**

```bash
git fetch origin main && git merge origin/main --no-edit
cd agent && npx vitest run   # 合并后再跑一遍
```

- [ ] **Step 3: 应用 D1 migration（必须先于 Worker deploy）**

```bash
cd agent && CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler d1 migrations apply voicedrop-core --remote
```
Expected: 0004_prompt_shares_borrowed.sql applied（列表里只剩这一个未应用项）

- [ ] **Step 4: 部署 Worker + 拉线上内容验证**

```bash
cd agent && CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler deploy
curl -sS --max-time 240 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/2f33014654e1b826e27ab00d4e7242fd/workers/scripts/voicedrop-agent/content/v2" \
  -o "$CLAUDE_JOB_DIR/tmp/vd-live-check.js"
grep -c "coreDeletePromptShare" "$CLAUDE_JOB_DIR/tmp/vd-live-check.js"   # ≥1：新代码在
grep -c "IMAGE_SUANLI" "$CLAUDE_JOB_DIR/tmp/vd-live-check.js"            # ≥1：别人的活没被冲掉
```

- [ ] **Step 5: push main + Pages 部署**（core-db.js 是 Pages functions 共享代码，保持同版）

```bash
git push origin HEAD:main
D="$CLAUDE_JOB_DIR/tmp/jd-deploy" && rm -rf "$D" && mkdir -p "$D" && git archive HEAD | tar -x -C "$D" && cd "$D" && CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler pages deploy . --project-name jianshuo-dev --branch main --commit-dirty=true
```

- [ ] **Step 6: 线上冒烟**

```bash
curl -sS "https://jianshuo.dev/agent/prompt-market?limit=5" -H "Authorization: Bearer <任意匿名 token 不可用时跳过>" -o /dev/null -w "%{http_code}\n"
# 或至少：GET /agent/prompt-share/<任一活跃码> 返回 200，市场端点无 5xx
```
Expected: 无 5xx；市场正常出列表（borrowed 未上量前行为与改造前一致）

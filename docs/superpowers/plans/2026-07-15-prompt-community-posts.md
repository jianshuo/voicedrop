# 提示词社区帖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 开「分享这条提示词」= 铸 7 位码 + 自动发社区帖；社区加「提示词」筛选 tab；帖内一键导入/投币/回应；关分享帖码同死。

**Architecture:** 提示词帖是 schema-2 社区帖的新变体（`kind:"prompt"`，`promptCode` 指向 `shares/<码>` 写穿副本，不复制内容）；shareId 从码 HMAC 派生（`shareIdFor("promptshare:<码>")`）保证同码同帖、fork 免疫。发帖/撤帖逻辑放在 agent worker 的 prompt-share 路由里（iOS/MCP/安卓零特判）；D1 `community_posts` 加 `kind` 列，reco feed 透传；iOS 客户端过滤出「提示词」tab。老 App 靠 community/get 合成 `articles` 形状零崩溃降级。

**Tech Stack:** Cloudflare Workers（agent/reco）+ Pages Functions（files API）+ D1 + R2；iOS SwiftUI（xcodegen 工程）。

**Spec:** `docs/superpowers/specs/2026-07-15-prompt-community-posts-design.md`（voicedrop repo）

## Global Constraints

- 服务端仓库 = `~/code/jianshuo.dev`，iOS 仓库 = `~/code/voicedrop`。两仓直接在 main 提交（用户约定：验证后直接 push main，不开 PR）。
- 任何服务端改动前后跑 `cd ~/code/jianshuo.dev/agent && npm test`（全量必须绿）；reco 改动另跑 `cd ~/code/jianshuo.dev/reco && npm test`；MCP 改动跑 `cd ~/code/jianshuo.dev/mcp && npm test`。
- D1 写失败一律吞掉（console.log 后继续），绝不打断主路径——与现有 indexUpsert 同纪律。
- 错误码复用现有契约：登录门槛 = `403 {error:"needs_apple_signin"}`；审核拦截 = `403 {error:"content_flagged"}`。
- iOS 新增 .swift 文件后先 `xcodegen generate`；本计划不新增文件，只改现有文件。
- iOS 单测跑法：`xcodebuild test -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VoiceDropTests`。
- voicedrop-agent 部署纪律：部署前先 `git pull origin main`（wrangler 整包覆盖，旧树部署 = 回滚别人）。
- 提交信息不带 `[tf]`（不自动发 TestFlight；iOS 发版由用户拍板）。

---

## 服务端（jianshuo.dev repo）

### Task 1: D1 migration + reco feed 透传 kind

**Files:**
- Create: `reco/migrations/0003_community_posts_kind.sql`
- Modify: `reco/src/store.js`（feedRows SELECT）
- Modify: `reco/src/index.js`（feed 响应映射）
- Modify: `reco/test/fakes.js`（fake 行支持 kind 列）
- Test: `reco/test/index.test.js`

**Interfaces:**
- Produces: D1 列 `community_posts.kind TEXT NOT NULL DEFAULT 'article'`；`GET /reco/feed` 响应每个 post 多 `kind` 字段（`'article'` 或 `'prompt'`，缺省不下发也可——**决定：恒下发**，客户端解码简单）。

- [ ] **Step 1: 写 migration 文件**

```sql
-- reco/migrations/0003_community_posts_kind.sql
-- 提示词社区帖：帖子类型列。存量全部是文章帖，DEFAULT 'article' 零影响。
ALTER TABLE community_posts ADD COLUMN kind TEXT NOT NULL DEFAULT 'article';
```

- [ ] **Step 2: 写失败测试（feed 透传 kind）**

在 `reco/test/index.test.js` 的 feed describe 里加（沿用该文件现有的 fakeEnv/seed 写法，给 seed 行加 `kind: 'prompt'`）：

```js
it("feed 每帖带 kind：文章帖 article、提示词帖 prompt", async () => {
  const env = fakeEnv({ posts: [
    { share_id: "aaaaaaaaaaaa", owner: "users/u1/", author: "甲", title: "文章帖",
      first_shared_at: 1000, kind: "article" },
    { share_id: "bbbbbbbbbbbb", owner: "users/u2/", author: "乙", title: "改毒舌",
      first_shared_at: 2000, kind: "prompt" },
  ]});
  const resp = await worker.fetch(req("GET", "/reco/feed"), env);
  const { posts } = await resp.json();
  const byId = Object.fromEntries(posts.map(p => [p.shareId, p]));
  expect(byId.aaaaaaaaaaaa.kind).toBe("article");
  expect(byId.bbbbbbbbbbbb.kind).toBe("prompt");
});
```

（`req` / `fakeEnv` 用该测试文件里现成的构造函数；若 fake 的 SELECT 解析在 `reco/test/fakes.js:27` 按列名过滤，给它的行对象补 `kind` 字段即可。）

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/reco && npx vitest run test/index.test.js`
Expected: FAIL —— `kind` 为 undefined。

- [ ] **Step 4: 实现**

`reco/src/store.js` feedRows 的 SELECT 加列：

```js
    `SELECT share_id, owner, author, title, preview, cover_photo_key, has_photo,
            article_count, first_shared_at, updated_at, reply_to, kind
     FROM community_posts WHERE hidden=0
     ORDER BY first_shared_at DESC LIMIT 500`,
```

`reco/src/index.js` feed 响应映射（posts 的 map 里）加一行：

```js
        kind: r.kind || "article",
```

`reco/test/fakes.js`：fake 行缺省补 `kind: 'article'`（模拟 DEFAULT）。

- [ ] **Step 5: 跑测试确认通过 + reco 全量**

Run: `cd ~/code/jianshuo.dev/reco && npm test`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev && git add reco/ && git commit -m "feat(reco): community_posts 加 kind 列，feed 透传——提示词社区帖 Task 1"
```

---

### Task 2: Pages——indexUpsert 认 kind + community/list 快路径带 kind

**Files:**
- Modify: `functions/files/api/[[path]].js`（indexUpsert、community/list D1 快路径）
- Test: `agent/test/community-index.test.js` 或该文件现有社区索引测试所在文件（先 `grep -rln indexUpsert agent/test/` 找到正确文件；若测试在 `articles-index-cache.test.js`/`community` 相关文件里，就地扩展）

**Interfaces:**
- Consumes: Task 1 的 D1 `kind` 列。
- Produces: `indexUpsert(p, articles, photos, {hidden, kind})` —— 第四参对象新增 `kind`（缺省 `'article'`）；`GET /files/api/community/list` D1 快路径每帖带 `kind`。后续 Task 4（agent 发帖）与 Task 5（reconcile/get 自愈）都调它的语义等价物。

- [ ] **Step 1: 写失败测试**

在现有社区索引测试文件里加两条（沿用其 fake env / 请求构造）：

```js
it("indexUpsert 带 kind=prompt 时行的 kind 是 prompt；缺省是 article", async () => {
  // 走 share 路由发一个普通文章帖 → 查 fake D1 行 kind === 'article'
  // 再直接构造一个 kind:'prompt' 的帖调用 reindex → 行 kind === 'prompt'
});

it("community/list D1 快路径每帖带 kind", async () => {
  // seed fake D1 两行（article/prompt），GET community/list，断言响应 posts[].kind
});
```

（具体断言按该文件现有风格写实——fake D1 是 `agent/test/fakes.js` 的内存版，`_posts` 可直接检查。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/<对应文件>`
Expected: FAIL。

- [ ] **Step 3: 实现**

`indexUpsert` 签名与 INSERT 改成：

```js
  async function indexUpsert(p, articles, photos, { hidden = null, kind = null } = {}) {
    if (!env.RECO_DB) return;
    try {
      const ex = cardExtras(articles, photos, p.owner);
      const title = articles[0]?.title ?? p.title ?? '';
      const k = kind || p.kind || 'article';
      const hid = hidden !== null ? (hidden ? 1 : 0)
        : ((await env.FILES.head(reportKey(p.shareId))) ? 1 : 0);
      await env.RECO_DB.prepare(
        `INSERT INTO community_posts (share_id, owner, article_key, author, title, preview,
           cover_photo_key, has_photo, article_count, first_shared_at, updated_at, reply_to, hidden, kind)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(share_id) DO UPDATE SET
           owner=excluded.owner, article_key=excluded.article_key, author=excluded.author,
           title=excluded.title, preview=excluded.preview, cover_photo_key=excluded.cover_photo_key,
           has_photo=excluded.has_photo, article_count=excluded.article_count,
           first_shared_at=excluded.first_shared_at, updated_at=excluded.updated_at,
           reply_to=excluded.reply_to, hidden=excluded.hidden, kind=excluded.kind`,
      ).bind(p.shareId, p.owner || '', p.articleKey || null, p.author || '', title,
             ex.preview || null, ex.coverPhotoKey || null, ex.hasPhoto ? 1 : 0,
             articles.length || 1, p.firstSharedAt || null,
             p.updatedAt || p.firstSharedAt || null, p.replyTo || null, hid, k).run();
    } catch (e) { console.log('[community-index] upsert failed', String(e?.message || e)); }
  }
```

community/list D1 快路径：SELECT 加 `kind`，响应 map 加 `kind: r.kind || 'article'`。R2 慢路径的响应行也补 `kind: p.kind || 'article'`（从帖 JSON 读）。

`agent/test/fakes.js` 的内存版 RECO_DB：INSERT 列解析若是写死列表，同步加 `kind`。

- [ ] **Step 4: 跑测试确认通过 + agent 全量**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: 全绿（1041+ 用例）。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev && git add functions/ agent/test/ && git commit -m "feat(community): 展示索引与 list 认 kind 列——提示词社区帖 Task 2"
```

---

### Task 3: agent worker——prompt-community 发帖/撤帖帮手 + RECO_DB binding

**Files:**
- Create: `agent/src/prompt-community.js`
- Modify: `agent/wrangler.jsonc`（d1_databases 加 RECO_DB）
- Test: `agent/test/prompt-community.test.js`（新）

**Interfaces:**
- Consumes: `shareIdFor` / `communityKey`（`functions/lib/community-store.js`）、`readProfileName`（`functions/lib/style-store.js`）、`resolvePromptShare`（`./prompt-share.js`）。
- Produces:
  - `promptShareId(code, secret) → Promise<string>`（12 位）
  - `publishPromptPost(env, scope, code, leaf) → Promise<string|null>`（返回 shareId；失败吞掉返回 null）
  - `retractPromptPost(env, code) → Promise<void>`（删帖删 D1 行，best-effort）
  Task 4 在 prompt-share 路由里调这三个。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/prompt-community.test.js
import { vi, describe, it, expect } from "vitest";
vi.mock("agents", () => ({ Agent: class Agent {}, getAgentByName: async () => ({}) }));
import { fakeEnv } from "./fakes.js";
import { promptShareId, publishPromptPost, retractPromptPost } from "../src/prompt-community.js";

const SECRET = "test-secret";
const OWNER = "users/anon-owner111/";
const LEAF = { label: "更毒舌", instruction: "把它改得更毒舌，观点不变。", appliesTo: ["text"] };

function makeEnv(seed = {}) { const e = fakeEnv(seed); e.SESSION_SECRET = SECRET; return e; }

describe("promptShareId", () => {
  it("同码恒同 id，12 位", async () => {
    const a = await promptShareId("4563566", SECRET);
    expect(a).toMatch(/^[A-Za-z0-9_-]{12}$/);
    expect(await promptShareId("4563566", SECRET)).toBe(a);
    expect(await promptShareId("4563567", SECRET)).not.toBe(a);
  });
});

describe("publishPromptPost", () => {
  it("写 community/<shareId>.json（kind=prompt, promptCode）+ D1 行", async () => {
    const e = makeEnv();
    const sid = await publishPromptPost(e, OWNER, "4563566", LEAF);
    const post = JSON.parse(await (await e.FILES.get(`community/${sid}.json`)).text());
    expect(post).toMatchObject({ schema: 2, shareId: sid, owner: OWNER,
      kind: "prompt", promptCode: "4563566" });
    expect(post.firstSharedAt).toBeTypeOf("number");
    const row = e.RECO_DB._posts.find(r => r.share_id === sid);
    expect(row).toMatchObject({ kind: "prompt", title: "更毒舌", has_photo: 0 });
  });

  it("复活保留 firstSharedAt（帖已存在时不重置）", async () => {
    const e = makeEnv();
    const sid = await publishPromptPost(e, OWNER, "4563566", LEAF);
    const t0 = JSON.parse(await (await e.FILES.get(`community/${sid}.json`)).text()).firstSharedAt;
    await publishPromptPost(e, OWNER, "4563566", LEAF);
    const t1 = JSON.parse(await (await e.FILES.get(`community/${sid}.json`)).text()).firstSharedAt;
    expect(t1).toBe(t0);
  });

  it("RECO_DB 缺失/写炸不打断（仍写 R2 返回 shareId）", async () => {
    const e = makeEnv();
    delete e.RECO_DB;
    const sid = await publishPromptPost(e, OWNER, "4563566", LEAF);
    expect(sid).toMatch(/^[A-Za-z0-9_-]{12}$/);
    expect(await e.FILES.get(`community/${sid}.json`)).toBeTruthy();
  });
});

describe("retractPromptPost", () => {
  it("删帖删 D1 行；帖不存在时静默", async () => {
    const e = makeEnv();
    const sid = await publishPromptPost(e, OWNER, "4563566", LEAF);
    await retractPromptPost(e, "4563566");
    expect(await e.FILES.get(`community/${sid}.json`)).toBeNull();
    expect(e.RECO_DB._posts.find(r => r.share_id === sid)).toBeUndefined();
    await retractPromptPost(e, "4563566"); // 幂等不炸
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/prompt-community.test.js`
Expected: FAIL —— 模块不存在。

- [ ] **Step 3: 实现 `agent/src/prompt-community.js`**

```js
// src/prompt-community.js — 提示词社区帖：分享即发帖，帖码同生同死。
// spec: voicedrop repo docs/superpowers/specs/2026-07-15-prompt-community-posts-design.md
//
// 帖 = community/<shareId>.json 的 kind:"prompt" 变体，内容零复制——正文实时读
// shares/<码>（写穿副本，作者保存时 refreshPromptShare 已同步）。shareId 从【码】
// HMAC 派生（不从 itemId）：码一辈子不变（含 fork re-key），同码同帖复活、fork 后
// 帖不断，全部自动成立，索引里不用存任何新绑定。
import { shareIdFor, communityKey } from "../../functions/lib/community-store.js";
import { readProfileName } from "../../functions/lib/style-store.js";

export const promptShareId = (code, secret) => shareIdFor(`promptshare:${code}`, secret);

// 卡片预览口径对齐 Pages 的 cardExtras：纯文本前 60 字。
const previewOf = (s) => String(s || "").replace(/\s+/g, " ").trim().slice(0, 60);

/// 发帖（开分享/复活时调用）。失败吞掉返回 null——发帖是铸码的附属动作，
/// 绝不能让它拖垮铸码本身；漂移由 reconcileIndex 收敛。
export async function publishPromptPost(env, scope, code, leaf) {
  try {
    const shareId = await promptShareId(code, env.SESSION_SECRET);
    const key = communityKey(shareId);
    let firstSharedAt = Date.now();
    const existing = await env.FILES.get(key);
    if (existing) {
      try { firstSharedAt = JSON.parse(await existing.text()).firstSharedAt || firstSharedAt; } catch {}
    }
    let author = "";
    try { author = await readProfileName(env, scope); } catch {}
    const post = { schema: 2, shareId, owner: scope, kind: "prompt", promptCode: code,
                   author, firstSharedAt };
    await env.FILES.put(key, JSON.stringify(post), { httpMetadata: { contentType: "application/json" } });
    await indexUpsertPrompt(env, post, leaf);
    return shareId;
  } catch (e) { console.error("[prompt-community] publish failed:", e && e.message); return null; }
}

/// 撤帖（关分享时调用）。best-effort、幂等。
export async function retractPromptPost(env, code) {
  try {
    const shareId = await promptShareId(code, env.SESSION_SECRET);
    await env.FILES.delete(communityKey(shareId));
    if (env.RECO_DB) {
      try {
        await env.RECO_DB.prepare("DELETE FROM community_posts WHERE share_id=?").bind(shareId).run();
      } catch (e) { console.log("[prompt-community] index delete failed", String(e?.message || e)); }
    }
  } catch (e) { console.error("[prompt-community] retract failed:", e && e.message); }
}

// D1 展示索引行（与 Pages indexUpsert 的 prompt 语义一致：title=label、
// preview=正文前60字、无图）。写失败吞掉。
async function indexUpsertPrompt(env, post, leaf) {
  if (!env.RECO_DB) return;
  try {
    await env.RECO_DB.prepare(
      `INSERT INTO community_posts (share_id, owner, article_key, author, title, preview,
         cover_photo_key, has_photo, article_count, first_shared_at, updated_at, reply_to, hidden, kind)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
       ON CONFLICT(share_id) DO UPDATE SET
         owner=excluded.owner, author=excluded.author, title=excluded.title,
         preview=excluded.preview, updated_at=excluded.updated_at, hidden=excluded.hidden,
         kind=excluded.kind`,
    ).bind(post.shareId, post.owner, null, post.author || "", leaf.label || "",
           previewOf(leaf.instruction) || null, null, 0, 1,
           post.firstSharedAt, Date.now(), null, 0, "prompt").run();
  } catch (e) { console.log("[prompt-community] index upsert failed", String(e?.message || e)); }
}
```

`agent/wrangler.jsonc` 的 `d1_databases` 加一项（database_id 抄 reco/wrangler.jsonc 的同库）：

```jsonc
    { "binding": "RECO_DB", "database_name": "voicedrop-reco", "database_id": "feeee5df-0f48-43ca-8845-473d8b4809c3" }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/prompt-community.test.js`
Expected: PASS。（若 fakeEnv 未内置 RECO_DB，从 fakes.js 导出的内存版手动挂到 e 上——看 fakes.js 现有导出方式。）

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev && git add agent/src/prompt-community.js agent/wrangler.jsonc agent/test/prompt-community.test.js && git commit -m "feat(agent): 提示词社区帖发布/撤回帮手 + RECO_DB binding——Task 3"
```

---

### Task 4: agent worker——prompt-share 路由接线（登录门槛 + 审核 + 发帖/撤帖）

**Files:**
- Modify: `agent/src/prompt-share.js`（handlePromptShareRoutes）
- Test: `agent/test/prompt-share.test.js`（扩展）

**Interfaces:**
- Consumes: Task 3 的 `publishPromptPost` / `retractPromptPost`；`checkArticlesShareable`（`functions/lib/moderation.js`）。
- Produces: `POST /agent/prompt-share` 成功响应新增 `communityShareId` 字段；匿名 token → `403 {error:"needs_apple_signin"}`；审核拦截 → `403 {error:"content_flagged"}`。`DELETE` 撤帖。**iOS（Task 8-10）与 MCP（Task 6）依赖这些契约。**

- [ ] **Step 1: 写失败测试（扩展 prompt-share.test.js）**

沿用该文件的 makeEnv/post/del/makeToken 基建。注意现有 makeToken 造的是 `apple:true` 的 session token；匿名场景直接给 `anon_xxx` 裸 token：

```js
describe("分享即发帖（2026-07-15 提示词社区帖）", () => {
  it("开分享 → 铸码 + 社区帖 + communityShareId 字段", async () => {
    const e = makeEnv();
    const r = await post(e, { id: SYS_ITEM });
    const body = await r.json();
    expect(r.status).toBe(200);
    expect(body.communityShareId).toMatch(/^[A-Za-z0-9_-]{12}$/);
    const p = JSON.parse(await (await e.FILES.get(`community/${body.communityShareId}.json`)).text());
    expect(p).toMatchObject({ kind: "prompt", promptCode: body.code, owner: OWNER });
  });

  it("匿名 token 403 needs_apple_signin，不铸码不发帖", async () => {
    const e = makeEnv();
    const req = new Request("https://jianshuo.dev/agent/prompt-share", {
      method: "POST", headers: { Authorization: "Bearer anon_abcdef1234567890" },
      body: JSON.stringify({ id: SYS_ITEM }),
    });
    const r = await handlePromptShareRoutes(new URL(req.url), req, e);
    expect(r.status).toBe(403);
    expect((await r.json()).error).toBe("needs_apple_signin");
  });

  it("审核拦截：label/正文命中屏蔽词 → 403 content_flagged，不铸码", async () => {
    const e = makeEnv({ "config/community-blocklist.json": JSON.stringify(["测试屏蔽词"]) });
    // 先 PUT 一条含屏蔽词的自建提示词（putPrompts 基建），再对它开分享
    await putPrompts(e, [{ id: "p_flagged00", type: "action", label: "x",
      prompt: "内容含测试屏蔽词", appliesTo: ["text"] }]);
    const r = await post(e, { id: "p_flagged00" });
    expect(r.status).toBe(403);
    expect((await r.json()).error).toBe("content_flagged");
  });

  it("关分享 → 帖同死；再开 → 同码同帖复活且 firstSharedAt 保留", async () => {
    const e = makeEnv();
    const first = await (await post(e, { id: SYS_ITEM })).json();
    const postKey = `community/${first.communityShareId}.json`;
    const t0 = JSON.parse(await (await e.FILES.get(postKey)).text()).firstSharedAt;
    await del(e, SYS_ITEM);
    expect(await e.FILES.get(postKey)).toBeNull();
    const again = await (await post(e, { id: SYS_ITEM })).json();
    expect(again.code).toBe(first.code);
    expect(again.communityShareId).toBe(first.communityShareId);
    // 复活后 firstSharedAt 重置为新时间是可接受的（帖曾被删除）；只断言帖回来了
    expect(await e.FILES.get(postKey)).toBeTruthy();
  });
});
```

**注意**：现有用例里有匿名/scope 相关的老断言可能因门槛收紧而变红——逐条看：凡断言「匿名能铸码」的行为已被产品决策推翻，改写那些用例为 403 断言，不要削弱新门槛来迁就旧测试。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/prompt-share.test.js`
Expected: 新用例 FAIL。

- [ ] **Step 3: 实现（改 handlePromptShareRoutes）**

`agent/src/prompt-share.js`：

1. 顶部 import：

```js
import { checkArticlesShareable } from "../../functions/lib/moderation.js";
import { publishPromptPost, retractPromptPost } from "./prompt-community.js";
```

2. `resolveUserScope` 改为区分身份来源（返回 `{scope, verified}`）：

```js
async function resolveUserScope(request, env) {
  const tok = bearerToken(request);
  if (env.SESSION_SECRET) {
    const s = await verifySession(tok, env.SESSION_SECRET);
    if (s && s.scope && s.scope.startsWith("users/")) return { scope: s.scope, verified: true };
  }
  const anon = await anonScopeFromToken(tok);
  if (anon && anon.startsWith("users/")) return { scope: anon, verified: false };
  return null;
}
```

3. POST/DELETE 分支开头改成：

```js
  const who = await resolveUserScope(request, env);
  if (!who) return J({ error: "unauthorized" }, 401);
  // 发社区帖需要可追责身份（与社区发帖同一道门槛）。匿名 token 连码也不再能铸——
  // 分享 = 发帖是一个动作，不能半做。GET 公开预览不在此列（在上面已 return）。
  if (!who.verified) return J({ error: "needs_apple_signin" }, 403);
  const scope = who.scope;
```

4. DELETE 分支删码之后撤帖：

```js
  if (isDelete) {
    const itemId = decodeURIComponent(url.pathname.slice("/agent/prompt-share/".length));
    const { byItem } = await loadIndex(env, scope);
    const code = byItem[itemId]?.code;
    if (code) {
      await env.FILES.delete(`shares/${code}`);
      await retractPromptPost(env, code);
    }
    return J({ ok: true, code: code || null, sharing: false });
  }
```

5. POST 分支：`effectiveLeaf` 拿到 leaf 之后、长度检查之前加审核；写完 `shares/<码>` 之后发帖：

```js
  const leaf = await effectiveLeaf(env, scope, itemId);
  if (!leaf) return J({ error: "unknown id" }, 404);
  if (leaf.instruction.length > cfg.maxLength) return J({ error: "too long" }, 413);
  // 关键词审核（与文章分享同一把闸）：label+正文拼一篇“文章”扫一遍。
  const kw = await checkArticlesShareable([{ title: leaf.label, body: leaf.instruction }], env);
  if (kw.flagged) return J({ error: "content_flagged", term: kw.term }, 403);
```

结尾（现有 `await env.FILES.put(`shares/${code}`, …)` 之后）：

```js
  const communityShareId = await publishPromptPost(env, scope, code, leaf);
  return J({ code, url: `https://voicedrop.cn/${code}`, created, sharing: true,
             ...(communityShareId ? { communityShareId } : {}) });
```

- [ ] **Step 4: 跑 prompt-share 测试 + agent 全量**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: 全绿。老用例若因门槛收紧变红，按 Step 1 注意事项改写断言。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev && git add agent/src/prompt-share.js agent/test/prompt-share.test.js && git commit -m "feat(agent): 开分享=铸码+发社区帖，关分享=帖码同死；登录门槛+审核——Task 4"
```

---

### Task 5: Pages——community/get 合成形状 + unshare 同死 + reconcile 收编提示词帖

**Files:**
- Modify: `functions/files/api/[[path]].js`（community/get、community/unshare、reconcileIndex）
- Test: agent/test 里现有社区路由测试文件（`grep -rln "community/get" agent/test/` 定位）扩展

**Interfaces:**
- Consumes: Task 2 的 `indexUpsert(..., {kind})`；`resolvePromptShare`（agent/src/prompt-share.js —— Pages 不能 import agent worker 源码，**就地重读 `shares/<码>` JSON**，见实现）。
- Produces: `GET community/get/<shareId>` 对 prompt 帖返回 `{shareId, author, title, articles:[{title,body}], owner, firstSharedAt, kind:"prompt", promptCode, appliesTo}`（老 App 兼容契约）；`POST community/unshare/<shareId>` 对 prompt 帖连 `shares/<码>` 一起删。

- [ ] **Step 1: 写失败测试**

```js
it("community/get 对提示词帖返回合成 articles + kind + promptCode", async () => {
  // seed：shares/4563566 = 写穿副本 JSON；community/<sid>.json = kind:prompt 指针
  // GET community/get/<sid> → articles[0] == {title: label, body: instruction}，
  // kind == "prompt"，promptCode == "4563566"，appliesTo 原样
});

it("community/get：码已失效（shares/<码> 没了）→ 404 且帖被自愈清掉", async () => {
  // seed 只有 community/<sid>.json 没有 shares/<码> → 404；community/<sid>.json 被删；D1 行被删
});

it("community/unshare 提示词帖：owner 撤帖连码同死", async () => {
  // seed 帖 + shares/<码> + owner 索引；unshare → 帖没了 + shares/<码> 没了
});

it("reconcileIndex 收编提示词帖：从 shares/<码> 读 title/preview，kind=prompt", async () => {});
it("reconcileIndex：码失效的提示词帖被清（R2 帖 + D1 行）", async () => {});
```

（具体 seed/断言按现有社区测试文件基建写实。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/<对应文件>`
Expected: FAIL。

- [ ] **Step 3: 实现**

在 `[[path]].js` 社区段（liveDocForPointer 附近）加提示词帖的解析帮手：

```js
  // 提示词帖（kind:"prompt"）：内容实时读 shares/<码> 写穿副本。副本没了 = 码已关
  // = 帖该死没死（agent 撤帖那步 best-effort 失败过）→ 自愈：清帖清索引，返回 null。
  async function livePromptLeaf(pointerKey, p) {
    try {
      const o = await env.FILES.get(`shares/${p.promptCode}`);
      if (o) {
        const doc = JSON.parse(await o.text());
        if (doc && doc.type === "prompt" && typeof doc.instruction === "string") return doc;
      }
    } catch {}
    await env.FILES.delete(pointerKey);
    await indexDelete(p.shareId);
    return null;
  }
```

`community/get`：解析出 `p` 之后、`p.articleKey` 分支之前加：

```js
    if (p.kind === 'prompt') {
      const leaf = await livePromptLeaf(communityKey(shareId), p);
      if (!leaf) return json({ error: 'not found' }, 404);
      const articles = [{ title: leaf.label || '分享提示词', body: leaf.instruction }];
      const heal = indexUpsert(p, articles, undefined, { kind: 'prompt' });
      if (waitUntil) waitUntil(heal); else await heal;
      return json({ shareId: p.shareId, author: p.author, title: articles[0].title,
                    articles, owner: p.owner, firstSharedAt: p.firstSharedAt,
                    kind: 'prompt', promptCode: p.promptCode,
                    ...(Array.isArray(leaf.appliesTo) ? { appliesTo: leaf.appliesTo } : {}),
                    ...(p.replyTo ? { replyTo: p.replyTo } : {}) });
    }
```

`community/unshare`：owner 校验通过后、删帖之前加：

```js
    let parsed = null; try { parsed = JSON.parse(await obj.text()); } catch {}
    // （owner 变量从 parsed 取，替换原先的独立 JSON.parse）
    if (parsed?.kind === 'prompt' && parsed.promptCode) {
      // 同生同死的反方向：社区撤帖 = 关分享（码立即失效）。owner 索引保留，
      // 提示词编辑页开关状态（按 shares/<码> head 判断）自动归位。
      await env.FILES.delete(`shares/${parsed.promptCode}`);
    }
```

`reconcileIndex`：postObjects 循环里 `p.articleKey` 分支之前加：

```js
        if (p.kind === 'prompt') {
          const o2 = await env.FILES.get(`shares/${p.promptCode}`);
          let leaf = null;
          try { const d = o2 && JSON.parse(await o2.text()); if (d?.type === 'prompt') leaf = d; } catch {}
          if (!leaf) { await env.FILES.delete(o.key); await indexDelete(p.shareId); return; }
          await indexUpsert(p, [{ title: leaf.label || '', body: leaf.instruction }], undefined,
                            { hidden: hidden.has(p.shareId), kind: 'prompt' });
          seen.add(p.shareId); indexed++;
          return;
        }
```

- [ ] **Step 4: 跑测试确认通过 + agent 全量**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: 全绿。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev && git add functions/ agent/test/ && git commit -m "feat(community): get 合成提示词帖形状 + unshare 帖码同死 + reconcile 收编——Task 5"
```

---

### Task 6: MCP——share_prompt/unshare_prompt 描述更新

**Files:**
- Modify: `mcp/src/tools.js`
- Test: `cd ~/code/jianshuo.dev/mcp && npm test`（描述改动无新断言，跑全量确认没碰坏）

- [ ] **Step 1: 改 description**

`share_prompt` 的 description 改为：

```js
    description:
      "把我的一条提示词分享出去：生成 7 位数字分享码（同时是 voicedrop.cn/<码> 短链），" +
      "并【自动发一个社区帖】（社区里大家能看到、导入、投币、回应）。需要 Apple 或微信登录" +
      "后的身份（匿名 token 会被拒并提示登录）。一条提示词一辈子一个码——重复调用返回同一个码，" +
      "关掉再开也是同码复活、社区帖同步复活。之后我改这条提示词，分享内容和社区帖自动跟着更新。" +
      "id 用 list_prompts 拿。返回里的 communityShareId 是社区帖 id。",
```

`unshare_prompt` 的 description 改为：

```js
    description:
      "停止分享一条提示词：分享码立即失效（别人再用码会被告知「分享已停止」），社区帖同步撤下。" +
      "码不会易主——之后再对同一条 share_prompt，还是原来那个码、原来那个帖。",
```

- [ ] **Step 2: 跑 MCP 全量**

Run: `cd ~/code/jianshuo.dev/mcp && npm test`
Expected: 130 用例全绿。

- [ ] **Step 3: Commit**

```bash
cd ~/code/jianshuo.dev && git add mcp/src/tools.js && git commit -m "docs(mcp): share_prompt/unshare_prompt 描述跟上自动发社区帖语义——Task 6"
```

---

### Task 7: 服务端部署 + 线上冒烟

**Files:** 无代码改动；纯运维。

- [ ] **Step 1: 合并远端 + push**

```bash
cd ~/code/jianshuo.dev && git pull --rebase origin main && npm test --prefix agent && git push origin main
```

- [ ] **Step 2: D1 migration（先于一切部署）**

```bash
cd ~/code/jianshuo.dev/reco && npx wrangler d1 migrations apply voicedrop-reco --remote
```

Expected: 0003 applied。

- [ ] **Step 3: 部署 reco → agent → Pages（按依赖序）**

```bash
cd ~/code/jianshuo.dev/reco && npx wrangler deploy
cd ~/code/jianshuo.dev/agent && npx wrangler deploy
rm -rf /tmp/jd-deploy && mkdir -p /tmp/jd-deploy && cd ~/code/jianshuo.dev && git archive HEAD | tar -x -C /tmp/jd-deploy && cd /tmp/jd-deploy && CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler pages deploy . --project-name jianshuo-dev --branch main --commit-dirty=true
```

- [ ] **Step 4: 线上冒烟（用 MCP 或 curl，走王建硕自己的登录 token）**

1. `share_prompt`（挑一条测试提示词）→ 响应有 `code` + `communityShareId`。
2. `GET /reco/feed` → 该 `communityShareId` 出现且 `kind:"prompt"`。
3. `GET /files/api/community/get/<communityShareId>` → 合成 `articles[0].body` == 提示词全文，`promptCode` == 码。
4. `unshare_prompt` → feed 里消失、`voicedrop.cn/<码>` 显示「分享已停止」、community/get 404。
5. 再 `share_prompt` → 同码同帖回来。
6. 匿名 token 调 `share_prompt` → 403 needs_apple_signin。
7. 收尾：把测试分享关掉，不留垃圾帖。

- [ ] **Step 5: 更新 voicedrop repo 的 STATE.md（服务端已上线段落）并提交**

---

## iOS（voicedrop repo）

### Task 8: 模型 + 「提示词」tab + 卡片角标

**Files:**
- Modify: `VoiceDropApp/Community.swift`（CommunityPost/CommunityFullPost 加字段）
- Modify: `VoiceDropApp/CommunityFeedView.swift`（FeedTab 加 case + tab 栏 + 过滤 + 角标）
- Test: `VoiceDropTests/`（新增 `CommunityKindTests.swift` —— 新文件，记得 `xcodegen generate`）

**Interfaces:**
- Consumes: feed/list 响应的 `kind` 字段（Task 1/2）。
- Produces: `CommunityPost.kind: String?`（nil 当 article）、`CommunityPost.isPrompt: Bool`；`CommunityFullPost.kind/promptCode/appliesTo`；`FeedTab.prompts` case。Task 9 依赖这些。

- [ ] **Step 1: 写失败测试**

```swift
// VoiceDropTests/CommunityKindTests.swift
import XCTest
@testable import VoiceDrop

final class CommunityKindTests: XCTestCase {
    func testDecodeKindDefaultsToArticle() throws {
        let json = #"{"shareId":"abcdefghijkl","title":"t"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityPost.self, from: json)
        XCTAssertFalse(p.isPrompt)
    }
    func testDecodePromptKind() throws {
        let json = #"{"shareId":"abcdefghijkl","title":"改毒舌","kind":"prompt"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityPost.self, from: json)
        XCTAssertTrue(p.isPrompt)
    }
    func testFullPostDecodesPromptCode() throws {
        let json = #"{"shareId":"abcdefghijkl","articles":[{"title":"改毒舌","body":"把它改得更毒舌"}],"kind":"prompt","promptCode":"4563566"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(CommunityFullPost.self, from: json)
        XCTAssertEqual(p.promptCode, "4563566")
        XCTAssertEqual(p.kind, "prompt")
    }
}
```

- [ ] **Step 2: `xcodegen generate` 后跑测试确认失败**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild test -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VoiceDropTests/CommunityKindTests`
Expected: FAIL（字段不存在编译错）。

- [ ] **Step 3: 实现**

`Community.swift` CommunityPost 加：

```swift
    var kind: String? = nil          // "prompt" = 提示词帖；nil/"article" = 文章帖
    var isPrompt: Bool { kind == "prompt" }
```

CommunityFullPost 加：

```swift
    var kind: String? = nil
    var promptCode: String? = nil    // 提示词帖：7 位分享码（导入用）
    var appliesTo: [String]? = nil
```

`CommunityFeedView.swift`：

```swift
    enum FeedTab { case reco, latest, replies, prompts }
```

列表来源 switch 加：

```swift
        case .prompts: return store.posts.filter { $0.isPrompt }
```

tab 栏在 `tabLabel(String(localized: "回应"), .replies)` 后面加：

```swift
            tabLabel(String(localized: "提示词"), .prompts)
```

`TextCoverCard`（提示词帖走文字卡）：卡片左上加角标胶囊（仅 `post.isPrompt` 时）：

```swift
            if post.isPrompt {
                Text("提示词")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.85)))
                    .foregroundStyle(Theme.ink)
            }
```

（具体挂点：TextCoverCard 的 ZStack/VStack 顶部，与现有元素对齐方式一致；`String Catalog` 会自动收新 key「提示词」。）

- [ ] **Step 4: 跑测试确认通过 + 全量单测 + BUILD**

Run: 同 Step 2 的命令去掉 `-only-testing` 限定；再 `xcodebuild build`。
Expected: 测试绿，BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/ VoiceDropTests/ VoiceDrop.xcodeproj && git commit -m "feat(community): 提示词帖模型 + 提示词筛选 tab + 卡片角标——Task 8"
```

---

### Task 9: CommunityPostView 提示词变体 + 「收下这条提示词」

**Files:**
- Modify: `VoiceDropApp/Community.swift`（CommunityPostView，:410 起）

**Interfaces:**
- Consumes: Task 8 的 `CommunityFullPost.kind/promptCode`；`PromptStore.shared.importPrompt(code:) → Result<PromptNode, PromptError>`（现成）。
- Produces: 无下游依赖。

- [ ] **Step 1: 实现**

CommunityPostView 正文区（现有 articles 渲染已天然显示合成的 label+全文，零改动）之上/CTA 区加：帖为提示词 (`full?.kind == "prompt"`) 且非自己的帖（`post.mine != true`）时显示主按钮：

```swift
    @State private var importing = false
    @State private var imported = false

    @ViewBuilder private var importPromptButton: some View {
        if let code = full?.promptCode, full?.kind == "prompt", post.mine != true {
            Button {
                guard !importing else { return }
                importing = true
                Task {
                    let r = await PromptStore.shared.importPrompt(code: code)
                    importing = false
                    switch r {
                    case .success:
                        imported = true
                        showToast(String(localized: "已加入你的提示词"))
                        Analytics.capture("社区提示词导入")
                    case .failure(let err):
                        showToast(err.message)
                    }
                }
            } label: {
                Label(imported ? String(localized: "已收下") : String(localized: "收下这条提示词"),
                      systemImage: imported ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(importing || imported)
            .padding(.horizontal, 16)
        }
    }
```

挂在正文 articles 渲染之后、回应区之前（视图结构以实读 CommunityPostView 为准；`showToast` 用该视图现有的 toast 机制，若无则用与投币同款的提示路径）。投币/回应零改动——按 shareId 全复用。

- [ ] **Step 2: BUILD + 模拟器目验**

Run: `xcodebuild build`；模拟器打开社区任一帖确认文章帖无按钮。
Expected: BUILD SUCCEEDED；文章帖 UI 零变化。

- [ ] **Step 3: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/Community.swift && git commit -m "feat(community): 提示词帖详情页「收下这条提示词」导入 CTA——Task 9"
```

---

### Task 10: PromptEditView 分享开关——社区文案 + 登录重试

**Files:**
- Modify: `VoiceDropApp/PromptStore.swift`（setSharing 加 needs_apple_signin 处理）
- Modify: `VoiceDropApp/PromptEditView.swift`（分享卡文案）

**Interfaces:**
- Consumes: Task 4 的 `403 needs_apple_signin` 契约；`AuthStore.shared.signInWithApple()`（CommunityStore.withAppleRetry 同款）。
- Produces: 无下游依赖。

- [ ] **Step 1: 实现 setSharing 登录重试**

`PromptStore.setSharing` 把一次请求提成内部函数，403 needs_apple_signin 时拉起 Apple 登录、成功后重试一次（对齐 CommunityStore.withAppleRetry 语义）：

```swift
    func setSharing(id: String, on: Bool) async -> String? {
        guard !token.isEmpty else { return String(localized: "请先登录") }
        let first = await postSharing(id: id, on: on)
        guard first.needsSignin else { return first.message }
        // 分享到社区需要可追责身份：拉起 Apple 登录，成功后重试一次。
        await AuthStore.shared.signInWithApple()
        guard AuthStore.shared.isAuthenticated else { return String(localized: "分享到社区需要先登录") }
        return await postSharing(id: id, on: on).message
    }

    private func postSharing(id: String, on: Bool) async -> (message: String?, needsSignin: Bool) {
        var req: URLRequest
        if on {
            struct P: Encodable { let id: String }
            req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-share"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(P(id: id))
        } else {
            req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-share").appendingPathComponent(id))
            req.httpMethod = "DELETE"
        }
        req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return (String(localized: "网络出错，请重试"), false)
        }
        if resp.isOK {
            Analytics.capture("提示词分享开关", ["开": on])
            return (nil, false)
        }
        if resp.httpStatusCode == 403,
           (try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "needs_apple_signin" {
            return (nil, true)
        }
        return (resp.httpStatusCode == 429
            ? String(localized: "今天生成分享码的次数已达上限，明天再试")
            : String(localized: "操作失败，请重试"), false)
    }
```

- [ ] **Step 2: 分享卡文案**

`PromptEditView.swift` 分享卡（:311 附近）：

```swift
Text("分享到社区").font(.system(size: 15)).foregroundStyle(Theme.ink)
Text(sharing ? "分享中：社区可见，关闭后分享码失效、社区帖撤下"
             : "开启后发布到社区，并得到分享码短链")
```

（第二行的确切现有字符串以实读为准，保持排版结构不动只换文案；String Catalog 收新 key，旧 key「分享这条提示词」及其英文翻译删除。）

- [ ] **Step 3: BUILD + 全量单测**

Run: `xcodebuild build` + VoiceDropTests 全量。
Expected: 绿。

- [ ] **Step 4: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/ && git commit -m "feat(prompts): 分享开关=发布到社区，匿名拉起登录重试——Task 10"
```

---

### Task 11: 收尾——真机手测清单 + STATE.md + push

**Files:**
- Modify: `STATE.md`

- [ ] **Step 1: STATE.md 新段落**

记录：提示词社区帖已实现（spec/plan 路径、kind 契约、同生同死语义、匿名门槛收紧、老 App 兼容合成形状、agent 加了 RECO_DB binding）+ 真机手测清单（下）。

- [ ] **Step 2: push main（不带 [tf]）**

```bash
cd ~/code/voicedrop && git push origin main
```

- [ ] **Step 3: 真机手测清单（用户执行，写进 STATE.md）**

① 开分享 → 社区推荐/最新/提示词 tab 三处立见，卡片有「提示词」角标
② 另一账号点开 → 全文 + 「收下这条提示词」→ 长按菜单立即可用
③ 投币、文章回应各来一次
④ 关开关 → 帖码同消（feed 消失 + 码短链「分享已停止」）
⑤ 再开 → 同码同帖复活
⑥ 匿名账号翻开关 → 拉起 Apple 登录 → 登录后自动重试成功
⑦ 老版本 App（TestFlight 上一版）打开提示词帖 → 当文字帖可读、可投币，无崩溃
⑧ 自己的提示词帖不显示导入按钮

真机通过后由用户拍板发 TestFlight（`gh workflow run build.yml -f destination=testflight` 或下次带 `[tf]` 的提交）。

---

## Self-Review 备忘（已跑）

- spec §2.1/2.2/2.3 → Task 1/3；§3.1/3.2 → Task 4；§3.3/3.4/3.5 → Task 5；§3.6 → Task 1；§3.7 → Task 3；§3.8 → Task 6；§4.1 → Task 8；§4.2 → Task 9；§4.3 → Task 10；§5 测试分散在各 task 的 TDD 步骤；§7 部署 → Task 7（服务端先行，iOS Task 8-11 随后）。
- 类型一致性：`publishPromptPost/retractPromptPost/promptShareId`（Task 3 定义、Task 4 消费）；`indexUpsert` 第四参 `{hidden, kind}`（Task 2 定义、Task 5 消费）；`CommunityPost.isPrompt`/`CommunityFullPost.promptCode`（Task 8 定义、Task 9 消费）；`403 needs_apple_signin`（Task 4 定义、Task 10 消费）。
- 有意留给实现者按现场实况适配的点（非占位符）：各测试文件的 fake 基建细节、CommunityPostView 的 toast 机制与按钮挂点、PromptEditView 现有文案字符串——计划已给出语义与代码骨架，现场以实读为准微调。

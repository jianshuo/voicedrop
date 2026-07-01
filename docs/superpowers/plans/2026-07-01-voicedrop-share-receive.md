# VoiceDrop 接受分享（Share Collect）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 VoiceDrop 成为 iOS 系统分享目标：音频/图片→「成文」sheet 挖文章，文字/网页/文档→「风格数据集」sheet 攒语料并一键「提取文章风格」。

**Architecture:** 自定义 SwiftUI Share Extension（替换 `SLComposeServiceViewController`）按类型分派三种 sheet；客户端提取一切文字（PDFKit/NSAttributedString/readability）；服务端加语料 collect/list/extract 接口 + 一处「无语音+有照片→vision」挖图逻辑。图片经静音占位 `.m4a` 复用现有音频锚点，iOS 主 app 零改动。

**Tech Stack:** SwiftUI + UIKit（Share Extension，`UIHostingController`）、PDFKit、AVFoundation；Cloudflare Pages Functions（语料 R2 接口）、Cloudflare Worker（agent，蒸馏 + 挖矿，Claude API）；vitest（服务端测试）；xcodegen。

设计源（pixel-perfect 复刻）：`design_handoff_share_collect/Share Collect.dc.html`。
Spec：`docs/superpowers/specs/2026-07-01-voicedrop-share-receive-design.md`。

## Global Constraints

- 服务端改动前后各跑 `cd ~/code/jianshuo.dev/agent && npm test`，保持现有 117+ 用例全绿（向后兼容是契约）。
- 设计 token（verbatim）：sheet 底 `#FAF6EF`；卡/输入底 `#fff`；主赭红 `#D8593B`（阴影 `rgba(216,89,59,0.28)`）；强调橙 `#C0682E`/`#C98A2E`；主文字 `#2A2521`；次文字 `#8A8175`/`#a79f93`；分隔线 `#EFE7D9`/`#ECE3D5`；本次新增高亮底 `#FBF1E9` 描边 `#E8C9B8`。字体 `-apple-system,'PingFang SC'`。
- 文件名：音频用录音式名 `VoiceDrop-<yyyy-MM-dd-HHmmss>-<dur>-<weekday>-<period>.m4a`（`RecordingName.make`）；图片占位音频同款名，图片传 `photos/<sessionTs>/<i>-<rand>.jpg`（`RecordingName.photoKey` 约定）。
- 鉴权用 `AppGroup.sharedBearer`（anon token）。所有服务端用户路由 401 无 token。
- R2 语料样本 key：`<scope>style/<id>.json`（`scope = users/<sub>/`）。
- iOS 新文件产生后**跑 xcodegen**（`cd ~/code/voicedrop && xcodegen`）。
- 提交信息结尾附带 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

# Phase 1 — 服务端（vitest TDD，先行，供 iOS 消费）

### Task 1: 无语音 + 有照片 → vision 挖图（`miner.js` + `prompts/mine.js`）

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/prompts/mine.js`（新增 `IMAGE_ONLY_SYSTEM`）
- Modify: `~/code/jianshuo.dev/agent/src/miner.js`（`mineOneAudio` 无语音分支）
- Test: `~/code/jianshuo.dev/agent/test/mine-image.test.js`（新建）

**Interfaces:**
- Consumes: 现有 `mineVariant(env, {transcript, styleText, photos, cacheMode, modelCfg, scope, stem, turnId, metaExtra, log})`、`gatherPhotos`/`photos/<ts>/` 收集、`writeArticle`、`writeEmpty`、`notifyStatus`。
- Produces: `IMAGE_ONLY_SYSTEM`（string 常量）；`mineOneAudio` 在 ASR 空且有照片时返回 `"mined"` 并写含 `[[photo:...]]` 的文章。

- [ ] **Step 1: 读现状定位插入点**

Run: `cd ~/code/jianshuo.dev/agent && grep -n "no-speech\|gatherPhotos\|photos/\|writeEmpty\|IMAGE_ONLY\|MINE_SYSTEM\|export const" src/miner.js src/prompts/mine.js | head -40`
目的：找到 `mineOneAudio` 里 ASR 判空→`writeEmpty("no-speech")` 的确切位置，以及照片收集函数名与 `mineVariant` 调用形态。

- [ ] **Step 2: 写失败测试**

`test/mine-image.test.js`：
```js
import { describe, it, expect, vi, beforeEach } from "vitest";
import { mineOneAudio } from "../src/miner.js";

// 最小 env：FILES 存根 + 无 D1（计费 fail-open）。Claude 由 modelCfg 注入的 fetch mock 返回一篇带 [[photo]] 的文章。
function makeEnv({ objects }) {
  const store = new Map(Object.entries(objects));
  return {
    FILES: {
      head: async k => store.has(k) ? {} : null,
      get: async k => store.has(k) ? { text: async () => store.get(k), arrayBuffer: async () => new TextEncoder().encode(store.get(k)).buffer } : null,
      put: async (k, v) => { store.set(k, typeof v === "string" ? v : "bin"); },
      list: async () => ({ objects: [], truncated: false }),
      delete: async k => { store.delete(k); },
    },
    _store: store,
  };
}

describe("mineOneAudio: 无语音 + 有照片 → vision", () => {
  it("ASR 空但有照片时写出含 [[photo]] 的文章而非 .empty", async () => {
    const scope = "users/anon-abc/";
    const audioKey = `${scope}VoiceDrop-2026-07-01-101010-1s-周三-上午.m4a`;
    const photoKey = `${scope}photos/2026-07-01-101010/0-a1b.jpg`;
    const env = makeEnv({ objects: { [audioKey]: "audiobytes", [photoKey]: "jpgbytes" } });
    // ASR + Claude 桩：ASR 返回空 text；Claude 返回 {title, body(含标记)}
    const modelCfg = fakeModelCfgReturning({
      articles: [{ title: "午后的三张照片", body: "随手拍。\n\n[[photo:photos/2026-07-01-101010/0-a1b.jpg]]" }],
    });
    const r = await mineOneAudio(audioKey, Object.keys(env._store), {}, env, modelCfg);
    expect(r).toBe("mined");
    const doc = JSON.parse(env._store.get(`${scope}articles/VoiceDrop-2026-07-01-101010-1s-周三-上午.json`));
    expect(doc.articles[0].body).toContain("[[photo:");
    expect(env._store.has(`${scope}articles/VoiceDrop-2026-07-01-101010-1s-周三-上午.empty`)).toBe(false);
  });

  it("ASR 空且无照片仍写 .empty no-speech", async () => {
    const scope = "users/anon-abc/";
    const audioKey = `${scope}VoiceDrop-2026-07-01-101010-1s-周三-上午.m4a`;
    const env = makeEnv({ objects: { [audioKey]: "audiobytes" } });
    const modelCfg = fakeModelCfgReturning({ articles: [] });
    const r = await mineOneAudio(audioKey, Object.keys(env._store), {}, env, modelCfg);
    expect(r).toBe("empty");
    expect(env._store.has(`${scope}articles/VoiceDrop-2026-07-01-101010-1s-周三-上午.empty`)).toBe(true);
  });
});
```
> 注：`fakeModelCfgReturning` / ASR 桩按 Step 1 摸到的 `mineVariant`/ASR 实现方式补最小实现（参照 `test/asr-resumable.test.js` 既有 mock 风格）。若 `mineOneAudio` 直接读全局 ASR，改为在 env 注入可控 ASR 结果。

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/mine-image.test.js`
Expected: FAIL（当前无语音直接 `.empty`，第一例拿不到文章）。

- [ ] **Step 4: 加 `IMAGE_ONLY_SYSTEM` 提示词**

`src/prompts/mine.js` 末尾：
```js
// 分享/录音只有照片、没有语音时用的短提示词：不硬写长文，起简短标题 + 一段简短的看图描述。
export const IMAGE_ONLY_SYSTEM = `你在帮用户把「几张照片」整理成一条极简的图文记录，没有任何语音或文字说明。
要求：
1. 只输出 JSON：{"articles":[{"title":"…","body":"…"}]}，不要额外文字。
2. 标题简短（≤14 字），像随手记，不夸张。
3. 正文只写 2–4 句：平实描述这些照片里能看到的场景/物件/氛围，用用户的文风；不要编造照片里没有的事实、时间、地点。
4. 在描述到某张照片处，另起一行插入它的标记 [[photo:<key>]]（key 用下方给出的原样值）；每张照片至少出现一次。
5. 宁可留白，不要空洞套话。`;
```

- [ ] **Step 5: 改 `mineOneAudio` 无语音分支**

在 ASR 判空处（Step 1 定位），改为先收照片再决定：
```js
// ASR 无语音：若这条录音带了照片，就看图写一条极简图文；否则才 no-speech。
if (!transcriptText) {
  const photos = await gatherPhotos(audioKey, env);         // 复用现有照片收集（按 photos/<ts>/）
  if (photos.length) {
    await notifyStatus(scope, stem, "mining", env);
    const styleText = (await readStyleText(env, scope + "CLAUDE.json", scope + "CLAUDE.md")).trim();
    const articles = await mineVariant(env, {
      transcript: "", styleText, photos, cacheMode: "system", modelCfg, scope, stem,
      turnId: `${Date.now()}-${stem.slice(-8)}`,
      systemOverride: IMAGE_ONLY_SYSTEM,                     // 见 Step 6
      metaExtra: { source: "image" }, log,
    });
    if (articles.length) {
      const doc = { schema: 2, id: stem, sourceAudio: `${stem}.m4a`, createdAt: uploaded[audioKey] || new Date().toISOString(), transcript: "", srt: "", articles, status: "ready", model: modelCfg.model };
      await writeArticle(audioKey, doc, env);
      await notifyStatus(scope, stem, "ready", env);
      try { await maybeAutoShareCommunity(audioKey, env, log); } catch (e) { log("自动分享失败", { error: String(e) }); }
      return (result = "mined");
    }
  }
  await writeEmpty(audioKey, "no-speech", env);
  await notifyStatus(scope, stem, "empty", env);
  return (result = "empty");
}
```
> `gatherPhotos`/`readStyleText`/`maybeAutoShareCommunity`/`mineVariant` 的真实名以 Step 1 为准；`IMAGE_ONLY_SYSTEM` 从 `./prompts/mine.js` import。

- [ ] **Step 6: `mineVariant` 支持 `systemOverride`**

在 `mineVariant` 里，若传了 `systemOverride` 则用它替换默认 MINE_SYSTEM（其余 transcript/photos/style 拼装不变）：
```js
const system = opts.systemOverride || MINE_SYSTEM;   // 默认不变，向后兼容
```

- [ ] **Step 7: 跑测试确认通过 + 全量回归**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/mine-image.test.js && npm test`
Expected: 新测试 PASS；`npm test` 全绿。

- [ ] **Step 8: Commit**

```bash
cd ~/code/jianshuo.dev && git add agent/src/miner.js agent/src/prompts/mine.js agent/test/mine-image.test.js
git commit -m "feat(miner): 无语音+有照片→vision 看图写短文（IMAGE_ONLY_SYSTEM）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: 风格语料 API（Pages `functions/files/api/[[path]].js`）

**Files:**
- Modify: `~/code/jianshuo.dev/functions/files/api/[[path]].js`（`action === 'style'` 段内加子路由）
- Test: `~/code/jianshuo.dev/agent/test/style-corpus.test.js`（新建，直接测纯逻辑或经 onRequest）

**Interfaces:**
- Produces:
  - `POST /files/api/style/collect` body `{type, title, text, source}` → `{ok, id}`，写 `<scope>style/<id>.json` = `{id, type, title, chars, source, text, collectedAt}`。
  - `GET /files/api/style/dataset` → `{items:[{id,type,title,chars,source,collectedAt}], count, totalChars}`（倒序，不回传 `text`）。
  - `DELETE /files/api/style/dataset` → `{ok, deleted}`（删全部 `<scope>style/*.json`）。

- [ ] **Step 1: 摸现有 style 路由与 scope 解析**

Run: `cd ~/code/jianshuo.dev && grep -n "action === 'style'\|resolveScope\|scope\|style/history\|style/head\|const rest\|segments" "functions/files/api/[[path]].js" | sed -n '1,40p'`
目的：拿到 scope 变量名、子路径解析方式（如 `parts`/`rest`）、`json()` 响应助手名。

- [ ] **Step 2: 写失败测试**

`test/style-corpus.test.js`（若仓库已有 `articles-api.test.js` 经 `onRequest` 测的范式，照抄其 env/token 搭法）：
```js
import { describe, it, expect } from "vitest";
import { onRequest } from "../../functions/files/api/[[path]].js";
import { makeEnv, anonReq } from "./helpers/pages-env.js"; // 若无则参照 articles-api.test.js 内联

describe("style corpus API", () => {
  it("collect 写样本，dataset 列出元数据（不含 text），DELETE 清空", async () => {
    const env = makeEnv();
    const c = await onRequest(anonReq("POST", "/files/api/style/collect", { type: "web", title: "远程团队一致性", text: "正文……", source: "sspai.com" }, env));
    const { id } = await c.json(); expect(id).toBeTruthy();

    const d = await onRequest(anonReq("GET", "/files/api/style/dataset", null, env));
    const ds = await d.json();
    expect(ds.count).toBe(1);
    expect(ds.items[0]).toMatchObject({ type: "web", title: "远程团队一致性", source: "sspai.com" });
    expect(ds.items[0].chars).toBeGreaterThan(0);
    expect(ds.items[0].text).toBeUndefined();

    const del = await onRequest(anonReq("DELETE", "/files/api/style/dataset", null, env));
    expect((await del.json()).ok).toBe(true);
    expect((await (await onRequest(anonReq("GET", "/files/api/style/dataset", null, env))).json()).count).toBe(0);
  });
});
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/style-corpus.test.js`
Expected: FAIL（路由不存在 → 404/未定义）。

- [ ] **Step 4: 实现三个子路由**

在 `action === 'style'` 段内，`style/history`、`style/head` 判定旁边加（用 Step 1 的 scope/parts 变量名）：
```js
// ── 风格数据集（语料）collect / dataset ──
if (parts[1] === 'collect' && request.method === 'POST') {
  const b = await request.json().catch(() => ({}));
  const text = (b.text || '').trim();
  if (!text) return json({ error: 'empty-text' }, 400);
  const id = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const sample = { id, type: b.type || 'text', title: (b.title || '').slice(0, 200), chars: [...text].length, source: b.source || '', text, collectedAt: new Date().toISOString() };
  await env.FILES.put(`${scope}style/${id}.json`, JSON.stringify(sample), { httpMetadata: { contentType: 'application/json' } });
  return json({ ok: true, id });
}
if (parts[1] === 'dataset') {
  if (request.method === 'GET') {
    const items = [];
    let cursor;
    do {
      const listed = await env.FILES.list({ prefix: `${scope}style/`, cursor });
      for (const o of listed.objects) {
        const obj = await env.FILES.get(o.key); if (!obj) continue;
        const s = await obj.json().catch(() => null); if (!s) continue;
        items.push({ id: s.id, type: s.type, title: s.title, chars: s.chars || 0, source: s.source || '', collectedAt: s.collectedAt });
      }
      cursor = listed.truncated ? listed.cursor : null;
    } while (cursor);
    items.sort((a, b) => (a.collectedAt < b.collectedAt ? 1 : -1));
    return json({ items, count: items.length, totalChars: items.reduce((n, i) => n + (i.chars || 0), 0) });
  }
  if (request.method === 'DELETE') {
    let cursor, deleted = 0;
    do {
      const listed = await env.FILES.list({ prefix: `${scope}style/`, cursor });
      for (const o of listed.objects) { await env.FILES.delete(o.key); deleted++; }
      cursor = listed.truncated ? listed.cursor : null;
    } while (cursor);
    return json({ ok: true, deleted });
  }
}
```
> `parts`/`scope`/`json` 用 Step 1 的真实名。`collectStyle` 旧样本形状兼容：老样本可能无 `id`/`chars`，dataset 读取时 `s.id || o.key.split('/').pop().replace(/\.json$/,'')`、`chars` 缺则 `[...(s.text||'')].length`。

- [ ] **Step 5: 跑测试确认通过 + 回归**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/style-corpus.test.js && npm test`
Expected: PASS + 全绿。

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev && git add "functions/files/api/[[path]].js" agent/test/style-corpus.test.js
git commit -m "feat(files-api): 风格语料 collect/dataset/DELETE 接口

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: 提取文章风格（agent worker `POST /agent/style/extract`）

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/index.js`（加路由 + `handleStyleExtract`）
- Create: `~/code/jianshuo.dev/agent/src/style-extract.js`（纯蒸馏逻辑）
- Test: `~/code/jianshuo.dev/agent/test/style-extract.test.js`

**Interfaces:**
- Consumes: `resolveScope(bearer, env)`（现有 token→scope）、`writeStyleDoc(env, styleKey, style, source)`、`ensureAccount`/`debit`（计费）、`callClaude`（现有 Claude 调用封装，名以 index.js 为准）。
- Produces: `POST /agent/style/extract` body `{clearAfter}` → `{ok, version, styleSummary}`；空语料 → 400 `{error:"empty-dataset"}`；401 无 token。

- [ ] **Step 1: 摸 worker 里 Claude 调用 + scope 解析 + style key**

Run: `cd ~/code/jianshuo.dev/agent && grep -n "resolveScope\|callClaude\|anthropic\|writeStyleDoc\|CLAUDE.json\|styleKey\|handleUsageRoute" src/index.js | head -30`

- [ ] **Step 2: 写失败测试**

`test/style-extract.test.js`：
```js
import { describe, it, expect } from "vitest";
import { distillStyle } from "../src/style-extract.js";

describe("distillStyle", () => {
  it("把语料样本拼进提示词并从 Claude 返回里取风格文本", async () => {
    const samples = [{ title: "A", text: "我写东西偏口语。" }, { title: "B", text: "喜欢短句。" }];
    const fakeClaude = async ({ system, messages }) => {
      expect(system).toMatch(/风格/);
      expect(messages[0].content).toContain("我写东西偏口语");
      return "偏口语、短句、少形容词。";
    };
    const style = await distillStyle(samples, fakeClaude);
    expect(style).toContain("短句");
  });

  it("空语料抛错", async () => {
    await expect(distillStyle([], async () => "")).rejects.toThrow(/empty/);
  });
});
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/style-extract.test.js`
Expected: FAIL（模块不存在）。

- [ ] **Step 4: 实现 `style-extract.js`**

```js
// 把风格数据集（外部素材样本）蒸馏成一段「写作风格」描述。纯逻辑：Claude 调用注入，便于测试。
export const DISTILL_SYSTEM = `你是文风分析师。下面是用户收集的若干篇「他欣赏/想学」的文章样本。
请提炼出一套可复用的中文写作风格描述（第二人称「你」写给写作助手看）：语气、句式长短、用词偏好、段落节奏、标点习惯、爱用/避免的表达。
只输出风格描述本身，150–400 字，不要复述样本内容、不要分点编号堆砌。`;

export async function distillStyle(samples, claude) {
  if (!samples.length) throw new Error("empty-dataset");
  const corpus = samples.map((s, i) => `【样本${i + 1}${s.title ? "·" + s.title : ""}】\n${(s.text || "").slice(0, 4000)}`).join("\n\n");
  const style = await claude({ system: DISTILL_SYSTEM, messages: [{ role: "user", content: corpus }] });
  return (style || "").trim();
}
```

- [ ] **Step 5: 接线路由 `handleStyleExtract`（index.js）**

在 `/agent/restyle` 判定旁加：
```js
if (url.pathname === "/agent/style/extract" && request.method === "POST") {
  const scope = await resolveScope(request.headers.get("Authorization"), env);
  if (!scope) return json({ error: "unauthorized" }, 401);
  const body = await request.json().catch(() => ({}));
  // 读语料
  const samples = [];
  let cursor;
  do {
    const listed = await env.FILES.list({ prefix: `${scope}style/`, cursor });
    for (const o of listed.objects) { const obj = await env.FILES.get(o.key); const s = obj && await obj.json().catch(() => null); if (s && (s.text || "").trim()) samples.push(s); }
    cursor = listed.truncated ? listed.cursor : null;
  } while (cursor);
  if (!samples.length) return json({ error: "empty-dataset" }, 400);
  const claude = makeClaudeCaller(env);          // 复用 index.js 现有封装
  const style = await distillStyle(samples, claude);
  const { head } = await writeStyleDoc(env, `${scope}CLAUDE.json`, style, "share-extract");
  if (body.clearAfter) { let c; do { const l = await env.FILES.list({ prefix: `${scope}style/`, cursor: c }); for (const o of l.objects) await env.FILES.delete(o.key); c = l.truncated ? l.cursor : null; } while (c); }
  try { if (env.USAGE) { await ensureAccount(env.USAGE, scopeSub(scope), Date.now()); await debit(env.USAGE, scopeSub(scope), estimateUY(style), "style-extract", { samples: samples.length }, Date.now()); } } catch {}
  return json({ ok: true, version: head, styleSummary: style.slice(0, 80) });
}
```
> `makeClaudeCaller`/`resolveScope`/`json`/`scopeSub`/`estimateUY` 用 index.js/usage.js 真实名（Step 1）。`writeStyleDoc` 已 import。计费 best-effort、失败不阻断。

- [ ] **Step 6: 跑测试 + 回归**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/style-extract.test.js && npm test`
Expected: PASS + 全绿。

- [ ] **Step 7: Commit**

```bash
cd ~/code/jianshuo.dev && git add agent/src/index.js agent/src/style-extract.js agent/test/style-extract.test.js
git commit -m "feat(agent): POST /agent/style/extract 蒸馏风格数据集为写作风格新版本

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: 部署服务端 + 冒烟

- [ ] **Step 1: 全量测试**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: 全绿。

- [ ] **Step 2: 部署 Worker**

Run: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`

- [ ] **Step 3: 部署 Pages（干净 worktree，见 STATE.md 部署坑）**

```bash
cd ~/code/jianshuo.dev && git worktree add --detach /tmp/vd-pages main && cd /tmp/vd-pages && npx wrangler pages deploy . --project-name jianshuo-dev; cd ~/code/jianshuo.dev && git worktree remove /tmp/vd-pages
```

- [ ] **Step 4: 冒烟三接口**（用真实 anon token 替换 `$T`）

```bash
T=<anon_token>
curl -s -XPOST https://jianshuo.dev/files/api/style/collect -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d '{"type":"text","title":"冒烟","text":"这是一段冒烟测试文本，用来验证语料收集接口。","source":"smoke"}'
curl -s https://jianshuo.dev/files/api/style/dataset -H "Authorization: Bearer $T"
curl -s -XPOST https://jianshuo.dev/agent/style/extract -H "Authorization: Bearer $T" -H "Content-Type: application/json" -d '{"clearAfter":false}'
```
Expected: collect 返回 `{ok,id}`；dataset 含该项；extract 返回 `{ok,version,styleSummary}`。

---

# Phase 2 — iOS Share Extension（自定义 UI，实现 + xcodegen build + 手测）

> 无 iOS 单测框架（仓库单测在 agent/）。每个 iOS 任务的验收 = **`xcodebuild` 编过** + 该任务的手测清单项。所有视觉值按 `design_handoff_share_collect/Share Collect.dc.html` 逐一复刻。

### Task 5: `ShareExtraction.swift` — 客户端提取（纯 helper）

**Files:**
- Create: `~/code/voicedrop/VoiceDropShare/ShareExtraction.swift`

**Interfaces:**
- Produces:
  - `enum ShareKind { case audio, image, web, document, text }`
  - `struct Extracted { let title: String; let text: String; let kind: ShareKind; let source: String }`
  - `func extractPDF(_ url: URL) -> String?`
  - `func extractRichDocument(_ url: URL) -> String?`
  - `enum Readability { static func fetch(_ url: URL) async -> (title: String?, text: String)? }`
  - `func firstLineTitle(_ text: String, fallback: String) -> String`

- [ ] **Step 1: 写 PDF/docx/title helper**

```swift
import Foundation
import PDFKit
import UIKit

func extractPDF(_ url: URL) -> String? {
    guard let doc = PDFDocument(url: url), let s = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}

func extractRichDocument(_ url: URL) -> String? {
    guard let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
    let s = a.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

func firstLineTitle(_ text: String, fallback: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    let t = line.isEmpty ? fallback : line
    return String(t.prefix(40))
}
```

- [ ] **Step 2: 写 Readability（微信特判 + 通用剥标签）**

```swift
enum Readability {
    static func fetch(_ url: URL) async -> (title: String?, text: String)? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let title = firstMatch(html, #"<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)"#)
            ?? firstMatch(html, #"<title[^>]*>([^<]+)</title>"#)
        var body = html
        if url.host?.contains("mp.weixin.qq.com") == true, let m = firstMatch(html, #"(?s)<div[^>]+id=[\"']js_content[\"'][^>]*>(.*?)</div>"#) { body = m }
        else if let m = firstMatch(html, #"(?s)<article[^>]*>(.*?)</article>"#) { body = m }
        else if let m = firstMatch(html, #"(?s)<body[^>]*>(.*?)</body>"#) { body = m }
        let text = stripTags(body)
        return text.count < 40 ? (title, title ?? "") : (title, text)
    }
    private static func firstMatch(_ s: String, _ pat: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func stripTags(_ h: String) -> String {
        var s = h
        for p in [#"(?s)<script.*?</script>"#, #"(?s)<style.*?</style>"#] { s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        for (e, c) in ["&nbsp;":" ", "&amp;":"&", "&lt;":"<", "&gt;":">", "&quot;":"\"", "&#39;":"'"] { s = s.replacingOccurrences(of: e, with: c) }
        return s.replacingOccurrences(of: #"\n[ \t]*\n(\s*\n)+"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 3: build**

Run: `cd ~/code/voicedrop && xcodegen && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp VoiceDropShare project.yml VoiceDrop.xcodeproj 2>/dev/null; git add VoiceDropShare/ShareExtraction.swift
git commit -m "feat(share-ext): 客户端提取 helper（PDF/docx/readability/title）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `ShareAPI.swift` — 上传/接口客户端 + 静音音频资源

**Files:**
- Create: `~/code/voicedrop/VoiceDropShare/ShareAPI.swift`
- Create: `~/code/voicedrop/VoiceDropShare/silent.m4a`（bundle 资源；用 `ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -b:a 32k silent.m4a` 生成）
- Modify: `~/code/voicedrop/project.yml`（若需把 `silent.m4a` 列进 `VoiceDropShare` 资源 —— 目录已整包含，确认即可）

**Interfaces:**
- Consumes: `AppGroup.sharedBearer`、`AppGroup.uploadBase`（现有 `VoiceDropApp/Networking.swift`，已 verbatim 共享进扩展 target）、`API.filesBase`/agent base。
- Produces:
  - `func putFile(_ url: URL, name: String, contentType: String) async -> Bool`
  - `func putData(_ data: Data, name: String, contentType: String) async -> Bool`
  - `func collectStyle(type: String, title: String, text: String, source: String) async -> Bool`
  - `func fetchDataset() async -> [DatasetItem]`（`struct DatasetItem: Decodable { let id,type,title,source,collectedAt: String; let chars: Int }`）
  - `func extractStyle(clearAfter: Bool) async -> Bool`
  - `func deleteDataset() async -> Bool`
  - `func triggerMine() async`

- [ ] **Step 1: 生成静音资源并确认 base URL**

Run: `cd ~/code/voicedrop && (command -v ffmpeg && ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -b:a 32k VoiceDropShare/silent.m4a) ; grep -n "filesBase\|agentBase\|/agent\|uploadBase\|static let" VoiceDropApp/Networking.swift | head`
> 若无 ffmpeg：用主 app 录 1s 静音导出，或 `AVAudioRecorder` 运行时生成（见 Task 8 备选）。确认 agent base（`https://jianshuo.dev/agent` 或 workers.dev）。

- [ ] **Step 2: 写 `ShareAPI.swift`**（用 Step 1 的 base；请求都带 `setBearer(AppGroup.sharedBearer)`）

```swift
import Foundation

struct DatasetItem: Decodable, Identifiable { let id: String; let type: String; let title: String; let source: String; let collectedAt: String; let chars: Int }

enum ShareAPI {
    private static var filesBase: URL { API.filesBase }              // …/files/api
    private static var agentBase: URL { URL(string: "https://jianshuo.dev/agent")! }
    private static func authed(_ url: URL, _ method: String) -> URLRequest { var r = URLRequest(url: url); r.httpMethod = method; r.setBearer(AppGroup.sharedBearer); return r }

    static func putFile(_ file: URL, name: String, contentType: String) async -> Bool {
        var r = authed(AppGroup.uploadBase.appendingPathComponent(name), "PUT"); r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return ((try? await URLSession.shared.upload(for: r, fromFile: file))?.1 as? HTTPURLResponse)?.statusCode.isOK2 ?? false
    }
    static func putData(_ data: Data, name: String, contentType: String) async -> Bool {
        var r = authed(AppGroup.uploadBase.appendingPathComponent(name), "PUT"); r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return ((try? await URLSession.shared.upload(for: r, from: data))?.1 as? HTTPURLResponse)?.statusCode.isOK2 ?? false
    }
    static func collectStyle(type: String, title: String, text: String, source: String) async -> Bool {
        var r = authed(filesBase.appendingPathComponent("style/collect"), "POST"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["type": type, "title": title, "text": text, "source": source])
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode.isOK2 ?? false
    }
    static func fetchDataset() async -> [DatasetItem] {
        guard let (d, _) = try? await URLSession.shared.data(for: authed(filesBase.appendingPathComponent("style/dataset"), "GET")) else { return [] }
        struct R: Decodable { let items: [DatasetItem] }
        return (try? JSONDecoder().decode(R.self, from: d))?.items ?? []
    }
    static func extractStyle(clearAfter: Bool) async -> Bool {
        var r = authed(agentBase.appendingPathComponent("style/extract"), "POST"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["clearAfter": clearAfter])
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode.isOK2 ?? false
    }
    static func deleteDataset() async -> Bool {
        return ((try? await URLSession.shared.data(for: authed(filesBase.appendingPathComponent("style/dataset"), "DELETE")))?.1 as? HTTPURLResponse)?.statusCode.isOK2 ?? false
    }
    static func triggerMine() async { _ = try? await URLSession.shared.data(for: authed(agentBase.appendingPathComponent("mine/trigger"), "POST")) }
}
private extension Int { var isOK2: Bool { (200..<300).contains(self) } }
```
> 若 `Networking.swift` 已有 `isOK`/`setBearer`/`API.filesBase`，复用它们、删掉此处重复定义。

- [ ] **Step 3: build**

Run: `cd ~/code/voicedrop && xcodegen && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropShare/ShareAPI.swift VoiceDropShare/silent.m4a project.yml VoiceDrop.xcodeproj
git commit -m "feat(share-ext): ShareAPI 客户端（上传/语料/提取/mine）+ 静音占位资源

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `ShareRootView` + `ShareRouter` — 自定义入口替换 SLCompose

**Files:**
- Rewrite: `~/code/voicedrop/VoiceDropShare/ShareViewController.swift`（改为 `UIHostingController` 承载 SwiftUI；删除 `SLComposeServiceViewController` 子类 + `IntentPicker`）
- Create: `~/code/voicedrop/VoiceDropShare/ShareRouter.swift`（类型分派 + 加载附件）
- Create: `~/code/voicedrop/VoiceDropShare/ShareRootView.swift`（按 kind 切三种子视图；提供 `close()` = `extensionContext.completeRequest`）
- Modify: `~/code/voicedrop/VoiceDropShare/Info.plist`（`NSExtensionPrincipalClass` 保持 `ShareViewController`；`NSExtensionMainStoryboard` 不用；activation rule 不变）

**Interfaces:**
- Produces:
  - `ShareRouter.classify(_ items: [NSExtensionItem]) -> ShareKind`
  - `ShareRouter.loadPayload(...) async -> SharePayload`（`struct SharePayload { var audio: URL?; var images: [URL]; var webURL: URL?; var docs: [URL]; var text: String?; var note: String }`）
  - `ShareRootView(payload:, close:)`

- [ ] **Step 1: 重写 `ShareViewController` 为 UIHostingController**

```swift
import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let kind = ShareRouter.classify(items)
        let ctx = extensionContext
        let root = ShareRootView(items: items, kind: kind, close: { ctx?.completeRequest(returningItems: [], completionHandler: nil) })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host); host.view.frame = view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view); host.didMove(toParent: self)
    }
}
```

- [ ] **Step 2: `ShareRouter.classify` + `loadPayload`**（用 Task 5 的 `ShareKind`；UTType 判定同旧 `ShareViewController` 的 `hasItemConformingToTypeIdentifier`）

```swift
import UniformTypeIdentifiers
import Foundation

enum ShareRouter {
    static func classify(_ items: [NSExtensionItem]) -> ShareKind {
        let ps = items.flatMap { $0.attachments ?? [] }
        func any(_ id: String) -> Bool { ps.contains { $0.hasItemConformingToTypeIdentifier(id) } }
        if any(UTType.audio.identifier) { return .audio }
        if any(UTType.image.identifier) { return .image }
        if any(UTType.url.identifier) && !any(UTType.fileURL.identifier) { return .web }
        if any(UTType.pdf.identifier) || any("org.openxmlformats.wordprocessingml.document") || any("com.microsoft.word.doc") || any(UTType.rtf.identifier) { return .document }
        return .text
    }
    // loadPayload: 遍历附件，按 kind 用 loadFileRepresentation / loadItem 取 URL/text（照抄旧 ShareViewController 的 loadFile/loadURL/loadText），落到 SharePayload。
}
```
> `loadPayload` 复用旧 `ShareViewController.swift`（本任务改写前）里的 `loadFile`/`loadURL`/`loadText` 实现，原样搬进 `ShareRouter`。

- [ ] **Step 3: `ShareRootView` 骨架（切子视图）**

```swift
import SwiftUI

struct ShareRootView: View {
    let items: [NSExtensionItem]
    let kind: ShareKind
    let close: () -> Void
    @State private var payload: SharePayload?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture(perform: close)
            Group {
                if AppGroup.sharedBearer.isEmpty { NotLoggedInSheet(close: close) }
                else if let p = payload {
                    switch kind {
                    case .audio:            AudioComposeView(payload: p, close: close)
                    case .image:            PhotoComposeView(payload: p, close: close)
                    default:                StyleDatasetView(payload: p, close: close)   // web/document/text
                    }
                } else { LoadingSheet() }
            }
        }
        .task { payload = await ShareRouter.loadPayload(items) }
    }
}
```
> `NotLoggedInSheet`/`LoadingSheet` = 简单占位（sheet 底 `#FAF6EF`、一行说明 + 关闭）。

- [ ] **Step 4: build**

Run: `cd ~/code/voicedrop && xcodegen && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropShare project.yml VoiceDrop.xcodeproj
git commit -m "feat(share-ext): 自定义 UIHostingController 入口 + 类型分派（替换 SLCompose）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: `StyleDatasetView` — 风格数据集 sheet

**Files:**
- Create: `~/code/voicedrop/VoiceDropShare/StyleDatasetView.swift`

**复刻要点（`Share Collect.dc.html` 左 sheet，逐值对齐）：** sheet 底 `#FAF6EF` 圆角 `18` 顶；顶部 grabber `#DDD3C2`；标题「风格数据集」19pt 600 `#2A2521`，副「已收集 N 项 · 约 X 字」13pt `#8A8175`，右「关闭」16pt 600 `#8A8175`（点 → `close`）。列表项：38×38 圆角 9 图标底按类型（文档 `#EDE6D8`/`#7A6E5C`、网页 `#E4EBE6`/`#5E8A6A`、文字 `#EDE6D8`/`#7A6E5C`）+ 标题 15pt `#2A2521` 单行省略 + 副标题 12pt `#a79f93`「类型 · 字数/域名 · 日期」，行间 `#EFE7D9` 分隔。「本次新增」11pt 700 `#C0682E` + 渐变线；新项底 `#FBF1E9` 描边 `#E8C9B8` 圆角 11 + 赭红勾。URL 项三态：解析中（转圈 `#C98A2E`）/失败（`#B0A798` + 「重试」按钮 `#C0682E`）。底部：复选「提取后清空数据集」默认勾（勾底 `#D8593B`）；「继续收集」白底 `#E2D8C8` 描边；「提取文章风格」主按钮 50h `#D8593B` 阴影 `rgba(216,89,59,0.28)` + 下载图标。

**Interfaces:**
- Consumes: `ShareAPI.fetchDataset/collectStyle/extractStyle/deleteDataset`、`Readability.fetch`、`extractPDF/extractRichDocument/firstLineTitle`、`SharePayload`。

- [ ] **Step 1: 视图 + 状态机**

关键行为（写全）：
```swift
@State private var existing: [DatasetItem] = []      // GET dataset
@State private var newItems: [NewItem] = []          // 本次新增，含 .parsing/.done/.failed 态
@State private var clearAfter = true
@State private var extracting = false

// onAppear: existing = await ShareAPI.fetchDataset()；同时把 payload 转成 newItems 并逐个 collect：
//  - text/document: 本地已提取好 → collectStyle(type,title,text,source) → .done
//  - web: 先插 .parsing 行 → Readability.fetch → 成功 collectStyle + .done(回填标题) / 失败 .failed(可重试)
// 「提取文章风格」: extracting=true → ShareAPI.extractStyle(clearAfter) → 成功 close()
// 「继续收集」: close()（数据集留存，新项已 collect）
```
> `NewItem` 结构：`{ id, type, title, source, state: parsing|done|failed, retryURL: URL? }`。document 分支在 sheet 内决定 `extractPDF`/`extractRichDocument`（payload.docs 里带原始文件 URL）。

- [ ] **Step 2: build**（同上 xcodebuild 命令）→ BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropShare/StyleDatasetView.swift project.yml VoiceDrop.xcodeproj
git commit -m "feat(share-ext): 风格数据集 sheet（列表/本次新增/URL 三态/提取风格/清空）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: `AudioComposeView` — 成文 sheet · 音频版

**Files:**
- Create: `~/code/voicedrop/VoiceDropShare/AudioComposeView.swift`

**复刻要点（`Share Collect.dc.html` 右 sheet）：** 标题「从这段录音成文」+「来自 <源> · 已就绪」+ 关闭。音频卡：48×48 圆角 12 `#E8E4EF`/`#7A6EA0` 音符图标 + 文件名 16pt 600 + 「m4a · 大小」；波形 44h 等宽条 `#E8DFCF`（真采样可选，v1 用固定高度序列占位）；播放键 38 圆 `#2A2521`（`AVAudioPlayer`）+ 进度条 + 时长 tabular。生成设置卡：写作风格（当前风格首句省略 + chevron，只读）+ 识别语言「中文（自动）」。算力预估「预计消耗约 N 算力 · 转写 + 成文一步完成」（图标 `#C98A2E`，值加粗 `#C98A2E`）。底部主按钮 52h `#D8593B`「开始生成文章」。

**Interfaces:**
- Consumes: `ShareAPI.putFile/triggerMine`、`RecordingName.make`（若可从主 app 共享；否则在扩展内复制其算法生成录音式名）、`AVAudioPlayer`。

- [ ] **Step 1: 视图 + 生成动作**

```swift
// 播放：AVAudioPlayer(contentsOf: payload.audio!)，播放键切 play/pause，progress 定时刷新。
// 算力预估：ceil(durationSec/3600 * 0.8 * 23) + 典型挖矿 2 算力（粗算，展示用）。
// 「开始生成文章」: 
//   let name = RecordingName.make(start: Date(), duration: durationSec, place: nil)  // VoiceDrop-<ts>-<dur>-…m4a
//   await ShareAPI.putFile(payload.audio!, name: name, contentType: "audio/mp4")
//   await ShareAPI.triggerMine(); close()
```
> `RecordingName.make` 在 `VoiceDropApp/RecordingName.swift`；把该文件加入 `VoiceDropShare` target 的 sources（project.yml 已含 `VoiceDropApp/Networking.swift` 单文件先例）——在 `VoiceDropShare.sources` 追加 `- path: VoiceDropApp/RecordingName.swift`。

- [ ] **Step 2: project.yml 加 RecordingName.swift 到扩展 target + xcodegen + build**

Run: `cd ~/code/voicedrop && xcodegen && xcodebuild ... build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropShare/AudioComposeView.swift project.yml VoiceDrop.xcodeproj
git commit -m "feat(share-ext): 成文 sheet 音频版（波形/播放/算力/开始生成）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: `PhotoComposeView` — 成文 sheet · 图片版

**Files:**
- Create: `~/code/voicedrop/VoiceDropShare/PhotoComposeView.swift`

**复刻要点：** 复用 `AudioComposeView` 的 sheet 外形与底部按钮；标题「看图写一篇」+「N 张图片 · 已就绪」；波形处换成**缩略图网格**（每格方形裁切，圆角 10）；生成设置只留写作风格；算力预估（vision 粗算，如「约 3 算力」）。

**Interfaces:**
- Consumes: `ShareAPI.putData/putFile/triggerMine`、`RecordingName.make`/`RecordingName.photoKey`/`RecordingName.timestamp`、`silent.m4a` bundle 资源、图片方形裁切（复用主 app `SquareImage.jpeg` 若可共享，否则扩展内内联一个 1080px 方裁函数）。

- [ ] **Step 1: 视图 + 生成动作**

```swift
// sessionTs = RecordingName.timestamp(Date())        // yyyy-MM-dd-HHmmss
// let audioName = RecordingName.make(start: date, duration: 1, place: nil)
// 「开始生成文章」:
//   let silent = Bundle.main.url(forResource:"silent", withExtension:"m4a")!
//   await ShareAPI.putFile(silent, name: audioName, contentType: "audio/mp4")
//   for (i,img) in images.enumerated() {
//     let key = "photos/\(sessionTs)/\(i)-\(RecordingName.randomTag()).jpg"    // 相对 key
//     await ShareAPI.putData(SquareImage.jpeg(img, max:1080), name: key, contentType:"image/jpeg")
//   }
//   await ShareAPI.triggerMine(); close()
```
> 上传 key 传给 `putFile`/`putData` 的 `name` 是相对 key（落到 `users/<sub>/<name>`），故图片 name 用 `photos/<sessionTs>/<i>-<rand>.jpg`、音频用 `audioName`。确认 `AppGroup.uploadBase.appendingPathComponent(name)` 对含 `/` 的 name 编码正确（必要时对每段分别拼）。

- [ ] **Step 2: xcodegen + build** → BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropShare/PhotoComposeView.swift project.yml VoiceDrop.xcodeproj
git commit -m "feat(share-ext): 成文 sheet 图片版（缩略图网格 + 占位音频 + 图片上传）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: 联调 · TestFlight · 端到端手测

- [ ] **Step 1: 清理旧 SLCompose 残留 + 全量 build**

确认已删 `IntentPicker`、旧 `SLComposeServiceViewController` 逻辑、旧 `Intent`/`filename(intent:)`。
Run: `cd ~/code/voicedrop && xcodegen && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED。

- [ ] **Step 2: 推 main → TestFlight**

```bash
cd ~/code/voicedrop && git push origin main
```
（GitHub Actions Build & Deploy → TestFlight；等 Beta 构建。）

- [ ] **Step 3: 端到端手测清单**（TestFlight 新 build）

  - 微信文章分享 → 数据集 sheet「正在解析网页…」→ 回填标题、入库；`/style/dataset` 可见。
  - 知乎/登录墙链接 → 「解析失败·仅存链接」+ 重试可用。
  - Word/PDF/纯文字分享 → 数据集 sheet 出现该项、字数正确。
  - 「提取文章风格」（勾清空）→ 设置里写作风格出新版本；数据集清空。
  - 音频（备忘录）分享 → 成文·音频 sheet：波形/播放/时长/算力 → 「开始生成文章」→ 「我的录音」出现该条并成文。
  - 单图/多图分享 → 成文·图片 sheet：缩略图 → 「开始生成文章」→ 「我的录音」出现、成文为图文、图片内联。
  - 未登录设备分享 → 显示「请先登录」占位、主操作禁用。

- [ ] **Step 4: 更新 STATE.md**

在 STATE.md 增一节「接受分享（Share Collect）」：路由表、三 sheet、语料 collect/dataset/extract 接口、`IMAGE_ONLY_SYSTEM`、占位音频约定、部署命令。Commit。

---

## Self-Review

**Spec 覆盖：**
- 路由（音频/图片→成文，文字/网页/文档→数据集）→ Task 7 分派 + Task 8/9/10 三 sheet ✓
- 客户端提取（PDF/docx/readability）→ Task 5 ✓
- 语料 collect/dataset/清空 → Task 2；提取风格 → Task 3 ✓
- vision 挖图（无语音+有照片）→ Task 1 ✓
- 占位音频复用音频锚点、iOS 主 app 零改动 → Task 10 + 组件边界 ✓
- 部署（Pages/Worker/TestFlight）→ Task 4 + Task 11 ✓
- xcodegen（新文件）→ 各 iOS 任务 build 步 ✓

**占位符扫描：** 无 TBD/TODO；iOS 视图给了逐值设计 token + 关键行为代码；「用真实名以 Step 1 为准」是有意的集成锚点，不是占位。

**类型一致性：** `ShareKind`/`SharePayload`/`DatasetItem`/`NewItem` 全任务一致；`ShareAPI` 方法名在消费任务里一致；`IMAGE_ONLY_SYSTEM`/`distillStyle`/`writeStyleDoc` 跨任务一致。

**已知实现期开放点**（spec 同款）：`mineVariant`/`gatherPhotos`/`makeClaudeCaller` 等真实名以各任务 Step 1 的 grep 为准；`NSAttributedString` docx、`AVAudioPlayer`、波形绘制在扩展进程的实测；含 `/` 的上传 key 编码；静音 `.m4a` 生成法。

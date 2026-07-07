# 提示词中心化注册表 + 分层可配置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把散落的提示词收进 `agent/src/prompts/` 一个中心目录，并把 ui-config 的「默认 ← 全局 R2 覆盖」机制扩到核心成文/图片提示词，让管理端经 `/agent/prompt-registry` 零部署改这些提示词；APP 零改动。

**Architecture:** 新增 `prompts/catalog.js`（默认值 + 元数据）与 `prompts/loader.js`（`loadPrompts(env)` 读 R2 `config/prompts.json` 叠加 global 档、locked 档永不覆盖 + 写入校验）。`miner.js`/`image-mine.js` 在已有 env 的调用点改成从 `loadPrompts` 取生效提示词，喂给现成的纯函数 `buildMinePrompt`/`buildStagePayload`。`prompt-registry.js` 的 GET/PUT 扩成同时覆盖 ui-config 菜单叶子 + 这些核心提示词。

**Tech Stack:** Cloudflare Worker (ESM JS)、vitest、R2（`env.FILES`，测试用 `test/fakes.js` 的 `fakeEnv`）。

## Global Constraints

- **搬迁保字节一致**：把内联提示词搬进 `prompts/` 时，字面量内容一字不改；`prompts/catalog.js` 的默认值必须与 `miner.js`/`image-pipeline.js` 原用的常量**同一引用/同一字节**（eval harness 与 `build-mine-prompt.test.js` 依赖挖矿 prompt 字节稳定）。
- **命名空间隔离**：核心提示词存 R2 `config/prompts.json`，**绝不**塞进 `config/ui-config.json`（后者被 APP 下载）。本期不新增任何面向客户端的端点。
- **locked 永不配置**：moderation、`mine.imageOnly` 归 locked，只搬迁不接 R2 覆盖。
- **registry 只列已接线的**：GET `/agent/prompt-registry` 只列出真正会读取 R2 覆盖的核心提示词（`mine.system`/`mine.force`/`image.*`），避免「能编辑但不生效」的 footgun。
- **认证**：`/agent/prompt-registry` 仍只认 `Bearer FILES_TOKEN`（`env.FILES_TOKEN`）。
- **测试命令**：`cd agent && npx vitest run <file>`；全量 `npx vitest run`。代码根 `~/code/jianshuo.dev/agent/`。
- **本期范围外（Phase 2）**：`edit.*`/`command.*`/`style.distill`/工具说明的消费端接线、任何 per-user voice 端点。这些提示词本期只搬进 `prompts/`（合并），不进 catalog/registry。

---

### Task 1: 内联提示词搬进 `prompts/` 中心目录（纯搬迁，行为不变）

把 8 处内联提示词从各处理文件搬进 `prompts/` 域文件，原地改成 import。**字面量一字不改**，全量测试须保持绿。

**Files:**
- Create: `agent/src/prompts/edit.js`（`REVISE_SYSTEM`、编辑 agent `SYSTEM`，从 `index.js:79`/`:104` 搬）
- Create: `agent/src/prompts/command.js`（`COMMAND_SYSTEM`，从 `command-turn.js:7` 搬）
- Create: `agent/src/prompts/style.js`（`DISTILL_SYSTEM`，从 `style-extract.js:8` 搬）
- Create: `agent/src/prompts/moderation.js`（`MOD_CATEGORIES` + `buildModerationSystem(categories)`，从 `miner.js:641/646` 搬）
- Create: `agent/src/prompts/tool-desc.js`（`merge_articles`/`add_followups`/`edit_photo`/`new_photo` 的 description 字符串，从 `tools.js` 搬）
- Modify: `agent/src/index.js`（删本地 `REVISE_SYSTEM`/`SYSTEM` 定义，改 import）
- Modify: `agent/src/command-turn.js`、`agent/src/style-extract.js`、`agent/src/miner.js`、`agent/src/tools.js`（同上，改 import）

**Interfaces:**
- Produces: `prompts/edit.js` → `export const REVISE_SYSTEM`, `export const EDIT_SYSTEM`；`prompts/command.js` → `export const COMMAND_SYSTEM`；`prompts/style.js` → `export const DISTILL_SYSTEM`；`prompts/moderation.js` → `export const MOD_CATEGORIES`, `export function buildModerationSystem(categories = MOD_CATEGORIES)`；`prompts/tool-desc.js` → `export const MERGE_ARTICLES_DESC / ADD_FOLLOWUPS_DESC / EDIT_PHOTO_DESC / NEW_PHOTO_DESC`。

- [ ] **Step 1: 建 `prompts/edit.js`，把 `index.js` 里 `REVISE_SYSTEM` 与编辑 agent `SYSTEM` 的字面量原样剪切过来**

```js
// agent/src/prompts/edit.js — 语音改稿相关提示词（从 index.js 搬，字面量不改）
export const REVISE_SYSTEM = `…（把 index.js:79 起 REVISE_SYSTEM 的原字面量整段粘过来，一字不改）…`;
export const EDIT_SYSTEM = `…（把 index.js:104 起 SYSTEM 的原字面量整段粘过来；原文末尾内嵌 ${"${REVISE_SYSTEM}"} 保留）…`;
```

- [ ] **Step 2: `index.js` 删除本地定义，改 import**

`index.js` 顶部加：`import { REVISE_SYSTEM, EDIT_SYSTEM as SYSTEM } from "./prompts/edit.js";`，删掉原 `const REVISE_SYSTEM = …` 与 `const SYSTEM = …` 两段。其余引用 `SYSTEM`/`REVISE_SYSTEM` 的代码不动。

- [ ] **Step 3: 同法搬 `command.js` / `style.js` / `moderation.js` / `tool-desc.js`，各自源文件改 import**

`command-turn.js`：`import { COMMAND_SYSTEM } from "./prompts/command.js";`
`style-extract.js`：`import { DISTILL_SYSTEM } from "./prompts/style.js";`
`miner.js`：`import { MOD_CATEGORIES, buildModerationSystem } from "./prompts/moderation.js";`，把 `miner.js:646` 的 `const system = \`…${MOD_CATEGORIES}…\`` 改成 `const system = buildModerationSystem();`（`buildModerationSystem` 内部就是原模板串，保证字节一致）。
`tools.js`：四个工具的 description 改引 `tool-desc.js` 的导出常量。

- [ ] **Step 4: 跑全量测试，确认纯搬迁零回归**

Run: `cd agent && npx vitest run`
Expected: 全绿（尤其 `build-mine-prompt`、`moderation`、`command-turn`、`style-extract`、`tools`、`edit-turn`、`prompt-registry`）。任何 diff 说明字面量被改动，回到对应文件对齐。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/prompts/ agent/src/index.js agent/src/command-turn.js agent/src/style-extract.js agent/src/miner.js agent/src/tools.js
git commit -m "refactor(prompts): 内联提示词收进 prompts/ 中心目录（字面量不变）"
```

---

### Task 2: `prompts/catalog.js` — 核心提示词默认值 + 元数据

登记本期接线的核心提示词：默认值（复用现有导出，保证同字节）+ 元数据（档位、校验必留串）。

**Files:**
- Create: `agent/src/prompts/catalog.js`
- Test: `agent/test/prompt-catalog.test.js`

**Interfaces:**
- Consumes: `prompts/mine.js` 的 `MINE_SYSTEM`/`MINE_SYSTEM_FORCE`/`IMAGE_ONLY_SYSTEM`；`prompts/image-pipeline.js` 的 `OBSERVE_SYSTEM`/`PLAN_SYSTEM`/`WRITE_SYSTEM`/`REVIEW_SYSTEM`。
- Produces: `export const PROMPT_DEFAULTS`（`{id: string}`）、`export const PROMPT_META`（`{id: {label, tier:'global'|'locked', required: string[]}}`）。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/prompt-catalog.test.js
import { describe, it, expect } from "vitest";
import { PROMPT_DEFAULTS, PROMPT_META } from "../src/prompts/catalog.js";
import { MINE_SYSTEM } from "../src/prompts/mine.js";

describe("prompt catalog", () => {
  it("每个 id 都有非空默认串和 tier", () => {
    for (const [id, meta] of Object.entries(PROMPT_META)) {
      expect(typeof PROMPT_DEFAULTS[id]).toBe("string");
      expect(PROMPT_DEFAULTS[id].length).toBeGreaterThan(0);
      expect(["global", "locked"]).toContain(meta.tier);
    }
  });
  it("默认值与源常量同字节（不得漂移）", () => {
    expect(PROMPT_DEFAULTS["mine.system"]).toBe(MINE_SYSTEM);
  });
  it("required 里的串必须真的出现在默认值中", () => {
    for (const [id, meta] of Object.entries(PROMPT_META)) {
      for (const tok of meta.required || []) expect(PROMPT_DEFAULTS[id]).toContain(tok);
    }
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-catalog.test.js`
Expected: FAIL（`catalog.js` 不存在 / import 报错）。

- [ ] **Step 3: 写 `prompts/catalog.js`**

```js
// agent/src/prompts/catalog.js — 核心提示词的默认值 + 元数据（本期接线子集）。
// tier: 'global' = 可被 R2 config/prompts.json 覆盖；'locked' = 只搬迁、永不配置。
// required: 覆盖时必须保留的子串（契约兜底）；本期核心 prompt 的 JSON 由 output_config
// schema 在代码侧强制，故 required 多为空，校验退化成「非空」。
import { MINE_SYSTEM, MINE_SYSTEM_FORCE, IMAGE_ONLY_SYSTEM } from "./mine.js";
import { OBSERVE_SYSTEM, PLAN_SYSTEM, WRITE_SYSTEM, REVIEW_SYSTEM } from "./image-pipeline.js";

export const PROMPT_DEFAULTS = {
  "mine.system": MINE_SYSTEM,
  "mine.force": MINE_SYSTEM_FORCE,
  "mine.imageOnly": IMAGE_ONLY_SYSTEM,
  "image.observe": OBSERVE_SYSTEM,
  "image.plan": PLAN_SYSTEM,
  "image.write": WRITE_SYSTEM,
  "image.review": REVIEW_SYSTEM,
};

export const PROMPT_META = {
  "mine.system":    { label: "挖矿成文 · 主 system", tier: "global", required: [] },
  "mine.force":     { label: "挖矿成文 · 强制兜底", tier: "global", required: [] },
  "mine.imageOnly": { label: "纯图成文（回退）",     tier: "locked", required: [] },
  "image.observe":  { label: "图片流水线 · 观察",   tier: "global", required: [] },
  "image.plan":     { label: "图片流水线 · 选题",   tier: "global", required: [] },
  "image.write":    { label: "图片流水线 · 写作",   tier: "global", required: [] },
  "image.review":   { label: "图片流水线 · 终审",   tier: "global", required: [] },
};
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-catalog.test.js`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/prompts/catalog.js agent/test/prompt-catalog.test.js
git commit -m "feat(prompts): 核心提示词 catalog（默认值+元数据）"
```

---

### Task 3: `prompts/loader.js` — `loadPrompts(env)` + `validateOverride`

三层里的「默认 ← 全局 R2」这一层（本期无 per-user）。locked 档与未知 id 一律忽略，空串回落默认，缺 required 串拒绝。

**Files:**
- Create: `agent/src/prompts/loader.js`
- Test: `agent/test/prompt-loader.test.js`

**Interfaces:**
- Consumes: `catalog.js` 的 `PROMPT_DEFAULTS`/`PROMPT_META`；`test/fakes.js` 的 `fakeEnv(seed)`（R2 键 `config/prompts.json`）。
- Produces: `export async function loadPrompts(env)` → `{id: string}`（含全部 catalog id，global 档按 R2 覆盖，locked 恒为默认）；`export function validateOverride(id, instruction)` → `null`(ok) 或 错误字符串。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/prompt-loader.test.js
import { describe, it, expect } from "vitest";
import { loadPrompts, validateOverride } from "../src/prompts/loader.js";
import { PROMPT_DEFAULTS } from "../src/prompts/catalog.js";
import { fakeEnv } from "./fakes.js";

const seed = (obj) => fakeEnv({ "config/prompts.json": JSON.stringify({ prompts: obj }) });

describe("loadPrompts", () => {
  it("无 R2 文件时返回全部默认值", async () => {
    const p = await loadPrompts(fakeEnv());
    expect(p["mine.system"]).toBe(PROMPT_DEFAULTS["mine.system"]);
    expect(p["image.write"]).toBe(PROMPT_DEFAULTS["image.write"]);
  });
  it("global 档被 R2 覆盖", async () => {
    const p = await loadPrompts(seed({ "mine.system": "新的成文提示词" }));
    expect(p["mine.system"]).toBe("新的成文提示词");
  });
  it("locked 档即便 R2 有值也不被覆盖", async () => {
    const p = await loadPrompts(seed({ "mine.imageOnly": "恶意覆盖" }));
    expect(p["mine.imageOnly"]).toBe(PROMPT_DEFAULTS["mine.imageOnly"]);
  });
  it("空串 / 未知 id 忽略", async () => {
    const p = await loadPrompts(seed({ "mine.force": "   ", "bogus.id": "x" }));
    expect(p["mine.force"]).toBe(PROMPT_DEFAULTS["mine.force"]);
    expect(p["bogus.id"]).toBeUndefined();
  });
  it("坏 JSON 回落默认，不抛", async () => {
    const env = fakeEnv({ "config/prompts.json": "{ not json" });
    const p = await loadPrompts(env);
    expect(p["mine.system"]).toBe(PROMPT_DEFAULTS["mine.system"]);
  });
});

describe("validateOverride", () => {
  it("global 非空放行", () => expect(validateOverride("mine.system", "hi")).toBeNull());
  it("空串拒绝", () => expect(validateOverride("mine.system", "  ")).toBeTruthy());
  it("locked 拒绝", () => expect(validateOverride("mine.imageOnly", "x")).toBeTruthy());
  it("未知 id 拒绝", () => expect(validateOverride("nope", "x")).toBeTruthy());
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-loader.test.js`
Expected: FAIL（`loader.js` 不存在）。

- [ ] **Step 3: 写 `prompts/loader.js`**

```js
// agent/src/prompts/loader.js — 提示词解析：内置默认 ← 全局 R2 config/prompts.json（global 档）。
// 本期无 per-user 层。locked 档 / 未知 id / 空串 / 缺 required 串 一律忽略，坏文件回落默认。
import { PROMPT_DEFAULTS, PROMPT_META } from "./catalog.js";

export async function loadPrompts(env) {
  const resolved = { ...PROMPT_DEFAULTS };
  let doc = null;
  try {
    const o = await env?.FILES?.get?.("config/prompts.json");
    if (o) doc = JSON.parse(await o.text());
  } catch { doc = null; }
  const over = doc && typeof doc === "object" && doc.prompts && typeof doc.prompts === "object" ? doc.prompts : null;
  if (over) {
    for (const [id, val] of Object.entries(over)) {
      if (validateOverride(id, val) !== null) continue; // 未知/locked/空/缺串 → 跳过
      resolved[id] = val;
    }
  }
  return resolved;
}

export function validateOverride(id, instruction) {
  const meta = PROMPT_META[id];
  if (!meta || meta.tier !== "global") return "unknown or non-editable prompt id";
  if (typeof instruction !== "string" || !instruction.trim()) return "empty instruction";
  for (const tok of meta.required || []) if (!instruction.includes(tok)) return `missing required token: ${tok}`;
  return null;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-loader.test.js`
Expected: PASS（全部用例）。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/prompts/loader.js agent/test/prompt-loader.test.js
git commit -m "feat(prompts): loadPrompts 全局 R2 覆盖层 + 写入校验"
```

---

### Task 4: 接线挖矿（`miner.js`）读 `loadPrompts`

`generateArticles` 已有 `env`。在此解析一次，把 `mine.system`/`mine.force` 喂给 `buildMinePrompt`；image-only 路径的 `systemOverride`（locked 常量）仍优先。

**Files:**
- Modify: `agent/src/miner.js:601-609`（`generateArticles`）
- Test: `agent/test/mine-prompt-override.test.js`

**Interfaces:**
- Consumes: `loadPrompts(env)`（Task 3）；`buildMinePrompt`（既有，`systemPrompt`/`forcePrompt` 形参）。
- Produces: 无新导出；行为上 `mine.system`/`mine.force` 变为 R2 可覆盖。

- [ ] **Step 1: 写失败测试（在解析边界断言组合正确）**

```js
// agent/test/mine-prompt-override.test.js
import { describe, it, expect } from "vitest";
import { loadPrompts } from "../src/prompts/loader.js";
import { buildMinePrompt } from "../src/miner.js";
import { fakeEnv } from "./fakes.js";

describe("mine prompt R2 override 组合", () => {
  it("R2 覆盖 mine.system 后，buildMinePrompt 的 system 反映覆盖值", async () => {
    const env = fakeEnv({ "config/prompts.json": JSON.stringify({ prompts: { "mine.system": "OVERRIDDEN-MINE" } }) });
    const P = await loadPrompts(env);
    const payload = buildMinePrompt({ transcript: "t", styleText: "s", photos: null, force: false, systemPrompt: P["mine.system"], forcePrompt: P["mine.force"] });
    expect(payload.system[0].text).toContain("OVERRIDDEN-MINE");
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/mine-prompt-override.test.js`
Expected: 初次可能 PASS（buildMinePrompt 本就接受 systemPrompt）——本用例主要锁死"解析→组合"契约。若已 PASS，继续 Step 3 做真正接线（让生产路径也用解析值）。

- [ ] **Step 3: 在 `generateArticles` 顶部解析并接线**

`agent/src/miner.js`，`generateArticles` 函数体开头（`const payload = buildMinePrompt({...})` 之前）加：

```js
  const _P = await loadPrompts(env);
```

把 `buildMinePrompt({...})` 调用里的两处默认接上解析值（`systemOverride` 仍优先，保 image-only 行为）：

```js
  const payload = buildMinePrompt({
    transcript, styleText: claudeMd, photos, force, cacheMode,
    provider: modelCfg.provider, model: modelCfg.model,
    systemPrompt: systemOverride || _P["mine.system"],
    forcePrompt: _P["mine.force"],
    ...(photoInstr !== undefined ? { photoInstr } : {}),
  });
```

并在 `miner.js` 顶部 import：`import { loadPrompts } from "./prompts/loader.js";`

- [ ] **Step 4: 跑相关测试**

Run: `cd agent && npx vitest run test/mine-prompt-override.test.js test/build-mine-prompt.test.js test/usage_mine.test.js`
Expected: 全绿。`build-mine-prompt` 证明默认路径字节不变（无 R2 时 `_P["mine.system"] === MINE_SYSTEM`）。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/miner.js agent/test/mine-prompt-override.test.js
git commit -m "feat(prompts): 挖矿 system/force 接入 R2 零部署覆盖"
```

---

### Task 5: 接线图片流水线（`image-mine.js` / `image-pipeline.js`）

给纯函数 `buildStagePayload` 加可选 `stageSystem` 形参（默认 `STAGE_SYSTEM`，保字节一致）；在 `image-mine.js` 编排处解析一次、传下去。

**Files:**
- Modify: `agent/src/prompts/image-pipeline.js:115-121`（`buildStagePayload` 签名 + 取 system）
- Modify: `agent/src/image-mine.js:78,94`（解析并传 `stageSystem`）
- Test: `agent/test/image-stage-override.test.js`

**Interfaces:**
- Consumes: `loadPrompts(env)`；`buildStagePayload`。
- Produces: `buildStagePayload` 新增可选形参 `stageSystem`（`{observe,plan,write,review}`，缺省 = 内置 `STAGE_SYSTEM`）。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/image-stage-override.test.js
import { describe, it, expect } from "vitest";
import { buildStagePayload } from "../src/prompts/image-pipeline.js";
import { loadPrompts } from "../src/prompts/loader.js";
import { fakeEnv } from "./fakes.js";

describe("image stage system override", () => {
  it("不传 stageSystem 时与内置一致（字节不变）", () => {
    const a = buildStagePayload({ stage: "observe", model: "m" });
    expect(a.system[0].text.length).toBeGreaterThan(0);
  });
  it("传入解析后的 stageSystem 覆盖 observe", async () => {
    const env = fakeEnv({ "config/prompts.json": JSON.stringify({ prompts: { "image.observe": "OBS-OVERRIDE" } }) });
    const P = await loadPrompts(env);
    const stageSystem = { observe: P["image.observe"], plan: P["image.plan"], write: P["image.write"], review: P["image.review"] };
    const payload = buildStagePayload({ stage: "observe", model: "m", stageSystem });
    expect(payload.system[0].text).toContain("OBS-OVERRIDE");
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/image-stage-override.test.js`
Expected: FAIL（`stageSystem` 形参未被使用，覆盖用例断言不到 `OBS-OVERRIDE`）。

- [ ] **Step 3: 给 `buildStagePayload` 加 `stageSystem` 形参**

`agent/src/prompts/image-pipeline.js`：函数签名加 `stageSystem = STAGE_SYSTEM`，并把 `const sys = STAGE_SYSTEM[stage];` 改成 `const sys = (stageSystem || STAGE_SYSTEM)[stage];`：

```js
export function buildStagePayload({
  stage, provider = "anthropic", model,
  photos = [], factPack = null, observation = null, storyPlan = null,
  draftArticles = null, styleText = "", previousIssues = null,
  stageSystem = STAGE_SYSTEM,
}) {
  const sys = stageSystem[stage];
  if (!sys) throw new Error(`unknown stage: ${stage}`);
  // …其余不变
```

- [ ] **Step 4: `image-mine.js` 编排处解析并传下去**

`agent/src/image-mine.js`：顶部 import `import { loadPrompts } from "./prompts/loader.js";`。在跑 stage 的编排函数开头解析一次：

```js
  const _P = await loadPrompts(env);
  const stageSystem = { observe: _P["image.observe"], plan: _P["image.plan"], write: _P["image.write"], review: _P["image.review"] };
```

把 `:78`/`:94` 两处 `buildStagePayload({ stage, provider, model, ...extra })` 改为 `buildStagePayload({ stage, provider, model, stageSystem, ...extra })`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npx vitest run test/image-stage-override.test.js test/image-pipeline.test.js test/image-mine.test.js`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/prompts/image-pipeline.js agent/src/image-mine.js agent/test/image-stage-override.test.js
git commit -m "feat(prompts): 图片流水线四阶段 system 接入 R2 覆盖"
```

---

### Task 6: 扩展 `/agent/prompt-registry` 覆盖核心提示词

GET 在 ui-config 菜单叶子之外，追加核心 global 提示词；PUT 按 id 路由：核心 id → 校验后写 `config/prompts.json`；其余 → 原 ui-config 路径。

**Files:**
- Modify: `agent/src/prompt-registry.js`（GET 追加、PUT 分流、新增 `config/prompts.json` 读写）
- Test: `agent/test/prompt-registry-core.test.js`

**Interfaces:**
- Consumes: `loadPrompts(env)`、`validateOverride`（Task 3）、`PROMPT_META`（Task 2）。
- Produces: GET `/agent/prompt-registry` 返回 `{prompts:[{id,label,instruction}]}` 含 `mine.*`/`image.*`（locked 的 `mine.imageOnly` 不列）；PUT 接受核心 id。

- [ ] **Step 1: 写失败测试**

```js
// agent/test/prompt-registry-core.test.js
import { describe, it, expect } from "vitest";
import { handlePromptRegistry } from "../src/prompt-registry.js";
import { fakeEnv } from "./fakes.js";

const TOK = "test-files-token";
const req = (method, body) => new Request("https://jianshuo.dev/agent/prompt-registry", {
  method, headers: { Authorization: `Bearer ${TOK}`, "Content-Type": "application/json" },
  body: body ? JSON.stringify(body) : undefined,
});

describe("prompt-registry core prompts", () => {
  it("GET 列表含核心 global 提示词、不含 locked", async () => {
    const env = { ...fakeEnv(), FILES_TOKEN: TOK };
    const res = await handlePromptRegistry(req("GET"), env);
    const { prompts } = await res.json();
    const ids = prompts.map((p) => p.id);
    expect(ids).toContain("mine.system");
    expect(ids).toContain("image.write");
    expect(ids).not.toContain("mine.imageOnly"); // locked
  });
  it("PUT 核心 id 写入 config/prompts.json", async () => {
    const env = { ...fakeEnv(), FILES_TOKEN: TOK };
    const res = await handlePromptRegistry(req("PUT", { id: "mine.system", instruction: "NEW" }), env);
    expect(res.status).toBe(200);
    const saved = JSON.parse(await (await env.FILES.get("config/prompts.json")).text());
    expect(saved.prompts["mine.system"]).toBe("NEW");
  });
  it("PUT 空 instruction 拒绝 400", async () => {
    const env = { ...fakeEnv(), FILES_TOKEN: TOK };
    const res = await handlePromptRegistry(req("PUT", { id: "mine.system", instruction: "  " }), env);
    expect(res.status).toBe(400);
  });
  it("PUT locked id 拒绝", async () => {
    const env = { ...fakeEnv(), FILES_TOKEN: TOK };
    const res = await handlePromptRegistry(req("PUT", { id: "mine.imageOnly", instruction: "x" }), env);
    expect([400, 404]).toContain(res.status);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-registry-core.test.js`
Expected: FAIL（GET 不含核心 id；PUT 核心 id 走 ui-config `updatePrompt` 返回 404）。

- [ ] **Step 3: 扩展 `prompt-registry.js`**

顶部加：`import { loadPrompts, validateOverride } from "./prompts/loader.js";` 和 `import { PROMPT_META } from "./prompts/catalog.js";`

GET 分支改为在 ui-config 叶子后追加核心 global 提示词：

```js
  if (request.method === "GET") {
    const cfg = await loadUIConfig(env);
    const core = await loadPrompts(env);
    const corePrompts = Object.entries(PROMPT_META)
      .filter(([, m]) => m.tier === "global")
      .map(([id, m]) => ({ id, label: m.label, instruction: core[id] }));
    return new Response(JSON.stringify({ prompts: [...flattenPrompts(cfg), ...corePrompts] }), { headers });
  }
```

PUT 分支开头加核心 id 分流（在现有 ui-config `updatePrompt` 逻辑之前）：

```js
    if (PROMPT_META[body.id]) {
      const err = validateOverride(body.id, body.instruction);
      if (err) return new Response(JSON.stringify({ error: err }), { status: 400, headers });
      let doc = {};
      const cur = await env.FILES.get("config/prompts.json");
      if (cur) { try { doc = JSON.parse(await cur.text()); } catch { doc = {}; } }
      if (!doc.prompts || typeof doc.prompts !== "object") doc.prompts = {};
      doc.prompts[body.id] = body.instruction;
      await env.FILES.put("config/prompts.json", JSON.stringify(doc, null, 2));
      return new Response(JSON.stringify({ ok: true, id: body.id }), { headers });
    }
```

（原 ui-config `loadUIConfig`+`updatePrompt`+写 `config/ui-config.json` 分支保持不变，作为非核心 id 的回落。）

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-registry-core.test.js test/prompt-registry.test.js`
Expected: 全绿（新用例 + 原 ui-config 用例都过）。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev
git add agent/src/prompt-registry.js agent/test/prompt-registry-core.test.js
git commit -m "feat(prompts): prompt-registry GET/PUT 覆盖核心提示词（写 config/prompts.json）"
```

---

### Task 7: 全量回归 + 部署 + 线上验证

**Files:** 无新增。

- [ ] **Step 1: 全量测试**

Run: `cd agent && npx vitest run`
Expected: 全绿。

- [ ] **Step 2: 部署（注意 `.claude/worktrees` 会撑爆 Pages 上传，先挪开）**

```bash
cd ~/code/jianshuo.dev
mv .claude/worktrees /private/tmp/vd_worktrees_stash
CLOUDFLARE_ACCOUNT_ID=2f33014654e1b826e27ab00d4e7242fd npx wrangler deploy   # agent worker
# 若 agent 是随 pages 部署：npx wrangler pages deploy . --project-name jianshuo-dev --branch main --commit-dirty=true
mv /private/tmp/vd_worktrees_stash .claude/worktrees
```
（确认 agent worker 的真实部署命令：`agent/package.json` 的 `deploy` = `wrangler deploy`，在 `agent/` 目录跑。）

- [ ] **Step 3: 线上验证 GET 列出核心提示词**

```bash
curl -s https://jianshuo.dev/agent/prompt-registry -H "Authorization: Bearer $FILES_TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[p['id'] for p in d['prompts']]; print('mine.system' in ids, 'image.write' in ids, 'mine.imageOnly' not in ids)"
```
Expected: `True True True`。

- [ ] **Step 4: 线上验证 PUT 覆盖后 GET 回读到新值，再改回**

```bash
# 备份当前值 → PUT 一个可辨识改动 → GET 确认 → 改回原值（避免污染生产）
```
（人工执行：确认零部署覆盖闭环通了，且改回原值。）

- [ ] **Step 5: 收尾提交（若有 docs 更新）**

```bash
cd ~/code/jianshuo.dev && git add -A && git commit -m "chore(prompts): 部署核心提示词注册表" || true
```

---

## Self-Review

- **Spec coverage**：合并（Task 1）✓；catalog 中心化（Task 2）✓；三层里的默认+全局 R2（Task 3，本期无 per-user，符合 spec「voice 档 0 个」）✓；结构/语气拆分——本期核心 prompt 无 `{{VOICE}}` 槽，语气走 `<style>`，validateOverride 预留 required 机制 ✓；locked（moderation/imageOnly）只搬不配 ✓；管理端零部署 = 扩展 prompt-registry（Task 6）✓；命名空间隔离 `config/prompts.json` ✓；APP 零改动（无客户端端点变更）✓。Phase 2（edit/command/style/tool-desc 消费端接线、per-user voice 端点）已在 Global Constraints 显式标为范围外。
- **Placeholder scan**：Task 1 的搬迁步骤用「粘原字面量」描述而非重抄 200 行提示词正文——这是有意的（重抄会引入转写错误），字节一致由 Step 4 全量测试 + Task 2 的 `toBe(MINE_SYSTEM)` 守住。其余步骤均含可运行代码/命令。
- **Type consistency**：`loadPrompts(env)→{id:string}`、`validateOverride(id,instruction)→null|string`、`PROMPT_META[id].tier`、`buildStagePayload({...,stageSystem})`、`buildMinePrompt({systemPrompt,forcePrompt})` 跨任务一致。
- **风险**：Task 1 搬迁若手滑改字节，Task 2/全量测试立刻抓到。Task 4/5 默认路径字节不变由既有 `build-mine-prompt`/`image-pipeline` 测试守住。

# 长按配图/文字操作菜单 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 文章详情页长按配图/段落弹出服务端配置的分组菜单，点选后把成品指令塞进现有语音编辑通道执行（图片风格重画 / 段落改写 / 公众号题图）。

**Architecture:** 服务端唯一新增 `GET /agent/ui-config`（worker 内置缺省 + R2 `config/ui-config.json` 整体覆盖，照 community-blocklist 先例）；iOS 新增 `UIConfigStore.swift`（模型+拉取+缓存+内置兜底）+ 页面无关的 `ConfigMenuContent` 渲染器，挂在 `PhotoTile`（仅已出图）与段落行的 `.contextMenu` 上，点选经 `agent.enqueue(...)`（与插入照片/口述同一入口）。指令执行、placeholder、失败路径全部复用现有机制（`edit_photo`/`new_photo`/正文改写）。

**Tech Stack:** Cloudflare Worker (agent/, vitest) · SwiftUI iOS (xcodegen)

**Spec:** `docs/superpowers/specs/2026-07-04-longpress-actions-menu-design.md`（含定稿 JSON 契约与全部指令文案——实现时**逐字**从 spec 复制）

## Global Constraints

- 改 worker 前后都跑 `cd ~/code/jianshuo.dev/agent && npm test`（改前确认基线绿）。
- `~/code/jianshuo.dev` 工作目录可能停在别的分支——commit 前 `git branch --show-current` 检查；若非 main 用临时 worktree（STATE.md git 坑，worktree 里要真跑 `npm install`）。
- voicedrop 仓库当前分支 `design/sdui-homepage`，iOS 改动就提在这个分支；`mining/relay_server.py` 的未提交改动是别的工作，**不要碰、不要一起 commit**。
- 新增 Swift 文件后跑 `xcodegen generate`（项目由 project.yml 生成）。
- 部署顺序：worker 先（新端点先上无害），app 后。客户端有内置兜底，无硬依赖。
- schema 协商：客户端遇到 schema > 1 → 用内置兜底；未知 pages/节名/type 静默跳过。

---

### Task 1: Agent worker — `GET /agent/ui-config` + 测试

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/ui-config.js`
- Modify: `~/code/jianshuo.dev/agent/src/index.js`（route，加在 `/agent/mine/trigger` 块附近）
- Test: `~/code/jianshuo.dev/agent/test/ui-config.test.js`

**Interfaces:**
- Produces: `loadUIConfig(env) → Promise<object>`；`DEFAULT_UI_CONFIG`（导出供测试与文档对照）；HTTP `GET /agent/ui-config`（Bearer 任意有效用户 token → 200 JSON；无/无效 token → 401）。

- [ ] **Step 1: 基线**：`cd ~/code/jianshuo.dev/agent && npm test` 全绿才继续。
- [ ] **Step 2: 写失败测试** `test/ui-config.test.js`（route 测试模式参考 `paint-callback-route.test.js` 现有写法调整 import/env 构造）：

```js
import { describe, it, expect } from "vitest";
import { DEFAULT_UI_CONFIG, loadUIConfig } from "../src/ui-config.js";

const leafInstructions = (menu) => {
  const out = [];
  const walk = (n) => { if (n.instruction) out.push(n.instruction); (n.children || []).forEach(walk); };
  (menu.groups || []).flat().forEach(walk);
  return out;
};

describe("DEFAULT_UI_CONFIG shape", () => {
  const lp = DEFAULT_UI_CONFIG.pages["voice-editor"].longpress;
  it("schema 1 + voice-editor 两节", () => {
    expect(DEFAULT_UI_CONFIG.schema).toBe(1);
    expect(lp.image.groups.length).toBeGreaterThan(0);
    expect(lp.text.groups.length).toBeGreaterThan(0);
  });
  it("image 叶子全带 {{KEY}}，含 卡通(宫崎骏)/广告", () => {
    const ins = leafInstructions(lp.image);
    expect(ins.length).toBe(6);
    ins.forEach((i) => expect(i).toContain("[[photo:{{KEY}}]]"));
    expect(ins.some((i) => i.includes("宫崎骏"))).toBe(true);
    expect(ins.some((i) => i.includes("商品广告"))).toBe(true);
  });
  it("text 改写叶子带 {{LINE}}+{{QUOTE}}；题图说『放在文章最前面』+2.45:1，不带行占位", () => {
    const ins = leafInstructions(lp.text);
    const rewrites = ins.filter((i) => i.includes("{{LINE}}"));
    expect(rewrites.length).toBe(4);
    rewrites.forEach((i) => expect(i).toContain("{{QUOTE}}"));
    const cover = ins.find((i) => i.includes("公众号题图") || i.includes("题图"));
    expect(cover).toContain("放在文章最前面");
    expect(cover).toContain("2.45:1");
    expect(cover).not.toContain("{{LINE}}");
  });
});

describe("loadUIConfig R2 覆盖", () => {
  const envWith = (text) => ({ FILES: { get: async (k) => (k === "config/ui-config.json" && text != null ? { text: async () => text } : null) } });
  it("R2 缺失 → 内置", async () => {
    expect(await loadUIConfig(envWith(null))).toEqual(DEFAULT_UI_CONFIG);
  });
  it("R2 合法 → 整体覆盖", async () => {
    const override = { schema: 1, pages: { "voice-editor": { longpress: { image: { groups: [[]] } } } } };
    expect(await loadUIConfig(envWith(JSON.stringify(override)))).toEqual(override);
  });
  it("R2 损坏/非对象 → 内置", async () => {
    expect(await loadUIConfig(envWith("{oops"))).toEqual(DEFAULT_UI_CONFIG);
    expect(await loadUIConfig(envWith('"just a string"'))).toEqual(DEFAULT_UI_CONFIG);
  });
});

describe("GET /agent/ui-config route", () => {
  // import worker default + 按 paint-callback-route.test.js 的 env/ctx 构造方式
  it("无 token → 401；anon token → 200 且 content-type json、body.schema===1", async () => {
    const { default: worker } = await import("../src/index.js");
    const env = { FILES: { get: async () => null } };
    const r401 = await worker.fetch(new Request("https://jianshuo.dev/agent/ui-config"), env, {});
    expect(r401.status).toBe(401);
    const r = await worker.fetch(new Request("https://jianshuo.dev/agent/ui-config", { headers: { Authorization: "Bearer anon_testtoken123" } }), env, {});
    expect(r.status).toBe(200);
    const body = await r.json();
    expect(body.schema).toBe(1);
    expect(body.pages["voice-editor"]).toBeTruthy();
  });
});
```

- [ ] **Step 3: 跑测试确认失败**：`npx vitest run test/ui-config.test.js` → FAIL（模块不存在）。
- [ ] **Step 4: 实现** `src/ui-config.js`：`DEFAULT_UI_CONFIG` = spec「组件 §1」JSON **逐字**（六个图片风格 + 四个改写 + 插入图片/公众号题图，两个 text group）；

```js
// src/ui-config.js — 长按菜单的服务端配置（spec 2026-07-04-longpress-actions-menu-design.md）
// 真源 = 这里的字面量；R2 `config/ui-config.json` 存在且解析为带 schema+pages 的对象
// 则整体覆盖（照 community-blocklist 先例）。改 R2 = 零部署调菜单文案。
export const DEFAULT_UI_CONFIG = { /* spec JSON 逐字 */ };

export async function loadUIConfig(env) {
  try {
    const o = await env.FILES.get("config/ui-config.json");
    if (o) {
      const cfg = JSON.parse(await o.text());
      if (cfg && typeof cfg === "object" && typeof cfg.schema === "number" && cfg.pages && typeof cfg.pages === "object") return cfg;
    }
  } catch { /* fall through to built-in */ }
  return DEFAULT_UI_CONFIG;
}
```

index.js route（`/agent/mine/trigger` 块前后，import loadUIConfig）：

```js
// ── /agent/ui-config ── 长按菜单等 UI 配置（任意有效用户 token；scope 预留 per-user 合并）──
if (url.pathname === "/agent/ui-config") {
  if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
  const tok = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const scope = await resolveScope(tok, env);
  if (!scope) return new Response("unauthorized", { status: 401 });
  const cfg = await loadUIConfig(env);
  return new Response(JSON.stringify(cfg), { headers: { "content-type": "application/json" } });
}
```

- [ ] **Step 5: 跑单文件测试 → PASS，再全量 `npm test` → 全绿。**
- [ ] **Step 6: Commit**（jianshuo.dev 仓库，注意分支坑）：`feat(agent): GET /agent/ui-config 长按菜单配置端点（内置缺省 + R2 覆盖）`

### Task 2: iOS — `UIConfigStore.swift`（模型+拉取+缓存+兜底）

**Files:**
- Create: `VoiceDropApp/UIConfigStore.swift`

**Interfaces:**
- Produces: `UIMenuNode {id,label,type?,children?,instruction?}`、`UIMenuConfig {groups:[[UIMenuNode]]}`、`UIConfigStore.shared`（`@MainActor @Observable`，声明风格镜像 `ArticleAgentSession`）、`func refresh() async`、`func menu(page:String, kind:String) -> UIMenuConfig?`、`static func fill(_ instruction:String, subs:[String:String]) -> String`。

- [ ] **Step 1: 实现**（要点，完整字段见 spec §2）：
  - Codable 链：`UIConfigDoc {schema:Int, pages:[String:UIPageConfig]}`，`UIPageConfig {longpress:UILongpressConfig?}`，`UILongpressConfig {image:UIMenuConfig?, text:UIMenuConfig?}`；全部字段可缺省解码（`try?`/optional），未知 type 由渲染器跳过。
  - 内置兜底：与服务端 `DEFAULT_UI_CONFIG` **内容一致**的 JSON 字符串常量，`static let builtin: UIConfigDoc`（启动即解码，`!` 可接受——常量随包测试覆盖）。
  - 兜底链：`doc` 初值 = UserDefaults 缓存（key `uiConfigCache.v1`）解码成功者，否则 builtin。`refresh()`：`GET API.agentBase/ui-config` + `AuthStore.shared.bearer` → 200 且 `schema <= 1` 才替换 doc + 写缓存；任何失败静默保留现值。
  - `fill`：对 subs 逐对 `replacingOccurrences(of:"{{K}}", with:v)`。
- [ ] **Step 2: `cd ~/code/voicedrop && xcodegen generate` + `xcodebuild build`（模拟器 destination）→ BUILD SUCCEEDED。**
- [ ] **Step 3: Commit**：`feat(ios): UIConfigStore — 长按菜单配置模型/拉取/缓存/内置兜底`

### Task 3: iOS — 通用菜单渲染器 + PhotoTile/段落挂载

**Files:**
- Create: `VoiceDropApp/ConfigMenu.swift`（`ConfigMenuContent`）
- Modify: `VoiceDropApp/RecordingDetailView.swift`（`articleBody` 的 `.paragraph`/`.image` 两个 case + `PhotoTile`）

**Interfaces:**
- Consumes: Task 2 的 `UIConfigStore` / `fill`；现有 `agent.enqueue(_:articleIndex:)`、`bodyRows` 的 `n`/`text`/`key`。
- Produces: `ConfigMenuContent(menu:fill:onPick:)`（页面无关，输入 `UIMenuConfig` + 占位替换闭包 + 点选回调）。

- [ ] **Step 1: `ConfigMenuContent`**：groups 间 `Divider()`；`type=="submenu"&&children!=nil` → `Menu(label){...递归...}`；有 `instruction` → `Button(label){ onPick(fill(instruction)) }`；其余 EmptyView（静默跳过）。
- [ ] **Step 2: PhotoTile**：加 `var menuContent: (() -> AnyView)? = nil`（或注入 menu+onPick 两参，实现取顺手者），**仅 `image != nil`** 时在 body 链尾附 `.contextMenu { ... }`；`{{KEY}}` → `relKey` 的替换在 PhotoTile 内完成。其它 PhotoTile 使用点（若有）默认参数 nil = 零行为变化。
- [ ] **Step 3: 段落行**：`.paragraph` case **去掉 `.textSelection(.enabled)`**，附 `.contextMenu`：text 菜单（`{{LINE}}`→`String(n)`，`{{QUOTE}}`→段落前 15 字、双引号替换为单引号防指令引文断裂）+ `Divider()` + 本地「拷贝」（`UIPasteboard.general.string = text`，不进服务端配置）。
- [ ] **Step 4: 点选回调** = `agent.enqueue(instruction, articleIndex: articleIndex)`（与 `insertPhotos` 同入口，连接已在 `.task` 里 `agent.connect(recording)` 建好，队列/「正在改」UI 全复用）。详情页 `.task` 里补 `Task { await UIConfigStore.shared.refresh() }`（fire-and-forget）。
- [ ] **Step 5: 构建 + 已有单测**：`xcodegen generate`；`xcodebuild ... build` → SUCCEEDED；`xcodebuild ... -only-testing:VoiceDropTests test`（如套件可跑）。
- [ ] **Step 6: Commit**：`feat(ios): 长按配图/段落弹操作菜单，点选走语音编辑通道`

### Task 4: 部署 + 真机验收 + STATE.md

- [ ] **Step 1: worker 部署**：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`；`curl -s -o /dev/null -w '%{http_code}' https://voicedrop-agent.jianshuo.workers.dev/agent/ui-config` → 401；带合成 anon token → 200。
- [ ] **Step 2: iOS**：push 分支（合并进 main 时走 TestFlight CI）。真机手测清单（spec「测试」节）：长按已出图的图→卡通→「正在改」→placeholder→出图；长按段落→更简洁→段落更新；插入图片→公众号题图→顶部 placeholder→横幅题图；「拷贝」可用；制作中的图长按无菜单。
- [ ] **Step 3: STATE.md**：新增「长按操作菜单」小节（端点、R2 覆盖键、iOS 文件、菜单文案零部署可调的说明）+ 提及语音编辑引擎已切 haiku（config/model.json.editModel）。

## Self-Review

- Spec 覆盖：ui-config 端点+R2 覆盖 (T1)、iOS 模型/缓存/兜底 (T2)、渲染器+两个挂载+拷贝+textSelection 取舍 (T3)、部署顺序+真机清单+文档 (T4)。题图不加 size 参数（用户定）→ 无对应任务，spec 已记录。✅
- 占位符/类型一致：`loadUIConfig(env)`、`UIMenuConfig`、`fill`、`agent.enqueue(_:articleIndex:)` 各任务间名称一致。✅
- 指令文案唯一真源 = spec JSON，T1/T2 都注明「逐字复制」。✅

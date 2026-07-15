# 锚点协议 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 长按目标（图/行）随手势结构化上传（`anchor` 字段），服务端校验+漂移自愈后渲染成独立上下文行注入模型；提示词可写纯自然语言，占位符兼容保留。

**Architecture:** iOS `EditRequest` 加可选 `anchor`（image: key / line: 行号+整行原文），WS `instruct` 消息透传 → 编辑 DO 队列存列（照抄 `article_index` 的迁移模式）→ `runEditTurn` 校验（image key ∈ 本文照片；line 行号+原文一致，不一致按整行唯一匹配自愈，失败丢弃）→ varLines 注入。协议双向兼容，两端独立发版。模板改写是 Phase B，本计划不动模板。

**Tech Stack:** Cloudflare Workers（agent）+ DO SQLite；iOS SwiftUI。

**Spec:** `docs/superpowers/specs/2026-07-16-anchor-protocol-design.md`

## Global Constraints

- 服务端仓库 `~/code/jianshuo.dev`，iOS 仓库 `~/code/voicedrop`；直接 main 提交，commit 结尾不加 Co-Authored-By。
- 服务端改动前后 `cd ~/code/jianshuo.dev/agent && npm test` 全量绿（1067 基线）。
- iOS：`xcodegen generate`（如加新文件）；测试 destination 用 `iPhone 17`；BUILD SUCCEEDED + VoiceDropTests 全绿（106 基线）。
- anchor 全链路可选：缺失/非法 = 现状行为，绝不 4xx、绝不阻断编辑。
- 行号口径 = 服务端 `linenum.js` 的行切分（与 edit_current_article 工具、iOS bodyRows 同一口径）——校验/自愈必须复用它，不许自己 split("\n")。
- `anchor.text` 防御上限 2000 UTF-16 units（超长截断后再比对/搜索）。
- 部署顺序：服务端先行（T2），iOS 随后（T4）。

---

### Task 1: 服务端——anchor 透传、校验自愈、注入（一个 task 打穿）

**Files:**
- Modify: `agent/src/edit-turn.js`（runEditTurn 签名 + resolveAnchor 帮手 + varLines 注入）
- Modify: `agent/src/index.js`（:101 附近 ALTER 迁移、:239 附近 instruct 解析、:198-203 row→runEditTurn）
- Modify: `agent/src/queue.js`（submit/行结构透传 anchor，照抄 article_index 的待遇）
- Modify: `agent/src/prompt-share.js`（resolveSharedPromptBlock 注入块补一句）
- Test: `agent/test/`（edit-turn/queue 相关现有测试文件就地扩展；先 grep runEditTurn 定位）

**Interfaces:**
- Consumes: `linenum.js` 的行切分（读该文件找现成导出）。
- Produces: WS `instruct` 消息新可选字段 `anchor`：`{type:"image", key:string}` 或 `{type:"line", line:number, text:string}`——**T3/T4 的 iOS 按这个形状编码**。`runEditTurn({..., anchor})`。

- [ ] **Step 1: 写失败测试**（按现有 edit-turn 测试基建写实，覆盖六态）

```js
// ① image anchor 合法 → prompt 里出现「用户长按的图片：[[photo:<key>]]」
// ② image key 不在本文 → 不注入（prompt 里无「用户长按」字样）
// ③ line anchor 行号+text 一致 → 注入「用户长按的是第 N 行（"<text>"）」
// ④ 行号不符但 text 在正文唯一匹配 → 注入修正后的行号（自愈）
// ⑤ text 无匹配/多处匹配 → 不注入
// ⑥ 无 anchor → prompt 与现状逐字节一致（回归锁）
// ⑦ queue: instruct 消息带 anchor → row 存留 → runEditTurn 收到（DO 层透传，
//    按现有 queue/DO 测试基建写；anchor 非对象/type 非法 → 按 null 存）
// ⑧ prompt-share: 注入块含「若上下文提供了用户长按的目标」补句
```

- [ ] **Step 2: RED 确认**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/<定位到的文件>`

- [ ] **Step 3: 实现**

`edit-turn.js` 加帮手（linenum.js 的行切分函数名以实读为准）：

```js
/// anchor 校验 + 漂移自愈（spec §4.1）。返回注入行字符串或 null（宁缺勿错）。
/// lines = linenum.js 同口径的行数组；photos = 文章 photos 相对 key 列表。
export function resolveAnchorLine(anchor, { lines, photoKeys }) {
  if (!anchor || typeof anchor !== "object") return null;
  if (anchor.type === "image") {
    const key = typeof anchor.key === "string" ? anchor.key : "";
    if (!key || !photoKeys.includes(key)) return null;
    return `用户长按的图片：[[photo:${key}]]（指令里说的「这张图/这张照片」就是它）`;
  }
  if (anchor.type === "line") {
    const text = String(anchor.text || "").slice(0, 2000);
    if (!text) return null;
    let n = Number.isInteger(anchor.line) ? anchor.line : -1;
    const at = (i) => (lines[i] || "").slice(0, 2000);
    if (!(n >= 0 && n < lines.length && at(n) === text)) {
      const hits = lines.map((l, i) => [l.slice(0, 2000), i]).filter(([l]) => l === text).map(([, i]) => i);
      if (hits.length !== 1) { console.log("[anchor] line drift unresolved, dropped"); return null; }
      n = hits[0];   // 漂移自愈：正文被并发编辑动过，按整行唯一匹配修正行号
    }
    return `用户长按的是第 ${n} 行（"${text}"）（指令里说的「这段/这行」就是它）`;
  }
  return null;
}
```

`runEditTurn` 签名加 `anchor`；构建 varLines 处（:105-112 附近，「这次的语音指令」之前）：

```js
  const anchorLine = resolveAnchorLine(anchor, { lines: <linenum口径行数组>, photoKeys: <本文照片相对key列表> });
  if (anchorLine) varLines.push("", anchorLine);
  varLines.push("", "这次的语音指令：", instruction);
```

行号基准（0 还是 1）以 linenum.js/edit 工具现状为准——注入行里的「第 N 行」必须与模型在 edit_current_article 工具里用的行号同一口径，实读后对齐。

`index.js` 三处（全部照抄 article_index 模式）：

```js
try { this.sql`ALTER TABLE queue ADD COLUMN anchor TEXT`; } catch (_) {}
// instruct 解析（:239 附近）：
const anchor = msg.anchor && typeof msg.anchor === "object"
  && (msg.anchor.type === "image" || msg.anchor.type === "line")
  ? JSON.stringify(msg.anchor) : null;
const r = await this._queue.submit({ id, text: instruction, images, article_index, anchor });
// row 读取（:198 附近）：
let anchor = null; try { anchor = row.anchor ? JSON.parse(row.anchor) : null; } catch (_) {}
// runEditTurn({...", anchor })
```

`queue.js`：submit 入参与 INSERT/SELECT 列加 anchor（QUEUE_TABLE_SQL 不动——列靠 ALTER 迁移，与 article_index 同待遇；INSERT 需容忍老表无列吗？不需要——constructor 先 ALTER 后用）。

`prompt-share.js` resolveSharedPromptBlock 的注意句加：「若上下文提供了『用户长按的目标』，提示词里说的『这张图/这段』即指它。」

- [ ] **Step 4: GREEN + 全量**

Run: `cd ~/code/jianshuo.dev/agent && npm test` → 1067+ 全绿。

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev && git add agent/ && git commit -m "feat(edit): 锚点协议服务端——anchor 透传/校验/漂移自愈/上下文注入——锚点 T1"
```

---

### Task 2: 服务端部署 + 冒烟（controller 亲自执行）

- [ ] `git pull --rebase origin main` → agent 全量绿 → push → `npx wrangler deploy --cwd agent`
- [ ] 冒烟：现有 App（无 anchor）长按菜单动作照常工作（回归）；WS 发带 anchor 的 instruct 无 5xx（tail 观察一条即可，或靠 T5 真机）。

---

### Task 3: iOS——EditAnchor 模型 + WS 编码 + 队列持久化

**Files:**
- Modify: `VoiceDropApp/AgentSession.swift`（EditAnchor + EditRequest.anchor + enqueue 参数 + send payload + persist 编解码）
- Test: `VoiceDropTests/`（新文件 AnchorTests.swift → 记得 xcodegen）

**Interfaces:**
- Consumes: T1 的 wire 形状：`anchor: {type:"image", key}` / `{type:"line", line, text}`。
- Produces: `enum EditAnchor: Equatable { case image(key: String); case line(Int, text: String) }` + `EditRequest.anchor: EditAnchor?` + `enqueue(_:images:articleIndex:anchor:)`——T4 调用。

- [ ] **Step 1: 失败测试**——EditAnchor → payload 字典的编码形状（两 case + nil 缺省不带键）；EditRequest 持久化 round-trip 带 anchor。
- [ ] **Step 2: 实现**——send() 的 payload 加 `if let anchor = item.anchor { payload["anchor"] = anchor.wireDict }`；persist 编解码按 EditRequest 现有机制扩展（实读后同构加字段，老磁盘队列缺字段=nil 不炸）。
- [ ] **Step 3: BUILD + VoiceDropTests 全绿 → Commit**

```bash
git commit -m "feat(edit): EditAnchor 模型与 WS/持久化编码——锚点 T3"
```

---

### Task 4: iOS——菜单调用点带锚点 + 新建提示词引导文案

**Files:**
- Modify: `VoiceDropApp/RecordingDetailView.swift`（presentImageMenu :920 附近、文字菜单 :857 附近——onPick 带 anchor；{{KEY}}/{{LINE}}/{{QUOTE}} 替换**原样保留**）
- Modify: `VoiceDropApp/PromptNewSheet.swift` / `PromptEditView.swift`（提示词输入框 placeholder/说明文案改为自然语言示例「把这张照片重画成水彩」「把这段改得更简洁」，不再教占位符）

**Interfaces:**
- Consumes: T3 的 `enqueue(..., anchor:)`。
- 文字菜单的 line 锚点取**整行原文**（长按那一段的 text，非 15 字前缀）；行号与 {{LINE}} 同一变量。

- [ ] **Step 1: 实现两处调用点 + 文案**
- [ ] **Step 2: BUILD + 全量测试绿 → Commit（带 [tf]）**

```bash
git commit -m "feat(edit): 长按菜单动作携带锚点，提示词引导自然语言 [tf]——锚点 T4"
```

---

### Task 5: 收尾（controller）——STATE.md + 真机手测清单

- [ ] STATE.md 新段落（协议形状、自愈语义、Phase B 待办、老 App 兼容矩阵）。
- [ ] 真机手测清单：① 多图文章长按第 2 张图选水彩 → **确改第 2 张**（金标准）② 长按中间某段选更简洁 → 确改那段 ③ 自建自然语言提示词（无占位符）在多图文章长按精确命中 ④ 老提示词（带占位符）行为不变 ⑤ 语音自由指令回归正常。

## Self-Review 备忘

- spec §3 → T1(wire 解析)+T3(编码)；§4.1 → T1；§4.2 → T1（补句）；§5 → T3/T4；§6 → 各 task TDD + T5 手测；§7 Phase B 明确不做；§8 → T2 先行 T4 随后。
- 类型一致：wire 形状（T1 定义、T3 消费）；enqueue anchor 参数（T3 定义、T4 消费）；行号口径（linenum.js 单一真源，T1 内部对齐，注入行与工具行号一致）。
- 留给实现者实读适配的点（非占位符）：linenum.js 的具体导出名、行号 0/1 基准、EditRequest persist 的现有编码机制、edit-turn 测试文件位置。

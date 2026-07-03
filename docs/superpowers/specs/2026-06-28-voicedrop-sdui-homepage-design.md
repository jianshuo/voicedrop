# VoiceDrop 可定制首页（语音驱动的 JSON SDUI）— 设计

Date: 2026-06-28
Status: Approved design, pending implementation plan

## 一句话

让用户对着 app 说「我想要一个这样的首页，有写文章、看社区、记录、思考四块，你帮我做出来」，
agent 生成一份 `users/<sub>/page.json`（服务端驱动 UI 文档），下次打开 app 由原生渲染引擎渲染成真实首页。

## 为什么是 JSON SDUI 而不是 HTML

- **Apple 政策**：受控/封闭词表的 JSON-SDUI，app 下载的是「配置/数据」，渲染用的是编译进包里的原生组件，
  **不是下载可执行代码** —— 比裸 HTML 更稳地符合审核指南 2.5.2，也不触发 4.7（mini-app）。
- **私人首页**：这是用户**自己看的**首页、不展示给别人，所以**不触发 UGC 审核负担**（1.2）。
- **健壮性**：封闭词表可逐节点校验，坏数据降级而非崩溃；HTML/WebView 做不到这点。

## 已定的四个核心决定（来自 brainstorming）

1. **组件模型 = 混合**：通用排版原语（vstack/hstack/grid/text/image）+ 一等「功能块」（recordButton/articleList/communityFeed/notePlaceholder）。既有 HTML 级排版自由，又能直接拉起真实功能；词表封闭、可校验。
2. **安全壳 = 取代 + 固定外壳**：page.json 只管中间内容区；顶部品牌栏 + 齿轮（含「编辑首页」「重置首页」）是永远固定的原生外壳，page.json 改不到。page.json 缺失/解析失败 → 回退内置默认布局。
3. **v1 范围 = 只包现有功能**：功能块 = recordButton、articleList、communityFeed + 展示块 text/image/grid/card/spacer。「思考」= `notePlaceholder` 占位块（能摆能渲染，点进去「即将推出」）。**笔记/随想是未来独立项目**，不在本 spec。
4. **生效方式 = 即时生效**：复用现有「语音改文章」基建（agent Worker + 客户端串行队列）；改完即写回 + 当场重渲染。第一次没有 page.json 时即「从零生成」。

## 架构与数据流

```
┌─ 原生固定外壳（page.json 改不到）────────────┐
│  品牌栏 [VoiceDrop 口述]            [⚙︎ 齿轮] │   齿轮里永远有「编辑首页」「重置首页」
├─ 可定制内容区（由 page.json 渲染）───────────┤
│   PageRenderer(root node 树)                  │   递归渲染
└──────────────────────────────────────────────┘

用户语音「帮我做个…首页」
   │ app 持麦，客户端串行队列（同 ArticleAgentSession）
   ▼
agent Worker 新增 PageEditor DO  (wss://…/agent/page)
   │ 读 users/<sub>/page.json(当前，无则默认) + users/<sub>/CLAUDE.md(名字/风格) + 词表说明
   │ → Claude → 返回完整 page.json
   ▼
服务端按 schema 校验（不过则 Claude 重试，绝不写坏 JSON）→ 写 users/<sub>/page.json → 推回 app
   ▼
app 本地再校验 → 重建 node 树 → 首页当场重渲染（即时生效）
```

- 存储：`users/<sub>/page.json`，走已有 Files API `download/<key>` / `upload/<key>`。
- 校验**两端各做一遍**，共用同一份词表定义（单一真理源，见下）。
- 新用户 / 解析失败 / 「重置首页」→ 内置默认 page.json（复刻今天的「录音键＋我的录音＋VD社区」）。

## page.json 词表（封闭、可校验）

顶层：
```json
{ "schema": 1, "version": 3, "root": <node> }
```
- `schema`：词表版本，向后兼容用。
- `version`：每次编辑自增（便于客户端缓存判新 / 未来撤销）。
- `root`：单个根节点（通常是 `vstack`）。

**节点四类**（app 只认这些 `type`，未知 type → 解码为 `.unknown`，渲染层跳过并记日志）：

| 类别 | type | 关键字段 |
|---|---|---|
| 容器 | `vstack` `hstack` `grid` `spacer` | `spacing`(数) `padding`(数) `align`(`leading`/`center`/`trailing`) `columns`(grid 用) `children`([]) `size`(spacer 用) |
| 展示 | `text` `image` | text: `value`(串) `size`(数) `weight`(`regular`/`medium`/`semibold`/`bold`) `color`(token 名) `align`；image: `source`(`photo:<relKey>` / `asset:<name>`) `aspect`(数) `corner`(数) |
| 磁贴（可点→跳转） | `card` | `title` `subtitle` `icon`(SF Symbol 白名单) `tint`(token 名) `tap`(动作枚举) |
| 内嵌（就地渲染真实功能） | `embed` | `block`: `recordButton` / `articleList` / `communityFeed` / `notePlaceholder` |

**磁贴 vs 内嵌**
- `card`：会跳转的瓦片。`tap` ∈ 封闭枚举 `record` / `openArticles` / `openCommunity` / `openSettings` / `openNote`。
- `embed`：把真实功能**就地**渲染进首页（如文章列表直接铺在首页上）。

**白名单（不收任意值，保持品牌一致 + 杜绝安全/跑版）**
- `color` / `tint`：仅接受 `Theme.swift` 的 token 名（`ink` `secondary` `accent` `recordRed` `greenDone` …）。
- `icon`：仅接受一份 SF Symbol 允许集。
- 未知/越界的 token、size 超合理范围 → 回落到默认值（不是报错）。

**校验规则**
- 单个节点非法 → 丢弃该节点，照常渲染其余。
- 整份 JSON 结构性损坏 / `root` 缺失或为空 → 回退上一份好的；再不行 → 内置默认。
- **不变量：永远不会白屏 / 崩溃。**

### 范例

```json
{
  "schema": 1,
  "version": 1,
  "root": {
    "type": "vstack", "spacing": 16, "padding": 20, "children": [
      { "type": "text", "value": "早安，建硕", "size": 28, "weight": "bold", "color": "ink" },
      { "type": "grid", "columns": 2, "spacing": 12, "children": [
        { "type": "card", "title": "写文章", "icon": "doc.text", "tint": "accent", "tap": "openArticles" },
        { "type": "card", "title": "看社区", "icon": "person.2", "tint": "accent", "tap": "openCommunity" },
        { "type": "card", "title": "思考", "icon": "brain", "tint": "secondary", "tap": "openNote" }
      ]},
      { "type": "embed", "block": "recordButton" }
    ]
  }
}
```

## iOS 渲染引擎

新文件（都在 `VoiceDropApp/`，xcodegen 自动纳入；新增文件后需 `xcodegen generate`）：

| 文件 | 职责 |
|---|---|
| `PageModel.swift` | `PageNode` 枚举 + `Codable` 解码器（纯 Foundation，**单元可测**）。解码即校验；未知 type → `.unknown`。词表的客户端真理源。 |
| `PageRenderer.swift` | `PageNode -> some View` 递归渲染器。容器递归、展示叶子直绘、`card` 复用现有卡片 chrome（`Theme.card` / `cardChromeShadow`）、`embed` 桥接真实视图。 |
| `PageStore.swift` | `@Observable`：拉 `users/<sub>/page.json`、本地校验、回退逻辑、持有当前 `PageNode` 树；`scenePhase` 激活刷新（同 `LibraryStore`）。 |
| `PageAgentSession.swift` | 照抄 `ArticleAgentSession`：hold-to-talk 持麦、客户端串行队列、连 PageEditor DO、`updated` 触发重渲染。 |

**`embed` 桥接（复用现有视图，不重写）**
- `recordButton` → 现有红色录音键（拉起 `RecordSession`）。
- `articleList` → 把 `LibraryView` 的录音/文章列表抽成可复用子视图 `RecordingsList`。
- `communityFeed` → 把社区列表抽成可复用子视图。
- `notePlaceholder` → 「即将推出」占位卡。

**唯一一处现有代码重构**：`LibraryView` 从「写死的两栏首页」改为「固定外壳 + `PageRenderer(store.tree)`」。
今天的两栏布局原样搬进**内置默认 page.json**，默认体验零变化，老用户无感。列表体从 `LibraryView`
拆成 `RecordingsList` / 社区子视图，`LibraryView` 与 `embed` 共用，行为不变。

## PageEditor 语音生成（复用 agent Worker）

服务端（`~/code/jianshuo.dev/agent/src/`，与 `ArticleEditor` 并列）：
- 新 DO `PageEditor`，路由 `wss://…/agent/page`。结构照抄 `ArticleEditor`（app 持麦、客户端串行队列：一条改完再发下一条）。
- 每条指令：读当前 `page.json`（无则默认）+ 用户 `CLAUDE.md`（名字/文风）+ **词表说明（系统提示）** → Claude 返回**完整 page.json** → **服务端按 schema 校验**（不过 → Claude 重试，绝不写坏 JSON）→ 写 `users/<sub>/page.json` → 推回 app。
- 所有 Claude 调用照旧落 `llmlogs/`。

客户端入口：齿轮菜单「编辑首页」→ hold-to-talk，麦克风按钮即「正在改」指示器（与改文章完全一致的体感）。

## 词表单一真理源

一份 `page-schema` 描述（节点类型 + token 白名单 + 几个范例）**同时**用于：
1. 喂给 Claude（系统提示）；
2. 服务端校验；
3. 对照客户端 `PageModel` 解码器。

三处一致避免漂移。实现时确定它的存放形式（建议：agent 仓库里一个 `page-schema.js`/`.json` 常量 + iOS 侧解码器为对应实现，spec 此处不强绑文件名，留给实现计划）。

## 测试

- **服务端**（`agent/test/`，`npm test`）：page.json schema 校验器单测——合法样例通过；各类非法（未知 type、坏 token、缺字段、整体损坏、空 root）按预期被拒/降级；PageEditor「Claude 返回坏 JSON → 重试」路径。
- **iOS**：`PageModel` 解码器单测（纯 Foundation，同 `RecordingName`）——fixture page.json 解码出预期节点树；非法输入降级到 `.unknown` / 回退而不抛。
- **回退链路**：缺文件 / 坏 JSON / 空 root → 内置默认渲染；断言永不白屏。

## 不做（YAGNI / 未来）

- 「思考」的真实笔记/随想功能（独立项目）。
- 公开/分享他人可见的自定义页（会触发 UGC 审核，另案）。
- 任意色值 / 任意图标 / webview 块。
- 撤销/重做历史（即时生效已选定；如需要可后续复用文章版本控制的 head 指针模型）。
- 预览-确认流（已选「即时生效」）。

## 受影响 / 相关代码

- iOS：`LibraryView.swift`（改造为外壳+渲染器）、`Theme.swift`（token 白名单来源）、`RecordSession.swift`/`Community.swift`（embed 桥接复用）、新增四个 `Page*.swift`。
- Worker：`~/code/jianshuo.dev/agent/src/`（新 `PageEditor` DO，与 `ArticleEditor` 并列）、`agent/test/`（新测试）。
- 存储契约：新增 `users/<sub>/page.json`（见 STATE.md「R2 layout」需补一条）。

## Phase 1 落地说明（2026-07-03）

- 默认首页采用「`tree == nil` → 原生首页」而非内置一份默认 page.json 树——等价结果、更低风险，
  且词表不需要 `tabs` 节点。没有自定义页的用户走的代码路径与改造前完全相同（零回归）。
- 实现偏差（相对本 spec 附的示意代码，均为编译/运行时发现的必要修正）：
  1. `PageDocument.decode` 区分「root type 不在词表」（→ nil，整份作废回退）与「type 认识但必填字段
     非法」（→ 该节点降级 `.unknown` 渲染为空，文档保留）——原示意两者混同，与自身测试矛盾。
  2. 外壳在树含 `articleList`/`communityFeed` embed 时不套 ScrollView（SwiftUI List 在 ScrollView 里
     塌成零高），`PageNode.containsListEmbed` 自适应；纯静态页仍套 ScrollView 以便超屏滚动。
  3. `resolveTree` 标 `nonisolated`（Swift 6 严格并发下 @MainActor 类内纯函数需显式脱离隔离才能单测）。

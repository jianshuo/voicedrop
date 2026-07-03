# VoiceDrop 语音指令（Voice Command）设计

**日期**：2026-07-02
**状态**：设计已批准，待写实现计划
**涉及仓库**：`~/code/voicedrop`（iOS app）+ `~/code/jianshuo.dev/agent`（Cloudflare Worker 后端）

## 目标

在「我的录音」首页，**长按**底部那颗红色录音键，进入一个像 Siri 一样的语音指令模式：列表每篇文章浮出圈序号，用户按住说一句自然语言指令（例「把③和④合并」「删掉第②篇」「给①换个更口语的标题」），松手后由 Claude 理解意图并对文章库执行相应操作。

**核心工程约束**：听写捕获 + 反馈这套交互，要**复用现有「语音编辑」栈的同一套代码**（不做平行实现）。绑死单篇文章的那层（会话/路由/工具集/计费）另起一层库级实现，架在共享引擎之上。两套 agent 的完全统一留待以后。

## 关键决策（brainstorming 结论）

1. **指令宽度 = 开放式 agent**：LLM 理解自由口语，映射到一组库级动作（合并/删除/改标题/换风格重写/归类…），不是固定关键词匹配。
2. **交互 = 对讲机式**：按住红键→列表出序号→说话→松手执行（复用现有 `holdGesture` 的按住说、上滑取消）。滚动受限是已知取舍（常用的顶部几篇都在视野内）。
3. **执行时机 = 分级确认**：非破坏性动作直接执行；破坏性动作先弹确认卡。
4. **合并语义 = LLM 智能揉成一篇 + 保留原文**：Claude 把两篇揉成一篇连贯新文章（去重、顺逻辑、用户文风），**另存为新一条，原两篇保留**。⇒ 合并是**非破坏性**的（没删东西），可直接执行。**实际唯一的破坏性动作是 `delete_article`**，只有它需要确认。

## 全局约束

- 所有 UI 文案中文。
- ASR = 火山（豆包）流式，走现有 `/agent/asr` 代理（服务端持凭证）。
- LLM = Claude（编辑/agent 走 Anthropic-only，`resolveEditModel`），用最新型号。
- 写文章一律走版本化 Files API（`PUT ${origin}/files/api/articles/${stem}`），不直接 R2 put；沿用 `doc.lastEditId` exactly-once。
- 计费走 `USAGE` D1（`ensureAccount`/`debit`）。
- 新增 iOS 文件后跑 `xcodegen generate`（`project.yml` 是真源）。
- 服务端测试放 `agent/test/`，用 `makeMemStore` 单测队列/工具。
- 参考现有语音编辑 spec：`2026-06-27-voice-edit-durable-queue-design.md`、`2026-06-28-voice-edit-volc-asr-proxy.md`。

## 复用地图（来自代码勘察）

### 原样复用（零改动）
- `SpeechDictation`（`VoiceDropApp/VoiceEdit.swift:105-302`）+ `VolcAudioStreamer` + `VolcASRProtocol.swift`：麦克风采集 + 流式 ASR，**完全不认文章**，只需 bearer token。
- 服务端 `/agent/asr`（`src/index.js:578-588`）+ `proxyVolcAsrWebSocket`（`src/asr-proxy.js`）：火山流式 ASR 透明代理，无 stem。
- 反馈 UI 片段：`darkBubble`（实时转写，`RecordingDetailView.swift:831-844`）、`replyBubble`（一行结果/报错，`:809-826`）、`queueRow`（排队，`:761-780`）。
- 服务端 `runAgentLoop`（`src/loop.js:20-57`，通用 tool-use 驱动，article-agnostic）+ `ArticleQueue`（`src/queue.js:74-145`，幂等持久 FIFO 队列，依赖注入可单测）+ 消息词汇 `status/updated/reply/error/snapshot`。
- 已有库级工具（`src/tools.js`）：`list_articles`、`read_article`、`write_article`、`read_style`、`write_style`、`share_to_community`、`publish_wechat`。

### 抽出成共享组件（一次重构，两处受益 —— 这就是"以后统一改进"的接缝）
- **iOS `PushToTalkBar`**：把 `RecordingDetailView` 的按住说话 bar（`voiceBar` `:737-758`、`pill` `:782-804`、`holdGesture` `:864-882`）抽成独立 View，持有 `SpeechDictation` + 一个会话抽象。文章专属的两处参数化掉：`highlightedTranscript`（第N行/图N 染色，`:847-861`）与末尾 `enqueue(articleIndex:)`（`:879`）。
- **iOS `VoiceAgentSession` 协议**：`state / queue / onReply / onUpdate / enqueue / connect / disconnect`。现有 `ArticleAgentSession` 实现它；新加 `LibraryCommandSession` 也实现它。`PushToTalkBar` 只依赖协议。

### 库级新增（薄薄一层，架在共享引擎上）
- iOS `LibraryCommandSession`（`ArticleAgentSession` 的无 stem 兄弟）、库级序号 overlay、红键长按接线。
- 服务端 `/agent/command` WS 路由、`LibraryAgent` DO（每用户一个）、`runCommandTurn`、库级工具集、`meteredCommandGate`。

## 产品 / 交互

**入口**：底部红键。轻点 = 录音（`showRecord`，不变）；**长按 = 语音指令**。

**按住时**：触觉反馈 + 列表每篇左侧浮出圈序号 ①②③…（按当前新→旧的绝对位置编号，仅命令态显示）；红键变为"聆听 pill"（松开发送 / 上滑取消）；`darkBubble` 实时转写。

**指令示例**：「把③和④合并」「删掉第②篇」「给①换个更口语的标题」「②③④用轻松点的风格重写」「这几篇归到『上海』标签」。

**松手 → 转写 + Claude 理解 →**
- 非破坏性（合并 / 改标题 / 换风格 / 归类）：直接执行，`replyBubble`「已把 ③④ 合成《新标题》」，列表刷新。
- 破坏性（`delete_article`）：弹确认卡「要删掉 ②《…》吗？」→ 确认才删。
- 没听清 / 空转写 / 编号超界 / 指代不明：`replyBubble` 提示，数据不动。

## 数据流（编号 → stem 解析，防错位）

客户端把**用户看到的那份有序清单**随指令一起发：`{ type:"instruct", id, text, refs:[{n, stem, title}] }`。服务端 agent 把"第③篇"映射到 `refs[2].stem`，**绝不让服务端另列一遍导致编号与用户所见错位**。`refs` 只含轻量字段；文章正文由工具按需 `read_article` 拉取。

## 服务端组件

### `/agent/command` WS 路由（`src/index.js`）
仿 `/agent/edit`（`:539-561`）：要求 `Upgrade: websocket`；bearer→`resolveScope`（401）；**不带 stem**；DO 名 `sanitizeName(scope + ":command")`（每用户一个）；注入 `x-vd-scope`。

### `LibraryAgent` DO（`src/index.js`）
仿 `ArticleEditor`（`:100-305`）：复用 `ArticleQueue` 引擎 + `runAgentLoop` + 消息词汇。区别：身份是 scope（非 scope+stem），`runTurn` 调 `runCommandTurn`（新），gate 用 `meteredCommandGate`（新）。durable 队列/幂等/重连/snapshot 机制原样继承。

### `runCommandTurn`（`src/command-turn.js`，新）
仿 `runEditTurn`（`src/edit-turn.js`）：构造 system（用户文风 CLAUDE.json 作缓存前缀）+ 把 `refs` 编号清单喂进 prompt + 用户指令；驱动 `runAgentLoop`，`ctx = { env, scope, token, origin, turnId, refs }`（无单一 articleKey）；工具执行后回 `reply` 概述 + 受影响文章的 `updated`。

### 库级工具集（`src/tools.js` 扩展）
- 复用：`list_articles`、`read_article`、`write_article`、`read_style`、`write_style`、`share_to_community`、`publish_wechat`。
- 新增：
  - `merge_articles({ stems:[...] , guidance? })` — 读多篇 → Claude 揉成一篇连贯新文章（用户文风）→ 以新 stem 另存 → **原文保留**。非破坏性。**列表锚点**：新文章是"无录音"的独立文章，而「我的录音」列表锚在 `.m4a` 上——所以要沿用风格 intro 的套路，**先写 `articles/<new-stem>.json`、再写一个 0s 静音 `<new-stem>.m4a`（`-0m0s-`）**，article JSON 先落 → miner 扫到 m4a 时 `.json` 已存在 → skip ASR，文章即出现在列表。新 stem 命名不带 `Task` token（避免被 `classifyKey` 当任务），形如 `VoiceDrop-merged-<yyyy-...>`。
  - `delete_article({ stem })` — **破坏性**，走确认流。
  - `restyle_article({ stem, guidance })` — 复用 `miner.js` 的 `restyleArticle`。非破坏性。
  - `tag_article({ stems:[...], tag })` — 给文章打标签/归类（写进 doc 的一个 `tags` 字段；列表/详情后续可展示）。非破坏性。
  - 每个工具带 `destructive:boolean`。

### 分级确认（新增 `confirm` 消息类型）
非破坏性工具在 loop 内直接执行。破坏性工具（`delete_article`）**不在 loop 内直接删**：服务端把 pending 动作存进 DO durable 态（keyed by turnId），向客户端发 `{ type:"confirm", id, summary, action }`；客户端弹确认卡；用户点确认发 `{ type:"confirm", id }` → 服务端执行并回 `updated`/`reply`；点取消发 `{ type:"cancel", id }` → 丢弃 pending。

### 计费 `meteredCommandGate`（`src/index.js` / `usage.js`）
复用 `ensureAccount`/`debit`；只做**余额判断**（去掉每文章 `MAX_EDITS_PER_ARTICLE` 上限，库级指令不按文章计）。每次 Claude 调用按 `claudeCostUY` 扣费，reason `"command"`，detail 带 `turn_id`（+ 受影响 stem 若适用）。合并/重写因产出新文章，成本与一次挖矿/编辑相当。

## iOS 组件

### `VoiceAgentSession` 协议（新，`VoiceDropApp/`）
`var state / error / queue / onUpdate / onReply`；`func enqueue(_:images:articleIndex:)`；`func connect(...)`；`func disconnect()`。`ArticleAgentSession` 改为实现它（行为不变）。

### `PushToTalkBar`（新，从 `RecordingDetailView` 抽取）
持有 `SpeechDictation` + `VoiceAgentSession`。参数：是否启用第N行/图N 染色（文章编辑开、库指令关）、`onSend(transcript)` 或直接 `enqueue`。`RecordingDetailView` 改用它（回归验证编辑流不变）。

### `LibraryCommandSession`（新）
实现 `VoiceAgentSession`；连 `wss /agent/command`（**无 stem**）；队列持久化用 scope 级 key（`commandQueue.<scope>`，仿 `EditQueueStore` 但换 key）；结果复用 `onReply/onUpdate`。

### `LibraryView` 接线
- 红键加长按手势（复用 `holdGesture` 逻辑）：按下→触觉 + `showCommandMode=true`（列表浮序号）+ `dictation.start()`；松手→`stopAndGetFinal()`→`command.enqueue(text, refs:)`；上滑取消。
- `rowCard` 命令态左侧圈序号（按 `articlesForList` 的绝对位置）。
- 结果 `replyBubble` + 破坏性动作确认卡（`.alert` 或自绘卡）。
- `command.onUpdate` → `refresh()` 刷新列表。

## 错误处理

- 空转写/没听清 → `reply` 提示，不动数据，不扣费（无 Claude 调用）。
- 编号超界/指代不明 → agent 回 `reply` 追问或报错，不改数据。
- 余额不足 → gate 回 `no-credit`，`reply` 提示去充值。
- 幂等：沿用 `id`/`turn_id` exactly-once；合并重复提交不会造两篇（`lastEditId` 语义在库级用 turnId 去重）。
- WS 断线：复用 `ArticleAgentSession` 的自动重连 + connect-时 `snapshot` 对账。

## 测试

- 服务端（`agent/test/`，`makeMemStore`）：`runCommandTurn` + 各库级工具（`merge_articles` 揉合并留原文、`delete_article` 破坏性+确认流、`restyle_article`、`tag_article`）；`meteredCommandGate` 余额门；编号→stem 解析（`refs` 映射）；`confirm`/`cancel` 流幂等。
- iOS：`PushToTalkBar` 抽取后，回归现有语音编辑流（`RecordingDetailView`）不变；`LibraryCommandSession` 连接/enqueue/onReply 路径。

## 范围外 / 以后

- **两套 agent 完全统一**（单一 `/agent` + scope 参数）：本期只共享引擎（`runAgentLoop`/`ArticleQueue`/ASR/`PushToTalkBar`/消息词汇），`ArticleEditor` 与 `LibraryAgent` 暂并存。统一是明确的后续项。
- 命令态列表滚动（对讲机按住时不滚）：本期接受"引用可见项"。
- `tag`/归类的列表展示 UI、更多动作（拆分、批量发布等）：后续增量加进 `TASK_HANDLERS` 式的工具集。

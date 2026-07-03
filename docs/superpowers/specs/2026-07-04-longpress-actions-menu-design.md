# 长按配图/文字 · 操作菜单（2a/2b）— 设计

日期：2026-07-04
设计稿：claude.ai/design 项目 `834ad7a9`（`Long Press Actions.dc.html`，方向 2a+2b+2c；2d SDUI 富组件暂缓）
相关既有 spec：`2026-06-28-voice-edit-volc-asr-proxy.md`（语音编辑通道）

## 一句话

在文章详情页长按一张配图或一段文字，弹出原生分组菜单（2a），点进二级子菜单（2b）选一个操作，客户端把**配置好的指令文本**（内嵌该图精确 `[[photo:KEY]]` marker，或该段的第N行+开头引文）塞进**现有语音编辑通道**，由 Claude 执行 `edit_photo` / 正文改写；配图路径下图片随即变成现成的「正在制作中」placeholder，约 1 分钟后新图自动替换。图片和文字各一套菜单，都由服务端下发。

## 核心决策（已与用户确认）

| 决策 | 选择 | 理由 |
|---|---|---|
| 触发通道 | **走语音编辑线（经 Claude），不做直连端点** | 服务端零新增、一条码路、Claude 看着上下文能写出更贴的编辑指令；代价是点击到生效约 5–15 秒 + 每次多一轮对话 token 算力，用户已接受 |
| 菜单配置 | **2c 服务端 JSON 下发**（`GET /agent/longpress-menu`，一次下发 image/text 两套） | 加选项/调指令模板不发 App 版 |
| 图片定位 | **精确 key，不用图N号码** | 长按的 PhotoTile 本身持有 relKey；号码是给口述用的，且 legacy 数字 marker 有 iOS/agent 编号分歧的已知坑，用 key 整个绕开 |
| 文字定位 | **第N行 + 开头引文双保险** | 段落没有 key；第N行是语音编辑既有契约（iOS bodyRows 与 agent linenum.js 同规则），引文让 LLM 能校验、罕见编号漂移时不改错段 |
| v1 图片菜单 | **图片风格子菜单**（卡通/水彩/素描/油画/胶片） | 口述修改/删除配图/画幅比例/重新生成后续再加 |
| v1 文字菜单 | **改写这段子菜单**（更简洁/更口语/更书面/扩写一点）+ 客户端本地「拷贝」 | 具体选项是配置文案，上线后零部署可调 |
| 状态跟踪 | **不做**（无原图✓、无当前风格打勾） | 每按一次 = 一次新编辑；想回原状走文章版本历史 |
| Placeholder | **零新代码** | `PhotoTile` 已实现 Image Placeholder 设计（制作中/失败重试，404 自动轮询 5 分钟）；`edit_photo` 本来就先换 marker 再提交 paint job。文字改写走既有「正在改」指示，无需占位 |

## 数据流

```
长按 PhotoTile（已加载出图的才出菜单）／ 长按段落 Text
  → 原生 contextMenu：组→Section，submenu→Menu（= 2a 分组 + 2b 二级替换式，系统行为）
  → 点「卡通」／点「更简洁」
  → 指令模板填占位符：
      图片：「把这张图（[[photo:photos/…/45-k2x.jpg]]）转成手绘卡通插画风格，
             构图和主体不变，正文其他内容都不要动。」
      文字：「把第7行（开头是"上周和团队复盘"）改写得更简洁，
             意思不变，正文其他行都不要动。」
  → 塞进 ArticleAgentSession 现有指令队列（与口述指令同路：同「正在改」指示、同串行排队）
  → ArticleEditor DO 一轮对话 → Claude 调 edit_photo ／ 改写正文
  → 图片：marker 换 newKey、提交 paint job、推更新文档
      → PhotoTile 对 newKey 404 → 「正在制作中」placeholder（现成）→ 3s 轮询
      → paint-callback 落图 + 扣 4.2 算力 → 图自动出现
  → 文字：改写落盘、推更新文档 → 详情页原位刷新（既有行为）
```

失败路径全部现成：paint 提交失败 `edit_photo` 自动回滚 marker；出图失败回调写回原图副本、不扣费；算力不足由工具返回错误、经语音编辑既有的回复路径呈现（与口述编辑失败同一表现）。

## 组件

### 1. Agent worker：`GET /agent/longpress-menu`（唯一服务端新增）

- 鉴权：任意有效用户 token（`resolveScope`，同 `mine/trigger`），否则 401。
- 响应（2c schema，image/text 两套一次下发）：

```json
{
  "schema": 1,
  "menus": [
    { "target": "image",
      "groups": [[
        { "id": "style", "label": "图片风格", "type": "submenu",
          "children": [
            { "id": "cartoon",    "label": "卡通", "instruction": "把这张图（[[photo:{{KEY}}]]）转成手绘卡通插画风格，构图和主体不变，正文其他内容都不要动。" },
            { "id": "watercolor", "label": "水彩", "instruction": "…" },
            { "id": "sketch",     "label": "素描", "instruction": "…" },
            { "id": "oil",        "label": "油画", "instruction": "…" },
            { "id": "film",       "label": "胶片", "instruction": "…" }
          ] }
      ]] },
    { "target": "text",
      "groups": [[
        { "id": "rewrite", "label": "改写这段", "type": "submenu",
          "children": [
            { "id": "concise",  "label": "更简洁", "instruction": "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更简洁，意思不变，正文其他行都不要动。" },
            { "id": "casual",   "label": "更口语", "instruction": "…" },
            { "id": "formal",   "label": "更书面", "instruction": "…" },
            { "id": "expand",   "label": "扩写一点", "instruction": "…" }
          ] }
      ]] }
  ]
}
```

- 占位符：`{{KEY}}` = 被长按图片的 relKey；`{{LINE}}` = 段落的第N行号（bodyRows 的连续行号，与 linenum.js 同契约）；`{{QUOTE}}` = 该段开头 ~15 字（引号内如有引号做转义）。全部由客户端替换。指令是普通中文文本，客户端可见无妨。
- 模板同构，只换风格/语气词，具体措辞实现时在 worker 字面量里定稿（属文案不属结构）。
- 配置真源 = worker 内置字面量；R2 `config/longpress-menu.json` 存在且解析合法则整体覆盖（照 `community-blocklist` 先例）。改 R2 = 零部署调菜单/文案。
- `schema` 协商：客户端遇到高于自己支持的 schema → 用内置兜底菜单。

### 2. iOS：菜单模型 + 获取

- 新文件 `LongPressMenu.swift`：`Codable` 模型 `{schema, menus:[{target, groups:[[Node]]}]}`，`Node {id, label, type, children?, instruction?}`；未知 `type`/`target` 静默跳过。
- 详情页首次出现时 `GET /agent/longpress-menu`（带 `AuthStore.bearer`），成功则存 UserDefaults 作缓存。兜底链：本次拉取 → 上次缓存 → 内置默认（与服务端 v1 内容一致的硬编码）。长按永远有菜单。

### 3. iOS：长按菜单挂载

- **图片**：菜单实现在 `PhotoTile` 内部（它知道自己的加载状态），**仅 `image != nil` 时**附加 `.contextMenu`——制作中/失败态长按无菜单（编辑一张还没出的图必然失败，直接不给入口）。菜单内容与点选回调由父视图注入；PhotoTile 自己完成 `{{KEY}}` → relKey 替换。
- **文字**：段落行（`bodyRows` 的 `.paragraph`）附加 `.contextMenu`，用 text 菜单；`{{LINE}}`/`{{QUOTE}}` 由该行的 n 和段落文本替换。**段落行取消 `.textSelection(.enabled)`**（长按选择与 contextMenu 手势冲突），补偿：text 菜单尾部由客户端本地追加「拷贝」项（`UIPasteboard`，不进服务端配置、不走网络）。
- 点选 → 成品指令交给现有 `ArticleAgentSession` 指令入队路径（与听写结果同一入口），排队/串行/「正在改」UI 全部复用。**连接生命周期也复用**：若点选时 websocket 尚未建立，按听写路径的既有逻辑先建连再发（菜单路径不自己管连接）。
- 只在文章详情页生效：`PhotoTile` 与段落行本就只在 RecordingDetailView；社区（`CommunityPhotoTile`）与公开网页不涉及。

### 4. 不做的（non-goals）

直连 HTTP 端点；原图✓/当前风格状态；画幅比例、重新生成、删除配图、删除这段、口述修改菜单项；给段落配图（new_photo 入口）；2d SDUI 富组件（预览网格/滑杆/banner）；菜单里的算力标注。

## 测试

- **Agent**（改动前后跑全量 `cd ~/code/jianshuo.dev/agent && npm test`）：新增 `longpress-menu.test.js` — 无 token 401；200 返回形状合法（schema/menus 两个 target/instruction 含各自占位符）；R2 覆盖生效；R2 损坏时回退内置。
- **iOS**：xcodegen 重新生成工程（新增 `LongPressMenu.swift`）+ 构建通过；真机手测：长按图 → 点卡通 → 「正在改」→ placeholder → 出图；长按段落 → 点更简洁 → 段落更新；「拷贝」可用；制作中的图长按无菜单。

## 部署顺序

worker 先（`npx wrangler deploy`，新端点先上无害）→ App 后（TestFlight）。菜单端点不可达时客户端有内置兜底，两端不存在硬依赖。

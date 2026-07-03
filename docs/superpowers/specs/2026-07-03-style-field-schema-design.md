# style 出正文进 schema 字段（方案二）— design

日期：2026-07-03 · 状态：已批准（对话中确认，含两个前置点）

## 问题

`<!-- style: 风格 vN -->` 注释藏在文章 body 顶部：iOS 渲染/编号前剥掉它
（`ArticleBody.segments` → `stripOriginComment`），agent 的 `linenum.js` 不剥 →
用户看到的第N行和喂给模型的第N行错位 +1，语音编辑「改第3行」改错行。

## 决定

1. **style 版本改为 per-article 字段** `articles[i].style = N`（整数）。
   不放 doc 顶层：换风格重写产生新 version，undo/redo 在版本间移动 head，
   style 必须跟着版本内容走；`versions[].articles` 是唯一随版本走、又被
   `withTopLevelArticles`/history 端点透传给 iOS 的载体。
2. **前置改造：per-article 层从白名单重建改成继承+覆盖**（`{...a, title, body}`）。
   tools.js 5 处（write_article / edit_current_article / 换图×2 / 插图+回退）
   之前只保 `{title, body}` + 手搬 `wechatMediaId`，任何新字段会在第一次编辑时
   静默丢失。改完后 per-article 层加字段零成本（doc 顶层 writeArticleDoc 的
   `...rest` 本来就保留一切）。
3. **写入方换字段**：miner.js 两处 tagging（restyle:813、正常挖矿:1115）从
   `prependStyleComment` 改为 `{...a, style: v}`；`style-store.js` 删掉
   `styleComment`/`prependStyleComment`（保留 `styleLabel`）。
4. **linenum.js 防御性剥注释**：编号前剥 `<!--…-->`（镜像 iOS），万一注释再混进
   body，编号不再错位；编辑回写时注释自然消失（自清洁，迁移后注释无意义）。
5. **iOS**：`MinedArticle` 加 `style: Int?`；chip（`currentStyleLabel/V`）和
   `existingVersion(forStyle:)` 先读字段、读不到回退读 body 注释（兼容期）；
   `stripOriginComment` 留着当保险。
6. **存量迁移（一次性）**：临时迁移 worker（`agent/scripts/migrate-style-field/`）
   经 `wrangler dev --remote` 绑生产 R2 直跑（不部署、不需要 FILES_TOKEN）：
   扫全部 `users/*/articles/*.json`，对每个 version 的每篇：注释→`style` 字段、
   body 去注释。迁移前先 `/dump` 全量备份到本地。幂等。

## 不做 / 已知边界

- write_article 整篇重写时旧字段按 index 对位（wechatMediaId 既有语义），
  拆/并文章时 style 可能错位 → 后果只是 chip 显示旧版本号，接受。
- 风格介绍文（style-intro）今天就没有 tag，维持无 `style` 字段。
- iOS 老 build 迁移后读不到注释 → chip 暂时消失，等 TestFlight 更新，接受。
- legacy 数字图片标记越界时 iOS 跳行不计数、linenum.js 计数——另一个罕见的
  编号分歧，本次不修，记入 STATE.md。
- v1 老 doc（顶层 title/body）早于 style 功能，迁移跳过。

## 部署顺序

agent worker 先部（停写注释）→ 立刻迁移（dry→real）→ iOS push main 出 TestFlight。
两侧 npm test / xcodebuild 过了才部署；迁移后用 wjs-voicedrop 读真实文章抽查。

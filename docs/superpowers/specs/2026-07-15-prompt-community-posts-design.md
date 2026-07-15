# 提示词社区帖 —— 分享即发帖 + 社区「提示词」筛选 tab

日期：2026-07-15
状态：已与用户对齐，待实施
前置：2026-07-11 prompt-share-magic-number-design.md（魔法数字）、2026-07-13 prompt-manager-redesign.md（ref/fork 模型）
两仓库：jianshuo.dev（服务端）+ voicedrop（iOS）

## 0. 一句话

开「分享这条提示词」开关 = 铸 7 位码 **+ 自动发一个社区帖**；社区瀑布流混排提示词帖，
tab 栏在「回应」后面加「提示词」筛选；帖内可一键导入、投币、用文章回应。
关开关 = 帖与码同死；再开 = 同码同帖复活。

用户动机（原话大意）：提示词是社区非常重要的内容，应该给更多曝光让大家用起来，
否则社区没有活力、信息不够。

## 1. 拍板的产品决策

| 问题 | 决策 |
|---|---|
| 混排 or 专区 | **混排 + 筛选**：提示词帖进推荐/最新流拿曝光，「提示词」tab 是过滤器 |
| 匿名用户 | **和社区发帖同一道门槛**：翻分享开关提示注册/登录（403 needs_apple_signin），登录后铸码+发帖一气呵成。匿名不再能铸码（行为收紧，用户拍板） |
| 帖内动作 | 一键导入、投币、文章回应。未选：突出展示 importCount |
| 关分享语义 | **同生同死**：关开关 = 码失效 + 撤帖；再开 = 同码同帖复活。社区侧「取消分享」也反向同死（连码一起关） |
| 存量 | **不回填**。只有新的「开分享」动作发帖；存量用户关一下再开即进社区 |

## 2. 数据模型

### 2.1 社区帖新变体（R2 真源）

`community/<shareId>.json`：

```json
{ "schema": 2, "shareId": "<12位>", "owner": "users/<sub>/",
  "kind": "prompt", "promptCode": "<7位码>",
  "author": "<铸码时名字>", "firstSharedAt": 1730000000000,
  "replyTo": "<可选>" }
```

- **不复制内容**。正文实时读 `shares/<码>`（写穿副本）——作者改提示词 →
  已有的 `refreshPromptShare` 保存时同步副本 → 帖子自然跟新。
  与文章帖（articleKey 指针实时读原文章）同一个模式。
- 没有 `kind` 字段 = 文章帖（全部存量），读侧以 `kind === "prompt"` 分支。

### 2.2 shareId 派生

`shareId = shareIdFor("promptshare:<码>", SESSION_SECRET)`（复用文章帖的 HMAC 派生函数，
输入换成码）。**从码派生、不从 itemId 派生**：

- 码一辈子不变（含 fork re-key：rekeyForkedShares 只挪 byItem 的 key，码不动）→
  同码同帖复活、fork 后帖不断，全部自动成立；
- 不需要在 `prompt-shares.json` 里存任何新绑定字段。

### 2.3 D1 展示索引

migration `reco/migrations/0003_community_posts_kind.sql`：

```sql
ALTER TABLE community_posts ADD COLUMN kind TEXT NOT NULL DEFAULT 'article';
```

提示词帖的行：`title` = label，`preview` = 提示词正文前 60 字（同 cardExtras 清洗口径），
`has_photo` = 0，`cover_photo_key` = NULL，`article_count` = 1，`kind` = 'prompt'。

## 3. 服务端流程（jianshuo.dev repo）

### 3.1 POST /agent/prompt-share（开分享）——改

1. **身份收紧**：resolveUserScope 之后再验身份来源——匿名 token（anonScopeFromToken
   命中而非 verifySession）返回 `403 {error:"needs_apple_signin"}`。与社区发帖同一个
   错误码：iOS 弹登录 sheet、MCP 的 BY_CODE 翻译，全部现成复用。
2. **审核**：铸码前对 `label + "\n" + instruction` 跑 `checkArticlesShareable`
   （Pages lib，agent worker 已有 `../../functions/lib/*` import 先例）。flagged →
   `403 {error:"content_flagged"}`，不铸码不发帖。
3. 铸码/复活逻辑照旧（幂等同码、日上限、maxLength）。
4. **发帖**：写 `community/<shareId>.json`（kind:"prompt"）+ upsert D1 索引行。
   author = `readProfileName(env, scope)`（与文章帖同源）。firstSharedAt 若帖已存在
   （复活）则保留原值。
5. 响应加 `communityShareId` 字段。

### 3.2 DELETE /agent/prompt-share/<itemId>（关分享）——改

删 `shares/<码>`（现状）+ 删 `community/<shareId>.json` + 删 D1 行。

### 3.3 社区侧取消分享（Pages community/unshare）——改

对 `kind === "prompt"` 的帖：撤帖之外**连 `shares/<码>` 一起删**（同生同死的反方向）。
owner 校验照旧（只能撤自己的）。提示词编辑页开关的状态读数（shareStates 按
`shares/<码>` head 判断）因此自动归位为「未分享」。

### 3.4 community/get ——改（老 App 兼容的关键）

`kind === "prompt"` 的帖返回合成形状：

```json
{ "shareId": "...", "owner": "...", "author": "...", "kind": "prompt",
  "promptCode": "<7位码>", "appliesTo": ["text"],
  "articles": [{ "title": "<label>", "body": "<提示词全文>" }] }
```

- 老版本 App 不认识 `kind`，按普通文字帖渲染：可读全文、可投币、可回应，
  只是没有导入按钮。零崩溃降级。
- `shares/<码>` 已不存在（码关了但帖还在的漂移态）→ 404 + 顺手清帖清索引
  （对齐 liveDocForPointer 的孤儿自愈风格）。
- 顺手 upsert D1（自愈，与文章帖同）。

### 3.5 reconcileIndex ——改

`community/*.json` 里 `kind === "prompt"` 的：从 `shares/<码>` 读内容 → upsert
（title=label，preview=正文前 60 字）；`shares/<码>` 已失效 → 删帖删行（同 3.4 自愈）。

### 3.6 reco worker ——改

`feed` 与 `rank` 的 SELECT / 响应带出 `kind` 字段。混排排序不区分 kind
（提示词帖与文章帖同池参与推荐/时间序）。

### 3.7 agent worker 配置

wrangler 配置加 `RECO_DB` binding（voicedrop-reco 同库）——发帖/撤帖即时写索引，
不等对账。写失败一律吞掉（与 Pages 侧 indexUpsert 同纪律：绝不打断主路径）。

### 3.8 MCP

零逻辑改动（发帖在服务端 handler 内，share_prompt 自动获得）。只改
`share_prompt` / `unshare_prompt` 的 description：说明会自动发/撤社区帖、
需要 Apple/微信登录。

## 4. iOS（voicedrop repo）

### 4.1 CommunityFeedView

- tab：推荐 / 最新 / 回应 / **提示词**。前三个行为不变（混排含提示词帖）；
  「提示词」= 当前列表按 `kind == "prompt"` 过滤（客户端过滤，不加新端点）。
- `CommunityPost` model 加 `kind` 字段（缺省 "article"，向后兼容解码）。
- 提示词卡：沿用文字帖三色暖渐变封面（按 shareId hash 取色，现成），
  左上角加「提示词」小角标胶囊区分形态。标题 = label，预览 = preview。

### 4.2 CommunityPostView

`kind == "prompt"` 时：

- 正文区显示完整提示词文本（从 community/get 合成的 articles[0].body 拿，零新请求）。
- 主 CTA「收下这条提示词」→ `POST /agent/prompts/import {code}`（PromptStore
  已有网络层）→ 成功 toast「已加入你的提示词」，长按菜单立即可见；重复导入
  = 再存一份副本（服务端语义如此，不做去重拦截）。
- 投币、文章回应照旧（按 shareId，机器全复用）。
- 自己的提示词帖不显示导入按钮（owner == 自己）。

### 4.3 PromptEditView 分享开关

- 文案「分享这条提示词」→ 「分享到社区」，说明文字明示：开了会公开发到社区 +
  得到 7 位码短链。
- 匿名用户翻开关 → 403 needs_apple_signin → 弹登录引导（复用社区现有处理路径），
  登录成功后重试开关动作。

## 5. 测试

- **agent**（jianshuo.dev）：prompt-share.test.js 扩展——开分享发帖（R2 帖形状 +
  D1 行）、匿名 403、审核拦截不铸码、关分享撤帖、再开同码同帖复活、
  firstSharedAt 保留、D1 写失败不打断主路径。
- **Pages**：community/get 合成形状（老 App 兼容契约）、码失效自愈 404、
  unshare 提示词帖连码同死、reconcileIndex 收编/清理提示词帖、list 快路径带 kind。
- **reco**：feed/rank 透传 kind。
- **iOS**：CommunityPost 解码缺省 kind、提示词过滤逻辑单测；真机手测清单——
  ① 开分享 → 社区立见（推荐/最新/提示词 tab 三处）② 导入全链路（含另一账号）
  ③ 投币/回应 ④ 关开关 → 帖码同消 ⑤ 再开 → 同码复活 ⑥ 匿名翻开关 → 登录引导
  ⑦ 老版本 App 打开提示词帖当文字帖可读。

## 6. 已知边界（有意不做）

- **删除提示词条目不自动关分享**：帖与码冻结在删除前内容——与现状码的行为一致，
  本次不改。
- importCount 不在帖内突出展示（用户未选）。
- 存量分享不回填。
- 推荐算法不为提示词帖做加权/降权，同池混排。
- 中文数字码、原生提示词帖搜索等仍属更远期。

## 7. 部署顺序

1. D1 migration（加列，DEFAULT 'article'，存量行零影响）。
2. reco worker（feed 带 kind——先于写入方上线，字段多出来老 App 忽略）。
3. agent worker（发帖逻辑 + RECO_DB binding）与 Pages（get/unshare/reconcile）
   ——注意 voicedrop-agent 部署纪律：先合 origin/main 再 wrangler deploy。
4. iOS（tab + 导入 CTA + 开关文案），随下一班 TestFlight。

服务端先行完全安全：老 App 看到的提示词帖是普通文字帖（3.4 合成形状兜底）。

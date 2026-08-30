# 一生一次领 320 算力（写一本书）— 设计定稿

日期：2026-08-30 · 状态：已批准，开做

## 目标

在 `voicedrop.cn/book/` 放一个落地页：读者点一下就能领到 **320 算力**——正好是
写一本书的一口价（`BOOK_SUANLI`）——领完在 App 里直接写。**一个真人一生只能领一次。**

## 约束（用户定稿）

1. 领取在 **App 内**完成，网页只是宣传页 + deep link 入口。
2. 只有 **绑过 Apple / 微信** 的账号能领（跟投币同一道 `hasVerifiedBinding` 闸门）。
3. **一生一次**，不是每周一次。
4. **不许加新表**——用现有表结构承载。

## 为什么必须挂实名闸门

匿名身份是客户端自己生成随机串换来的（`anon_…` → sha256 → scope），没有注册这一步。
代码里写死过一条防线：

> 「这同时就是写书的准入门槛：伪造随机 token 的新账户只有 200 注册赠送，不够一本书。」

一个无闸门的「白领 320」等于把这条防线整个拆掉：脚本刷随机 token 就能无限白写书。
挂上 `hasVerifiedBinding` 之后，一次领取必须对应一个真实 Apple ID 或微信号。

`identities` 表是 **first-write-wins**，登录只读它找回既有 scope ⇒ 同一个 Apple ID /
微信号一辈子对应同一个 scope ⇒ 「换手机再领一次」不成立。这是「一生一次」成立的根据。

## 数据层：零新表，用 `mint`

一次领取 = `mint` 表一行：

| 列 | 值 | 说明 |
|---|---|---|
| `kind` | `'claim'` | 表头注释本就写着留给未来玩法（已有 `feed` / `referral` 先例） |
| `subject_key` | `'book320'` | 活动 id |
| `actor_sub` / `beneficiary_sub` | 领取人 scope | |
| `coins_uc` / `price_uy` / `actor_uy` / `beneficiary_uy` | **全 0** | 见下 |
| `detail` | `{"suanli":320}` | 真实发放额的审计快照 |

唯一索引 `idx_mint_once (kind, subject_key, actor_sub)` 就是「一人一生一次」的执行层：
原子、防连点、防并发、防重放。

**金额列必须填 0**，这是正确性要求不是偷懒：

- 币价分母 `sumCoins7d` = `SUM(coins_uc) WHERE ts>7d`，**无 kind 过滤** → `coins_uc>0`
  会拉低金币价格。
- 投币日熔断 = `SUM(actor_uy+beneficiary_uy) WHERE ts>=day0`，**无 kind 过滤** →
  记真金额的话，31 个人领一次就把投币熔断（320 算力≈13.9e6uy，闸线 5×日池≈434e6uy）。

**顺带修一个既有 bug**：`mintLedger` 的「今日」那条 SQL 同样漏了 kind 过滤，
现在 `kind='referral'` 的行已经在虚增后台铸币榜的今日事件数。补上 `AND kind='feed'`。

钱照旧走 `grantBucket(scope, suanliToUY(320), 'campaign:book320', now+90d, ...)`：
账单页现成地把 `campaign:*` 归成「活动赠送」，App 一行不用改。

**写入顺序定死**（照抄 mint/referral 的铁律）：先 `INSERT OR IGNORE` 抢唯一键，
`changes===1` 才付钱。极小概率「事件已记、grant 前崩」= 少发一笔，可由 mint 行与
ledger 对账补发，与既有 known-limitation 同级。

## 接口

新模块 `agent/src/claim.js`，由 `handleUsageRoute` 分发（mint.js 的同款薄壳结构）。

### `GET /agent/usage/claim`
不需要实名，给页面/App 决定按钮长什么样：

```json
{ "campaign": "book320", "suanli": 320, "claimed": false,
  "eligible": false, "reason": "needs_apple_signin", "suanli_balance": 200 }
```

### `POST /agent/usage/claim`
- 无 token → 401 `unauthorized`
- 未绑定实名 → 403 `needs_apple_signin`（安卓 `needs_wechat_signin`，看 `X-VD-Platform`，
  与投币同一约定，App 已会弹登录再重试）
- 已领过 → 200 `{ok:true, already:true, granted_suanli:0, suanli:<余额>}`
- 成功 → 200 `{ok:true, granted_suanli:320, suanli:<新余额>, expires_at:<ms>}`
- `env.USAGE` 不可用 → 503

## 网页 `voicedrop.cn/book/`

文件 `~/code/jianshuo.dev/voicedrop/book/index.html`（EO 去前缀后即 `voicedrop.cn/book/`）。
浅色静态页，沿用现有 voicedrop 页风格。主按钮 `voicedrop://claim?c=book320`：

- 装了 App → 直接拉起 App 的领取页
- 没装 App → JS 超时兜底跳下载引导（iOS App Store / `voicedrop.cn/apk/`）
- 微信内 → 沿用 apk 页已有的「右上角···在浏览器打开」蒙层（微信拦 deep link）

英文镜像 `/en/book/` 交给现有夜间同步，不手写。

## iOS

- 新 deep link `voicedrop://claim`，挂在已有 `voicedrop://usage|books|settings` 的同一处分发。
- 落到轻量确认页：说明 320=一本书 → 「领取」→ `POST /agent/usage/claim` → 到账后直接推到写书入口。
- 未绑定 → 复用现成登录弹窗流程，登录后自动重试。
- 单测：deep link 解析 + 领取状态机（纯逻辑，不打网络）。

## 成本敞口

一生一次 ⇒ 总敞口 = 真实身份数 × ¥13.9。**暂不加全站上限**；真要加可以直接
`SELECT COUNT(*) FROM mint WHERE kind='claim'`，仍然零新表。

注册赠送 200 + 领 320 = 520，写完一本书剩 200。

## 测试

- `agent/test/claim.test.js`：401 / 未绑定 403 / 首次成功发 320 且 mint 记一行 /
  重复领 already 且不二次发钱 / 并发只发一次 / 金额列全 0 不影响币价与熔断 / GET 状态。
- `agent/npm test` 全绿；iOS `xcodebuild test` 改动前后各跑一遍。

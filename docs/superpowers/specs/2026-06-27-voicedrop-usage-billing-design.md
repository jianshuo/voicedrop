# VoiceDrop 算力计费(usage / billing)· 技术 Spec

> 2026-06-27 · 给 VoiceDrop 加一套**用量记账**:每个用户一个「算力」账户,处理录音 / 语音编辑时
> 按真实成本扣算力,扣到 0 停;新用户一次性送 500 算力,后续靠活动补充。
>
> **本期只做"赠送的虚拟算力 + 记账 + 余额闸"。不做收钱充值、不做退款、不做提现、不碰真钱。**
> 收钱是将来单独立项的事(带支付通道 + 法务),不在本 spec。

---

## 0. 范围与原则

- **算力 = 成本穿了件马甲。** 算力是一个**赠送的虚拟单位**,锚定真实成本:**23 算力 = ¥1**(1 算力 ≈ ¥0.043)。
  用户看到的是算力,底层真账本用**微元(1 微元 = 1e-6 元)整数**存,算力 / 元都只是显示投影。
- **无现金价值。** 算力是赠品,**不可提现、不可退款、不可转移**。这一条把"记账风险 + 退款风险"从根上切掉
  —— 账上挂的不是用户的钱,是一笔营销负债。
- **正余额倒扣到 0。** 给用户看的是正数余额,扣到 0 就停;底层真实成本是一直累加的流水,余额 = 送的额度 − 真实成本。
- **公开透明。** 每个用户能看自己的余额 + 消费明细(折算真实成本);运营有一个看全量的 admin 视图。
- **平价透传,绝不亏。** 显示算力 = 真实成本 × 23,不赚钱。成本换算用**钉死的保守汇率 + 向上取整(ceil)**,
  保证四舍五入只会多收一丝、绝不少收。
- **失败开放(fail-open)。** 计费 D1 挂了 → **放行**录音 / 编辑,记一条 lapse,**绝不因为"计费表坏了"挡住用户**。
  成本本来就小,产品体验 > 这几分钱。(这是和 reco「失败回退」一致的哲学。)
- **持久财务数据,独立库。** 用**独立 D1 库 `voicedrop-usage`**,**绝不**进 reco 的 `engagement` 表 / reco 库
  (reco 是可丢弃 sidecar,计费不能挂在可丢弃的东西上)。延续 STATE.md 既定决策。

## 1. 落点:绑在 agent worker 上(不另起 worker)

和 reco 不同 —— reco 是**可随时拔掉**的旁挂 sidecar,所以独立成 worker;**计费必须和"产生成本的地方"
紧耦合**,而所有花钱的动作(火山 ASR + Claude)都发生在 **agent worker(`voicedrop-agent`)** 里:

```
                       voicedrop-agent (现有 Worker)
   ┌────────────────────────────────────────────────────────────┐
   │  Miner DO (miner.js)      ── ASR + Claude 挖文章 ──┐         │
   │  ArticleEditor DO (index) ── Claude 语音编辑 ──────┤ 在写    │
   │                                                    ├ llmlogs │
   │                                                    │ 同一点  │
   │                          ┌─────────────────────────▼──────┐ │
   │   usage.js / usage_store ─┤ 记账 debit · 发放 grant · 余额闸 ├─┤
   │                          └──────────────┬──────────────────┘ │
   │   读接口 /agent/usage/*  ←───────────────┘                    │
   └───────────────────────────────────┬────────────────────────┘
                                        │  binding: USAGE
                                   ┌────▼─────────────┐
                                   │ D1 voicedrop-usage│ (新建, agent worker 私有)
                                   └───────────────────┘
```

- **新 D1 `voicedrop-usage`**,binding 名 `USAGE`,绑在 agent worker(`agent/wrangler.jsonc`)。
- 记账 / 发放 / 余额闸全在 agent worker 内联,**在写 `llmlogs/` 的同一点**顺手 UPSERT(STATE.md 既定)。
- 读接口也由 agent worker 出(它有 D1 binding + 已能验 token):`jianshuo.dev/agent/usage/*`。
  app 直连(app→worker 是外部请求,不踩 Pages→worker 的同区 fetch 坑)。
- 部署:仍是 `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`(无新增 worker)。

## 2. 计价(单一真源 `agent/src/usage.js`)

所有价格 / 汇率 / 锚定率集中在一处,纯函数,可单测:

```javascript
// ── 单一真源:改价只改这里 ──
const FX = 7.3;          // USD→RMB,钉死的保守值(略高=只会多收,不会亏)
const RATE = 23;         // 算力 / 元(23 算力 = ¥1),钉死
const SIGNUP_GRANT_UY = yuanToUY(500 / RATE);   // 新用户一次性额度 = 500 算力 的微元值

const PRICE = {          // USD / token
  'claude-sonnet-4-6': { in: 3 / 1e6,  out: 15 / 1e6 },
  'claude-haiku-4-5':  { in: 1 / 1e6,  out: 5 / 1e6  },
};
const ASR_RMB_PER_HOUR = 0.8;   // 火山录音文件识别(大模型版若不同,只改此处)

// ── 成本 → 微元(整数,ceil 不亏)──
const yuanToUY = (y) => Math.ceil(y * 1e6);
function claudeCostUY(model, inTok, outTok) {
  const p = PRICE[model];
  if (!p) return 0;                       // 未知模型不计费(宁可漏,不可错扣)
  const usd = inTok * p.in + outTok * p.out;
  return Math.ceil(usd * FX * 1e6);
}
function asrCostUY(seconds) {
  return Math.ceil((seconds / 3600) * ASR_RMB_PER_HOUR * 1e6);
}

// ── 微元 → 显示(算力 / 元)──
const uyToSuanli = (uy) => uy * RATE / 1e6;   // 微元 → 算力
const uyToYuan   = (uy) => uy / 1e6;          // 微元 → 元
```

> **为什么微元不是算力做底层单位**:钱是基准、算力是马甲。微元让"真实成本(元)"永远精确,
> 算力是乘个常数的投影;将来若真要结算 / 对账,单位本来就是钱。锚定率钉死,所以两者恒等价。

实测手感(本批数据,FX≈7.2 跑的;7.3 会高 ~1.4%):一条典型录音 ≈ **2 算力**,
haiku 改一刀 ≈ **1.4 算力**,sonnet 改一刀 ≈ **4 算力**,500 算力 ≈ 277 条录音 / 中位用户 5~6 个月。

## 3. 数据模型(D1 `voicedrop-usage`,两张表)

标准记账:`account` 是快表(余额 + 累计,供快速读 / 闸门),`ledger` 是**只追加**的流水(审计 / 账单 / 透明)。

```sql
-- 账户快表:每用户一行
CREATE TABLE account (
  user_sub   TEXT PRIMARY KEY,           -- "users/anon-<hash>/"(= token 解析出的 scope)
  balance_uy INTEGER NOT NULL DEFAULT 0, -- 当前余额,微元(可短暂为负:最后一笔允许透支,见 §6)
  granted_uy INTEGER NOT NULL DEFAULT 0, -- 累计获得(微元)
  spent_uy   INTEGER NOT NULL DEFAULT 0, -- 累计消费(微元)
  created_at INTEGER NOT NULL,           -- ms
  updated_at INTEGER NOT NULL
);

-- 流水:每一笔发放(grant)/ 消费(spend)都留痕
CREATE TABLE ledger (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_sub   TEXT NOT NULL,
  ts         INTEGER NOT NULL,           -- ms
  kind       TEXT NOT NULL,              -- 'grant' | 'spend'
  amount_uy  INTEGER NOT NULL,           -- 微元;grant 为正,spend 为正(用 kind 区分方向)
  reason     TEXT NOT NULL,              -- grant: 'signup'|'campaign:<id>'  spend: 'mine'|'edit'|'asr'
  detail     TEXT,                       -- JSON: {model,in_tok,out_tok,asr_sec,stem,turn_id}
  balance_uy INTEGER NOT NULL            -- 记账后余额快照(对账锚点)
);
CREATE INDEX idx_ledger_user ON ledger(user_sub, ts);
```

- **balance = account.balance_uy**(去规范化的快值),每笔 ledger 写入时**同事务**更新 account。
- ledger 是真源;account 坏了能从 ledger 重算(`SUM(grant) − SUM(spend)`)。
- 建库一次性:
  ```bash
  cd ~/code/jianshuo.dev/agent
  npx wrangler d1 create voicedrop-usage      # database_id 填进 agent/wrangler.jsonc 的 USAGE binding
  npx wrangler d1 execute voicedrop-usage --remote --file=migrations/0001_usage.sql
  ```
  迁移文件 `agent/migrations/0001_usage.sql` 入 repo。

## 4. 发放(grant)

- **新用户一次性 500 算力 —— 懒创建。** 匿名用户没有显式注册事件,所以**第一次任意 usage 操作
  触到一个没有 account 行的 user_sub** 时,创建 account 并落第一笔 `grant/signup`(= `SIGNUP_GRANT_UY`)。
  `ensureAccount(user_sub)` 幂等:已存在则什么都不做。**不自动续期**(不是 /月)。
- **活动补充(送算力)。** admin 原语 `POST /agent/usage/grant`(auth = `FILES_TOKEN`):
  `{user_sub | "all", suanli, reason}` → 落 `grant/campaign:<reason>`。签到 / 邀请 / 节日送都在这个原语上搭,
  本期只做原语,不做活动逻辑。
- grant 落账后:若该用户有因 `no-credit` 被挡的录音(§6),顺手 kick 一次 mine 让它们复活。

## 5. 记账(debit)—— 在写 llmlogs 的同一点扣

每个花钱的动作完成后,**紧挨着写 llmlog 的地方**落一笔 `spend`:

| 触发点(agent worker) | reason | 金额 | detail |
|---|---|---|---|
| `miner.js` 每次 Claude 挖文章调用后 | `mine` | `claudeCostUY(model,in,out)` | `{model,in_tok,out_tok,stem,turn_id}` |
| `miner.js` ASR 完成后 | `asr` | `asrCostUY(sec)` | `{asr_sec,stem}` —— **sec 用 ASR 返回的真实 `audio_info.duration`**,缺失再退回文件名时长 |
| `index.js` ArticleEditor 每次 Claude 编辑后 | `edit` | `claudeCostUY(model,in,out)` | `{model,in_tok,out_tok,stem}` |

`debit(user_sub, amount_uy, reason, detail)`:一个事务里 `UPDATE account SET balance_uy-=…, spent_uy+=…` + `INSERT ledger`。
**best-effort**:扣账失败(D1 错)只记 lapse,不回滚已经做完的挖 / 改(钱小,产品优先)。

## 6. 余额闸(gating)—— 扣到 0 就停

闸门在**动手前**查 `balance_uy > 0`;允许**最后一笔透支**(查的时候 >0 就放行,做完即使扣成微负也认),
下一笔自然被挡。所以单条永远能跑完,不会做一半被砍。

- **挖文章(Miner DO)**:处理某条录音前 `ensureAccount` + 查余额。
  - 余额 > 0 → 正常挖。
  - 余额 ≤ 0 → 写 `users/<sub>/articles/<stem>.blocked` `{status:"blocked",reason:"no-credit"}`,**不挖**。
    app 显示徽标 **余额不足**;音频保留。`no-credit` 的 `.blocked` **非终态**:用户拿到新算力后,
    miner 下次运行重判余额 > 0 → 删 `.blocked` 重挖(§4 grant 后 kick)。
- **语音编辑(ArticleEditor DO)**:收到编辑指令先查余额 ≤ 0 → 拒绝,回 `{error:"no-credit"}`,
  app 在编辑 UI 提示「算力不足,无法继续编辑」。

> **失败开放**:查余额时 D1 不可达 → 当作放行(记 lapse),不挡用户。

## 7. 防滥用硬闸(独立于余额)

挡的是"变态用法",和余额是两层(余额是花钱闸,这俩是物理闸):

- **单条录音 ≤ 3 小时**:app 端录音到 3h 自动停;miner 防御性兜底——时长 > 3h 的音频写
  `.blocked {reason:"too-long"}`(**终态**,不重试),不送 ASR。
- **单篇语音编辑 ≤ 100 次**:ArticleEditor 处理前数该 `(user_sub, stem)` 的编辑数
  (`SELECT COUNT(*) FROM ledger WHERE user_sub=? AND reason='edit' AND json_extract(detail,'$.stem')=?`),
  ≥ 100 → 拒绝,提示「这篇已达编辑上限」。

> 这俩是兜底:¥10 量级的余额其实会**先**到顶(一条 3h 录音光 ASR ≈ 55 算力、100 次 sonnet 编辑 ≈ 390 算力),
> 硬闸只拦"上传 10 小时文件"这种极端。

## 8. 读接口 + 公开透明

agent worker 新增路由(auth:任意有效 token 解析出 `user_sub`,复用现有验证):

- `GET /agent/usage/balance` → `{suanli, yuan, granted_suanli, spent_suanli}`(`ensureAccount` 懒建 + 首充 500)。
- `GET /agent/usage/ledger?limit=50` → 最近流水 `[{ts,kind,reason,suanli,yuan,detail}]`(给 app 的"明细")。
- `POST /agent/usage/grant`(**admin** `FILES_TOKEN`)→ 发放(§4)。
- `GET /agent/usage/admin/accounts`(**admin**)→ 全量账户 `{user_sub,balance,granted,spent}`,供运营总览。

**透明面**:
- **app 内**:每个用户看自己的余额 + 明细(满足"自己的成本一目了然")。
- **admin**:`voicedrop/admin/usage.html`(仿 `mine.html`/`llm.html`),读 admin 接口,看全量余额 / 消费 / 流水。
- 「**全量公开账本**」(所有人看所有人)涉及隐私,**本期不做**,留作日后决策(§14)。

## 9. iOS(`VoiceDropApp/`)

加法为主,核心流程不动:

- **设置页 账户区**(`SettingsView.swift`)新增一行:**算力余额 N · 查看明细 ›**;
  点进去 = 新页 `UsageView.swift`:大字余额 + 「这是什么」说明(算力 = 你的免费额度,无现金价值)+ 明细列表
  (每行 `−X 算力 · 录音/编辑 · 时间`,可切换显示折合 ¥)。数据走 `/agent/usage/balance` + `/ledger`。
- **录音列表**(`Library.swift`/`LibraryView.swift`)识别新标记 `.blocked`:
  - `reason:no-credit` → 徽标 **余额不足**(点 → 说明 + 将来的活动 / 充值入口占位)。
  - `reason:too-long` → 徽标 **录音过长**。
  - 即 `LibraryStore` 的状态机加一个 `blocked(reason)`,与现有 待处理/听录音/挖文章/已成文/无语音 并列。
- **语音编辑**(`RecordingDetailView.swift` / `AgentSession.swift`):收到 `no-credit` / 编辑上限错误 →
  在 mic 指示器处提示对应文案,停止该次编辑。
- 新增 Swift 文件记得 `xcodegen generate`(CLAUDE.md)。

## 10. 测试(`agent/test/`)

- **纯函数(`usage.js`,无 I/O)**:`claudeCostUY` / `asrCostUY` / `uyToSuanli` —— 已知 token→已知微元、
  ceil 不亏、未知模型返回 0;锚定率 23、汇率 7.3 的数值快照。
- **store(fake D1)**:`ensureAccount` 幂等且只首充一次;`debit` 同事务更新 account + 落 ledger;
  `grant` 累加;余额从 ledger 可重算;编辑计数正确。
- **闸门逻辑**:余额 >0 放行、≤0 挡;最后一笔透支允许、再下一笔被挡;fail-open(D1 抛错→放行 + lapse)。
- **回归**:改动前后按 CLAUDE.md 跑 `cd ~/code/jianshuo.dev/agent && npm test`,确认 miner / agent / 路由不回归。

## 11. 部署 / 上线顺序

1. `agent/migrations/0001_usage.sql` + `wrangler d1 create voicedrop-usage` → 填 binding `USAGE` 进 `agent/wrangler.jsonc`。
2. `npx wrangler d1 execute voicedrop-usage --remote --file=migrations/0001_usage.sql`。
3. 加 `agent/src/usage.js` + `usage_store.js` + 测试 → `npm test` 绿。
4. 接线:`miner.js`(debit + 余额闸 + `.blocked`)、`index.js`(编辑闸 + debit + 编辑上限 + `/usage/*` 路由)。
5. `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`。
6. `voicedrop/admin/usage.html` 部署(随 Pages)。
7. iOS:`UsageView` + 设置入口 + `.blocked` 徽标 + 编辑错误提示;`xcodegen` → push `main` → TestFlight。
8. **次序安全**:worker 先上,老 app 不读 `/usage` 也无害(用户照常用,只是看不到余额);
   余额闸一上线即对所有人生效(新用户首充 500,老用户首次触达也懒建首充 500)。

## 12. 明确不做(YAGNI)

- ❌ **收钱 / 充值 / 支付通道**(将来单独 spec + 法务)。
- ❌ **退款 / 提现 / 转移 / 把钱打给用户**(算力无现金价值)。
- ❌ **全量公开账本**(所有人看所有人)—— 隐私,留待决策。
- ❌ 月度自动续额度(只新用户一次性 + 活动;不做 /月 reset)。
- ❌ 浮动锚定率 / 多币种 / 阶梯价 / 折扣券到期逻辑(本期锚死 23、平价透传)。
- ❌ 把用量塞进 reco / engagement(独立库,持久财务数据)。
- ❌ prompt-caching / haiku 降本本身(那是 miner/agent 的优化,另开;本 spec 只如实按当时成本扣)。

## 13. 起步参数(都在 `usage.js`,可调)

| 参数 | 值 | 含义 |
|---|---|---|
| `RATE` | 23 | 算力 / 元(23 算力 = ¥1),钉死 |
| `FX` | 7.3 | USD→RMB,保守钉死 |
| `SIGNUP_GRANT` | 500 算力 | 新用户一次性 |
| `ASR_RMB_PER_HOUR` | 0.8 | 火山 ASR(大模型版若不同改此处) |
| 录音上限 | 3 小时 | 超 → `.blocked too-long`(终态) |
| 单篇编辑上限 | 100 次 | 超 → 拒绝 |
| 余额闸阈值 | `> 0` | 允许最后一笔透支 |
| 计费失败策略 | fail-open | D1 挂 → 放行 + lapse |

---

## 附:与最初四条诉求的对应

| 最初说的 | 本设计 |
|---|---|
| 定期给每个用户发账单 | app 内「算力明细」+ admin 全量视图(随时可看,不必"定期推送") |
| 消费金额从账户陆续自动扣费 | §5 在每次 ASR / Claude 后实时 debit |
| ~~定期结算,把账户里的钱打给用户~~ | **删除**(算力是赠送虚拟单位,无现金价值,无款可打) |
| 账户余额和成本一目了然、公开透明 | §8:用户看自己、admin 看全量;算力可一键折回真实 ¥ |

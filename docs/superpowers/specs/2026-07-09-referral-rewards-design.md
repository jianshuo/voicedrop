# 邀请奖励（分享带新装，算力入账）— design

日期：2026-07-09 · 状态：已批准（对话中逐点定稿）

## 问题

App Store 安装归因天然断链：新用户点朋友分享的文章链接 → 落地页 → App Store →
装好后从主屏打开，没有任何机制知道他是谁带来的。要给「带来新安装的作者」发奖励，
必须自己做归因；业界（Branch/AppsFlyer）的指纹匹配方案是黑盒且贵。

产品事实：VoiceDrop 的分享链接（`shares/<id>`、社区帖 `community/<id>.json`）
服务端本来就带 owner——**用户每次正常分享文章就已经在发邀请链接**，不需要发明
新的「邀请链接」。缺的只是：新装设备上的归因 + 入账。

## 决定

### 1. 归因 = 三层漏斗，静默优先，逐级降级（口令不做）

新账号首次启动后 24h 内，按顺序取第一个命中，**一次入账终身封笔（first-touch）**：

1. **Universal link 回点**（确定归因）：新用户 24h 内点任何分享链接拉起 App →
   token 在手 → claim。需要 AASA + associated domains（见 §5）。
2. **IP 指纹**（静默概率归因）：落地页每次被访问，Pages 在 R2 记
   `refhits/<ipHash>-<ts>`（值 `{owner, token, ts}`，ipHash = HMAC(SESSION_SECRET, ip)，
   不存明文 IP；R2 lifecycle 2 天过期）。App 首启向 worker hello，worker 用
   `CF-Connecting-IP` 反查 24h 窗口——**唯一 owner 匹配才发**，同 IP 多个 owner
   候选（CGNAT/办公网）直接放弃，宁漏不错。
3. **剪贴板兜底**（唯一会弹窗的层）：前两层都未归因时才碰剪贴板，且分两步：
   先 `UIPasteboard.detectPatterns`（probableWebURL，不弹窗）静默探测，疑似有
   URL 才真正读取（此时才出系统粘贴弹窗，文案包装成「检测到朋友的邀请，领取算力」），
   读到我们的分享 URL → claim。剪贴板没 URL 时用户全程零弹窗。
   落地页「下载」按钮的点击 handler（用户手势，微信内可写）把分享 URL 写入剪贴板。

### 2. 判新 + 防刷

- **判新用服务端时间，不信客户端**：账号出生时间 = D1 账本 `signup` 授予行的 ts
  （无行则本次 claim 视为出生并写入）。出生 < 24h 才可归因。
- **DeviceCheck 防重装刷币**：claim 必须带 `DCDevice.generateToken()`；worker 调
  Apple DeviceCheck API（.p8 key，新增 worker secret）query 两个 bit，bit0 已置 →
  拒发；发放成功后置 bit0。跨删除重装持久；模拟器无 DeviceCheck 天然挡掉。
- 每账号一生只归因一次（D1 `referrals` 表按 sub 唯一）。
- owner == 新账号自己（同 sub）不发。
- **owner 每日封顶 10 个被奖励安装**（R2 config 可调），超出照常归因但不发币。
- 误归因（自然新用户碰巧点了别人链接）接受，视作营销预算。

### 3. 奖励 = 按币记价，入账时刻实时汇率折算力，并入投币铸币经济

- 面额：**作者 12 币、新用户 6 币**，存 R2 `config/referral.json`
  `{enabled, authorCoins, newUserCoins, dailyCapPerOwner}` 零部署可调。
- **入账时刻定价**（不是分享时刻——分享链接寿命长，锁分享价要给每条 share 盖汇率戳
  且可被囤链套利）：复用 `mint.js` 池子公式
  `payout_uy = coins_uc × POOL_7D_UY ÷ (SEED + 近7天铸币 + 本次)`，邀请铸币**计入
  7 天分母、共享 FUSE_MULT 熔断**——邀请越火单价自动跌，总支出被池子天然封顶。
  冷启动顶满价 200 算力/币（作者一单 ≈2400 算力），是已知且接受的早期红利。
- 账本 reason 新增 `referral_author`（邀请奖励）/ `referral_new`（受邀赠送），进
  `REASON_ZH`；过期走 `CAMPAIGN_EXPIRE_DAYS = 90` 天（白送的钱不留永久负债）。

### 4. 落地页（`functions/voicedrop/[token].js`）

- 底部常驻 CTA 条：「这篇文章由 VoiceDrop 口述生成 · 下载 App，你约得 X 算力，
  作者约得 Y 算力」+ App Store 按钮。按钮点击时写剪贴板（§1.3）。
- **数字按访问时刻现算，带「约」字**（链接本身不带数字；访问→入账通常隔分钟级，
  误差最小）：worker 每次铸币后把当前价写 R2 `config/mint-rate.json`
  `{suanliPerCoin, updatedAt}`，Pages 直接读同一 FILES bucket（不跨服务调用，
  避开 CF 同 zone fetch 坑）；读不到 → 显示不带数字的通用文案兜底。
- 每次渲染顺手写 refhits（§1.2）。`?s=` 分节参数、og tags 等现有行为不动。

### 5. Universal links（AASA）

- `jianshuo.dev/.well-known/apple-app-site-association`（Pages 静态文件，
  Content-Type application/json、无重定向）：`applinks` 匹配 `/voicedrop/*`。
  appID = `<TEAMID>.com.wangjianshuo.VoiceDrop`（TEAMID 实现时从 fastlane 取）。
- **voicedrop.cn 同样要出 AASA**：腾讯云反代需透传 `/.well-known/`（实现时验证，
  必要时改 `infra/voicedrop-cn` 配置）。
- iOS entitlements（project.yml / xcodegen）：`applinks:jianshuo.dev` +
  `applinks:voicedrop.cn`。
- App 侧 `NSUserActivity` 处理 → 解析 token → claim。沿用「深链不打断录音」规则。

### 6. API / 数据形态

- **`POST /agent/referral/claim`**（agent worker，用户 bearer）：
  body `{source: "link"|"clipboard"|"hello", token?, deviceCheckToken}`。
  worker：解 scope → 判新（§2）→ 已归因/DeviceCheck bit 置位 → 幂等返回 →
  解析 owner（token 走 `shares/<id>` / `community/<id>.json`；hello 走 refhits
  IP 反查）→ owner≠self + 日封顶 → 双侧铸币入账 → D1 `referrals` 记
  `{sub PK, owner, source, token, ts}` + DeviceCheck 置位。
  返回 `{attributed, suanli?}` 供 App 提示「获得约 X 算力」。
- refhits：R2 `refhits/<ipHash>-<ts>`（§1.2），lifecycle 2 天。
- 汇率发布：R2 `config/mint-rate.json`（§4）。

### 7. iOS

- `ReferralManager`：首启（anon token 就绪后）→ hello claim → 未归因 →
  detectPatterns → 读剪贴板 → claim；universal link 到达随时 claim（24h 内）。
- DeviceCheck token 生成；入账成功 toast + 账单页自然显示中文 reason。

## 不做 / 已知边界

- 口令输入不做（太繁琐）；公众号文末带链接不做（污染正文，暂缓）。
- 主动「邀请好友」入口 / 作者主页页（`/voicedrop/u/<token>`）二期再议——
  一期只吃现有分享流量。
- 微信内置浏览器拦 universal link / App Store 跳转：接受，剪贴板层就是为它兜底。
- CGNAT 下 IP 多候选不发：接受（宁漏不错）。
- 老 build 无归因能力：接受，等 TestFlight 更新。
- 分母里邀请铸币和投币铸币互相压价：**故意的**，一个经济体一套价格。

## 部署顺序

Pages 先上（AASA + refhits + CTA，对老 App 无害）→ agent worker（claim + 铸币 +
rate 发布，跑 `npm test`）→ voicedrop.cn 透传验证 → iOS（entitlements + 归因序列，
xcodebuild 过）push main 出 TestFlight。上线后用 wjs-voicedrop 造一次真实分享→
新模拟器装机走一遍三层归因冒烟。

# VoiceDrop — changelog（倒序，最新在最上面）

从 STATE.md 拆出的逐日改动流水（2026-07-26 拆分；此前流水混在 STATE.md 前 960 行，把架构章节挤到了第 969 行之后）。稳定的架构 / 契约 / R2 layout 见 [STATE.md](STATE.md)。新流水往本文件顶部（本段之下）插。

## 写书引擎改成三腿降级链：kimi → codex → claude（2026-09-02）

承上条同日：写书从**单腿**改成**三条腿的降级链**，一条腿用不了就自动换下一条，
三条全倒才算失败（照旧退款 + 管理员告警）。顺序由用户定：`kimi → codex → claude`
（`BOOK_LEGS` 可改）。改的是 `~/code/jianshuo.dev/claude-agent/src/`。

**起因**：9/2 上午 7 单在 11 分钟内涌进来（两个用户各一次点三本），把 Kimi 的
5 小时滚动配额打穿——08:24–09:37 之间 **9 本书全灭**，每本都跑了几十轮才倒在
403 上，用户白等一场；而同机的 Codex（ChatGPT 订阅）和 Claude 订阅整段时间闲着。

**三条腿其实早就有了**，缺的只是调度：`runClaudeExec(inject=true)`=Kimi、
`runClaudeExec(inject=false)`=Claude 订阅、`runCodexExec`=Codex。新的 `runBookEngine`
串起来，每倒一条腿问一句「**这条腿用不了，还是这本书写坏了**」：
- **用不了**（配额满 / 凭据失效）→ 换下一条腿重跑；
- **写坏了**（撞轮数上限、崩溃、超时、Kimi 内容风控 high risk）→ 直接认输，
  换腿只会再烧一份别人的配额重蹈覆辙。

判别抽在 `src/book-legs.ts`（`shouldTryNextLeg`），错误串全部抄自事故当天的真实
日志，**9 条 node --test 单测**锁死（本仓此前没有测试，顺手加了 `npm test`）。
判别宁可宽松：漏判=退回「一条腿倒下全线瘫痪」的老样子，误判=多花一条腿重跑，
前者伤用户、后者只费自己的额度。

⚠️ **先修了一个会让整条链失灵的 bug**：`runClaudeExec` 的 catch 用笼统的
「Claude Code process exited with code 1」**覆盖掉**了已经识别出的具体错误——
9/2 日志里的配额 403 就是这么被盖掉的。不修的话 `shouldTryNextLeg` 看到的是一句
没有配额字样的空话，永远判 false，链等于没写。现在 catch 只在 error 为空时才填。

**换腿=整本重跑**（各腿会话不互通），所以第二条腿起的 prompt 追一句 `RESUME_HINT`：
先查工作目录有没有半成品，有就接着写完、**不要另起一本新书也不要换 slug**。
前一腿烧掉的轮数收不回来，这是换腿的固有代价。

**顺带删掉**旧的「每 6 小时前 N 本走 Claude 订阅」取号机制（`takeBookSlot` /
`BOOK_CLAUDE_FIRST_N` / `bookrate.json`）与 `BOOK_ENGINE` 开关：取号是**开跑前猜**
哪条腿有额度，链是**倒下后换**一条真有额度的——后者不需要猜。VPS `.env` 里那两行
已成死配置，不再被读取。

**部署注意**：`deploy.sh` 会 `systemctl restart`，**正在跑的书会被杀掉**。依赖没变时
可以拆成「先 rsync dist（不影响运行中的进程）→ 等空窗再单独 restart」，把停机窗口
压到一次秒级重启（本次就是这么上的线，当时有 3 本书在跑）。

## 写书降价 320 → 160 只改了代码没部署，线上多扣了 12 本书的钱（2026-09-02）

用户报「界面写扣 160，实际扣了 320」。**属实，而且不是扣两次，是线上根本没降过价**。
9/1 的降价提交（jianshuo.dev `19bc522`）合进了 main，但 **voicedrop-agent 这个
Worker 一直没部署**——线上跑的还是旧代码，一口价照扣 320。

取证两条：①`GET /agent/usage/prices` 线上返回 `not-found`——这个价目端点正是降价
那次新增的，线上没有它 = 那次改动没上线；②D1 账本里每笔 `book` 都扣
**13,913,043 微元**，而 `suanliToUY(320)=13,913,043`、`suanliToUY(160)=6,956,522`；
同期 `book-revise` 扣 1,739,130 = `suanliToUY(40)` 对得上，说明换算没毛病，就是
写书那个价还是 320。

**界面为什么显示 160**：`Prices.swift` 的 `fallback = Table(book: 160,…)`。App 去拉
价目端点吃了 404 → `merge` 返回 nil → 一路用兜底 160 显示。于是显示端和扣费端
**各写死各的、谁也不知道谁**——这才是「后端出口」那次改造没做完的那一半。

处置：部署 Worker（`prices` 已返回 160）；9/1 00:00 起被多扣的 **5 个用户 / 12 笔 /
1920 算力**（≈¥83.5）全额退回，365 天有效期，账本 `campaign:book-overcharge-refund`
对账 1920 分毫不差。

**契约新增**：`POST /agent/usage/grant` 加可选 `push:{title,body,link}`——发放的同时
给本人发 APNs。运营补偿/退款如果不吭声，用户只能自己去账本里发现，等于没退。
返回体多一个 `pushed` 布尔（推送失败不影响发放已成事实）。本次 5 人 4 送达，
1 个没 push token（没装 App / 从网页写的书）。

⚠️ **给未来 agent 的教训**：这类「改了常量但没部署」是完全无声的——测试全绿、
代码 review 也看不出。`/agent/usage/prices` 现在正好可以当探针：改完价先
`curl` 一下线上，对不上就是没部署。别忘了 `~/code/jianshuo.dev/agent` 是**手动**
`npx wrangler deploy`，不跟着 git push 走。

## 订阅加高档 ¥199/月 → 2000 算力 + 写书页升档 upsell（2026-08-30）

承上条：付费死角补成「不再是死胡同」之后，真正能卖的货也补上了——同一订阅组
加高档 `sub.monthly_199`（¥199/月 → 2000 算力，与主档 ¥19.9/200 同倍率）。
**iOS 从「写死单档」改成档位表**：`StoreService.tiers`（id → 每月算力，与服务端
`SUB_PRODUCTS` 对齐）、`productsByID` 一次拉全档、`purchase(_ id:)` 买指定档、
`Transaction.updates`/`currentEntitlements` 认所有档位（原来只认主档，升档后的
交易会被漏掉）、status 多解 `product_id` → `activeProductID`/`upgradeTier`。
**upsell 时机**（纯函数 `BookWritingSheet.upsellTier`，9 条测试锁死）：①订着主档
且当月烧光 → 推升档（再买同一档 StoreKit 只回「你已订阅」，升档是唯一能再花钱
的路）；②还没订且缺口 > 主档 200（写一本书 320）→ 越级直推高档，别让人订完
才发现还是写不成。三个否决项：售卖开关关着、已在顶档、商品苹果拉不到
（ASC 没建/没过审 → 绝不摆一个点了必败的按钮）。价格一律 `displayPrice`。
**ASC**（API 全程）：商品 6806785013 建全四件套（双语本地化/175 地区可售/
CHN ¥199 基准等价铺价——USA $29.99、JPN ¥5000/审核截图复用同一付费页/reviewNote），
新档 groupLevel=1、旧档降为 2（同级=交叉切换要等下个周期，升级才立即按比例
补差价），已 `subscriptionSubmissions` 提审 → WAITING_FOR_REVIEW。
⚠️ 中国区**没有 ¥199.99 这个价格点**（阶梯 …198/199/200/203…），取 ¥199。
iOS 205 条 + 服务端 1403 条全绿。

## 写书页付费死角：订着且当月烧光的人看不到任何购买入口（2026-08-30）

现场报「算力不够时以前有购买选项，现在没了」。查下来**代码一行没删**，是
`showSubscribePath = store.enabled && !store.active` 把它挡了：当初的理由是
「订着的人每月已在自动到账，再卖是骚扰」，但漏了**订着、且当月 200 已烧光**
这一档——付费的路整条消失，只剩加油/邀请。线上取证：`/agent/iap/status` 返回
`{active:true, enabled:true, sub_suanli:0, monthly_suanli:200}`，余额 188.2 <
书价 320，正好卡死在这个洞里。
补法：新增 `showSubscribedDryPath = store.active && store.subSuanli <= 0`，
这一档给第三条来路——「你的包月算力本月已用完（每月 N）」+ 续费日期（拿不到
就不编）+「管理订阅」按钮（系统 `manageSubscriptionsSheet`，升档/续费在那做）；
「两条/三条来路」文案跟着算。顺带把服务端一直在返回、客户端却丢掉的
`sub_suanli` / `monthly_suanli` 接进 StoreService。
**注意这补的是「不再是死胡同」，不是「现在就能买到算力」**：商品表里只有
`SUB_PRODUCTS = {monthly_19_9: 200}` 一个自动续期订阅，没有一次性加油包
（consumable），已订户不能重复买同一订阅（StoreKit 只回「你已订阅」）。要让
当月烧光的人真能掏钱补算力，得新建消耗型商品：ASC 建档 + iap.js 发放逻辑 +
客户端购买 UI + 过审。定价待定，未做。全量 196 条测试绿。

## 书架卡顿修复：书多了每 7 秒冻 2 秒（2026-08-30）

书架打开约 7 秒后整屏卡死 1-2 秒，滚一屏后再犯。三处叠加，逐个拆掉：
① **无条件重建**——`BooksShelfStore.load()` 原来无条件 `books = 解码结果`，
即便书单一字未变，`@Observable` 也判定变化，整棵视图树重建（每格含渐变 ×2、
Canvas 页口纹理、双层阴影），几十本在一帧内重排就是那 1-2 秒；改成
`if fresh != books` 才赋值（ShelfBook 本就 Equatable，零成本）。
② **VStack 全量构建**——屏外的书也全建，且每本 CoverImage 立刻起一个 .task
拉封面；换 `LazyVStack`，滚到哪建到哪。
③ **主线程解码封面**——`UIImage(data:)` 只包壳，JPEG 真解码拖到主线程首次
渲染那刻，几十张同时到齐即冻屏；改 ImageIO `CGImageSourceCreateThumbnailAtIndex`
（maxPixelSize 640，配格宽 ~170pt 的 Retina 余量）在后台线程降采样并
`ShouldCacheImmediately` 预解码，主线程只画现成像素。
**没有加分页**：`/books/?format=json` 是服务端一次性返回全量的单个 JSON，
分页要连服务端一起改；而瓶颈在渲染不在传输（几百本也就几十 KB），LazyVStack
已解决。书量涨到上千本再议服务端分页。全量 196 条测试绿。

## 写书：没设名字先弹一次署名输入框（2026-08-30）

BookWritingSheet 提交时若 profile.name **确认为空**（进场随余额一并 GET
/style 拉到且为空），先弹原生 alert 输入框问作者名：填了就 PUT /style
{name} 存进他名下（与设置页同端点，埋点「写书补署名」）再提交；留空确认
= 明确不署名，照常开写且本次 sheet 不再拦（nameAsked 标记防死循环）；取消
则不提交。名字已设置或 /style 拉不到（网络失败/没登录）都不打扰——与旧行
为一致，服务端有啥署啥。判定抽成纯函数 shouldAskAuthorName（只有 loadedName
== "" 才问），BookAuthorNamePromptTests 3 条锁契约；全量测试绿。

## 评分弹窗时机升级：峰值触发 + 四道闸门（2026-08-28）

ReviewPrompter 从「第 3/10/30 次打开文章 2 秒后弹」升级为峰值时机系统：
① 文章触发改为**停留满 10 秒**才弹（正在读自己的作品），提前离开由
articleClosed 取消；② 新增**公众号推送成功**触发（1.5 秒后，openCount≥3
的留存闸）。四道闸门：会话出过错不弹（Uploader 失败路径打 noteError）、
60 天冷却、每 marketing 版本最多一次、系统 3 次/年硬限自兜底。决策抽成
纯函数 shouldFire，ReviewPrompterTests 5 条锁契约；193 测全绿。背景：
美区仅 1 条评分是增长体检的最薄弱环节，评分是搜索排名+转化的双重信号。

## 设置页新增语言切换（2026-08-28）

「其他」卡片加「语言」行（🌐）：跟随系统 / 简体中文 / English。实现走 iOS 标准
AppleLanguages 覆写（Prefs.appLanguage，""=跟随系统即清覆写键），重启 App 生效，
切换后弹一次提示。新字符串英文翻译已手写进 Localizable.xcstrings；语言名
「简体中文/English」用 verbatim 不参与本地化（语言名显示为它自己）。
AppLanguageTests 锁契约；188 测全绿。

## 修复同一录音双传成两篇文章的竞态（2026-08-28）

实锤案例：一段 2m49s 录音在服务端成了两个文档（`…-Fri-Morning` 00:52:05 /
`…-Fri-Morning-Chuo-Shinkawa` 00:52:07），各挖出一篇文章。根因：promote 先落
无地名正式名（立刻进 drain 扫描域，2026-08-26 防孤儿设计），再 await 地理编码
改富名；旧注释断言「改名会让在飞的上传失败」，但 BackgroundTransfer 的
URLSession 在任务创建时已拷走文件——旧名照样传成功、收尾 removeItem 静默失败，
富名文件又被当新录音再传一遍。修法：`RecordingPromoter.enrichHolds`（内存态
hold 集合），promote 落盘后挂住文件名、改富名结束放行，`Uploader.pendingFiles`
扫描跳过 hold 中文件。内存态是有意的：窗口期被杀→集合蒸发→下次启动按盘上现名
上传，最坏丢地名，录音 never lost、永不双传。新增 RecordingPromoterHoldTests
两条契约测试；187 测全绿。（本次只改客户端；服务端按时间戳主干查重的兜底另议。）

## 书卡点击补 view 埋点（2026-08-27）

书卡 onSelect 直接推 BookReaderView、不经帖子详情页，view/finish/like 三个埋点
全绕过——书帖在推荐排序里是零信号。现在 onSelect 书分支补 engage(view)。
服务端配套（jianshuo.dev commit ccbbf25）：reco engage 的 shareId 限长 32→64，
9 本长 slug 书（如 book-embodied-intelligence-humanoid-robots，42 字符）的互动
此前会被 400 拒。finish（读到底）与红心入口暂不做——红心是产品决策，等拍板。

## 书帖转正为一等社区帖 + 书卡不出「取消分享」（2026-08-27）

服务端（jianshuo.dev 仓 commit 24ff269）：书不再由 reco 在 feed 读时混入书架
JSON（9s 慢源+SWR 双层缓存整体废除），改为**写时登记**——lab 写书/修书收尾调
agent worker `POST /agent/book/community` 把书 upsert 进 community_posts
（share_id "book-<slug>"、kind "book"），存量 98 本已回填。书帖的赞/回应/推荐
排序自此与普通帖同权（旧路径永远显示 0 赞）。版本门槛只能在服务端做：reco feed
对 build<330 的客户端把 kind='book' 行整体滤掉。社区展示索引三处写入（文章/
提示词/书）收口到 functions/lib/community-index.js 一段代码。
本仓：书主人现在在自己的书卡上 mine==true——contextMenu 对 kind=="book" 不出
「取消分享」（书的下架走修书→hidden，unshare 会去删不存在的分享快照）。

## 写书页算力不够：第三条来路——订阅包月算力（2026-08-27）

BookWritingSheet 的「算力不够？」攒法卡在原有两条（请朋友加油 / 邀请安装）之外加第三条：
订阅包月算力（¥19.9/月 → 每月 200 算力，价格用 product.displayPrice 本地化），行内直接给
一键订阅按钮（复用 StoreService.purchase()，购买后刷新余额）。显示条件 = 服务端售卖开关
开着（store.enabled）且未订阅（!store.active）——开关关着或已订阅的人看到的仍是两条，
文案「两条/三条来路」随之切换。进场 loadNumbers() 先 store.refresh() 拿开关/订阅态/价格。

## VD社区书架：feed 混入全部书 + 点书卡进书架阅读页（2026-08-27）

服务端（jianshuo.dev 仓 reco worker）把公开书架 97 本书混进 `/reco/feed`（kind:"book"、
shareId "book-<slug>"、封面走 /photo/ 通道新放行的 `users/*/books/*/cover.jpg`），所有
用户可见。书列表接口 `/voicedrop/books/?format=json` 一次 ~9s，走 SWR：feed 绝不同步
等它，isolate 内存 + Cache API（同 colo 共享）双层缓存 10min——冷 colo 首刷无书、二刷
即有。本仓：社区瀑布流 onSelect 里书卡由卡片字段拼 ShelfBook 推入书架同款
BookReaderView（同一导航栈，back 回社区原位；首版曾用临时 SafariView sheet，同日
按用户反馈改为推栈），其余帖子路径不变。同日补通用版本头：`setBearer` 收口处
所有 API 请求统一带 `X-VD-Version` / `X-VD-Build`（ClientVersion，Networking.swift），
服务端按 build 门槛开功能——reco 只对 build ≥ 330（书卡首发版）混书，旧版看不到书、
不存在点开失败的过渡期；这套头以后任何按版本开闸的功能都复用。

## 线路改为只按 App Store 商店区域；竞速探测整体移除（2026-08-26）

`APIRoute` 重写：`Storefront.current.countryCode`（启动取一次，App Group 持久化
`api.route.storefront`）决定线路——CHN/取不到 → voicedrop.cn，其他区 → jianshuo.dev
直连。probe/probeIfDue/pick/measure、`api.route.host`、回前台复测、「线路探测」埋点、
APIRouteTests 全部删除（xcodegen 已重生成工程）；新埋点「商店区域」`{区域,线路}`。
前情：08-25 曾把商店区域做成竞速的冷启动默认，同日用户拍板改为唯一判定。
TestFlight/Xcode 直装均读设备登录商店账号的区域。185 单测全过。

## review 落地第一批：4.5 个 bug + 3 处收口（2026-08-26）

先对 2026-08-25 review 逐条核实（三路并行 agent 复核，结论：定量断言基本全对；
NotificationCenter「悬垂指针崩溃源」在现代 iOS 不成立（selector 版 zeroing weak）、
`monthly_19_9` 商品 ID 非问题（界面价格走 StoreKit displayPrice）、`wechatThumbMediaId`
不是死代码（往返保存字段，删了会抹服务端数据）——照 review 的死代码清单删码前先看这行）。
随后修复：

- **bug① 录音丢失窗口**：`RecordingPromoter.promote` 的 place 改闭包——文件先落
  无地名正式名（任何 await 之前），拿到地理标注再改富名；stop→promote 窗口内被杀
  只丢地名不丢录音。⚠️ review 说的「cleanupStaleStaging 启动误删」机制不成立——
  该函数**全仓零调用**，真实后果是 staging 孤儿永久滞留（队列/列表只认 `VoiceDrop-`
  前缀）。已把它改造成 `recoverStaleStaging`（启动调用，VoiceDropApp）：可播且
  ≥4s 的残片补升级进上传队列（救回历史孤儿），坏的删；mtime 5 分钟内的不碰
  （App Shortcut 可能一启动就在录）。
- **bug② 编辑 socket 永久断线**：`RecordingDetailView.onDisappear` 复位 `connected`。
  触发者是插图 `.fullScreenCover`（sheet 不触发 presenter 的 onDisappear），恰好
  插图接下来就要用这条 socket。
- **bug③ 库级命令冷启动丢 refs**：`LibraryCommandSession.connect()` 从 persisted
  `refsJSON` 回填 refs（此前只写不读），「把第二篇…」杀进程后不再失去指代。
- **bug④ unshare/report/屏蔽 只删 posts**：新增 `CommunityStore.removePostLocally/
  removeAuthorLocally` 统一出口（posts + timeOrdered + persistFeedCache——「最新」
  是默认 tab，其数据源是 timeOrdered）；**CommunityStore 单例化**（`CommunityStore.shared`，
  LibraryView/RecordingDetailView 共用），根治双实例互不知情。
- **bug⑤ 删号/换身份后推送断**：PushRegistrar 监听 `.vdDidAdoptAccount` →
  重新 `registerForRemoteNotifications()`，系统回调用新 bearer 重传 push-token。
- **commitEdit 失败回滚**：原位编辑保存失败时 `applyLocalArticles(oldArticles)` 回滚
  本地 doc（对齐 toggleCommunity 的失败恢复语义），不再「屏上改了、服务端没改」。
- **微信 errcode 文案单一真源**：`LibraryStore.wechatKnownError`（发布+凭据验证共用，
  含 40164/40013/40125/41002/41004 等），SettingsView 那份删除；40164 文案统一成
  白名单指引。
- **lab.jianshuo.dev 收口**：`API.bookAPIBase`（Networking.swift），BookWritingSheet/
  BookReviseSheet 三处硬编码改引用（该主机无国内镜像，不参与线路切换，但换域名只改一行）。

全量 191 条单测改动前后各跑一遍，均 pass。review 其余大项（API 样板迁移 72→11、
行号契约收敛、WS 会话合并、SuanliStore）未动，留待后续批次。

## 全仓只读架构审查（2026-08-25，无代码改动）

7 路并行模块 review（录音上传 / 详情编辑 / 社区 / 设置账户IAP / 提示词 / 会话WS / Share Ext+中继）
+ 全仓 grep 定量扫描，产出 [docs/review-2026-08-25.md](docs/review-2026-08-25.md)（所有结论带
file:line 证据）。**无代码改动**，纯文档。

核心结论（给未来 agent 的速记）：
- **网络样板半迁移**：`API.authed/get/send`（Networking.swift:165-198）只用了 11 处，全仓 70 处
  手写 `URLRequest+setBearer+JSONDecoder+isOK` 未迁（Library 16 / Community 13 / SettingsView 10 /
  PromptStore 8）。**新代码一律走 helper，存量逐步搬**（这是 2026-07-26 审查后没做完的活）。
- **正文行号/分段契约 4~5 份独立实现**（bodyRows / BodyDiff / MarkdownTextBlock / replacingLine /
  ExportManager），第N行计数 3 份——改行号规则要同步 3 处 + 服务端 prompt（{{LINE}}）。
- **WS 生命周期 4 套**（AgentSocket 收口了 Article/Library/Status；RealtimeSession / DeviceLink /
  SpeechDictation 没迁）；WS 帧解析 5 处裸字典零测试；Article/LibraryCommand 会话 ~85% 同构。
- **余额/邀请 5 处各自实现**（usage/balance ×3、referral/link ×2），无共享 store、无到账广播。
- **5 个待修 bug**：① promote 先 await 定位后移动文件 → staging 文件可能被启动清理误删（录音丢失）；
  ② RecordingDetailView `connected` 永不复位 → 盖 sheet 后编辑 socket 永久断线；③
  LibraryCommandSession 重启恢复丢 refs；④ Community unshare/report 乐观更新只删 posts 不动
  timeOrdered 且不持久化（双 CommunityStore 实例根因）；⑤ 删号换身份后 push-token 不补传。
- 测试失衡：191 条里 PromptStore 系占 51%；Library/Community/Uploader/WS 帧/Share Ext(9 文件零测试)/
  relay 主链 全无覆盖。

## 国内/海外线路自动切换：voicedrop.cn(EO) vs jianshuo.dev(CF) 竞速选线（2026-08-19）

用户要求：国内资源走 voicedrop.cn（腾讯 EdgeOne），海外直连 jianshuo.dev（Cloudflare），
不再让海外用户绕道中国。落地 = `Networking.swift` 新增 **`APIRoute`**：

- `API.host/photoHost` 变计算属性，读 `APIRoute.currentHost`；`filesBase/photoBase/
  agentBase/recoBase/agentLink` 全部随之动态。新增 `API.publicWebBase`
  （`voicedrop.cn/<path>` ≡ `jianshuo.dev/voicedrop/<path>` 的去前缀映射），书架
  JSON/封面/书页 WKWebView（`BooksShelfView`）与隐私政策链接（`UsageView`）改走它。
- 判定 = 并发 HEAD 两入口落地页竞速，快者胜；150ms 迟滞防抖；单边失败用活边、
  双边失败守现状（纯函数 `APIRoute.pick`，新测试 `APIRouteTests.swift` 6 例）。
- 时机 = App 冷启动必测 + 回前台 30 分钟节流（`VoiceDropApp.swift` `probeRoute`），
  PostHog 埋「线路探测」`{线路,切换,cn毫秒,cf毫秒}`。结果存 App Group
  UserDefaults `api.route.host`，Share Extension 免探测沿用；默认（从未探测）仍
  voicedrop.cn。`AppGroup.uploadBase` let→计算属性（防冻结）。
- 不切换的：分享页/邀请链接/微信 universalLink 恒 .cn（外发）；WS 与
  /cdn-cgi/image/ 缩略图恒 jianshuo.dev（原状）。
- 全量 191 条单测通过（xcodebuild test，iPhone 17 Pro 模拟器）。

## 1.12 首审被拒→补 EULA 链接重提（2026-08-19）

自动审核拒了：订阅类 App 的**元数据必须带用户协议（EULA）链接**。App 内订阅卡早就
链了 Apple 标准 EULA（stdeula），但 App 描述里没有。修法：两语言 description 末尾
追加订阅说明 + 标准 EULA 链接 + 隐私政策链接（本地 fastlane/metadata 与 ASC API
PATCH 双写，防 deliver 覆盖）。**重提坑**：元数据改完后版本卡在 REJECTED，直接
PATCH submitted 报「Version is not ready」且 20 分钟不自愈——解法照旧：cancel 提审
单 → 新建草稿 → 重挂三条目（appStoreVersion + subscriptionGroupVersion +
subscriptionVersion，id 都复用）→ submitted:true，即回 WAITING_FOR_REVIEW。

## 包月算力订阅开闸：售卖开关打开 + ASC 商品从空壳建全 + 1.12 提审（2026-08-18）

用户要求「打开付费开关让用户能买 ¥19.9/月 200 算力」。开关本身一分钟（R2 写
`config/iap.json` = `{"enabled":true}`，零部署即时生效，iOS 订阅卡随即显示——模拟器
实拍已验证）；但查 ASC 发现订阅商品 `monthly_19_9`（id 6791993826）还是 7-19 留下的
**空壳**（MISSING_METADATA：0 本地化/0 价格/无截图/无可用地区），光开开关用户根本
买不了。当天用 ASC API 全部补齐：

- **本地化**：zh-Hans「包月算力」+ en-US「Monthly Credits」（描述上限 55 字符，超长 409）。
- **价格**：CHN 有精确 ¥19.9 价格点；先建 `subscriptionAvailability`（全部 175 地区 +
  未来新地区），**再**建价格（顺序反了 subscriptionPrices 会 409 ENTITY_ERROR）；其余
  174 地区用该价格点的 `equalizations` 逐个 POST `subscriptionPrices`（API 无一键等价，
  ASC UI 的「自动等价」就是这 175 个 per-territory 价格）。
- **审核截图**：临时快照单测（app-hosted VoiceDropTests 里把 UsageView 挂窗口、等 8s
  真网络加载、drawHierarchy 渲染 PNG 直接写主机路径）实拍算力页付费墙，三步上传
  （POST 占位 → PUT 二进制 → PATCH checksum）。拍完测试文件即删。
- **审核备注** + 状态确认 **READY_TO_SUBMIT**（175/175 价格）。
- **1.12 提审**：首个订阅必须搭新版本（1.11 已 READY_FOR_SALE）。project.yml 垫到
  1.12、双语 release notes（订阅 + books 封面修复）、185 单测绿、push main 自动
  TestFlight（build 318 秒 VALID），dispatch `appstore` workflow 提审成功。
- **坑：deliver 提的审不带订阅**——提审单里只有版本条目，订阅停在 READY_TO_SUBMIT
  没进审；单发 `POST subscriptionSubmissions` 又被 409 FIRST_SUBSCRIPTION_MUST_BE_
  SUBMITTED_ON_VERSION 挡（首订阅必须与版本同单）。**解法（全 API，UI 免动手）**：
  cancel 提审 → 新建 reviewSubmission 草稿 → 挂 appStoreVersion 条目 →
  `POST /v1/subscriptionVersions` 给订阅拍送审快照（已存在则 409 里带现成 id）→
  再挂 `subscriptionGroupVersion` + `subscriptionVersion` 两个条目（2025+ 新增的
  item 类型，fastlane Spaceship 模型里没有）→ PATCH submitted:true。终态：订阅/
  订阅组/1.12 三者同单 WAITING_FOR_REVIEW。
- **仍需手工**（API 做不了）：ASC → App 信息 → App Store 服务器通知 V2 生产+沙盒 URL
  填 `https://jianshuo.dev/agent/iap/notifications`（没配的话续费发放走 App 启动时
  claim currentEntitlements 的兜底路径，功能不缺失但不实时）。

## 修书：写好的书在 App 里持续修改 + 每本书一条永久对话线（2026-08-15，全链已部署）

写书从「一锤子」变成「可持续对话」：读书页 ⋯ 菜单 → **「修改这本书」**，聊天式界面
——上面是这本书的永久历史（开书种子 + 每次修改指令 + agent 改完写的「修改说明」），
底部输入框提新指令，**每次 40 算力**。fire-and-forget（202 后可关 App），运行中每 6s
轮询；sheet 关掉后 WebView 换实例重载看新版。

- **服务端登记簿（谁能修 = 主人）**：lab VPS `bookmeta/<slug>.json` =
  `{slug,scope,author,createdAt,thread:[{ts,kind:create|revise,instruction,sessionId,
  status:running|done|failed,reply}]}`。创建时登记：`runBookJob` 把随机 jobId 塞进
  prompt 让 agent 写进 book.json，job 收尾拿 jobId 反查 slug 落盘（找不到落
  `_unmatched-` 供人工对号）；同时捕获 SDK session_id——完整过程 jsonl 永远可在
  lab 网页（密码门）`/api/sessions/<id>` 回看。存量 48 本书中署名「王建硕」的 9 本
  已手工登记到建硕 scope；无署名老书无法安全断定归属，**未登记 = 404 不能在线修**。
- **lab 新端点**：`POST /api/book/revise {slug,instruction}`（主人校验在扣费**前**：
  先 dry 探路拿 scope 比对，403 一分不扣；同书单飞 409）；`GET /api/book/history
  ?slug=`（主人可见对话线）。Caddy 豁免改成 `/api/book /api/book/*`。
- **修书 = fresh session + 文件真源，不 resume 写书旧 session**（子 agent 的正文
  本来就不在主对话里，背整段历史只多花钱）。skill 新增「修书模式」：工作目录
  `workspace/book-<slug>`（**写书约定同步从 /tmp 挪到 workspace**——PrivateTmp 重启
  即失）；缺目录用 `build.mjs pull` 从线上 `_src/` 源稿镜像重建（build.mjs 每次发布
  顺手镜像 book.json/章节片段/导读到 `books/<slug>/_src/`，书架统计只看顶层不受
  影响）；`_src` 之前的老书走「抓渲染页提取 `<article>`」手工重建。修完只发动过的
  章节，收尾输出 200 字内「修改说明」→ 即 thread 里的 reply。
- **worker**：book-charge 接受 `kind:"revise"` → 40 算力（`BOOK_REVISE_SUANLI`，
  usage.js），ledger reason `book-revise`（「修书」）带 slug。测试 +1 例（1372 绿）。
- **iOS**：`BookReviseSheet.swift`（对话线 + 输入框 + 402/403/404/409 文案），
  `BookThread/BookThreadEntry` 解码模型；`BookReviseThreadTests` +3 例（183 绿）。
  埋点「修书发起 / 修书已受理」、screen「修改书」。
- 上线自测：真实修书《散场之后》(entropy) 走「老书无 _src 手工重建」最难路径。

## 网页书架与 iOS 写书 tab 完全同款（2026-08-13）

`voicedrop.cn/books/` 的 HTML 书架重写成和 `BooksShelfView.swift` 一比一：暖纸底、
两本一排 + 木搁板、第一格写书入口（网页上链到 voicedrop.cn 落地页）、cover.jpg
铺图 / 布面缺省封面、书脊页口投影全套。代码在 jianshuo.dev
`functions/voicedrop/books/[[path]].js`（1bee57b），**两边样式改任何一边记得同步**。
数据侧 cover/chapters 并进 collectBooks 的同一次全量列举（原 indexJSON 的 head+
delimited list enrich 删了，R2 调用减半）。踩坑：grid 列必须 `minmax(0,1fr)`——
`1fr` 隐式 min-content 下限会被 nowrap 长书名撑破列宽，封面按 0.7 比例跟着变高，
同排两本高矮不一。

## 写书书架：时间倒序 + 每本书 ⋯ 分享菜单（2026-08-13）

- **书架顺序改为时间倒序，最新的书在最前**。排序在服务端
  （jianshuo.dev `functions/voicedrop/books/[[path]].js` 的 `collectBooks`）：每本书
  的诞生时间 = 书文件夹里**最早**的 R2 `uploaded`（index.html 会反复重发刷新时间戳，
  最早的文件基本不动，当创建时间最稳；同龄兜底按书名排保证稳定）。JSON 索引多了
  `createdAt`（epoch ms）字段；iOS/网页书架照单全收，零客户端排序逻辑。
- **读书页（BookReaderView）顶栏右上角加 ⋯ 菜单（仿 VD 社区文章页）**，目前一项
  「分享」：微信拿裸链接 `voicedrop.cn/books/<slug>/` 出富卡片（有 cover.jpg 时带上
  当缩略图），X/复制等拿「《书名》— 作者 + 链接」整段文字——复用社区的
  `SharePayload`/`ShareSheet` 通路。（首版曾放书架封面右上角，按反馈挪进阅读页顶栏。）
  `ShelfBook` 新增 `author: String?`（老 UserDefaults 缓存里没有，必须 optional
  否则解码失败丢缓存）。

## 文章专属封面 cover.jpg：列表行图标按书本 2:3 竖版优先显示（2026-08-13）

新约定：`users/<sub>/photos/<sessionTs>/cover.jpg` = 该文章的专属封面。与场景照片
同目录——公开 `/photo/<key>` 端点、PUT 上传路径、删录音连带清理全部零服务端改动。
key 真源 `RecordingName.coverKey(sessionTs:)`（挨着 photoKey）；`Recording.coverJpgKey`
从 stem 解析。显示侧只动了「文章」tab 的行图标（`RowCoverIcon`）：

- 优先探测 cover.jpg，存在 → **40×60（2:3 书本比例）**竖版缩略图；不存在 → 回退
  原有首图 42×42 方块 → 波形图标。已成文但无照片的行现在也会探测（原先直接波形）。
- 探测 miss 记**会话级内存负缓存**（不落盘，吸取「正在制作中卡死」URL 负缓存教训）——
  晚生成的封面下次冷启动自愈显示。PhotoService 的 thumbMissed 是按单 key 记的，
  cover.jpg 404 不会误伤全局缩图；失败响应本来就不落盘。
- ⚠️ **cover.jpg 按约定视为一次性写入**：PhotoService 磁盘缓存按 key 信一辈子，
  覆盖重写同 key 不会刷新已缓存设备。将来要换封面需换 key 或引入版本化。
- 生成侧还没有：谁来产出 cover.jpg（后处理流水线/手动上传）待定，显示侧已就绪。
- 社区卡片（cover_photo_key）与公开网页未动——它们仍用首图；要吃上 cover.jpg 需
  动 D1 索引 upsert（cardExtras），留作后续。
- 测试：`VoiceDropTests/RecordingCoverTests.swift`（4 条，XCTest——本仓测试统一
  XCTest，别用 swift-testing，`-only-testing` 会静默匹配不到）。

## 1.10 提交 App Store 审核（2026-08-12）

垫 MARKETING_VERSION 1.9→1.10（主 target 与 VoiceDropShare 扩展对齐，扩展此前一直落在 1.8），
双语 release notes 主打「写书」tab 与正文块级 Markdown 排版。流程照旧：单测 176 条全过 →
push main 出 TestFlight 构建 → dispatch `appstore` → `fastlane release skip_build:true`。
ASC 已确认 1.10 WAITING_FOR_REVIEW，`release/1.10` 标签已打。

## 正文块级 Markdown 渲染：#/## 标题、列表、引用、分隔线（2026-08-11 第三弹）

此前正文只走 `AttributedString(.inlineOnlyPreservingWhitespace)`——**粗体**、`代码`、
[链接] 能渲染，但 `#`/`##` 标题、`-` 列表、`1.` 有序列表、`>` 引用、`---` 分隔线
都原样露出符号。现在：

- **新增 `VoiceDropApp/MarkdownBlock.swift`**：`MarkdownBlock.classify` 按「一行一个
  block」分类（h1/h2/h3、bullet、ordered、quote、divider、plain），与 bodyRows 的
  第N行切分天然对齐。`####`–`######` 统一按 h3 渲染；`#话题`（井号后无空格）、
  4 位数字（年份）、`1.5` 这类不误判。有序列表认 `1.` / `1)` / `1、` 三种。
- **`MarkdownRowView`**：单行渲染视图，块级样式套行内 Markdown。标题用 inkRead
  加大加粗（22/19/17pt），列表加赭红 `•`/序号，引用左侧赭红竖条 + metaRead，
  分隔线细线。行内解析闭包可注入——文章页复用自己的 BodyParseCache。
- **接入三处**：`RecordingDetailView` 只读段落行（长按菜单/高亮/行号 overlay 全部
  不动）、`Community.swift` 社区帖两处正文（改用 `MarkdownTextBlock` 多行版，原
  局部 textAttributed 已删）。
- **编辑通道零改动**：键盘精修/语音编辑仍编辑原始 Markdown 文本（第N行编号、
  `replacingLine` 拼接都按原文走），渲染只是显示层的甜头。
- 测试：`VoiceDropTests/MarkdownBlockTests.swift` 24 条纯逻辑单测；全仓 176 条 pass。

## 写书页重设计：明码 320 + 攒算力指引 + 真实署名（2026-08-11 第二弹，全链已部署）

`BookWritingSheet` 推倒重排（入口不变 = 书架第一格）：

- **去掉公开书架入口行**——书架就是身后的「写书」tab，不再另给链接。
- **320 算力做成价签 hero**：琥珀底大字「⚡320 算力」+ 右侧实时余额（够=绿
  不够=红；`GET /agent/usage/balance`）。CTA =「开始写书 · 320 算力」，
  不够时变灰「算力不够 · 还差 X」。
- **算力不够 → 攒法卡紧跟价签**（第一眼要的是「怎么办」）：两条来路带现价
  数字——「请朋友给你的文章加油，一次约得 N 算力（约 x 次就够）」「邀请朋友
  装 VoiceDrop，装一个约得 M 算力（约 y 个就够）」+ ShareLink 直接发邀请
  链接。数字来自 **`GET /agent/referral/link` 新增的 `suanliFeedAuthor`**
  （作者侧 2 币×mint-rate 币价）与既有 `suanliInviter`；现价拿不到只说通用
  文案，绝不编数字。
- **流程简介 + 中心思想引导**：「怎么写成」四步卡（拆大纲→并行写→独立评审→
  上你的架）；种子输入改名「中心思想」，文案引导一句话说清要讲明白的问题/
  主张（也可贴整篇文章）。
- **真实署名（王建硕 → 提交者）**：lab `/api/book` 受理后用提交者 bearer 拉
  `CLAUDE.json` `profile.name`（设置页「名字」，挖文章署名同源）写进 skill
  提示词；skill `book.json.author` 不再默认王建硕，没名字整个不署。
  `build.mjs` 索引页新增 `<meta name="author">`；Pages 书架印章按作者出
  （中文 3 字去姓；存量无 author 的书归「建硕」），books JSON 加 `author`。
  `payload.author` 可显式覆盖（App 暂不传，lab 自取）。
- **book-charge dry 响应带 `need_suanli`**——价目字段两种结果同形。
- 部署：agent worker（1350 测试绿）+ Pages + lab VPS + VPS skill 全部上线；
  冒烟：加油现价 75、邀请现价 338、dry 返回 320/余额。iOS 153 单测绿，
  模拟器实拍两态（余额够 / 新账号 200 不够——差 120、约 2 次加油或 1 个
  邀请就够，与服务端数字一致）。

## 第三个 tab「写书」= 图书馆书架（2026-08-11，iOS + Pages 已部署）

设计稿 `Books.dc.html` ①（design 项目 claude.ai/design/p/834ad7a9…）。只落地
图书馆屏；新书设置/写作中/成书三屏没做——写书流程沿用现有 `BookWritingSheet`
fire-and-forget，读书沿用网页版。

- **iOS 新 tab**：`HomeTab` 加 `.books`，tab 头「我的录音 · VD社区 · **写书** ·
  <标签…>」；书架页 = 新文件 `BooksShelfView.swift`——实体书两本一排 + 木色
  搁板，**第一格固定是「写书」入口**（虚线封面 + 红加号）→ 弹现有
  `BookWritingSheet`；书封：有 cover.jpg 直接铺图（保留书脊/页口/投影），
  没有就布面缺省封面（宋体书名 + 细线 + 副题，颜色 = 服务端按 slug 哈希，
  和网页书架同色）。点一本书 → **原地推入 `BookReaderView`**（同一导航栈，
  像打开一篇文章）：暖纸顶栏（返回键 + 宋体书名）+ 内嵌 WKWebView 显示
  `voicedrop.cn/books/<slug>/`，章节跳转都在 WebView 里、左缘手势先退网页
  历史再 pop 回书架（初版曾是底部 Safari sheet，按用户要求同日改推入）。
  数据缓存在 UserDefaults，离线先画上次的书架。红色录音键在写书 tab 隐藏
  （第一格自己就是入口）。
- **tab 头自动滚动**：`tabHeader` 包 `ScrollViewReader`，选中的 tab 自动滚进
  可视区（英文 locale 下前两个 tab 很长，写书原本被截在屏幕外）。
- **设置页「实验功能 → 写书」入口撤销**（设计稿明确取消；`showBookWriting`
  状态与 sheet 一并删除，`BookWritingSheet` 文件保留由书架调用）。
- **深链**：`voicedrop://books`（alias `library`）+ universal link
  `voicedrop.cn/books`（书架根 → 原生 tab；`/books/<slug>` 单本书仍走 .web）。
- **服务端**（jianshuo.dev Pages，已部署）：书架函数
  `functions/voicedrop/books/[[path]].js` 加 **`GET /books/?format=json`** —
  `{books:[{slug,title,main,sub,c,c2,cover,chapters}]}`，与 HTML 书封同一个
  `collectBooks`（title 取 `<slug>/index.html` 的 `<title>`，main/sub 按
  ——／：／· 拆，c/c2 = slug 哈希配色）；另补 cover.jpg 存在性（head）和顶层
  章节数（`.html` 计数，index/intro 不算；单页书为 0，App 端回落显示副题）。
  60s 缓存 + CORS `*`。
- 验证：153 条单测改动前后全绿；模拟器深链 `voicedrop://books` 截图核对设计稿
  （入口格与书同高、搁板、章数 meta、tab 下划线）。

## 写书改计费制 + 挪到设置页（2026-08-10 第二弹，iOS + worker + lab 已部署）

- **限制全拆**：「每 scope 每天 2 本」「全局同时只写一本」「须有成文文章」三道闸
  全部移除——**算力就是闸门，每本书一口价 320 算力**。
- **agent worker 新路由 `POST /agent/usage/book-charge`**（user bearer）：余额
  < 320 → 402 `{error:"no-credit",need_suanli,suanli}` 不扣；够 → `debit` 记
  ledger reason `book`（reasonZH「写书」）返新余额；`{dry:true}` 只验不扣。
  常量 `BOOK_SUANLI=320`/`bookCostUY()`（usage.js）。伪造随机 token 的新账户
  只有 200 注册赠送 < 320，天然被 402 挡住——上一版的「查成文文章」门槛因此
  退役。测试 `agent/test/book-charge.test.js`（3 例，全套 1350 绿）。
- **lab `/api/book` 简化**：verify+quota 逻辑全删，换成转发 bearer 调
  book-charge——扣成功才 `runBookJob`，202 带 `{charged_suanli,suanli}`。
- **iOS**：「写书」行从「关于」页挪到**设置页新「实验功能」分组**（发布与其他
  之间），副标题标明「每本 320 算力」；sheet 文案加价格；402 显示「要 320、
  你有 N」并指去算力页；409/429 分支删除。
- 冒烟：真 token dry 200（余额 15707）；伪 token 402（200<320）；无 token 401。

## 关于页加「实验功能 → 写书」（2026-08-10，iOS + lab VPS 已部署）

「关于」页新增「实验功能」区 + 「写书」行 → `BookWritingSheet`（新文件
`BookWritingSheet.swift`）：

- **功能**：给一个词/一句话/一篇文章当种子，点「开写」→
  **lab.jianshuo.dev**（Tokyo VPS 常驻 Claude Agent SDK 服务）用
  **wjs-voicedrop-writing-book** skill 写一本书（大纲 agent → 每章并行写手 →
  独立评审 → 过稿一章发一章）。成书在公开书架 **https://voicedrop.cn/books/**
  （sheet 里有链接行 + 受理页大按钮）。
- **fire-and-forget 契约（lab 侧新端点 `POST /api/book`，同日部署）**：
  `{seed}`+bearer → 验完立刻 **202**，agent 在 VPS 进程里后台跑完整本书——
  **提交完就可以关 App**（区别于 /api/chat 的断线即中止）。同时只跑一本
  （1 核小机，`busy` → 409，App 提示等写完再来）。`{dry:true}` = 只验认证不起
  job（部署冒烟用）。`BOOK_MAX_TURNS` 默认 80。
- **认证零内置密钥**：App 带自己已有的 VoiceDrop 用户 bearer
  （`AuthStore.shared.bearer`）。⚠️ anon token 是客户端自造随机数，whoami 对
  任何格式正确的 token 都返回 scope——**whoami 只做归因不是门槛**（用户当场
  指出）。真门槛 = lab 同时拿 bearer 调 `GET /files/api/articles`，**该 scope
  必须已有成文文章**（伪造 token 散列出的 scope 永远是空的 → 401；真用户先
  录音成文才能写书）+ **每 scope 每天限 2 本**（`BOOK_DAILY_LIMIT`，进程内存
  计数 → 429）。Caddy 对 `/api/book` 路径豁免 basic_auth（`@needsauth not
  path /api/book`，Caddyfile 已备份 `.bak-20260810`）；`/api/chat` 网页聊天
  照旧密码门。
- 已冒烟：伪造随机 anon token → 401；有效用户（有文章）dry → 200 带 scope；
  /api/chat 仍 401。skill 在 VPS `/opt/claude-agent/.claude/skills/`；书架
  已在线（已有《钱不脏》《散场之后》两本）。
- 埋点：「写书发起」「写书已受理」。App 端 401/409/429 各有文案。125 条单测全绿。

## 使用手册改内置 sheet + admin/feedback 控制台页（2026-08-09 第二弹，iOS + Pages 已部署）

- **使用手册不再外跳网页**：设置「使用手册」行改开内置 `HelpManualSheet`
  （`HelpManualView.swift`）。`ManualParser`（纯逻辑、可单测）把 markdown 解析成
  块（#/##/### 标题、表格、代码块、-/数字列表、段落），SwiftUI 按 Theme 排版，
  行内加粗/链接走 `AttributedString(markdown:)`，顶部横滑章节 chips 用
  `ScrollViewReader` 跳转。内容 = bundle 资源 `Resources/HelpManual.md`
  （project.yml 新增 `Resources` 路径 `buildPhase: resources`）——**真源仍是
  jianshuo.dev repo `voicedrop/help/manual/manual.md`，网页版改了 cp 一份过来**。
  测试 `HelpManualParserTests.swift`（5 例，含真手册整本解析：8 章、表格在、无空段）。
- **admin/feedback 控制台页**（jianshuo.dev 仓，已部署）：
  `jianshuo.dev/voicedrop/admin/feedback`，照 llm.html 的 gate/换 token 模式，按日期
  下拉看当天全部反馈卡片（名字/scope/版本/时间/正文）。后端
  `GET /files/api/feedback/{dates,list?date=}`（admin-only 403，list 连内容一起返回、
  ts 倒序、坏 JSON 跳过；日期文件夹用 cursor 翻页的 listDateFolders，防截断坑）。
  全部控制台页导航加了「用户反馈」tab。测试 `agent/test/feedback-admin.test.js`（4 例）。

## 设置加「使用手册」+「意见反馈」（2026-08-09，iOS + worker 已部署）

设置「其他」卡在 数据与备份 和 关于 之间加两行：

- **使用手册**：`Link` 直开 https://voicedrop.cn/help/manual（外部 Safari，页面已在线 200）。
- **意见反馈**：`FeedbackSheet`（SettingsView.swift，照 NameEditSheet 模式：多行
  TextEditor + 占位文案 + 2000 字截断 + 发送成功打勾 1.2s 自动关 + 失败留言重试）。
  发送 = `SettingsStore.sendFeedback` → **`POST /agent/feedback`**（agent worker 新
  路由，jianshuo.dev 仓）：**身份以 bearer 为准**（服务端 resolveScope 解析 scope，
  客户端只附 name/version 展示字段），落 R2 `feedback/<YYYY-MM-DD>/<ts>-<rand>.json`
  存档 + `sendPush` 直推管理员（`env.ADMIN_SCOPE`）手机；同一 scope 60s 内只推第一
  条防轰炸（marker `ops/feedback-last/<sub>.json`），**存档不受节流影响，反馈永不丢**。
  空文本 400、无 token 401、文本截 2000 字。测试 `agent/test/feedback.test.js`（5 例，
  含身份来自 token 非客户端声称、节流仍存档）。worker 已部署并线上冒烟（401/200 +
  APNs 冒烟推送）。查看反馈：R2 `feedback/` 前缀按日期翻，或等手机推送。

## 用户报「重写失败」排查闭环：假 .jpg 图片 400 + remine 超时上调（2026-08-07，worker 已部署 + iOS）

用户报重写失败，怀疑「还有 15 秒 timeout」。排查结论（obs 拉 5 天全量 /agent/restyle 调用）：

- **今天的真凶不是超时**：08-07 06:19–06:52 UTC 一位用户连试 7 次 restyle 全部
  `exception 500`（3–7s 即死）。根因 = 照片 media_type 写死 `image/jpeg`
  （miner.js loadPhoto→buildMinePrompt / image-pipeline / edit-turn 三处），而
  .jpg 名下字节实为其他格式（安卓/相册导入），Anthropic 整个请求 400
  （"specified using the image/jpeg media type, but the image appears to be…"
  / "Could not process image"）→ 一张坏图拖垮整次重写，重试永远失败。
- **修复（jianshuo.dev 8433af6，worker 53d7c88c 已部署）**：新 `agent/src/image-type.js`
  按 magic bytes 嗅探 jpeg/png/gif/webp，三处接入；认不出的格式（HEIC 等）跳过该图
  （[[photo:key]] 标记照留，模型只是看不见）。测试 1338 绿（旧 fixture 假图字节补了
  JPEG 魔数）。线上 E2E：塞 PNG 假 .jpg 的 session 重写 200 ok（修前必 500）。
- **15s EO 回源超时已不存在**：上海腾讯云 VPS（49.235.147.96，可当大陆探针）走
  voicedrop.cn 实测 23s / **119s** 长重写都 200 返回。obs 里 `canceled ≈15.0s` 的
  批量掐断只出现在 08-02，08-03 起绝迹（EO 侧行为已变）。restyle 路由的
  `ctx.waitUntil` 保底（1008b09）继续留着。
- **iOS 残余风险**：列表页「重写」（remine）超时 120s，但 31min 录音重写实测
  119s、更长必假报「重写失败」（服务端其实会写成）→ 上调 300s 对齐详情页
  restyle。remine 无 WS preview-done 兜底（那是详情页专属），超 300s 仍会假报——
  known trade，等有真实反馈再做收尾对账。

## 社区默认排序改「最新」+ tab 行右侧加搜索（2026-08-07，iOS）

用户拍板：VD社区打开缺省落在「最新」tab（原「推荐」）；tab 行右侧（原空
`Spacer()` 位置）加放大镜入口。

- **默认 tab**：`CommunityFeedView.tab` 初值 `.reco` → `.latest`。推荐/回应 tab 本身不动。
- **搜索**：点放大镜 → 顶行原位切换成胶囊输入框 +「取消」（`searchRow`），**本地过滤**
  当前 tab 已加载列表的 标题/作者/预览 三字段（不打服务端，秒出结果；预览是
  community/list 下发的正文前 ~60 字，等于顺带搜了开头正文）。清空按钮、`@FocusState`
  自动弹键盘、取消即退出并清词。埋点 `社区搜索`（打开入口时记一次）。
- **过滤逻辑抽成纯函数** `CommunitySearch.filter(_:query:)`（`Community.swift`）：
  trim 后空查询原样返回；`localizedCaseInsensitiveContains` 匹配；nil 字段不匹配不崩。
  新增 `CommunitySearchTests` 9 例（空查询/三字段/大小写/nil/保序），全量 148 绿。
- 给未来 agent：搜索只覆盖**已加载**的帖子（feed 一次全量下发，现阶段等于全站）；
  以后帖子多到分页时要换服务端搜索端点。

## 录音上传改走 background URLSession：锁屏/杀进程系统续传（2026-08-04，iOS）

昨日解除照片串行后，根因还剩另一半：8-03 晚一条 22 秒/110KB 录音迟到 22 分钟，同
session 4 张 300-400KB 照片却在录完当秒全部传完、照片队列为空——堵的不是线路也不是
照片。真凶是**前台 `URLSession.shared` 的第一枪随挂起冻结**：录完立刻锁屏/装兜里，
bg assertion 只有 ~30s，第一次 PUT 没打完（或一次瞬时失败进了退避 sleep）就随进程
挂起冻结，之后没有任何机制再试，文件要等「下次打开 App」的 drain 触发点才补传。
实测 8/1–8/3 每条录音的「录完→R2 落地」延迟恰好等于下次打开 App 的间隔（22 分钟～
2 小时、8-02 一条 65KB 迟 124 分钟），与文件大小无关；本机对照 PUT 计时 EdgeOne
4-8s / CF 直连 2-3s，纯线路远够不到分钟级。

- **新增 `BackgroundTransfer.swift`**：唯一的 background session（identifier
  `com.wangjianshuo.VoiceDrop.upload`，`sessionSendsLaunchEvents`，resource 窗口 6h）。
  音频与 tags 边车的 PUT 都从这里走：锁屏/切后台/进程被杀，系统守护进程接管传完；
  完成事件在进程复活后回放。任务元数据在 `taskDescription`（`Job` JSON，存 Documents
  **相对**路径——容器绝对路径每次安装会变）；同一文件按 `taskByPath` 去重，并发入队
  挂到在飞任务上等同一结果（输家任务清 taskDescription 再 cancel，delegate 见 job=nil
  忽略）。收尾（删本地/keepLocal、清边车、乐观行、埋点）集中在 delegate →
  `Uploader.shared.finishAudioTransfer` **幂等**执行，进程死活两条路同一结果。
- **`Uploader` 单例化 + 瘦身**：进程内「3 次尝试+1.5s/3s 退避」与 `beginBG/endBG`
  全删（bg session 在 resource 窗口内自己等网自己重试）；服务器真拒绝（4xx/5xx）→
  文件留盘等下一次 drain 重新入队。`uploadTagsSidecar` 的前台 PUT 换成后台入队；
  音频成功时边车仍在飞则留给它自己的收尾删（成功即删，失败留一个无重试点的孤儿
  小文件，无害）。
- **接线**：`PushRegistrar.application(_:handleEventsForBackgroundURLSession:)` 存系统
  收尾回调；`VoiceDropApp.init` 调 `BackgroundTransfer.shared.activate()`（delegate 尽早
  就位才收得到上一条命的完成事件）；`LibraryView` 改用 `Uploader.shared`。
- **埋点口径 3**：`耗时秒`=入队→系统送达（**含挂起期**，即用户体感的「录完到传完」）；
  `排队秒` 沿用口径 2；`尝试次数` 恒 1（进程内不再重试）。PostHog 按口径过滤。
- 测试：新增 `BackgroundTransferJobTests` 7 例（Job 编解码 roundtrip / Documents 锚定
  相对路径（/var 与 /private/var）/ 边车远端名派生）；全量 139 绿。
- **给未来 agent**：① Swift 6 里 NSLock 裸 `lock()/unlock()` 在 async 上下文编译报错，
  一律 `withLock` 同步闭包（锁绝不跨挂起点）；② 用户 force-quit 会让系统取消后台任务
  ——文件仍在盘上，下次启动 drain 重新入队，语义不破；③ 照片仍走前台
  `PhotoService.upload`（拍照即传，录音中 app 必然活着；晚到照片有服务端
  backfillSessionPhotos 兜底）；④ 多条待传音频在 drainPending 里仍串行 await，离线时
  第一条会把后面的压到联网后一起走——bg session 下无害，别改成 fail-fast。

## 弱网上传提速：解除照片串行 + 服务端晚到照片补写（2026-08-03，iOS + agent worker + Pages）

用户报「上传特别慢」，最初设想音频直传腾讯 COS。排查否掉了前提：线路（voicedrop.cn
EdgeOne）实测 1.7MB/s 不是瓶颈；8-01 苏州弱网中位 214s 且与文件大小无关的真凶是
`Uploader.upload` 开头**强制串行**的「tags 边车 PUT + 照片队列逐张 3 次退避重试」。
方向经用户确认：不动存储架构，修真瓶颈。

- **iOS 解除串行（`Uploader.swift`）**：音频立刻 PUT；照片 drain 改 fire-and-forget
  并行赶路；tags 边车并行 Task（成功分支 `await tagsTask.value` 后再删本地边车，语义
  同旧版）。`isUploadable` 的 moov 扫描改首尾各 512KB（原全文件扫，每次 refresh 都跑）。
- **照片队列并行化（`PhotoUploadQueue.swift`）**：`withTaskGroup` 滑动窗口并发 3
  （`maxConcurrent`，一行可调）、每张每次 drain 只试一次、**退避 sleep 全删**——重试交给
  下一次 drain 触发点（启动/联网恢复/enqueue/音频上传前/**前台刷新**，最后一个是
  `LibraryView.refresh` 本次补的）。新增可注入 `uploadImpl`（单测第一次能真正驱动 drain，
  `PhotoUploadQueueDrainTests` 4 例：并发≤3 / 失败留盘 / 全失败 8 张 <1s / 空文件即清）。
- **「照片一张不丢」移到服务端兜底（关键，必须先于 iOS 发版部署）**：Pages 照片 PUT 落盘
  后带 `photoTs`（+admin 时带 scope）poke 用户 Miner DO 分片（`dispatchMine` 扩参）；DO 记
  `pbf:<ts>` 待办，60s grace（合并 burst）后在 **alarm 里先于 runMine** 调
  `backfillSessionPhotos`（`miner.js` 新 export）：文章已成文 → 全版本 `photoKeysIn` 算
  everSeen（出现过又被删=用户意志，永不复活），缺的 `ensurePhotoKeys` 补末尾、
  `writeArticleDoc` 铸 `photo-backfill` 版本、notifyStatus 推客户端；no-speech/silent 的
  `.empty` → 清掉（含 D1 flag）同 alarm 看图重挖（ASR checkpoint 防二次扣费）；doc 尚未
  写盘 → no-op（DO alarm 串行 ⇒ 未来挖矿 fresh 重列必然看见，这是正确性核心）。alarm 改
  **min 语义**（photo poke 不许拖慢挖矿 500ms poke）。08-02 流水里的「已知残余：成文后
  才上传成功的照片进不了文章」就此闭环。线上已验证：成文后补传照片，60-90s 内 marker
  出现 + photo-backfill 版本 + 状态推送。
- **埋点口径 2**：「录音上传完成/失败」补 `口径:2`；`排队秒` 语义变为「drain 里排在前面
  的音频占用的等待」（单条恒≈0，口径 1 的照片串行等待已消亡）；照片侧新增「照片队列清空」
  `{张数,失败,耗时秒,并发}`；服务端补写有 `[pbf]` 日志可查。对比 8-01 基线（口径 1）用
  `排队秒+耗时秒` 总和对总和。
- 测试：agent `photo-backfill.test.js` 19 例（含 DO poke/alarm min/trigger 透传/Pages poke），
  全套 1330 绿；iOS 单测全绿。另修 `prompt-market.test.js` 写死日期随时间衰减翻车的 flake
  （改「10 天前」相对日期）。
- **给未来 agent**：`.assetsignore` 对 `wrangler pages deploy` **不生效**——worktree 里装过
  `agent/node_modules`（workerd 107MiB）会撑爆 Pages 25MiB 限制。首选解法（记忆库
  domains-hosting-deploy 已记）：`git archive HEAD` 导出到 /tmp 干净树再 deploy；本次删了
  worktree 内 node_modules 也通（可重装，但并行会话要重 npm install）。多条待传音频仍串行
  （罕见态，第一条最早到达）+ background URLSession 列为 future work。

## push main 恢复自动发 TestFlight（2026-08-02，CI）

用户要求撤销 2026-07-09 的 `[tf]` opt-in 闸：`build.yml` 里 push main 一律跑
`fastlane beta` 上传 TestFlight（PR 仍只验编译；workflow_dispatch 的
certs/appstore 路径不变）。苹果 ~20 包/24h 上传限额仍在——高强度迭代日撞 409
就是限额到了，等窗口刷新，**别改回 opt-in**（用户已明确要每 push 必发）。

## 录音期间照片一张都不能丢（2026-08-02，iOS + agent worker）

用户反馈：录音时拍的照片有时没进正文。排查出三个丢失点，全部闭环：

- **服务端保底（主因，`agent/src/miner.js`，已部署）**：初次挖矿此前全靠模型自觉插
  `[[photo:key]]`（restyle 有 `ensurePhotoMarkers` 兜底、初挖没有）——模型漏插即静默丢图。
  现在有语音挖矿与看图模式两条写盘路径都在写盘前 **fresh 重列** `photos/<sessionTs>/`
  （cursor 翻页；不用跑批开始的 allKeys 快照，顺带兜住「照片在 ASR 期间才上传完」的竞态），
  凡正文没引用的 key 按序补 `[[photo:key]]` 到最后一篇末尾，minelog 记「补回漏掉的照片标记」。
  新增 `ensurePhotoKeys(relKeys, articles)`（`ensurePhotoMarkers` 改为其薄壳）。
  测试 `agent/test/photo-guarantee.test.js`（含晚到照片竞态用例）。
- **iOS 照片上传落盘队列（`PhotoUploadQueue.swift` 新文件）**：此前录音期间拍照上传是
  单次 fire-and-forget（`PhotoService.upload` 一次失败即永久丢，拍完锁屏任务被杀也丢）。
  现在拍完先落盘 `Documents/pending-photos/<relKey>`，上传成功才删；3 次退避重试 + 后台
  保活 + 失败留盘，启动 / 联网恢复 / 下次音频上传前都会 drain。relKey 从路径末三段还原
  （不做前缀比较，`/var` 与 `/private/var` 符号链接会失配）。
- **照片先于音频上传（`Uploader.upload` 开头 `await PhotoUploadQueue.shared.drain()`）**：
  音频的到达才触发挖矿，照片先到位挖矿必然看得见。drain 全量串行化且等真正跑完才返回
  （不是"已有 drain 在跑就放行"，那会让音频抢跑）；`current` 清空放任务体内与最后一次
  `runAgain` 检查在 MainActor 上原子，无「标了重跑却没人跑」窗口。
- 编辑器插图路径（`RecordingDetailView.insertPhotos`）失败有 toast、用户在场可重试，不改。
- 已知残余：照片若在**成文之后**才上传成功（极端离线场景），不会追加进已写盘的文章
  （双保险把这个窗口压到几乎为零；真发生时照片还在 R2，重写一次即回）。

## 快速删除崩溃 + 心跳双回调防护（2026-08-02，纯 iOS）

Kaola 实机两份 crash log（build 279）定位出两个 bug：

- **首页快速删除 → Index out of range（主案）**：`LibraryStore.load` 的两个 late-enrichment
  循环（blockReason / .tags sidecar）写成 `for i in recordings.indices` 且循环体内有
  `await`——挂起期间 swipe 删除把 `recordings` 删短，恢复后旧下标越界即 SIGTRAP。
  修：先快照 stem 列表，每次 await 回来按 stem `firstIndex` 重找（与 `fetchMissingTitles`
  「Matched back by id」同规范）。全仓已扫，无其他「跨 await 持有下标」点。
- **AgentSocket.ping continuation 双 resume（00:41 crash）**：`sendPing` 回调在连接
  同时出错时可能被调两次（URLSession 已知坑），CheckedContinuation 二次 resume 即崩。
  修：`OSAllocatedUnfairLock` 一次性门闩。
- 另一份 7-31 crash 是 0x8BADF00D 启动 watchdog（设备当时系统 CPU 打满），非代码问题。

125 条单测改动前后全绿。排查手法沉淀：设备不插线也能
`devicectl device info files / copy from --domain-type systemCrashLogs` 直接拉 .ips；
TestFlight 非 bitcode 构建 ASC 无 dSYM（dSYMUrl=null），系统帧用本地
iOS DeviceSupport Symbols + atos 符号化。

## 录音上传埋点补耗时/大小/网络类型（2026-08-02，纯 iOS）

「上传特别慢」排查（用 R2 时间戳反推 947 条录音）发现 App 缺上传耗时数据：8-01 苏州外出
蜂窝弱网中位 214s 且与文件大小无关（照片队列串行放大），而线路本身实测无碍（voicedrop.cn
1.7MB/s 稳定 > 直连 CF）。此后不用再反推：「录音上传完成」新增 `耗时秒`（音频 PUT 本身）、
`排队秒`（tags 边车+照片 drain 的等待，慢的真凶通常在这）、`文件KB`、`网络类型`
（WiFi/蜂窝/有线/其他/离线，复用 Uploader 现成 NWPathMonitor 随路径更新）；
「录音上传失败」也带 `网络类型`，重试耗尽额外带 `耗时秒`/`文件KB`。

## 1.8 提交 App Store 审核（2026-08-02）

复用 TestFlight build 279（7-28 上传，内容 = release/1.7 之后 main 的 25 个 commit：
重连风暴修复、编辑 WS 25s 心跳+终态重拉、全量 SWR 秒开缓存、API 入口切 voicedrop.cn、
文章图片三点提示、录音不足 4 秒拦截、下线多风格对比）。发版准备 = 9bbf2e7：project.yml
MARKETING_VERSION 追上列车 1.8 + 双语 release notes；`workflow_dispatch destination=appstore`
→ `fastlane release skip_build:true`。125 条单测提交前全绿。

## 挖矿只产出一篇文章（2026-08-02，纯服务端 prompt）

MINE_SYSTEM（`jianshuo.dev/agent/src/prompts/mine.js`）从「一篇或多篇、可拆 2–3 篇」改为
永远只产出 1 篇：转写跳了几个话题也要用内在线索组织进同一篇；篇幅完全跟随内容，
内容多就写长，不有意删减素材。JSON 契约不变（仍是 `articles` 数组，只放一篇元素），
iOS / miner 代码零改动。测试断言同步更新（prompt-extraction.test.js），已部署
voicedrop-agent（版本 a4aaf443）。注：prompt-market.test.js 有 1 条既有失败（hot 排序
时间衰减），与本次无关。

## 录音不足 4 秒不上传（2026-07-28，纯 iOS）

太短的录音产不出文章，不再送进上传队列。收口点在 `RecordingPromoter.promote`（新增
`minDuration = 4`）：不足 4 秒直接删掉暂存文件、返回 nil（签名 `URL` → `URL?`），所以
四条调用路径——正常停止 / 来电中断 / onDisappear 兜底 / 社区回复录音——没有一条能绕过。
UI 提示：`RecordSession` 停止时进新 `Phase.tooShort` 全屏提示「录音太短，时间太短，
不足以产生文章」（埋点「录音太短」）；社区回复路径 toast「时间太短，不足以产生文章」且
不关页面。服务端 miner 原有的 `too-short` empty 标记继续兜底存量。125 条单测改动前后全绿。

## /code-review max 后续修复（2026-07-26，紧随下一节的五项重构）

max 档审查（10 finder + 对抗验证）对上一轮重构复查，确认 12 条、全部落地（ff1fffc + d3177dd）：

- **重连风暴（最重）**：AgentSocket receive 回调缺代际守卫——「开新前杀旧」让被取消 task 的回调以 .failure 迟到落地，reconnect 再杀健康新连接成永久 1.5s 循环。修：`guard task === t` + connect 同 url 幂等（ff1fffc）。
- **orphan reconnect**：断连前排下的 1.5s 重连在 disconnect+connect 之后醒来会拆新连接。修：generation 计数，connect/disconnect 各 +1，醒来代数不符作废。
- **reconcile 半修**：库级快照对账 onUpdate 曾以 doc 非空为前提——article 常为 null 的 merge/delete 场景丢 stems 又跳 refresh。改无条件调用。
- **库级 socket 无人断开**：现在有 25s 心跳后会跑满进程生命周期。LibraryView 让 command 与 status 同进退（scenePhase/adopt）。
- **销号不广播**：AccountService 成功后 post .vdDidAdoptAccount，旧身份 WS/内存队列不再复活进新身份。
- 其余：send() 无连接时也走 onFailure；URLSession 跨重连复用；空 bearer 停机 + onAuthLost「未登录」终态；StatusSession 删调用方侧防双开 guard（契约只留基座一份）；Community 两处 uniqueKeysWithValues 改 uniquingKeysWith（重复 shareId 不再 trap）；ArticleDoc.fromWire 挪回模型旁；tokenProvider 标 @ObservationIgnored。
- 未采纳（有记录）：onOpen 清 error（与旧行为等价）、QueuedAgentSession 二次抽象（更大重构）、confirm/cancel 帧持久化（存量协议问题）。审查还替服务端澄清两点：ledger 游标格式无双重编码；/status /command 都走 DO hibernation API，心跳安全。

## 代码审查五项修复（2026-07-26，纯 iOS + 文档，服务端零改动）

三个子代理并行审查（重复代码 / 流程清晰度 / 分层）后的 Top-5 落地。模拟器构建通过 + 125 条单测全绿。

- **抽 `AgentSocket` 基座**：ArticleAgentSession / LibraryCommandSession / StatusSession 共用建连 / 25s 心跳 / 1.5s 重连 / 防双 socket；修掉两处已发生的漂移——库级命令连接补上心跳（之前被 NAT 掐死要等下次说话才发现）、reconcile 透传 stems（行缓存能正确失效）。StatusSession 旧防双开 guard 在 reconnect 空窗会漏（「4 位码显示出来然后崩」成因），基座用 active 标志 + 开新前先杀旧根治。RealtimeSession 协议不同（二进制帧+代际 token），未动。
- **销号事务外提 `AccountService`**：Apple 5.1.1(v) 的不可逆删号流程离开 AccountView 的 private func，fm/defaults 留注入口。
- **`FeedRow` 改组合解码**：内嵌解码 CommunityPost，「加字段三处同步」降为零（kind 漏映射→提示词 tab 恒空那类 bug 结构性不可能再发生）。
- **`API.authed/get/send` 收口 + `tokenProvider` 注入**：Networking.swift 提供主 App 版 authed helper（对齐 ShareAPI 既有纪律）；UsageView / SettingsStore / PromptMarketSection 的字符串插值 URL 全部迁走（含一个用户可控 query 的强解包）；LibraryStore / CommunityStore / SettingsStore / PromptStore 加 tokenProvider 注入点，Store 层从此可脱离真 Keychain 测试。
- **文档修偏**：README 行为段与结构表重写（删掉不存在的 ContentView「单屏状态机」）；STATE.md 拆成稳定架构（本体，708 行）+ 本文件（流水）；CLAUDE.md 补本仓 iOS 测试命令（旧的只指向 jianshuo.dev/agent 的 npm test）。

## 语音编辑提速第二~四轮（2026-07-25 凌晨，纯服务端，worker ce966caa）

第一轮（见下节）上线后实测还慢，连续打点（llmlog laps + Workers Observability）逐层
剥出三个真凶，全部修掉。jianshuo.dev repo d1703e4 / 25303b9 / 01abf81：

- **轮 2：DO 钉 wnam**（index.js）。R2 桶在 WNAM、Anthropic 在美国，而国内用户的
  ArticleEditor/LibraryAgent DO 建在 HKG——每次 I/O 跨太平洋，晚高峰单次 1.5~20s
  （实测一次 fast path 出图 42s 零 LLM）。`getAgentByName(..., {locationHint:"wnam"})`
  + DO 名加代号 `w1:` 强制重建（旧 DO 编辑对话 history 丢弃，可接受）。顺带
  `config/model.json` 加 60s isolate 缓存（cachedModelConfig）。**改桶位置不可行**：
  R2 无香港区、位置建桶即焊死、Anthropic 封 HKG 出口。
- **轮 3：文章写入直连 article-store 库**（tools.js 四处 HTTP PUT 全换 writeArticleDoc
  直调）。wnam DO 里 binding 读 doc 0.1s，但绕 HTTP 调自己 /files/api/articles/ 写
  要 8~22s。agent worker 与 Pages 同绑 FILES/CORE、同一份库，直写语义不变。**顺手修
  真 bug**：tag_article 删空标签 `delete doc.tags` 会被 writeArticleDoc 合并语义复活
  （最后一个标签永远删不掉），改显式 `undefined` 覆盖。测试断言从「抓 HTTP 请求体」
  改「读 R2 落盘 doc」（6 个文件）。
- **paint 异步收单**（paint/src，VPS 已部署）：POST /api/jobs 不再同步跨洋下载
  image_url 原图（提交方干等 5~8s），提交时只校验 URL/SSRF，下载挪到 worker 起跑前；
  下载失败走 job 失败回调（VoiceDrop 失败分支写回原图）。paint_post 5.4s→0.85s 实测。
- **轮 4：连接快照加固**（index.js onConnect）。占位图不出现的疑似根因：编辑中 WS
  断线（中国↔CF 直连常态，EO 不透传 WS），重连快照若恰逢 R2 偶发 internal error，
  loadDoc 吞错返回 null——App reconcile 照样消掉任务芯片但正文不更新。现 loadDoc
  失败重试一次 + 打日志（`[edit] snapshot loadDoc`）。**iOS 侧兜底未做**（snapshot
  article 为 null 时应主动 HTTP 拉一次 doc），下次 iOS 发版可加。
- **实测数字**（fast path 出图，点击→占位标记落盘+出图任务提交）：42s → **6~8s**
  （queue 0.6~1.1s + setup 0.1~0.2s + find_item 0.1~0.4s + put_article ~3s +
  paint_post 0.8~3.2s）。put_article 3s 还有压缩空间（doc 版本链大、R2 读写×4+D1）。
  出图全程（点击→成品图落 R2）实测 ~58s。
- **常开打点**：`[edit] turn … queue_wait/setup`、`[edit-turn] fast path find_item/tool`、
  `[edit_photo] total account+doc/put+dims/paint_post`。查法：Workers
  Observability API（记忆 voicedrop-realtime-quota-alert 有 curl 模板）或 admin llmlog。

## 轮 5：乐观回执 + 瘦身写入（2026-07-25，worker c749db9d，jianshuo.dev f32b33e）

- **乐观回执**：fast path 校验一过（~1s）就经 `notify` 通道广播「🎨 正在生成图片」
  reply，写盘/探尺寸/提交出图挪到回执后。失败落回 LLM 路径时终广播顶掉这句。
- **瘦身写入**：`writeArticleDoc(env,key,doc,source,{current,deferIndex})`——current
  免重读（队列按文章串行，读写间本无 CAS）；索引+D1 维护 fire-and-forget（对账自愈）。
  agent 四处直写启用；Pages 路由不传 opts 行为不变。edit_photo 内并行（余额∥读文、
  写指针∥探尺寸）。预期：回执 ~1s、占位卡 ~2s。
- **图片锚点漂移自愈**（同日 2fd63b8）：`healPhotoAnchorKey` 按「目录/偏移-」base 唯一
  匹配把旧 key 修正到现存 key（App 界面停旧正文时长按不再被反问「哪张图」）；
  resolveAnchorLine 与 fast path 共用。
- ⚠️ 用户编辑器 format-on-save 曾把 tools.js 整文件重排并写坏 `?.`（`? .`）——已恢复
  原格式、保留其文案改动（出图回复改「正在生成图片」）。**改 agent 源码前关自动格式化**。

## 「UI 停在旧正文」终局排查 + iOS 收敛兜底（2026-07-25 凌晨）

用户连续报「占位符不出现/插图失败/长按被反问哪张图」。服务端逐环验证**全部健康**：
① R2 doc 编辑正确落盘（插图 markers 在 head 版本里）② 自建匿名号 WS 端到端复现：
snapshot/status/edit-preview/updated/reply 全部按序到达、updated 正文含新标记（8.2s）
③ doc JSON 与 iOS ArticleDoc 全字段类型兼容 ④ voicedrop.cn(EO) 对 /files/api JSON
不缓存（MISS×3）、照片 404 no-store 不负缓存、200 正常边缘缓存 ⑤ GET /articles/<stem>
= readArticleDoc 纯 R2 读，权威新鲜。结论：**病灶是 iOS 收敛依赖单一下行消息成功
送达**——国内 WS 每 ~15-20s 断一次（obs 可见 /agent/edit 重连对），updated 常落死
连接；快照对账消掉任务芯片但 article 偶发缺失时正文不更新。

**iOS 修复（本 repo，已 push main）**：AgentSession 新增 `onResolved`（指令终态：
updated/error/快照对账都触发）；RecordingDetailView 借此**主动 HTTP 重拉权威 doc**
（store.fetchDoc）覆盖本地状态——收敛不再依赖任何一条 WS 消息。需 TestFlight 发版
生效。服务端两道加固（快照 loadDoc 重试 + 图片锚点 healPhotoAnchorKey 漂移自愈）
已先行部署兜住旧版 App 的大部分场景。

~~遗留观察项：writeArticleDoc 直写 current:doc 顶层 articles 泄漏~~ **已修**
（jianshuo.dev d5eaa82，worker 79cd2ddb）：current 侧同款字段清洗 + opts.current
先过 migrateToV3（否则老 schema-2 doc 直写会重置版本链）。泄漏的危害不只洁癖：
undo 后 raw /download 和 DO 连接快照会把过期顶层正文当权威发出。受影响用户
141 个存量 doc 已批量清洗（CF REST API 直写 R2，S3 凭据只读不可用）；其他用户
历史泄漏由下次写入 lazy 自愈。回归测试在 edit-fastpath.test.js（1317 绿）。

**iOS 心跳（41f695f，待 TestFlight）**：编辑 WS 加 25s ping——国内 NAT/CF 掐
空闲连接，心跳保活 + 死连接提前暴露立即重连。sendPing 回调在后台队列，
nonisolated static + continuation 包装（Swift 6 隔离坑，见记忆
swift6-mainactor-callback-crash）。注意：WS 断开大头其实是 App 设计
（RecordingDetailView.onDisappear 主动 disconnect——切页面/拍照全断），心跳只
治「停留页面内空闲」那部分。

## 语音编辑提速三件套（2026-07-25，纯服务端，worker 3aee7388 已部署，iOS 零改动）

起因：2026-07-24 llmlog 实测 prompt market 图片 prompt 一次点击要 6.4–12.7s 纯 LLM
才开始出图（Sonnet 第一轮 5–8s 逐字复读 prompt 进 edit_photo + 第二轮 1.5–4s 纯确认），
批量套风格被串行队列放大（10 张图最后一张 2 分钟后才排到）。jianshuo.dev repo 58cc97a：

- **① photo 工具短路**（loop.js）：`edit_photo`/`new_photo` 进 `TERMINAL_TOOLS`——
  出图是异步的，工具已返回「🎨 正在生成…」文案，省掉确认轮。edit-turn 无 summary
  时用该文案兜底回复（比「改好了」诚实，图还没出来）。
- **② 长按图片 prompt 确定性直通**（edit-turn.js）：itemId 对应菜单 kind=image 条目
  + 锚点是本篇真实存在的图 + instruction 无残留 `{{…}}` 占位符 + 无随手拍新图 →
  跳过 LLM 直接调 `edit_photo`（iOS 发送前已把 {{KEY}} 换成目标 key，instruction
  就是最终 prompt）。7–12s → <1s，且零 token 成本。任何条件不满足或工具失败都
  落回原 LLM 路径。toolRuns 里带 `fast:true` 标记，llmlog 可查直通命中率。
- **③ 写后校验只验高风险编辑**（edit-turn.js verify 闸门）：write_article 整篇重写 /
  带锚点 / 一次 ≥2 op 才跑 haiku 质检；单 op 无锚点的小改（加粗/删行）跳过——
  haiku 往返实测 1.9–3.5s（不是当初预估的 ~1s），接近小编辑本身耗时。
- 测试：`agent/test/edit-fastpath.test.js` 锁三块行为（直通/回退×4/短路/校验门×3），
  全量 1307 绿。**真机手测清单**：① 长按图 → prompt market 的图片 prompt →
  占位图应 ~1s 内出现（原来 7–12s）② 语音说「把图2改成贴纸」（无 itemId 路径）→
  走 LLM 但只一轮，回复是「🎨 正在…」③ 单 op 小改（加粗某段）不再有 haiku 校验
  延迟 ④ admin llmlog 看 tool_runs 里的 fast:true。

## 系统缺省「合影照片」组减到 4 个动作（2026-07-24，worker 31a2d94f 已部署）

按建硕要求删掉「电影感调色」（sys_gp_cinema）和「日系动画电影」（sys_gp_anime）
两个改图动作（jianshuo.dev e600220，agent/src/prompt-template.js）。模板叶子
18→16、prompt-registry 24→22，计数断言同步更新，1296 测试绿。线上没有
R2 `config/prompt-template.json` 覆盖，内置字面量即真源，部署即生效。
已有用户自己 prompts.json 里的副本不受影响（那是用户数据，不是系统缺省）。

## 多风格对比整体下线（2026-07-24，两端已改，worker 3b5603d3 已部署）

「勾选 2–3 个文风版本、成文时各挖一篇并排对比」的功能全删：

- **iOS**（SettingsView.swift + Theme.swift）：写作风格页的「多风格对比」开关、
  勾选 UI、对比态版本栏、「完成」按钮全部移除；`Prefs.multiStyle` / `Prefs.styles`
  删掉（UserDefaults 里的旧 key 残留无害，无人再读）。`SettingsStore.saveStyles` /
  `serverStyles` / `StyleResponse.styles` 一并删除。版本下拉恢复为纯单选切换。
- **服务端**（jianshuo.dev repo 81c4099）：`functions/files/api/[[path]].js` 的
  GET /style 不再返回 `styles`，PUT /style 忽略 `body.styles`（旧客户端「关掉开关」
  会 PUT {styles:[]} → 400 empty_content，App 端 fire-and-forget 不受影响）。
  `agent/src/miner.js` 挖矿只按 head 文风挖一篇：picks/toMine/variants 循环、
  cacheMode "transcript" 分支全删（"transcript" 机制保留，改稿路径还在用）。
  已存在用户 CLAUDE.json 里的 `profile.styles` 字段留着但无人再读——之前选过
  非 head 单风格的用户会静默回到 head 文风，这是预期行为。
- 测试：style-api.test.js 两条多风格用例改为「已下线」断言，全量 1296 绿。
  iOS BUILD SUCCEEDED。

## 文风 undo 后再写不再截断未来版本（2026-07-24，已部署活体验证）

- **行为变更**（jianshuo.dev repo 3addf11，worker 64d6bb33 + Pages 446727d6 已部署）：
  `writeStyleDoc`（functions/lib/style-store.js）以前在 undo（head 后移）之后再写会把
  head 之后的版本全部丢弃（git 式截断）。现在**整链保留**，新版本号 = max(v)+1 接链尾，
  head 指向它；只有 STYLE_MAX_VERSIONS(20) 上限还会挤掉最老的。线上用一次性账号
  活体验证过（undo 到 v1 再写 → v2 幸存、新版 v3）。**文章 doc（article-store.js）的
  同款截断没改**——只动了文风。
- **起因**：用户 CZ（短码 15A15A）7-15 撤回 v9 后语音改文风，v10–v16 七个版本被截断；
  更早 v1–v5 被当时的 10 版上限挤掉（07-19 才升到 20）。
- **恢复**：从夜间备份桶 `jianshuo-dev-files-backup` 的 `trash/2026-07-12 / 07-15 / 07-16`
  三份快照拼出全集，按时间重排 v1–v15 直接 r2 put 回
  `users/anon-15a15a…/CLAUDE.json`（head=15 = 原当前生效的庆山风，挖矿不受影响）。
  v1–v5 的 trash 快照 07-17 已过 14 天清理期，真没了。
  ⚠️ 版本号是重排过的：她文章上旧的 `articles[i].style = N` 标签对不上新链号
  （截断那一刻就已经对不上了，不是恢复引入的）。恢复用的三份备份快照留在
  `~/.claude/jobs/fdf92bd2/tmp/cz-backup-*.json`。

## 编辑 loop 写后校验 + 长按菜单开放给语音（2026-07-24，纯服务端已部署 worker 0e3956a7，iOS 零改动）

agent 端 agentic 化第一批（jianshuo.dev repo a4d89ae，全量 1296 测试绿）：

- **写后校验（haiku 质检员）**：`runAgentLoop` 新增 `verify` 钩子——终结编辑工具
  （edit_current_article / write_article）落盘后、短路收尾前，`claude-haiku-4-5` 对照
  「指令 + 锚点 + 正文 diff」判 `{ok, issue}`；不合格把 issue 追加进同一条 tool_result
  消息（保持 user/assistant 交替）让编辑模型再修一轮，**每回合至多验一次**。
  best-effort 铁律：校验器抛错 / 输出不合法 / 读不到 doc / 正文无 diff（如只改标题）
  一律放行——绝不把成功的编辑拖成失败。diff 是多重集合逐行比对（`diffBodyLines`，
  不做 LCS，宁可放行）。DO 侧 `callVerify` 走 `_makeLoggedCall`（同 turnId 进 llmlog、
  model 字段区分、同一套算力计费；与主 callClaude 各有 step 计数器，序号可能重叠，
  只影响日志观感）。出图（edit_photo/new_photo 异步）和发公众号等动作不校验。
  代价：每次成功文字编辑多 ~1s haiku 往返。
- **语音用长按菜单（use_my_prompt）**：新工具按名字取用户提示词库（长按菜单同款）
  某条全文——exact→fuzzy 匹配、**完全同名多条（历史重复导入）取首条不算歧义**、
  近名多条返回 ambiguous 候选让模型跟用户确认。`edit-turn` 往上下文注入一行
  【我的提示词菜单】目录（只有标签几十字，与分享码 fast path `Promise.all` 并行拉，
  不加串行往返；R2 挂了 loader 自己回退模板目录）。EDIT_SYSTEM 教了占位符规则：
  kind=image → {{KEY}} 换目标图 KEY 后 edit_photo / 新图当 new_photo prompt；
  文字类 → {{LINE}}/{{QUOTE}} 换目标行号和行首原文后 edit_current_article。
  **iOS 零改动**（语音指令走原 WS 链路）。锚点回归锁测试⑥已更新为含目录行的新形状。
- 线上验证：worker 部署后 MCP list_prompts 正常吐全树（真树含「公众号题图｜教程步骤」×2
  历史重复，取首条逻辑覆盖）。**真机手测清单**：① 语音说「把图2改成白边贴纸」→
  use_my_prompt 命中 sys_gp_sticker → edit_photo 出图 ② 说「这段更简洁」长按/不长按
  两路 ③ 故意含糊的指令看写后校验是否打回重修（admin llmlog 看 haiku verdict）
  ④ 原有编辑指令回归（校验放行不增加失败）。

## App API 入口收敛到 voicedrop.cn（2026-07-24，iOS 已 push main，EO 已部署）

`API.host` = voicedrop.cn：files / agent / reco / agentLink 的 HTTP 请求全部从腾讯
EdgeOne 境内边缘进，EO 跨境回源通道回 CF——国内用户不再直连 CF anycast。
两个豁免留在新增的 `API.cfHost`（jianshuo.dev 直连）：**WebSocket**（/agent/edit、
/status、/asr、/realtime——EO 边缘函数 WS 透传未验证）和 **/cdn-cgi/image 缩略图**
（CF 专有）。EO 侧：边缘函数把 /agent/*、/reco/* 同源透传 + 规则引擎 ModifyOrigin
改源站到 jianshuo.dev zone worker 路由（真相在 jianshuo.dev repo
`infra/voicedrop-cn-edgeone/`）。**踩过的死胡同**：EO 边缘函数里直接 fetch 外部 URL
走节点裸公网出境——workers.dev 被墙 545、jianshuo.dev 超时；只有配置/规则改写的
源站走 EO 回源专线。100MB PUT 实测穿透（EO 无 413 上限）。回滚 = iOS 把 host 改回
jianshuo.dev 即可，EO 侧规则无害可留。

## 采访「从国内连不上」根因 = OpenAI 额度耗尽，非跨境（2026-07-21，已部署）

排查坐实：realtime relay close 日志 `source:"openai" code:1013 reason:"insufficient_quota"`
——采访是 OpenAI **账户额度/配额耗尽**把会话秒关，**对所有地区都坏、与 GFW/香港无关**。
跨境腿本身是好的（`relay open` 能打出即握手成功，含香港 geo-block 的 ENAM 中继兜底）。
误判成「中国网络」是因为历史上确有跨境断连旧账。**该次 outage 已于 07-21 ~09:39 UTC
自行恢复**（额度补上/计费窗口重置），探针 `session.created` 成功、近 90min 无 quota close。

改动（下次再发生时自动生效）：
- **服务端**（jianshuo.dev/agent，worker 已 deploy version 0c3e37a0）：
  - `push.js` 新增 `alertAdminThrottled(env, ruleKey, windowMs, msg, push=sendPush)`：给
    `env.ADMIN_SCOPE` 推「重要失败」，同 ruleKey **60 分钟只推一次**（marker 存 R2
    `ops/alerts/<key>.json`——报警从一次性中继 DO 发出，跨会话去重靠 R2 共享真源）。
  - `realtime.js` closeBoth：`source==="openai"` 且 reason 命中 `OPENAI_FATAL_RE`
    (`insufficient_quota|billing|exceeded_current_quota|account_deactivated`) → 报警，
    `ctx.waitUntil` 后台发、绝不阻塞/抛。`test/push-alert.test.js` 覆盖，全量 1237 绿。
  - ⚠️ 未活体验证的一环：`ADMIN_SCOPE` 指向的管理员 scope 是否已注册 push token
    （故障当时不复现，无法真触发一次推送坐实）。同 scope 已被 miner-fail / voicedrop.cn
    探活报警复用，且 APNs prod 通路本身验证可用（文章推送成功）。
- **iOS**（voicedrop，已 push main→TestFlight CI，build 已过）：`RealtimeSession` 加
  `.unavailable` 终态识别硬拒绝（error 事件 or close 1013/quota），`RealtimeInterviewer`
  不再重连、停上行 tee，录音界面提示「AI 采访暂不可用 · 录音继续」。修掉了 `connect()`
  同步置 `.live` 清零 reconnectAttempt 导致「6 次上限」永不触发的无限重连风暴。

## 提示词保存提速：分享同步挪后台（2026-07-19，纯服务端已上线并线上验证）

## 提示词保存提速：分享同步挪后台（2026-07-19，纯服务端已上线并线上验证）

「提示词保存慢」根因不在 App：`PUT /agent/prompts` 是**整树 PUT**，服务端每次保存都
把用户**全部在分享中的副本**重刷一遍——`collectSavedIds` 收整棵树的 id，凡在分享中
的都命中，逐条 `refreshPromptShare`（各 ~4-5 次串行 R2 往返）。分享 11 条的用户一次
保存 ≈ 50-60 次串行往返，卡 2-3 秒。删除/改名/排序全走这条 PUT，都一样慢。

修（jianshuo.dev repo，worker 已 deploy，1180 测试绿）：
- **rekey + syncActiveShares 整体挪进 `ctx.waitUntil` 后台**（prompt-routes.js PUT 分支）。
  响应体 `resolved(tpl, body.items)` 只用手上的 body、不读 R2，落盘成功即返回。
  waitUntil-or-await：线上有 ctx 后台跑；单测 `worker.fetch(req,env)` 不传 ctx →
  await 内联，保持「保存后副本已刷新/码已 rekey」的同步断言（同 openPromptShare 发帖）。
- **两处 for-await 串行改 Promise.all**：syncActiveShares 逐条 refresh、shareStates 逐条
  head（后者也在 iOS 分享卡 GET /agent/prompt-shares 热路径上）。
- **线上验证**：原样回写 PUT 后，命中树的分享副本 `updatedAt` 在响应返回之后才推进
  （证明同步确在后台跑），响应本身不再等它。
- **未做（第二层，待用户拍语义）**：把自动 write-through 整条删掉，分享改「铸码拍快照
  + 作者显式点更新」，与「导入=独立快照」语义对齐。rekey 保留（管分享卡身份跟 fork 走）。

## 提示词分享带分组落位（2026-07-19，纯服务端已上线冒烟，iOS 零改动）

## 提示词分享带分组落位（2026-07-19，纯服务端已上线冒烟，iOS 零改动）

「收下这条提示词」不再全堆顶层。jianshuo.dev repo befa835（worker 7f1a2fd0 +
Pages Action 已部署），全量 1179 测试绿：

- **分享副本记 `groupPath`**：铸码/写穿时 `effectiveLeaf` 记下这条提示词在作者树里的
  父分组名，存进 `shares/<码>` 的 `groupPath: ["合影照片"]`。**数组格式是给未来放宽
  层数留的**（用户拍板：暂不做三层菜单，树保持两级封顶，所以至多一段；导入侧也只
  消费第一段）。作者把项挪组/挪顶层再保存，syncActiveShares 写穿刷新跟着变。
- **导入按组落位**：收下时同名顶层分组（系统组/自建组，trim 后精确匹配）命中就合并
  进去；没有就新建同名自建组；副本没带 groupPath（老码）→ 照旧落顶层。幂等不变。
  导入响应的 `item` 改为按 id 扁平查找（不能再取「最后一个顶层项」）。
- **标题「分组｜名字」**：`promptPostTitle`（functions/lib/community-store.js 单一真源）
  用在 D1 索引 title、community/get 合成、落地页 `<h1>`、分享前关键词审核（分组名
  公开展示了必须一并过审）四处。
- **iOS 零改动**：importPrompt 成功后 `refresh()` 重拉整树，落位自动生效；SharePreview
  多出的 groupPath 字段老客户端 Decodable 自动忽略。
- 存量边界：老 dotted id（voice-editor.longpress.*）的在分享副本刷不动（effectiveLeaf
  不认，既有边界），无 groupPath 导入落顶层；建硕自己的 p_c12hsv8l/p_50zo83oa 已手动
  重开刷新验证（落地页/社区帖标题「合影照片｜…」双域已验）。
- **三层菜单已调研未做**（2026-07-19 用户拍板暂缓）：iOS 数据层/长按菜单数据生成天然
  递归，但 PromptManagerView 两套摊平行模型 + PromptDragEngine（Scope/落点几何/
  「组进组」双重防御）写死两级，是未来放开的大头；服务端 validateList 两处
  `depth > 0`、resolveList/sanitizeStoredItems 非递归。届时 groupPath 已是数组无需迁移。

## App Store 推荐提名（Featuring Nomination，2026-07-18 已提交）

- 已通过 App Store Connect API 提交中国大陆区推荐提名：类型 APP_ENHANCEMENTS，
  提名 id `e435f73b-aff9-4adb-be1c-0831d68bd346`，状态 SUBMITTED，期望推荐窗口
  2026-08-15 ～ 2026-09-30，territory CHN / locale zh-Hans / iPhone。
- 内容围绕 1.5 大更新（追问 / 拍照插图 / 提示词社区 / ¥19.9 包月订阅 / 邀请奖励）。
- 工具：`POST /v1/nominations`，JWT 用 fastlane 同一把 ASC key（S6363V64RS）。
  ASC 网页端「Featuring Nominations」可查看/编辑。以后每次大版本都值得再提一次
  （最少提前 3 周，最多提前 3 个月）。

## 中文产品页素材打磨（2026-07-18，已进 main，随下一个 release 上传）

- **截图集重排**（fastlane/screenshots/zh-Hans/，9 张）：GPT Image 2 海报（假 UI）
  与「海报式真截图」交替——3 张真机截图（语音改稿/录音+拍照/主页归档）套上
  米色渐变底+大标题+深色圆角手机框（合成脚本思路：PingFang SC Semibold 116px
  标题、980px 宽截图、r=148 外框），与海报家族视觉统一；Claude Code 那张挪到
  第 9 位。前 3 张（搜索可见）= 海报×2 + 真 UI×1。
- **App 预览视频**：`fastlane/app_preview/zh-Hans/voicedrop-preview-zh-886x1920.mp4`
  （886×1920、30fps、19.7s、H.264+静音 AAC，规格合规）。三段真实 UI 缓推 +
  字幕条 + 品牌尾卡。Apple 官方偏好真实录屏，静帧+动效有小概率被拒，被拒就
  撤视频重交（不影响 app 审核结论）。
- **已上传到 ASC（2026-07-18）**：1.5 过审上架后，用 ASC API 开了 **1.6 草稿版本**
  （id `da34ce41-08e8-4e34-af3e-0f00adc5128d`），zh-Hans 6.9" 截图集清旧换新
  （9 张）+ 预览视频均已上传，assetDeliveryState 全部 COMPLETE。脚本思路：
  appScreenshots/appPreviews 三步走（POST 预留 → PUT uploadOperations 分片 →
  PATCH uploaded+md5），**fastlane deliver 传不了 preview 但裸 API 可以**。
  ⚠️ 下次 release lane 跑 deliver 时 zh-Hans 截图会被 fastlane/screenshots/
  同一套内容重传（无害）；预览视频 deliver 不会碰，已在版本上。
  en-US 截图/预览未动，仍是旧的英文海报套装。

## 苹果订阅（2026-07-17，服务端已部署冒烟，iOS 已合 main；⚠️ 需 ASC 手工建产品才能真买）

**售卖开关（2026-07-17 晚追加，当前=关）**：订阅卡默认隐藏——服务端 `/agent/iap/status`
回 `enabled`（读 R2 `config/iap.json`，文件不存在/坏 = false），iOS 只在 `enabled || active`
时显示订阅卡（已订户永远可见管理入口）。**要开闸**：往 R2 写
`config/iap.json` = `{"enabled":true}`（`npx wrangler r2 object put
jianshuo-dev-files/config/iap.json --file=<f> --remote`），零部署即时生效；claim/ASN
通知不受开关影响。TestFlight build 260 的卡是常显的（开关前打的包），261 起隐藏。

spec = jianshuo.dev repo `docs/superpowers/specs/2026-06-30-voicedrop-subscription-credits-design.md`
（当年 P1 分桶/P2 活动赠送已上线，这次补 P3 服务端 + P4 iOS），plan 同 repo
`docs/superpowers/plans/2026-07-17-voicedrop-subscription-p3p4.md`。
¥19.9/月 → 每月 200 算力，桶过期 = 苹果周期末 + 6h 宽限 → 月清零（不滚存）。

- **服务端**（jianshuo.dev repo，worker 5ccd8737 已部署，D1 migration 0004 已 apply）：
  `agent/src/iap.js` 三端点——`POST /agent/iap/claim`（客户端回传 transaction_id）、
  `POST /agent/iap/notifications`（ASN V2 webhook，DID_RENEW 自动续账/REFUND 清零桶）、
  `GET /agent/iap/status`。**信任模型 = 全部回查 App Store Server API**（生产 404 →
  sandbox 兜底），不做本地 JWS 链验签——伪造 id/通知在回查一步死掉。worker secrets
  `ASC_API_KEY_ID/ASC_API_ISSUER_ID/ASC_API_KEY_CONTENT`（与 fastlane 同一把 key，已 put）。
  绑定 first-claim-wins（`iap_sub`，换账号 claim 同一订阅 409）；幂等键 = `iap_txn.transaction_id`
  （每月续费一个新 id → 月月各发一桶）。测试 18 例（`agent/test/iap.test.js`），全量 1154 绿。
  线上冒烟：status 200 / 假交易 claim 走真苹果 API 回 not-found（证明 JWT key 有效）。
- **iOS**：`StoreService.swift`（StoreKit 2：purchase / Transaction.updates 监听 /
  启动 currentEntitlements 逐笔 claim 兜底——服务端幂等所以随便重放）；`UsageView`
  订阅卡从「即将上线」换成真购买（价格用 product.displayPrice，未加载时字面 ¥19.9；
  订阅中显示续费日 + 管理订阅 manageSubscriptionsSheet；未订阅显示购买键 + 恢复购买 +
  自动续期披露 + 隐私/协议链接——审核必需）。App 启动挂 `StoreService.shared.start()`
  （VoiceDropApp.swift）。产品 ID = `com.wangjianshuo.VoiceDrop.sub.monthly_19_9`——**ID 里
  写死价格（人民币主档记号），以后加档（¥49.9 之类）= 新 ID**：服务端 `usage.js
  SUB_PRODUCTS`（产品 ID → 每月算力）加一行 + ASC 建同名产品 + iOS 加档位；各国售价
  在 ASC 按店面单独定，界面价格永远用 `product.displayPrice`（自动本地货币）。
- **⚠️ 上线前的 App Store Connect 手工步骤（代码做不了，做完才能真买）**：
  ① 功能 → App 内购买 → 新建**自动续期订阅**：产品 ID 就是上面那个，新建订阅群组
  （如「VoiceDrop 会员」），时长 1 个月，价格选最接近 ¥19.9 的价位点，中文显示名+描述；
  ② App 信息 → App Store 服务器通知 → **V2**，生产+沙盒 URL 都填
  `https://jianshuo.dev/agent/iap/notifications`；
  ③ 首个订阅必须随下一个 App 版本一起提审（审核备注里说明订阅内容）。
- **真机手测清单（发 TestFlight + ASC 产品建好后）**：① 算力页出订阅卡、价格显示
  ASC 价位 ② 沙盒账号购买成功 → 算力 +200、明细出「包月发放」 ③ 重启 App 不重复发
  ④ status 显示订阅中+续费日 ⑤ 沙盒加速续费（~5 分钟一个月）→ 自动 +200（ASN 主路）
  ⑥ 恢复购买在重装后能找回订阅 ⑦ 退款测试（沙盒退款 → 桶清零）。
- 已知边界（有意）：订阅奖励记在 anon scope（与所有算力同口径，Apple 登录不换 scope）；
  sandbox 交易也发真算力（自家 TestFlight 测试用，量小可控，ledger detail 带 env 可查）；
  退款只清剩余不追回已花；安卓无支付通道（苹果 only，spec §13）。

## 「收下这条提示词」幂等（2026-07-16 深夜，服务端已部署 worker 6e1b4cab，iOS 已合 main 未发 TestFlight）

反复点「收下」不再重复添加。识别键 = 实体上的 `importedFrom: <7位分享码>`（导入落盘时打上）：

- **服务端**（jianshuo.dev dc9af06）：import 端点先扫用户树（含分组内），同码命中直接返回
  已有条目 + `already:true`，不追加、不重复 +importCount；存量老副本（无标记但 label+prompt
  与本次导入完全一致）按内容认领并补标记。**整树 PUT 按 id 从旧文档补回 importedFrom**——
  老客户端（PromptNode 没建模该字段）整树 PUT 会剥掉标记，服务端兜底防冲。validateList
  白名单放行（限 action 实体、7 位码格式），resolveList 透传给客户端。测试 prompts.test.js
  幂等块 8 例，线上冒烟 401/405 守门 + MCP list_prompts 真树正常。
- **iOS**（已合 main）：PromptNode 建模 importedFrom 并随 rawItems 回写（客户端不制造洞）；
  社区帖打开时 `PromptLogic.containsImport` 查本地缓存树命中则按钮常显「已收下」；重复点
  按服务端 already 提示「这条提示词你已经收下过了」（不重复打「社区提示词导入」埋点）。
  单测 +3（round-trip / containsImport / decode），全量 125 绿。
- ⚠️ **String Catalog 坑**：`String(localized: cond ? "a" : "b")` 三目里的字面量编译器
  抽不出 key——必须每个分支各自 `String(localized:)`。另外 xcodebuild 不更新 xcstrings
  （GUI 构建才会），本次新 key 是手工按 JSON 插入的；xcstrings 因重序列化有一次性格式
  压缩（数据逐 key 验证过零丢失），下次 Xcode GUI 构建可能再canonicalize一次，勿慌。
- **存量重复未清**：建硕自己的树里已有历史重复（「改图｜手绘解释风」×3、「公众号题图｜
  教程步骤」×2、「合照｜日系动画电影」×2 等）——旧行为产物，内容完全一致的会被新逻辑
  认领，不完全一致的（差一个 [[photo]] token 之类）要在 App 里手动删，服务端不代删。

## 归因三修（2026-07-16 排查后落地，jianshuo.dev 6b59c22 已部署冒烟）

「好多人从链接装了但邀请人没反应」排查结论：一周 ~190 新账号仅 6 次归因（4 剪贴板
+2 上线自测）。**主因 = voicedrop.cn 腾讯云反代**：Pages 侧 `CF-Connecting-IP` 恒为
代理出口 IP（实测响应带 `via: 2.0 Caddy`），IP 指纹层对微信分享流量 100% 失效，
7-09 起文章分享页同病。三项修复：

- **第一方 beacon**：`POST /agent/referral/hit`（无鉴权，body=码/分享 id，解析不出
  owner 静默丢）——两个落地页内联 sendBeacon/fetch(no-cors) 让**访客浏览器直连**
  jianshuo.dev 报到，真实 IP 只有这条路拿得到。服务端 refhit 改为只在直连
  （无 x-forwarded-host）时写，反代垃圾停写。
- **剪贴板双保险 + 微信蒙层**：execCommand 同步先行（微信 webview 的
  navigator.clipboard 常不可用）叠 clipboard API；微信内点下载不跳转，弹
  「点右上角→浏览器打开」蒙层（剪贴板照写）。
- **邀请人到账推送**：claim 成功后 sendPush owner「你邀请的朋友装好了，算力 +N」
  深链 voicedrop://usage（复用投喂通道）——此前奖励静默进桶，成功了邀请人也无感。
- 测试：invite-link 23 例 / referral-landing 7 例，全量 1120 绿；线上冒烟：hit 204、
  两落地页含 beacon/execCommand/wx-mask。

## 归因再排查：零拉新 = 三层各有死因叠加（2026-07-16 深夜）

- **在售 iOS 1.3/1.4 不认 `/i/` 邀请链接**：剪贴板正则的 `/i/<码>` 模式 7-16 凌晨才进
  main（testflight/255 有，release/1.4 没有）——公众装的版本对邀请链接剪贴板层全废。
  等下一版上架才通。
- **PostHog「邀请落地页访问」distinct_id 全是同一个人**：id = IP 哈希，反代出口 IP
  恒定。已修（jianshuo.dev 0592eb7 已部署）：反代流量改读 `X-Forwarded-For` 首段
  （真实访客 IP）。⚠️ **X-Real-IP 不可用——Cloudflare 边缘会用连接方 IP 覆写它**
  （实测），XFF 是追加不覆写。落地页响应头 `x-vd-vid` 露出打点 id，`curl -I` 可核对
  （已验证：反代后 = 直连 IPv4 同哈希）。refhits 归因层仍只认浏览器直连 beacon
  （XFF 直打 pages.dev 可伪造，不进给钱的路径）。
- **安卓端其实有 ReferralManager**（houleixx/voicedrop-android，GitHub 代码搜索没索引
  到，别再用它下结论）。但有三坑已在本地修好待交付（分支 referral-invite-links）：
  ① 正则不认 `/i/` 邀请链接；② runOnLaunch 在 Application.onCreate 跑，无窗口焦点
  时 Android 10+ 拒读剪贴板——补了 RecordingsActivity.onWindowFocusChanged 焦点重试；
  ③ AppRouter 没有 INVITE 深链（已装用户点邀请链接开的是网页）。单测 315 绿。
  已交付：houleixx/voicedrop-android **PR #1**（fork jianshuo/voicedrop-android，
  分支 referral-invite-links）——等 houleixx 合并出新 APK 后，`/gh/` 直链要手改
  版本号（见 voicedrop-apk-distribution 记忆）。
- D1 真值（mint kind='referral'）：总共 6 条=2 自测+4 剪贴板（7-11 文章链接×3、
  7-16 凌晨邀请码自测×1）；新账号 20-40/天。IP 层 beacon 7-16 22:04 才上线，
  之前反代流量 IP 指纹 100% 垃圾——零拉新不是单一 bug。

## 邀请好友：设置页入口 + 邀请落地页（2026-07-16，服务端已部署，iOS 已合 main 未发 TestFlight）

referral 二期（补掉 2026-07-09 遗留 ④「主动邀请入口」）。设计稿 = claude.ai/design 项目
`Settings.dc.html`（邀请行）+ `Invite.dc.html`（分享 sheet 1b / 落地页 1c）。

- **邀请码一码两用**：码 = anon sub 前 6 位 hex 大写 ＝ App 设置页显示的账户短码
  （`inviteCodeForScope`，撞码退 10/16 位；非 anon scope 走 sha256 派生）。注册表
  R2 `invites/<码>` = `{owner, name, ts}`，name 每次取链接时从 CLAUDE.json profile 刷新
  （改名传导到落地页）。
- **服务端**（jianshuo.dev repo，worker 423081cc + Pages b83a98d3 已上线冒烟）：
  ① `GET /agent/referral/link`（anon/session 均可）→ `{code, url, name, enabled,
  suanliInviter, suanliFriend}`（奖励 = 面额 × mint-rate 现价，读不到回 0，客户端隐藏数字）；
  ② 落地页 `functions/voicedrop/i/[code].js`——深色品牌下载页（邀请人行/金色奖励条/
  三卖点/双下载键 App Store + jianshuo.dev/voicedrop/apk/，UA 弱化非本机端），访问写
  refhits IP 指纹（归因 2 层）、下载点击写剪贴板（3 层）、大写归一、未知码 404；
  ③ claim 的 `ownerFromToken` 认 `invites/<码>`——归因三层全部直接复用现有 referral。
  测试 `agent/test/invite-link.test.js`（17 例）。
- **分享卡片带 logo（2026-07-16 晚补）**：落地页 og:image/image_src 原来传空 →
  微信卡片空图标。已补 `voicedrop/icon-512.png`（App icon-1024 缩 512 的网页资产，
  两域可访问）+ 落地页拼绝对 URL（反代域 `voicedrop.cn/icon-512.png`、直连域
  `/voicedrop/` 前缀）。commit 56d5e03，Pages 已部署、双域线上验证过。文章/指令
  分享页无照片时仍是无图文字卡（有意保留），要品牌图可复用同一资产。
- **iOS**：设置页「账户·算力」卡下加单独一张「邀请好友」卡（SettingsView），副标题/
  「+N」徽标用现价（`SettingsStore.loadInvite`，0 = 隐藏数字）；点击拉系统分享 sheet
  （复用 SharePayload/ArticleShareItem——微信目标拿裸 URL 出 og 富卡片，其余拿文本）。
  `ReferralManager.shareToken` 新认 `voicedrop.cn/i/<码>` 与 `jianshuo.dev/voicedrop/i/<码>`；
  `AppRouter` 新 DeepLink `.invite(code)`（已装用户点邀请链接 → 记归因第 1 层 → 落 App
  主页，不看下载页）。单测 `VoiceDropTests/InviteLinkTests.swift`（6 例，全量 112 绿）。
- **真机手测清单（发 TestFlight 后）**：① 设置页邀请行出现、+N 数字合理 ② 点击弹分享
  sheet，微信里出「X 邀请你用 VoiceDrop」富卡片 ③ 链接在浏览器开落地页（奖励数字与
  App 一致）④ 新设备装后首启归因成功（invite 码走 link/剪贴板层）⑤ 已装设备点邀请
  链接直接进 App 主页。
- **分享零等待（2026-07-16 用户反馈修正）**：点邀请卡**立即**弹分享 sheet，不等
  loadInvite——邀请码 = 账户短码（anonId 前 6 位 hex，客户端与服务端 sha256 同源派生），
  链接本地拼；服务端回过权威链接（撞码加长极端情形）就用那个。注册表写穿放后台
  （设置页 .task 预取 + 点击时再兜一次）；离线分享的极端窗口 = 落地页暂 404，回线自愈。
- 已知边界：奖励文案「各得」只在双边同额时带数字（当前 9:9）；`enabled:false` 时 App
  仍显示入口（副标题通用文案）——要藏入口就等 loadInvite 加 gate，有意先不做；新增
  中文 String Catalog key 等夜间英文同步。

## 投喂到账推送：文章被投币 → 作者收 APNs，点开进算力账单（2026-07-16）

- **服务端**（jianshuo.dev repo `agent/src/mint.js`）：`POST /agent/feed` 双边
  grantBucket 之后给 `post.owner` 发 `sendPush`——「{投币者} 投喂了《{标题}》，
  算力 +X」，`link=voicedrop://usage`、`threadId=feed`。sendPush 尽力而为
  （缺 secret/无 token 静默 no-op），幂等分支（already）不重复推。
  测试在 `agent/test/mint.test.js`（vi.mock push.js 断言调用参数）。
- **iOS**：`DeepLink` 新增 `.usage`（`voicedrop://usage`，`billing` 也认）；
  LibraryView 新增 `navigationDestination(isPresented: $showUsage) { UsageView() }`
  ——点通知**直达账单页**，不绕设置页。其余深链分支互斥清理 showUsage
  （沿用「链接永远干净落地」约定）。
- 投币者自己不推（动作是他本人发起的）；安卓暂无推送通道，收币照常入账。

## referral 漏斗打点进 PostHog（2026-07-16，已上线）

「为啥没 refer 到人」从此可查。服务端直发四步漏斗（functions/lib/posthog.js，
waitUntil 后台 best-effort，POSTHOG_API_KEY 缺失=整体不打点）：
「邀请落地页访问」「邀请下载点击」（distinct_id=refhits 同款 ipHash，匿名）→
「邀请claim」（distinct_id=新账号 sub，属性【结果】= not-new/no-match/self/already/
归因成功… + ip_hash 关联键，与访问事件串漏斗）→ iOS 已有「邀请归因成功」。
key = iOS 同一只 phc_ 客户端 key（用户授权）：agent wrangler.jsonc vars + Pages
secret 两处。隐私红线不变：只送元数据、IP 只以 HMAC 哈希出现。
查看：app.posthog.com → Activity 筛「邀请」。
背景结论（2026-07-16 排查）：7-11 后零 referral 非 bug——主动邀请入口 7-16 才上线、
归因仅限新账号（重装不算：anon 身份在 iCloud 钥匙串）、CGNAT 放弃、1.3 刚在售。
测试方法：模拟器（钥匙串独立=真新账号）访问 voicedrop.cn/i/<码> → 装 app 首启。

## 锚点协议：长按目标结构化上传，提示词回归自然语言（2026-07-16，服务端已上线，iOS 随本班 TestFlight）

spec = `docs/superpowers/specs/2026-07-16-anchor-protocol-design.md`，plan 同名 plans/。
长按图/文字菜单动作把目标作为 `anchor` 字段随 WS instruct 上传（`{type:"image",key}` /
`{type:"line",line,text:整行原文}`），编辑 DO 队列存列（照 article_index 模式 ALTER 迁移），
`runEditTurn` 校验后 varLines 注入独立上下文行。要点：

- **校验宁缺勿错 + 漂移自愈**：image key 两代格式归一后 membership（legacy `[[photo:N]]`
  数字 token 经 doc.photos[N-1] 解析——final review 抓的 Critical，249a442 修）；line 行号
  +整行原文一致，正文被并发编辑动过时按整行唯一匹配修正行号，失败丢弃不注入。
- **行号口径单一真源** = linenum.js（1-based，与 edit_current_article 工具/iOS bodyRows 同构）。
- **无 anchor = 现状逐字节一致**（回归锁测试）；占位符 {{KEY}}/{{LINE}}/{{QUOTE}} 替换保留，
  双供给无冲突。语音自由指令/回答追问/库级命令无锚点（设计如此）。
- **Phase B 待办**：sys_* 模板改写自然语言（去占位符）——前置=新版覆盖足够（老 App 无
  anchor，模板去占位符会让老 App 多图文章退化）；改模板记得同步 iOS 内置兜底快照。
- 新建提示词输入框有空态引导（自然语言示例）。
- **真机手测清单**：① 多图文章长按第 2 张图选水彩 → 确改第 2 张（金标准）② 长按中间段
  选更简洁 → 确改那段 ③ 自建自然语言提示词（无占位符）多图精确命中 ④ 老提示词（带占
  位符）行为不变 ⑤ 语音自由指令回归。

## 提示词社区帖：分享即发帖 + 社区「提示词」tab（2026-07-15，服务端已上线，iOS 待真机手测+TestFlight）

spec = `docs/superpowers/specs/2026-07-15-prompt-community-posts-design.md`，plan 同名 plans/。
SDD 执行记录在 `.superpowers/sdd/progress.md`。**服务端已部署**（agent worker 36190a31 /
reco d785d93e / Pages 3a45768e，D1 migration 0003 已 apply），线上冒烟过：feed 115 帖带
kind=article、匿名 403、新 MCP 工具可用。iOS 4 个 commit 已合 main **未发 TestFlight**。

- **数据模型**：提示词帖 = `community/<shareId>.json` 的 `kind:"prompt"` 变体
  （`promptCode` 指向 `shares/<码>` 写穿副本，内容零复制实时读）；
  `shareId = HMAC("promptshare:<码>")` 从码派生（fork re-key/复活全自动成立）。
  D1 community_posts 加 `kind` 列，reco feed / community/list 双路径透传。
- **同生同死（四条路径全闭环）**：开分享=铸码+发帖；关分享/社区取消分享/举报
  resolve-remove/销号——都连 `shares/<码>` 一起删（后两条是最终全分支 review 抓的漏，
  aca6df2 修）。再开=同码同帖复活（firstSharedAt 重置，计划明文接受）。
- **门槛收紧（产品决策）**：POST /agent/prompt-share 需 Apple/微信 session，匿名 403
  needs_apple_signin——**匿名不再能铸码**。铸码前 checkArticlesShareable 关键词审核。
- **老 App 兼容**：community/get 对 prompt 帖合成 `articles:[{title:label,body:全文}]` +
  kind + promptCode，老客户端当文字帖渲染（可读/投币/回应，无导入按钮）。
- **iOS**：CommunityFeedView 四 tab（推荐/最新/回应/提示词，混排+客户端过滤）+
  TextCoverCard「提示词」角标；CommunityPostView「收下这条提示词」CTA（gate:
  kind=prompt && promptCode && !mine，走 PromptStore.shared.importPrompt）；
  PromptEditView 开关文案改「分享到社区」，403 拉起 Apple 登录重试一次
  （二次拒绝返回可见错误，不伪装成功——review 抓的竞态）。
- **真机首测后的修复轮（2026-07-16，四个包：a095346/32067ff/09e575d/470227c + 服务端两轮提速）**：
  ① feed 行映射漏 kind →「提示词」tab 恒空（FeedRow→CommunityPost 手工映射，**加字段
  必须三处同步**，代码里有警示注释）；② 分享失败文案按服务端错误码映射（笼统「操作失败」
  掩盖过 413/审核/401 排障）；③ 提示词帖详情页对齐落地页形态（分享码+内容盒+怎么用——
  合成 articles 只是老 App 降级，不是新版展示）；④ 开关闪烁 = 先放开 toggle 再刷状态的
  时序反了；⑤ **开分享 10 秒 = 15 个串行存储操作积垢**（必需仅 5：读树/读索引/验码/写索引/
  写副本；3 个读的是生产不存在的运营配置；发帖四连挪 waitUntil；黑名单预取并行+首铸跳
  importCount 保护读）——关键路径现 ~3 个来回。教训：每个功能各加一两跳没人算总账。
- **⚠️ token 坑（2026-07-16 真机 bug，a095346 修）**：`AuthStore.bearer` **永远是
  anonToken**（Apple 登录后也不变），登录证明在 `AuthStore.shared.session`（JWT）。
  任何要过「可追责身份」门槛的请求（社区写、prompt-share）必须送 `session ?? bearer`
  ——CommunityStore.shareToken 与 PromptLogic.shareAuthToken 都是这个式子。只送
  bearer 会 403 needs_apple_signin 且拉起登录也救不回（重试还是送 bearer）。
- **已知缺口：MCP 的 share_prompt 对所有人 403**——配对登录发的是 anon 型完整密钥，
  不是 session JWT，服务端无从验证 Apple 绑定（绑定不落盘，session 即证明）。要解得
  另立项（配对流程发 session / 服务端持久化绑定标记），暂记录。
- **真机手测清单（发 TestFlight 后必跑）**：① 开分享→社区三处立见（推荐/最新/提示词
  tab，卡片带角标）② 另一账号打开→全文+收下→长按菜单立即可用 ③ 投币/文章回应
  ④ 关开关→帖码同消（feed+短链「分享已停止」）⑤ 再开→同码同帖 ⑥ 匿名翻开关→
  拉起登录→重试成功 ⑦ 老版本 App 打开 prompt 帖当文字帖可读 ⑧ 自己的帖无导入按钮。
- 已知边界（有意不做）：删除提示词条目不自动关分享（帖码冻结，与码现状一致）；
  D1 挂时 R2 慢路径 prompt 卡无题无预览（窗口期展示降级）；导入成功双埋点
  （「社区提示词导入」+「提示词导入码兑换」，分析时注意）；4 个新中文 key 待夜间
  英文同步收敛。

## PostHog 产品分析已接入（2026-07-14，模拟器验证事件已送达）

- SPM 包 `posthog-ios`（project.yml `packages:`，from 3.0.0）；初始化在
  `Analytics.swift`（`VoiceDropApp.init()` 调用），host = US cloud。
- **key 链路**：`Secrets.xcconfig` 的 `POSTHOG_API_KEY` → project.yml info
  properties `PostHogAPIKey: $(POSTHOG_API_KEY)` → Info.plist 构建期替换 →
  `Bundle.main` 读取。**key 缺失/为空 = PostHog 整体不启用**（guard 直接 return，
  App 行为不变）。CI 侧 build.yml 重建 Secrets.xcconfig 时从 GitHub secret
  `POSTHOG_API_KEY`（已 gh secret set）写入——改 Secrets 相关内容记得三处同步：
  本地 xcconfig / Secrets.example / build.yml。
- DEBUG build 开 `config.debug`（console 可见每条事件上送日志）；Release 不开。
- 看数据：app.posthog.com → Activity。
- **identify（2026-07-14 二期）**：`Library.ownerScope()` 的 /whoami 成功后剥出 sub
  调 `Analytics.identify(sub)`（LibraryView 启动 task 顺手触发一次保证每次启动都走到）；
  `AppleAuth.signOut()` 调 `Analytics.reset()` 防串号。
- **手动埋点约 24 个事件（中文事件名）**，统一走 `Analytics.capture`。
  **隐私红线（隐私政策已对外承诺，加新埋点必须遵守）：只送元数据
  （类型/时长/计数/布尔），任何用户内容——正文/指令文本/转写——绝不进 PostHog。**
  分布：录音（开始/完成/失败/拍照/上传完成/上传失败，RecordSession/Uploader）、
  采访（开启/结束，RealtimeInterviewer）、语音编辑（发起——普通修改/回答追问/库级命令
  + 落地含耗时秒与成败，AgentSession/LibraryCommandSession）、原位编辑完成、
  文章打开、追问（回答/跳过）、分享（创建分享链接/发公众号/小红书导出）、
  社区（发到社区/取消分享/投币/社区互动/社区浏览 tab）、提示词（保存/分享开关/导入码兑换）、
  邀请归因成功、登录完成。
- **上下文 super properties（2026-07-15）**：`Analytics.screen(名, stem:)` 把
  「当前界面」「当前录音」注册成 super properties，之后**每条**事件自动带上——
  任何动作都能回答「用户当时在哪个界面、看哪条录音」；同时记「界面进入」事件
  形成动线。挂载点 5 个：录音列表（onAppear，回列表即清「当前录音」）、
  录音详情（带 recording.stem，时间戳文件名非内容）、社区、提示词管理、账户。
  加新界面时记得挂 `.onAppear { Analytics.screen("<名>") }`。
- **隐私政策已同步披露**（jianshuo.dev repo `voicedrop/privacy` + `voicedrop/en/privacy`，
  2026-07-14 已部署）：删掉了「没有第三方分析」旧承诺，新增 PostHog 条目。
  App Store Connect 隐私标签已由用户手动更新（2026-07-15）：新增「标识符→用户 ID」+
  「使用数据→产品交互」，均关联身份、用途=分析、不用于追踪（无需 ATT）。

## 键盘精修 v2：长按菜单「编辑」→ 原位编辑（2026-07-14，用户拍板重做后上线）

v1（PR #9 / commit `cc13560`）真机错误百出当天 revert（`50bd5b0`）后，用户明确
要求按新约束重做：**长按的所有 behavior 不变；编辑全程排版零变化；编辑完恢复
阅读态**。v2 实现（`InlineParagraphEditor.swift` + RecordingDetailView 最小改动）：

- **入口**：长按菜单 localRows「拷贝」下面加「编辑」。长按手势本身一行没动
  （v1 的教训：为拿触点坐标改成 sequenced 手势，菜单从「按住即弹」变成
  「松手才弹」——这就是行为回归，别再犯）。
- **排版零变化**：无描边框/出血/内边距/淡出；UITextView 与只读 Text 逐项对齐
  （16pt / lineSpacing 9 / 零 inset / 同色），`sizeThatFits` 按提议宽度自适应；
  编辑态顶栏「取消/完成」frame 锁 40pt 与平时工具栏同高。只有目标段被键盘盖住
  时才 `scrollTo(anchor: nil)` 最小滚动。
- **光标**：不做「落在长按点」（v1 的坐标换算是 bug 之源）；光标落段尾，
  点哪儿改哪儿全走 UITextView 原生行为。
- **数据层**（沿用 v1 已验证部分）：`ArticleBody.replacingLine` 按 bodyRows
  同一套「文字游程+图片标记各占一行」切分精确替换单行；`LibraryStore.saveArticles`
  现拉服务端原始 JSON 只 merge `articles` 一个 key 再 PUT（`ArticleDoc` 没建模
  `schema`/`status`/`model` 等字段，整 struct 重编码回传会冲掉它们——所有对
  `PUT /articles/<stem>` 的部分更新都必须走这个套路）；该端点不经 LLM、自动铸
  版本，undo/redo 天然可用。单测 `ArticleBodyLineReplaceTests`（9 例）。
- 编辑中锁交互：长按文字/图片菜单不弹、章节 chips `allowsHitTesting(false)`、
  说话条隐藏（退出恢复）。
- 教训存档（与 2026-07-12「实时预览 UI 已撤销」同款）：自绘手势 + UIKit 桥接的
  交互，模拟器/单测全绿≠能用，**必须真机手测过再发**。v2 经用户本地验证后才 push。

## 性能改造第二轮（2026-07-13，API 速度体检后落地）

服务端（jianshuo.dev repo）四连改 + 本 repo 一处，全部已上线实测：

- **community/list、community/replies 走 D1 展示索引直出**（7s → 0.2-0.3s），
  响应后 waitUntil 全量对账（reconcileIndex，与 admin reindex 共用）。
- **GET /articles 列表索引直出**（1.0-1.7s → ~0.45s）：article-store 四个写入口
  收口到 putArticleDoc 同步维护 articles-index.json；R2 listing 权威、退到
  waitUntil 对账。community/get 的索引自愈回写也挪进 waitUntil（0.85s → ~0.55s）。
- **GET /recordings 轻量录音列表**（新路由，~0.5s）：recordings-index.json
  （上传/直删 .m4a 同步维护）+ articles-index 的 sidecar 标记（empty/blocked/tags，
  /empty /blocked 路由与 .tags 上传/删除同步点亮熄灭）并发直出四个状态位。
  教训：delimiter listing 在 R2 内部仍要扫过全部 key（1.0-1.6s），不能放请求路径。
- **照片缩图归服务端（2026-07-14 定案，别在客户端缩图）**：jianshuo.dev zone 已开
  Cloudflare Images Transformations，展示面小图走
  `/cdn-cgi/image/width=512,quality=60/files/api/photo/<key>`（218KB→33KB，边缘缓存
  后 0.15s）。iOS 的 preferThumb 即这条路，zone 开关关掉时自动回退原图；安卓/网页
  以后同样拼这个 URL，客户端一律不做缩图、不传 .thumb 文件（曾试过端上旁挂
  .thumb.jpg，已撤销并清光 R2 遗留）。计费：5,000 唯一转换/月免费，超出 $0.50/千，
  当前量级 $0。PhotoService 另有磁盘缓存（photo key 不可变→永久可信）治重复下载。
- **本 repo：Library.loadOnce 首选 GET /recordings**（fetchRecordingRows），
  老服务端没有该路由 → 自动回退全量 GET /list 客户端自筛（老行为原样保留，
  ListResponse 别删）。/list 接口继续存在：老版本 App、24h 只读 token、Mac
  入库管道还在用，只是新 App 主界面不再碰它。

## 性能改造（2026-07-12，性能审计后落地）

三处结构性提速（jianshuo.dev repo 两处 + 本 repo 一处），审计结论：瓶颈在服务端，iOS 端整体健康。

- **Miner 按用户分片**（`agent/src/index.js` + `miner.js`）：上传/用户触发 →
  `idFromName("miner:<scope>")`，每个分片只 list 自己用户的前缀、只挖自己的录音——
  一个用户的长录音不再阻塞其他所有人；10s resume pass 不再全量扫桶。原单例
  `"miner"` 降级为 sweep 调度器（6h cron/admin 手动）：整桶 list 一次、把有活的
  scope 踢给对应分片，自己绝不挖矿（sweep 与分片因此不可能双挖同一条录音）。
  ops 错误计数照旧在单例。测试 `mine-sharding.test.js`。
- **GET /articles 列表摘要索引**（`functions/files/api/[[path]].js`）：per-user
  `users/<sub>/articles-index.json`，稳态 = prefix list + 1 次索引读，不再每篇
  整档 GET（schema-3 信封含 10 版正文+全文转写，此前只为取标题全读）。索引是
  **自愈缓存、只由该路由维护**：R2 listing 为准，etag 变了才重读该篇，删除自动
  剪除，坏了整体重建；所有写入方零改动。**transcript 保留在文章 doc 里（用户
  拍板不拆）**。注意 iOS 列表刷新走的是 `GET /list`（纯元数据），此索引主要提速
  网页文章列表/admin。测试 `articles-index-cache.test.js`。
- **iOS 详情页正文解析缓存**（`RecordingDetailView.swift` BodyParseCache）：
  bodyRows 的正则分段 + 每段 AttributedString(markdown:) 曾在每次重绘（按住说话
  开/关、高亮淡出）整篇重跑；现按 (body, photos) memoize，重绘 = 字典命中。
  引用类型 @State，body 求值中改内容不触发失效循环。

## ⚠️ 实时预览 UI 已撤销（2026-07-12 晚，用户拍板）——但服务端流式基建保留

正文内打字机（行级替换/插入 + 整篇幽灵稿）在真机上引入多个难预料的布局 bug，
用户决定撤销**全部预览渲染**（7a67fcd）：编辑/重写回到「一次性出结果」。
**别在没有用户明确要求时重新引入预览 UI。** 保留的部分：
- 服务端全部照旧（流式调用是 524 修复的根基；preview-delta/edit-preview 照发，App 忽略）；
- AgentSession 的预览消息解析（回调未挂 = 忽略）；
- preview-done → finishRestyle 双路收尾（长文重写超 HTTP 超时也能落定）+ restyle 300s 超时。

## 已撤销的原设计（存档）：编辑实时预览全家桶（2026-07-12，服务端仍在线 + E2E 实测）

LLM 调用全面改流式（anthropic.js 永远 stream:true，SSE 内部聚合、调用方零改动），
由此解锁三层实时预览 + 修复超长录音挖矿事故链：

- **524 根因修复**：非流式被 Anthropic 门口的 Cloudflare ~100s 掐线;2h12m 录音
  (4万字转写)168s 生成必死。流式后一次成功——那条录音已挖出 13 篇文章。
  连带:ASR checkpoint(.asrdone.json,完成即落盘,失败重试复用不重扣费,
  asrCharged 按 stem 终生一次)、连续失败熔断(5 次→.blocked(mine-failed)+
  admin 推送)、挖矿 max_tokens 8000→24000(截断报人话错误)。
- **重写幽灵稿**（/agent/restyle + write_article 工具）：preview-delta/reset/done
  经详情页 WS 广播,App 显示流式长出的新稿;preview-done 兜底 HTTP 超时收尾。
- **行级打字机**（edit_current_article 工具）：edit-preview {i,op,line,text},
  App 底部卡片显示「第 N 行 · 改写中」+ 流式新文本。
- **relay 透传**：中转 DO 把 SSE 原样管回,调用方聚合——地域封锁用户同样有增量。

核心部件 agent/src/preview.js（PreviewExtractor/EditOpsExtractor：JSON 流里剥
纯文本,任意 chunk 切断安全;makePreviewPusher/makeEditPreview 合批广播）。
E2E:重写 93 批增量/2107 字符,编辑打字机 replace_line 增量+updated 全过。

## 已上线：Prompt Manager 重构 Phase 1 —— ref/fork 模型服务端（2026-07-14 部署）

提示词后端整体换模型。spec = `docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md`，
plan = `docs/superpowers/plans/2026-07-13-prompt-manager-phase1-server.md`。
**PR jianshuo.dev#22 已合（cf4b668），worker 版本 `f4cd16cd` 已部署。线上冒烟全过：
`GET /agent/prompts` 200（sys_* items）、三个老端点 404、公开导入预览查无码 404、无 token 401。**
⚠️ 冒烟时发现历史遗留（非本次引入）：**worker 的 `FILES_TOKEN` secret ≠ Pages/`~/code/.env` 的那份**
——老 admin 路由 `/agent/usage/admin/accounts` 用本地 token 也 401。admin 类路由（registry/usage admin）
要用 worker 自己那份 secret；prompt.jianshuo.dev 调优页自带正确 token，不受影响。要统一就
`wrangler secret put FILES_TOKEN`。

- **核心 = ref → fork**：模板 `agent/src/prompt-template.js`（R2 `config/prompt-template.json`
  可整体覆盖，**生产上当前两个 config 文件都不存在（404），代码字面量即真源**）+ 每用户
  `users/<sub>/prompts.json`。每项 `{"ref":"sys_*"}`（跟随模板最新）或完整实体（冻结，
  `forkedFrom` 标记 fork 来源）。**没有 prompts.json = 全跟随** → GET 绝不为新用户落盘（落盘=冻结）。
- **老语义 id（voice-editor.longpress.*）与 `/agent/ui-config*` 全部删除**。部署后老 app：
  长按菜单静默退内置默认（UIConfigStore.refresh 失败=保留现值，不崩）、老设置页「提示词」报
  加载失败。已确认接受；Phase 2 iOS 要紧跟。
- **端点**：`GET/PUT /agent/prompts`（写只有整树 PUT）、`POST /agent/prompts/{restore-defaults,import}`、
  `GET /agent/prompt-share/<code>`（**公开**导入预览，author 无名回空串）。`prompt-registry`
  改读写 `config/prompt-template.json`（对外形状不变）。铸码走新解析器 → **自建提示词第一次可分享**；
  PUT 保存活同步分享中的条目。老魔法数字继续能兑换（写穿副本不依赖 itemId）。
- **prompt-classify 已砍**（2026-07-13 用户拍板，实现过又删）：新建默认「都行」，无 AI 建议。
- **Phase 2（iOS）未做**，spec §9。**服务端遗留给 Phase 2 的三件事**（终审发现，记在
  worktree `.superpowers/sdd/progress.md`）：① 分享状态读端点（老的随 ui-config/custom 死了，
  PromptEditView 分享卡需要；用 POST 试探会把已关的分享复活）；② fork 一条正在分享的 sys_* 条目会让
  分享码永远停在旧内容（需设计决策：fork 时 re-key 或客户端转移）；③ registry PUT 无 MAX_PROMPT 上限（admin-only）。
- 对抗性 review 全程抓出 **12 个真实缺陷**（校验器可被 5MB 载荷打穿/会 throw 成 500、恢复默认重复
  补条目/超 200 上限、匿名作者显示成机器码等），全部修复 + 回归测试。计划文档已同步修正。

### Phase 2（iOS）——已上线（2026-07-14）：PR #24 已合并部署（worker `97c94d38`），iOS 合 main 后经 workflow_dispatch 发 **TestFlight build 99**

> ⚠️ ~~发版规矩（2026-07-09 起）：**push main 不会自动发 TestFlight**——commit message 带 `[tf]`
> 或 `gh workflow run build.yml -f destination=testflight` 才上传（苹果 ~20 包/24h 限额）。CI 绿 ≠ 出包。~~
> **2026-08-02 已撤销**：push main 恢复自动发 TestFlight（见顶部当日条目）。

### 第 6 轮拖拽（6a–6d）——分支 `prompt-drag-6a6d`，2026-07-14

handoff `design_handoff_prompt_manager 2/`。Phase 2 Task 7 的原生 `onMove` 排序**作废**，换全自定义拖拽：

- **`PromptDragEngine.swift`（新）**：纯几何逻辑（无 SwiftUI），`RowFrame`/`DropTarget`/`Scope`；
  `dropIndex`（手指 Y + 行帧 → 落点：同域排序 / `.intoGroup` / `.outOfGroup`）+ `apply`（落地，
  委托 `PromptLogic.moving*`）。24 个单测（含嵌套源不重复、两级封顶双保险、空组/边界）。
- **编辑态**（`PromptManagerView.swift` 重构）：普通态仍是 List（左滑删除等全保留）；编辑态换
  ScrollView+VStack——行帧经 PreferenceKey 收集（named coordinate space），**≡ 左手柄是唯一拖动
  发起点**（`DragGesture` 挂手柄上），拖起行画在 overlay 跟手（1.03 + 抬起投影；悬停 folder 加码
  1.04 + rotate -1°）。落点 = 44pt 琥珀虚线缝隙。folder 悬停 **0.3s** 张口（`#FBF3E9` 底 + `#D8A25B`
  边 + 4px 外发光环 + 图标变 `folder.badge.plus` + 「放进「X」」「松手收纳」）；拖组内行时 folder 卡
  下方出「移到分组外」落点区（接受域 = 组跨度之外任意处，落点=folder 之后——比设计字面更宽容，有意）。
- **手势生命周期**（review 抓的坑）：拖动中源行**高度塌 0 但保留视图身份**（从 ForEach 移除会杀死
  进行中的手势 → 浮层卡死）；换行拖动有 takeover guard；scenePhase 离开 active 强制复位。
- **known trade**：无拖动自动滚屏（列表典型 15 行，200 封顶）；dwell 计时在 View 层（Task.sleep，
  计划许可）；真机 QA 必测项=组内排序/收纳/拖出全链路 + 0.3s 手感。
- 数据层零改动（draft + 整树 PUT + baseline 冲突检查全复用），服务端零变更。

spec = `docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md` §9，plan =
`docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md`（分 8 个 task，TDD，
逐 task 提交在 `prompt-manager-phase2` 分支）。Task 8（本次）删掉最后的老文件、跑完全量验证。

- **新文件**：`PromptStore.swift`（整树模型 `PromptNode`/`PromptAnchor` + 网络层 GET/PUT
  `/agent/prompts` + `restore-defaults`/`import` + 按 `appliesTo` 过滤出长按菜单用的
  `UIMenuConfig`——挪进 `ConfigMenu.swift` 消费，视觉不动）；`PromptManagerView.swift`
  （设置 → 提示词，新列表页，替换老 `InstructionSettingsView`；支持 5a 分组展示/1b 左滑删除/
  1d+1a 拖动排序含拖进分组/4a 新建入口）；`PromptEditView.swift`（编辑单条，两个开关+分享卡，
  分享卡 UI 从老 `InstructionSettingsView` 原样搬来）；`PromptNewSheet.swift`（新建提示词，3c，
  默认「都行」无 AI 分类建议——分类功能已在服务端砍掉）；`PromptImportSheet.swift`
  （导入码流程，4b）。**`VoiceDropTests` target 是本仓库第一个单测 target**
  （`VoiceDropTests/PromptStoreTests.swift`，68 个用例，覆盖模型/过滤/reorder/fork/merge 逻辑），
  项目由 xcodegen 生成，`project.yml` 的 `VoiceDrop.scheme.testTargets` 已声明；跑法：
  `xcodebuild test -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VoiceDropTests`
  （新增 `.swift` 文件后照例先 `xcodegen generate`）。
- **删除**：`UIConfigStore.swift`（Task 3，随长按菜单切到 PromptStore 一起删）、
  `InstructionSettingsView.swift`（Task 8，本次；分享卡 UI 已在 Task 5 原样搬进
  `PromptEditView.swift`，`ShareCodePayload`/`shareAction` 两边都是 `private`，删除前
  grep 全仓确认零外部引用）。
- **PromptStore 三级回退**：network（`GET /agent/prompts`）→ `UserDefaults` 本地缓存
  （上次成功拉取的整树）→ **内置兜底**（客户端字面量镜像服务端 `prompt-template.js` 的
  `sys_*` 默认值）。⚠️ **服务端模板字面量变了，客户端内置兜底不会自动跟着变**——iOS 这份
  是手抄的快照，改服务端默认提示词时记得同步改这份，否则断网用户（第三级）看到的是旧默认值。
- **fork-on-edit 语义**：编辑一条 `{"ref":"sys_*"}` 系统条目 = 客户端把它实体化成完整节点
  （`forkedFrom` 记来源），整棵树 PUT 落盘；分享码跟着走：PR jianshuo.dev#24
  `prompt-shares-readapi` 分支的 `rekeyForkedShares` 在服务端 PUT 保存时把 `shares/<码>`
  的 owner 索引从老 ref id 挪到新 fork id（码不变），随后现有的「保存时刷新分享内容」同步
  把 fork 后的新文本写进码。「恢复默认」= 整体丢弃 fork 换回 ref（未做单条粒度恢复，spec
  原说的按钮简化为整体操作，视为有意裁剪，见 Task 8 brief 的 Self-Review）。
- **菜单 = 从同一份列表客户端过滤**：`ConfigMenu.swift` 不再单独打一次网络请求，而是吃
  `PromptStore` 拉回的整树，按每个节点的 `appliesTo`（文字/图片…）本地过滤出对应长按菜单，
  长按文字菜单和长按图片菜单是同一份数据的两个视图，新建/编辑/删除立刻反映到两边。
- **AppRouter 7 位数字深链**：`https://voicedrop.cn/<7位魔法数字>` → `.promptImport` case →
  落 `PromptImportSheet`（与老的「AI 指令」魔法数字兑换页复用同一套 7 位码解析器/正则，
  只是落地视图从老设置页换成新 Prompt Manager 的导入 sheet）。
- **reorder = 本地草稿 + 整树 PUT**：拖动排序全在本地维护一份草稿树（`PromptStore` 的
  moving 系列纯函数，68 个单测里大头是这些——跨分组拖动、分组进分组拒绝、越界 clamp 等），
  松手才整树 PUT 落盘；PUT 带 baseline 冲突检测（保存前服务端整树若已变化于本地拉取时的
  快照，拒绝覆盖，避免多端并发排序互相打架——具体冲突提示见 `PromptStore.swift` 内注释）。
- ⚠️ **发版顺序硬约束**：iOS **不能在 jianshuo.dev PR #24（`prompt-shares-readapi`，
  截至 2026-07-14 仍 OPEN，未合并未部署）落地前上 TestFlight**——`PromptEditView` 的分享卡
  读分享状态靠 `GET /agent/prompt-shares`，这个端点是 PR #24 加的；没它，分享开关在新
  设置页会读不到状态（老的 `ui-config/custom` 里的 `shareCode`/`sharing` 字段已随 Phase 1
  删除）。同理 fork 后分享码保活也靠 PR #24 的 `rekeyForkedShares`，没部署的话 fork 一条
  正在分享的系统条目会让分享码停在 fork 前的旧内容。
- **手测清单**（人工 QA，见 `.superpowers/sdd/task-8-report.md`；模拟器脚本能力有限，
  交互手势必须真人跑一遍）：① 设置→提示词打开新列表（不再「加载失败」）② 长按文字/图片
  菜单 = 过滤视图，新建的文字项立刻出现在长按文字菜单 ③ 编辑一条系统项 → 徽标变「已自定义」
  → 长按菜单吃到新文本 ④ 删除 → 恢复默认能找回 ⑤ 导入码全流程（需 PR #24 部署）⑥ 分享
  开关 + fork 后码不变（需 PR #24 部署）⑦ 断网 → 长按菜单仍能渲染（内置兜底）⑧ **在展开的
  分组内部重新排序**（nested onMove，本轮最担心的风险点）⑨ 把一个动作拖进分组；分组内条目
  「移出分组」左滑；分组拖进分组应被拒绝 ⑩ 深链 voicedrop.cn/<7位码> 落到导入 sheet。

## 新功能：指令分享码「魔法数字」（2026-07-11，服务端已上线，真机手测通过，TestFlight 已发）

**2026-07-11 验证与部署（Mac 侧）**：agent 全量 75 文件 731 用例绿；iOS xcodebuild
BUILD SUCCEEDED（含改名后二次构建）；jianshuo.dev 分支已合 main 并部署——worker
版本 ded919c4 + Pages（jianshuo.dev/voicedrop/<码> 与 voicedrop.cn/<码> 均已线上
冒烟：查无码 404「分享已停止」）。**产品措辞全面改名「AI 指令」→「提示词」**
（用户拍板）：iOS 设置入口/编辑页（我的提示词/默认提示词）/分享卡「分享这条提示词」/
分享文案/String Catalog 七个 key（英文同步 prompt 措辞），服务端落地页/注入块
（【分享提示词开始/结束】、回复提「分享提示词」）/测试断言。R2 config/prompt-share.json
未 seed（走代码默认值，需要调再 seed）。iOS 已随真机手测通过合入 main 发 TestFlight。

用户在 设置 → AI 指令 → 编辑页开「分享这条指令」开关 → 得 7 位数字码（同时就是
voicedrop.cn/<码> 短链）；别人语音里说「用 <码> 改这段」→ 服务端识别、把共享指令
一次性注入本轮 prompt（不改使用者设置）。spec =
`docs/superpowers/specs/2026-07-11-prompt-share-magic-number-design.md`，plan 同名。
两仓库同分支 `claude/ai-instruction-storage-8jf5u2`（jianshuo.dev + voicedrop）。

- **一个注册表**：`shares/<码>` 与文章分享同命名空间——文章条目值是纯文本
  articleKey，指令条目是 typed JSON **写穿副本**（label+instruction 当前生效文本）。
  保存指令时 `ui-config-custom.js` 经 `refreshPromptShare` 同步重写（活绑定）；
  开关关 = 删 `shares/<码>`，owner 索引 `users/<sub>/prompt-shares.json` 保留 →
  再开**同码**复活。已知边界：运营改全局默认不推送到已分享的未自定义条目。
- **服务端**（jianshuo.dev）：`agent/src/prompt-share.js`（POST/DELETE
  /agent/prompt-share，铸码撞重摇、日上限/长度/开关走 R2 `config/prompt-share.json`
  `{enabled,dailyCapPerUser:20,maxLength:4000,notFoundNote}`）；兑换识别在
  `edit-turn.js`/`command-turn.js`（正则 `(?<![0-9])[1-9][0-9]{6}(?![0-9])`，先做
  ASR 断句归一，8 位+/首位 0 不命中，每轮取首个；查无注入软备注）；落地页
  `functions/voicedrop/[token].js` prompt 分支（纯数字码查无 → 「分享已停止」404）。
  GET /agent/ui-config/custom 每条多 `shareCode`/`sharing` 两字段。
  测试：`prompt-share.test.js`(31) + `prompt-share-landing.test.js`(5) + 两 turn 各 2；
  全量 75 文件 731 用例绿。
- **iOS**：只改 `InstructionSettingsView.swift`（分享卡 + setSharing + ShareSheet
  文案）。兑换侧零 iOS 改动（老版本 App 服务端部署后立即可用）。
- **部署顺序**：先 agent worker + Pages（`npx wrangler deploy`），可选 seed
  config/prompt-share.json，再 iOS TestFlight。
- **真机验证**（2026-07-11 全部通过）：① 开关 → 出码/关码/再开同码；② voicedrop.cn/<码> 落地页样式与
  「分享已停止」；③ 改文本保存后落地页（≤5min 缓存）与兑换同步；④ 另一账号语音
  「用 <码> …」按共享指令执行、回复提指令名、设置不变；⑤ 断句「123，4567」命中、
  错码回复无效、库级命令同样生效。**Linux 容器没跑过 xcodebuild，iOS 需先真机构建。**
- 二期挂起：VD社区原生提示词帖、一键导入收藏、中文数字码。

## 最近改动：社区列表页改 D1 索引后台（2026-07-14，已上线）

社区展示页后台从「R2 全量扫描」换成「reco 的 D1 物化索引」。**R2 community/*.json
仍是真源**，D1 表 community_posts 只是可全量重建的展示索引：

- **新端点 `GET /reco/feed`**（reco worker）：一次带回 列表元数据+推荐序+每帖红心/
  回应数+我赞过的。替代 app 老的 list(每帖2次R2读) + rank 两步。线上实测 106 帖
  0.23s，与 R2 list 逐项校验一致（ids/标题/封面/时间序零差异）。
- **双写**（files API，Pages 侧新增 RECO_DB 绑定=voicedrop-reco 同库）：share upsert /
  unshare delete / report hidden=1 / resolve 同步 / 销号 delete-by-owner / 孤儿 reap
  连索引删。**详情打开(community/get)顺手 upsert**——文章编辑后 feed 的过期卡片靠
  这个自愈。索引写失败一律吞掉不打断主路径。
- **重建**：`POST /files/api/community/reindex`（admin，FILES_TOKEN 在 ~/code/.env），
  幂等，回填/漂移兜底用。首次回填 indexed:107。
- **iOS**：`CommunityStore.load()` 首选 loadViaFeed()，失败/空索引回退老路径
  loadViaListAndRank()（R2 list + rank，兼容老服务端）。
- 已知边界：文章编辑不直接写索引（agent worker 挖矿/编辑不碰 D1），靠详情打开自愈
  ＋ reindex 兜底；如嫌不够，可给 agent 5min cron 加一次 reindex 调用。
- 迁移：reco/migrations/0002_community_posts.sql（已 apply --remote）。

## 最近改动：社区改双排瀑布流（2026-07-13，已上线服务端，iOS 待发版）

按 ~/Downloads/design_handoff_community_feed 方向 1a（小红书式图文混排）重做社区列表页：

- **iOS**：新文件 `CommunityFeedView.swift`（两列贪心 masonry；照片帖图封面高度随原图
  宽高比，文字帖三色暖渐变封面按 shareId hash 取色；标题细体不加粗——用户拍板；元信息行
  = 头像+作者+红心被赞数(常显)+回应数(>0)；回应帖 ↩ 胶囊角标；推荐/最新/回应分段 tab）。
  `LibraryView.communityContent` 的旧单列 List 已删，取消分享从侧滑改长按 context menu。
  「最新」= store.timeOrdered（服务端时间序快照，不经 reco）；「推荐」= reco 排序。
  曾做过「最新」专属单列时间流，用户拍板 revert——两 tab 同一副瀑布流、只差顺序。
- **服务端（都已部署）**：① Pages `functions/files/api/[[path]].js` community/list 每帖补
  hasPhoto/coverPhotoKey(完整 R2 key)/preview(前60字纯文本)——列表卡片素材一次带齐，
  客户端绝不该为每卡拉 fetchPost；② reco worker rank 响应加 likes(每帖被赞数) 给红心。
- **事故修复（2026-07-13）**：社区过百帖（106）后 reco 的 `IN (?,…)` 超 D1 100 绑定参数
  上限 → rank 整条 500 → app 静默回退（推荐==时间序、红心全 0）。修法：countsFor/likedBy
  按 90 分块合并；test/fakes.js 的 fake D1 bind 复刻 100 上限让单测能抓住此类回归。
- 设计稿里的顶栏大标题「社区」+搜索按钮没做（app 有自己的 tab 栏，搜索无行为定义）。

## 最近改动：采访员 prompt 按 OpenAI realtime 指南重构（2026-07-12，已部署）

`agent/src/realtime.js`（jianshuo.dev repo）的 INTERVIEWER_INSTRUCTIONS 从一段稠密硬约束
长句改成分节结构（角色/语气/何时不说话/怎么问/语言/听不清），依据
https://developers.openai.com/api/docs/guides/realtime-models-prompting ：

- **删「停顿超过三秒」**：模型感知不到时长，何时开口是 semantic_vad 的活，死指令只制造矛盾。
- **新增 `wait_for_user` no-op 工具**（session.tools）：治结构性冲突——create_response:true
  强迫每次 VAD 断句必须说话 vs 提示词要求沉默。静音/噪音/思考声/半句话时模型调它，回合
  安静结束；relay 和 app 都不处理这个调用（app 未知事件走 default:break，最多闭麦约 1 秒，
  有 15s watchdog 兜底）。
- 补：语言钉死始终中文（夹英文单词不切换）、听不清只澄清不脑补、反重复句式。
- **同日用户拍板问题方向：问宏观不问细节**——为什么重要/背后逻辑/更大趋势/判断立场，
  明确禁止追问数字、时间地点、具体场景（第一版写的「往细处挖」被否）。测试锁了方向。
- 测试锁行为：realtime-route.test.js 断言分节标题在、wait_for_user 在工具表里、计时/冷场
  措辞不在。全量 795 用例绿，wrangler 已部署，线上 relay 路由 426 验证过。
- **待真机实测**：wait_for_user 会不会被过度调用（该提问时也装哑）——若是，收紧工具
  description 的触发条件；「安静 vs 健谈」的老矛盾以后用这个工具调，别再改语气措辞。

## 最近修复：采访者自顾自说个不停（2026-07-10）

生产 ledger 坐实（多段采访 audio_out = audio_in 的 3~10 倍）。三个叠加根因、三处修：

- **服务端 `agent/src/realtime.js`（jianshuo.dev repo，已部署）**：① session.update 加
  `max_output_tokens: 300`——semantic_vad 自动触发的回应从不走 app 的 response.create(120)，
  此前无任何长度上限；② 提示词删「他一说完你就要接住，不让对话冷场」（这是在命令模型填满
  每个沉默），加三条铁律：说完即停 / **绝不连续发言**（等讲者说出新内容才能再开口）/
  听到回声噪音保持沉默。有测试锁行为（realtime-route.test.js：上限有界 + 铁律措辞在、
  冷场措辞不在）。
- **iOS 半双工开麦前清残留**：闭麦经常把讲者的话截成半截留在 OpenAI 输入缓冲里，开麦后
  第一帧新音频会把这半截「封口」→ semantic_vad 判定「说完了」→ 又自动回一条 → 连环。
  现在 `RealtimeInterviewer.openMic()`（resume 与 15s watchdog 两条路都走它）先发
  `input_audio_buffer.clear` 再放开上行（`RealtimeSession.clearInputBuffer()`）。
- **验证**：agent 全量 73 文件 687 用例绿；iOS xcodebuild BUILD SUCCEEDED；行为效果待
  真机采访实测——如果还犯，下一个观察点是 400ms 回声尾巴是否够长（EngineRecorder
  `.dataPlayedBack` → +400ms 开麦）以及 eagerness:"medium" 是否退回 "low"。

## 上一个大改：邀请奖励（referral，2026-07-09 上线）

带来新装的作者和新用户双边得算力。spec = `docs/superpowers/specs/2026-07-09-referral-rewards-design.md`，
plan = `docs/superpowers/plans/2026-07-09-referral-rewards.md`。**已部署 + 生产冒烟**（link 层与
IP 层端到端验证过；剪贴板层待 TestFlight 真机）。

- **归因三层**（新账号 24h 内 first-touch 一次，终身封笔）：① universal link 分享链接拉起 →
  `AppRouter` 里 `ReferralManager.shared.noteShareToken(id)`；② App 首启 hello → worker 用
  `CF-Connecting-IP` 反查 R2 `refhits/<ipHash>/<ts>`（落地页每次访问由 Pages 写入，HMAC 不存明文
  IP，lifecycle 2 天）——**24h 窗口内唯一 owner 才算**（CGNAT 多 owner 放弃，宁漏不错）；
  ③ 剪贴板兜底：落地页下载按钮点击写入本页 URL，App 端 `detectedPatterns` 先无感探测、疑似有
  URL 才真读（此时才弹系统粘贴条）。iOS 全在 `ReferralManager.swift`（RootView.task 触发）。
- **奖励 = 币记价、入账时刻实时汇率**：作者 12 币 / 新人 6 币（R2 `config/referral.json`
  `{enabled,authorCoins,newUserCoins,dailyCapPerOwner:30,requireDeviceCheck}` 零部署可调），
  入账走 mint 表 `kind='referral'`（subject_key=新账号 sub；唯一索引=每账号一生一次），
  **与投币同池同分母同保险丝**（sumCoins7d 无 kind 过滤），钱走 grantBucket
  `referral_author`/`referral_new`（账单显示「邀请奖励/受邀赠送」），90 天过期。
  owner 日封顶 30 装/天，超出只发新人侧。核心 = `agent/src/referral.js`
  （`POST /agent/referral/claim {source,token?,deviceCheckToken?}`）。
- **判新防刷**：`account.created_at` < 24h（服务端时间）+ DeviceCheck 两 bit
  （`agent/src/devicecheck.js`，复用 APNS .p8 的 ES256 JWT；**线上 requireDeviceCheck 暂 false**——
  等真机验证 APNs key 是否开了 DeviceCheck 服务，没开就建新 key 加 secrets `DC_KEY_P8`/`DC_KEY_ID`
  再改 true）+ owner==self 拒绝。
- **落地页 CTA**（`functions/voicedrop/[token].js` `ctaHtml`）：「你约得 X 算力，作者约得 Y」按
  访问时刻现价现算——现价 = R2 `config/mint-rate.json`（worker 每次投币/邀请铸币后 +6h cron 刷新，
  `publishMintRate`），读不到显示无数字通用文案。voicedrop.cn 反代自动带上（同一 Function）。
- 测试：`agent/test/referral.test.js`（21）+ `refhits.test.js`（6）+ `devicecheck.test.js`（9）+
  `referral-landing.test.js`（4）+ mint-rate 用例；全量 73 文件 685 用例绿。
- **已知遗留**：① requireDeviceCheck=false 期间重装刷币敞口（防线剩「每账号一次+判新」；验 key 后开回）；
  ② 剪贴板层真机未验；③ iOS 端归因成功 alert 文案朴素（RootView）；④ 主动「邀请好友」入口/作者
  主页 `/voicedrop/u/<token>` 二期。

## 上一个大改：Universal Links——voicedrop.cn 链接直接拉起 App（2026-07-09）

- **服务端（jianshuo.dev repo，已部署）**：AASA 文件两份——`voicedrop/.well-known/apple-app-site-association`（voicedrop.cn 经腾讯云 Caddy「补前缀」映射取到）+ 根 `.well-known/…`（jianshuo.dev 老分享链接，components 只声明 `/voicedrop/*`）；`_headers` 强制 `application/json`（Pages 对无扩展名文件默认 octet-stream）。策略 = voicedrop.cn 整站进 App，仅排除 `/files/*` 与 `/privacy/*`。已实测 voicedrop.cn / www / jianshuo.dev 三处 200 无跳转 + Apple CDN（`app-site-association.cdn-apple.com/a/v1/voicedrop.cn`）200。
- **新公开 API `GET /files/api/link/<id>`** → `{type:"article"|"community",owner,stem,title,articles:[{title,body}],photos?}`——解析 + **直接带正文**（只读阅读页就地渲染，免二次请求；暴露面与公开 HTML 页等同）；shares/ 未命中回落 community/ 指针；被举报帖 404（对齐公开页）。分享指向非 articles 键 / 文章已删一律 404。测试 `agent/test/link-resolve.test.js`。
- **分享页 Smart App Banner**（`functions/voicedrop/[token].js` metaTags）：`apple-itunes-app` app-id=6781565141、app-argument=分享 url。微信内点链接**不会**拉起 App（微信限制）；「在 Safari 中打开」后靠这条横幅一键进 App——同域页内点击不触发 universal link，横幅是唯一可靠的 web→app 跳板。
- **iOS**：⚠️ **entitlements 真源在 `project.yml` 的 `entitlements.properties`——`xcodegen generate` 每次整个重写 `.entitlements` 文件，直接改文件会被无声冲掉**（本次实施时踩到）。已加 `applinks:voicedrop.cn/www.voicedrop.cn/jianshuo.dev`。`AppRouter` 认 https URL（`universalLink(_:)` 静态解析，DeepLink 新 case `shareLink(id:fallback:)`/`web(URL)`）；`LibraryView.openShareLink` 调 link API——**全原生分流**：自己的文章开 `RecordingDetailView`；社区帖开 `CommunityPostView`（构造轻量 `CommunityPost(shareId:)`，视图自己经 community/get 拉全文/回复/投币态，投喂/喜欢/回应全可用）；别人的普通分享开新的只读阅读页 **`SharedArticleView`**（Community.swift 尾部，与帖子页同套排版：标题/章节 chips/正文段落/CommunityPhotoTile 内嵌图，`?s=<i>` 决定初始篇；无任何社区动作——非社区分享服务端没有投喂/喜欢的挂点）；解析失败/help 等才落 `SafariView` 兜底，绝不死链；「录音进行中丢弃深链」守卫天然覆盖新 case。`VoiceDropApp` 补 `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`（部分 iOS 只走 activity 不走 onOpenURL）。
- **签名**：App ID 已开 Associated Domains capability（`fastlane produce enable_services --associated-domains`，本地 ASC env 直接可用）；`fastlane refresh_profiles` 已重发 profile 到 certs repo（beta lane 的 `readonly:false` 仍留着，CI 下次构建自取）。
- **已知遗留**：① `~/code/jianshuo.dev/infra/voicedrop-cn/Caddyfile` 在 repo 里是 **0 字节空文件**（README 的「10 分钟重建」不成立）——线上真配置在 `/etc/caddy/Caddyfile`，需要 ssh `ubuntu@49.235.147.96` 的人回填（本次会话权限拦了远程读取）；② 微信内直接拉起 App 未做（需微信开放平台 `wx-open-launch-app` 开放标签 + 服务号 JS 签名，另立项）；③ `?s=<index>` 段选择：别人分享的只读阅读页已按它选初始篇；**自己文章**的原生详情页仍打开整组未跳篇。
- 计划全文：`docs/superpowers/plans/2026-07-09-universal-links.md`。

## 上一个大改：录音后端统一 AVAudioEngine + AI 采访变录音内开关（2026-07-08）

录音与 AI 采访解耦：**所有录音默认走 `EngineRecorder`（AVAudioEngine）**，AI 采访员是录音过程中随时可开关的旁路——录音界面停止键左侧新增「采访」键（与右侧拍照对称），点一下连 relay、再点结束，每段独立计费（worker 在 WS close 结算）。列表里原来的隐藏采访入口已删除。

- **神圣不变量**：tap 里永远先写 m4a 再 tee PCM；采访/半双工/AI 播放只碰 tee 支流，动不到文件。
- **文件格式整段定格**（2026-07-08 评审修复）：`Sink` 在 start() 就按 `pref.highQuality`（标准 16kHz/32kbps · 高 24kHz/64kbps，同 `Prefs.recorderSettings` 契约）建 AAC 文件，**每个 tap buffer 经持久 `AVAudioConverter` 转进固定格式**——中途换路由（AirPods/蓝牙、采样率变化）只换 converter 输入侧，文件不断不裂。AI tee 也走持久 converter（相位跨 buffer 连续）。
- **路由切换恢复**：`AVAudioEngineConfigurationChange` → 拆 tap → 停引擎 → 按新原生格式重装 tap → 重启（老代码带旧格式 tap 重启会 NSException 崩溃）；播放引擎同时 tearDown，下一段 AI 音频懒重启。
- **半双工排水计数带 generation token**：`player.stop()` 会异步触发所有排队 buffer 的完成回调，旧 generation 的递减一律丢弃，防止快速关/开采访时新段计数被污染 → 提前开麦自听循环。
- **错误可见 + 不 promote 幽灵**：`engineError` 在普通录音界面也显示（不再只在采访 overlay）；stop() 校验文件存在，不存在返回 nil → UI 显示「录音失败」，绝不无声吞录音。
- **RealtimeSession 每段 generation + 计数复位**：采访反复开关时旧 WS 回调不再把新会话标 degraded，debugLine 只反映当前段。
- **中断（来电）先关 relay 再交 take**（onInterrupted 包装），计费不悬空。
- **深链不打断录音**：录音进行中收到 voicedrop:// 深链直接丢弃（以前会 dismiss cover 丢整段录音）。
- **tee 门控**：`teeEnabled` 关闭时 Sink 不做重采样/不 hop 主线程——普通录音零采访开销；level/tapBuffers 走 100ms tick 读原子快照，不再每 buffer 两次主线程 Task。
- **逃生门**：设置 → 数据与备份 → 「经典录音引擎」（`Prefs.classicRecorder`）切回 AVAudioRecorder（无采访键）。**新引擎稳定一两个版本后删掉此开关和分支。** `classic` 在 RecordSession 里用 @State 定格整段会话。
- **半双工背景**：设备上 VPIO/AEC 不可用（tap 0 buffers，已穷尽排查），AI 说话时静音上行、response.done+播放排空+400ms 尾巴后恢复。AI 声音会进录音（用户已接受）。
- **已知遗留**：RecordSession 里 classic/engine 仍是 if/else 分支（RecordingBackend 协议未完全启用——刻意不在稳定期重构）；真机需验证：录音中插拔 AirPods 前后段都在、采访中拔耳机不崩、AI 说话中关/开采访无卡麦。
- **服务端**：relay 在 voicedrop-agent worker `/agent/realtime/relay`（WS 中转 OpenAI gpt-realtime-2.1，key 不落设备，`response.done.usage` 计费）；采访员提示词在 `agent/src/realtime.js`（名字叫 VoiceDrop，默认沉默、卡住才插话）。

## 更早的大改：追问（follow-up questions，2026-07-07 上线）

成文后 AI 按篇追问 1–3 个「只有作者知道」的细节，作者按住说话回答，回答被织进正文。

- **数据形态**：问题是 `articles/<stem>.json` **doc 顶层 sidecar** `questions:[{id,articleIndex,text,status,createdAt}]`——不进 body、不进 versions，发公众号/分享页/社区/小红书全出口天然不带（曾经的「正文尾——追问——节」方案已废弃，那会全渠道泄漏）。
- **服务端**（jianshuo.dev repo）：MINE_SYSTEM 让模型在 JSON 里按篇给 `questions` 数组；`miner.js extractFollowups` 收进 doc 顶层（`parseArticles` 还会剥掉误写进正文的尾节兜底）；`PATCH /files/api/articles/<stem>/question` 改状态（元数据写，不铸版本，`article-store.setQuestionStatus`）；CONFIG.json `noFollowups:true` 关掉；重挖整组换新。**坑：Anthropic output_config schema 不支持数组 `maxItems`（线上 400）——上限只能靠 prompt+parse 截断。**
- **iOS**：`FollowupQuestions.swift`（FollowupState 状态机 + FollowupWrap 包裹卡 + 星标）。**交互（2026-07-07 按用户口述修正）**：缺省收起——只在原「按住 说话 修改」条右侧亮 52×52 星标（角标=未答数）；点星标 → 追问信息（题号/跳过/问题/进度条）**把原 push-to-talk 包起来**（`PushToTalkBar.wrapPill` 插槽），按住的还是原来那个条（文案换「按住 说话 回答」）；**松手立刻按普通指令入队**（`mapInstruction` 包成【回答追问】前缀，agent SYSTEM 认它做定点织入），当场标 answered+翻题，之后就是普通发信息 UI（队列气泡），没有专门等待态；织入落地后 diff 新旧正文对被补段落做几秒荧光高亮（锦上添花，不阻塞）。7 天未答客户端过滤；设置 →「成文后追问」开关。设计稿 `design_handoff_follow_up_questions/` 里 3a 的独立回答按钮和 3c 确认行已被这版交互取代。
- **续问（2026-07-07）**：对语音 agent 说「再追问我几个」→ `add_followups` 工具（agent/src/tools.js）在本回合上下文里自己出 1–3 题，`article-store.appendQuestions` 追加落库（去重、不铸版本）；App 在 onUpdate 里 `followup.merge(newDoc)` 接上新题重新亮星标（本地已推进的 answered/skipped 状态不被服务端回读回退）。注意：追问展开态下按住说话一律当回答（包【回答追问】前缀），想续问先收起卡片再说。
- **编辑落地高亮（2026-07-07）**：所有语音修改落地后 `BodyDiff.changedRows` 按内容 diff 新旧正文，变动行黄底 3.5s 淡出（`highlightLines`，按篇存）；追问织入共用此路。


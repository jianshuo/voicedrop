# 提示词社区帖 — SDD progress ledger

Plan: docs/superpowers/plans/2026-07-15-prompt-community-posts.md
Spec: docs/superpowers/specs/2026-07-15-prompt-community-posts-design.md
Bases: jianshuo.dev=45332b4 (main) ; voicedrop=557dfd7 (main)
Repo per task: T1-T7 = jianshuo.dev ; T8-T11 = voicedrop
Workflow: 直接在各自 main 提交（用户既定约定）。T7 部署、T11 收尾由 controller 亲自执行。

## Tasks
- [x] T1 D1 migration + reco feed kind        (jianshuo.dev/reco)
- [x] T2 Pages indexUpsert/list kind          (jianshuo.dev/functions)
- [x] T3 prompt-community 帮手 + RECO_DB      (jianshuo.dev/agent)
- [x] T4 prompt-share 路由接线                (jianshuo.dev/agent)
- [x] T5 get/unshare/reconcile                (jianshuo.dev/functions)
- [x] T6 MCP 描述                             (jianshuo.dev/mcp)
- [x] T7 部署 + 冒烟                          (controller)
- [x] T8 iOS 模型+tab+角标                    (voicedrop)
- [x] T9 iOS 详情页导入 CTA                   (voicedrop)
- [x] T10 iOS 分享开关登录重试                (voicedrop)
- [x] T11 收尾 STATE.md + push                (controller)

- T1: complete (commit 1444de7, SPEC✅/Approved; reco 31/31 绿). Minors→final triage: (M1) 新测试遮蔽了模块级 env 助手（可读性 nit）；(M2) `r.kind || "article"` 兜底分支无专测（DB DEFAULT 兜底，可接受）。
- T2: complete (commit e8e9a1e, SPEC✅/Approved; agent 1043/1043 绿). Minor→final triage: 显式 {kind:'prompt'} 参的优先级分支本 task 无直接测试（T5 的 prompt 用例会覆盖）。
- T3: complete (commit eb2ae7c, SPEC✅/Approved; agent 1048/1048 绿). Reviewer ⚠️ 已由 controller 裁决：真撤帖后再开 firstSharedAt 重置=计划明文接受（「同帖」指 shareId 身份不变）；保留逻辑服务幂等重开。Minors→final triage: (M1) indexUpsertPrompt 的 ON CONFLICT UPDATE 列集比 Pages 侧窄（对 prompt 帖全是常量，惰性不一致）；(M2) prompt 帖无 replyTo（brief 即如此，spec §2.1 可选字段）。
- T4: complete (commit c326ccd, SPEC✅/Approved; agent 1052/1052 绿). 老测试 9 块全部「换真 session token」类改写，reviewer 逐块核实无削弱；GET 公开预览确认在门槛之前 return。Minor: 实现者报告把 2 个实际改过的用例说成未改（文档瑕疵，非代码问题）。
- T5: complete (commit bc7bd67, SPEC✅/Approved; agent 1057/1057 绿). Reviewer 的 Important-⚠️（get 自愈丢 hidden）controller 已核实为非 bug：indexUpsert 省略 hidden 时从 R2 举报标记派生（[[path]].js:1002），与文章帖自愈同语义。旧测试改写合理（不真实帖形状→生产真形状，断言不变）。Minors→final triage: (M1) livePromptLeaf 与 reconcile 对 shares 副本的合法性校验不一致（后者不查 instruction 类型）；(M2) 无 label 时 get 兜底「分享提示词」vs reconcile 兜底空串。
- T6: complete (commit 9804610, SPEC✅/Approved; mcp 130/130 绿). 纯文案逐字核实。
- T7: complete. push main（45332b4..9804610，agent 1057 绿）；D1 0003 applied --remote ✅；部署 reco d785d93e / agent 36190a31 / Pages 590c164a。线上冒烟：feed 115 帖全带 kind=article ✅、community/list 快路径 kind ✅、匿名 token POST prompt-share → 403 needs_apple_signin（MCP 错误翻译也对）✅、新 MCP 工具 list_prompts 线上可用 ✅。快乐路径（share→帖→get 合成→unshare 同死）需 App 内 Apple session token，MCP 配对令牌是 anon 型——**并入 T11 真机手测清单**，非阻塞。
- T8: complete (commit 11195ef, SPEC✅/Approved; VoiceDropTests 104/104 + BUILD SUCCEEDED). 顺手修真 bug：tab 埋点 ternary 会把新 tab 误标「回应」→ 换 exhaustive switch（隐私红线守住，纯元数据）。注意：本机模拟器是 iPhone 17（无 iPhone 16）。Minors: .prompts 过滤/tabAnalyticsName 无 UI 级测试；appliesTo 无解码测试。
- T9: complete (commit 197e8c6, SPEC✅/Approved; 104/104 + BUILD SUCCEEDED). 三重 gate/防重入/纯元数据埋点均核实。Minor→final triage: 社区导入成功会同时发两个埋点事件（「社区提示词导入」+ PromptStore 内部的「提示词导入码兑换」）——语义重叠非重复，审计漏斗时注意。
- T10: complete (impl 5a957eb + fix ee524db, SPEC✅/Approved after fix; 104/104 + BUILD SUCCEEDED). Important 已修：重试再遇 needs_apple_signin 不再伪装成功，返回「分享到社区需要先登录」。Minor→final triage: 新增 4 个中文 key 暂无英文翻译（夜间英文同步管道会收敛，见 memory voicedrop-english-version）。

## Final whole-branch review (fable) — SHIP AFTER FIXES → 修复后 READY TO SHIP
- 🟠 F1 举报 resolve-remove 杀帖不杀码（违规内容仍公开可达+可复活）→ 修
- 🟠 F2 销号不删提示词码（存量缺口，本分支放大暴露面；Apple 5.1.1(v) 风险）→ 修
- 🟡 F3 举报列表 prompt 帖空标题（管理员无法判断举报）→ 修
- 🟡 F4 livePromptLeaf 把 R2 瞬时错误当码死误删帖 → 修（异常上抛，仅真 404/坏 JSON 自愈）
- 四修一个 commit aca6df2（每条一测，agent 1061/1061 绿），复审 ALL FIXED，READY TO SHIP。
- 其余 Minor 全部 RECORD ONLY（见各 task 行）。
- 服务端最终部署：Pages 3a45768e（含 aca6df2）；agent 36190a31、reco d785d93e 不变。
- 待办：TestFlight（用户拍板发版）→ 真机手测清单（STATE.md 有）→ 快乐路径 E2E。

# 锚点协议 — SDD ledger（2026-07-16 立项）
Plan: docs/superpowers/plans/2026-07-16-anchor-protocol.md
Spec: docs/superpowers/specs/2026-07-16-anchor-protocol-design.md
Bases: jianshuo.dev=910bbb9 ; voicedrop=d667a0a（各自 main 直接提交）
- [x] A1 服务端 anchor 全链路（edit-turn/index/queue/prompt-share）
- [x] A2 服务端部署+冒烟（controller）
- [x] A3 iOS EditAnchor+编码+持久化
- [x] A4 iOS 菜单调用点+引导文案 [tf]
- [x] A5 收尾 STATE.md+手测清单（controller）
- A1: complete (impl 307b481 + fix 249a442, SPEC✅/Approved after fix; agent 1106/1106). Critical 已修：legacy [[photo:N]] 数字标记两代归一（与 iOS resolvePhotoKey 同口径），reviewer 端到端复核。行号基准 1-based 与 edit 工具一致；⑥ 逐字节回归锁成立。Minors: /^\d+$/ 不认带符号串（无实际影响）。
- A2: complete. push 249a442、worker 5078b16d 部署；GET /agent/prompts 200 健康；anchor 可选=老 App 零影响（⑥ 逐字节锁）。
- A3: complete (commit 50b4a96, SPEC✅/Approved; 122/122 + BUILD SUCCEEDED，reviewer 自复跑). enqueue 拆双 overload（协议 witness 约束，调用点全核实无歧义）；老磁盘队列缺键解码有字面 JSON 测试。Minor: wireDict 与 Codable 键名双源（有测试锁，记录）。
- A4: complete (commit 9bed7da, SPEC✅/Approved; 122/122 + BUILD SUCCEEDED). 4 行最小 diff；引导文案经核实本无占位符教学（TextEditor 无 placeholder），零改动成立；app 内剩余占位符只在 sys_* 内置模板=Phase B。
- Final review (fable): SHIP AFTER FIXES → Important（T4 引导文案漏做且 commit message 失实）controller 亲修（PromptEditView 空态 placeholder）；五条跨仓缝全咬合（wire 契约/行号三方/key 空间/持久化升级/relay 不经缝）。Minors 全 RECORD（含先于本分支的 photo 行计数偏差——自愈可治）。
- A5: complete. STATE.md 沉淀 + iOS push（T4 [tf] 随车发 TestFlight）。

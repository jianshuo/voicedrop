# VoiceDrop 语音指令 — SDD progress ledger

Plan: docs/superpowers/plans/2026-07-02-voicedrop-voice-command.md
Spec: docs/superpowers/specs/2026-07-02-voicedrop-voice-command-design.md
Bases: jianshuo.dev=60ec6f7 (main) ; voicedrop=292a5b2 (main)
Repo per task: T1-T9 = jianshuo.dev/agent ; T10-T14 = voicedrop/VoiceDropApp
Workflow: 直接在各自 main 上提交（本会话既定工作流 + harness work-in-place）。部署/push 见任务步骤。

## Tasks
- [x] T1 runAgentLoop 可选 tools/terminalTools + pending   (jianshuo.dev)
- [x] T2 库级工具 merge/restyle/tag_article              (jianshuo.dev)
- [x] T3 delete_article 暂存 + deleteArticleFiles         (jianshuo.dev)
- [x] T4 COMMAND_TOOL_NAMES/toolDefsFor                   (jianshuo.dev)
- [x] T5 runCommandTurn + 编号→stem                       (jianshuo.dev)
- [x] T6 meteredCommandGate                               (jianshuo.dev)
- [x] T7 LibraryAgent DO + confirm/cancel + wrangler v5   (jianshuo.dev)
- [x] T8 /agent/command 路由                              (jianshuo.dev)
- [x] T9 部署+连通冒烟(功能冒烟→T14 真机)                                       (jianshuo.dev)
- [x] T10 VoiceAgentSession 协议                          (voicedrop)
- [x] T11 抽 PushToTalkBar                                (voicedrop)
- [x] T12 LibraryCommandSession + CommandQueueStore       (voicedrop)
- [x] T13 LibraryView 接线                                (voicedrop)
- [x] T14 TestFlight 真机验证                             (voicedrop)

- T2: complete (impl 851f1a5 + fix 6c82b99, re-verified diff = exact 2 prescribed fixes; 406/406). SPEC✅.
  Minors -> FINAL triage:
    (M1) merge_articles writeStandaloneArticle 非原子：article JSON PUT 成功但 m4a put 失败→孤儿文章(列表不显示)。低概率(同请求 R2)。
    (M2) restyle_article 丢弃 restyleArticle 成功返回的 head（不影响功能）。
    (M3) command-tools.test.js 仅 happy-path，未覆盖 merge 的 guard 分支（符合 brief 的单测规格）。

- T3: complete (commit ca891a2, SPEC✅/Approved; 408/408). Minor(final): deleteArticleFiles 不 badStem 校验(调用方已校验,低危)。

- T4: complete (commit 906aacf, controller-verified diff = exact spec exports; 409/409).

- T5: complete (impl fc8c3cf + fix a0d4abd, SPEC✅; 411/411). DEVIATION: 命令集去掉 publish_wechat/share_to_community(单篇绑定 ctx.articleKey,库级无 stem→会抛;spec 原说复用,v1 砍,详情页仍可发/分享). 待用户知会。

- T6: complete (commit 9f99559, controller-verified exact spec fn; 412/412).

- T7: complete (impl a063625 + fix fdb5b9c, SPEC✅; 413/413 + queue _pending test; wrangler dry-run OK). Fixed Important: 暂存删除在队列里视为未完成(不误报已完成/不孤立 pending)+确认卡列全部待删标题。

- T8: complete (commit 5965f8e, controller-verified route mirrors /agent/edit; 413/413 + dry-run OK).

- T9: deployed voicedrop-agent v4dfe42fd (含 LibraryAgent DO + v5 migration)。连通冒烟：/agent/command 命中处理器返 426「expected websocket」(路由已上线)。功能级 WS 冒烟(真 token+merge/delete)推迟到 T14 真机端到端(需真 WS 握手+token)。Phase 1 服务端完成。

- T10: complete (commit eb61705, controller-verified protocol+conform+unwrap; BUILD SUCCEEDED).

- T11: complete (commit 43b13e4, SPEC✅/Approved, 无行为漂移, reviewer 复跑 BUILD SUCCEEDED). agentReply 作参数留父视图(我授权,合理)。

- T12: complete (commit ba4ca33, controller-verified WS 契约匹配已部署服务端: 出 instruct/confirm/cancel, 入 status/reply/error/updated/snapshot/confirm, URL /command, refs[{n,stem,title}], onConfirm; BUILD SUCCEEDED).

- T13: complete (commit af544ed, wiring 全到位: confirm alert/onConfirm/序号badge/currentRefs/onWillSend→setRefs/完成退出; BUILD SUCCEEDED). CAVEAT(设备调优#1): 长按红键进命令态→再按住 bar 说话(两次触摸),非单次连续对讲机(跨视图手势无法共享一次触摸)。真机体验后决定是否把红键本身做成 sequenced 长按→拖动的一次性握持。

- T14: CI 首次失败(Release arm64 CompileSwift 超时 LibraryView:54，4 链 alert 类型推断爆预算)→修复 1ffd92a(拆 body+rowAlerts 两 some View + clearBinding 显式 Binding)→CI 重跑 SUCCESS(6m11s),TestFlight 构建上线。final review 修复 9ccc190(C1/I1/M4)已 push+Worker 重部署 d3f743ac。全部 14 任务完成,待真机端到端验证。

## Completed
- T1: complete (commit 63cf925, review clean SPEC✅/Approved; 405/405 full suite)

## Final whole-branch review (server, opus) — findings
- 🔴 C1 (ship-blocker): merge_articles 的 ctx.callClaude 无 tools，但 _makeLoggedCall 无条件带 tool_choice → Anthropic 400 → 合并全挂。修复中：两处 _makeLoggedCall tool_choice 改成有 tools 才带。
- 🟠 I1: LibraryAgent 队列 loadDoc=null 关掉了 lastEditId exactly-once → 中途驱逐会重跑(重复合并/重复计费 restyle)。修复中：merge stem 用稳定 row.id 确定性生成+存在即跳过；per-turn done marker(command-turns/<id>.json)。
- 🟡 M2(合并 stem 秒级碰撞→并入 I1a)、M4(deleteArticleFiles 加 badStem)。M3(未确认删除 hibernation 后重弹)=设计如此，保留。
- SOUND: confirm/cancel exactly-once+恢复、refs→stem 越权、工具集隔离、计费门。
- 残留已知 minor: restyle 重挖中途被驱逐仍可能重复计费(在地改写,很窄),记录不修。

## Post-真机 round 1 fixes (2026-07-02)
- 🔴 真机 400「tools.4.custom.destructive: Extra inputs not permitted」：tool 定义里的 destructive 字段被原样发给 Anthropic，schema 不允许→每次命令首个 agent 调用就挂。移除 4 处 destructive（本就没被读），加 schema 守卫测试。414 绿。Worker 重部署 13a2aa58。commit 644e9fd。
- UX：红键本身长按即说话（对讲机，LongPress(0.3).sequenced(before:DragGesture)，轻点仍录音），去掉两步 PushToTalkBar 命令栏；反馈复用抽出的 VoiceFeedbackStack（语音编辑 bar 不回归）；数字在按住时浮现。commit a69fb0f + gap fix 979cc87。iOS CI SUCCESS，TestFlight 上线。
- 🔴 crash (真机, 任意命令后): 服务端库级命令回 {updated, article:null}, JSON null→NSNull, decodeDoc 的 try? JSONSerialization.data(withJSONObject:NSNull) 抛 ObjC NSInvalidArgumentException(try? 抓不住)→abort()。崩溃栈确认 +[NSJSONSerialization dataWithJSONObject:]→objc_exception_throw→abort。修复 b054ff9: decodeDoc 先 isValidJSONObject 守卫(两处:LibraryCommandSession+AgentSession)。iOS CI SUCCESS, TestFlight 上线。

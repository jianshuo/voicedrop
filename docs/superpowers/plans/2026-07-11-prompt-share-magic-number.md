# 指令分享码（魔法数字）— 实施计划

spec：`docs/superpowers/specs/2026-07-11-prompt-share-magic-number-design.md`

## Architecture

- **一个注册表**：`shares/<7位数>` 值 = `{"type":"prompt","sub","itemId","createdAt"}`
  活指针，与文章分享（纯文本 key）同表；解析先 JSON.parse 判 type。
- **生效文本现算**：`resolvePromptShare(env, code)` → `loadUIConfig` + `flattenPrompts`
  + `loadUserOverrides(env, "users/<sub>/")` → `{label, instruction}`（override ?? default）。
  分享/落地/兑换三处同一函数。
- **兑换**：edit-turn / command-turn 指令行之后正则识码（断句归一 + 7 位边界），
  命中 push 注入块（模板在代码里，见 spec §4）。
- **iOS** 只做分享侧开关卡（`InstructionSettingsView.swift`）。

## Tasks

### Task 1: 服务端基线 + 分支
- [ ] `cd /workspace/jianshuo.dev/agent && npm test` 全绿（基线 73 文件 687 用例）
- [ ] `git checkout -b claude/ai-instruction-storage-8jf5u2`

### Task 2: TDD — `agent/test/prompt-share.test.js` 先失败
- [ ] 用例矩阵见 spec「测试清单」；fakeEnv seed `shares/…`、`users/<sub>/ui-config.json`、
  `config/prompt-share.json`;路由测试 `worker.fetch(new Request(...), env, {})`
  照 `referral.test.js` 写法
- [ ] `npx vitest run test/prompt-share.test.js` → FAIL（模块不存在）

### Task 3: 实现 `agent/src/prompt-share.js` + 接线
- [ ] `loadPromptShareConfig(env)`：`{enabled:true,dailyCapPerUser:20,maxLength:4000,notFoundNote:true}` ← R2 覆盖
- [ ] `mintCode(env)`：`crypto.getRandomValues`，`String(1_000_000 + n % 9_000_000)`，
  撞 `shares/<code>` 重摇 ≤5
- [ ] `handlePromptShareRoutes(url, request, env)`：POST/DELETE（鉴权照 referral：
  verifySession → anonScopeFromToken）；非命中返 null
- [ ] `resolvePromptShare` / `resolveSharedPromptBlock`（注入模板 + 软备注 + `{{` 才带占位符条）
- [ ] `index.js`：`{ const r = await handlePromptShareRoutes(url, request, env); if (r) return r; }`
- [ ] `ui-config-custom.js` GET 补 `shareCode`/`sharing`
- [ ] `npx vitest run test/prompt-share.test.js` → PASS

### Task 4: 兑换注入 + 既有测试补例
- [ ] `edit-turn.js`（指令 push 后）+ `command-turn.js` 同款：
  `const shared = await resolveSharedPromptBlock(env, instruction); if (shared) varLines.push("", shared);`
- [ ] `edit-turn.test.js` / `command-turn.test.js` 各加 2 例（含/不含注入块）

### Task 5: 落地页 prompt 分支
- [ ] `functions/voicedrop/[token].js`：map 值 JSON.parse 判 type → `promptPage()`
  （复用 page/metaTags/ctaHtml/writeRefhit；文案见 spec §6）；已关闭 → 「这条分享已停止」404
- [ ] 测试照 `referral-landing.test.js` 所在位置补 prompt 分支用例

### Task 6: 服务端收尾
- [ ] 全量 `npm test` 绿
- [ ] Commit `feat(agent): 指令分享码——7 位数活绑定分享/开关撤销/语音报号一次性兑换 + 落地页`
- [ ] `git push -u origin claude/ai-instruction-storage-8jf5u2`（网络失败 2/4/8/16s 退避 ≤4 次）

### Task 7: iOS 分享卡（voicedrop 仓库）
- [ ] `InstructionItem` 增 `shareCode`/`sharing`（Decodable 容错）
- [ ] `InstructionCustomStore.setSharing(id:on:)`（POST/DELETE，429 区分）
- [ ] 编辑页分享卡（Toggle + 展开态：码/链接/复制×2/分享…）+ `ShareCodeSheet`
- [ ] Commit `feat(ios): AI 指令编辑页分享开关——7 位码 + 链接 + 复制/分享` + push
- [ ] Linux 无法 xcodebuild —— 手测清单见 spec 与 STATE.md

### Task 8: STATE.md
- [ ] 机制一段：端点、R2 key（`shares/<码>` typed / `users/<sub>/prompt-shares.json` /
  `config/prompt-share.json`）、注入点、落地页分支、测试文件、待真机验证清单

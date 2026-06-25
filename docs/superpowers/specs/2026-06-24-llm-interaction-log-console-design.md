# LLM 交互日志控制台 — 设计

Date: 2026-06-24
Status: approved (设计已确认，进入实现)

## 目标

把 VoiceDrop 所有与大语言模型（Claude / Anthropic Messages API）的交互**逐次原样记录**下来，
并在一个 admin 页面里看到每一次交互**发出去什么、收回来什么**的完整细节。

## 现状（两处 LLM 调用，都直接 POST `api.anthropic.com/v1/messages`）

| 来源 | 代码 | 运行环境 | 形态 |
|---|---|---|---|
| `mine`（挖矿成文） | `voicedrop/mining/mine.py` → `generate_articles()` | GitHub Actions 批处理 | 一次调用（含 1 次 retry） |
| `agent`（交互修改） | `jianshuo.dev/agent/src/index.js` → `_callClaude()` | Cloudflare Worker / Durable Object | 多轮 agent loop（每条语音指令最多 8 步、带 tool use） |

共享存储：R2 bucket `jianshuo-dev-files`（binding `FILES`）。
- Worker 直接 `env.FILES`。
- mine.py 经 files API（`https://jianshuo.dev/files/api`）+ `FILES_TOKEN`，已有 `api_put(key, body, ct)` 助手（PUT `…/upload/<key>`）。

已有 admin 控制台：`jianshuo.dev/voicedrop/admin/index.html`（「VoiceDrop 控制台」，浅色，`FILES_TOKEN` 进门）。

## 决策（已与用户确认）

1. 查看页：**单独新页** `voicedrop/admin/llm.html`，从现有控制台加入口链接。
2. 保留：**30 天自动过期**（R2 lifecycle，prefix `llmlogs/`）。
3. 范围：**两处一起做**（mine + agent）。

## 存储格式

每一次 Anthropic HTTP 调用写一条 JSON 到 R2，前缀 `llmlogs/`（在 `users/` 之外 → 仅 admin 可见）：

```
key: llmlogs/<YYYY-MM-DD>/<epoch_ms>-<rand6>.json
```

记录字段：

```jsonc
{
  "id": "<epoch_ms>-<rand6>",
  "ts": 1750000000000,            // epoch ms
  "source": "mine" | "agent",
  "user_scope": "users/<sub>/",   // 哪个用户触发
  "model": "claude-sonnet-4-6",
  "latency_ms": 4210,
  "http_status": 200,
  "ok": true,
  "turn_id": "<id>",              // 同一条指令的多步/重试归为一组
  "step": 0,                       // turn 内的第几步（agent loop 步号；mine 的 retry 序号）
  "request": { /* 完整发出的 body：model, system, messages, tools?, max_tokens, output_config?, tool_choice? */ },
  "response": { /* 收到的 body：id, content, stop_reason, usage */ },
  "error": "<string>",            // 仅失败时；此时 response 省略
  "meta": { "stem": "<article stem>", "instruction": "<语音指令，仅 agent>" }
}
```

写入是**尽力而为、失败不影响主流程**：日志写入包在 try/catch，任何异常只吞掉、不打断挖矿或编辑。

## 组件

### 1. 写入 · agent（`jianshuo.dev/agent/src/index.js`）
- `onMessage` 里为本次指令生成 `turn_id`，并维护 `step` 计数。
- 用一个**日志包装闭包**替换传给 `runAgentLoop` 的 `callClaude`：调用真实 `_callClaude` 前后计时、抓 request/response/error，写一条 `llmlogs/…` 记录（`await env.FILES.put`，try/catch 包裹）。
- `source:"agent"`，`user_scope`=本会话 scope，`meta.stem`/`meta.instruction` 带上。

### 2. 写入 · mine（`voicedrop/mining/mine.py`）
- `generate_articles()` 内每次 anthropic 调用（含 retry）前后计时、抓 request/response/error，经 `api_put("llmlogs/…json", body, "application/json")` 写一条记录。
- `source:"mine"`，`user_scope`/`meta.stem` 由调用处（main 循环已知 audio→prefix/stem）传入。

### 3. 读取接口（`jianshuo.dev/functions/files/api/[[path]].js`）
- 新增 **admin-only** 动作 `GET /files/api/llmlog/list?date=<YYYY-MM-DD>&cursor=<c>`：
  - 仅 `scope===''`（admin）放行，否则 403。
  - `env.FILES.list({ prefix: 'llmlogs/' + (date?date+'/':''), cursor, limit })`，返回 `{ objects:[{key,size,uploaded}], cursor, truncated }`，**页内倒序**（R2 按 key 升序，客户端 reverse → 最新在前）。
- 读单条：admin 复用现有 `GET /files/api/download/<key>`（admin scope='' → 原始 key 直读），无需新接口。

### 4. 查看页（`jianshuo.dev/voicedrop/admin/llm.html`）
- 复用现有控制台的浅色样式与 `FILES_TOKEN` 进门 gate。
- 左：倒序列表（时间 / 来源 badge / 模型 / tokens 用量 / 状态 ok·err）。顶部按日期切换 + 「加载更多」游标翻页。
- 右：选中一条看完整 `request`（system / messages / tools，可折叠）与 `response`（content / stop_reason / usage）或 `error`。
- 同一 `turn_id` 的多条折叠成一组（agent 多步指令）。
- 入口：从 `voicedrop/admin/index.html` 加一个「LLM 日志」链接。

### 5. 保留策略
- R2 lifecycle：`llmlogs/` 前缀 30 天过期。
  `npx wrangler r2 bucket lifecycle add jianshuo-dev-files --prefix llmlogs/ --expire-days 30`
  （命令以 wrangler 实际子命令为准；若 CLI 不支持则在 Cloudflare 控制台加规则，并在此记录。）

## 部署
- Worker：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`
- Pages（files API + admin 页）：`cd ~/code/jianshuo.dev && npx wrangler pages deploy . --project-name jianshuo-dev`
- mine.py：提交后随下次 GitHub Actions `mine` 生效。

## 非目标（YAGNI）
- 不做实时推流 / 不做跨用户分析报表 / 不做检索全文索引。先做「逐条记录 + 翻看」。
- 不记录 Volcano ASR（这是「与大语言模型」的日志；ASR 不在范围）。

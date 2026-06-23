# Voice-driven article actions

Date: 2026-06-23
Status: approved design, ready for implementation plan

## Problem

When the user edits a mined article by voice, every spoken instruction is currently
interpreted as "rewrite the prose." We want spoken instructions to be able to do *anything*
the user could do by hand — not just rewrite, but combine articles, publish to WeChat, share
to the community — without enumerating a task-specific tool for each.

Examples the user should be able to just *say*:
- "把开头改紧凑点" — rewrite
- "把最近两篇合并到这篇里" — read others, weave into current
- "发公众号" — publish a WeChat 公众号草稿
- "分享到社区" — share to the VoiceDrop community

## Approach: general primitives + an agentic loop

Instead of task-level composite tools (`merge_recent_articles`, etc.), the agent gets a small
set of **general primitive tools** and *composes* them itself in a multi-step tool-use loop.
"合并最近两篇" is not a tool — it emerges as `list_articles → read_article → read_article →
write_article`. New behaviors need no new tools.

## Current flow (baseline)

```
mic → SpeechDictation (zh-CN ASR) → transcript
    → ArticleAgentSession.enqueue(text)  [serial queue, one in flight]
    → wss://jianshuo.dev/agent/edit?stem=<stem>   {type:"instruct", text}
    → ArticleEditor (Durable Object): load article + style, ONE Claude call (rewrite
      whole doc via json_schema), write back, push {type:"updated", article}
    → app reloads the doc in place
```

Relevant files:
- `VoiceDropApp/VoiceEdit.swift` — `SpeechDictation` (ASR; unchanged).
- `VoiceDropApp/AgentSession.swift` — `ArticleAgentSession` (WebSocket client; handles `status` / `updated` / `error`).
- `~/code/jianshuo.dev/agent/src/index.js` — `ArticleEditor` Durable Object.
- Existing distribution endpoints (Pages Functions, bearer-auth):
  - `POST /files/api/wechat/<articleKey>` — publish/update a WeChat draft (sync, via VPS relay).
  - `POST /files/api/community/share/<articleKey>` — share to community, returns `{shareId}`.

## Design

### 1. Tool set — all atomic primitives

| Tool | Input | Executor | Effect |
|---|---|---|---|
| `list_articles` | — | Worker (R2) | list the user's articles `[{stem, title, createdAt}]`; skip `.empty` markers |
| `read_article` | `{stem}` | Worker (R2) | return `{transcript, articles:[{title,body}]}` for any of the user's stems |
| `write_article` | `{articles:[{title,body}]}` | Worker (R2) | **write the CURRENT article only** (the DO's own stem); no `stem` arg |
| `publish_wechat` | — | Worker → existing URL | `fetch POST /files/api/wechat/<currentKey>`; return `{errcode/created/updated}` |
| `share_to_community` | — | Worker → existing URL | `fetch POST /files/api/community/share/<currentKey>`; return `{shareId, url}` |

Notes:
- `read_article` is read-any (needed to pull source articles for a merge); `write_article` is
  **write-current-only** — it takes no `stem` and always targets the DO's article. Cross-stem
  writes are impossible by construction, so the blast radius of a mistake is the current
  article (which the user is editing anyway).
- `publish_wechat` / `share_to_community` are atomic capabilities, not composites — a publish
  cannot be decomposed into read/write. They wrap the existing client-button URLs directly,
  server-side. They fire immediately (no app-side confirm — "说了直接发").

### 2. Agentic loop in the Durable Object

`ArticleEditor.onMessage` changes from a single Claude call to a **tool-use loop**:

```
messages = [user: instruction + current article context]
loop:
  resp = Claude(messages, tools=[the 5 tools above])
  if resp has tool_use:
    for each tool_use: execute via the Worker, append tool_result to messages
    continue
  else:
    break   // Claude produced a final (non-tool) response → done
```

- Each tool executes server-side in the Worker; results are fed back as `tool_result` so Claude
  can chain steps (read two articles, then write the merge).
- `write_article` / `read_article` use the DO's R2 binding scoped to `users/<sub>/`.
- `publish_wechat` / `share_to_community` call the existing Pages endpoints with the user's
  bearer token (see §3).
- The history table still records the original instruction per turn.

### 3. Auth for the distribution tools

The distribution endpoints need the user's identity. The Worker already authenticates the WS
upgrade in `onConnect` and injects `x-vd-article-key` / `x-vd-scope`. Extend that to also
persist the verified **bearer token** into the DO `config` table (same mechanism as
`articleKey`/`scope`). `publish_wechat` / `share_to_community` read it back and send
`Authorization: Bearer <token>` to the existing endpoints. The token is the user's own and
never leaves their scope.

### 4. Reporting back to the app

Unchanged protocol. After the loop ends:
- If the current article was written (`write_article` ran), the Worker pushes
  `{type:"updated", article}` with the final doc — the app reloads in place exactly as today.
  (Merge writes into the current doc, so this fires; the other source articles stay untouched.)
- Distribution results (draft id / share URL / WeChat errcode) are summarized in Claude's final
  text and surfaced to the app as `{type:"status"}` / existing channels; no new message type.
- `{type:"status",state:"working"}` and `{type:"error",message}` are unchanged. The loop
  resolves the in-flight queue item once (on the terminal `updated`/final), so
  `ArticleAgentSession`'s serial queue keeps draining as today.

## App-side changes

Minimal. `SpeechDictation` and the WebSocket protocol are unchanged. `ArticleAgentSession`
already handles `status` / `updated` / `error`; no new message types. The only possible tweak
is surfacing the agent's final summary text (e.g. "已发草稿 / 已分享：<url>") as a toast —
optional, can be a follow-up.

## Worker-side changes (`~/code/jianshuo.dev/agent/src/index.js`)

- `onConnect`: also persist the verified bearer token to `config`.
- `onMessage`: replace the single `output_config` rewrite call with the tool-use loop (§2).
- Implement the 5 tool handlers; `write_article` ignores/forbids any stem other than the DO's
  own; distribution tools `fetch` the existing URLs with the stored token.
- Keep `REVISE_SYSTEM` (the owner-voice DNA) as the system prompt; reframe it to "you can edit,
  combine, publish, or share — use the tools to do what the instruction asks, default to
  editing the current article in the owner's voice."
- Keep recording each instruction in `history`.

## Out of scope (YAGNI)

- No task-level composite tools (merge/split/etc. are composed from primitives).
- No visible command list / chips (discoverability is natural-language-only).
- No app-side confirmation, no `action` message type (公众号 fires directly).
- No cross-stem writes.

## Testing

- Worker: tool-use loop terminates; mock Claude driving `list → read → read → write` produces
  the merged current doc and leaves sources untouched.
- Worker: `write_article` only ever writes the DO's own stem (reject/ignore otherwise).
- Worker: `publish_wechat` / `share_to_community` call the right URL with the stored bearer
  token; their results are fed back as `tool_result`.
- Worker: `list_articles` skips `.empty`; `read_article` returns transcript + articles.
- App: `ArticleAgentSession` still routes `updated` and drains the queue across a
  multi-tool turn (which may take longer than a single rewrite).
- Manual: speak rewrite / merge / 发公众号 / 分享社区 end-to-end against a test user.

# Task 6 Review — Wire the loop into ArticleEditor + real Claude tool-use call

**Commit:** `96bd2b4` (`feat: drive ArticleEditor with the agentic tool-use loop`)
**Scope:** `agent/src/index.js` only (213 lines touched: +64 / −149). DO glue, not unit-tested — judged by reading.

---

## Spec compliance: ✅

Every deliverable in the spec is present and correct.

| Spec requirement | Status | Evidence |
|---|---|---|
| `onConnect` persists bearer token (stripped of `Bearer `) into `config` alongside `articleKey`/`scope` | ✅ | `index.js:70-78`. Regex `/^Bearer\s+/i` strips prefix; `set()` writes `articleKey`/`scope`/`token`. |
| Imports `runAgentLoop` from `./loop.js`, `TOOL_DEFS` from `./tools.js` | ✅ | `index.js:18-19` |
| `SYSTEM` constant reuses existing `REVISE_SYSTEM` voice-DNA text (still present + embedded) | ✅ | `REVISE_SYSTEM` defined `24-40`, embedded via `${REVISE_SYSTEM}` at `50`. |
| `onMessage` rewritten: `_busy` guard + `status:working`; loads doc; builds userText (articles+transcript+instruction); runs `runAgentLoop(...)`; re-reads doc + ALWAYS sends `{type:"updated", article}`; inserts history; error path intact; `_busy` reset in finally | ✅ | `87-132`. Matches the spec call shape exactly. |
| `_callClaude` → tool-use wrapper: POSTs Messages API with `tools` + `tool_choice:{type:"auto"}`, returns raw JSON, throws on non-ok | ✅ | `136-148` |
| Old `_rewrite` deleted; `ARTICLES_SCHEMA`/`articlesFrom`/`parseLLMJson` removed (unreferenced) | ✅ | grep across `src/` for all five symbols + `output_config`/`json_schema`: **zero matches**. |
| Commit staged ONLY `src/index.js`; not `functions/files/api/[[path]].js` | ✅ | `git show --name-only 96bd2b4` → single file `agent/src/index.js`. |

### Correctness-focus checks (the things tests don't cover)

- **`ctx` carries all five fields the tools need** ✅ — `index.js:116`: `{ env: this.env, scope, articleKey, token, origin: "https://jianshuo.dev" }`. Cross-checked against tool consumers in `tools.js`: `env`+`scope` (list/read/write/style), `articleKey` (write_article, relKey), `token`+`origin` (postFiles). All present, none missing/misnamed.
- **`_config()` surfaces the token** ✅ — `_config` (`80-85`) does `SELECT k,v FROM config` into a dict, so any key `onConnect` wrote (including `token`) is returned. `onMessage` destructures `{ articleKey, scope, token }` at `97`.
- **`callClaude` arg shape** ✅ — loop invokes `callClaude({system, messages, tools})` (`loop.js:19`); wrapper signature is `_callClaude({ system, messages, tools })` (`index.js:136`) and forwards all three plus `model`/`max_tokens`/`tool_choice` into the body. Shapes line up; the `(p)=>this._callClaude(p)` thunk preserves `this`.
- **"Always updated" fires for action-only turns** ✅ — the `connection.send({type:"updated"...})` at `121-123` is unconditional, placed after the loop, gated on nothing about whether a tool wrote. A publish-only turn (no `write_article`) re-reads the same unchanged doc and still emits `updated`. Re-read uses a fresh `FILES.get(articleKey)` so it reflects any write the loop performed; falls back to in-memory `doc` if the object vanished.
- **No dangling references to deleted symbols** ✅ — grep clean (above).
- **WebSocket protocol to the app unchanged** ✅ — still exactly `{type:"status",state:"working"}`, `{type:"updated",article}`, `{type:"error",message}`. Worker entry, header forwarding (`x-vd-article-key`/`x-vd-scope` + `Authorization` via `new Request(request)`), `StatusHub`, and auth helpers are byte-identical to before.

---

## Code quality: Approved

Clean, faithful execution of the plan. The DO is genuinely thin glue now; all real logic lives in the tested `tools.js`/`loop.js`. No Critical or Important issues. A few Minor observations, none blocking.

### Minor

1. **History context regressed (behavior change, spec-compliant but worth confirming).** The old `_rewrite` fed the last 12 instructions (`SELECT instruction FROM history ... LIMIT 12`) into the prompt as "历次修改要求". The new `onMessage` still *inserts* into `history` (`125`) but never *reads* it — `userText` (`105-114`) contains only the current doc + transcript + this single instruction. So the agent no longer sees prior turns' instructions; the `history` table is now write-only within a turn and cross-turn memory is effectively gone. This matches the Task 6 spec's `userText` definition exactly (spec lists only current articles/transcript/instruction), so it's compliant — flag to the implementer only to confirm the memory loss was deliberate.

2. **`void result;` (`126`).** `runAgentLoop` returns `{calledTools, finalText, steps}` and the result is deliberately discarded. The spec's "Notes / out of scope" explicitly defers surfacing the agent's `finalText` summary, so this is intentional. The `void` documents the intent.

3. **Re-read cost / out-of-band write.** `onMessage` does `FILES.get(articleKey)` once before the loop (`99`) and once after (`121`). The post-loop re-read is *necessary* precisely because `write_article` mutates R2 out-of-band (the loop returns no doc), so this double-read is the correct way to get authoritative post-write state. Two R2 GETs per turn by design — not a defect.

4. **`tool_choice:{type:"auto"}` permits a no-write turn.** For a default 改写 turn the model *should* call `write_article`, but `auto` lets it reply with text and write nothing — in which case the unconditional re-read returns the unchanged doc and the user sees "no change." Prompt-reliability concern, not a code bug; the SYSTEM prompt does say 默认就是「改写当前这篇」 to steer it. Acceptable for v1.

### Verified-correct, easy-to-get-wrong (not issues)

- v1 fallback for legacy single-`body` docs preserved in `onMessage` (`102-103`), mirroring old `_rewrite`.
- `_busy` reset in `finally` (`130`) on every path incl. throw — no permanent lock.
- Error path stringifies `(e && e.message) || e` (`128`), safe for non-Error throws.
- `max_tokens: 8000` and `model: MODEL` (`claude-sonnet-4-6`) carried over; model constant kept per Global Constraints.

---

## Verdict

**Spec ✅** — all seven deliverables and all six correctness-focus points satisfied; commit hygiene correct (single file `src/index.js`).
**Code quality: Approved** — no Critical/Important findings. The only substantive behavioral note (Minor #1: per-turn history context dropped) is spec-compliant and likely intentional; confirm with the implementer that cross-turn memory loss was deliberate.

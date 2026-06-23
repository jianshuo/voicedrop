# Agent Reply Bubble Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the article-editing agent's closing one-liner (`finalText`) as a transient chat-style bubble in the app, so non-`write_article` tools (publish, share, style) and recoverable failures stop being silent.

**Architecture:** The Worker's `runAgentLoop` already computes `finalText`; add a `hadError` flag and stop discarding it — `onMessage` sends a new `{type:"reply", text, ok}` after the existing `{type:"updated"}`. The app's `ArticleAgentSession` routes `reply` to a callback; `RecordingDetailView` shows it as a light bubble that fades on success and sticks (muted-red, tap-to-dismiss) on error.

**Tech Stack:** Cloudflare Worker (Durable Object, `agents` SDK) + vitest; SwiftUI iOS app.

## Global Constraints

- Two repos: Worker = `~/code/jianshuo.dev/agent` (work in `agent/`; the parent repo has PRE-EXISTING uncommitted changes to `functions/files/api/[[path]].js` and `.wrangler/state/...` — never `git add -A`/`git add .`, stage only named files). App = `~/code/voicedrop`.
- Reply message shape: `{type:"reply", text:<string>, ok:<bool>}`. `ok:false` = a tool reported an error this turn.
- Transient only: success fades after ~3s; error is sticky until tapped. No persistence, no new app→agent messages, no in-bubble affordances.
- Error bubble style: subtle — muted-red border + warning glyph on the light bubble, NOT a filled amber bubble.
- The `updated` message and the serial queue resolution are UNCHANGED; `reply` is display-only and must not touch the queue.
- Commit after each task with the exact message given.

---

### Task 1: Worker — return `hadError` and emit the reply message

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/loop.js` (`runAgentLoop`)
- Modify: `~/code/jianshuo.dev/agent/src/index.js` (`ArticleEditor.onMessage`)
- Test: `~/code/jianshuo.dev/agent/test/loop.test.js`

**Interfaces:**
- Produces: `runAgentLoop(...)` now returns `{calledTools, finalText, steps, hadError}` where
  `hadError` is `true` iff any tool result this turn had a truthy `.error`.
- Produces (WebSocket, agent→app): `{type:"reply", text, ok}` sent from `onMessage` after `updated`.

- [ ] **Step 1: Write the failing test for `hadError`**

Append to `~/code/jianshuo.dev/agent/test/loop.test.js` (inside the existing `describe("runAgentLoop", ...)` or as a new `describe`). It reuses the `asst`/`toolUse`/`text`/`ctx` helpers already defined at the top of that file:

```js
describe("runAgentLoop hadError", () => {
  it("flags hadError when a tool returns an error", async () => {
    const env = fakeEnv({ "users/u/articles/cur.json": JSON.stringify({ articles: [{ title: "C", body: "c" }] }) });
    // read_article with a bad stem returns {error:"bad_stem"}; then Claude wraps up.
    const script = [asst(toolUse("read_article", { stem: "../x" })), asst(text("读不了"))];
    let i = 0;
    const r = await runAgentLoop({ callClaude: async () => script[i++], ctx: ctx(env), system: "S", userText: "go" });
    expect(r.hadError).toBe(true);
  });

  it("hadError is false for an all-success chain", async () => {
    const env = fakeEnv({ "users/u/articles/cur.json": JSON.stringify({ articles: [{ title: "C", body: "c" }] }) });
    const script = [asst(toolUse("write_article", { articles: [{ title: "C2", body: "c2" }] })), asst(text("改好了"))];
    let i = 0;
    const r = await runAgentLoop({ callClaude: async () => script[i++], ctx: ctx(env), system: "S", userText: "go" });
    expect(r.hadError).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — `r.hadError` is `undefined` (not `true`/`false`).

- [ ] **Step 3: Implement `hadError` in the loop**

In `~/code/jianshuo.dev/agent/src/loop.js`, update `runAgentLoop` to accumulate `hadError`. Replace the function body so the tool-execution section captures each result and checks `.error`, and the return includes `hadError`:

```js
export async function runAgentLoop({ callClaude, ctx, system, userText, maxSteps = 8 }) {
  const messages = [{ role: "user", content: userText }];
  const calledTools = [];
  let finalText = "";
  let hadError = false;
  let steps = 0;
  while (steps < maxSteps) {
    const resp = await callClaude({ system, messages, tools: TOOL_DEFS });
    steps++;
    const { text, toolUses } = parseAssistant(resp);
    messages.push({ role: "assistant", content: resp.content });
    if (!toolUses.length) { finalText = text; break; }
    const results = [];
    for (const tu of toolUses) {
      calledTools.push(tu.name);
      const result = await runTool(tu.name, tu.input, ctx);
      if (result && result.error) hadError = true;
      results.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify(result) });
    }
    messages.push({ role: "user", content: results });
  }
  return { calledTools, finalText, steps, hadError };
}
```

(Keep `parseAssistant` and the imports exactly as they are.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS — all loop tests including the two new `hadError` cases; the prior 18 still green.

- [ ] **Step 5: Emit the reply in `onMessage`**

In `~/code/jianshuo.dev/agent/src/index.js`, find the `onMessage` block that currently does:

```js
      const after = await this.env.FILES.get(articleKey);
      const finalDoc = after ? JSON.parse(await after.text()) : doc;
      connection.send(JSON.stringify({ type: "updated", article: finalDoc }));

      this.sql`INSERT INTO history (instruction, created_at) VALUES (${instruction}, ${Date.now()})`;
      void result;
```

Replace it with (send a `reply` derived from the loop result; drop `void result`):

```js
      const after = await this.env.FILES.get(articleKey);
      const finalDoc = after ? JSON.parse(await after.text()) : doc;
      connection.send(JSON.stringify({ type: "updated", article: finalDoc }));

      const summary = (result.finalText || "").trim();
      if (summary) {
        connection.send(JSON.stringify({ type: "reply", text: summary, ok: !result.hadError }));
      } else if (result.hadError) {
        connection.send(JSON.stringify({ type: "reply", text: "操作没完成", ok: false }));
      }

      this.sql`INSERT INTO history (instruction, created_at) VALUES (${instruction}, ${Date.now()})`;
```

Note: the existing `SYSTEM` constant already ends with "做完简短说一句结果即可。", so `finalText` is normally present — no SYSTEM change needed.

- [ ] **Step 6: Verify tests + build still clean**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (no regressions; `index.js` has no unit tests but must still parse).
Run: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy --dry-run`
Expected: build succeeds, no syntax/import errors (no upload).

- [ ] **Step 7: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/loop.js src/index.js test/loop.test.js
git commit -m "feat: emit agent reply message (finalText + hadError) from the edit loop"
```

---

### Task 2: App — route `reply` and render the transient bubble

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/AgentSession.swift` (`ArticleAgentSession`)
- Modify: `~/code/voicedrop/VoiceDropApp/RecordingDetailView.swift` (`voiceBar`, state, wiring)

**Interfaces:**
- Consumes: the `{type:"reply", text, ok}` message from Task 1.
- Produces: `ArticleAgentSession.onReply: ((String, Bool) -> Void)?` — invoked on the main actor
  when a `reply` arrives. Does NOT modify the queue.

This task has no unit-test harness (SwiftUI view + WebSocket client); the gate is a clean
compile plus the manual smoke in the spec. Steps are still small and ordered.

- [ ] **Step 1: Add the `onReply` callback and handler to `ArticleAgentSession`**

In `~/code/voicedrop/VoiceDropApp/AgentSession.swift`, next to the existing
`var onUpdate: ((ArticleDoc) -> Void)?` declaration, add:

```swift
    /// Called on the main actor when the agent sends a one-line reply (text + ok).
    /// Display-only — does not affect the edit queue.
    var onReply: ((String, Bool) -> Void)?
```

Then in `handle(_:)`, add a `case "reply"` alongside the existing `status` / `updated` / `error`
cases (it must NOT dequeue or pump — purely surfacing):

```swift
        case "reply":
            if let text = obj["text"] as? String, !text.isEmpty {
                let ok = obj["ok"] as? Bool ?? true
                onReply?(text, ok)
            }
```

- [ ] **Step 2: Add the reply model + state + wiring to `RecordingDetailView`**

In `~/code/voicedrop/VoiceDropApp/RecordingDetailView.swift`:

(a) Add a small model near the top of the file (file scope, e.g. just above the view struct):

```swift
/// A transient one-line reply from the editing agent.
struct AgentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let ok: Bool
}
```

(b) Add state inside the view, next to the other `@State` properties:

```swift
    @State private var agentReply: AgentReply?
```

(c) Where `agent.onUpdate = { ... }` is wired (around line 84, in the same setup block before
`agent.connect(recording)`), add the reply wiring. On success, auto-clear after ~3s only if the
shown reply is still the same one; on error, leave it until tapped:

```swift
        agent.onReply = { text, ok in
            let reply = AgentReply(text: text, ok: ok)
            agentReply = reply
            if ok {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if agentReply?.id == reply.id { agentReply = nil }
                }
            }
        }
```

- [ ] **Step 3: Render the bubble in `voiceBar`**

In `~/code/voicedrop/VoiceDropApp/RecordingDetailView.swift`, in the `voiceBar` computed view,
insert the reply bubble into the `VStack(spacing: 8)` ABOVE the queue rows / transcript / pill
(i.e. as the first child, so it sits highest in the floating stack). Add it right after the
`return VStack(spacing: 8) {` line:

```swift
            if let reply = agentReply { replyBubble(reply) }
```

Then add the `replyBubble` helper next to `darkBubble(_:)`:

```swift
    /// The agent's transient one-line reply. Success: neutral light card (auto-fades).
    /// Error: muted-red border + warning glyph, sticky until tapped.
    private func replyBubble(_ reply: AgentReply) -> some View {
        let warn = Color(hex: "C0392B")
        return HStack(spacing: 8) {
            Image(systemName: reply.ok ? "sparkles" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(reply.ok ? Theme.accent : warn)
            Text(reply.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(reply.ok ? Theme.borderRead : warn.opacity(0.7), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { if !reply.ok { agentReply = nil } }
    }
```

Also add the reply to the bar's animation so it eases in/out — extend the existing
`.animation(.easeInOut(duration: 0.22), value: agent.queue)` area by adding, just after it:

```swift
        .animation(.easeInOut(duration: 0.22), value: agentReply)
```

- [ ] **Step 4: Compile the app**

Run:
```bash
cd ~/code/voicedrop && xcodegen generate && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ddp build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If the build fails for environment/signing reasons unrelated
to these edits, capture the exact error in the report; a compile error in the edited files must
be fixed.

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop && git add VoiceDropApp/AgentSession.swift VoiceDropApp/RecordingDetailView.swift
git commit -m "feat: show transient agent reply bubble (fades on success, sticky on error)"
```

Note: `VoiceDropApp/Community.swift` and `VoiceDropApp/RecordingDetailView.swift` may have
PRE-EXISTING uncommitted edits in the working tree. Stage ONLY the two files named above; if
`RecordingDetailView.swift` already had unrelated pending changes, include them only if they are
part of this feature — otherwise coordinate (do not silently bundle unrelated changes). Confirm
with `git diff --cached --stat` before committing.

---

## Self-review notes

- Spec §1 (Worker hadError + reply + fallback) → Task 1 Steps 1–5. SYSTEM already instructs a
  closing line, so no prompt edit (noted in Task 1 Step 5).
- Spec §2 (app receive/hold) → Task 2 Steps 1–2 (`onReply`, state, 3s fade on success, sticky on
  error).
- Spec §3 (bubble UI: light card, success fades, error muted-red sticky tap-to-dismiss) → Task 2
  Step 3.
- Spec §Testing (Worker unit test for hadError) → Task 1 Steps 1–4. App manual smoke is the
  spec's checklist, run after deploy.

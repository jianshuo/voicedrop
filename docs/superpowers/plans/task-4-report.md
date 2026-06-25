# Task 4 Fix Report — 2026-06-23

## Edits Made

**`agent/src/tools.js`** (commit `7b1810d`):
1. `postFiles`: changed bare `fetch(...)` to `globalThis.fetch(...)` so the test stub is unambiguously picked up.
2. `relKey`: replaced silent fallback with a throw — `if (!articleKey.startsWith(scope)) throw new Error("bad_scope"); return articleKey.slice(scope.length);` — so misconfigured context surfaces as `{error:"bad_scope"}` via `runTool`'s catch.

**`agent/test/tools.test.js`** (same commit):
3. Removed unused `vi` from `import { afterEach, vi } from "vitest"` → `import { afterEach } from "vitest"`.
4. Made `afterEach` cleanup unconditional: `afterEach(() => { delete globalThis.fetch; });`.
5. Added `Authorization: Bearer t` assertion to the `share_to_community` test (mirrors `publish_wechat` test).

## Test Run

```
cd ~/code/jianshuo.dev/agent && npm test
```

Output: `14 passed (14)` — all tests green, duration ~207ms.

## Commit

SHA: `7b1810d`  
Message: `fix: harden distribution tools (globalThis.fetch, strict relKey, test cleanup)`

---

# Task 4 Review: Distribution tools — publish_wechat / share_to_community

Commit: `430f290` — touches only `agent/src/tools.js` and `agent/test/tools.test.js`. Confirmed: `functions/files/api/[[path]].js` not staged.

---

## Spec Compliance: FAIL (one issue)

### Both tools present
`publish_wechat` and `share_to_community` are registered in `src/tools.js`. TOOL_DEFS grows to 7. Input schemas are `{type:"object",properties:{},additionalProperties:false}` (no input). Correct.

### URL paths
- `publish_wechat` posts to `${origin}/files/api/wechat/${rel}`. Correct.
- `share_to_community` posts to `${origin}/files/api/community/share/${rel}`. Correct.

### Authorization header
`headers: { Authorization: \`Bearer ${token}\` }` — present. Correct.

### Non-ok handling
Returns `body || { error: \`http_${resp.status}\` }`. Returns the body when available, falls back to `{error:"http_<status>"}`. Correct.

### `rel` computation — SPEC FAIL
**Critical:** The spec and Global Constraints both require `rel = articleKey.slice(scope.length)` (the bare `slice`). The implementation uses:

```js
function relKey({ articleKey, scope }) {
  return articleKey.startsWith(scope) ? articleKey.slice(scope.length) : articleKey;
}
```

The fallback branch (`return articleKey`) fires when `articleKey` does NOT start with `scope`, and in that case it returns the full key unchanged — including the full `users/<sub>/...` prefix. This would cause a double-prefix on the server (`keyFor` would re-prepend scope to an already-full key). However, in production the DO always sets `articleKey` to a key inside `scope`, so the fallback branch is dead code. Functional risk is low, but the spec says there is no fallback — it should always slice. The fallback silently swallows a mis-configured context instead of surfacing an error, which could cause a confusing server-side 404 rather than a clear local error.

### `fetch` vs `globalThis.fetch`
**Critical:** `postFiles` calls bare `fetch` at line 103, not `globalThis.fetch`. In Cloudflare Workers the runtime injects `fetch` as a global, so production works. But the test stub sets `globalThis.fetch = fakeFetch(...)`. In Node/Vitest, bare `fetch` resolves from the module's lexical scope binding — in practice, Node's global `fetch` IS `globalThis.fetch`, so the tests happen to pass. However, the spec explicitly requires: **"Both read `globalThis.fetch` so tests can stub it."** The implementation deviates: it uses the unqualified name `fetch`, not `globalThis.fetch`. If Vitest ever hoists the module or runs in a context where the binding is captured at import time rather than call time, the stub would not be picked up.

### Test count
14 tests pass. Confirmed by the existing report. Correct.

---

## Code Quality: Issues

**Critical — `globalThis.fetch` vs bare `fetch`**
The spec is explicit. `postFiles` should read `globalThis.fetch` at call time so the stub assignment in tests is unambiguously honored. The current `fetch` works in practice (Node's global `fetch` is `globalThis.fetch`) but violates the stated contract and is fragile if the execution context changes.

Fix: `const resp = await globalThis.fetch(...)` in `postFiles`.

**Critical — relKey fallback**
The fallback `return articleKey` returns the full key when scope is missing, which would double-prefix on the server. Better: throw or return `{ error: "bad_scope" }` to surface the misconfiguration rather than silently producing a broken URL.

**Minor — unused `vi` import in test**
`import { afterEach, vi } from "vitest"` imports `vi` but never uses it. No mocking is done — the stub is set by direct property assignment. Harmless, but the `vi` import is dead weight and should be dropped.

**Minor — `afterEach` cleanup condition is narrower than needed**
`if (globalThis.fetch && globalThis.fetch.calls) delete globalThis.fetch` — the `.calls` check means if somehow a `fakeFetch` without `.calls` is installed, it leaks into subsequent tests. Simpler and more robust: just `delete globalThis.fetch` unconditionally (or restore the original).

**Minor — `share_to_community` test does not assert the Authorization header**
The `publish_wechat` test checks `call.headers.Authorization`. The `share_to_community` test does not. Given the bearer token is the critical auth path, the same assertion on the community call would strengthen coverage. Not a correctness bug, but a gap in test hygiene.

---

## Summary

| Check | Result |
|---|---|
| Both tools present | Pass |
| URL paths correct | Pass |
| Authorization header sent | Pass |
| Non-ok handling | Pass |
| `rel` strips scope prefix | Pass (functionally) |
| `relKey` fallback safe | Fail — silently returns full key |
| Uses `globalThis.fetch` | Fail — uses bare `fetch` (spec deviation) |
| Commit scope (2 files only) | Pass |
| 14 tests green | Pass |
| TOOL_DEFS = 7 | Pass |

**Spec: FAIL** — two deviations from explicit spec requirements (`globalThis.fetch` and `relKey` fallback behavior).

**Code quality: Issues** — two Critical, three Minor findings above.

# VoiceDrop 算力计费 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each VoiceDrop user a gifted "算力" balance that is debited at real cost when their recordings are mined / voice-edited, stops them at 0, and is visible/transparent — with no real-money, refund, or payout surface.

**Architecture:** A new private D1 database `voicedrop-usage` bound to the **existing** `voicedrop-agent` Worker (where all billable ASR + Claude calls happen). Pure pricing/decision functions in `agent/src/usage.js`; D1 access in `agent/src/usage_store.js`; thin wiring into `miner.js` (mine path) and `index.js` (edit path + read routes). iOS adds a balance view, a `.blocked` recording state, and an edit-blocked message.

**Tech Stack:** Cloudflare Workers (ESM), D1 (SQLite), Vitest + better-sqlite3 (test-time D1 shim), SwiftUI.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-06-27-voicedrop-usage-billing-design.md`). Every task implicitly includes these:

- **Exchange (钉死):** `RATE = 23` 算力 per ¥. `FX = 7.3` USD→RMB. Display only; ledger stored in **微元 (integer, 1e-6 元)**, never float.
- **Pricing source of truth:** sonnet-4-6 = $3/$15 per Mtok; haiku-4-5 = $1/$5 per Mtok; 火山 ASR = ¥0.8/hour. All cost computed in 微元 with `Math.ceil` (never undercharge). Unknown model → cost 0.
- **Grant:** new user one-time **500 算力** (lazy-created on first touch). No monthly reset. Campaign grants via admin primitive.
- **Gate:** process only if `balance_uy > 0` (last transaction may overdraw to slightly negative; next is blocked).
- **Anti-abuse:** recording ≤ **3 hours**; ≤ **100 edits** per article.
- **Fail-open:** if D1 is unreachable, allow the work and skip recording (log a lapse); never block the product.
- **No real money:** no top-up, refund, withdrawal, payout, or public all-users ledger in this plan.
- **Isolation:** lives in `voicedrop-usage` D1 only — never touch reco / `engagement`.
- **Repo paths:** Worker = `~/code/jianshuo.dev/agent/`. iOS = `~/code/voicedrop/VoiceDropApp/` (xcodegen — run `xcodegen generate` after adding any Swift file). Pages admin pages live beside `voicedrop/admin/mine.html` (locate with `find ~/code/jianshuo.dev -name mine.html`).
- **Test gate (CLAUDE.md):** before and after changes run `cd ~/code/jianshuo.dev/agent && npm test` — must stay green (no regression in miner/agent/routes).

---

### Task 1: Pricing & decision pure functions (`usage.js`)

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/usage.js`
- Test: `~/code/jianshuo.dev/agent/test/usage.test.js`

**Interfaces:**
- Produces: `FX`, `RATE`, `PRICE`, `ASR_RMB_PER_HOUR`, `SIGNUP_GRANT_UY`, `MAX_RECORDING_SEC`, `MAX_EDITS_PER_ARTICLE`; `yuanToUY(y)→int`, `suanliToUY(s)→int`, `uyToSuanli(uy)→number`, `uyToYuan(uy)→number`, `claudeCostUY(model,inTok,outTok)→int`, `asrCostUY(seconds)→int`, `gateDecision(balanceUY,durationSec)→"ok"|"no-credit"|"too-long"`, `editGate(balanceUY,editsSoFar)→"ok"|"no-credit"|"limit"`.

- [ ] **Step 1: Write the failing test**

```javascript
// test/usage.test.js
import { describe, it, expect } from "vitest";
import {
  claudeCostUY, asrCostUY, uyToSuanli, SIGNUP_GRANT_UY,
  gateDecision, editGate, MAX_RECORDING_SEC, MAX_EDITS_PER_ARTICLE,
} from "../src/usage.js";

describe("usage pricing", () => {
  it("claudeCostUY: haiku 1000in/100out = 10950 微元", () => {
    expect(claudeCostUY("claude-haiku-4-5", 1000, 100)).toBe(10950);
  });
  it("claudeCostUY: unknown model = 0", () => {
    expect(claudeCostUY("gpt-x", 1000, 100)).toBe(0);
  });
  it("asrCostUY: 1 hour = 800000 微元 = 18.4 算力", () => {
    expect(asrCostUY(3600)).toBe(800000);
    expect(uyToSuanli(800000)).toBeCloseTo(18.4, 5);
  });
  it("signup grant ≈ 500 算力", () => {
    expect(uyToSuanli(SIGNUP_GRANT_UY)).toBeCloseTo(500, 2);
  });
});

describe("usage gates", () => {
  it("gateDecision: too-long wins over balance", () => {
    expect(gateDecision(999999, MAX_RECORDING_SEC + 1)).toBe("too-long");
  });
  it("gateDecision: zero balance blocks", () => {
    expect(gateDecision(0, 60)).toBe("no-credit");
    expect(gateDecision(1, 60)).toBe("ok");
  });
  it("editGate: balance then limit", () => {
    expect(editGate(0, 0)).toBe("no-credit");
    expect(editGate(100, MAX_EDITS_PER_ARTICLE)).toBe("limit");
    expect(editGate(100, 0)).toBe("ok");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage.test.js`
Expected: FAIL — `Failed to resolve import "../src/usage.js"`.

- [ ] **Step 3: Write the implementation**

```javascript
// src/usage.js — single source of truth for VoiceDrop usage pricing.
export const FX = 7.3;            // USD->RMB, fixed conservative
export const RATE = 23;           // 算力 per ¥ (23 算力 = ¥1)
export const ASR_RMB_PER_HOUR = 0.8;
export const PRICE = {            // USD per token
  "claude-sonnet-4-6": { in: 3 / 1e6, out: 15 / 1e6 },
  "claude-haiku-4-5":  { in: 1 / 1e6, out: 5 / 1e6 },
};
export const MAX_RECORDING_SEC = 3 * 3600;
export const MAX_EDITS_PER_ARTICLE = 100;

export const yuanToUY = (y) => Math.ceil(y * 1e6);          // 元 -> 微元 (ceil)
export const suanliToUY = (s) => Math.round((s / RATE) * 1e6); // 算力 -> 微元
export const uyToSuanli = (uy) => (uy * RATE) / 1e6;        // 微元 -> 算力
export const uyToYuan = (uy) => uy / 1e6;                   // 微元 -> 元

export const SIGNUP_GRANT_UY = suanliToUY(500);            // 一次性 500 算力

export function claudeCostUY(model, inTok, outTok) {
  const p = PRICE[model];
  if (!p) return 0;
  const usd = (inTok || 0) * p.in + (outTok || 0) * p.out;
  return Math.ceil(usd * FX * 1e6);
}
export function asrCostUY(seconds) {
  return Math.ceil(((seconds || 0) / 3600) * ASR_RMB_PER_HOUR * 1e6);
}
export function gateDecision(balanceUY, durationSec) {
  if ((durationSec || 0) > MAX_RECORDING_SEC) return "too-long";
  if (balanceUY <= 0) return "no-credit";
  return "ok";
}
export function editGate(balanceUY, editsSoFar) {
  if (balanceUY <= 0) return "no-credit";
  if ((editsSoFar || 0) >= MAX_EDITS_PER_ARTICLE) return "limit";
  return "ok";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage.test.js`
Expected: PASS (8 assertions).

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add src/usage.js test/usage.test.js
git commit -m "feat(usage): pricing + gate decision pure functions"
```

---

### Task 2: D1 migration + binding + better-sqlite3 dev dep

**Files:**
- Create: `~/code/jianshuo.dev/agent/migrations/0001_usage.sql`
- Modify: `~/code/jianshuo.dev/agent/wrangler.jsonc` (add `d1_databases`)
- Modify: `~/code/jianshuo.dev/agent/package.json` (devDependency `better-sqlite3`)

**Interfaces:**
- Produces: D1 binding `env.USAGE`; tables `account`, `ledger` (schema below, consumed by Task 3).

- [ ] **Step 1: Write the migration SQL**

```sql
-- migrations/0001_usage.sql
CREATE TABLE IF NOT EXISTS account (
  user_sub   TEXT PRIMARY KEY,
  balance_uy INTEGER NOT NULL DEFAULT 0,
  granted_uy INTEGER NOT NULL DEFAULT 0,
  spent_uy   INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_sub   TEXT NOT NULL,
  ts         INTEGER NOT NULL,
  kind       TEXT NOT NULL,            -- 'grant' | 'spend'
  amount_uy  INTEGER NOT NULL,         -- positive magnitude; direction from kind
  reason     TEXT NOT NULL,            -- 'signup'|'campaign:<id>'|'mine'|'edit'|'asr'
  detail     TEXT,                     -- JSON
  balance_uy INTEGER NOT NULL          -- post-transaction snapshot
);
CREATE INDEX IF NOT EXISTS idx_ledger_user ON ledger(user_sub, ts);
```

- [ ] **Step 2: Add the D1 binding to wrangler.jsonc**

Insert a top-level block alongside the existing `r2_buckets` block:

```jsonc
"d1_databases": [
  { "binding": "USAGE", "database_name": "voicedrop-usage", "database_id": "PLACEHOLDER_FROM_CREATE" }
],
```

- [ ] **Step 3: Create the remote DB and run the migration**

```bash
cd ~/code/jianshuo.dev/agent
npx wrangler d1 create voicedrop-usage   # copy the printed database_id into wrangler.jsonc above
npx wrangler d1 execute voicedrop-usage --remote --file=migrations/0001_usage.sql
```
Expected: create prints a `database_id` UUID; execute prints `Executed 3 commands`.

- [ ] **Step 4: Add the test-time D1 shim dependency**

```bash
cd ~/code/jianshuo.dev/agent
npm install -D better-sqlite3
```
Expected: `better-sqlite3` appears under `devDependencies` in `package.json`.

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add migrations/0001_usage.sql wrangler.jsonc package.json package-lock.json
git commit -m "feat(usage): D1 voicedrop-usage schema + USAGE binding + sqlite test dep"
```

---

### Task 3: D1 store + test shim (`usage_store.js`)

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/usage_store.js`
- Modify: `~/code/jianshuo.dev/agent/test/fakes.js` (add `fakeD1`)
- Test: `~/code/jianshuo.dev/agent/test/usage_store.test.js`

**Interfaces:**
- Consumes: `SIGNUP_GRANT_UY` from `usage.js`; a D1-like handle (`prepare().bind().run()/first()/all()`).
- Produces: `ensureAccount(db,userSub,now)→balanceUY`, `getBalanceUY(db,userSub)→int|null`, `debit(db,userSub,amountUY,reason,detail,now)`, `grant(db,userSub,amountUY,reason,now)`, `getLedger(db,userSub,limit)→rows[]`, `editCount(db,userSub,stem)→int`, `allAccounts(db)→rows[]`. Test helper `fakeD1(migrationSql)`.

- [ ] **Step 1: Add the better-sqlite3-backed D1 shim to fakes.js**

Append to `~/code/jianshuo.dev/agent/test/fakes.js`:

```javascript
import Database from "better-sqlite3";

// Minimal D1-compatible handle backed by in-memory SQLite (real SQL).
export function fakeD1(migrationSql) {
  const db = new Database(":memory:");
  if (migrationSql) db.exec(migrationSql);
  return {
    prepare(sql) {
      const stmt = db.prepare(sql);
      let args = [];
      const api = {
        bind(...a) { args = a; return api; },
        run() { const r = stmt.run(...args); return { success: true, meta: { changes: r.changes, last_row_id: r.lastInsertRowid } }; },
        first(col) { const row = stmt.get(...args); if (col != null) return row ? row[col] : null; return row ?? null; },
        all() { return { results: stmt.all(...args) }; },
      };
      return api;
    },
    exec(sql) { db.exec(sql); return { count: 0 }; },
  };
}
```

- [ ] **Step 2: Write the failing test**

```javascript
// test/usage_store.test.js
import { describe, it, expect, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { fakeD1 } from "./fakes.js";
import { ensureAccount, getBalanceUY, debit, grant, getLedger, editCount, allAccounts } from "../src/usage_store.js";
import { SIGNUP_GRANT_UY } from "../src/usage.js";

const SQL = readFileSync(fileURLToPath(new URL("../migrations/0001_usage.sql", import.meta.url)), "utf8");
const U = "users/anon-test/";
let db;
beforeEach(() => { db = fakeD1(SQL); });

describe("usage_store", () => {
  it("ensureAccount grants signup once, idempotent", async () => {
    expect(await ensureAccount(db, U, 1)).toBe(SIGNUP_GRANT_UY);
    expect(await ensureAccount(db, U, 2)).toBe(SIGNUP_GRANT_UY); // no double grant
    expect(await getBalanceUY(db, U)).toBe(SIGNUP_GRANT_UY);
    expect((await getLedger(db, U, 10)).length).toBe(1);
  });
  it("debit lowers balance + writes ledger; can overdraw", async () => {
    await ensureAccount(db, U, 1);
    await debit(db, U, SIGNUP_GRANT_UY + 5, "mine", { stem: "s1" }, 2);
    expect(await getBalanceUY(db, U)).toBe(-5);
    const led = await getLedger(db, U, 10);
    expect(led[0].kind).toBe("spend");
    expect(led[0].balance_uy).toBe(-5);
  });
  it("grant adds + ensures account", async () => {
    await grant(db, U, 1000, "campaign:x", 1);
    expect(await getBalanceUY(db, U)).toBe(SIGNUP_GRANT_UY + 1000);
  });
  it("editCount counts only edit rows for that stem", async () => {
    await ensureAccount(db, U, 1);
    await debit(db, U, 1, "edit", { stem: "a" }, 2);
    await debit(db, U, 1, "edit", { stem: "a" }, 3);
    await debit(db, U, 1, "edit", { stem: "b" }, 4);
    await debit(db, U, 1, "mine", { stem: "a" }, 5);
    expect(await editCount(db, U, "a")).toBe(2);
  });
  it("allAccounts returns rows", async () => {
    await ensureAccount(db, U, 1);
    expect((await allAccounts(db)).length).toBe(1);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_store.test.js`
Expected: FAIL — cannot resolve `../src/usage_store.js`.

- [ ] **Step 4: Write the implementation**

```javascript
// src/usage_store.js — D1 access for the usage ledger.
import { SIGNUP_GRANT_UY } from "./usage.js";

export async function ensureAccount(db, userSub, now) {
  const row = await db.prepare("SELECT balance_uy FROM account WHERE user_sub=?").bind(userSub).first();
  if (row) return row.balance_uy;
  await db.prepare(
    "INSERT INTO account (user_sub,balance_uy,granted_uy,spent_uy,created_at,updated_at) VALUES (?,?,?,?,?,?)"
  ).bind(userSub, SIGNUP_GRANT_UY, SIGNUP_GRANT_UY, 0, now, now).run();
  await db.prepare(
    "INSERT INTO ledger (user_sub,ts,kind,amount_uy,reason,detail,balance_uy) VALUES (?,?,?,?,?,?,?)"
  ).bind(userSub, now, "grant", SIGNUP_GRANT_UY, "signup", null, SIGNUP_GRANT_UY).run();
  return SIGNUP_GRANT_UY;
}

export async function getBalanceUY(db, userSub) {
  const row = await db.prepare("SELECT balance_uy FROM account WHERE user_sub=?").bind(userSub).first();
  return row ? row.balance_uy : null;
}

export async function debit(db, userSub, amountUY, reason, detail, now) {
  if (!amountUY || amountUY <= 0) return;
  const cur = await db.prepare("SELECT balance_uy FROM account WHERE user_sub=?").bind(userSub).first();
  const bal = (cur ? cur.balance_uy : 0) - amountUY;
  await db.prepare("UPDATE account SET balance_uy=?, spent_uy=spent_uy+?, updated_at=? WHERE user_sub=?")
    .bind(bal, amountUY, now, userSub).run();
  await db.prepare("INSERT INTO ledger (user_sub,ts,kind,amount_uy,reason,detail,balance_uy) VALUES (?,?,?,?,?,?,?)")
    .bind(userSub, now, "spend", amountUY, reason, detail ? JSON.stringify(detail) : null, bal).run();
}

export async function grant(db, userSub, amountUY, reason, now) {
  await ensureAccount(db, userSub, now);
  const cur = await db.prepare("SELECT balance_uy FROM account WHERE user_sub=?").bind(userSub).first();
  const bal = cur.balance_uy + amountUY;
  await db.prepare("UPDATE account SET balance_uy=?, granted_uy=granted_uy+?, updated_at=? WHERE user_sub=?")
    .bind(bal, amountUY, now, userSub).run();
  await db.prepare("INSERT INTO ledger (user_sub,ts,kind,amount_uy,reason,detail,balance_uy) VALUES (?,?,?,?,?,?,?)")
    .bind(userSub, now, "grant", amountUY, reason, null, bal).run();
}

export async function getLedger(db, userSub, limit = 50) {
  const r = await db.prepare(
    "SELECT ts,kind,amount_uy,reason,detail,balance_uy FROM ledger WHERE user_sub=? ORDER BY ts DESC, id DESC LIMIT ?"
  ).bind(userSub, limit).all();
  return r.results;
}

export async function editCount(db, userSub, stem) {
  const row = await db.prepare(
    "SELECT COUNT(*) AS n FROM ledger WHERE user_sub=? AND reason='edit' AND json_extract(detail,'$.stem')=?"
  ).bind(userSub, stem).first();
  return row ? row.n : 0;
}

export async function allAccounts(db) {
  const r = await db.prepare(
    "SELECT user_sub,balance_uy,granted_uy,spent_uy,updated_at FROM account ORDER BY spent_uy DESC"
  ).all();
  return r.results;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_store.test.js`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add src/usage_store.js test/fakes.js test/usage_store.test.js
git commit -m "feat(usage): D1 store (ensureAccount/debit/grant/ledger) + sqlite test shim"
```

---

### Task 4: Wire the mine path (gate + `.blocked` + debit) in `miner.js`

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/miner.js` (add imports + `writeBlocked` helper near `writeEmpty` ~L447; gate logic in `mineOneAudio` after the `.json`/`.empty` HEAD skip ~L499–502; ASR debit after `asrPoll` returns duration ~L246/277; Claude debit after each `writeLlmLog` ~L565/569)
- Test: `~/code/jianshuo.dev/agent/test/usage_mine.test.js`

**Interfaces:**
- Consumes: `gateDecision`, `claudeCostUY`, `asrCostUY` (usage.js); `ensureAccount`, `getBalanceUY`, `debit` (usage_store.js); existing `userPrefix(audioKey)`, `audioDurationSeconds(key)`, `writeEmpty(audioKey,reason,env)`.
- Produces: marker `articles/<stem>.blocked` with content `{status:"blocked",reason:"no-credit"|"too-long"}`; ledger `spend` rows reason `mine`/`asr`.

- [ ] **Step 1: Write the failing test (gate short-circuit)**

```javascript
// test/usage_mine.test.js
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { fakeD1 } from "./fakes.js";
import { meteredMineGate } from "../src/miner.js";   // extracted, see Step 3
import { SIGNUP_GRANT_UY } from "../src/usage.js";

const SQL = readFileSync(fileURLToPath(new URL("../migrations/0001_usage.sql", import.meta.url)), "utf8");

describe("meteredMineGate", () => {
  it("new user (lazy 500) with normal duration => ok", async () => {
    const db = fakeD1(SQL);
    expect(await meteredMineGate(db, "users/anon-a/", 60, 1)).toBe("ok");
  });
  it("over 3h => too-long (no account touched needed)", async () => {
    const db = fakeD1(SQL);
    expect(await meteredMineGate(db, "users/anon-b/", 3 * 3600 + 1, 1)).toBe("too-long");
  });
  it("drained balance => no-credit", async () => {
    const db = fakeD1(SQL);
    // drain: ensure + debit everything
    const { ensureAccount, debit } = await import("../src/usage_store.js");
    await ensureAccount(db, "users/anon-c/", 1);
    await debit(db, "users/anon-c/", SIGNUP_GRANT_UY, "mine", {}, 2);
    expect(await meteredMineGate(db, "users/anon-c/", 60, 3)).toBe("no-credit");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_mine.test.js`
Expected: FAIL — `meteredMineGate` is not exported.

- [ ] **Step 3: Add imports + the exported gate helper + writeBlocked to miner.js**

At the top of `miner.js` (with the other imports):

```javascript
import { gateDecision, claudeCostUY, asrCostUY } from "./usage.js";
import { ensureAccount, getBalanceUY, debit } from "./usage_store.js";
```

Add an exported helper (pure-ish, testable) near the other helpers:

```javascript
// Decide whether to mine this recording. too-long ignores balance; otherwise
// lazy-create the account (first touch grants 500) then check balance.
export async function meteredMineGate(db, scope, durationSec, now) {
  if (durationSec > 3 * 3600) return "too-long";
  if (!db) return "ok";                 // fail-open: no D1 binding
  try {
    const bal = await ensureAccount(db, scope, now);
    return gateDecision(bal, durationSec);
  } catch { return "ok"; }              // fail-open on D1 error
}
```

Add `writeBlocked` next to `writeEmpty` (mirror its R2 PUT shape):

```javascript
async function writeBlocked(audioKey, reason, env) {
  const body = JSON.stringify({ status: "blocked", reason });
  await apiPut(`articles/${adminArticlePath(audioKey).replace(/\.json$/, ".blocked")}`, body, env);
  // (use the same .blocked path the app reads: articles/<sub>/<stem>.blocked)
}
```

> NOTE for implementer: confirm the exact `.blocked` key matches `adminArticlePath(audioKey)` with the extension swapped to `.blocked` (mirror how `writeEmpty` derives `.empty`). Read `writeEmpty` (~L447) and copy its key-derivation verbatim, swapping the suffix.

- [ ] **Step 4: Wire the gate into `mineOneAudio`**

Immediately after the existing `.json`/`.empty` HEAD skip (~L499–502), before ASR:

```javascript
const scope = userPrefix(audioKey);
const durSec = audioDurationSeconds(audioKey);      // from filename, pre-ASR
const decision = await meteredMineGate(env.USAGE, scope, durSec, Date.now());
if (decision === "too-long") { await writeBlocked(audioKey, "too-long", env); return; }
if (decision === "no-credit") { await writeBlocked(audioKey, "no-credit", env); return; }
// If a stale .blocked exists from a prior no-credit run, drop it before mining:
try { await env.FILES.delete(`${userPrefix(audioKey)}articles/${stemOf(audioKey)}.blocked`); } catch {}
```

> NOTE: `stemOf`/the exact blocked-delete key must match `writeBlocked`'s key. Reuse the same derivation. Also ensure `mineOneAudio`'s pre-skip does NOT treat `.blocked` as terminal — only `.json`/`.empty` are terminal, so blocked recordings are re-visited (intended for no-credit retry). too-long re-block each run is cheap; optionally skip if `.blocked` already says too-long.

- [ ] **Step 5: Debit ASR after duration is known**

After `asrPoll` completes and `res.audio_info.duration` (ms) is available (~L246/277):

```javascript
const asrSec = (res.audio_info?.duration ?? durSec * 1000) / 1000;
try { if (env.USAGE) await debit(env.USAGE, scope, asrCostUY(asrSec), "asr", { asr_sec: Math.round(asrSec), stem: stemOf(audioKey) }, Date.now()); } catch {}
```

- [ ] **Step 6: Debit Claude after each mining call**

Immediately after each `writeLlmLog(...)` for the mine call (~L565/569), where `r.rawResp` holds usage:

```javascript
try {
  if (env.USAGE) {
    const u = r.rawResp?.usage || {};
    await debit(env.USAGE, scope, claudeCostUY(modelCfg.model, u.input_tokens, u.output_tokens),
      "mine", { model: modelCfg.model, in_tok: u.input_tokens, out_tok: u.output_tokens, stem: stemOf(audioKey), turn_id: turnId }, Date.now());
  }
} catch {}
```

- [ ] **Step 7: Run the gate test + full suite**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_mine.test.js && npm test`
Expected: gate test PASS (3); full suite green.

- [ ] **Step 8: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add src/miner.js test/usage_mine.test.js
git commit -m "feat(usage): meter mine path — balance gate, .blocked markers, ASR+Claude debit"
```

---

### Task 5: Wire the edit path (gate + edit-cap + debit) in `index.js`

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/index.js` (ArticleEditor `runTurn` ~L150–174 / `onMessage` ~L176–206; Claude log point `_makeLoggedCall` ~L241–248)
- Test: `~/code/jianshuo.dev/agent/test/usage_edit.test.js`

**Interfaces:**
- Consumes: `editGate`, `claudeCostUY` (usage.js); `ensureAccount`, `getBalanceUY`, `debit`, `editCount` (usage_store.js); ArticleEditor's `scope`, `articleKey`/`stem`, `this.env.USAGE`, the connection-send mechanism used for `{type:"error",message}`.
- Produces: ledger `spend` rows reason `edit`; `{type:"error",message}` to the client on `no-credit`/`limit`.

- [ ] **Step 1: Write the failing test (edit gate)**

```javascript
// test/usage_edit.test.js
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { fakeD1 } from "./fakes.js";
import { meteredEditGate } from "../src/index.js";   // extracted, see Step 3
import { ensureAccount, debit } from "../src/usage_store.js";
import { SIGNUP_GRANT_UY } from "../src/usage.js";

const SQL = readFileSync(fileURLToPath(new URL("../migrations/0001_usage.sql", import.meta.url)), "utf8");

describe("meteredEditGate", () => {
  it("ok for funded new user", async () => {
    const db = fakeD1(SQL);
    expect(await meteredEditGate(db, "users/anon-a/", "s1", 1)).toBe("ok");
  });
  it("no-credit when drained", async () => {
    const db = fakeD1(SQL);
    await ensureAccount(db, "users/anon-b/", 1);
    await debit(db, "users/anon-b/", SIGNUP_GRANT_UY, "edit", { stem: "s1" }, 2);
    expect(await meteredEditGate(db, "users/anon-b/", "s1", 3)).toBe("no-credit");
  });
  it("limit at 100 edits of same stem", async () => {
    const db = fakeD1(SQL);
    await ensureAccount(db, "users/anon-c/", 1);
    for (let i = 0; i < 100; i++) await debit(db, "users/anon-c/", 1, "edit", { stem: "s1" }, 10 + i);
    expect(await meteredEditGate(db, "users/anon-c/", "s1", 200)).toBe("limit");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_edit.test.js`
Expected: FAIL — `meteredEditGate` not exported.

- [ ] **Step 3: Add imports + exported edit-gate helper to index.js**

Top imports:

```javascript
import { editGate, claudeCostUY } from "./usage.js";
import { ensureAccount, getBalanceUY, debit, editCount } from "./usage_store.js";
```

Exported helper:

```javascript
export async function meteredEditGate(db, scope, stem, now) {
  if (!db) return "ok";                 // fail-open
  try {
    const bal = await ensureAccount(db, scope, now);
    const edits = await editCount(db, scope, stem);
    return editGate(bal, edits);
  } catch { return "ok"; }
}
```

- [ ] **Step 4: Enforce the gate before running an edit turn**

In `runTurn` (or at the top of `onMessage`'s instruct handling, ~L188 before `this._queue.submit`), after resolving `scope` + `stem`:

```javascript
const decision = await meteredEditGate(this.env.USAGE, scope, stem, Date.now());
if (decision === "no-credit") { this._send(connection, { type: "error", message: "算力不足，无法继续编辑" }); return; }
if (decision === "limit") { this._send(connection, { type: "error", message: "这篇已达编辑上限（100 次）" }); return; }
```

> NOTE: use the ArticleEditor's existing send mechanism (the same one used elsewhere to emit messages to the socket). Read `onMessage`/the WebSocket send usage and match it (`this._send` is illustrative — use the real method).

- [ ] **Step 5: Debit after each edit Claude call**

In `_makeLoggedCall` right after `writeLlmLog(...)` (~L248), where `r.json.usage` holds tokens:

```javascript
try {
  if (this.env.USAGE) {
    const u = r.json?.usage || {};
    await debit(this.env.USAGE, scope, claudeCostUY(model, u.input_tokens, u.output_tokens),
      "edit", { model, in_tok: u.input_tokens, out_tok: u.output_tokens, stem }, Date.now());
  }
} catch {}
```

> NOTE: `scope` and `stem` are in `_makeLoggedCall`'s closure args (see L156/234–237). Confirm names; reuse them.

- [ ] **Step 6: Run the edit test + full suite**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_edit.test.js && npm test`
Expected: edit test PASS (3); full suite green.

- [ ] **Step 7: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add src/index.js test/usage_edit.test.js
git commit -m "feat(usage): meter edit path — balance + 100-edit gate, per-edit debit"
```

---

### Task 6: Usage read/admin routes in `index.js`

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/index.js` (add routes in the `fetch` dispatch before the final 404 at ~L392)
- Test: `~/code/jianshuo.dev/agent/test/usage_routes.test.js`

**Interfaces:**
- Consumes: `resolveScope(token,env)` (existing, L404–414), `uyToSuanli`/`uyToYuan` (usage.js), store fns; admin check `tok === env.FILES_TOKEN` (pattern L366/377).
- Produces: `GET /agent/usage/balance`, `GET /agent/usage/ledger`, `POST /agent/usage/grant` (admin), `GET /agent/usage/admin/accounts` (admin). JSON via existing helper or `new Response(JSON.stringify(x),{headers:{"content-type":"application/json"}})`.

- [ ] **Step 1: Write the failing test (balance route handler)**

Extract the route logic into a tested function `handleUsageRoute(url, request, env)` returning a `Response|null`:

```javascript
// test/usage_routes.test.js
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { fakeD1 } from "./fakes.js";
import { handleUsageRoute } from "../src/index.js";

const SQL = readFileSync(fileURLToPath(new URL("../migrations/0001_usage.sql", import.meta.url)), "utf8");
function req(path, { method = "GET", token } = {}) {
  return new Request("https://jianshuo.dev" + path, { method, headers: token ? { Authorization: "Bearer " + token } : {} });
}

describe("usage routes", () => {
  it("balance route lazily creates account and returns ~500 算力", async () => {
    const env = { USAGE: fakeD1(SQL), SESSION_SECRET: "" }; // anon token path
    const r = await handleUsageRoute(new URL("https://jianshuo.dev/agent/usage/balance"), req("/agent/usage/balance", { token: "anon_unittesttoken_abcdefghijklmnop" }), env);
    expect(r.status).toBe(200);
    const body = await r.json();
    expect(Math.round(body.suanli)).toBe(500);
  });
  it("non-usage path returns null (delegates to normal dispatch)", async () => {
    const r = await handleUsageRoute(new URL("https://jianshuo.dev/agent/edit"), req("/agent/edit"), {});
    expect(r).toBeNull();
  });
  it("admin grant requires FILES_TOKEN", async () => {
    const env = { USAGE: fakeD1(SQL), FILES_TOKEN: "admintok" };
    const bad = await handleUsageRoute(new URL("https://jianshuo.dev/agent/usage/grant"), req("/agent/usage/grant", { method: "POST", token: "nope" }), env);
    expect(bad.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_routes.test.js`
Expected: FAIL — `handleUsageRoute` not exported.

- [ ] **Step 3: Implement `handleUsageRoute` and call it from `fetch`**

Add the exported handler:

```javascript
import { uyToSuanli, uyToYuan, suanliToUY } from "./usage.js";
import { ensureAccount, getLedger, grant, allAccounts } from "./usage_store.js";

const J = (x, status = 200) => new Response(JSON.stringify(x), { status, headers: { "content-type": "application/json" } });
const bearer = (req) => (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
const r1 = (n) => Math.round(n * 10) / 10;
const r2 = (n) => Math.round(n * 100) / 100;

export async function handleUsageRoute(url, request, env) {
  if (!url.pathname.startsWith("/agent/usage/")) return null;
  const tok = bearer(request);
  const isAdmin = env.FILES_TOKEN && tok === env.FILES_TOKEN;

  if (url.pathname === "/agent/usage/balance" && request.method === "GET") {
    const scope = await resolveScope(tok, env);
    if (!scope) return J({ error: "unauthorized" }, 401);
    if (!env.USAGE) return J({ suanli: 0, yuan: 0, granted_suanli: 0, spent_suanli: 0, degraded: true });
    await ensureAccount(env.USAGE, scope, Date.now());
    const a = await env.USAGE.prepare("SELECT balance_uy,granted_uy,spent_uy FROM account WHERE user_sub=?").bind(scope).first();
    return J({ suanli: r1(uyToSuanli(a.balance_uy)), yuan: r2(uyToYuan(a.balance_uy)),
      granted_suanli: r1(uyToSuanli(a.granted_uy)), spent_suanli: r1(uyToSuanli(a.spent_uy)) });
  }

  if (url.pathname === "/agent/usage/ledger" && request.method === "GET") {
    const scope = await resolveScope(tok, env);
    if (!scope) return J({ error: "unauthorized" }, 401);
    if (!env.USAGE) return J({ entries: [], degraded: true });
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "50", 10) || 50, 200);
    const rows = await getLedger(env.USAGE, scope, limit);
    return J({ entries: rows.map((e) => ({ ts: e.ts, kind: e.kind, reason: e.reason,
      suanli: r1(uyToSuanli(e.amount_uy)), yuan: r2(uyToYuan(e.amount_uy)),
      balance_suanli: r1(uyToSuanli(e.balance_uy)), detail: e.detail ? JSON.parse(e.detail) : null })) });
  }

  if (url.pathname === "/agent/usage/grant" && request.method === "POST") {
    if (!isAdmin) return J({ error: "unauthorized" }, 401);
    const b = await request.json().catch(() => ({}));
    if (!b.user_sub || typeof b.suanli !== "number") return J({ error: "bad-request" }, 400);
    await grant(env.USAGE, b.user_sub, suanliToUY(b.suanli), "campaign:" + (b.reason || "manual"), Date.now());
    return J({ ok: true });
  }

  if (url.pathname === "/agent/usage/admin/accounts" && request.method === "GET") {
    if (!isAdmin) return J({ error: "unauthorized" }, 401);
    const rows = await allAccounts(env.USAGE);
    return J({ accounts: rows.map((a) => ({ user_sub: a.user_sub,
      balance_suanli: r1(uyToSuanli(a.balance_uy)), granted_suanli: r1(uyToSuanli(a.granted_uy)),
      spent_suanli: r1(uyToSuanli(a.spent_uy)), spent_yuan: r2(uyToYuan(a.spent_uy)) })) });
  }
  return J({ error: "not-found" }, 404);
}
```

In the `fetch` dispatch, before the final 404 (~L392):

```javascript
{ const r = await handleUsageRoute(url, request, env); if (r) return r; }
```

- [ ] **Step 4: Run route test + full suite**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/usage_routes.test.js && npm test`
Expected: route test PASS (3); full suite green.

- [ ] **Step 5: Deploy the Worker and smoke-test live**

```bash
cd ~/code/jianshuo.dev/agent && npx wrangler deploy
curl -s https://jianshuo.dev/agent/usage/balance -H "Authorization: Bearer $(grep '^FILES_TOKEN' ~/code/.env | cut -d= -f2)" | head -c 300
```
Expected: deploy succeeds; curl returns a JSON balance object (admin token resolves to an admin scope or 401 — verify with a real anon token from the app if needed).

- [ ] **Step 6: Commit**

```bash
cd ~/code/jianshuo.dev/agent
git add src/index.js test/usage_routes.test.js
git commit -m "feat(usage): /agent/usage balance|ledger|grant|admin routes"
```

---

### Task 7: Admin transparency viewer (`usage.html`)

**Files:**
- Create: `voicedrop/admin/usage.html` (same dir as `mine.html` — locate with `find ~/code/jianshuo.dev -name mine.html`)

- [ ] **Step 1: Locate the admin dir**

Run: `find ~/code/jianshuo.dev -name mine.html`
Expected: a path like `~/code/jianshuo.dev/voicedrop/admin/mine.html`. Use that directory.

- [ ] **Step 2: Create `usage.html`**

```html
<!doctype html><meta charset="utf-8"><title>VoiceDrop · 算力账本</title>
<style>body{font:14px/1.5 -apple-system,sans-serif;max-width:860px;margin:2rem auto;padding:0 1rem;color:#222}
table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #eee;padding:6px 8px;text-align:right}
th:first-child,td:first-child{text-align:left;font-family:ui-monospace,monospace}input{padding:6px;width:340px}</style>
<h1>算力账本 · 全量账户</h1>
<p><input id="t" placeholder="admin token (FILES_TOKEN)"> <button onclick="go()">加载</button></p>
<p id="sum"></p>
<table><thead><tr><th>账户</th><th>余额(算力)</th><th>累计获得</th><th>累计消费</th><th>消费(¥)</th></tr></thead><tbody id="b"></tbody></table>
<script>
async function go(){
  const t=document.getElementById('t').value.trim();
  const r=await fetch('https://jianshuo.dev/agent/usage/admin/accounts',{headers:{Authorization:'Bearer '+t}});
  if(!r.ok){document.getElementById('b').innerHTML='<tr><td>加载失败 '+r.status+'</td></tr>';return;}
  const {accounts}=await r.json();
  let spent=0;
  document.getElementById('b').innerHTML=accounts.map(a=>{spent+=a.spent_yuan;
    return `<tr><td>${a.user_sub.replace('users/anon-','').slice(0,6).toUpperCase()}</td><td>${a.balance_suanli}</td><td>${a.granted_suanli}</td><td>${a.spent_suanli}</td><td>${a.spent_yuan}</td></tr>`}).join('');
  document.getElementById('sum').textContent=`共 ${accounts.length} 账户 · 总消费 ¥${spent.toFixed(2)}`;
}
</script>
```

- [ ] **Step 3: Deploy Pages + verify**

```bash
cd ~/code/jianshuo.dev && npx wrangler pages deploy . --project-name jianshuo-dev
```
Then open `https://jianshuo.dev/voicedrop/admin/usage.html`, paste the admin token, confirm the accounts table renders.

- [ ] **Step 4: Commit**

```bash
cd ~/code/jianshuo.dev
git add voicedrop/admin/usage.html
git commit -m "feat(usage): admin 算力账本 viewer"
```

---

### Task 8: iOS — balance view + settings entry

**Files:**
- Create: `~/code/voicedrop/VoiceDropApp/UsageView.swift`
- Modify: `~/code/voicedrop/VoiceDropApp/AccountView.swift:142` (add a row above "查看全部文章")

**Interfaces:**
- Consumes: `AuthStore.shared.bearer`, `URLRequest.setBearer` (Networking.swift), `URLResponse.isOK`.
- Produces: `UsageView` (SwiftUI) calling `GET https://jianshuo.dev/agent/usage/balance` and `…/ledger`.

- [ ] **Step 1: Create `UsageView.swift`**

```swift
import SwiftUI

private struct Balance: Decodable { let suanli: Double; let spent_suanli: Double }
private struct LedgerResp: Decodable { let entries: [Entry] }
private struct Entry: Decodable, Identifiable {
    var id: Int { ts }
    let ts: Int; let kind: String; let reason: String; let suanli: Double; let balance_suanli: Double
}

struct UsageView: View {
    @State private var balance: Double = 0
    @State private var spent: Double = 0
    @State private var entries: [Entry] = []
    private let base = URL(string: "https://jianshuo.dev/agent/usage")!
    private var token: String { AuthStore.shared.bearer }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(balance.rounded())) 算力").font(.system(size: 34, weight: .bold))
                    Text("累计消费 \(Int(spent.rounded())) 算力").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            } footer: {
                Text("算力是 VoiceDrop 送你的免费额度，无现金价值、不可提现。处理录音和语音修改会按真实成本消耗算力。")
            }
            Section("明细") {
                ForEach(entries) { e in
                    HStack {
                        Text(label(e)).font(.subheadline)
                        Spacer()
                        Text("\(e.kind == "grant" ? "+" : "−")\(fmt(e.suanli)) 算力")
                            .foregroundStyle(e.kind == "grant" ? .green : .primary)
                    }
                }
                if entries.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("算力")
        .task { await load() }
    }

    private func label(_ e: Entry) -> String {
        switch e.reason {
        case "signup": return "新用户赠送"
        case "asr": return "语音转写"
        case "mine": return "挖文章"
        case "edit": return "语音修改"
        default: return e.reason.hasPrefix("campaign:") ? "活动赠送" : e.reason
        }
    }
    private func fmt(_ s: Double) -> String { s < 10 ? String(format: "%.1f", s) : String(Int(s.rounded())) }

    private func load() async {
        async let b: Balance? = get("balance")
        async let l: LedgerResp? = get("ledger?limit=50")
        if let b = await b { balance = b.suanli; spent = b.spent_suanli }
        if let l = await l { entries = l.entries }
    }
    private func get<T: Decodable>(_ path: String) async -> T? {
        var req = URLRequest(url: base.appending(path: path)); req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
```

> NOTE: `base.appending(path:)` URL-encodes `?` — if `ledger?limit=50` breaks, build the ledger URL with `URL(string: "https://jianshuo.dev/agent/usage/ledger?limit=50")!` directly.

- [ ] **Step 2: Add the settings entry in `AccountView.swift`**

Above the "查看全部文章" button (~L142), inside the same section:

```swift
NavigationLink { UsageView() } label: {
    HStack { Text("算力余额"); Spacer(); Text("查看明细").foregroundStyle(.secondary) }
}
```

- [ ] **Step 3: Regenerate the Xcode project (new Swift file)**

```bash
cd ~/code/voicedrop && xcodegen generate
```
Expected: `UsageView.swift` is picked up (it's in `VoiceDropApp/`, auto-included).

- [ ] **Step 4: Build to verify it compiles**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/UsageView.swift VoiceDropApp/AccountView.swift project.yml VoiceDrop.xcodeproj
git commit -m "feat(ios): 算力余额 view + settings entry"
```

---

### Task 9: iOS — `.blocked` recording state + badge

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/Library.swift` (Recording struct ~L120–169; `load()` marker detection ~L226–227)
- Modify: `~/code/voicedrop/VoiceDropApp/LibraryView.swift:277–297` (`statusBadge`)

**Interfaces:**
- Consumes: list API names; `download/<key>` for the blocked marker's reason.
- Produces: `Recording.blockReason: String?` (`"no-credit"|"too-long"`); two new badges.

- [ ] **Step 1: Add `blockReason` to the Recording model + detect the marker**

In `Library.swift`, add to the `Recording` struct:

```swift
var blockReason: String? = nil   // "no-credit" | "too-long"; nil = not blocked
```

In `load()` where `.json`/`.empty` are detected (~L226–227), add:

```swift
let blocked = names.contains("articles/\(stem).blocked")
```
…and when building the `Recording`, if `blocked` and not `hasArticles`/`isEmpty`, fetch the reason (rare path):

```swift
var reason: String? = nil
if blocked {
    reason = await fetchBlockReason(stem)   // see Step 2
}
// pass blockReason: reason into the Recording initializer
```

- [ ] **Step 2: Add `fetchBlockReason` helper in `LibraryStore`**

```swift
private func fetchBlockReason(_ stem: String) async -> String? {
    var req = URLRequest(url: base.appending(path: "download/articles/\(stem).blocked"))
    req.setBearer(token)
    guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "no-credit" }
    return obj["reason"] as? String ?? "no-credit"
}
```

> NOTE: `download/<key>` is scoped to the caller (Files API). The `.blocked` key is under the user's own scope, so the bearer token resolves it. Confirm the `download/` route prefixes with the user scope automatically (it does — `list` returns scope-relative `articles/<stem>.blocked`).

- [ ] **Step 3: Render the two badges in `statusBadge`**

In `LibraryView.swift:277`, before the default `待处理` branch:

```swift
if let r = rec.blockReason {
    return badge(Theme.warn, r == "too-long" ? "录音过长" : "余额不足")
}
```

> NOTE: match the existing `badge(_:_:)` helper signature used by the other branches (color, text). If there's no `Theme.warn`, reuse the same red used for delete / `Color(hex:"C0392B")`.

- [ ] **Step 4: Build to verify**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/Library.swift VoiceDropApp/LibraryView.swift
git commit -m "feat(ios): 余额不足 / 录音过长 recording badges from .blocked marker"
```

---

### Task 10: iOS — surface edit-blocked error

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/AgentSession.swift:142–166` (the `case "error"` already maps `{type:"error",message}` → `error`/`.error` state — verify it surfaces the server message)
- Verify: `~/code/voicedrop/VoiceDropApp/RecordingDetailView.swift:707–724` (`replyBubble`) shows the message with the warning icon

**Interfaces:**
- Consumes: `{type:"error",message}` emitted by Task 5; existing `AgentSession.error`, `onReply`, `AgentReply(ok:false)`.

- [ ] **Step 1: Verify the error message reaches the reply bubble**

Read `AgentSession.swift:142–166`. The `case "error"` sets `error = obj["message"]` and `state = .error`. Ensure the message is also delivered to `onReply` as a non-ok reply so `replyBubble` renders it. If `onReply` is not called on error, add:

```swift
case "error":
    let msg = (obj["message"] as? String) ?? "出错了"
    onReply?(msg, false)          // shows the red warning bubble (RecordingDetailView:707)
    if let id { resolve(id) }
    state = .error
```

- [ ] **Step 2: Build to verify**

```bash
cd ~/code/voicedrop && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build -quiet
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (real device/sim against deployed worker)**

Drain a test account's balance (admin `POST /agent/usage/grant` cannot subtract; instead test by editing until 0, or temporarily lower `SIGNUP_GRANT_UY` in a local deploy). Trigger a voice edit → confirm the bubble shows "算力不足，无法继续编辑". Do 101 edits on one article → confirm "这篇已达编辑上限（100 次）".

- [ ] **Step 4: Commit**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/AgentSession.swift
git commit -m "feat(ios): surface 算力不足 / 编辑上限 errors in the edit bubble"
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:
- §1 落点(agent worker + USAGE binding) → Task 2. §2 计价单一真源 → Task 1. §3 D1 两表 → Task 2/3. §4 发放(signup 500 + campaign) → Task 3 (`ensureAccount`/`grant`) + Task 6 (grant route). §5 记账(mine/asr/edit debit) → Tasks 4/5. §6 余额闸 + `.blocked` → Tasks 4/5 + Task 9. §7 防滥用(3h/100) → Task 1 (`gateDecision`/`editGate`) + Tasks 4/5. §8 读接口 + 透明 → Task 6 + Task 7. §9 iOS → Tasks 8/9/10. §10 测试 → tests in Tasks 1/3/4/5/6. §11 部署顺序 → deploy steps in Tasks 6/7/8. §12 不做 → respected (no money/refund/payout routes). §13 参数 → Task 1 constants.
- **Fail-open**: covered in `meteredMineGate`/`meteredEditGate`/routes (`!env.USAGE` → degraded/ok).

**Placeholder scan** — the `database_id: "PLACEHOLDER_FROM_CREATE"` in Task 2 is filled by the `wrangler d1 create` step (Step 3), not a plan gap. `NOTE` blocks point the implementer at exact existing code to copy verbatim (key derivation, send method, closure var names) rather than inventing names — these are deliberate "match the real symbol" instructions, not TODOs.

**Type consistency** — `claudeCostUY(model,inTok,outTok)`, `asrCostUY(seconds)`, `debit(db,userSub,amountUY,reason,detail,now)`, `editCount(db,userSub,stem)`, `meteredMineGate(db,scope,durationSec,now)`, `meteredEditGate(db,scope,stem,now)`, `handleUsageRoute(url,request,env)` are used identically wherever they appear across tasks. Ledger `reason` values (`signup`/`campaign:*`/`mine`/`asr`/`edit`) and `detail.stem` are consistent between writer (Tasks 4/5) and reader (`editCount`, iOS labels).

**Known follow-ups (out of scope, noted):** the `.blocked` no-credit auto-retry (re-mine after a grant) relies on the miner re-visiting blocked recordings each run (Task 4 Step 4 NOTE) — verify during execution that `.blocked` is not treated as terminal. The grant route can optionally kick a mine afterward (not implemented; cheap to add later).

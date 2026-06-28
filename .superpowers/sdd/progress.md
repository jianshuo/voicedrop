# VoiceDrop 算力计费 — SDD progress ledger

Plan: docs/superpowers/plans/2026-06-27-voicedrop-usage-billing.md
Spec: docs/superpowers/specs/2026-06-27-voicedrop-usage-billing-design.md
Branches: voicedrop-usage in BOTH repos. Deploy/push DEFERRED to user.
Bases: jianshuo.dev=1103305 ; voicedrop=bee56a7 (docs commit on b8ec410)
Repo per task: T1-T7 = jianshuo.dev/agent ; T8-T10 = voicedrop/VoiceDropApp + admin html (T7)

## Tasks
- [x] T1 usage.js pricing/gate pure functions   (jianshuo.dev)
- [x] T2 D1 migration + USAGE binding + sqlite dep (jianshuo.dev)
- [x] T3 usage_store.js + fakeD1 shim            (jianshuo.dev)
- [x] T4 miner.js wiring (gate/.blocked/debit)   (jianshuo.dev)
- [x] T5 index.js edit path wiring               (jianshuo.dev)
- [x] T6 /agent/usage routes                   (jianshuo.dev) [296abde]
- [x] T7 admin usage.html  [72474d0]              (jianshuo.dev)
- [x] T8 iOS UsageView + settings entry          (voicedrop) [9a130dc]
- [x] T9 iOS .blocked badges                     (voicedrop) [b35f55b]
- [x] T10 iOS edit-blocked error                 (voicedrop) [c4c7aae]

## Completed
(none yet)

- T1: complete (commit 520a721, review clean Approved; 7/7 focused + 175/175 full, no regression)
- T2: complete (commit b79278c, review clean Approved; D1 voicedrop-usage id=317b7cd5-e926-49f0-a6c9-497e4740aea8 created+migrated; 175 full green; commit clean 4 files, no WIP leak)
- T3: complete (commit 63d380b + fix 7ef4c83, re-review Approved; 5/5 focused + 180/180 full).
  Important FIXED: debit/grant now atomic via db.batch() + fakeD1 batch() shim.
  Minors -> FINAL review triage:
    (M1) debit() has no ensureAccount guard -> orphaned ledger row if called pre-account (callers do ensure first; cheap 1-line defense).
    (M2) fakeD1.batch is sync while real D1 batch is async (await works; parity gap only).
    (M3) grant() does redundant SELECT after ensureAccount (wasted round-trip, single-writer).
    (M4) import Database mid-file in fakes.js (style).
    (M5) editCount dead ':0' branch (COUNT(*) never null).
- T4: complete (962f0df + route fix f7ee83a, re-review Approved; usage_mine 3/3, articles-api 25/25, full 185/185).
  Critical FIXED: added PUT articles/.../blocked route in functions/files/api/[[path]].js + reap .blocked on DELETE.
  3-way key consistency PROVEN: route writes users/<sub>/articles/<stem>.blocked = miner stale-delete = list/iOS detection.
  Extra (kept): text-path (mineOneText) Claude debit too — correct & best-effort.
  !! DEPLOY DEP: apiPut hits ORIGIN=https://jianshuo.dev (prod Pages). blocked route only works LIVE after Pages deploy (deferred to user).
  Minors -> FINAL: (M6) ASR duration unit assumed ms — add clarifying comment; (M7) pre-existing DELETE comment indent.
- T5: complete (commit 68469b9, review Approved; usage_edit 3/3, full 196/196).
  Gate precedes Claude call (no spend on reject); queue marks gate-reject terminal (no retry loop);
  error {type:"error",id,message} reaches client with exact strings; debit best-effort.
  Minor -> FINAL: (M8) dead import getBalanceUY in index.js (and likely also miner.js — check both in final cleanup).

## ⚠️ CONCURRENCY (2026-06-28): foreign commits landing on voicedrop-usage (shared checkout)
Other live Claude sessions commit onto the currently-checked-out branch (= voicedrop-usage).
USER ACTION: closing the other sessions; resume only after branch tip stops moving.

### jianshuo.dev billing commits (MINE — the only ones to merge/cherry-pick):
  520a721 T1 usage.js
  b79278c T2 D1 migration+binding
  63d380b T3 usage_store
  7ef4c83 T3 fix (atomic batch)
  962f0df T4 miner metering
  f7ee83a T4 fix (blocked route)
  68469b9 T5 edit metering
  296abde T6 usage routes   <-- IMPLEMENTED, REVIEW STILL PENDING
### jianshuo.dev FOREIGN commits on this branch (NOT mine, exclude from billing merge):
  6d87ece feat(agent): miner auto-shares to VD社区   (touched miner.js — additive, no conflict)
  4540b0d feat(voicedrop): 分享卡片 meta 分段感知       (functions/voicedrop/[token].js)
### voicedrop repo billing commits (MINE):
  bee56a7 docs(usage): spec + plan

## RESUME POINT: review Task 6 (review 296abde alone via 296abde^..296abde to skip foreign diff), then Task 7-10.
- FOREIGN on voicedrop branch too: da81d07 docs(state) - exclude from billing.
- Sessions closed; both tips stable. Resuming: review T6 (296abde^..296abde isolates it).
- T6: complete (commit 296abde, isolated review Approved; admin gating airtight, scope isolation safe, 3/3 + 205/205).
  Minors -> FINAL: (M9) limit=0 coerces to 50; (M10) thin route test coverage (only 3 per brief); (M11) no timing-safe FILES_TOKEN compare (negligible); (M12) grant accepts negative suanli (admin-only; maybe intended as correction).
- T7 starting: create voicedrop/admin/usage.html in jianshuo.dev. DEPLOY (Pages) SKIPPED — deferred to user.
- T7: complete (commit 72474d0, review Approved; endpoint+auth+fields all correct, NOT deployed). jianshuo.dev side (T1-T7) DONE.
- voicedrop billing base for iOS tasks: da81d07 (foreign docs on top of my bee56a7).
- T8: complete (commit 9a130dc, review Approved; BUILD SUCCEEDED; Decodable shapes exact, literal-URL workaround, no-cash-value footer, graceful failure).
  Minors -> FINAL: (M13) Entry.id=ts may collide same-second in ForEach; (M14) inline padding constants in AccountView row.
- T9: complete (commit b35f55b, review Approved; BUILD SUCCEEDED; precedence .json/.empty over .blocked airtight in both data+view, fetch gated to blocked rows only).
  FOLLOW-UP (reviewer Important but said "ship it / correctness unaffected" -> controller deferred to FINAL):
    (M15) fetchBlockReason serial-await per blocked recording in load() loop; rare (0-1 blocked typical); TaskGroup parallel fan-out is the follow-on fix.
    (M16) fetchBlockReason uses JSONSerialization vs project's Codable convention (style).
- T10: complete (commit c4c7aae, review Approved; error msg now reaches replyBubble, queue resolve+state preserved). ALL 10 TASKS DONE.

## FINAL whole-feature review (opus, 2026-06-28): Ready to merge = YES. 0 Critical.
Traced end-to-end: money integer-微元 never-undercharge; mine→blocked→iOS key agrees 4 ways; edit→gate→error→bubble terminal; admin gating sound; debit/grant atomic; fail-open on hot paths; iOS Decodable matches routes.
Important #1 (edit-cap counts Claude calls not user edits — spec §7 SQL faithful but message "100次" overstates; balance dominates) -> USER DECISION pending.
Important #2 (ensureAccount NOT atomic + first-touch race) -> FIXING NOW.
Fix wave (jianshuo.dev): ensureAccount atomicity+race, M8 dead import, M6 ASR ms clamp/comment, usage routes fail-open try/catch.
won't-fix (per opus triage): M2,M3,M5,M7,M9,M11,M12,M14. fix-later: M1,M4,M10,M13,M15,M16 + 3h-cap-needs-filename-duration(Minor).

## DONE — all 10 tasks + hardening complete & reviewed (2026-06-28).
Final fix wave 520b026 re-reviewed Approved (ensureAccount atomic+race-safe, dead import, ASR clamp, routes fail-open).
Remaining: (a) USER DECISION on edit-cap semantics (Important #1); (b) deploy (Pages + Worker) deferred to user; (c) merge billing SHAs (interleaved with foreign commits).
### FINAL billing SHA list (only these merge):
 jianshuo.dev: 520a721 b79278c 63d380b 7ef4c83 962f0df f7ee83a 68469b9 296abde 72474d0 520b026
   FOREIGN (exclude): 6d87ece, 4540b0d
 voicedrop: bee56a7(docs) 9a130dc b35f55b c4c7aae
   FOREIGN (exclude): da81d07

## edit-cap fix: 4f0a1bc — editCount now COUNT(DISTINCT turn_id) (real edits, not API calls); detail carries turn_id; tests rewritten to prove turns-vs-rows. 9 focused + 206 full green. (formal re-review skipped per user "go".)
### FINAL jianshuo.dev billing SHAs (append 520b026, 4f0a1bc):
 520a721 b79278c 63d380b 7ef4c83 962f0df f7ee83a 68469b9 296abde 72474d0 520b026 4f0a1bc
 FOREIGN exclude: 6d87ece, 4540b0d
### voicedrop billing SHAs: bee56a7(docs) 9a130dc b35f55b c4c7aae  | FOREIGN exclude: da81d07
## STATUS: implementation COMPLETE. Pending USER: deploy (Worker+Pages), merge billing SHAs, push iOS->TestFlight.

## SHIPPED (2026-06-28):
- jianshuo.dev: merged voicedrop-usage -> main (FF, 4f0a1bc), PUSHED origin. Worker deployed (wrangler, USAGE D1 binding live). Pages deployed (from clean tmp worktree; .assetsignore must exist). Feature branch deleted.
  LIVE-verified: /agent/usage/admin/accounts -> {"accounts":[]}; admin usage.html 200; balance no-token 401.
  Fixed deploy gotcha: foreign session had deleted .assetsignore (restored); .claude/worktrees/*/node_modules breaks `pages deploy .` -> deploy from clean `git worktree add --detach`.
- voicedrop: STATE.md updated (algorithm 算力计费 section). Rebased my 6 commits onto origin share-extension work (clean, no overlap), PUSHED main (c24bf7b). Feature branch deleted.
- !! iOS TestFlight build FAILS at fastlane `match` — Share Extension (EXT_BUNDLE_ID, from the share-extension session already on main) has NO provisioning profile in CI (readonly). NOT a billing issue (billing code never reached compile; steps 1-4 pass, dies at match). FIX (share-extension owner's loose end): run `fastlane match appstore` non-readonly to create the extension's appstore profile. Billing iOS code compiles locally (BUILD SUCCEEDED every task).

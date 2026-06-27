# Voice-edit durable queue — SDD progress ledger

Plan: docs/superpowers/plans/2026-06-27-voice-edit-durable-queue.md
Phase A repo+worktree: ~/code/jianshuo.dev/.claude/worktrees/voice-edit-durable-queue (branch voice-edit-durable-queue, base b856856)
Phase B repo+worktree: ~/code/voicedrop/.claude/worktrees/voice-edit-durable-queue (branch worktree-voice-edit-durable-queue)
Deploy/push: DEFERRED to user (active WIP in both repos; outward-facing).
BASELINE FIX (2026-06-27): Phase B branch was initially cut from stale origin/main; REBASED onto local main 2dca5f4 (3 unpushed commits incl. Networking setBearer). Branch now merges cleanly into local main. New Phase B SHAs: B1=dbccc4d, B2=55092eb (uses req.setBearer, not inline). Phase A is a separate repo (jianshuo.dev) — unaffected, SHAs unchanged.

## Tasks
- [x] A1 queue.js durable queue module
- [x] A2 write_article stamps lastEditId
- [x] A3 edit-turn.js runEditTurn (HARDENED: self-idempotency guard — verified present + tested)
- [x] A4 ArticleEditor DO wiring  (Phase A code-complete; A5 deploy deferred to user)
- [x] B1 EditQueueStore.swift
- [x] B2 AgentSession.swift rewrite
- [x] B3 RecordingDetailView onDisappear (verify-only — no code change needed; build green, no removed-symbol refs, onDisappear→disconnect now preserves queue)

## FINAL whole-branch reviews (2026-06-27): BOTH "Ready to merge: Yes" — 0 Critical, 0 Important.
Phase A (opus): exactly-once holds end-to-end; sql([...]) + lastEditId-through-writeArticleDoc verified against real source; backward-compat strictly additive. Prior Minors (A2/A3/A4) confirmed addressed in f191648.
Phase B (sonnet): all 5 §6 items implemented; reconnect double-send safe (server dedups by id); builds clean.

### Follow-up Minors (non-blocking — for a future pass, user's call):
PHASE A:
- runTurn inserts a history row on ERROR too (baseline inserted only on success) → a failed edit becomes replay context. 1-line guard: skip insert when res.hadError.
- _queue passes a `schedule` injection that ArticleQueue never calls (scheduling lives in onMessage/onStart) — dead wiring; remove for clarity.
- schedule(0,"drainQueue") not deduped via getSchedules (spec §3 mentions it); safe due to _draining guard; align code or spec note.
- no GC of done/error queue rows (grows per article) — fine at personal scale.
PHASE B:
- reconcile() calls persist()+state per item (batch once); silently drops server-`error` items with no UI signal (set self.error first); stem="" guard if enqueue before connect; reconnect() [weak self] (pre-existing); EditQueueStore.save silent-encode (theoretical).

## Minor findings (for final review triage)
- A1: best-effort loadDoc → narrow double-apply window (crash after write+stamp, then transient read blip on replay) UNLESS runEditTurn (A3) re-checks lastEditId. RESOLUTION: A3 hardened to re-check lastEditId at the top of runEditTurn (plan updated). Verify closed after A3.

- A2 (Minor): no negative-path test that absent editId → no lastEditId stamp. Cheap; protects the backward-compat Global Constraint. Final review: add `omits lastEditId when ctx.editId is absent` to tools.test.js (or fold into a Minor cleanup wave).

## Completed
- B2: complete (commit 55092eb, review clean Approved; BUILD SUCCEEDED on rebased base; setBearer used; 5/5 protocol+durability constraints verified). Key ⚠️ resolved: client double-sends on reconnect is SAFE (server dedups by id). Minors→final: (1) reconcile batches persist+state once; (2) reconnect [weak self] (pre-existing); (3) reconcile silently drops server-error items (no UI signal); (4) stem="" guard if enqueue before connect.
- B3: complete (verify-only, no commit; build green, no removed-symbol refs, onDisappear semantics correct).
- B1: complete (commit 8e6ea35, review clean Approved; BUILD SUCCEEDED). Minor→final: silent encode-failure path in save() (theoretical only for two Strings).
- A1: complete (commits fadfe43..1365aaf, review clean; queue 9/9, full suite 96/96 pristine)
- A2: complete (commit 5723c1a, review clean Approved; tools 18/18, full suite 97/97 pristine; 2 ⚠️ resolved by controller: fakeFetch import pre-exists; writeArticleDoc {...rest} preserves lastEditId — verified in article-store.js)
- A3: complete (commit 28e8563, review clean Approved; edit-turn 3/3, full suite 100/100 pristine; self-idempotency guard verified present+tested). Minors→final: missing-doc test could assert hadError+article:null; idempotency test could assert reply==="".
- A4: complete (commit 6f11d30, review clean Approved; full suite 100/100, node --check src/index.js OK, _busy 0 refs; backward-compat verified). Minors→final cleanup wave: (1) drop dead import resolveArticles (index.js:22); (2) drop dead import runAgentLoop (index.js:18); (3) append .catch(()=>{}) to onConnect snapshot IIFE.

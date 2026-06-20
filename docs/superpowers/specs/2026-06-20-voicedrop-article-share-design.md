# VoiceDrop — share a mined article via a public jianshuo.dev link

Date: 2026-06-20

Add a Share button to a mined article in the app, backed by an HMAC-signed public
preview page under `jianshuo.dev/voicedrop/<token>`. Also fix manual long-press
copy to grab the whole article (title + body), not one paragraph.

## Security model

The article JSON lives in the user's private R2 space at
`users/<sub>/articles/<stem>.json`. A share link is an **HMAC-signed token** over
that key — unforgeable and unguessable, so only links the user explicitly creates
exist. The public page serves **only** validly-signed `users/*/articles/*.json`
keys; never audio, the file list, or any other object. Deleting the recording
(which deletes the JSON) makes the link 404 — the built-in "unshare". No database,
no revocation table for v1.

## Backend — jianshuo.dev (Cloudflare Pages Functions + R2)

### 1. Authenticated share-mint endpoint
`GET /files/api/share/<name>` in `functions/files/api/[[path]].js`, behind the
existing per-user auth (anon/session token). It:
- resolves the user's full key via the existing `keyFor(name)` (→ `users/<sub>/articles/<stem>.json`),
- signs it: `token = b64url(payload) + "." + HMAC_b64url("share:" + payload, SESSION_SECRET)`,
  where `payload = b64url(fullKey)`. The `share:` domain-separator prevents any
  confusion with session JWTs.
- returns `{ url: "https://jianshuo.dev/voicedrop/<token>" }`.

Only `.json` article keys are shareable; reject anything not matching
`users/<sub>/articles/*.json`.

### 2. Public preview page
New `functions/voicedrop/[token].js` (single dynamic segment so it never shadows
the static `/voicedrop/` landing or `/voicedrop/privacy/`):
- Split `<token>` into `payload.sig`; recompute HMAC with `SESSION_SECRET`; if it
  doesn't verify (e.g. the segment is `privacy`), `return context.next()` to fall
  through to the static assets.
- Valid → decode the key, guard it matches `users/*/articles/*.json`, `env.FILES.get(key)`.
  404 (a small styled page) if missing.
- Render a clean, **light-theme**, mobile-friendly HTML page: each article's title
  (h1/h2) + body (markdown → HTML, minimal converter for headings/paragraphs/bold/
  lists), pangu spacing already baked into the stored text. Small footer crediting
  VoiceDrop. `Cache-Control: public, max-age=300`.

`SESSION_SECRET` is an existing Pages secret available to all functions.

## App — RecordingDetailView + Library.swift

### 3. LibraryStore.shareURL(_:)
`func shareURL(_ rec: Recording) async -> URL?` → `GET /files/api/share/<stem>.json`
with the user token → parse `{ url }`. Returns nil on failure.

### 4. Share button
On the article pane in `RecordingDetailView`, a share icon
(`square.and.arrow.up`). On tap: fetch `shareURL`, then present the iOS share
sheet (a small `UIViewControllerRepresentable` wrapping `UIActivityViewController`)
seeded with the URL. Show a brief progress state while fetching; on failure show a
inline message. The link is per-recording (covers all its articles).

### 5. Copy-all on long-press
Replace the per-paragraph `Text(.init(para))` loop with a **single selectable
`Text`** built from one `AttributedString(markdown:)` over
`"## <title>\n\n<body>"` using `interpretedSyntax: .inlineOnlyPreservingWhitespace`
(preserves paragraph breaks). Long-press → Select All → Copy now yields the whole
article including the title. Keep the existing one-tap copy button (already copies
title+body).

## Deploy

- jianshuo.dev: deploy via the project's Cloudflare Pages flow (wrangler pages
  deploy / git push, per the repo's convention).
- App: commit to the worktree branch → merge to main → push → TestFlight CI.

## Verification

- `curl` the share endpoint with a real anon token → returns a `jianshuo.dev/voicedrop/<token>` URL.
- Open that URL in a browser → renders the article; tampering one char of the
  token → falls through / 404.
- `/voicedrop/` and `/voicedrop/privacy/` still serve their static pages.
- App builds; Share button opens the sheet with the link; long-press copies the full article.

## Out of scope (v1)

- Revocation UI (delete-the-recording is the unshare).
- Per-article links (whole-recording page chosen).
- Analytics / view counts.

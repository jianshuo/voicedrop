# Task 2 Report: R2 content tools — list / read / write article

## What changed

- `src/tools.js`: Appended `badStem()` guard and three `register()` calls:
  - `list_articles` — lists `.json` keys under `scope/articles/`, skips `.empty`/`.srt`, sorts newest-first, caps at 30.
  - `read_article` — reads a stem, validates with `badStem()`, returns `{transcript, articles}`.
  - `write_article` — writes back to the DO's own `articleKey`, preserves `wechatMediaId` by index, rejects empty arrays.
- `test/tools.test.js`: Appended 6 new tests across `list_articles`, `read_article`, and `write_article` describes.

## npm test output

```
 ✓ test/tools.test.js (8 tests) 2ms
 Test Files  1 passed (1)
      Tests  8 passed (8)
```

8 tests total (2 from Task 1 + 6 from Task 2). All green.

## Commit SHA

`0d46cbd` — "feat: list_articles / read_article / write_article R2 tools"

## Concerns

None. Implementation follows the plan exactly; pre-existing uncommitted files (`functions/files/api/[[path]].js`, `.wrangler/state/`) were not touched.

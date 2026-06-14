# CLAUDE.md

Guidance for working in this repo. See `PLAN.md` for the full design/roadmap and
`README.md` for user-facing usage.

## What this is

A native macOS app (in progress) that backs up the user's AO3 bookmarks as `.epub` files
with a dark, liquid-glass, snappy gallery and full local filtering. **M0** (core spike) and
**M1** (core sync + store) are done: a runnable Swift package that pages through bookmarks,
ingests every card (work / external / series) into a GRDB/SQLite store with FTS5, expands
bookmarked series into their member works, and runs a resumable, rate-limited EPUB download
queue — all before any SwiftUI is written.

## Build / test / run

```sh
swift build                 # build library + CLI
swift run selftest          # headless parser + Store checks against real captured HTML
swift run ao3archiver        # bounded sync: paginate → ingest → expand series → download
```

Auth + config is via environment variables (see README): `AO3_USERNAME`,
`AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`, `AO3_MIN_INTERVAL`, `AO3_USER_AGENT`,
`AO3_LIST_PATH`, and the M1 sync bounds `AO3_MAX_PAGES`, `AO3_MAX_DOWNLOADS`,
`AO3_EXPAND_SERIES`. Bounds default **low** (2 pages / 3 downloads) — never crawl all ~91
pages by accident; politeness is a hard requirement.

### Testing note

Full **Xcode is installed**, so `swift test` runs the swift-testing suite in
`Tests/AO3KitTests/` (18 tests, 3 suites — parser, downloader, Store). `swift run selftest`
is the equivalent **framework-free** runner (same assertions against the same fixtures) and
also works under Command-Line-Tools-only toolchains, where `swift test` fails with "no such
module 'Testing'". Keep the two in sync when changing the parser or store — both pin to the
fixtures in `Tests/AO3KitTests/Fixtures/`.

## Layout

```
Sources/AO3Kit/        reusable core the SwiftUI app will sit on
  AO3Client.swift      ONLY networked component: rate limiter, 429/5xx backoff, cookie, UA
  RateLimiter.swift    single-flight token-slot limiter
  BlurbParser.swift    listing HTML → [WorkBlurb]; classifies work/external/series;
                       parses bookmark id/date/rec/private, series Works:, pagination Next
  WorkDownloader.swift resolve + fetch server-rendered EPUB; validates ZIP magic
  Store.swift          GRDB schema/migrations + FTS5; idempotent upserts (preserve archive
                       state); download-queue/stale query; sync_run bookkeeping
  FileStore.swift      archive folder + works/<id> - title.epub layout, write/exist
  SyncEngine.swift     orchestration: bounded paginate → ingest → expand series → download
  Models.swift         WorkBlurb, BookmarkKind
  ArchivePaths.swift   on-disk epub filename/sanitization
Sources/ao3archiver/   CLI driver: runs a bounded SyncEngine pass (top-level code; not @main)
Sources/selftest/      headless assertions (parser + Store) runnable without XCTest
Tests/AO3KitTests/     swift-testing suite + Fixtures/ (real captured AO3 HTML):
                       works_listing, bookmarks_page, series_card, series_page
```

## AO3 facts that constrain the code (verified against the live site)

- **No public API** — everything is HTML scraping. Auth is the `_otwarchive_session`
  cookie, injected explicitly by `AO3Client` (never persisted by the tool).
- **AO3 renders EPUBs server-side** — we download, never construct them.
- **Listing markup is shared** across works-search / tag / bookmarks pages: cards are
  `li.work.blurb.group` / `li.bookmark.blurb.group`. One parser serves all sources.
- Each card embeds `<!-- updated_at=<unixts> -->`; the EPUB URL carries the same value,
  so it's the **download cache key** (skip re-download when unchanged).
- **EPUB link gotcha:** the href is `/downloads/<id>/<slug>.epub?updated_at=<ts>` and
  301-redirects to `download.archiveofourown.org`. Match it on the path **before `?`**
  (it does NOT end in `.epub`), and let URLSession follow the redirect.
- **Adult works** show an interstitial; bypass with `?view_adult=true`.
- **Bookmarks are heterogeneous:** work / external-work (`/external_works/…`, off-site,
  no EPUB) / series (a nested collection). All are recorded via `BookmarkKind`; only
  `.work` is downloadable. Series get expanded (fetch `/series/<id>`) into member works.
- **Rate limiting is real and strict** — AO3 returns 429 *and* 503 with Retry-After under
  light bursts. Default to ~1 request / 4s, single-flight, with backoff. Politeness is a
  hard requirement, not a nicety.

## Conventions

- **Built from scratch.** `ao3_api` / `ao3downloader` are references for AO3 *behavior*
  only — no vendored code. (The user dislikes both.)
- **All network access goes through `AO3Client`.** Nothing else should construct
  URLSession requests; that's where politeness/backoff lives.
- **Parser selectors are pinned to real HTML fixtures.** When AO3 markup drifts, update
  the fixture + the expectations together. Fail soft per-field; one bad card must never
  abort a whole page.
- Honest, descriptive User-Agent with contact `syrtis@sysd.info`. No forged browser UA.

## M1 store/sync facts

- **Idempotent upserts preserve archive state.** `Store.upsertWork` updates metadata via
  `ON CONFLICT(id) DO UPDATE` but never touches `epub_path` / `epub_updated_at` /
  `download_state` — re-reading a bookmark page must not clobber a downloaded file.
- **"Needs download" is a query, not a flag** (`epub_path IS NULL OR updated_at >
  epub_updated_at`), so an interrupted sync resumes correctly. `updated_at` is the **unix
  ts** (the cache key), not ISO.
- **`work_fts` is a plain FTS5 table** (not `content=''`): upserts DELETE-then-INSERT by
  `rowid = work.id`, so no external-content triggers are needed.
- **Series expansion + dedup:** a series' member works share the one `work` row (UNIQUE id)
  and get a `series_work` link; if separately bookmarked they also keep their own `bookmark`
  row. The polymorphic `bookmark(item_kind,item_id)` makes the overlap a non-issue.
- **Sync is bounded by default** (`maxPages`, `maxDownloads`); external works are stored
  `download_state='unavailable'` and excluded from the queue.
- **Folder bookmark is M2.** A security-scoped bookmark needs the app sandbox; M1's
  `FileStore` is plain directory management.

## Roadmap pointer

Next is the **SwiftUI gallery (M2)**: card list + cover grid over the M1 store, the snappy
in-memory filter pipeline, open/reveal. Then full filter parity (M3). See `PLAN.md` §10.

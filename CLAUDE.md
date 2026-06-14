# CLAUDE.md

Guidance for working in this repo. See `PLAN.md` for the full design/roadmap and
`README.md` for user-facing usage.

## What this is

A native macOS app (in progress) that backs up the user's AO3 bookmarks as `.epub` files
with a dark, liquid-glass, snappy gallery and full local filtering. **M0** (core spike),
**M1** (core sync + store), and **M2** (gallery MVP) are done: a Swift package that pages
through bookmarks, ingests every card (work / external / series) into a GRDB/SQLite store
with FTS5, expands bookmarked series, runs a resumable rate-limited EPUB download queue, and
presents it all in a dark Liquid Glass SwiftUI gallery with in-memory filtering/search/sort.

## Build / test / run

```sh
swift build                 # build library + CLI + app
swift run selftest          # headless parser + Store + gallery-model checks (98 checks)
swift test                  # swift-testing suite (needs Xcode; 24 tests, 4 suites)
swift run ao3archiver        # bounded sync: paginate → ingest → expand series → download
swift run AO3ArchiverApp     # M2 SwiftUI gallery over the synced DB (reads AO3_ARCHIVE_DIR)
```

> **Headless caveat:** the SwiftUI gallery **compiles** here but can't be *run/rendered*
> without a window server, so the view layer is compile-verified only. All gallery logic
> lives below the SwiftUI line in `AO3Kit` (`GalleryModel.swift`) and is unit-tested — keep
> it that way: anything with an `if` belongs in the model, not a View.

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
  GalleryModel.swift   M2 read/filter/sort layer (below the SwiftUI line, fully tested):
                       WorkListItem, Store.fetchAllListItems() (fan-out-safe join),
                       GalleryFilter/GallerySort/Facets, @Observable GalleryViewModel
  Models.swift         WorkBlurb, BookmarkKind
  ArchivePaths.swift   on-disk epub filename/sanitization
Sources/ao3archiver/   CLI driver: runs a bounded SyncEngine pass (top-level code; not @main)
Sources/AO3ArchiverApp/  M2 SwiftUI gallery (thin Views over GalleryViewModel): App entry,
                       GalleryView, FilterSidebar, WorkCardView (metadata card), WorkDetailView,
                       Theme (Liquid Glass helpers). SwiftPM executable, not a .app bundle yet.
Sources/selftest/      headless assertions (parser + Store + gallery model) without XCTest
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
- **Folder bookmark is still deferred.** A security-scoped bookmark needs the app sandbox;
  the M2 app is a SwiftPM executable (no Info.plist/entitlements/sandbox) and reads the DB
  from a plain path (`AO3_ARCHIVE_DIR`). Real `.app` packaging + sandbox come later.

## M2 facts (gallery)

- **Platform is macOS 26 package-wide** (`.macOS("26.0")` in Package.swift) — one
  deployment boundary so real Liquid Glass (`.glassEffect`, `.buttonStyle(.glass)`) and
  Observation are available with no scattered `@available`. Glass is the only render path.
- **Logic below the SwiftUI line.** `fetchAllListItems()` builds the gallery's display
  rows from the `bookmark` table joined to `work`/`series` + tags, grouping tags in memory
  so a work with N tags yields ONE item with N tags (no join fan-out — tested). Items come
  from the `bookmark` table, so series *members* that aren't separately bookmarked don't
  appear as their own cards.
- **No covers.** AO3 EPUBs contain no cover art; the gallery is metadata cards, not a cover
  grid. Don't reintroduce cover extraction.
- **Facet counts** are a pure function over the set filtered by all OTHER dimensions
  (true faceted search) — so a dimension never hides its own values. Tested.
- **Filters are include + exclude (tri-state).** Each `GalleryFilter` dimension has an
  include set and an exclude set; the sidebar cycles each value neutral → include → exclude
  → neutral (one list, not AO3's duplicated include/exclude lists). Exclude wins.
- **AO3 corner symbols are colour-coded** from `AO3Kit` classification (`ratingLevel`,
  `warningLevel`, `categories`). Category is one comma-joined symbol ("F/M, M/M") → split
  into per-category badges. Tags are text-only pills (no icons), grouped by type on
  separate lines (fandom → relationships → characters → freeform).
- **Verification ceiling = `swift build`.** Don't `swift run AO3ArchiverApp` as a check —
  it needs a window server and will hang headlessly. Test the model, compile the views.

## Roadmap pointer

Next is **M3 — full filter parity**: every facet from §7 (include **and** exclude tags,
ranges, crossovers, more sorts, live counts, saved presets) over the M2 model. Then Liquid
Glass polish (M4) and hardening (M5). See `PLAN.md` §10.

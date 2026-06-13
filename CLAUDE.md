# CLAUDE.md

Guidance for working in this repo. See `PLAN.md` for the full design/roadmap and
`README.md` for user-facing usage.

## What this is

A native macOS app (in progress) that backs up the user's AO3 bookmarks as `.epub` files
with a dark, liquid-glass, snappy gallery and full local filtering. Currently at **M0**
(core spike, done): a runnable Swift package that proves AO3 auth + polite rate limiting +
bookmark parsing + EPUB download before any SwiftUI is written.

## Build / test / run

```sh
swift build                 # build library + CLI
swift run selftest          # headless parser checks against real captured HTML
swift run ao3archiver        # full pipeline: fetch listing → parse → download one EPUB
```

Auth + config is via environment variables (see README): `AO3_USERNAME`,
`AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`, `AO3_MIN_INTERVAL`, `AO3_USER_AGENT`,
`AO3_LIST_PATH`.

### Testing note (important in this environment)

The dev machine has **Command Line Tools only (no full Xcode)**, so `swift test` cannot
link XCTest/Testing and will fail with "no such module 'Testing'". Use **`swift run
selftest`** for headless verification here. The richer swift-testing suite in
`Tests/AO3KitTests/` is for CI / machines with full Xcode. Keep the two in sync when
changing the parser — both assert against the same fixtures.

## Layout

```
Sources/AO3Kit/        reusable core the SwiftUI app will sit on
  AO3Client.swift      ONLY networked component: rate limiter, 429/5xx backoff, cookie, UA
  RateLimiter.swift    single-flight token-slot limiter
  BlurbParser.swift    listing HTML → [WorkBlurb]; classifies work/external/series
  WorkDownloader.swift resolve + fetch server-rendered EPUB; validates ZIP magic
  Models.swift         WorkBlurb, BookmarkKind
  ArchivePaths.swift   on-disk epub filename/sanitization
Sources/ao3archiver/   M0 CLI driver (top-level code; not @main)
Sources/selftest/      headless assertions runnable without XCTest
Tests/AO3KitTests/     swift-testing suite + Fixtures/ (real captured AO3 HTML)
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

## Roadmap pointer

Next is **M1** (full bookmark pagination, GRDB schema/migrations + FTS5, series expansion,
content-download queue, FileStore), then the SwiftUI gallery (M2+). See `PLAN.md` §10.

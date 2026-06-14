# CLAUDE.md

Contributor guide for working in this repo. **Architecture lives in
[ARCHITECTURE.md](ARCHITECTURE.md)** (the single source of design truth — read it first);
[README.md](README.md) is user-facing; [PLAN.md](PLAN.md) is the roadmap. This file is the
day-to-day operational guide: how to build/test/run, where things are, and the conventions and
gotchas that bite.

## What this is

A native macOS app (**V1.1 shipped**) that backs up your AO3 bookmarks as `.epub` files with a
dark, liquid-glass gallery and full local filtering — synced and browsed entirely from the GUI.
The core (parser, store, sync engine, gallery model) is a tested Swift package; the SwiftUI app
is a thin skin over it. V1.1 added the performance pass (scaled to ~20k bookmarks: stored
haystack, debounced search, parallel facet passes, coalesced sync reloads) and a responsive
layout. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Build / test / run

```sh
swift build                 # build library + CLI + app
swift run selftest          # headless parser + Store + gallery-model checks (162 checks)
swift test                  # swift-testing suite (needs Xcode; 39 tests, 4 suites)
swift run ao3archiver       # bounded CLI sync: paginate → ingest → expand series → download
swift run AO3ArchiverApp    # SwiftUI gallery over the synced DB (reads AO3_ARCHIVE_DIR)
./Packaging/make-icon.sh    # render the liquid-glass app icon → Packaging/AppIcon.icns
./Packaging/make-app.sh     # assemble a real, double-clickable "AO3 Archiver.app"
```

`swift run selftest` is the **framework-free** equivalent of `swift test` (same assertions, same
fixtures) and also works under Command-Line-Tools-only toolchains, where `swift test` fails with
"no such module 'Testing'". **Keep the two in lockstep** when changing the parser, store, or model.

Config is via environment variables (see README's developer section): `AO3_USERNAME`,
`AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`, `AO3_MIN_INTERVAL`, `AO3_USER_AGENT`, `AO3_LIST_PATH`,
and sync bounds `AO3_MAX_PAGES`, `AO3_MAX_DOWNLOADS`, `AO3_EXPAND_SERIES`. **Bounds default low**
(2 pages / 3 downloads) — never crawl all pages by accident; politeness is a hard requirement.

## Layout

```
Sources/AO3Kit/        reusable, tested core the app sits on
  AO3Client.swift      THE ONLY networked component (rate limiter, 429/5xx backoff, cookie, UA)
  RateLimiter.swift    single-flight token-slot limiter
  BlurbParser.swift    listing HTML → [WorkBlurb]; classifies work/external/series; pagination
  WorkDownloader.swift resolve + fetch the server-rendered EPUB; validates ZIP magic
  Store.swift          GRDB schema/migrations + FTS5; idempotent upserts; queues; presets; meta
  FileStore.swift      archive folder + works/<id> - title.epub layout
  SyncEngine.swift     orchestration: bounded paginate → ingest → expand series → download
  GalleryModel.swift   read/filter/sort/facet engine + @Observable view model (below the SwiftUI line)
  Models.swift         WorkBlurb, BookmarkKind
  ArchivePaths.swift   on-disk epub filename/sanitization
Sources/ao3archiver/   CLI driver (bounded SyncEngine pass; top-level code, not @main)
Sources/AO3ArchiverApp/  SwiftUI gallery + in-app sync (thin Views over the tested model)
Sources/selftest/      headless assertions (parser + Store + gallery model) without XCTest
Tests/AO3KitTests/     swift-testing suite + Fixtures/ (real captured AO3 HTML)
Packaging/             make-app.sh, Info.plist, IconGen.swift + make-icon.sh
```

## Conventions (the rules the codebase leans on)

- **Built from scratch.** `ao3_api` / `ao3downloader` document AO3 *behaviour* only — no vendored
  code.
- **All network access goes through `AO3Client`.** Nothing else constructs URLSession requests;
  that's where politeness/backoff/cookie/UA live.
- **All branching logic lives below the SwiftUI line, in `AO3Kit`.** Anything with an `if` belongs
  in the model, not a View — that's what keeps it testable in a headless environment.
- **Parser fails soft per-field;** selectors are pinned to fixtures. When AO3 markup drifts, update
  the fixture + expectations together. One bad card must never abort a whole page.
- **Honest User-Agent** with contact `syrtis@sysd.info`; no forged browser UA.

## Invariants you must not break (full rationale in ARCHITECTURE.md)

- **Idempotent upserts preserve archive state:** `upsertWork` never touches `epub_path` /
  `epub_updated_at` / `download_state`. "Needs download" is a query, not a flag. `updated_at` is
  the unix ts (the download cache key), not ISO.
- **`bookmark` has two unique constraints** (`bookmark_id` PK + `UNIQUE(item_kind, item_id)`):
  `upsertBookmark` drops any stale row for the same item before insert, so a re-bookmark (new id,
  same work) can't abort a sync.
- **Filter dimensions: an emptied dimension drops its key** (never an empty `Set`) — `setInclude` /
  `setExclude` / `cycle` / `setBound` enforce it, so `isActive` / `==` / the memo key / preset
  round-trips stay honest. Adding a dimension is one `FacetDimension` case + one `values(for:)` line.
- **Faceted counts are computed against the set filtered by all OTHER dimensions** (a dimension
  never hides its own values).
- **Perf invariants (V1.1):** `searchHaystack` and `titleSortKey`/`authorSortKey` are stored
  (computed once in `init`) — don't make them computed again. The 9 facet passes run in parallel
  via `concurrentPerform` writing per-dimension slots; keep them deterministic (a test asserts
  parallel == serial). The memo (`MemoKey(filter, sort, gen)`) must stay correct — don't re-add
  per-dimension stored properties.

## Gotchas

- **Verification ceiling is `swift build` for the views.** The headless env compiles SwiftUI but
  can't render it — the view layer is compile-verified only; the user runs it and reports back.
  **Don't `swift run AO3ArchiverApp` as a check** — it needs a window server and hangs headlessly.
  Keep anything with an `if` in the model (tested), not the View.
- **The sidebar is a `ScrollView`, not a `List`** — a List is NSTableView-backed and reloads
  mid-event when a filter row mutates the model → reentrancy crash.
- **Archive folder resolution** (where `archive.sqlite` + `works/*.epub` live), highest priority
  first: `AO3_ARCHIVE_DIR` → the picked folder (UserDefaults `archiveFolderPath`) → default
  `~/Documents/ao3archive`. Plain on-disk path (non-sandboxed) — never store real data in `/tmp`.
- **Bare-`swift run` runtime nudges:** without a `.app` bundle the app needs
  `NSApp.setActivationPolicy(.regular)` + activate (else keystrokes go to the terminal) and a
  forced `.resizable` `NSWindow`. The bundle (`make-app.sh`) makes these unnecessary.

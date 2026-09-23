# CLAUDE.md

The day-to-day guide for working in this repo: how to build, test and run it, where things live,
and the rules and gotchas that matter. For *why* things are built the way they are, read
[ARCHITECTURE.md](ARCHITECTURE.md) (the design source of truth). [README.md](README.md) is for
users; [plans/](plans/README.md) holds the roadmap.

## What this is

A native macOS app (currently **1.6.1**) for browsing your AO3 bookmarks in a dark Liquid Glass
gallery with full local filtering, reading them in a built-in EPUB reader, and saving the works you
want to keep as `.epub` files. Syncing, browsing, downloading and reading all happen in the app;
a bounded CLI shares the same engine and archive folder.

The core (client, parser, store, sync engine, gallery model, reader, Kindle export) is the tested
`AO3Kit` package. The SwiftUI app is a thin skin over it.

## Build, test, run

```sh
swift build                 # library + CLI + app
swift test                  # swift-testing suite (Xcode is installed here)
swift run selftest          # the same checks, framework-free
swift run ao3archiver       # bounded CLI sync — talks to the real AO3; don't run it as a check
./Packaging/make-icon.sh    # render the app icon → Packaging/AppIcon.icns
./Packaging/make-app.sh     # build "AO3 Archiver.app" into build/ (version from AO3Config.toolVersion)
```

**Run both test runners and treat either failing as a failure.** `selftest` exists for toolchains
without Xcode (where `swift test` fails with "no such module 'Testing'"), and the two must stay in
lockstep. The easy way to keep them there: put new checks in **`Sources/AO3KitTestSupport/`**
(`EngineScenarios`, `ModelChecks`, `ReaderScenarios`), which both runners execute. Anything that
spans the sync engine belongs there, run against **`StubAO3`**, a `URLProtocol` fake of AO3. Tests
never touch the network.

When you pipe test output through `grep`, check the exit status of the test run itself; a
matching `grep` will happily report success on a failing suite.

The CLI is configured by environment variables: `AO3_USERNAME`, `AO3_SESSION_COOKIE`,
`AO3_ARCHIVE_DIR`, `AO3_MIN_INTERVAL`, `AO3_USER_AGENT`, `AO3_LIST_PATH`, and the bounds
`AO3_MAX_PAGES`, `AO3_MAX_DOWNLOADS`, `AO3_EXPAND_SERIES`, `AO3_MAX_SERIES`. **Bounds default
low** (2 pages, 3 downloads, 50 series). Politeness to AO3 is a hard requirement.

## Layout

```
Sources/AO3Kit/            the tested core
  AO3Client.swift          the ONLY networked component: host allowlist, cookie, UA, retries/backoff
  RateLimiter.swift        one process-wide slot clock (`.shared`) for every client
  BlurbParser.swift        listing HTML → [WorkBlurb]; work/external/series; pagination; totals
  WorkDownloader.swift     find this work's EPUB link, fetch it, check it's a ZIP
  Store.swift              GRDB schema + migrations; upserts; download queues; pruning; presets; meta
  FileStore.swift          archive folder layout: archive.sqlite + works/<id> - <title>.epub
  SyncEngine.swift         (actor) index → reconcile → expand series → download
  GalleryModel.swift       load/filter/sort/facets + the @Observable gallery view model
  Presentation.swift       display decisions the views would otherwise make (isSaved, badges, …)
  EpubDocument.swift       .epub → spine, TOC sections, generated reader HTML
  EpubSanitizer.swift      strips anything that could make the reader touch the network
  ReaderSession.swift      pure reader state (section, bounds, progress) + ReaderSettings/CSS
  ReaderModel.swift        @MainActor reader coordinator: resume, off-main extraction and prep
  KindleExport.swift       Send to Kindle: cover + info page + title badge
  KindleCover.swift        renders the cover JPEG (CoreText)
  Models.swift             WorkBlurb, BookmarkKind
  ArchivePaths.swift       safe EPUB filenames (bounded for APFS)
Sources/AO3ArchiverApp/    SwiftUI app: gallery, sidebar, detail panel, sync sheet, reader windows
                           SyncController = GUI sync driver; CredentialStore = Keychain
Sources/ao3archiver/       CLI (top-level code, one bounded SyncEngine.run)
Sources/AO3KitTestSupport/ StubAO3 + scenarios shared by both test runners
Sources/selftest/          framework-free test runner
Tests/AO3KitTests/         swift-testing suite + Fixtures/ (real captured AO3 HTML)
Packaging/                 make-app.sh, Info.plist, icon generation
```

## Rules the codebase leans on

- **Built from scratch.** `ao3_api` and `ao3downloader` were used to learn how AO3 *behaves*;
  no code is vendored.
- **All network access goes through `AO3Client`.** Politeness, backoff, the cookie and the
  User-Agent live there and nowhere else.
- **Branching logic lives in `AO3Kit`, not in views.** If it has an `if`, it belongs in the model
  (often `Presentation.swift`), where it can be tested headlessly.
- **The parser fails soft, field by field.** Selectors are pinned to captured fixtures; when AO3's
  markup changes, update the fixture and the expectations together. One bad card must never abort
  a page.
- **An honest User-Agent**: `ao3-archiver/<toolVersion>`, the user's AO3 username when known, and
  the contact address. Never a fake browser UA.
- **The cookie never leaves AO3.** `AO3Client.perform` refuses any non-AO3 host before building
  the request (`isAO3Host` matches the apex or a `.`-prefixed subdomain, not a bare suffix), the
  redirect delegate cancels off-AO3 hops, and an EPUB link must be `/downloads/<thisWorkID>/…`.
- **The version lives in one place**, `AO3Config.toolVersion`. The User-Agent reports it and
  `make-app.sh` stamps it into the bundle.

## Invariants you must not break

The rationale for each is in ARCHITECTURE.md.

**Data**
- **The archive is one file.** `archive.sqlite` uses SQLite's rollback journal, not WAL, so the
  folder never grows `-wal`/`-shm` sidecars. The whole app shares **one connection**
  (`Store.shared(atPath:)`); the 5-second busy timeout covers the CLI running alongside it.
- **Upserts never touch archive state.** `upsertWork` leaves `epub_path`, `epub_updated_at` and
  `download_state` alone. "Needs download" is a query, never a stored flag. `updated_at` is the
  unix timestamp AO3 embeds in each card and is the download cache key.
- **A saved work stays saved.** `markFailed` and deletion confirmation never demote a work that has
  an `epub_path`; the UI decides "saved" from the file (`WorkListItem.isSaved`), not from
  `download_state`.
- **Ingest is one transaction per card** (`upsertWorkAndBookmark`, `upsertSeriesMember`), so the
  orphan sweep can never catch a half-written card.
- **`bookmark` has two unique constraints** (the `bookmark_id` key and `(item_kind, item_id)`).
  `upsertBookmark` deletes a stale row for the same item first, so a re-bookmark can't abort a
  sync.
- **Migrations from v6 on use `foreignKeyChecks: .immediate`.** GRDB's default whole-database check
  after a migration aborts on any pre-existing dangling row, and a real archive had one.

**Sync**
- **Cancellation propagates.** `AO3Client` turns a cancelled request into `CancellationError`, the
  limiter's wait throws, and the download loop rethrows it. Never let a catch-all record
  cancellation as a per-work failure.
- **Deletion needs two separate runs to agree.** Each run records its sighting under its own
  source (`SyncEngine.sightingSource(runID:)`); a successful download clears sightings; the
  exclusion expires after 90 days.
- **Removing bookmarks is guarded by `SyncEngine.pruneDecision`.** It only prunes after a Full
  sync that had a cookie, read from page 1 to the last page, saw exactly as many bookmarks as AO3's
  own total, saw private bookmarks if you have any, and would remove no more than 5% (or 25,
  whichever is larger).
  Works with a saved file, reading position or series link are flagged, never deleted.
- **One download path.** The sync loop, Save Visible and the detail panel's Download button all go
  through `SyncEngine.downloadWork`.

**Gallery**
- **An emptied filter dimension drops its key** (never an empty `Set`), so `isActive`, `==`, the
  memo key and preset round-trips stay honest. Adding a dimension is one `FacetDimension` case plus
  one `values(for:)` line.
- **Facet counts are computed against everything filtered by the *other* dimensions**, so a
  dimension never hides its own values.
- **Performance:** `searchHaystack` and the sort keys are computed once in `init`. The 10 facet
  passes run in parallel into per-dimension slots (a test checks parallel equals serial). Keep the
  memo key `MemoKey(filter, sort, gen)` correct.

**Reader**
- Navigate **TOC sections, not raw spine items** (front matter folds into the first section).
- Render a **generated `text/html` document**, never the EPUB's own XHTML (the lenient parser keeps
  `&nbsp;` from truncating chapters).
- The no-network guarantee is enforced by **`EpubSanitizer` in the DOM**; the WebView's navigation
  delegate can't see subresource loads.
- Resume is **section-granular**, and the view reloads on a content **version** (the file path is
  reused).
- Remove the `WKScriptMessageHandler` in `dismantleNSView`. Don't reintroduce `content-visibility`;
  it makes WebKit jump when scrolling up.
- ZIPFoundation's `Archive` isn't thread-safe: off-main work opens its own handle
  (`EpubDocument.extractResources`) instead of sharing the document's.

## Gotchas

- **Views are compile-checked only.** The headless environment builds SwiftUI but can't render it,
  so the user click-tests the UI. Don't `swift run AO3ArchiverApp` as a check; it needs a window
  server and hangs.
- **The user's real archive is `~/Documents/ao3archive`.** Read it with `sqlite3 -readonly` to
  ground decisions in real data. Anything that changes it (a migration, a new on-disk format, a
  cleanup) gets a dry run on a copy in the scratchpad first, with a backup, and with the app quit.
  A migration once passed every test and still failed on the real archive.
- **The sidebar is a `ScrollView`, not a `List`.** A `List` is NSTableView-backed and reloads
  mid-event when a filter row changes the model, which crashes.
- **Archive folder resolution**, highest priority first: `AO3_ARCHIVE_DIR`, then the folder picked
  in the app (UserDefaults `archiveFolderPath`), then `~/Documents/ao3archive`. The app isn't
  sandboxed, so these are plain paths. Never keep real data in `/tmp`.
- **Running without the `.app` bundle** (`swift run AO3ArchiverApp`) needs
  `NSApp.setActivationPolicy(.regular)`, an explicit activate, and a forced `.resizable` window.
  The bundle built by `make-app.sh` needs none of that.

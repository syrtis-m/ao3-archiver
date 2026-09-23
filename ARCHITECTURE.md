# Architecture

How AO3 Archiver is built, and why. This is the design source of truth. For what the app does and
how to use it, see [README.md](README.md); for day-to-day working rules, [CLAUDE.md](CLAUDE.md);
for the roadmap, [plans/](plans/README.md).

> **Built from scratch.** Tools like `ao3_api` and `ao3downloader` were read only as documentation
> of how AO3 behaves (download URLs, rate limiting, pagination, what a card contains). No code is
> vendored and nothing depends on their abstractions.

---

## 1. What AO3 forces on the design

These were verified against the live site. They aren't preferences: getting them wrong gets the
tool, or the user's IP, throttled.

- **There is no API.** Everything is HTML. Authentication is the `_otwarchive_session` cookie,
  which the tool attaches to each request itself and never writes anywhere but the Keychain.
- **AO3 builds the EPUBs.** We download them as they are; we never assemble one.
- **One card format everywhere.** Works searches, tag pages, bookmark lists and series pages all
  use the same blurb markup (`li.work.blurb.group`, `li.bookmark.blurb.group`), so one parser
  serves every listing.
- **Every card embeds `<!-- updated_at=<unix time> -->`,** and the EPUB link carries the same
  value. That timestamp is the download cache key: if it hasn't changed, the saved file is current.
- **The EPUB link is awkward.** It looks like `/downloads/<id>/<slug>.epub?updated_at=<ts>` (so it
  doesn't *end* in `.epub`) and redirects to `download.archiveofourown.org`. We match on the path
  before `?` and let URLSession follow the redirect.
- **Adult works** sit behind an interstitial; `?view_adult=true` skips it.
- **Bookmarks come in three kinds:** a work, an external work (`/external_works/…`, hosted
  elsewhere, no EPUB), or a series. Only works can be downloaded; series are expanded into their
  member works.
- **Rate limiting is real.** AO3 answers light bursts with 429 or 503 and a `Retry-After`. We make
  one request at a time, a few seconds apart, and back off when asked. Politeness is a hard
  requirement.
- **No cover art.** AO3's EPUBs have no covers, so the gallery shows metadata cards, not a cover
  grid. (The Kindle export draws its own cover for the device; see §11.)

---

## 2. Module map

```
┌──────────────────────────────────────────────────────────────────────┐
│ AO3ArchiverApp (SwiftUI, macOS 26): a thin skin over the model         │
│   GalleryView · FilterSidebar · WorkCardView · WorkDetailView          │
│   SyncController · SyncSheet · CredentialStore (Keychain) · Theme      │
│   ReaderView · EpubWebView (reader windows)                            │
└───────────────┬──────────────────────────────────────────────────────┘
                │ observes; everything with an `if` lives below this line
┌───────────────▼──────────────────────────────────────────────────────┐
│ AO3Kit: the tested core                                                │
│   AO3Client · RateLimiter      the only network access                 │
│   BlurbParser · WorkDownloader  HTML → cards; card → EPUB bytes        │
│   Store · FileStore             SQLite catalog; EPUB files on disk     │
│   SyncEngine (actor)            index → reconcile → series → download  │
│   GalleryModel · Presentation   filter/sort/facets; display decisions  │
│   EpubDocument · EpubSanitizer  EPUB → safe, generated reader HTML     │
│   ReaderSession · ReaderModel   reader state and coordination          │
│   KindleExport · KindleCover    Send to Kindle                         │
│   Models · ArchivePaths                                                │
└──────────────────────────────────────────────────────────────────────┘
        ▲                         ▲                          ▲
  ao3archiver (CLI)     AO3KitTestSupport (stub AO3)   selftest / AO3KitTests
```

Two rules hold the design together:

1. **All network access goes through `AO3Client`.** Nothing else builds a request, so politeness,
   backoff, the cookie and the User-Agent are enforced in exactly one place.
2. **All logic lives in `AO3Kit`.** If code makes a decision, it belongs below the SwiftUI line,
   where it can be tested without a window server. The views only bind; `Presentation.swift`
   exists to hold the small display decisions (is this work saved? which badge?) that would
   otherwise creep into them.

---

## 3. Data layer (`Store`, `FileStore`)

The archive is a folder: one SQLite file and a `works/` folder of EPUBs.

```
<archive>/
  archive.sqlite
  works/<work id> - <sanitized title>.epub
```

It defaults to `~/Documents/ao3archive`. It's a plain path (the app isn't sandboxed), survives app
updates, and never lives in `/tmp`.

### Tables

The migrations in `Store.swift` are the canonical schema.

| Table | Holds | Notes |
|---|---|---|
| `work` | works and external works | `id` is the AO3 id. Archive state lives here: `epub_path`, `epub_updated_at`, `download_state`, `deleted_on_ao3_at` |
| `series`, `series_work` | bookmarked series and their member works | `part` gives series order |
| `bookmark` | one row per AO3 bookmark | points at a work or a series via `(item_kind, item_id)`; `removed_at` marks a bookmark removed on AO3 but kept locally (§5) |
| `tag`, `work_tag` | normalized work tags | |
| `bookmark_tag` | your own bookmark tags | separate from work tags |
| `work_fts` | FTS5 index over title, author, summary, tags, notes | maintained but not read by the app; see §13 |
| `filter_preset` | saved filters | JSON-encoded filter and sort |
| `reading_position` | reader resume point per work | section index + progress |
| `deleted_sighting` | one row per 404 sighting | `(work_id, source)`; see §5 |
| `meta` | key/value app state | the Full-sync resume cursor, the Quick-sync watermark |
| `sync_run` | one row per sync | counts and status (`ok`, `error`, `interrupted`) |

### One file, one connection

`archive.sqlite` uses SQLite's rollback journal, so the archive is always a single file you can
copy. The app opens it **once** (`Store.shared(atPath:)`), and the gallery, sync and every reader
window share that connection, so the app never competes with itself for the database lock.

The **busy timeout** (`busyMode = .timeout(5)`) is the part that prevents data loss. GRDB's default
is to fail immediately on a locked database. When the app used to open a second connection per
reader window, a reading-position save during a sync failed with `SQLITE_BUSY` and a `try?` threw
the error away, so your place in a book silently vanished. Now a writer that meets a lock waits for
the other short transaction instead. Inside the app that no longer happens; the timeout covers a CLI
sync running alongside it.

*Why not WAL:* 1.6.0 switched archives to WAL mode; 1.6.1 switched them back. WAL's advantage
(readers don't block the writer) doesn't matter with one in-app connection, and it adds `-wal` and
`-shm` files that must be copied together. Apple's SQLite keeps them on disk even after a clean
close, and after an app quit recent writes live only in `-wal`, so copying or cloud-syncing
`archive.sqlite` alone gives an out-of-date database. The journal mode is stored in the file, so
`Store.makeConfiguration` converts a WAL archive back when it opens one: it checkpoints the WAL into
the main file, then removes the leftover `-shm` only after the switch succeeds (which proves no
other connection was using WAL).

### Rules the data layer keeps

- **Upserts never touch archive state.** `upsertWork` updates metadata with
  `ON CONFLICT(id) DO UPDATE` but never writes `epub_path`, `epub_updated_at` or `download_state`,
  so re-reading a bookmark page can't clobber a downloaded file.
- **"Needs download" is a query, not a flag:** no file yet, or `updated_at > epub_updated_at`. An
  interrupted sync therefore resumes correctly, and a failed download is retried next time (so a
  work that needed a cookie downloads once you add one). `updated_at` is stored as the unix
  timestamp for exact comparison.
- **A saved work stays saved.** `markFailed` and deletion confirmation leave `download_state` at
  `'downloaded'` whenever an `epub_path` exists, and the UI asks the file (`WorkListItem.isSaved`),
  not the state. A failed refresh once flipped saved works to "failed", which hid their Read and
  Kindle buttons while the file sat on disk.
- **Re-bookmarks don't break the sync.** `bookmark` has two unique constraints (`bookmark_id` and
  `(item_kind, item_id)`). Re-bookmarking a work on AO3 gives it a new bookmark id, so
  `upsertBookmark` removes the old row for that item before inserting.
- **Each card is written in one transaction** (`upsertWorkAndBookmark`, `upsertSeriesMember`), so
  nothing can observe a work without its bookmark or series link. That matters because
  `deleteOrphanWorks` (run at app open and after pruning) deletes works nothing refers to: no
  bookmark, no series link, no file, no reading position.
- **Chapter gains are detected during the upsert.** `upsertWork` returns a `WorkUpsertChange`
  computed from the row's old `chapters_have` before overwriting it, which is the only moment the
  comparison is possible.
- **Migrations from v6 on use `foreignKeyChecks: .immediate`.** Every statement is still
  foreign-key checked, but GRDB skips its whole-database check after the migration. That check
  aborted on a single pre-existing dangling row in a real archive and left the app unable to open
  it; v7 deletes such rows.

---

## 4. Networking (`AO3Client`, `RateLimiter`, `WorkDownloader`)

`AO3Client` is the only component that touches the network.

- **One schedule for the whole app.** Every client queues on the process-wide `RateLimiter.shared`,
  which hands out time slots at the configured interval (4 s by default in the CLI, 5 s in the
  app). A sync, Save Visible, and any number of Download clicks all wait their turn on the same
  clock.
- **Retries back off, never below the polite interval.** 429 honours `Retry-After`; 429, 5xx
  (including Cloudflare's 52x codes) and network errors otherwise back off exponentially with
  jitter, and no wait is ever shorter than the normal request interval. `onRateLimit` lets the UI
  show "waiting 30 s" instead of looking stalled. A Cloudflare challenge page ("shields up") is
  reported as such rather than retried or mistaken for a login problem.
- **Cancellation is not a failure.** A cancelled request surfaces as `CancellationError` (URLSession
  reports `URLError.cancelled`; the limiter's sleep throws), so callers stop instead of retrying or
  recording a per-work error.
- **The cookie and User-Agent never leave AO3.** `perform` refuses any host that isn't AO3 before
  building the request. `isAO3Host` matches the apex or a `.`-prefixed subdomain; a bare suffix
  check would also accept `evil-archiveofourown.org`. The redirect delegate cancels any hop off AO3
  and re-attaches the cookie across AO3's own cross-host EPUB redirect, which URLSession would
  otherwise drop.
- **Honest identification.** The User-Agent is
  `ao3-archiver/<toolVersion> (personal bookmark backup; AO3 user: <name>; contact …)`.
  `AO3Config.toolVersion` is the app's single version number; `make-app.sh` stamps it into the
  bundle.

`WorkDownloader` fetches a work page, finds the EPUB link, and downloads it. The link must be
site-relative and belong to **this** work (`/downloads/<workID>/…`); the fallback selector also sees
author-written content, so without the id check a planted link could archive a different work under
this one's name. The downloaded bytes must start with the ZIP signature. A page with no download
link means the work needs a login (`requiresLogin`), unless it's a Cloudflare page.

---

## 5. Sync (`SyncEngine`)

`SyncEngine` is an `actor`. The app drives it from a detached task, so parsing, database writes and
file writes stay off the main thread, and two runs can't interleave. Every page and every EPUB is
committed as soon as it's done, so an interrupted run loses nothing.

### Full sync (`run`)

1. **Index.** Page through the bookmark list, parse each card and upsert it. External works are
   recorded but never downloaded. The next-page URL is saved as a resume cursor, so a run stopped at
   page 15 of 130 continues from page 15 next time (only if the cursor belongs to the same listing).
   **Start over** in the app clears it.
2. **Reconcile removed bookmarks** (the app's Full sync only). See below.
3. **Expand series.** Fetch each bookmarked series, following its pagination (up to
   `maxSeriesPages`), and link its member works.
4. **Download.** Fetch EPUBs for works that need one, up to the run's cap.

### Quick sync (`incrementalSync`)

A cheap catch-up, bounded by a small page budget:

1. **New bookmarks:** page the default (date bookmarked) listing until a page contains nothing new.
2. **Updated works:** page the date-updated listing until a whole page predates the last successful
   Quick sync. Re-ingesting bumps `updated_at`, which marks saved works stale. A card whose date
   didn't parse counts as "unknown", not "old", so parser drift makes the pass do more work, never
   stop early.
3. **New series:** expand up to three bookmarked series that have never been fetched.
4. **Re-download** saved works that went stale (capped). The never-downloaded backlog is left for
   Full sync or Save Visible.

The watermark is the run's start time and is saved only on success, so nothing updated mid-run is
skipped.

### Other entry points

- **Save Visible** (`downloadSelected`) downloads the unsaved works in the gallery's current view,
  at most 100 per request, skipping files that are already current. It's recorded as a normal sync
  run.
- **The detail panel's Download button** uses the same `downloadWork` as the sync loop, and **Fetch
  works in this series** uses the same series expansion.

**Queue order is intent.** Both download queues put the most recently bookmarked works first, then
series members nobody bookmarked directly. With a cap per run, order decides what gets saved;
ascending work id used to mean the oldest works on AO3 always went first.

### Removed bookmarks

After a Full sync's index pass, a bookmark this run didn't see *might* have been removed on AO3.
Acting on that is dangerous, since a partial view would delete real bookmarks, so
`SyncEngine.pruneDecision` requires every one of these:

- **A session cookie.** Private bookmarks are only shown to their logged-in owner, and an expired
  cookie on your own listing most likely serves the public ones rather than a login page.
- **A complete read:** the pass started on page 1 (not a resume) and continued until there was no
  Next link.
- **The exact count:** the number of distinct bookmarks seen equals the total in AO3's own heading
  ("1 - 20 of 1,811 Bookmarks", read by `BlurbParser.listingTotal`). A page that shifted mid-run or a
  truncated listing fails this.
- **Private bookmarks visible,** if the archive holds any.
- **A small change:** at most 5% of bookmarks (or 25, whichever is larger). A large drop is far more
  likely a parsing or login problem than you un-bookmarking hundreds of works at once.

If any check fails, nothing is removed and the activity log says why. If all pass, a bookmark whose
work is still yours locally (a saved file, a reading position, a series link) is kept and flagged
`removed_at`, which shows as an **Un-bookmarked** badge. Other removed bookmarks are deleted, and the
orphan sweep removes their works. A bookmark that reappears on AO3 is simply un-flagged.

### Cookie expiry mid-sync

AO3 doesn't reject a stale cookie; it returns a normal page containing the login form. A sync would
then find no cards and finish looking successful. `BlurbParser.looksLikeLoginPage` detects the form
(only when the page has no cards, so a fic summary that mentions logging in can't trigger it, and
only when a cookie was supplied, since logged-out pages legitimately show a login form). The engine
throws `AO3Error.sessionExpired`; the app pauses in a `needsCookie` state and **Resume sync**
restarts the same run with a fresh cookie. A Full sync continues from its saved cursor.

### Deleted works

A 404 on a work's page is **evidence** that the author deleted it, not proof; AO3 also returns 404
during deploys and for some restricted works. So:

- Each sync records at most one sighting per work, under its own source
  (`SyncEngine.sightingSource(runID:)`). A work is only treated as deleted once
  `Store.deletedConfirmThreshold` (2) different runs agree. (A fixed source once made the threshold
  unreachable; tests calling the Store directly with made-up sources didn't catch it.)
- Once confirmed, the work gets `deleted_on_ao3_at`: an **Only copy** badge if you saved it,
  **Deleted on AO3** if not. It drops out of the download queues so it isn't requested every sync.
- The exclusion **expires** after `deletedRecheckDays` (90), because authors do restore works. A
  re-confirmation after that gets a fresh timestamp.
- A successful download clears all sightings, and **Check again on AO3** in the detail panel clears
  the verdict by hand.
- Nothing is probed proactively; this only happens when the normal download flow meets a 404.

### Chapter gains

`SyncEngine.ingest` records positive `newChapters` deltas; the download loop reports "gained N
chapters — saved" only once the new file is actually written.

---

## 6. The gallery model (`GalleryModel`)

Everything the gallery shows comes from **pure computation over an in-memory list**, so filtering,
searching, sorting and facet counts never touch the disk.

- **`fetchAllListItems()`** joins `bookmark` to `work` or `series`, grouping tags in memory so a
  work with N tags is one item, not N rows. Items come from bookmarks, so series members you didn't
  bookmark appear under their series, not as their own cards.
- **One filter mechanism for every tag-like dimension.** Bookmark type, rating, category, language,
  fandom, warnings, relationships, characters, additional tags and your own tags are cases of
  `FacetDimension`, each with one `values(for:)` extractor. The filter keeps `include` and `exclude`
  sets per dimension. **An emptied dimension drops its key**, so `isActive`, `==`, the memo key and
  preset round-trips stay honest. Adding a dimension is one case plus one line.
- **Three-state facets.** A value cycles neutral → include → exclude → neutral. Exclude wins. Within
  a multi-value dimension (tags) includes are AND-ed; within a single-value one (rating) they're
  OR-ed, since a work can't have two ratings.
- **Ranges** (word count, kudos, comments, bookmarks, hits, date updated, date bookmarked) share one
  `NumericBound` mechanism over a `Double?` value. An item without a value (a series has no word
  count) drops out of an active range.
- **Yes/no filters** (crossover, rec'd, has notes, private) use `TriFilter`; completion and download
  state are single-select.
- **True faceted counts.** Each dimension's counts are computed against the items filtered by all
  *other* dimensions, so picking a value never hides its siblings.
- **Presets.** `GalleryFilter` and `GallerySort` are `Codable`; a preset is stored as JSON in
  `filter_preset`.
- **`GalleryViewModel`** (`@Observable`) holds the items, filter and sort, and memoizes the visible
  list and all facet counts under `MemoKey(filter, sort, loadGeneration)`, so a re-render doesn't
  recompute. During a sync the list reloads off the main thread (`reload(from:)`); a generation
  counter drops an older fetch that finishes after a newer one.

**Not available from the data:** a date-published filter or sort. Listing cards carry only the
updated date, and fetching each work's page to get it would cost one request per work.

---

## 7. Performance (designed for 20,000 bookmarks)

At 20k items nothing is quadratic and the working set is tens of MB, so the answer wasn't a SQL
rewrite. The slowness was repeated work, main-thread work and no input debounce. The fix keeps the
in-memory engine and makes it do less, less often, off the main thread, on more cores.

| Change | Effect | Where |
|---|---|---|
| Stored `searchHaystack` | built once per item, not per keystroke | `WorkListItem` |
| Debounced search | a burst of typing becomes one recompute (~200 ms) | `GalleryView` |
| Stored sort keys | plain `<` instead of locale-aware comparison per sort step | `WorkListItem` |
| Allocation-free matching | probe the small filter sets instead of building a set per item | `GalleryFilter.matches` |
| Parallel facet passes | the 10 facet counts run on all cores, each into its own slot | `GalleryViewModel` |
| Coalesced sync reloads | at most one gallery reload per ~1.2 s during a sync, fetched off-main | `SyncController`, `GalleryViewModel.reload` |

**Measured** (debug build, 20k synthetic items): a full recompute went from 349 ms to 135 ms, and
the first compute from 121 ms to 52 ms. A budget assertion in the scale test guards these numbers,
and a check that parallel facet counts equal serial ones keeps the concurrency deterministic.

**Deliberately not done:** moving the recompute itself off the main thread (little gain at 20k), and
switching search to SQL/FTS (only worth it past ~100k, and it would change search from "substring
anywhere" to token matching).

---

## 8. The app (`AO3ArchiverApp`)

The whole package targets **macOS 26**, so Liquid Glass (`.glassEffect`, `.buttonStyle(.glass)`) and
Observation are available everywhere with no `@available` branches.

- **Layout.** A filter sidebar with live facet counts (typeahead for dimensions with thousands of
  values), the gallery of metadata cards (comfortable or compact), a toolbar (search, sort, Save
  Visible, archive folder, sync) and a detail panel. It adapts to width: at 1100 pt and up both side
  panels can be pinned; between 720 and 1100 pt only one at a time; below 720 pt they open as sheets
  over the gallery.
- **Cards show metadata, not covers:** title, author, AO3's colour-coded corner symbols (rating,
  category, warnings, completion), tag pills by type, stats, summary, your bookmark tags and notes,
  and badges for **Only copy**, **Deleted on AO3** and **Un-bookmarked**.
- **The detail panel** offers Read, Open in Books, Send to Kindle, Reveal in Finder, Download EPUB
  and View on AO3; for a series, its works in order and a fetch button.
- **Syncing.** `SyncController` (`@MainActor`) drives the engine from a detached task and feeds
  progress back through one ordered stream: page N of M, a rate-limit banner, an activity log. Each
  run carries a generation number; Cancel frees the UI at once, and anything a cancelled run still
  reports is ignored, so it can't overwrite a newer run. The gallery owns its controller and cancels
  it if the archive folder changes. `SyncSheet` stores the username and cookie in the Keychain via
  `CredentialStore`. If the Keychain refuses a read, the stored value is kept (never overwritten by
  the empty field) and the sheet says so. A sync requires a username.
- **The sidebar is a `ScrollView`, not a `List`.** A `List` is NSTableView-backed and reloads
  mid-event when a filter row changes the model, which crashes.

**Archive folder:** `AO3_ARCHIVE_DIR` if set, else the folder picked in the app (UserDefaults
`archiveFolderPath`), else `~/Documents/ao3archive`. The CLI uses the same default. On open the app
closes sync runs left `running` by a crash (only ones older than six hours, in case a CLI sync is
live) and sweeps orphan works.

**The `.app` bundle** (`Packaging/make-app.sh`: non-sandboxed, ad-hoc signed) is the real way to run
it. Run bare with `swift run AO3ArchiverApp`, it needs a regular activation policy, an explicit
activate and a forced resizable window, which the code supplies.

---

## 9. The reader

Saved works open in the app's own reader, in their own windows. It only reads files already on disk,
so it adds no network use.

**What AO3's EPUBs look like.** An EPUB is a ZIP described by an OPF file (manifest plus an ordered
spine), with an EPUB2 `toc.ncx` or EPUB3 `nav` table of contents. AO3 splits a work into one file
per chapter **plus a preface and a title page**, and the title page isn't in the TOC. Navigating the
raw spine would therefore call the title page "Chapter 2".

**`EpubDocument`** parses the container, OPF, spine, metadata and TOC (falling back to spine order)
and derives **reading sections**: the spine files between one TOC entry and the next fold into one
titled section, so the title page lands inside "Preface". Extraction refuses any entry whose path
would escape the target folder.

**It renders generated HTML, not the EPUB's XHTML.** AO3's XHTML uses named entities like `&nbsp;`
without declaring them, and WebKit's strict XML parser stops at the first one, showing half a
chapter. So the reader builds a fresh `text/html` page from each section's sanitized body, inlines
its own stylesheet, and loads that. (`dc:language` goes into `<html lang>` only if it looks like a
real language tag.)

**No network, enforced in the page itself.** A `WKWebView` navigation delegate never sees image or
stylesheet loads, so **`EpubSanitizer`** cleans every body first. It removes scripts, embeds,
`<style>`, `<link>`, SVG animation elements and event handlers; drops any `url()`-bearing inline
style; and drops URL attributes that would load remotely. "Remote" is decided the way WebKit parses
URLs: a protocol-relative URL or any scheme other than a few local ones (`data:`, `mailto:`, …) is
remote, after removing the tabs and newlines that URL parsing ignores. That catches `https:host`,
`ht<tab>tps://` and backslash forms, which a prefix check misses. Every candidate in a `srcset` is
checked, and every attribute ending in `href` (so SVG's `xlink:href`) is treated as a link. The
navigation delegate cancelling non-file navigations is a second layer.

**Two modes.** *Chapters* shows one section at a time, and parses only that section, so even a huge
work opens instantly. *Scroll* shows the whole work; sanitizing every chapter takes a while (about
2.6 s for 247 chapters), so it happens off the main thread behind a spinner and is cached, making
later font or theme changes near-instant. The EPUB's images are extracted off the main thread too,
using a separate archive handle because ZIPFoundation's `Archive` isn't thread-safe. If extraction
fails, the window says so instead of staying blank. (`content-visibility` was tried for lazy
rendering and removed: it makes WebKit jump when scrolling up.)

**Resume** is by section, which survives font changes where a pixel offset wouldn't. In scroll mode
a debounced script reports the topmost visible section, so resume lands where you actually were.
Positions are saved to `reading_position` through the app's shared connection; if a save fails, the
reader shows a warning rather than losing it silently. The script message handler is removed in
`dismantleNSView` to avoid a retain cycle, and the view reloads on a content *version*, since the
generated file's path is reused.

**Windows.** Each work opens in its own `WindowGroup(for: ReaderWindowValue.self)` window: resizable,
full-screen, as many as you like. The logic (`ReaderSession` for position and bounds,
`ReaderSettings` for theme, font and CSS, `ReaderModel` to coordinate) is tested; the web view is
compile-checked only.

---

## 10. Ratio sorts (`GallerySort`)

Besides the single-number sorts, five sorts rank by how two numbers relate, surfacing fics a single
number buries:

| Sort | Ratio | Finds |
|---|---|---|
| Acclaim | kudos ÷ hits | quietly beloved works |
| Keeper | bookmarks ÷ kudos | works people save to reread |
| Conversation | comments ÷ kudos | discussion magnets, serials |
| Density | kudos ÷ words | short works that punch above their length |
| Collector | bookmarks ÷ hits | works readers keep |

They were chosen from an exploratory analysis of a real archive as the ratios least correlated with
raw popularity, so they actually reorder the list.

A plain ratio ranks flukes first (5 hits and 5 kudos is "100% acclaim"), so each sort uses
`num / (den + prior)` with a per-ratio prior (hits 300, kudos 40, words 2,000). That pulls
tiny-denominator works toward zero while barely moving normal ones, and unlike a minimum threshold
it keeps every item in the list. Missing numbers count as 0 and sink. `GallerySort.isRatio` groups
them in the sort menu.

---

## 11. Send to Kindle (`KindleExport`, `KindleCover`)

The **Send to Kindle** button hands a saved work to Amazon's *Send to Kindle* Mac app, found by
bundle id (`com.amazon.SendToKindle`; a name lookup would also match the Kindle reading app). AO3's
EPUB is bare, so `KindleExport.makeKindleEPUB` first makes a temporary copy with three additions,
each for a different part of the Kindle:

1. **A cover** (`KindleCover`), for the home screen: a 2:3 JPEG drawn with CoreGraphics and CoreText
   (safe off the main thread): title (shrinking as it lengthens), author, fandom, ship and word
   count. Skipped if the book already has a cover.
2. **An info page**, which you land on when you open the book: fandom, ship, rating, warnings,
   category and stats. It's the first spine item and is listed in the guide and TOC, because Kindle
   skips front matter it doesn't recognise as content. Simple reflowable markup, no tables or flexbox.
3. **A title badge** for the library list: `Title (Fandom, 10k words)`, with at most two fandoms and
   a length cap so it fits the list view.

**The OPF is edited with targeted string splices, never re-serialized** through an HTML parser,
which could mangle its XML namespaces. `mimetype` stays first and uncompressed. The OPF is replaced
**last**, because the other writes shift the ZIP's internal offsets and an entry read earlier would
be stale. If anything about the book is unexpected, the export leaves the valid copy alone rather
than failing.

The export runs off the main thread. Each export gets its own temporary folder (so two exports of
the same title can't collide) under `tmp/ao3-kindle/`, and folders older than an hour are swept,
since the file must outlive the hand-off to Amazon's app.

**Tested** by reopening the built file with `EpubDocument` (spine plus one, info page first and in
the TOC, `mimetype` first, cover present). **Only checkable on a device:** whether Amazon's converter
uses the cover and start page, and how the badge truncates.

---

## 12. Testing

Two runners execute the same checks against the same fixtures:

- **`swift test`**: the swift-testing suite in `Tests/AO3KitTests/`.
- **`swift run selftest`**: a framework-free runner for toolchains without Xcode.

They must stay in lockstep. The simplest way is to write checks in **`AO3KitTestSupport`**, which
both run:

- **`StubAO3`** is a fake AO3. `AO3Client` accepts an injected `URLSessionConfiguration` and
  `RateLimiter`, and the stub installs a `URLProtocol` on a unique `stub-….archiveofourown.org` host
  per test (it passes the host allowlist, and parallel tests don't share routes). Any request it
  wasn't told about fails loudly, so a test can never reach the real site.
- **`EngineScenarios`** run the real `SyncEngine` end to end: deletion across two runs, Cancel in the
  middle of downloads, series pagination, resume cursors, pruning (and every way it must refuse),
  Quick-sync series, Save Visible.
- **`ModelChecks`** and **`ReaderScenarios`** cover the prune guards, orphan sweep, legacy-database
  migration, the single-file conversion, display decisions, off-main reloads and reader extraction.

Prefer an engine scenario whenever behaviour spans the engine: a Store-level test with hand-picked
arguments is exactly how the unreachable deletion threshold hid in passing code. When fixing a bug,
check that the new test fails without the fix.

**Parser selectors are pinned to captured AO3 pages** in `Tests/AO3KitTests/Fixtures/` (works
listing, bookmarks page, series card, series page). When AO3's markup changes, update the fixture
and the expectations together; parsing fails soft per field, and one bad card never aborts a page.

**The views are compile-checked only.** The build environment can't render SwiftUI, so the user
click-tests the UI.

---

## 13. Known gaps and unverified assumptions

Kept in one place so they're easy to find and close:

- **The login-page markers have no captured fixture.** `looksLikeLoginPage` matches the form's
  action, a field name and Devise's flash text; no real expired-cookie page was available to pin it
  to. Capture one into `Fixtures/` when possible.
- **"404 means deleted" hasn't been confirmed on a real deleted work.** If AO3 serves a 200 "deleted"
  page instead, the download fails as `requiresLogin` and no deletion is ever recorded (safe, but
  silent). A captured response would settle it.
- **Pruning has never run against live AO3.** It depends on the "of N Bookmarks" heading matching
  the cards the parser sees; if they differ (for example a placeholder card the parser drops), every
  run safely skips pruning and says why in the activity log.
- **Each EPUB costs two requests** (work page, then file). Fetching `/downloads/<id>/…` directly
  might work but hasn't been tested against AO3.
- **`work_fts` is maintained but unused.** Search runs in memory; the FTS table is written on every
  upsert and read only by tests. Keep it as the path past ~100k bookmarks, or drop it: an open
  decision.

See [plans/](plans/README.md) for how each would be closed.

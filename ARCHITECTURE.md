# Architecture

The single source of truth for **how AO3 Archiver is built and why**. For what it does and how
to use it, see [README.md](README.md). For the forward-looking roadmap, see [PLAN.md](PLAN.md).
For day-to-day contributor conventions, see [CLAUDE.md](CLAUDE.md).

> **Built from scratch.** This is an original codebase. `ao3_api` / `ao3downloader` and similar
> tools are referenced only as *documentation of AO3's behaviour* (download-URL shape, 429
> handling, bookmark pagination, which fields live on a card) — no vendored code, no dependency
> on their abstractions.

---

## 1. What constrains the design (AO3 facts, verified against the live site)

These are not preferences; getting them wrong gets the tool (or the user's IP) throttled.

- **No public API.** Everything is HTML scraping. Auth is the `_otwarchive_session` cookie,
  injected explicitly per request and never persisted by the tool.
- **AO3 renders EPUBs server-side.** We download them as-is; we never construct EPUBs.
- **Listing markup is shared** across works-search / tag / bookmarks / series pages — cards are
  `li.work.blurb.group` / `li.bookmark.blurb.group`. **One parser serves all sources.**
- **Each card embeds `<!-- updated_at=<unixts> -->`,** and the EPUB URL carries the same value.
  That timestamp is the **download cache key** — skip re-download when it hasn't changed.
- **EPUB link gotcha:** the href is `/downloads/<id>/<slug>.epub?updated_at=<ts>` and
  301-redirects to `download.archiveofourown.org`. Match it on the path **before `?`** (it does
  *not* end in `.epub`) and let URLSession follow the redirect.
- **Adult works** show an interstitial; bypass with `?view_adult=true`.
- **Bookmarks are heterogeneous:** a work, an external work (`/external_works/…`, off-site, no
  EPUB), or a series (a nested collection). Only works are downloadable; series are expanded
  into their member works.
- **Rate limiting is real and strict.** AO3 returns 429 *and* 503 with `Retry-After` under light
  bursts. Default to ~1 request / 4s, single-flight, with backoff. **Politeness is a hard
  requirement, not a nicety.**
- **No cover art.** AO3 EPUBs contain no cover images — so the gallery is metadata cards, not a
  cover grid. (Don't reintroduce cover extraction.)

---

## 2. Module map

```
┌─────────────────────────────────────────────────────────────────────┐
│ AO3ArchiverApp (SwiftUI, macOS 26) — a thin skin over the model      │
│   GalleryView · FilterSidebar · WorkCardView · WorkDetailView         │
│   SyncController / SyncSheet · CredentialStore · Theme                │
└───────────────┬─────────────────────────────────────────────────────┘
                │ reads/observes (everything with an `if` lives below this line)
┌───────────────▼─────────────────────────────────────────────────────┐
│ AO3Kit — the reusable, fully-tested core                             │
│                                                                       │
│  GalleryModel   in-memory read/filter/sort/facet engine + view model │
│  Store          GRDB/SQLite schema + FTS5; idempotent upserts; queries│
│  SyncEngine     bounded, resumable: paginate → ingest → expand → dl   │
│  BlurbParser    listing HTML → [WorkBlurb] (work/external/series)     │
│  WorkDownloader resolve + fetch the server-rendered EPUB              │
│  FileStore      archive folder + works/<id> - title.epub layout       │
│  AO3Client      THE ONLY networked component (rate limit, backoff)    │
│  RateLimiter · Models · ArchivePaths                                  │
└──────────────────────────────────────────────────────────────────────┘
                ▲                              ▲
        ao3archiver (CLI driver)      selftest (headless checks)
```

**Two hard rules that the whole codebase leans on:**

1. **All network access goes through `AO3Client`.** Nothing else constructs a `URLSession`
   request — that one place owns politeness, backoff, the cookie, and the User-Agent.
2. **All logic lives below the SwiftUI line, in `AO3Kit`.** Anything with an `if` belongs in the
   model (`GalleryModel`), not a View. The views are a dumb, compile-verified skin; the model is
   unit-tested. This is what keeps the app testable despite a headless build environment.

---

## 3. Data layer (`Store`, GRDB/SQLite + FTS5)

The archive is a plain on-disk SQLite file plus a `works/` folder — portable, survives app
updates, and never lives in `/tmp`. The canonical schema is the migration list in
`Store.swift`; the shape:

| Table | Holds | Notes |
|---|---|---|
| `work` | works + external works | `id` = AO3 work id; archive state (`epub_path`, `epub_updated_at`, `download_state`) lives here |
| `series` | bookmarked series | expanded into member `work` rows on sync |
| `series_work` | series ↔ member work links | with `part` ordering |
| `bookmark` | one row per AO3 bookmark | polymorphic `(item_kind, item_id)` → a work or a series |
| `tag` / `work_tag` | normalized tags | so a facet count is one grouped query |
| `bookmark_tag` | the user's *own* bookmark tags | distinct from work tags |
| `work_fts` | FTS5 full-text index | title/author/summary/tags/notes |
| `filter_preset` | saved "Smart Bookmarks" | JSON-encoded filter + sort |
| `meta` | key/value | resume cursor for a throttled index |
| `sync_run` | sync bookkeeping | per-run counts/status |

**Design decisions that matter:**

- **Idempotent upserts preserve archive state.** `upsertWork` updates metadata via
  `ON CONFLICT(id) DO UPDATE` but **never touches** `epub_path` / `epub_updated_at` /
  `download_state` — re-reading a bookmark page must not clobber a downloaded file.
- **"Needs download" is a query, not a flag:** `epub_path IS NULL OR updated_at > epub_updated_at`,
  so an interrupted sync resumes correctly. `updated_at` is stored as the **unix ts** (the cache
  key), not ISO — exact comparison, no human-date parsing.
- **`bookmark` has two unique constraints** — `bookmark_id` (PK) and `UNIQUE(item_kind, item_id)`.
  A work re-bookmarked on AO3 returns a *new* bookmark id for the *same* item; `upsertBookmark`
  drops any stale row for that item before inserting, so the second constraint can't abort a sync.
- **`work_fts` is a plain FTS5 table** (not `content=''`): upserts DELETE-then-INSERT by
  `rowid = work.id`, so no external-content triggers are needed.
- **Series dedup:** a series' members share the one `work` row (UNIQUE id) plus a `series_work`
  link; if separately bookmarked they keep their own `bookmark` row too. The polymorphic
  `bookmark(item_kind, item_id)` makes the overlap a non-issue.

On-disk layout:
```
<ArchiveRoot>/
  archive.sqlite
  works/<work_id> - <sanitized title>.epub
```

---

## 4. Networking & sync

**`AO3Client`** is the only networked component: a single-flight token-slot `RateLimiter`
(default ~1 req / 4s, user-tunable), 429/503 `Retry-After` backoff with jitter and exponential
growth on repeats, 5xx + timeout retries, explicit cookie injection, an honest User-Agent (the requester's AO3
username when known + contact `syrtis@sysd.info`, built by `AO3Config.defaultUserAgent`), and
automatic following of the EPUB download redirect. It exposes
`onRateLimit` so the UI can surface a backoff instead of looking stalled.

**`SyncEngine`** orchestrates a bounded, resumable run (each step committed immediately):

1. **Index** — page through bookmarks, classify each card (`work`/`external` → `work`, `series`
   → `series`), upsert the lightweight metadata. External works are recorded but never queued
   for download.
2. **Series expansion** (rate-limited) — for each bookmarked series, fetch `/series/<id>`, parse
   its members with the same `BlurbParser`, upsert + link them, enqueue each for download.
3. **Content download** (slow, rate-limited) — fetch EPUBs for works that need one, validating
   the ZIP/EPUB magic bytes, and mark each downloaded on completion.

**Bounded by default** (`maxPages`, `maxDownloads` default low) so a casual run never crawls a
large account by accident. **Resumable:** the next-page URL is persisted in `meta`
(`SyncEngine.resumeKey`), so a run throttled at page 15 of ~130 resumes there, not at page 1.
A failed download stays in the queue (retryable across runs — run anonymously, add a cookie,
re-run to pick up works that needed login).

---

## 5. The gallery model (`GalleryModel` — the heart of the UI)

Everything the gallery shows is derived by **pure compute over an in-memory working set**, so
filter / search / sort / facet never touch disk on the hot path.

- **`fetchAllListItems()`** builds the display rows from the `bookmark` table joined to
  `work`/`series` plus tags, grouping tags **in memory** so a work with N tags yields one
  `WorkListItem` with N tags (no join fan-out). Items come from the `bookmark` table, so series
  *members* that aren't separately bookmarked don't appear as their own cards.
- **One generic keyed filter mechanism.** Every multi-value dimension (bookmark type, rating,
  category, warnings, language, fandom, relationship, character, freeform, your tags) lives in a
  single `FacetDimension` enum + a `WorkListItem.values(for:)` extractor. The filter stores
  `include`/`exclude` as `[FacetDimension: Set<String>]`. **Invariant: an emptied dimension drops
  its key** (never an empty set) — so `isActive` / `==` / the memo key / preset round-trips stay
  honest. Adding a dimension is one `case` + one line.
- **Tri-state facets.** Each value cycles neutral → include (green ✓) → exclude (red ⊘) →
  neutral — include and exclude in one list, not AO3's duplicated lists. Exclude wins.
- **Ranges are one mechanism too.** `RangeField` (word count / kudos / comments / bookmarks /
  hits / date updated / date bookmarked) + `NumericBound` (min/max) over a single `Double?`
  extractor. A nil-valued item (a series has no word count) drops out of an active range. Date
  bookmarked is parsed from text to `Date?` once at load (shared POSIX/UTC formatter, fail-soft)
  — no schema migration, because all filtering is in memory.
- **Derived / bookmark booleans** use `TriFilter` (any/yes/no): crossover (fandom count > 1),
  rec'd, has-notes, private/public. Completion and download are single-select.
- **Faceted counts are true faceted search:** each dimension's counts are computed against the
  set filtered by all *other* dimensions, so selecting one value never hides that dimension's
  other values.
- **Saved presets ("Smart Bookmarks").** `GalleryFilter`/`GallerySort` are `Codable`; a
  `FilterPreset` (name + filter + sort) is JSON-encoded into `filter_preset`. (A
  `[FacetDimension: Set<String>]` encodes as a JSON *array* — Swift only treats String/Int keys
  as object keys — which round-trips fine.)
- **`GalleryViewModel`** (`@Observable`) holds `allItems` + `filter` + `sort` and exposes the
  derived `visibleItems` / `facets(for:)`, **memoized** via an `@ObservationIgnored` cache keyed
  by `MemoKey(filter, sort, loadGeneration)` — so repeated renders don't recompute; only a real
  change does. A `recomputeCount` lets tests prove the memo holds.

### Out of scope by data availability

Date-*published* range and date-posted sort: the listing blurb carries only the *updated* date,
so a published date would need a per-work hydration fetch we deliberately avoid for politeness.
A local-file-size / download-status sort needs epub byte size stored at download (a small
post-V1 item).

---

## 6. Performance architecture (the V1.1 "M6" pass — designed for 20k bookmarks)

**Design point:** ~20k unique bookmarks on Apple-Silicon compute (many fast cores, ample RAM).
At this scale nothing in the pipeline is O(n²) and 20k items are only tens of MB resident — so
the answer is **not** a SQL rewrite. The slowness was wasted recomputation, main-thread
blocking, and no input debounce. The fix keeps the tested in-memory engine and makes it do
**less work, less often, off the main thread, across more cores.**

| Lever | What it does | Where |
|---|---|---|
| **Stored `searchHaystack`** | concatenated/lowercased once in `init`, not re-joined per match call | `WorkListItem` |
| **Debounced search** | a burst of keystrokes collapses to one recompute (~200ms); clearing applies instantly | `GalleryView` |
| **Precomputed sort keys** | `titleSortKey`/`authorSortKey` replace per-comparison `localizedCaseInsensitiveCompare` | `WorkListItem` / `GallerySort` |
| **Allocation-free matching** | probe each item value against the small include/exclude set instead of building a `Set` per item per dimension | `GalleryFilter.matches` |
| **Parallel facet passes** | the 9 independent faceted-count passes run via `DispatchQueue.concurrentPerform` (each writes its own result slot — no locking); wall-clock collapses toward one pass | `GalleryViewModel.derived` |
| **Coalesced sync reloads** | the live "grow the gallery" reload (a full `fetchAllListItems` + recompute) is throttled to ≤1 / ~1.2s during sync, with an immediate flush at end-of-run | `SyncController` |

**Measured (debug, 20k synthetic items):** a full recompute (visible list + all 9 facets) went
**349ms → 135ms (~2.6×)**; first compute 121ms → 52ms. These are guarded by a regression
assertion in the scale test, so later changes can't silently regress them. A "parallel facets ==
serial facets" check proves the concurrency stays deterministic.

**Deferred (optional, post-V1.1):** moving the recompute fully off-main with a generation token
(insurance for 50k+ / pathological filters; high architectural cost, modest payoff at 20k after
the above), and a SQL/FTS fallback (only past ~100k — and a search-*semantics* change, since
FTS is token/prefix matching, not the current substring-anywhere `contains`).

---

## 7. UI layer (`AO3ArchiverApp`)

A thin SwiftUI skin over the tested model. **Platform is macOS 26 package-wide**
(`.macOS("26.0")` in `Package.swift`) — one deployment boundary, so real Liquid Glass
(`.glassEffect`, `.buttonStyle(.glass)`) and Observation are available with no scattered
`@available`. Glass is the only render path.

- **Layout** mirrors AO3 bookmarks: a glass **filter sidebar** (live facet counts, typeahead on
  high-cardinality dimensions), the **gallery** of metadata cards (comfortable/compact density),
  a top bar (search + sort + sync), and a **detail inspector** (open in Books, reveal in Finder,
  view on AO3; series list their members in order, per-work download).
- **The card is metadata, not a cover:** title, author, AO3 colour-coded corner symbols (rating /
  category-with-gradients / warnings / completion), tag pills grouped by type, stats, summary,
  and your own bookmark tags/notes.
- **Responsive layout (V1.1).** The detail inspector is the *flex* pane: below ~900pt it
  auto-hides (width tracked via `onGeometryChange`) and returns when the window widens; the
  sidebar collapses to a toggle when its min width can't be honored. Tag pills truncate inside
  the card (`FlowLayout` clamps over-long children to the row width) instead of overflowing.
- **In-app sync.** `SyncController` (@MainActor @Observable) runs the off-main `SyncEngine` with
  live progress — page-of-total, a rate-limit banner, an activity feed — and reloads the gallery
  live (coalesced) as pages index. `SyncSheet` collects username + cookie into `CredentialStore`
  (Keychain). Default sync is **index-only** (fast, gentle); EPUBs download per-work on demand or
  via a bulk toggle.
- **The sidebar is a `ScrollView`, not a `List`:** a `List` is NSTableView-backed and reloads
  mid-event when a filter row mutates the model → "reentrant operation in NSTableView delegate".

### Archive folder resolution

Highest priority first: `AO3_ARCHIVE_DIR` env → the folder the user picked (UserDefaults
`archiveFolderPath`, via the toolbar folder menu) → default `~/Documents/ao3archive`. The CLI
uses the same default. Non-sandboxed by design (a personal tool reads a user-chosen folder
directly), so the path is plain — no security-scoped bookmark needed. The folder menu has
**Reveal in Finder**.

### Bundle vs. bare executable

The `.app` bundle (`Packaging/make-app.sh`, non-sandboxed, ad-hoc signed) is the real thing:
launched as a bundle it gets keyboard focus / resize / Dock for free. Run bare via
`swift run AO3ArchiverApp` it needs runtime nudges a bundle provides automatically —
`NSApp.setActivationPolicy(.regular)` + activate (else keystrokes go to the launching terminal),
and inserting `.resizable` on the `NSWindow`. Those nudges are belt-and-suspenders for the bundle.

---

## 8. Testing

Full **Xcode is installed**, so two runners exercise the same assertions against the same
fixtures:

- **`swift test`** — the swift-testing suite in `Tests/AO3KitTests/` (parser, downloader, Store,
  gallery model).
- **`swift run selftest`** — the framework-free equivalent (same assertions, same fixtures), which
  also runs under Command-Line-Tools-only toolchains where `swift test` can't import `Testing`.

Keep the two **in lockstep** when changing the parser, store, or model.

- **Parser selectors are pinned to real captured AO3 HTML** in `Tests/AO3KitTests/Fixtures/`
  (works listing, bookmarks page, series card, series page). When AO3 markup drifts, update the
  fixture and the expectations together. **Fail soft per-field** — one bad card must never abort
  a whole page.
- **The store/sync logic** (idempotency, stale-detection, FTS, series expansion, the re-bookmark
  constraint) and **the whole gallery model** (fan-out-safe join, tri-state include/exclude,
  ranges, derived filters, preset round-trip, sort, memoization, **20k scale + per-recompute
  budget**, parallel==serial facets) are covered — no network, no rendering.
- **Verification ceiling is `swift build`** for the views: the headless environment compiles
  SwiftUI but can't render it, so the view layer is compile-verified only and the user confirms
  visuals. Don't `swift run AO3ArchiverApp` as a check — it needs a window server and hangs
  headlessly.

---

## 9. Conventions

- **Built from scratch** — references document AO3 behaviour only; no vendored code.
- **All network access goes through `AO3Client`;** all branching logic lives in `AO3Kit`, not Views.
- **Parser fails soft per-field;** selectors pinned to fixtures.
- **Honest User-Agent** with contact `syrtis@sysd.info` — no forged browser UA.
- **Politeness is non-negotiable:** bounded defaults, single-flight, respect 429.

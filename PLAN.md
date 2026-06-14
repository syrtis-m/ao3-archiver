# AO3 Archiver — Build Plan

A native macOS app that backs up your AO3 bookmarks as `.epub` files on disk, with a
fast, dark, liquid-glass gallery that mirrors AO3's bookmarks UI — but with better,
fully-local filtering.

> **Guiding principle — built from scratch.** This is an original codebase. Existing
> tools (`ao3_api`, `ao3downloader`, and various bookmark scrapers) are treated only as
> *documentation of AO3's behavior* — the download URL shape, the 429 rate-limit
> handling, the bookmark pagination, which fields live on a card. We learn those facts,
> then write our own client, parser, rate limiter, schema, and UI. No vendored code, no
> dependency on their abstractions. Where this plan cites another tool, it's citing a
> fact about AO3, not borrowing an implementation.

---

## 1. Goals & non-goals

**Goals**
- Archive bookmarked works as real `.epub` files in a folder you control.
- Work **with** a session cookie (private/restricted bookmarks, locked works) and
  **without** one (public bookmarks only).
- A gallery that mimics AO3's bookmarks interface, with **filtering parity** plus
  improvements (instant, multi-facet, local).
- Dark-mode **liquid-glass** UI that is **snappy** — sub-frame filtering, no spinners
  while browsing.
- SQLite as the metadata store; EPUBs live on the filesystem.

**Non-goals (v1)**
- Not a general AO3 reader/commenter/poster. Read-only backup + browse.
- Not a scraper of *other people's* full libraries or bulk dataset creation (against
  AO3 policy). Scope is **your own bookmarks**.
- No EPUB *construction* — AO3 renders EPUBs server-side; we download them as-is.

---

## 2. Ethics, ToS & rate-limiting (read first — this shapes the design)

AO3 has **no public API**; everything is HTML scraping. The Org explicitly rate-limits
and monitors for abusive scraping, and returns **HTTP 429 "Retry later"** when you go
too fast. Backing up your own bookmarks is explicitly permitted ("fans backing up
works"); bulk dataset scraping is not. Design implications:

- **Single-threaded, polite, default-slow.** One request at a time. Target a
  conservative default (~1 request every 3–5 s; user-tunable). No parallel downloads.
- **Respect 429.** On 429, read AO3's requested wait and sleep at least that long with
  jitter and exponential backoff. Never hammer.
- **Cache aggressively.** Never re-download an EPUB whose `updated_at` hasn't changed.
  Re-scrape list pages only on explicit refresh.
- **Identify honestly.** A descriptive `User-Agent` (app name + contact), not a forged
  browser string.
- **Local-only.** No telemetry; the session cookie never leaves the machine.

These aren't nice-to-haves — getting them wrong is what gets the tool (or the user's
IP) throttled or blocked.

---

## 3. Tech stack — recommendation

**Recommended: native SwiftUI (macOS 26 "Tahoe") + GRDB (SQLite) + SwiftSoup.**

Rationale:
- **Liquid Glass is Apple's own design system** in macOS 26. Native SwiftUI gives the
  *real* material (`.glassEffect`, glass `Capsule`s, adaptive vibrancy), not a CSS
  approximation. This is the single best reason to go native given the explicit
  liquid-glass requirement.
- **Snappiness:** native list virtualization (`List`/`LazyVGrid`), GRDB + FTS5 give
  microsecond local queries; no JS bridge, no Electron overhead.
- **The backend is light.** Because AO3 generates EPUBs for us, the "scraper" only
  needs to (a) page through bookmark list HTML and (b) resolve a download link. Swift's
  `URLSession` + `SwiftSoup` handle both fine — we don't need Python's scraping
  ecosystem.
- **Files + DB are first-class:** EPUBs to a security-scoped bookmarked folder; GRDB
  for metadata; `NSMetadataQuery`/Spotlight integration is free.

**Alternative considered — Tauri (Rust + web UI):** smaller and cross-platform, Rust
`reqwest`+`scraper` backend is excellent, but Liquid Glass becomes a CSS
`backdrop-filter` imitation rather than the real material, and you lose native list
performance polish. Pick this only if cross-platform (Windows/Linux) becomes a hard
requirement.

**Rejected — Electron:** conflicts directly with "incredibly snappy."

> Decision point flagged for you: **native SwiftUI (recommended) vs. Tauri.** Everything
> below assumes SwiftUI; the data model, AO3 integration, and filter design are
> stack-agnostic and carry over to Tauri unchanged.

---

## 4. Architecture

```
┌───────────────────────────────────────────────────────────────┐
│ SwiftUI App (macOS 26)                                        │
│                                                               │
│  ┌────────────┐   ┌─────────────┐   ┌──────────────────────┐  │
│  │ Gallery /  │   │ Filter      │   │ Work detail / reader │  │
│  │ Grid view  │◄─►│ sidebar     │   │ (open in Books / QL) │  │
│  └────────────┘   └─────────────┘   └──────────────────────┘  │
│         ▲                ▲                                    │
│         │   @Observable view models (in-memory, instant)      │
│         ▼                ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ Store (GRDB / SQLite + FTS5)   — single source of truth  │ │
│  └──────────────────────────────────────────────────────────┘ │
│         ▲                                   ▲                 │
│         │ writes metadata                   │ writes .epub    │
│  ┌──────┴───────────┐              ┌─────────┴──────────────┐ │
│  │ SyncEngine       │              │ FileStore              │ │
│  │ - bookmark pager │              │ - folder bookmark      │ │
│  │ - work parser    │              │ - epub naming/layout   │ │
│  │ - download link  │              │ - cover extraction     │ │
│  └──────┬───────────┘              └────────────────────────┘ │
│         ▼                                                     │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ AO3Client  (URLSession + SwiftSoup)                      │ │
│  │ - cookie auth · rate limiter · 429 backoff · retry       │ │
│  └──────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────┘
```

**Module responsibilities**
- **AO3Client** — the *only* thing that touches the network. Owns the rate limiter,
  429/backoff, retries, cookie injection, and User-Agent. Returns raw HTML / bytes.
- **SyncEngine** — orchestration: page through bookmarks, parse each card, diff against
  the DB, enqueue EPUB downloads, write rows. Resumable and cancelable.
- **Store (GRDB)** — schema, migrations, queries, FTS5. All reads for the UI go here.
- **FileStore** — manages the user-chosen archive folder (security-scoped bookmark),
  EPUB filenames, and cover-image extraction (unzip EPUB, pull `cover.*`).
- **UI layer** — `@Observable` view models hold the *already-loaded* working set in
  memory so filtering never hits disk on the hot path.

---

## 5. Data model (SQLite)

```sql
-- Works (single items: AO3 works and external-work bookmarks). Series are collections
-- and live in their own table below.
CREATE TABLE work (
  id              INTEGER PRIMARY KEY,        -- AO3 work id, or external_works id when kind='external'
  kind            TEXT NOT NULL DEFAULT 'work', -- work | external
  source_path     TEXT NOT NULL,              -- /works/<id> or /external_works/<id>
  external_url    TEXT,                       -- off-site URL for external works (from the AO3 stub page)
  title           TEXT NOT NULL,
  author          TEXT NOT NULL,              -- display; pseud (plain text for external/anon)
  author_url      TEXT,
  summary         TEXT,
  rating          TEXT,                       -- G/T/M/E/Not Rated
  category        TEXT,                       -- F/M, M/M, Gen, ... (JSON array)
  warnings        TEXT,                       -- JSON array (incl. "Choose Not To Use")
  language        TEXT,
  word_count      INTEGER,
  chapters_have   INTEGER,
  chapters_total  INTEGER,                    -- NULL = "?" (WIP unknown length)
  is_complete     INTEGER,                    -- 0/1 derived
  kudos           INTEGER,
  comments        INTEGER,
  bookmarks_count INTEGER,
  hits            INTEGER,
  collections     INTEGER,
  published_at    TEXT,                       -- ISO date
  updated_at      TEXT,                       -- ISO date (drives re-download)
  is_anon         INTEGER DEFAULT 0,
  is_restricted   INTEGER DEFAULT 0,          -- "only registered users"
  series_json     TEXT,                       -- [{id,name,part}]
  -- local archive state
  epub_path       TEXT,                       -- relative to archive root; NULL if not yet downloaded
  epub_updated_at TEXT,                       -- updated_at captured at download time
  cover_path      TEXT,
  download_state  TEXT DEFAULT 'pending',     -- pending|downloaded|failed|stale|deleted_on_ao3
  last_error      TEXT,
  first_seen_at   TEXT,
  last_synced_at  TEXT
);

-- Tag dimensions (normalized for fast facet filtering)
CREATE TABLE tag (
  id    INTEGER PRIMARY KEY,
  type  TEXT NOT NULL,   -- fandom|relationship|character|freeform|warning|category|rating
  name  TEXT NOT NULL,
  UNIQUE(type, name)
);
CREATE TABLE work_tag (
  work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
  tag_id  INTEGER NOT NULL REFERENCES tag(id),
  PRIMARY KEY (work_id, tag_id)
);
CREATE INDEX idx_work_tag_tag ON work_tag(tag_id);

-- Series are collections of works. A bookmarked series is recorded here, and on sync we
-- expand it (fetch /series/<id>, which lists member work blurbs) into `work` rows linked
-- via `series_work`, then enqueue each member work's EPUB.
CREATE TABLE series (
  id            INTEGER PRIMARY KEY,          -- AO3 series id
  title         TEXT NOT NULL,
  author        TEXT,
  summary       TEXT,
  works_count   INTEGER,
  is_complete   INTEGER,
  updated_at    TEXT,
  last_synced_at TEXT
);
CREATE TABLE series_work (
  series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
  work_id   INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
  part      INTEGER,                          -- position in the series
  PRIMARY KEY (series_id, work_id)
);

-- Bookmark-specific facets (the "bookmarks-only" filters AO3 offers). A bookmark targets
-- either a work (incl. external) or a series — `item_kind`/`item_id` is the polymorphic ref.
CREATE TABLE bookmark (
  bookmark_id    INTEGER PRIMARY KEY,         -- AO3 bookmark id (orders "date bookmarked")
  item_kind      TEXT NOT NULL,               -- work | series  (work covers external too)
  item_id        INTEGER NOT NULL,            -- work.id or series.id depending on item_kind
  bookmarked_at  TEXT,
  bookmarker_notes TEXT,
  is_rec         INTEGER DEFAULT 0,           -- "recommendation"
  is_private     INTEGER DEFAULT 0,
  UNIQUE(item_kind, item_id)
);
CREATE TABLE bookmark_tag (   -- the user's *own* bookmark tags (distinct from work tags)
  bookmark_id INTEGER NOT NULL REFERENCES bookmark(bookmark_id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  PRIMARY KEY (bookmark_id, name)
);

-- Full-text search over title/author/summary/tags
CREATE VIRTUAL TABLE work_fts USING fts5(
  title, author, summary, tags, bookmarker_notes,
  content='', tokenize='unicode61 remove_diacritics 2'
);

-- Sync bookkeeping
CREATE TABLE sync_run (
  id INTEGER PRIMARY KEY, started_at TEXT, finished_at TEXT,
  pages_scanned INTEGER, works_new INTEGER, works_updated INTEGER,
  epubs_downloaded INTEGER, status TEXT, message TEXT
);
```

Notes:
- Tags are normalized so facet counts ("Fluff (142)") are a single grouped query.
- `work_fts` powers the search box; rebuilt incrementally on writes.
- `download_state = stale` when AO3's `updated_at` > our `epub_updated_at` → re-download
  candidate. `deleted_on_ao3` when a previously-seen work 404s but we keep the local EPUB.
- **As built in M1:** `work.updated_at` / `epub_updated_at` are stored as the **unix-ts**
  from the card comment (the download cache key), not ISO — comparison is exact and avoids
  parsing human dates. "Needs download" is computed by query (`epub_path IS NULL OR
  updated_at > epub_updated_at`) rather than trusting a stored `stale` flag, so an
  interrupted sync resumes correctly; `download_state` is a status cache for the UI. The
  v1 schema implements the columns the parser actually populates today; the remaining §5
  columns (published_at, is_anon, is_restricted, collections, series_json, cover_path) come
  in later migrations as the parser learns to fill them.

**On-disk layout**
```
<ArchiveRoot>/
  works/<work_id> - <sanitized title>.epub
  covers/<work_id>.jpg
  archive.sqlite
```
EPUB filename keeps the work id as a stable key; title is cosmetic.

---

## 6. AO3 integration details

### Auth
- **No cookie:** fetch `/users/<name>/bookmarks` for public bookmarks only.
- **With cookie:** user pastes their `_otwarchive_session` cookie value (Settings →
  "Sign in with session cookie", with copy-paste instructions from browser devtools).
  Store it in the **macOS Keychain**, never in the DB or logs. Send it on every request.
  Detect expiry (login redirect / missing username) and prompt to refresh.
- We deliberately **don't** store the AO3 password or automate the login form (captcha /
  ToS friction); cookie paste is the standard, robust approach used by existing tools.

### Listing bookmarks
- URL: `https://archiveofourown.org/users/<username>/bookmarks?page=<n>`.
- Each page = up to 20 bookmark "cards." Parse each card with SwiftSoup:
  title, work id (`/works/<id>`), author, fandoms, the rating/warning/category symbols,
  relationship/character/freeform tags, word count, chapters, kudos/comments/bookmarks/
  hits, last-updated date, series, **and** the bookmark-specific bits (bookmarker tags,
  notes, rec flag, private flag).
- Paginate until the "Next" link disappears. Optionally accept AO3's own filtered
  bookmark URL (so you can scope a sync to e.g. one fandom).

### Downloading the EPUB
- AO3 renders EPUBs server-side. On a work page, the **Download** menu contains a link
  shaped like:
  `https://archiveofourown.org/downloads/<work_id>/<slug>.epub?updated_at=<unix_ts>`
- Resolve it by fetching the work page and reading the `.download` menu's EPUB `href`
  (don't hardcode the slug). Then GET that URL and stream bytes to
  `works/<id> - <title>.epub`.
- The `updated_at` query param is the cache key — if unchanged since last download, skip.
- Restricted works require the cookie; without it they 302 to login → mark
  `download_state = failed, last_error = "requires login"`.

### Rate limiting & resilience
- Central **token-bucket limiter** in AO3Client (default ~1 req / 4 s, user-tunable).
- **429 handling:** parse the retry hint, sleep ≥ that with jitter, exponential backoff
  on repeats, surface a non-blocking "AO3 asked us to slow down" status.
- Resumable: every parsed page and downloaded EPUB is committed immediately, so a
  cancelled/crashed sync resumes without re-fetching.

---

## 7. Filtering — parity with AO3 + improvements

The win of storing everything locally: we can replicate **every** AO3 work/bookmark
filter and make them all instant and freely combinable.

**Work filters (parity with AO3's filter sidebar):**
- Rating (G/T/M/E/Not Rated)
- Archive Warnings (incl. "Choose Not To Use", "No Warnings Apply")
- Categories (F/F, F/M, M/M, Gen, Multi, Other)
- Fandoms (multi-select, with counts)
- Characters / Relationships / Additional (freeform) tags — include **and** exclude
- Crossovers (include/exclude/only)
- Completion status (complete / WIP)
- Word count range (min/max)
- Date updated range; ~~date published range~~ *(out of scope: the bookmarks listing blurb
  exposes only one `p.datetime` — the **updated** date — so there's no published date to range
  on without an extra per-work fetch. Date-updated + date-bookmarked ranges ship; date-published
  would need a hydration pass we deliberately avoid for politeness.)*
- Language
- Hits / Kudos / Comments / Bookmarks count ranges
- Free-text search across title, author, summary, tags

**Bookmark-specific filters (parity with AO3's bookmark filters):**
- Bookmark type — AO3 work / **external work** / series (improvement: AO3 doesn't let you
  cleanly isolate these; we can, e.g. "show only my external bookmarks")
- Your bookmark tags (multi-select include/exclude)
- Rec'd only
- With/without bookmarker notes
- Private / public bookmarks
- Date bookmarked range

**Sort:** by date bookmarked, date updated, title, author, word count, kudos, hits,
comments, bookmarks count — all shipped. *Date posted* is out of scope (no published date in
the listing, as above). Still TODO (improvement): **download status** and **local file size**
(needs epub byte size stored at download — the one M3.5 leftover).

**Improvements beyond AO3:**
- All facets combine with live counts (faceted search), tag include **and** exclude
  simultaneously, saved filter presets ("Smart Bookmarks"), full-text over summaries
  *and your own notes*, and filtering by **archive state** (not-yet-downloaded, stale,
  failed) — things AO3 can't know.

**Implementation:** filters compile to a single parametrized SQL `WHERE` over indexed
columns + `work_tag` joins + FTS `MATCH`. For "incredibly snappy," the active working
set is also held in memory in the view model, so typeahead/facet toggles re-filter in
RAM and only fall back to SQL when the result set is huge.

---

## 8. UI / UX — dark liquid glass, snappy

**Layout (mirrors AO3 bookmarks):**
- **Left:** glass filter sidebar — collapsible facet sections with live counts, exactly
  the AO3 ordering (Sort & Include / Exclude / More options).
- **Center:** the gallery — a list of rich **metadata cards** (AO3-style: title, author,
  fandoms, tag pills, stats row, summary, your tags/notes) with a comfortable/compact
  density toggle. *(Revised in M2: the originally-planned cover grid was dropped — AO3
  EPUBs contain no cover art, and a book cover is the wrong metaphor for browsing fic;
  what a reader scans is the metadata, so that's what the card foregrounds.)*
- **Top:** glass search bar + sort control + sync button with progress.
- **Detail:** work sheet with full metadata, "Open in Books / Quick Look," reveal-in-
  Finder, re-download, and "view on AO3."

**Liquid Glass specifics (macOS 26):**
- Real `.glassEffect()` / `glassEffectContainer` materials on sidebar, top bar, and
  cards; vibrant text over content. Dark mode as the default appearance.
- Subtle depth: glass toolbars float over the scrolling gallery; tag pills are glass
  capsules; selection uses tinted glass, not flat fills.

**Snappiness rules (non-negotiable for the feel):**
- Virtualized lists/grids; never render off-screen cards.
- In-memory working set → filter/sort/typeahead is pure compute, no disk on hot path.
- Async, cancelable image loading with a memory+disk thumbnail cache (downsample covers
  to display size).
- Debounced search (FTS off the main actor), but facet toggles apply instantly.
- All network/sync work off the main actor; the UI never blocks on AO3.

---

## 9. Sync / refresh lifecycle

1. **Index sync** (fast): page through bookmarks, upsert metadata, diff. Each card is
   classified by `kind`: works/external → `work`, series → `series`. External works keep
   a record (and, optionally, a follow-up fetch of the AO3 stub page for the off-site URL)
   but are never queued for EPUB download.
2. **Series expansion** (rate-limited): for each bookmarked series, fetch `/series/<id>`,
   parse its member work blurbs (same `BlurbParser`), upsert them into `work`, link via
   `series_work`, and enqueue each member for content sync. A series bookmark thus backs
   up the whole nested collection.
3. **Content sync** (slow, rate-limited): download EPUBs for `pending`/`stale` works in
   a background queue with the limiter; commit each on completion.
4. **Reconcile:** works no longer in bookmarks → mark `removed_from_bookmarks` (keep
   local EPUB unless user prunes). Works that 404 → `deleted_on_ao3` (your backup is now
   the only copy — highlight these).
5. Manual "Refresh bookmarks" + optional scheduled background sync (opt-in).

**Bookmark-shape realities (confirmed against a real public bookmarks page):**
- A bookmarks page mixes **work bookmarks** (`/works/…`), **series bookmarks**
  (`/series/…`), and **external-work bookmarks** (`/external_works/…`). Only AO3 works
  have a downloadable EPUB. M1 must classify each card and surface counts like "3
  external / 2 series bookmarks can't be archived as EPUB" rather than silently dropping
  them (M0 silently skips non-work cards — acceptable for the spike only).
- Each bookmark card carries **two** dates: the work's updated date (header) and the
  **bookmark date** (in the `div.user.module.group` bookmarker section). Capture both;
  the bookmark date drives "sort by date bookmarked".
- Bookmarker tags/notes live in that same bookmarker section (`ul.meta.tags`,
  `blockquote.userstuff.notes`) and are simply absent when the user didn't add any.

---

## 10. Milestones

> **V1 is shipped.** M0–M4 are complete: the de-risking spike, the polite sync engine + SQLite
> store, the Liquid Glass gallery, full filter parity, and a real double-clickable `.app` with
> in-app sync. The tool does what §1 set out to do — back up your AO3 bookmarks as EPUBs and
> browse/filter them locally, snappily, offline. M5 (hardening) and the small leftovers called
> out below are **post-V1**, not blockers.

- **M0 — Spike (de-risk): ✅ done.** `AO3Kit` (`AO3Client` rate limiter + 429/5xx
  backoff + cookie auth, `BlurbParser`, `WorkDownloader`) plus an `ao3archiver` CLI that
  fetches a listing, parses cards, and downloads one EPUB through the limiter. Parser
  pinned to real captured HTML; verified end-to-end against live AO3. Selectors were
  derived from real markup — notably the download href carries `?updated_at=`, so the
  EPUB link must be matched on the path before `?`, not an ends-with selector.
- **M1 — Core sync + store: ✅ done.** `Store` (GRDB schema/migrations + FTS5, idempotent
  upserts that preserve archive state), `FileStore` (archive folder + EPUB layout),
  `SyncEngine` (bounded paginated index sync → series expansion → resumable content-download
  queue, all through the one polite client). Parser extended for bookmark id / bookmark date
  / rec / private / series `Works:` count + pagination `Next`. Verified offline against
  fixtures (idempotency, stale-detection, FTS, series expansion) and live end-to-end
  (pagination, series expansion with member-dedup, resumable downloads of valid EPUBs).
  Deviations from §5 noted there: `work.updated_at` stored as the unix-ts cache key (not
  ISO); the security-scoped **folder bookmark** is deferred to M2 (it needs the app sandbox,
  which a SwiftPM CLI can't hold — M1's `FileStore` is plain directory management).
- **M2 — Gallery MVP: ✅ done.** SwiftUI app (`AO3ArchiverApp`) over the M1 store: dark
  Liquid Glass (`.glassEffect`), glass filter sidebar with live facet counts (bookmark
  type / rating / completion / download state / fandom), `.searchable` full-text, sort
  control, and a detail inspector (open in Books, reveal in Finder, view on AO3). The
  snappy in-memory pipeline is real and **unit-tested** in `AO3Kit`: `WorkListItem`,
  `fetchAllListItems()` (fan-out-safe join), and a pure `GalleryFilter`/`GallerySort`/
  `Facets` engine behind an `@Observable GalleryViewModel` — filter/sort/search is pure
  compute over the in-memory working set. **Dropped the cover grid:** AO3 EPUBs carry no
  cover art and a cover is the wrong metaphor for browsing fic — the centerpiece is a rich
  **metadata card** (title, author, fandoms, tag pills, stats, summary, your tags/notes),
  with a comfortable/compact density toggle. *Verification caveat:* the headless build
  environment can compile (`swift build`) but not run/render the SwiftUI layer, so the
  views are compile-verified only; all logic below the SwiftUI line is test-covered.
  *Refinements added through user testing:* AO3 colour-coded corner symbols (rating /
  category-with-gradients / warnings / completion); **tri-state include/exclude** facets
  (type / rating / category / fandom) — click to include, again to exclude — instead of
  AO3's duplicated filter lists; single-select **segmented** completion & download; live
  search; series detail lists member works in order; tags grouped by type (relationships
  split out) and capped ~15. The sidebar is a `ScrollView`, not a `List` (a List is
  NSTableView-backed and reloads mid-event when the filter changes → reentrancy). As a bare
  `swift run` executable the app needs runtime nudges (`.regular` activation policy for
  keyboard focus; force `.resizable` on the window) that a real `.app` bundle would make
  unnecessary — packaging is M4.
### M3 — Full filter parity (done)

Goal: every filter in §7 that the **bookmarks listing actually exposes**, include/exclude,
ranges, saved presets, snappy at real scale. Built on the M3.0 memoized working set (computed
once per (filter, sort, allItems) change, proven by a 2000-item scale test in both runners).
(Out of scope, by data availability: date-*published* range and date-posted sort — the
listing blurb has only the updated date; getting published dates would need a per-work
hydration pass we avoid for politeness.)

- **M3.0 — Perf foundation (done).** `GalleryViewModel` memoizes `visibleItems` + all facet
  counts via an `@ObservationIgnored` cache keyed by `MemoKey(filter, sort, gen)`; a
  `recomputeCount` lets tests prove the memo holds across repeated access and recomputes
  exactly once per change. Scale test: 2000 synthetic items.
- **M3.1 — Generic keyed tag-dimension facets (done).** One `FacetDimension` enum + one
  `WorkListItem.values(for:)` extractor drives the filter (`include`/`exclude` as
  `[FacetDimension: Set<String>]`), the facet counts, the view model
  (`facets(for:)`/`state(_:_:)`/`cycle(_:_:)`), and the sidebar. All ten dimensions —
  bookmark type, rating, category, warnings, language, fandom, relationships, characters,
  additional (freeform) tags, your tags — are tri-state include/exclude with live counts.
  Invariant: an emptied dimension drops its key (never an empty set). Single-select
  completion/download stay segmented controls.
- **M3.2 — High-cardinality facet UI (done).** Typeahead text field on the high-cardinality
  dimensions (fandom/relationship/character/freeform/your-tags); filters the full facet list
  *before* the render cap so rare values stay findable.
- **M3.3 — Range filters (done, no migration).** One `RangeField` + `NumericBound` (min/max)
  covers word count / kudos / comments / bookmarks / hits and **date updated / date
  bookmarked**. `bookmarkedAt` is parsed to a `Date` once at load (shared POSIX formatter,
  fail-soft) — no schema migration, because all filtering runs in memory (a `*_ts` column
  would be written and never read; add it only if range filtering is ever pushed into SQL).
  A nil-valued item (series → no word count) drops out of an active range.
- **M3.4 — Derived & bookmark filters (done).** `TriFilter` (any/yes/no) over crossover
  (fandom count > 1), rec'd, with/without notes, private/public; language is a facet dim.
- **M3.5 — More sorts (done for V1).** Added comments + bookmarks-count sorts. A local
  file-size / download-status sort is the one deferred item (needs epub byte size stored at
  download) — small, post-V1.
- **M3.6 — Saved presets ("Smart Bookmarks") (done).** `GalleryFilter`/`GallerySort` are
  `Codable`; a `filter_preset` table (migration v3) stores the JSON-encoded `FilterPreset`
  (name + filter + sort); sidebar save/apply/delete, applied instantly. Note: a
  `[FacetDimension: Set<String>]` encodes as a JSON array (Swift only uses String/Int keys as
  object keys), which round-trips fine.

### M4 — Packaging + in-app sync: ✅ done (ships V1)

- **M4.1 — Real `.app` bundle: ✅ done.** `Packaging/make-app.sh` assembles a double-clickable
  "AO3 Archiver.app" (Info.plist + bundle id + ad-hoc signature). **Non-sandboxed** by
  design (personal tool reads a user-chosen folder directly; signing/notarization is a
  distribution concern). Launched as a bundle it's a normal foreground app, so the
  bare-`swift run` runtime nudges become belt-and-suspenders. Liquid-glass **app icon** done
  (CoreGraphics, headless: `Packaging/IconGen.swift` + `make-icon.sh`).
- **M4.2 — In-app sync: ✅ done.** `SyncController` (@MainActor @Observable) runs the tested
  `SyncEngine` off the main actor; `SyncSheet` collects username/cookie and shows **live
  progress** — page-of-total bar (`BlurbParser.lastPageNumber`), a **rate-limit banner**
  (`AO3Client.onRateLimit`, so a backoff doesn't look like a stall), and a torrent-style
  activity feed. **M4.4 (cookie in Keychain) folded in** (`CredentialStore`). **Index is
  separated from download**: default sync is index-only (lightweight bookmark records per
  page, committed live so the gallery grows as it indexes and partial/cancelled runs are kept);
  EPUBs download **per-work on demand** (detail panel) or via a bulk toggle. Politeness interval
  is user-adjustable. **Index is resumable** — the next-page URL is persisted in a `meta` table,
  so a run throttled at page 15 of ~130 resumes there instead of restarting (`SyncEngine.Options
  .resumeIndex` + `resumeKey`); a **Quick sync** grabs just the latest 3 pages for catch-up.
- **M4.3 — Folder picker: ✅ done.** `NSOpenPanel` → plain path in UserDefaults (non-sandboxed,
  no security-scoped bookmark needed); `AO3_ARCHIVE_DIR` overrides. Default is the **visible**
  `~/Documents/ao3archive` (shared by app + CLI), with a **Reveal in Finder** folder menu. Also
  fixed the double-clicked "SQLite error 14" (create the folder before opening the db).
- **M4.5 — Glass polish: ✅ done for V1.** Dark Liquid Glass throughout (`.glassEffect`, glass
  buttons/pills, the liquid-glass app icon). Further polish (`glassEffectContainer` grouping,
  animated filter transitions, refined selection/hover) is optional post-V1 nicety, not a gap.
  (No thumbnail cache — AO3 EPUBs have no covers.)

### M5 — Hardening (post-V1, future)

Not part of V1; captured here as the natural next iteration if the tool grows beyond personal use.

- **M5.1 — Cookie expiry UX.** Detect login redirect / missing username → pause sync, prompt
  re-paste, resume.
- **M5.2 — Reconcile & deleted-work highlighting.** Works removed from bookmarks → mark; 404
  → `deleted_on_ao3`, highlight "your backup is the only copy."
- **M5.3 — Scheduled background sync** (opt-in), politeness-respecting.
- **M5.4 — Export/import** the archive folder; backup integrity checks.
- **M5.5 — Large-library perf pass** (10k+: fall back to an FTS5/SQL search path when result
  sets are huge — the in-memory pipeline is already memoized and proven snappy at 2k).
- **M5.6 — Local file-size / download-status sort** (the one deferred M3 sort; store epub byte
  size at download).

---

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| AO3 HTML changes break the parser | Isolate all selectors in one `Parser` type with snapshot tests against saved fixture HTML; fail soft per-field. |
| Rate limiting / IP throttle | Conservative defaults, 429 backoff, single-threaded, aggressive caching (§2). |
| Cookie expiry mid-sync | Detect login redirect, pause sync, prompt to re-paste; resume. |
| Large libraries (10k+ bookmarks) | Virtualized UI, indexed SQL, paged + resumable sync, memoized in-memory filter pipeline (proven snappy at 2k; FTS5/SQL fallback for huge sets is M5.5). |
| No cover art in AO3 EPUBs | Resolved by design: the gallery is **metadata cards** (title/author/tags/stats/summary), not a cover grid — no cover extraction needed. |
| Restricted/anon works | Require cookie; mark clearly when unavailable; never crash a sync over one work. |
| ToS / ethics | Scope to user's own bookmarks; polite client; honest UA; local-only; no bulk dataset features. |

---

## 12. Decisions (resolved for V1)

These were the pre-build open questions; here's what V1 settled on.

1. **Stack:** ✅ native SwiftUI (macOS 26, real Liquid Glass) + GRDB/SQLite + SwiftSoup.
2. **Scope:** ✅ bookmarks only for V1 (works/marked-for-later/collections are the same
   plumbing — just more list sources — and are a natural post-V1 add).
3. **Formats:** ✅ EPUB only (AO3 renders it server-side; other formats are a follow-up).
4. **Cookie UX:** ✅ manual paste, stored in the Keychain (simple, robust; an embedded WebView
   login is a possible post-V1 smoothing).
5. **Scheduled background backups:** ✅ manual refresh for V1 (in-app sync with live progress +
   resumable index); a scheduled opt-in sync is post-V1 (M5.3).
```

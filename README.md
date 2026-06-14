# AO3 Archiver

A native macOS app (in progress) that backs up your AO3 bookmarks as `.epub` files with
a fast, dark, liquid-glass gallery and full local filtering. See [PLAN.md](PLAN.md) for
the full design and roadmap.

## Status: M2 gallery + M3.0 perf + M4 packaging (in progress)

M0 de-risked the core mechanics; M1 built the backup engine; **M2** added the dark Liquid
Glass gallery; **M3.0** memoized the filter pipeline for scale; **M4 (packaging)** turned it
into a real, double-clickable `.app` you can **sync and browse entirely from the GUI** — no
terminal. You can run it as a CLI (sync) and/or the SwiftUI app (sync + browse):

- **`AO3Kit`** — the reusable core the SwiftUI app will sit on:
  - `AO3Client` — the only networked component. Polite single-flight **rate limiter**,
    **429 / Retry-After backoff**, 5xx + timeout retries, explicit session-cookie
    injection, honest User-Agent. Follows AO3's download redirect automatically.
  - `BlurbParser` — parses AO3 listing HTML (works search / tag pages / **bookmarks** /
    **series pages**, same markup) into `WorkBlurb`s. Classifies each card by `kind` —
    **work**, **external** (off-site, no EPUB), or **series** — and captures the
    bookmark-specific bits (bookmark id, bookmark date, rec/private, the bookmarker's tags
    & notes) plus pagination. Selectors pinned to real fetched markup.
  - `Store` — the SQLite metadata store (GRDB + **FTS5**): schema/migrations, **idempotent**
    upserts that preserve local archive state, a resumable download-queue query, and
    full-text search. Works, external works, series, and bookmarks are normalized with a
    tag index for fast faceting.
  - `FileStore` — owns the archive folder and the `works/<id> - <title>.epub` layout.
  - `SyncEngine` — orchestrates a **bounded, resumable** run: page through bookmarks →
    ingest every card → expand bookmarked series into member works → download EPUBs through
    the limiter, committing each immediately.
  - `WorkDownloader` — resolves the server-rendered EPUB link and downloads it, validating
    the ZIP/EPUB magic bytes.
  - `GalleryModel` — the gallery's read/filter/sort layer (kept below the SwiftUI line so
    it's unit-tested): `WorkListItem`, a fan-out-safe `fetchAllListItems()` join, and a pure
    `GalleryFilter`/`GallerySort`/`Facets` engine behind an `@Observable` view model.
- **`ao3archiver`** — CLI that runs a real bounded sync into a SQLite DB + archive folder.
- **`AO3ArchiverApp`** — the SwiftUI gallery, with **in-app sync**: a Sync sheet takes your
  username + `_otwarchive_session` cookie (stored in the **Keychain**) and runs the engine
  with live progress — page-of-total bar, a rate-limit banner (so a backoff doesn't look like
  a stall), and an activity feed; the bookmark list builds up **live** as it indexes. Index
  is separated from download: by default it just records the lightweight metadata (fast,
  gentle on AO3), and you **download EPUBs per-work on demand** from a work's detail panel (or
  enable bulk download). A folder menu (Reveal in Finder / Choose Folder) manages the archive
  location (default `~/Documents/ao3archive`). Dark Liquid Glass throughout, with a glass
  filter sidebar with live facet counts, live search, sort, and a detail inspector (open in
  Books, reveal in Finder, view on AO3; series show their member works in order). The centerpiece
  is a rich **metadata card** — title, author, AO3 colour-coded symbols (rating / category /
  warnings / completion), tag pills grouped by type, stats, summary, and your own bookmark
  tags/notes — *not* a book cover (AO3 EPUBs have none, and metadata is what you browse on).
  Facets (bookmark type / rating / category / fandom) are **tri-state**: click to include,
  again to exclude, again to clear — include and exclude in one list. Completion and download
  are single-select. The pipeline is in-memory, so filtering/search/sort is instant.

### Run it

No credentials (public demo listing — Good Omens tag):

```sh
swift run ao3archiver
```

Your own bookmarks, authenticated:

```sh
export AO3_USERNAME="your_ao3_username"
export AO3_SESSION_COOKIE="...value of the _otwarchive_session cookie..."
swift run ao3archiver        # backs up the first 2 pages / 3 EPUBs by default
```

Sync is **bounded by default** (2 pages, 3 downloads) so a casual run never crawls a large
account. To back up a whole account, the index pass has to reach every page at least once
to enqueue its works — raise `AO3_MAX_PAGES` high enough to cover the account, then bound
the slow part (downloads) and run repeatedly:

```sh
# Pass 1+: index every page once (cheap), download a polite batch each run.
AO3_MAX_PAGES=999 AO3_MAX_DOWNLOADS=50 swift run ao3archiver   # repeat until none remain
```

Downloads are **resumable**: each run skips works already on disk (unless AO3 shows a newer
`updated_at`, which re-queues them) and **retries** anything that previously failed — so if
you first run anonymously, works that needed a login are picked up once you add your cookie.
Note the *index* pass re-reads pages 1…`AO3_MAX_PAGES` each run; it's downloads, not page
fetches, that accumulate across runs — so set `AO3_MAX_PAGES` wide rather than expecting
deep pages to be reached a few at a time.

### The app (sync + browse)

Build a real, double-clickable app (needs the macOS 26 SDK / Xcode 26):

```sh
./Packaging/make-icon.sh    # once: render the app icon → AppIcon.icns
./Packaging/make-app.sh     # assemble "build/AO3 Archiver.app"
open "build/AO3 Archiver.app"
```

Or run it unbundled for dev: `swift run AO3ArchiverApp` (works, but as a bare executable it
needs runtime nudges for keyboard focus/resize; the bundle is the real thing).

In the app: click the **folder menu** to choose your archive folder (default
`~/Documents/ao3archive`), then **Sync** — paste your AO3 username and (optionally) your
`_otwarchive_session` cookie, and watch the bookmark list build live. By default sync is
**index-only** (just the metadata list, fast and gentle); flip on "Download EPUBs" for bulk,
or open any work and hit **Download EPUB** to grab one on demand. Then browse: a glass filter
sidebar with live counts, search, sort, and the metadata-card gallery.

Getting the cookie: log in to AO3 in your browser → DevTools → Application/Storage →
Cookies → `https://archiveofourown.org` → copy the **value** of `_otwarchive_session`. The
app stores it in the macOS **Keychain**; it's only ever sent to AO3.

### Configuration (environment variables)

| Variable             | Default                          | Purpose |
|----------------------|----------------------------------|---------|
| `AO3_USERNAME`       | —                                | Your AO3 username (enables bookmarks). |
| `AO3_SESSION_COOKIE` | —                                | `_otwarchive_session` value for private/restricted content. |
| `AO3_ARCHIVE_DIR`    | `~/Documents/ao3archive`         | Holds `archive.sqlite` + the `works/` EPUBs. |
| `AO3_MIN_INTERVAL`   | `4`                              | Minimum seconds between requests (politeness). |
| `AO3_USER_AGENT`     | `ao3-archiver/0.1 (… syrtis@sysd.info)` | Sent on every request. |
| `AO3_LIST_PATH`      | bookmarks, else demo             | Override the listing path (e.g. a filtered bookmarks URL). |
| `AO3_MAX_PAGES`      | `2`                              | Max bookmark pages fetched per run. |
| `AO3_MAX_DOWNLOADS`  | `3`                              | Max EPUBs downloaded per run. |
| `AO3_EXPAND_SERIES`  | `1`                              | Expand bookmarked series into member works (`0` to skip). |

### Tests

The parser is pinned to **real captured AO3 HTML** in `Tests/AO3KitTests/Fixtures/`
(works listing, bookmarks page, series card, series page). The store/sync logic
(idempotency, stale-detection, FTS, series expansion) **and the gallery model** (fan-out-safe
join, composing filters, sort, facets) are exercised against those same fixtures with a temp
database — no network, no rendering.

- Full Xcode: `swift test` (swift-testing suite — 31 tests, 4 suites).
- Command Line Tools only (no Xcode): `swift run selftest` — equivalent assertions (120
  checks), no test framework needed.

> The SwiftUI gallery is **compile-verified** (`swift build`) but its rendering isn't
> automatically tested — all of its logic lives in the unit-tested `GalleryModel`, so the
> views are a thin, dumb skin over verified behavior.

## Requirements

- macOS 26 (Tahoe) + Xcode 26 to build the SwiftUI app (Liquid Glass); the CLI/library use
  the Swift 6.3 toolchain. Package deployment target is macOS 26.
- Dependencies: [SwiftSoup](https://github.com/scinfu/SwiftSoup) for HTML parsing,
  [GRDB](https://github.com/groue/GRDB.swift) for the SQLite store (FTS5).

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free to use, modify, and share for any
**noncommercial** purpose (personal use, hobby projects, research, nonprofits). Commercial
use is not granted. This is a software-native license chosen over CC BY-NC-SA (which
Creative Commons advises against for code); the noncommercial restriction reflects AO3's own
nonprofit, transformative-works ethos. Dependencies remain under their own MIT licenses.

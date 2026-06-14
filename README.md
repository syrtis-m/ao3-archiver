# AO3 Archiver

A native macOS app (in progress) that backs up your AO3 bookmarks as `.epub` files with
a fast, dark, liquid-glass gallery and full local filtering. See [PLAN.md](PLAN.md) for
the full design and roadmap.

## Status: M2 — gallery MVP (done)

M0 de-risked the core mechanics; M1 built the backup engine; **M2** adds the dark, Liquid
Glass SwiftUI gallery over it. Runnable today as a CLI (sync) + a SwiftUI app (browse):

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
- **`AO3ArchiverApp`** — the **M2 SwiftUI gallery**: dark Liquid Glass, a glass filter
  sidebar with live facet counts (bookmark type / rating / completion / download state /
  fandom), full-text search, sort, and a detail inspector (open in Books, reveal in Finder,
  view on AO3). The centerpiece is a rich **metadata card** — title, author, fandoms, tag
  pills, stats, summary, and your own bookmark tags/notes — *not* a book cover (AO3 EPUBs
  have none, and metadata is what you actually browse on).

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

### Browse it (the app)

Once you've synced, open the gallery over the same archive folder:

```sh
AO3_ARCHIVE_DIR=/path/to/archive swift run AO3ArchiverApp
```

A dark Liquid Glass window with a filter sidebar (bookmark type, rating, completion,
download state, fandom — each with live counts), a search field, sort control, and a
metadata-card gallery; click a card for the detail inspector. The app is **read-only** in
M2 (syncing stays in the CLI). Building the app needs the macOS 26 SDK (Xcode 26).

Getting the cookie: log in to AO3 in your browser → DevTools → Application/Storage →
Cookies → `https://archiveofourown.org` → copy the **value** of `_otwarchive_session`.
It's only ever sent to AO3 and never written to disk by this tool.

### Configuration (environment variables)

| Variable             | Default                          | Purpose |
|----------------------|----------------------------------|---------|
| `AO3_USERNAME`       | —                                | Your AO3 username (enables bookmarks). |
| `AO3_SESSION_COOKIE` | —                                | `_otwarchive_session` value for private/restricted content. |
| `AO3_ARCHIVE_DIR`    | `./archive`                      | Holds `archive.sqlite` + the `works/` EPUBs. |
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

- Full Xcode: `swift test` (swift-testing suite — 24 tests, 4 suites).
- Command Line Tools only (no Xcode): `swift run selftest` — equivalent assertions (98
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

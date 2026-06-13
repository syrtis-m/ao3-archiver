# AO3 Archiver

A native macOS app (in progress) that backs up your AO3 bookmarks as `.epub` files with
a fast, dark, liquid-glass gallery and full local filtering. See [PLAN.md](PLAN.md) for
the full design and roadmap.

## Status: M0 — core spike (done)

M0 de-risks the riskiest mechanics before any UI is built, and is runnable today as a
CLI:

- **`AO3Kit`** — the reusable core the SwiftUI app will sit on:
  - `AO3Client` — the only networked component. Polite single-flight **rate limiter**,
    **429 / Retry-After backoff**, 5xx + timeout retries, explicit session-cookie
    injection, honest User-Agent. Follows AO3's download redirect automatically.
  - `BlurbParser` — parses AO3 listing HTML (works search / tag pages / **bookmarks**,
    same markup) into `WorkBlurb`s. Selectors derived from real fetched markup. Classifies
    each card by `kind` — **work**, **external** (`/external_works/…`, off-site, no EPUB),
    or **series** — so external and series bookmarks are recorded and filterable, never
    silently dropped.
  - `WorkDownloader` — resolves the server-rendered EPUB link from a work page and
    downloads it, validating the ZIP/EPUB magic bytes. Only `.work` cards are downloaded.
- **`ao3archiver`** — CLI that runs the whole pipeline end-to-end: fetch a listing →
  parse → download one EPUB to disk.

### Run it

No credentials (public demo listing — Good Omens tag):

```sh
swift run ao3archiver
```

Your own bookmarks, authenticated:

```sh
export AO3_USERNAME="your_ao3_username"
export AO3_SESSION_COOKIE="...value of the _otwarchive_session cookie..."
swift run ao3archiver
```

Getting the cookie: log in to AO3 in your browser → DevTools → Application/Storage →
Cookies → `https://archiveofourown.org` → copy the **value** of `_otwarchive_session`.
It's only ever sent to AO3 and never written to disk by this tool.

### Configuration (environment variables)

| Variable             | Default                          | Purpose |
|----------------------|----------------------------------|---------|
| `AO3_USERNAME`       | —                                | Your AO3 username (enables bookmarks). |
| `AO3_SESSION_COOKIE` | —                                | `_otwarchive_session` value for private/restricted content. |
| `AO3_ARCHIVE_DIR`    | `./archive`                      | Where `.epub` files are written. |
| `AO3_MIN_INTERVAL`   | `4`                              | Minimum seconds between requests (politeness). |
| `AO3_USER_AGENT`     | `ao3-archiver/0.1 (… syrtis@sysd.info)` | Sent on every request. |
| `AO3_LIST_PATH`      | bookmarks, else demo             | Override the listing path (e.g. a filtered bookmarks URL). |

### Tests

The parser is pinned to **real captured AO3 HTML** in
`Tests/AO3KitTests/Fixtures/works_listing.html`.

- Full Xcode / CI: `swift test` (swift-testing suite in `Tests/AO3KitTests`).
- Command Line Tools only (no Xcode): `swift run selftest` — same assertions, no test
  framework needed.

## Requirements

- macOS, Swift 5.10+ toolchain (Swift 6.3 used in development).
- Dependency: [SwiftSoup](https://github.com/scinfu/SwiftSoup) for HTML parsing.

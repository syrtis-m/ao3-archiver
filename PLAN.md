# Roadmap

What's shipped and what's next. For **how it's built**, see [ARCHITECTURE.md](ARCHITECTURE.md).
For **how to use it**, see [README.md](README.md).

---

## Goals & non-goals

**Goals**
- A dark, liquid-glass gallery that mirrors AO3's bookmarks UI, with **better, fully-local
  filtering** — instant, multi-facet, combinable — plus an in-app reader.
- **Selectively archive** the works you want to keep as real `.epub` files in a folder you control
  — saved as you browse or in a batch, never an all-or-nothing crawl.
- Work **with** a session cookie (private/restricted bookmarks) and **without** one (public only).
- Snappy at real scale: designed for ~20k bookmarks.

**Non-goals**
- Not a general AO3 reader/commenter/poster — read-only browse + selective backup.
- Not a scraper of other people's libraries or a bulk-dataset tool (against AO3 policy). Scope is
  **your own bookmarks**.
- No EPUB construction — AO3 renders EPUBs server-side; we download them as-is.

---

## Status: V1.5 shipped

The tool meets its goal — browse and filter your AO3 bookmarks locally, offline, and snappily, and
selectively save the works you want to keep as EPUBs. You **sync, browse, and read entirely from
the GUI**, no terminal required.

**V1.5 (this release) — cookie-expiry mid-sync + deleted-work detection:**
- **Cookie-expiry mid-sync.** A bookmarks/series listing fetch that bounces to AO3's login form
  (cookie missing, malformed, or expired) is now detected and **pauses the sync** instead of
  silently completing as if nothing was wrong — the previous failure mode looked like "no new
  bookmarks" with zero indication anything was off. The sync sheet shows a re-paste-cookie prompt;
  resuming continues from exactly where it paused (the full-sync resume cursor is already
  persisted; a Quick sync just re-walks its cheap, idempotent catch-up). Gated on a cookie having
  actually been supplied, so an anonymous sync of a legitimately-empty page is never misread as
  "expired."
- **Sync activity log tells you what changed**, not just page counts: a work whose chapter count
  grew is logged as "gained N chapters — saved" once the file is actually re-downloaded; a work
  that now 404s on AO3 is logged as deleted, distinct from an auth/transient failure.
- **"Only copy" badge.** A work confirmed gone from AO3 (`deleted_on_ao3_at`, set only when the
  normal download/redownload flow happens to hit a 404 — never proactively probed) gets a red
  badge on its card and a banner on its detail page: "your saved copy is the only one left" if you
  have it, "deleted before you could save it" if you don't.
- **Caveat:** the login-page markers and the "404 means deleted" assumption are best-effort,
  unverified against a real expired cookie / a real deleted work — unlike the rest of the parser,
  they aren't pinned to a captured fixture. Update them if AO3's behavior turns out to differ.

**V1.4 — Send to Kindle:**
- A one-button **Send to Kindle** on any saved work: generates a cover (AO3 ships none), prepends
  an info page (fandom/ship/rating/stats), and folds a compact badge into the Kindle library title.
  See [ARCHITECTURE.md §12](ARCHITECTURE.md#12-send-to-kindle-kindleexport-kindlecover--v14).

**V1.3 — Quick sync + ratio sorts:**
- **Quick sync** — a bounded, two-pass incremental catch-up (new bookmarks + re-download of works
  that gained chapters) for fast day-to-day syncing, instead of always walking the whole account.
- **Ratio sorts** — five derived sorts (Acclaim, Keeper, Conversation, Density, Collector) that
  rank by a *relationship* between two metrics, surfacing fics the single-metric sorts bury. See
  [ARCHITECTURE.md §11](ARCHITECTURE.md#11-derived-ratio-sorts-gallerysort).

**V1.2 — the in-app reader:**
- A dark, Liquid-Glass **EPUB reader** that opens any saved work in its **own window** (resizable,
  fullscreen, many at once) instead of handing off to Apple Books — purely local, no new network
  or ToS surface.
- Navigates **TOC sections, not raw spine** (AO3's front matter / title page fold into "Preface",
  so no more "Chapter 3 of 27"); **chapter** and **continuous-scroll** modes; theme / font / size;
  **section-granular resume**.
- Renders a **generated `text/html`** doc (fixes the `&nbsp;`-truncates-the-chapter XML bug);
  remote refs / scripts stripped by `EpubSanitizer`; whole-work sanitize runs **off the main
  thread** with a spinner and caches results. See [ARCHITECTURE.md §10](ARCHITECTURE.md#10-the-in-app-reader-v12).

**V1.1 — performance & polish:**
- **Scaled to 20k bookmarks.** Stored search haystack, debounced search, precomputed sort keys,
  allocation-free matching, and **parallelized facet passes** cut a full recompute ~2.6×
  (349ms → 135ms debug at 20k), guarded by a regression budget in the scale test. See
  [ARCHITECTURE.md §6](ARCHITECTURE.md#6-performance-architecture-the-v11-m6-pass--designed-for-20k-bookmarks).
- **Responsive layout** — the detail inspector auto-hides on narrow windows and the sidebar
  collapses, instead of panes clipping; tag pills truncate inside their card.
- **Coalesced live sync reloads** so a long sync doesn't hitch the UI on every page.
- **Bug fix:** a work re-bookmarked on AO3 (new bookmark id, same item) no longer aborts a sync.

**V1 - the foundation:**
- Polite, resumable sync engine + SQLite/FTS5 store (idempotent, archive-state-preserving).
- The dark Liquid Glass gallery with full filter parity — every facet the bookmarks listing
  exposes, tri-state include/exclude, numeric + date ranges, derived/bookmark filters, saved
  presets — all in-memory and memoized.
- A real, double-clickable `.app` with in-app resumable sync (live progress, rate-limit banner,
  index-only by default with per-work download on demand).

---

## What's next (post-V1.5, all optional)

None of these are blockers; V1.5 stands on its own.

- **Live-verify cookie-expiry + deleted-work detection** against real AO3 — the login-page markers
  and the 404-means-deleted assumption shipped in V1.5 are best-effort, not yet pinned to a
  captured fixture the way the rest of the parser is.
- **Scheduled background sync** (opt-in), politeness-respecting.
- **Export / import** the archive folder; backup integrity checks.
- **Local file-size / download-status sort** — the one deferred sort (needs epub byte size stored
  at download).

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| AO3 HTML changes break the parser | All selectors in one `BlurbParser`, pinned to saved fixture HTML; fail soft per-field. |
| Rate limiting / IP throttle | Conservative defaults, 429/503 backoff, single-flight, aggressive caching; politeness is a hard requirement. |
| Cookie expiry mid-sync | Detected (login-page markers, best-effort), pauses + prompts to re-paste, resumes. Not yet live-verified against a real expired cookie. |
| Large libraries (20k) | Memoized in-memory pipeline + the V1.1 perf pass; paged + resumable sync. SQL fallback only past ~100k. |
| Restricted/anon works | Require cookie; mark clearly when unavailable; never crash a sync over one work. |
| ToS / ethics | Scope to the user's own bookmarks; polite client; honest UA; local-only; no bulk-dataset features. |

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

## Status: V1.2 shipped

The tool meets its goal — browse and filter your AO3 bookmarks locally, offline, and snappily, and
selectively save the works you want to keep as EPUBs. You **sync, browse, and read entirely from
the GUI**, no terminal required.

**V1.2 (this release) — the in-app reader:**
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

## What's next (post-V1.1, all optional)

None of these are blockers; V1.1 stands on its own.

- **Cookie-expiry UX** — detect a login redirect / missing username mid-sync, pause, prompt to
  re-paste the cookie, resume.
- **Reconcile & deleted-work highlighting** — works removed from bookmarks get marked; a 404 →
  `deleted_on_ao3`, highlighted as "your backup is the only copy."
- **Scheduled background sync** (opt-in), politeness-respecting.
- **Export / import** the archive folder; backup integrity checks.
- **Local file-size / download-status sort** — the one deferred sort (needs epub byte size stored
  at download).
- **Off-main recompute** (generation token) — insurance for 50k+ / pathological filters; high
  architectural cost, modest payoff at the 20k target. Deferred from V1.1's perf pass.
- **100k+ ceiling-raiser** — a SQL/FTS5 search/filter fallback that pages from disk. Only if the
  library grows an order of magnitude past 20k, and a deliberate search-*semantics* change (FTS
  is token/prefix matching, not the current substring-anywhere match).

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| AO3 HTML changes break the parser | All selectors in one `BlurbParser`, pinned to saved fixture HTML; fail soft per-field. |
| Rate limiting / IP throttle | Conservative defaults, 429/503 backoff, single-flight, aggressive caching; politeness is a hard requirement. |
| Cookie expiry mid-sync | (Planned) detect login redirect, pause, prompt to re-paste, resume. |
| Large libraries (20k) | Memoized in-memory pipeline + the V1.1 perf pass; paged + resumable sync. SQL fallback only past ~100k. |
| Restricted/anon works | Require cookie; mark clearly when unavailable; never crash a sync over one work. |
| ToS / ethics | Scope to the user's own bookmarks; polite client; honest UA; local-only; no bulk-dataset features. |

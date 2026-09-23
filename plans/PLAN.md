# Roadmap

What's shipped and what's next. For how it's built, see [ARCHITECTURE.md](../ARCHITECTURE.md); for
how to use it, [README.md](../README.md).

---

## Goals and non-goals

**Goals**
- A dark Liquid Glass gallery modelled on AO3's bookmarks page, with **better, fully local
  filtering**: instant, multi-facet and combinable, plus a built-in reader.
- **Selective archiving:** save the works you want as real `.epub` files in a folder you control,
  one at a time or in batches, never as an all-or-nothing crawl.
- Work with a session cookie (private and restricted bookmarks) and without one (public only).
- Stay fast at real scale: designed for about 20,000 bookmarks.

**Non-goals**
- Not a general AO3 client. No reading comments, posting or kudos; just browsing and backing up.
- Not a scraper of other people's libraries or a dataset tool, which AO3's policies rule out. The
  scope is **your own bookmarks**.
- No EPUB building. AO3 renders EPUBs itself; we download them as they are.

---

## Shipped

### 1.6.1: reliability and staying in step (current)

1.6.0 was pulled after a day and replaced by 1.6.1, which keeps its features but stores the archive
as a single file again (see [ARCHITECTURE §3](../ARCHITECTURE.md#3-data-layer-store-filestore)).

- **Save Visible:** download the unsaved works in the current filtered view, up to 100 at a time,
  after a confirmation with a time estimate.
- **Series without a Full sync:** a per-series **Fetch works** button, Quick sync fills in three new
  series per run, and series longer than 20 works are fetched in full.
- **Removed bookmarks are reconciled** on Full sync, behind strict guards; works you saved stay,
  marked **Un-bookmarked**.
- **Newest bookmarks download first.**
- **Fixes:** saved works no longer lose their Read / Kindle buttons after a failed refresh; Cancel
  really cancels; deleted-work detection can actually confirm a deletion; an unreadable Keychain
  item is no longer overwritten; downloads share one polite schedule; no accidental crawling
  without a username; renamed works don't leave old files behind; the reader no longer freezes or
  shows a blank window; Send to Kindle runs off the main thread; a stray row in older archives no
  longer blocks the database upgrade.
- **Under the hood:** a fake-AO3 test harness runs the sync engine end to end in both test runners.

### Earlier releases

- **1.5: trust.** Pauses and asks for a fresh cookie when it expires mid-sync instead of finishing
  as if nothing happened; flags works deleted from AO3 (**Only copy** / **Deleted on AO3**); the sync
  log reports chapter gains.
- **1.4: Send to Kindle.** One button: a generated cover, an info page and a title badge.
- **1.3: Quick sync and ratio sorts.** A cheap incremental catch-up, and five sorts that rank by how
  two numbers relate (Acclaim, Keeper, Conversation, Density, Collector).
- **1.2: the reader.** Works open in their own windows, navigated by table-of-contents section, in
  chapter or scroll mode, resuming where you left off.
- **1.1: performance.** Scaled to 20k bookmarks (a full recompute went from 349 ms to 135 ms),
  responsive layout, coalesced reloads during sync.
- **1.0: the foundation.** The polite, resumable sync engine, the SQLite store, the gallery with
  full filter parity and presets, and a double-clickable app with in-app sync.

---

## What's next

The correctness work from the [adversarial review](ADVERSARIAL-REVIEW.md) is done apart from the
items below. See [README.md](README.md) for the plan index.

**Needs a live AO3 capture** (can't be done from the test harness):
- Pin the login-page markers and "404 means deleted" to real captured responses
  ([02 §1–§2](02-verification-and-hardening.md)).
- Test whether an EPUB can be fetched with one request instead of two ([02 §3](02-verification-and-hardening.md)).
- Watch the first real bookmark-pruning runs: they should either prune a handful of bookmarks or
  skip with a stated reason.

**Needs a decision:**
- `work_fts`: keep it (as the search path past ~100k bookmarks) or drop the write cost
  ([Plan 01](01-correctness-and-durability.md)).

**Larger directions:**
- **Multi-device, peer to peer, no servers** (Mac and Android first):
  [03](03-p2p-sync-foundation.md) (data model; land first), [04](04-p2p-transport.md) (transport),
  [05](05-cross-platform-core.md) (other platforms). With peer file transfer, each work would be
  fetched from AO3 once across all your devices.

**Smaller, unowned ideas:**
- Opt-in scheduled background sync, within the politeness rules.
- Sort or filter by file size (store the EPUB size at download).
- Export and integrity checks for the archive folder.

---

## Risks

| Risk | Mitigation |
|---|---|
| AO3's HTML changes | All selectors in `BlurbParser`, pinned to captured pages; parsing fails soft per field. |
| Rate limiting | One app-wide request schedule, conservative intervals, backoff never shorter than the interval, bounded runs. |
| Cookie expires mid-sync | Detected and paused for a fresh cookie; not yet verified against a real expired-cookie page. |
| A sync deletes real bookmarks | Pruning only after a complete, count-verified read with a cookie, capped at 5%; saved works are flagged, never deleted. |
| Large libraries | Memoized in-memory pipeline; paged, resumable sync. SQL search only past ~100k. |
| Restricted works | Need a cookie; one failing work never stops a sync. |
| Terms of service and ethics | Your own bookmarks only; a polite client with an honest User-Agent; local-only; no bulk features. |

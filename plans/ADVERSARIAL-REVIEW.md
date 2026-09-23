# Adversarial reviews

Two full reviews of the codebase, looking for bugs that pass every test. This file is the record of
what they found and what happened to each finding. File and line references point at the commit
each review read, so they'll drift. The fixes and the current design are in
[ARCHITECTURE.md](../ARCHITECTURE.md).

---

## First review: 2026-08-10, version 1.5 (`bf6c583`)

The whole codebase and documentation were read at a point where the build was clean and both test
runners passed (94 tests). Every finding was therefore a live bug in passing code.

**The headline.** The codebase is well built: its invariants are real, enforced and mostly tested,
and its security posture (host allowlist, DOM-level sanitizer, Keychain, honest User-Agent) is
better than most shipping software. The findings clustered in one blind spot: **it was rigorously
tested where it was pure, and untested where it touched the operating system** (SQLite locking,
actor isolation) **or AO3 itself** (behaviours never captured as fixtures).

Findings are ranked by expected harm to the archive. For a tool whose job is "don't lose the fic",
silent data loss outranks everything.

| # | Finding | Severity | Status |
|---|---|---|---|
| F1 | Reading positions silently lost when a save met a sync's database lock | P0 | Fixed (redone in 1.6.1) |
| F2 | One 404 permanently marked a work deleted and stopped archiving it | P0 | Fixed (fix corrected in 1.6) |
| F3 | The whole sync ran on the main thread, despite comments saying otherwise | P0 | Fixed |
| F4 | `work_fts` written on every sync, read by nothing | P1 | **Open**: needs a product decision |
| F5 | A 429 could be retried sooner than the normal request interval | P1 | Fixed |
| F6 | Two requests per EPUB where one might do | P1 | **Open**: needs a manual AO3 test |
| F7 | A planted `/downloads/` link could archive the wrong work | P1 | Fixed |
| F8 | Login-page and deleted-work detection had no captured AO3 pages behind them | P1 | **Open**: needs live captures |
| F9 | Mutable sync state shared across `await`s, guarded only by a comment | P2 | Fixed |
| F10 | The activity log could show events out of order | P2 | Fixed |
| F11 | Syncing without a username crawled an unrelated fandom tag | P2 | Fixed |
| F12 | Search ignored warnings, despite the README promising "any word" | P2 | Fixed |
| F13 | The sanitizer stripped local links that merely contained `https://` | P3 | Fixed |

The open items are planned in [Plan 01](01-correctness-and-durability.md) (F4) and
[Plan 02](02-verification-and-hardening.md) (F6, F8).

### F1: reading positions silently lost

Three facts combined. The store opened plain SQLite connections, GRDB's default is to fail
*immediately* on a locked database rather than wait, and the app opened one connection for the
gallery plus one per reader window. When a reader saved your place while a sync was writing, the
save failed with `SQLITE_BUSY`, and `ReaderModel`'s `try?` threw the error away. Your place in a
247-chapter work could vanish with nothing logged.

*Fix:* a 5-second busy timeout and a visible save error. The first version also switched to WAL;
1.6.1 replaced that with one shared connection for the whole app and went back to a single-file
database, because WAL's extra files made simple backups incomplete.

### F2: an unrecoverable "deleted" latch

A single 404 set `deleted_on_ao3_at`, which removed the work from both download queues forever.
Nothing ever cleared it, and the "404 means deleted" assumption had never been checked against a
real deleted work. A 404 during an AO3 deploy, or for a work briefly made restricted, would silently
stop the tool archiving a work that still existed, while its badge claimed it was gone. Unlike every
other uncertain parse in the codebase, which fails toward doing *more* work, this one failed toward
never trying again.

*Fix:* a work is treated as deleted only when two separate sightings agree, the exclusion expires
after 90 days, and **Check again on AO3** clears it by hand.

### F3: the sync ran on the main thread

`SyncController` is `@MainActor`, so the `Task` it created inherited main-actor isolation. The proof
was in the code: it called a main-actor method without `await`, which only compiles when already on
the main actor. Every listing parse, database write and EPUB write therefore ran on the main thread,
while a comment and ARCHITECTURE both said "off the main actor". The earlier fix for UI hitches
during sync (throttling reloads) had been treating a symptom.

*Fix:* `SyncEngine` became an `actor`, driven from a detached task, with progress delivered through
one ordered stream (which also fixed F10).

### F4 to F13, briefly

- **F4:** `upsertWork` rewrites the FTS row for every card on every sync; only tests read it.
- **F5:** the 429 fallback wait at attempt 0 was 1–2 s, four times faster than the 4 s interval,
  in response to AO3 saying "slow down".
- **F6:** each download fetches the work page just to read the EPUB link.
- **F7:** the fallback link selector also scanned author-written content.
- **F8:** see Plan 02.
- **F9:** the "no overlapping runs" guarantee lived in a comment on an `@unchecked Sendable` class.
  There was no live bug; making the engine an actor made the guarantee real.
- **F10:** one new `Task` per progress event, and independent tasks have no ordering guarantee.
- **F11** to **F13:** as in the table.

### What was good, and must stay that way

- **The host allowlist handles the subtle case.** `isAO3Host` matches the apex or a `.`-prefixed
  subdomain, never a bare suffix, so `evil-archiveofourown.org` is rejected. It's checked before a
  request is built *and* on every redirect.
- **The sanitizer works in the right layer:** on the DOM, not in a navigation delegate that can't
  see image loads.
- **`Store.count(_:)` allowlists its table name,** since an identifier can't be a bound parameter.
- **The idempotency rules are real and tested,** including keeping a deleted-but-saved work inside
  the Saved filter.
- **Quick sync fails soft in the safe direction:** a card whose date didn't parse counts as
  "unknown", not "old", so parser drift makes it do more work rather than stop early.

### The through-line

F2 and F8 share a root cause: two AO3 behaviours shipped as assumptions, without captured pages, in
a codebase whose parser rule is "pin every selector to real HTML". F1 and F3 share another: nothing
tested the boundary with the operating system, because the suite is (rightly) pure and headless.

---

## Follow-up review: 2026-09-22 (`aff9c82` and later)

A second pass read the code independently (including the first review's own fixes), the view layer,
and the real archive's data. It found another round of bugs in passing code, all fixed in 1.6, plus
one found by dry-running the upgrade on the real archive:

| Finding | Harm | Fix |
|---|---|---|
| The F2 fix's two-sighting threshold was unreachable: every sighting used the same source | Deleted works never confirmed; re-requested every sync | One sighting per run; an engine-level test drives two runs |
| Cancel during downloads marked every remaining work failed, then reported "Done" | Saved works lost their Read / Kindle buttons | Cancellation propagates through client, limiter and loop |
| A failed refresh demoted a saved work to "failed" | Same: file on disk, actions hidden, dropped from Saved | Saved works stay saved; the UI asks the file |
| A cancelled run still finishing could overwrite a new run's status | Wrong status, Cancel button gone | Runs carry a generation number |
| One rate limiter per client | Download clicks sent parallel requests to AO3 | One app-wide limiter |
| Series only read their first page | Long series silently truncated | Pagination followed |
| A saved resume cursor was used for a different listing | A Full sync could resume a stale crawl | Cursor only used for the same list |
| An unreadable Keychain item showed as empty, and a sync then deleted it | Cookie silently erased | Unreadable items are never overwritten |
| The WAL switch from F1 left three files in the archive folder | Copying `archive.sqlite` alone missed recent writes | Single-file database, one shared connection (1.6.1) |
| A stray dangling row in the real archive failed the database upgrade | The new build couldn't open the archive at all | Migrations tolerate and repair dangling rows |
| Smaller: sanitizer bypasses via WHATWG URL parsing, unescaped `dc:language`, over-long filenames, orphaned files on rename, same-title Kindle export collisions | Defense in depth, correctness | All fixed |

**What it taught.** Two of the worst bugs hid in fixes to the first review, behind tests that called
a lower layer with hand-picked arguments. The project now has a fake-AO3 harness
(`AO3KitTestSupport`) so behaviour spanning the sync engine is tested end to end in both runners,
and a rule to dry-run anything that changes the archive's format against a copy of the real data
first.

# Adversarial review — AO3 Archiver (V1.5)

Date: 2026-08-10. Reviewed against `main` @ `bf6c583`, with a full read of `Sources/AO3Kit/`,
`Sources/AO3ArchiverApp/`, `Sources/ao3archiver/`, and the doc set. Baseline at review time:
`swift build` clean, `swift test` **94 tests / 7 suites passed**, `swift run selftest`
**ALL CHECKS PASSED** — so every finding below is a live bug in *passing* code.

> **Status: all three P0s (F1, F2, F3) are fixed.** Line/severity text below is preserved as
> written at review time so the evidence stays auditable; see
> [01-correctness-and-durability.md](01-correctness-and-durability.md) §1–§3 for what shipped.
> The new regression test for F1 was verified to **fail** without the fix
> (`SQLite error 5: database is locked` on the `reading_position` INSERT) and pass with it.
> F4–F13 remain open.

**The headline.** This is a genuinely well-built codebase — the invariants in
[ARCHITECTURE.md](../ARCHITECTURE.md) are real, enforced, and mostly tested, and the
security posture (host allowlist, DOM-level sanitizer, Keychain, honest UA) is better than
most shipping software. The findings below are concentrated in one blind spot: **the
codebase is rigorously tested where it is pure, and untested where it touches the OS** —
SQLite concurrency, actor isolation, and the AO3 behaviours that were never captured as
fixtures. Every P0 below lives in that gap.

Findings are ranked by *expected harm to the archive*, not by how interesting they are.
A tool whose purpose is "don't lose the fic" should weight silent data loss above all else.

---

## Severity summary

| # | Finding | Severity | Plan |
|---|---|---|---|
| ✅ F1 | **Fixed.** No WAL + `busyMode = .immediateError` + 3 concurrent `Store` handles + `try?` writes → reading positions silently lost | **P0** | [01](01-correctness-and-durability.md) |
| ✅ F2 | **Fixed.** `deleted_on_ao3_at` was a one-way latch with no clearing path — one transient 404 permanently stops archiving a work | **P0** | [01](01-correctness-and-durability.md) |
| ✅ F3 | **Fixed.** The whole sync ran **on the main actor**, contradicting the code comments and ARCHITECTURE §7 | **P0** | [01](01-correctness-and-durability.md) |
| F4 | `work_fts` written on every upsert, read by nothing but `selftest` — pure write amplification | P1 | [01](01-correctness-and-durability.md) |
| F5 | 429 backoff can retry after ~1 s — *shorter* than the steady-state polite interval | P1 | [01](01-correctness-and-durability.md) |
| F6 | 2 requests per EPUB where 1 may suffice — doubles AO3 load on the dominant sync cost | P1 | [02](02-verification-and-hardening.md) |
| F7 | `epubHref` whole-page fallback can match an author-controlled `/downloads/` link → wrong work archived | P1 | [02](02-verification-and-hardening.md) |
| F8 | Two shipped AO3 behaviours (login page, 404-means-deleted) have **no captured fixture** | P1 | [02](02-verification-and-hardening.md) |
| F9 | `SyncEngine.chapterGains`: cross-suspension mutable state on an `@unchecked Sendable` class | P2 | [01](01-correctness-and-durability.md) |
| F10 | Activity-feed event ordering is not guaranteed (one detached `Task` per event) | P2 | [01](01-correctness-and-durability.md) |
| F11 | Anonymous sync silently crawls a hardcoded unrelated fandom tag | P2 | [02](02-verification-and-hardening.md) |
| F12 | Search haystack omits `warnings`, contradicting README's "search by any word" | P2 | [02](02-verification-and-hardening.md) |
| F13 | `EpubSanitizer.isRemote` substring match strips legitimate local hrefs | P3 | [02](02-verification-and-hardening.md) |

---

## P0 findings

### F1 — Reading positions are silently discarded under concurrency

**Evidence (all three conditions verified, not inferred):**

1. `Store.swift:26` — `dbQueue = try DatabaseQueue(path: path)`. No `Configuration`, so
   **journal mode is the default rollback journal, not WAL**. In rollback-journal mode a
   writer excludes all readers and vice versa.
2. `.build/checkouts/GRDB.swift/GRDB/Core/Configuration.swift:338` —
   `public var busyMode: Database.BusyMode = .immediateError`. GRDB's default is **no busy
   timeout**: a contended lock fails *immediately* with `SQLITE_BUSY` rather than retrying.
3. Three separate `Store` handles are open on the same `archive.sqlite` at once:
   `AO3ArchiverApp.swift:155` (gallery) and `AO3ArchiverApp.swift:101` — **one per reader
   window**, and the app explicitly supports "many at once" (ARCHITECTURE §10).
4. `ReaderModel.swift:171` — `try? store?.saveReadingPosition(...)`. The `try?` swallows the
   `SQLITE_BUSY`.

**Failure scenario.** You open three reader windows and hit Sync. The sync's `upsertWork`
transaction (main actor — see F3) holds the write lock. You scroll; the reader's debounced
`recordVisibleSection` fires `saveReadingPosition`; SQLite returns `SQLITE_BUSY`
immediately; `try?` discards it; the reader reports nothing. You close the window and your
place in a 247-chapter fic is gone. Nothing logs, nothing badges, no test covers it.

The same pattern applies to `persistPosition()` on every `goNext`/`goPrevious`/`jump`.

**Why the current design hides it.** ARCHITECTURE §10 justifies the second handle as "fine
for tiny, `try?`-guarded resume reads/writes" — which is exactly the reasoning that turns a
lock conflict into silent loss. `try?` is correct for *"this write is optional"*; resume
position is not optional, it's the feature.

**Fix direction:** WAL + a busy timeout + stop swallowing. Detailed in
[01](01-correctness-and-durability.md) §1.

---

### F2 — `deleted_on_ao3_at` is an unrecoverable latch

**Evidence.**
- Set in exactly one place: `SyncEngine.swift:365`, `try? store.markDeletedOnAO3(workID:)`,
  triggered by a single `catch AO3Error.http(404)`.
- Consumed as a permanent exclusion in **both** download queues:
  `Store.swift:466` and `Store.swift:488` (`AND deleted_on_ao3_at IS NULL`).
- `Store.markDeletedOnAO3` (`Store.swift:544`) uses `COALESCE(deleted_on_ao3_at, ?)` — it is
  deliberately *sticky*.
- **Nothing clears it.** A repo-wide grep for `deleted_on_ao3` finds the migration, the
  setter, two queue exclusions, two read sites in `GalleryModel`, two UI badges, and tests.
  There is **no `UPDATE … SET deleted_on_ao3_at = NULL`** anywhere, and no UI affordance.

**Failure scenario.** AO3 serves a 404 for a reason other than deletion — a deploy window, a
work temporarily set to registered-users-only, an orphaning redirect, a CDN blip, or simply
the assumption being wrong. The work is latched. It is dropped from
`worksNeedingDownload` *and* `worksNeedingRedownload` **forever**, so it will never be backed
up and an already-saved copy will never gain its new chapters. Meanwhile the card shows a red
badge asserting "deleted from AO3" — which is now a lie the user has no way to correct.

**Why this is the most serious finding for an archival tool.** F1 loses your bookmark in a
book. F2 silently stops the program from doing the one thing it exists to do, on an
unbounded set of works, and *tells you it's fine*. The blast radius grows with every sync.

**Compounding factor — the assumption is self-admittedly unverified.** ARCHITECTURE §13 says
in its own words: *"the 404-means-deleted assumption hasn't been confirmed against a real
deleted work."* Building a permanent, irreversible exclusion on top of an explicitly
unverified heuristic is the inversion of this codebase's own fail-soft ethos. Every other
uncertain parse in `BlurbParser` degrades toward *doing more work*; this one degrades toward
*never trying again*.

**Fix direction:** require corroboration before latching, make the latch expire, and add a
manual reset. Detailed in [01](01-correctness-and-durability.md) §2.

---

### F3 — The entire sync runs on the main actor

**Evidence — this is provable from the type system, not guessed.**

`SyncController` is declared `@Observable @MainActor` (`SyncController.swift:9-11`).
Therefore `start(...)` is main-actor-isolated, and the `Task { [weak self] in … }` it creates
at `SyncController.swift:92` **inherits that isolation** (unstructured `Task` inherits the
enclosing actor context).

The proof is in the code itself: line 123 calls `self?.finish(result:)` — a `@MainActor`
method — **with no `await`**. That only compiles if the task body is already main-actor
isolated. Same for `endRun`, `push`, and the `lastError` assignments in the `catch` arms.

**What that means in practice.** Inside that task:
- `BlurbParser.parseListing(html:)` — a full SwiftSoup DOM parse of a listing page, per page
- `store.upsertWork` / `upsertBookmark` — a SQLite write transaction, per card
- `files.writeEPUB` — a multi-hundred-KB `Data.write(options: .atomic)`, per work
- `EpubDocument`-free but still: `Store.replaceFTS` tokenization, per card (see F4)

…all execute **on the main thread**. The `await`s at the network boundary yield the thread,
which is why the app doesn't appear hung — but every page's parse-and-ingest burst is a main
thread stall of exactly the kind the V1.1 perf pass was fighting.

**The documentation says the opposite, in two places:**
- `SyncController.swift:6` — *"runs the tested `SyncEngine` **off the main actor**"*
- ARCHITECTURE §7 — *"`SyncController` (@MainActor @Observable) runs the **off-main**
  `SyncEngine`"*

**This is the most valuable finding in the review**, because it reframes prior work. ARCHITECTURE §6
records that live sync reloads had to be coalesced to ≤1/1.2 s because a long sync hitched
the UI. That coalescing treated a symptom. A material share of the hitch is the parse and the
DB writes competing with SwiftUI for the main thread — and it is still there, invisible,
under a comment claiming it was solved.

**Fix direction:** make `SyncEngine` genuinely off-main and let the controller be the only
main-actor part. Detailed in [01](01-correctness-and-durability.md) §3.

---

## P1 findings

### F4 — `work_fts` is maintained but unreachable

`Store.replaceFTS` (`Store.swift:427`) runs a `DELETE` + `INSERT` against the FTS5 virtual
table for **every work on every upsert** — i.e. every card on every page of every sync,
including the Quick sync's date-updated pass which deliberately re-ingests cards.

The only reader is `Store.searchWorkIDs` (`Store.swift:593`). A repo-wide grep shows it is
called **only from `Sources/selftest/main.swift`** (lines 207, 211, 214). Neither the app,
the CLI, nor any other part of `AO3Kit` calls it. The gallery's search is an in-memory
substring scan over `WorkListItem.searchHaystack` (`GalleryModel.swift:544`).

So the tool pays FTS5 tokenization + two statements per work per sync, plus the index's disk
footprint, for a capability **no user can reach**. At 20k works that is 40k statements of
pure overhead per full sync, on the main thread (F3).

This isn't obviously "delete it" — ARCHITECTURE §6 names FTS as the intended fallback past
~100k bookmarks. But the current state is the worst of the three options: maintained, never
exercised in anger, and unreachable. Pick one. See [01](01-correctness-and-durability.md) §4.

### F5 — 429 backoff can be shorter than the polite baseline

`AO3Client.backoff(attempt)` (`AO3Client.swift:291`) returns `min(60, pow(2, attempt)) +
random(0...1)`. At `attempt == 0` that is **1–2 seconds**.

`perform` uses it as the 429 fallback when AO3 sends no `Retry-After`
(`AO3Client.swift:240`). So the response to an explicit *"you are going too fast"* can be a
retry ~1 s later — **four times faster than the 4 s steady-state interval**.

`limiter.penalize(seconds: wait)` does push the next slot out, so the practical floor is that
same 1–2 s rather than zero. It's still backwards: a 429 should always back off *further*
than baseline, never less. ARCHITECTURE §9 lists politeness as non-negotiable; this is the
one place the code doesn't honour it. One-line fix, in [01](01-correctness-and-durability.md) §5.

### F6, F7, F8, F11, F12, F13

Detailed with evidence in [02-verification-and-hardening.md](02-verification-and-hardening.md).
Summarised in the table above.

---

## P2 findings

### F9 — `chapterGains` is unguarded cross-suspension mutable state

`SyncEngine.swift:23` declares `private var chapterGains: [Int: Int]` on a class marked
`@unchecked Sendable` (line 12). It is written in `ingest` and read/mutated via
`removeValue` in the download loop — across `await` boundaries, with the safety argument
living in a **comment** (*"SyncEngine doesn't support overlapping runs"*) rather than in the
type.

**No live defect.** Both callers are safe today: `SyncController` guards explicitly with
`guard phase != .running` (`SyncController.swift:80`), and the CLI issues exactly one
`engine.run(...)` in top-level code and then exits (`ao3archiver/main.swift:75`) — it has no
guard because it has no way to start a second run. The finding is that the invariant is
**unenforced**, not currently violated: nothing in the type system stops a future caller, and
a `@unchecked Sendable` annotation is a promise the compiler doesn't check. Cheap to make real
when [Plan 01](01-correctness-and-durability.md) §3 turns the engine into an actor — at which
point the guarantee is free rather than documented.

### F10 — Activity feed ordering is not guaranteed

`SyncController.swift:106` creates a **new** `Task { @MainActor in self?.apply(event) }` per
event. Independent tasks hopping to the same actor have no FIFO guarantee, so the
"torrent-style activity feed" can render events out of order — e.g. a "Saved: X" line above
the "Page 3" line that produced it. Cosmetic, but it's a log the user is asked to trust
during a long, slow operation. An `AsyncStream` fixes it and removes 40 task allocations
per page.

---

## What is genuinely good (and should be protected by any future work)

Stated explicitly because the plans in this directory must not regress it:

- **The host allowlist is correct, including the subtle part.** `AO3Client.isAO3Host`
  (`AO3Client.swift:178`) matches the apex exactly or a `.`-prefixed subdomain — it does not
  use a bare `hasSuffix`, so `evil-archiveofourown.org` is rejected. It's enforced *before*
  the request is formed (line 209) **and** in the redirect delegate (line 128). Two layers,
  both right.
- **The sanitizer is in the right layer.** `EpubSanitizer` cleans the DOM rather than relying
  on a `WKWebView` navigation delegate, which structurally cannot see subresource loads. The
  file's own doc comment articulates exactly why. `hasDangerousScheme` even strips C0 control
  characters before matching, defeating `java&#9;script:`.
- **`Store.count(_:)` guards its interpolated identifier** with `countableTables`
  (`Store.swift:579`) — a table name can't be bound as a parameter, and the author noticed.
- **The idempotency invariants are real and tested**, including the genuinely subtle
  `markDeletedOnAO3` `CASE WHEN epub_path IS NOT NULL` conditional (`Store.swift:548`) that
  keeps an "only copy" work inside the Saved facet.
- **`reachedUpdateFrontier` fails soft in the safe direction** (`SyncEngine.swift:246`): a
  card whose `updatedAt` didn't parse counts as *unknown*, not *old*, so parser drift makes
  the pass do more work rather than silently stop early. This is the exact instinct F2 is
  missing.

---

## The through-line

Three of the P0/P1 findings (F2, F8, and the caveats ARCHITECTURE §13 raises about itself)
are the same root cause: **two AO3 behaviours were shipped as assumptions without captured
fixtures**, in a codebase whose entire parser discipline is "pin the selector to real
captured HTML." The remaining P0s (F1, F3) share a different root cause: **the OS boundary —
SQLite locking and actor isolation — has no test that could have caught them**, because the
test suite is (correctly, deliberately) pure and headless.

Those two gaps, not any individual bug, are what the plans in this directory are organised
around.

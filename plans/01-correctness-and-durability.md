# Plan 01 — Correctness & durability (the P0 pass)

> **Status: §1, §2, §3 shipped.** §4 (`work_fts`) and §5 (429 floor) remain open.
> Verified at 96 tests / 7 suites + `selftest` ALL CHECKS PASSED, both runners in lockstep.
>
> Two things the implementation learned that this plan got wrong, recorded so they aren't
> re-lost:
> 1. **The WAL idiom.** GRDB 6.29.3 has `config.journalMode = .wal`, documented for exactly
>    the `DatabaseQueue` case. The hand-rolled `prepareDatabase` + `PRAGMA` originally written
>    below is wrong — the PRAGMA returns a row, so it needs `String.fetchOne`, not `execute`.
> 2. **WAL is one writer + many readers, not many writers.** The first version of the §1
>    regression test held a write transaction on handle A and wrote from handle B *inside* it —
>    a strict deadlock that can never pass, and which also silently passed pre-fix because
>    GRDB's deferred transaction takes no lock until the first write statement. The correct
>    shape: hold a **short** transaction on a background thread and let it release, so B
>    contends and then succeeds. Assert it actually waited (`> 0.1s`), or the test can pass
>    without contending at all.

**Goal:** close the three silent-data-loss / silent-wrong-behaviour findings (F1, F2, F3)
plus two cheap hygiene wins (F4, F5) and two P2 tidy-ups (F9, F10) from
[ADVERSARIAL-REVIEW.md](ADVERSARIAL-REVIEW.md).

**Prerequisite reading:** [ARCHITECTURE.md](../ARCHITECTURE.md) §3 (data layer), §4 (sync),
§7 (UI layer), §13 (deleted-work detection); [CLAUDE.md](../CLAUDE.md) "Invariants you must
not break".

**Ordering is load-bearing.** §1 (WAL) must land before §3 (off-main sync), because moving the
sync off the main actor *increases* real write concurrency against the reader windows — doing
§3 first would make F1 fire more often, not less. §2, §4, §5 are independent and can land in
any order.

**Global verification requirement.** Per [CLAUDE.md](../CLAUDE.md), `swift test` and
`swift run selftest` are lockstep mirrors of the same assertions. **Every store/model/parser
change in this plan must add its assertion to BOTH** `Tests/AO3KitTests/` and
`Sources/selftest/main.swift`. A change that only updates one is incomplete.

---

## §1 — WAL, busy timeout, and honest write failures (F1) · **P0**

### The problem, restated precisely

Three verified facts combine into silent loss:

1. `Store.swift:26` opens `DatabaseQueue(path:)` with no `Configuration` → **rollback journal**
   (writer excludes readers, reader excludes writer).
2. GRDB's default is `busyMode = .immediateError`
   (`.build/checkouts/GRDB.swift/GRDB/Core/Configuration.swift:338`) → a contended lock throws
   `SQLITE_BUSY` **immediately**, with no retry.
3. `ReaderModel.persistPosition()` (`ReaderModel.swift:171`) is `try?` → the throw is discarded.

Plus: three+ handles are open on one file (`AO3ArchiverApp.swift:155` gallery,
`AO3ArchiverApp.swift:101` **per reader window**).

### Implementation

**1a. Open every `Store` in WAL with a busy timeout.** Resolved dependency is **GRDB 6.29.3**,
which has a first-class API for exactly this case —
`.build/checkouts/GRDB.swift/GRDB/Core/Configuration.swift:319-329` documents it verbatim:
*"Applications that need to open a WAL database with a `DatabaseQueue` should set the
`journalMode` to `wal`."* **Use that, not a hand-rolled `PRAGMA`** (`PRAGMA journal_mode = WAL`
returns a row, so it wants `String.fetchOne`, not `execute` — GRDB itself does this at
`Database.swift:437`; rolling your own invites that trap).

In `Store.swift`, replace both initialisers' queue construction with a shared configuration:

```swift
/// WAL + a busy timeout are REQUIRED here, not tuning. The app opens one Store for the
/// gallery AND one per reader window on the same file (AO3ArchiverApp.swift:101/155), and
/// GRDB's default busyMode is `.immediateError` (Configuration.swift:338) — so without
/// both, a reader's resume write during a sync fails instantly with SQLITE_BUSY and the
/// `try?` at ReaderModel.swift:171 discards it. See ADVERSARIAL-REVIEW.md F1.
static func makeConfiguration() -> Configuration {
    var config = Configuration()
    config.journalMode = .wal        // GRDB 6.29+; DatabaseQueue does NOT do this by default
    config.busyMode = .timeout(5.0)
    return config
}
```

Use it in `init(path:)` — `DatabaseQueue(path: path, configuration: Self.makeConfiguration())` —
and in `init(inMemory:)` (harmless there; keeps one code path).

> **Note:** WAL is persistent (stored in the DB header), applies only to file-backed
> databases, and is a no-op for in-memory ones. `journalMode = .wal` is idempotent across
> connections.
>
> **If GRDB is ever downgraded below 6.29**, `config.journalMode` does not exist and you must
> fall back to `config.prepareDatabase { db in _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL") }`.
> Pin the version rather than relying on this.

> **Note on `.timeout(5.0)`:** deliberately generous. The contending writers here are a sync
> transaction (short) and a resume write (tiny). 5 s is far beyond either, so a timeout now
> genuinely means something is wrong rather than "we were unlucky".

**1b. Consider `DatabasePool` instead — but only after measuring.** With WAL, a
`DatabasePool` allows real concurrent reads (the gallery's `fetchAllListItems` during a sync
write). This is the *right* long-term shape but is a larger change: `Store` is
`@unchecked Sendable` around a `DatabaseQueue`'s serialisation guarantee, and every
`dbQueue.read`/`.write` call site would need re-auditing for the pool's snapshot semantics.
**Do 1a first, ship it, then evaluate.** Do not bundle them.

**1c. Stop swallowing resume writes.** In `ReaderModel.swift`, replace the silent `try?`:

```swift
/// Non-fatal but NOT silent: a dropped resume position is a user-visible feature
/// failing, and `try?` is what let it fail invisibly before (see ADVERSARIAL-REVIEW F1).
public private(set) var lastPersistError: String?

private func persistPosition() {
    guard let store else { return }
    do {
        try store.saveReadingPosition(workID: workID, spineIndex: session.index,
                                      progress: session.progress)
        lastPersistError = nil
    } catch {
        lastPersistError = String(describing: error)
    }
}
```

`ReaderView` should surface `lastPersistError` unobtrusively (a small warning glyph in the
toolbar, not a modal). Keep the branching in `ReaderModel` per the "no `if` in a View" rule —
expose a `var showsPersistWarning: Bool { lastPersistError != nil }`.

### Verification

- **New test in both runners** — `readingPositionSurvivesConcurrentWriter`: open two `Store`
  handles on the *same temp file path* (not in-memory — in-memory queues don't share a file
  and cannot reproduce this). Begin a write on handle A that stays open briefly, call
  `saveReadingPosition` on handle B, assert it **succeeds** and reads back. On `main` today
  this test fails with `SQLITE_BUSY`; after 1a it passes. **This test is the deliverable** —
  without it the fix is unfalsifiable.
- Add `journalModeIsWAL`: open a file-backed `Store`, assert
  `PRAGMA journal_mode` returns `"wal"`.
- `swift test` && `swift run selftest` both green.
- Manual (run-to-confirm, per the verification ceiling): open 3 reader windows, start a full
  sync, scroll each reader, close and reopen — positions retained.

### Risk

WAL creates `archive.sqlite-wal` / `-shm` sidecar files next to the DB. **This matters for
[Plan 03](03-p2p-sync-foundation.md)**: any file-level sync (Syncthing/iCloud) must treat the
three files as an atomic unit, and copying only `archive.sqlite` while a WAL is unmerged loses
recent writes. Call this out in the user-facing docs' "where your library lives" section.

---

## §2 — Make `deleted_on_ao3_at` recoverable (F2) · **P0**

### The problem, restated

One `AO3Error.http(404)` (`SyncEngine.swift:365`) permanently excludes a work from **both**
download queues (`Store.swift:466`, `Store.swift:488`), the flag is `COALESCE`d to be sticky
(`Store.swift:544`), **nothing anywhere clears it**, and ARCHITECTURE §13 admits the
"404 means deleted" premise is unverified against live AO3.

### Design principle

Match the instinct already present in `SyncEngine.reachedUpdateFrontier` (line 246), which
treats an unparseable date as *unknown, not old*, so drift causes **more** work rather than a
silent early stop. Apply the same asymmetry here: an uncertain signal must never cause
*permanently less* archiving.

### Implementation

**2a. Require corroboration before latching.** A single 404 records a *sighting*, not a
verdict. Add a migration:

```swift
m.registerMigration("v6-deleted-sightings") { db in
    // A 404 is EVIDENCE of deletion, not proof (ARCHITECTURE §13 admits the premise is
    // unverified). Count sightings and record when we last saw one, so a transient 404
    // during an AO3 deploy can't permanently retire a work from the download queue.
    try db.execute(sql: "ALTER TABLE work ADD COLUMN deleted_sightings INTEGER NOT NULL DEFAULT 0")
    try db.execute(sql: "ALTER TABLE work ADD COLUMN deleted_last_seen_at TEXT")
    // Existing latched rows: keep the flag (the user has seen the badge) but seed the
    // counter at 1 so the confirmation threshold applies to them too.
    try db.execute(sql: """
        UPDATE work SET deleted_sightings = 1, deleted_last_seen_at = deleted_on_ao3_at
        WHERE deleted_on_ao3_at IS NOT NULL
        """)
}
```

> **Forward-compatibility note — read before writing the migration.**
> [Plan 03](03-p2p-sync-foundation.md) §3.3 needs sightings to **union across devices**
> (two sightings from two devices must count the same as two from one), which an `INTEGER`
> counter cannot express — merging two counters is ambiguous. If P2P is on the roadmap at
> all, model this as a **row per sighting** from the start:
> `deleted_sighting(work_id, device_id, seen_at, PRIMARY KEY(work_id, device_id))`, and read
> the count as `SELECT count(*)`. Single-device behaviour is identical; it just avoids a
> second migration later. The `INTEGER` column above is the minimal version — pick one
> deliberately rather than discovering the conflict in Plan 03.

Rename the setter to `recordDeletedSighting(workID:)`, which increments `deleted_sightings`,
stamps `deleted_last_seen_at`, and sets `deleted_on_ao3_at` **only when
`deleted_sightings >= 2`** (i.e. confirmed on a *separate sync run*). Keep the existing
conditional-`download_state` `CASE WHEN epub_path IS NOT NULL` logic exactly as-is — it is
correct and ARCHITECTURE §13 explains why.

> **Why 2 and not 3:** each retry costs one polite request against a work we believe is gone.
> Two independent sightings across separate runs eliminates the transient-blip case (deploys,
> CDN 404s) at a cost of one extra request per genuinely-deleted work, ever. Three buys
> little more and doubles the cost.

**2b. Re-arm the queues after a cool-off.** Change the exclusion in both
`worksNeedingDownload` and `worksNeedingRedownload` from a hard `IS NULL` to a
time-bounded one:

```sql
AND (deleted_on_ao3_at IS NULL
     OR deleted_last_seen_at < datetime('now', '-90 days'))
```

A work confirmed gone stops being requested for 90 days — the politeness win ARCHITECTURE §13
wanted — then gets exactly one more chance. Authors do restore works and unlock
registered-users-only settings; an archival tool should notice.

**2c. Add the manual escape hatch.** `Store.clearDeletedOnAO3(workID:)` setting all three
columns back to `NULL`/`0`, wired to a **"Check again on AO3"** button in
`WorkDetailView`'s existing `deletedBanner` (`WorkDetailView.swift:40`). This is the
single most valuable line of UI in the plan: it converts an unfalsifiable claim into one the
user can challenge.

**2d. Only latch on a 404 for the *work page*.** Verify the `catch AO3Error.http(404)` in
`SyncEngine.download` can only be reached from the work-page fetch, not from an unrelated
404 inside the redirect chain. `WorkDownloader.downloadEPUB` (`WorkDownloader.swift:50`)
issues two requests; a 404 on the *second* (the `/downloads/` URL) means a stale/invalid
download link, **not** a deleted work. Distinguish them — thread a typed error out of
`WorkDownloader` rather than letting both collapse into `.http(404)`.

> 2d may be the actual bug behind the whole finding. Do not skip it.

### Verification

Both runners:
- `singleSightingDoesNotLatch` — one `recordDeletedSighting` leaves `deleted_on_ao3_at` NULL
  and the work **still in** `worksNeedingDownload`.
- `secondSightingLatches` — two sightings set the flag and remove it from both queues.
- `latchExpiresAfterCooloff` — with `deleted_last_seen_at` backdated 91 days, the work
  returns to `worksNeedingDownload`.
- `clearDeletedRestoresQueue` — `clearDeletedOnAO3` re-arms both queues and clears the badge.
- Preserve the existing `deletedOnAO3MarksAndExcludesFromQueues` assertions
  (`BlurbParserTests.swift:440`, `selftest/main.swift:255`) by updating them to double-sight.

### Depends on

[Plan 02](02-verification-and-hardening.md) §3 captures the real deleted-work fixture that
would let 2d be pinned rather than assumed. **2a–2c are worth doing before that fixture
exists** — they are precisely the mitigations for *not* having it.

---

## §3 — Move the sync off the main actor (F3) · **P0**

### The problem, restated

`SyncController` is `@MainActor` (line 9-11), so the `Task { … }` at line 92 inherits main-actor
isolation. **Proof:** line 123 calls the `@MainActor` method `finish(result:)` with no
`await` — which only compiles under that isolation. Every SwiftSoup listing parse, every
`Store` write transaction, and every `writeEPUB` therefore runs on the main thread.
`SyncController.swift:6` and ARCHITECTURE §7 both claim the opposite.

### Implementation

**3a. Make `SyncEngine` an `actor`** (it is currently `final class … @unchecked Sendable`,
`SyncEngine.swift:12`). This resolves F9 for free — `chapterGains` (line 23) becomes
actor-isolated state instead of a comment-guarded race — and makes "no overlapping runs"
enforceable rather than aspirational.

**3b. Detach the driving task.** In `SyncController.start`, replace
`task = Task { [weak self] in … }` with `Task.detached(priority: .userInitiated)`. This
forces every `self?.<mainActor method>` call inside to require an explicit `await`, which is
exactly the compiler check that was missing:

```swift
task = Task.detached(priority: .userInitiated) { [weak self] in
    do {
        // …build client / files / engine…
        let result = try await engine.run(listPath: listPath, options: options, onEvent: onEvent)
        await self?.finish(result: result)
    } catch is CancellationError {
        await self?.endRun(.cancelled)
    } catch AO3Error.sessionExpired {
        await self?.pauseForCookie(/* ResumeParams */)
    } catch {
        await self?.fail(with: error)
    }
}
```

Fold the current inline `catch` bodies into small `@MainActor` methods (`pauseForCookie`,
`fail(with:)`) so the detached closure only ever `await`s across the boundary. `ResumeParams`
currently holds a `Store` and a `() -> Void` closure (`SyncController.swift:30-34`) — the
closure must become `@MainActor @Sendable` for this to compile; making that explicit is a
correctness improvement, not a workaround.

**3c. Fix the event ordering while you're here (F10).** Replace the per-event
`Task { @MainActor in self?.apply(event) }` (`SyncController.swift:106`) with an
`AsyncStream<SyncEngine.Event>`: the engine's `onEvent` yields into the continuation; a single
`@MainActor` consumer task `for await`s and applies them **in order**. This removes both the
ordering hazard and ~40 task allocations per page.

**3d. Correct the documentation.** Update `SyncController.swift:6` and ARCHITECTURE §7. If
3a–3c are deferred, the comments must be corrected *anyway* — a comment asserting a safety
property the code doesn't have is worse than no comment.

### Verification

- **Compiler-enforced, which is the point:** after 3b, any `self?.mainActorMethod()` without
  `await` fails to build. That's the regression guard.
- Add a `SyncEngine` unit test asserting a second concurrent `run(...)` on the same actor
  serialises rather than interleaving `chapterGains`.
- Manual (run-to-confirm): scroll the gallery and type in the search box during a full sync.
  Before: visible hitching per page. After: smooth.
- `swift test` && `swift run selftest` green.

### Risk

`SyncController`'s `@Observable` properties must only be mutated on the main actor — 3b makes
that a compile error rather than a runtime hazard, so the risk is *build breakage during the
change*, not shipped regression. Budget for a mechanical fix-up pass across
`SyncController.swift` and `SyncSheet.swift`.

---

## §4 — Resolve the `work_fts` question (F4) · P1

`Store.replaceFTS` (`Store.swift:427`) writes on every upsert; `Store.searchWorkIDs`
(`Store.swift:593`) is called **only** from `selftest` (lines 207/211/214). Nothing in the
app, the CLI, or `AO3Kit` reads it.

**Pick one — do not leave it as-is:**

- **(A) Retire it.** Drop `replaceFTS` from the upsert path and the `work_fts` table in a
  migration. Removes ~2 statements + tokenizer work per work per sync from the (currently
  main-thread) hot path. **Cost:** forfeits the documented >100k fallback (ARCHITECTURE §6),
  and the table would have to be rebuilt to bring it back.
- **(B) Wire it up behind a threshold.** Keep the writes; have `GalleryViewModel` route search
  through `searchWorkIDs` when `allItems.count` exceeds a threshold. **Cost:** this is a
  *search-semantics change* — FTS5 is token/prefix matching, the current behaviour is
  substring-anywhere `contains`. ARCHITECTURE §6 already flags this. Typing `ircus` finds
  "circus" today and would stop doing so.

**Recommendation: (A).** The design point is 20k (ARCHITECTURE §6) and the measured recompute
is 135 ms; there is no evidence the fallback is needed, and (B) silently degrades a search
behaviour users rely on. If FTS is wanted later it should be an additive, opt-in "advanced
search" with its own UI affordance — not a silent swap at a hidden row count. **Defer to the
owner**: this is a product call, not a correctness one.

Whichever is chosen, the `selftest` FTS checks must be updated or removed in lockstep.

---

## §5 — Never retry a 429 faster than baseline (F5) · P1

`AO3Client.backoff(0)` returns 1–2 s (`AO3Client.swift:291`), used as the 429 fallback when
AO3 sends no `Retry-After` (`AO3Client.swift:240`). That is **shorter than the 4 s polite
interval**. One-line fix — floor the 429 path at the configured interval:

```swift
case 429:
    // A 429 must ALWAYS back off further than the steady-state interval — backoff(0)
    // is 1–2s, which would retry FASTER than baseline after AO3 explicitly told us to
    // slow down. Politeness is a hard requirement (ARCHITECTURE §9).
    let wait = max(config.minRequestInterval,
                   Self.retryAfter(http) ?? Self.backoff(attempt))
```

Consider the same floor on the 5xx path (line 258); a 503 with `Retry-After` is AO3 asking
too. Add a pure unit test in both runners: `backoffNeverUndercutsInterval` — assert the 429
wait is `>= minRequestInterval` for `attempt` 0…3, with and without a `Retry-After` header.
(Extract the wait computation into a `static func` so it's testable without a network.)

---

## Suggested sequencing

| Step | Section | Why here |
|---|---|---|
| 1 | §5 | One line, zero risk, immediate politeness win. Warm-up. |
| 2 | §1 | Must precede §3 (§3 raises real write concurrency). |
| 3 | §2 | Independent; highest archival value. |
| 4 | §3 | Largest change; benefits from §1 landing first. |
| 5 | §4 | Product decision; do last, and cheaper after §3 (less main-thread pressure to relieve). |

## Definition of done

- [ ] `swift build` clean; `swift test` and `swift run selftest` both green.
- [ ] Every new assertion exists in **both** runners.
- [ ] `readingPositionSurvivesConcurrentWriter` fails on `main` and passes after §1.
- [ ] ARCHITECTURE §3 gains a WAL note; §7 and `SyncController.swift:6` corrected re: off-main;
      §13 updated for the sighting-count / cool-off / manual-reset model.
- [ ] [PLAN.md](PLAN.md) "What's next" updated to reflect what shipped.

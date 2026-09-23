# Plan 01: Correctness and durability

**Status: done, except for one product decision (the `work_fts` table, below).**

This plan fixed the silent-failure findings from the [adversarial review](ADVERSARIAL-REVIEW.md).
The detailed step-by-step instructions it used to contain have been removed now that the work has
shipped: they described some designs that were later changed (notably WAL), and leaving them here
risked someone re-applying them. The current design is in [ARCHITECTURE.md](../ARCHITECTURE.md);
the history is in git.

## What shipped

| Finding | Fix | Where it's described now |
|---|---|---|
| F1: reading positions silently lost to `SQLITE_BUSY` | A 5-second busy timeout, save errors shown in the reader, and one shared database connection for the whole app | ARCHITECTURE §3 |
| F2: one 404 permanently marked a work deleted | Two runs must agree; the verdict expires after 90 days; **Check again on AO3** | ARCHITECTURE §5 |
| F3: the whole sync ran on the main thread | `SyncEngine` is an `actor`, driven from a detached task | ARCHITECTURE §5, §8 |
| F5: a 429 could be retried faster than the normal interval | Every backoff is floored at the request interval | ARCHITECTURE §4 |
| F9: unguarded state shared across `await`s | Solved by making the engine an actor | ARCHITECTURE §5 |
| F10: the activity log could show events out of order | One ordered event stream per run | ARCHITECTURE §8 |

### Lessons worth keeping

- **WAL was the wrong fix for F1.** The real cause was two connections in one app plus GRDB's
  fail-immediately default. 1.6.0 switched to WAL; 1.6.1 reverted to a single-file database with one
  shared connection and a busy timeout, because WAL's sidecar files made simple backups incomplete.
- **A lock-contention test must actually contend.** Hold a *short* write on one connection on a
  background thread, write from the other, and assert the second write waited (more than 0.1 s).
  Otherwise the test passes without ever meeting the lock.
- **The first F2 fix had its own bug.** Every sighting was recorded under the same source, so the
  two-sighting threshold could never be reached; the tests passed because they called the Store
  directly with two made-up sources. The fix records one sighting per run, and an engine-level test
  now drives two real runs. Test through the engine when behaviour spans it.

---

## Open: decide what to do with `work_fts` (F4)

`upsertWork` refreshes a full-text index (`work_fts`) for every card on every sync, but nothing in
the app or CLI reads it; only tests call `Store.searchWorkIDs`. Gallery search runs in memory.

There are two reasonable choices; leaving it as it is isn't one of them.

- **(A) Retire it.** Stop writing it and drop the table in a migration. That saves two statements
  and tokenizer work per card per sync, and some disk. The cost: the documented fallback for very
  large libraries (past ~100k bookmarks) would have to be rebuilt if it's ever needed.
- **(B) Use it above a threshold.** Route search through FTS when the library is huge. The cost:
  FTS matches whole tokens and prefixes, while today's search matches any substring, so typing
  `ircus` would stop finding "circus". That's a silent change in behaviour at a hidden size.

**Recommendation: (A).** The design point is 20k bookmarks, where a full recompute takes about
135 ms, and nothing suggests the fallback is needed. If full-text search is ever wanted, it should
be an explicit "advanced search", not a silent switch. This is the owner's call. Either way, update
the FTS checks in both test runners together.

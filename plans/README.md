# Plans

The roadmap and forward-looking plans for AO3 Archiver. For how it's built, see
[ARCHITECTURE.md](../ARCHITECTURE.md) (the design source of truth); for how to use it,
[README.md](../README.md); for working rules, [CLAUDE.md](../CLAUDE.md).

## Where things stand

| Document | What it is | Status |
|---|---|---|
| [PLAN.md](PLAN.md) | Goals, what's shipped, what's next | Current (1.6.1) |
| [ADVERSARIAL-REVIEW.md](ADVERSARIAL-REVIEW.md) | The two full code reviews and what happened to every finding | Record |
| [01: Correctness and durability](01-correctness-and-durability.md) | The P0 fixes from the first review | Done, except one decision: keep or drop `work_fts` |
| [02: Verification and hardening](02-verification-and-hardening.md) | Pinning AO3 behaviour to captured pages | Code done; captures and one manual test remain |
| [03: P2P sync foundation](03-p2p-sync-foundation.md) | The multi-device data model: device identity, an operation log, merge rules, per-device file possession | Not started. Irreversible schema work; land it first |
| [04: P2P transport](04-p2p-transport.md) | Discovery, QR pairing, pinned TLS, peer-to-peer EPUB transfer. No server | Not started |
| [05: Cross-platform core](05-cross-platform-core.md) | Android, Windows, Linux and a headless peer; conformance test vectors | Not started |
| [PLAN-ANDROID.md](PLAN-ANDROID.md) | The original Android port plan | Partly superseded by 03 and 05 (its header lists which parts) |

## Order of work

```
02 §1–§2 (capture AO3 pages) ──► 05 §2 (conformance vectors)

03 (data model) ──► 04 (transport) ──► 05 §4 (headless peer, Android client)

05 §1 (make AO3Kit portable) — independent; can happen any time
```

Two gates matter:

1. **03 before any Android work.** Otherwise the port copies a schema that's about to change.
2. **03's merge tests pass before 04 starts.** The whole merge layer can be tested with no network;
   debugging it through a socket is far slower.

## Conventions for these plans

- Line references go stale. Each document says which commit it read; re-check before acting.
- Every change lands in **both** test runners (`swift test` and `swift run selftest`), ideally via
  the shared `AO3KitTestSupport` scenarios.
- When a plan contradicts another document, it says so and names which one wins. Two documents
  quietly disagreeing is worse than either being wrong.
- When a plan's work ships, reduce it to a status summary. Step-by-step instructions for work
  that's done go stale and can mislead the next person.

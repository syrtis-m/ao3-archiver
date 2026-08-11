# Plans

Forward-looking plans for AO3 Archiver. For **how it's built** see
[ARCHITECTURE.md](../ARCHITECTURE.md) (the source of design truth), for **how to use it**
[README.md](../README.md), for **day-to-day conventions** [CLAUDE.md](../CLAUDE.md).

---

## Start here

| Document | What it is |
|---|---|
| [ADVERSARIAL-REVIEW.md](ADVERSARIAL-REVIEW.md) | Findings from a full adversarial read of the codebase at V1.5. Every plan below traces to it. **Read this first.** |
| [PLAN.md](PLAN.md) | The shipped-and-next roadmap (V1 → V1.5). |
| [PLAN-ANDROID.md](PLAN-ANDROID.md) | The Android port strategy. **Partly superseded** — see [03 §7](03-p2p-sync-foundation.md#7-reconciling-with-plan-androidmd-explicit-supersession). |

## Implementation plans

Each is self-contained: evidence, implementation, verification, risks, definition of done.

| # | Plan | Addresses | Size |
|---|---|---|---|
| 01 | [Correctness & durability](01-correctness-and-durability.md) | F1 silent loss of reading positions · F2 unrecoverable "deleted" latch · F3 sync runs on the main actor · F4 unused FTS writes · F5 429 backoff undercuts baseline | Medium |
| 02 | [Verification & hardening](02-verification-and-hardening.md) | F6–F8, F11–F13 · the two AO3 behaviours shipped with **no fixture** · wrong-work download hole · Kindle export coverage | Medium |
| 03 | [P2P sync foundation](03-p2p-sync-foundation.md) | The multi-device data model: device identity, oplog, HLC, merge semantics, per-device possession. **Irreversible — land first.** | Large |
| 04 | [P2P transport](04-p2p-transport.md) | mDNS discovery, QR pairing, pinned TLS, framing, peer EPUB pull. No server. | Large |
| 05 | [Cross-platform core](05-cross-platform-core.md) | Android / Windows / Linux / headless peer. Portable `AO3Kit`, conformance vectors. | Medium |

---

## Dependency order

```
01 §1 (WAL) ──────────────► 01 §3 (off-main sync)
     │
     └────────────────────► 03 (P2P data model) ──► 04 (transport) ──► 05 §4 (headless peer)
                                   │                                          ▲
02 §1–§2 (AO3 fixtures) ───────────┼──► 05 §2 (conformance vectors) ──────────┘
     │                             │
     └──► 01 §2 (deleted latch)    └──► 05 §4 (Android client)

05 §1 (portable core split) — independent, do early
```

**The three hard gates:**

1. **[01](01-correctness-and-durability.md) §1 (WAL) before [01](01-correctness-and-durability.md) §3 and before [03](03-p2p-sync-foundation.md).** Both increase real write concurrency; without WAL + a busy timeout that means more silent `SQLITE_BUSY` loss, not less.
2. **[03](03-p2p-sync-foundation.md) before [PLAN-ANDROID.md](PLAN-ANDROID.md) M1.** M1 would otherwise port a schema that is about to change.
3. **[03](03-p2p-sync-foundation.md) Phase 2 (merge tests green) before [04](04-p2p-transport.md).** The whole merge layer is testable with zero networking; debugging it through a socket costs an order of magnitude more.

## If you only do one thing

[01 §2](01-correctness-and-durability.md#2--make-deleted_on_ao3_at-recoverable-f2--p0) — the
`deleted_on_ao3_at` latch. It is the only finding where the tool **silently stops doing the
thing it exists for** (backing up a work), on a set that grows with every sync, while
displaying a badge asserting the opposite. Everything else is recoverable; this isn't.

## Conventions for these plans

- Findings cite `file:line` against `main` @ `bf6c583`. Re-verify before acting on stale line numbers.
- Every plan's verification section names **both** `swift test` and `swift run selftest` —
  per [CLAUDE.md](../CLAUDE.md) they are lockstep mirrors, so a change landing in only one is
  incomplete.
- Where a plan contradicts an existing doc, it says so explicitly and names which supersedes.
  Two plans quietly disagreeing is worse than either being wrong.

# Plan 03 — Peer-to-peer sync foundation (the data model)

**Goal:** let one archive live on several devices — a Mac laptop and an Android phone today, a
Windows/Linux laptop or a headless box later — with **no server anywhere**, no account, and no
cloud, while keeping the instant local-first feel the app has now.

**This plan is the irreversible half.** It defines the on-disk schema and the merge semantics.
[Plan 04](04-p2p-transport.md) moves bytes between devices; [Plan 05](05-cross-platform-core.md)
puts a second client on top. **Land this first** — both of the others are additive once the
data model is settled, and neither can be retrofitted onto the wrong one.

> **Do this before [PLAN-ANDROID.md](PLAN-ANDROID.md) M1.** That milestone would otherwise
> port a schema that is about to change, and its "open the Mac's `archive.sqlite` as a
> compatibility test" acceptance criterion is superseded here — see §7.

**Depends on:** [Plan 01](01-correctness-and-durability.md) §1 (WAL). Not optional — see §8.

---

## 1. The constraint that shapes everything

**SQLite files do not merge.** Replicating `archive.sqlite` two-way with a file syncer
(Syncthing, iCloud Drive, Dropbox) produces conflict copies, and after
[Plan 01](01-correctness-and-durability.md) enables WAL it gets *actively worse*: the DB is
then three files (`archive.sqlite`, `-wal`, `-shm`) that are only consistent as a set, and a
syncer that copies them independently — or copies the main file while a WAL is unmerged —
will hand you a torn or stale database. [PLAN-ANDROID.md](PLAN-ANDROID.md) already flags a
narrow version of this under "Read-position write-back."

**The insight that makes it tractable:** almost nothing in this database actually needs to
merge, because almost all of it is a **re-derivable cache of AO3**.

| Table | Class | Sync treatment |
|---|---|---|
| `work`, `series`, `series_work`, `bookmark`, `tag`, `work_tag`, `bookmark_tag` | **Derived** — re-fetchable from AO3 | Snapshot delta (§4). Idempotent; conflicts are meaningless. |
| `work_fts`, `sync_run` | **Derived, local** | Never synced. Rebuilt/ignored locally. |
| `meta` (resume cursor, `last_incremental_sync_at`) | **Per-device sync state** | **Never synced** — see §5, this is a trap. |
| `reading_position` | **User state — irreplaceable** | Oplog, LWW by HLC (§3.1). |
| `filter_preset` | **User state — irreplaceable** | Oplog, LWW + tombstones (§3.2). |
| `deleted_on_ao3_at` | **Global fact about AO3** | Oplog, first-sighting-wins (§3.3). |
| `epub_path`, `epub_updated_at`, `download_state` | **Per-device possession** | Not merged — *replaced* by a per-device table (§3.4). This is the important one. |

That leaves a CRDT surface of **three small entity types plus one possession table** — a few
hundred rows, not 20,000. Everything expensive is a cache.

---

## 2. Device identity and the oplog

### 2.1 Device identity

```swift
m.registerMigration("v7-device-identity") { db in
    // This device's stable identity. Generated once, never changed, never leaves the
    // device except as the author field on ops it created. NOT derived from hardware —
    // a reinstall should look like a new device rather than silently resurrect an old
    // device's sequence numbers.
    try db.execute(sql: """
        CREATE TABLE device (
          device_id   TEXT PRIMARY KEY,     -- UUIDv4, generated on first launch
          name        TEXT NOT NULL,        -- human label: "Athena's MacBook"
          platform    TEXT NOT NULL,        -- macos | android | windows | linux
          is_self     INTEGER NOT NULL DEFAULT 0,
          paired_at   TEXT,
          last_seen_at TEXT
        )
        """)
}
```

### 2.2 The oplog

```swift
m.registerMigration("v8-oplog") { db in
    // Append-only, per-device operation log. A device ONLY ever appends to its own
    // (device_id, seq) range, so the log itself is conflict-free by construction —
    // two devices can never contend for the same primary key. Merge conflicts are
    // resolved at REPLAY time (§3), not at write time.
    try db.execute(sql: """
        CREATE TABLE oplog (
          device_id  TEXT NOT NULL,      -- author
          seq        INTEGER NOT NULL,   -- monotonic, per-device, gapless
          hlc        TEXT NOT NULL,      -- hybrid logical clock (§2.3), sortable as text
          entity     TEXT NOT NULL,      -- reading_position | filter_preset | ao3_deletion
          entity_key TEXT NOT NULL,      -- work id / preset name
          payload    TEXT,               -- JSON; NULL = tombstone (delete)
          PRIMARY KEY (device_id, seq)
        )
        """)
    try db.execute(sql: "CREATE INDEX idx_oplog_entity ON oplog(entity, entity_key, hlc)")
}
```

**Why an oplog rather than syncing table rows:** a per-device append-only range is the one
structure a dumb transport can move without any merge logic — "send me everything after
seq N from device D" is a range request. It also survives a *file*-level syncer (each
device's ops could live in its own file), which keeps the Syncthing fallback in
[Plan 04](04-p2p-transport.md) viable with zero protocol.

### 2.3 Hybrid logical clocks

Ops are ordered by an HLC, not a wall clock, because a phone and a laptop drift and a laptop
that has been asleep can wake with a clock behind the phone's.

```
hlc = "<wall_ms padded to 15 digits>:<counter padded to 5>:<device_id>"
```

Encoded so that **lexicographic string comparison equals causal-then-tiebreak order** — which
means SQLite can sort it with a plain `ORDER BY hlc` and no custom collation, on every
platform. Rules (standard Kulkarni HLC):

- On send/local event: `wall = max(now_ms, last.wall)`; if `wall == last.wall` then
  `counter = last.counter + 1` else `counter = 0`.
- On receive of a remote op: `wall = max(now_ms, last.wall, remote.wall)`; counter advanced
  per the same rule against whichever term won.
- `device_id` is the final tiebreak, so **the total order is deterministic on every device** —
  two devices replaying the same op set must reach byte-identical state. That determinism is
  the property the tests in §6 assert.

**Clock-skew guard:** reject (log, don't apply) an incoming op whose `wall` is more than 24 h
ahead of local `now`. A wildly wrong peer clock could otherwise pin an LWW register forever.

---

## 3. Merge semantics, entity by entity

### 3.1 `reading_position` — last-writer-wins, with one crucial exception

LWW by HLC per `work_id`. Rejected alternative: "furthest position wins" — it would make
*going back to reread* impossible to sync, which is a normal thing readers do.

**The failure mode LWW creates, and the fix.** You read 40 chapters on the phone on a plane.
You get home, open the same work on the laptop (which still thinks you're at chapter 5). If
merely *opening* writes a position op, its newer HLC clobbers chapter 40 and the phone's
progress is destroyed on next sync.

Today the app would do exactly that: `ReaderModel.recordVisibleSection`
(`ReaderModel.swift:132`) is driven by the WebView's debounced scroll reporter, and **the
initial scroll-to-anchor on open fires it**.

> **Required:** an op is emitted only after a *user-initiated* navigation. Add a
> `hasUserNavigated` latch to `ReaderModel`, set by `goNext`/`goPrevious`/`jump` and by
> `recordVisibleSection` **only** once a scroll event has arrived that isn't the restore
> jump. Opening a work, restoring position, and re-rendering on a font change must emit
> nothing. This is a behavioural invariant, not an optimisation — put it in ARCHITECTURE §10
> alongside the other reader invariants.

Payload: `{"section": Int, "progress": Double?}` — deliberately **not** `locator`, and
deliberately section-granular, matching the existing rationale (ARCHITECTURE §10: a pixel
fraction drifts across devices with different screens even more than across font changes).

### 3.2 `filter_preset` — LWW plus tombstones

LWW by HLC per preset `name` (already the primary key, `Store.swift:165`). **Deletes must be
ops with a `NULL` payload, not row removals** — otherwise device A's delete is silently
resurrected by device B's older insert on the next exchange. Tombstones are retained
indefinitely; presets are a handful of rows and the log is small.

Rename = delete + insert, which under LWW is correct and needs no special case.

### 3.3 `deleted_on_ao3_at` — first sighting wins

The one field where LWW is wrong: this records *when we first observed AO3 404 a work*, and
`Store.markDeletedOnAO3` already `COALESCE`s to keep the earliest (`Store.swift:547`). Merge
by **min(hlc)**, preserving that semantic across devices.

This composes with [Plan 01](01-correctness-and-durability.md) §2: the sighting **count**
becomes a set-union across devices (two sightings from two devices is exactly as good as two
from one), which makes the corroboration rule *stronger* on a multi-device archive rather
than weaker. Ship `deleted_sightings` as a set of `(device_id, hlc)` rather than an integer.

### 3.4 Archive state — replace it with per-device possession

**This is the design change that carries the most weight.** `epub_path` is a *local
filesystem path*; it is meaningless on another device, and `download_state` conflates "this
work is archived" (a global truth) with "I have the bytes here" (a per-device truth).

```swift
m.registerMigration("v9-possession") { db in
    // Which device holds which EPUB. Each device owns (and only writes) its own rows, so
    // this needs no conflict resolution at all — it's a union, not a merge. Replicated so
    // every device knows what the fleet holds, which is what enables peer file pull
    // (Plan 04 §5) instead of re-downloading from AO3.
    try db.execute(sql: """
        CREATE TABLE work_copy (
          device_id  TEXT NOT NULL,
          work_id    INTEGER NOT NULL,
          updated_at INTEGER,          -- the AO3 cache key this copy corresponds to
          bytes      INTEGER,
          sha256     TEXT,             -- content identity; also the transfer integrity check
          recorded_at TEXT NOT NULL,
          PRIMARY KEY (device_id, work_id)
        )
        """)
    try db.execute(sql: "CREATE INDEX idx_work_copy_work ON work_copy(work_id)")
}
```

`epub_path` stays as a **local-only** column (never synced) — it is just where *this* device
put the file.

**Careful with `download_state` — do not over-derive it.** It currently carries four values
(`pending | downloaded | failed | unavailable`) that encode *three different things*:

| Value | Actually means | Source | Treatment |
|---|---|---|---|
| `downloaded` | this device holds bytes | file state | **Replace** — derive from `work_copy` |
| `pending` | no bytes here yet | file state | **Replace** — derive from `work_copy` |
| `unavailable` | it's an external work, AO3 has no EPUB | `kind = 'external'`, set at insert (`Store.swift:308`) | **Keep** — a global fact, already derivable from `kind` |
| `failed` | last download attempt errored here | `markFailed`, with `last_error` | **Keep, local-only** — a per-device UI cache, never synced |

So: *possession* becomes derived from `work_copy`; the other two stay. `DownloadFilter.matches`
(`GalleryModel.swift:449`) compares against these raw strings and **must be updated in step** —
it is the only consumer, which is why this is cheap, but it will silently mis-filter if missed.

Derived predicates:

- **archived somewhere in the fleet** → `EXISTS (SELECT 1 FROM work_copy WHERE work_id = w.id)`
- **archived here** → `EXISTS (… AND device_id = <self>)`
- **stale here** → the local `work_copy.updated_at < work.updated_at`

`worksNeedingDownload` (`Store.swift:460`) gains `AND NOT EXISTS (… device_id = <self> …)`.

**New UI state worth surfacing:** "on your MacBook, not on this phone" is now representable
and is genuinely useful — it's the affordance that offers the peer pull in
[Plan 04](04-p2p-transport.md) §5. Add it to `DownloadFilter` as a fifth case rather than
overloading an existing one.

**The payoff — a genuinely new capability, not just parity.** Because the phone can see the
laptop holds work 123 at `updated_at = T`, it can **pull the file from the laptop** instead of
asking AO3 for it. Across a fleet, each work is fetched from AO3 **once, ever**. That is a
politeness win that no other feature in this project delivers, and it fits the stated ethos
(ARCHITECTURE §1: *"politeness is a hard requirement, not a nicety"*) better than anything
currently shipping. It also means the phone may never need [PLAN-ANDROID.md](PLAN-ANDROID.md)
M5 (a sync client) at all — the laptop syncs AO3, the phone syncs the laptop, and no
politeness/cookie code ever runs on the phone.

### 3.5 What the sha256 is for

Content identity. AO3 renders EPUBs server-side and the same `(work_id, updated_at)` yields
identical bytes, so the hash is (a) the transfer integrity check, (b) the dedup key, and (c)
the thing that lets a device verify a peer-supplied file is the same one AO3 would have
served — a peer that ships you a corrupted or substituted EPUB is caught. Compute it once at
write time in `FileStore.writeEPUB` (`FileStore.swift:56`).

---

## 4. AO3-derived metadata — snapshot delta, not oplog

Putting 20k works × their tags through an oplog would be absurd — and unnecessary, because
**the merge function already exists and is already tested.**

`Store.upsertWork` is idempotent and *"never touches `epub_path` / `epub_updated_at` /
`download_state`"* (ARCHITECTURE §3, `Store.swift:319`). That invariant was written so a
re-sync couldn't clobber a downloaded file — and it turns out to be **exactly** the property
needed to receive metadata from a peer without trampling local archive state. The same is
true of `upsertBookmark`'s stale-row handling (`Store.swift:356`). *The hardest part of the
receive path is already built and already covered by tests.*

**Protocol:** the sender ships rows whose `last_synced_at` is newer than the receiver's
per-peer watermark; the receiver replays them through the **existing** `upsertWork` /
`upsertBookmark` / `upsertSeries` / `linkSeriesWork`. Idempotent, resumable, order-independent.

**Topology: one designated AO3-syncing device.** The Mac talks to AO3; other devices receive
metadata from it. This is not a limitation, it's the correct default:

- It halves-or-better the load on AO3 versus every device crawling independently, which the
  project's ToS posture demands.
- The session cookie stays on one device.
- It matches [PLAN-ANDROID.md](PLAN-ANDROID.md)'s reader-first phasing, where M5 is optional.

A second device *may* be promoted to syncer (a `device.can_sync_ao3` flag); the metadata
delta is idempotent either way, so nothing breaks if two do. It's a politeness preference,
not a correctness constraint.

---

## 5. What must never sync (each of these is a trap)

- **`meta`** — holds `SyncEngine.resumeKey` (the index resume cursor) and
  `lastIncrementalSyncKey` (the update frontier watermark). These are *per-device sync
  progress*. Replicating them makes the phone resume the laptop's crawl mid-account, or makes
  the laptop skip works updated during the phone's window. If `meta` is ever needed
  cross-device, namespace the keys by `device_id` first.
- **The session cookie.** It lives in the Keychain / Android Keystore
  (`CredentialStore.swift`), never in the DB, and **must never enter the oplog or any
  frame** on the wire. State this as an explicit invariant in ARCHITECTURE alongside the
  existing "the cookie never leaves AO3" rule — P2P adds a second exfiltration surface that
  rule didn't previously have to cover.
- **`epub_path`** — a local path (see §3.4).
- **`work_fts`** — a local index. If [Plan 01](01-correctness-and-durability.md) §4 option (A)
  is taken it ceases to exist, which is one fewer cross-platform compatibility problem
  (see §7).
- **`sync_run`** — local bookkeeping.

---

## 6. Verification — and why this layer is unusually testable

**The entire merge layer needs zero networking to test.** Construct two (or three) in-memory
`Store`s, append ops to each, hand one's oplog rows to the other's replay function, assert
convergence. That is a pure function over pure data — it fits this project's headless test
discipline exactly, and it means the risky part of P2P is fully covered *before*
[Plan 04](04-p2p-transport.md) writes a single socket.

Per [CLAUDE.md](../CLAUDE.md), every one of these goes in **both** `Tests/AO3KitTests/` and
`Sources/selftest/main.swift`:

- `convergenceIsOrderIndependent` — replay the same op set in three different orders (and
  with duplicates); assert byte-identical materialized state each time. **The core property.**
- `hlcSortsLexicographically` — HLC strings sort by (wall, counter, device_id) under plain
  string `<`. Guards the "no custom collation on any platform" claim.
- `readingPositionLWW` — later HLC wins; equal wall+counter breaks by device_id
  deterministically on both sides.
- `openingAWorkEmitsNoOp` — the §3.1 invariant: construct a `ReaderModel`, restore a saved
  position, assert **zero** ops. The plane-flight regression guard.
- `presetDeleteIsNotResurrected` — delete on A, stale insert on B, converge → still deleted.
- `deletionSightingsUnion` — sightings from two devices union rather than overwrite (§3.3).
- `possessionIsPerDevice` — device A's `work_copy` row never satisfies device B's
  `worksNeedingDownload` exclusion.
- `metadataDeltaPreservesArchiveState` — receive a peer's `upsertWork` for a work this device
  has downloaded; assert `epub_path` / `work_copy` untouched. This re-asserts the existing
  ARCHITECTURE §3 invariant *in the new context that now depends on it*.
- `cookieNeverAppearsInOplog` — a crude but valuable grep-style assertion over serialized ops.

---

## 7. Reconciling with PLAN-ANDROID.md (explicit supersession)

[PLAN-ANDROID.md](PLAN-ANDROID.md) M1 says: *"treat the Mac's `archive.sqlite` schema as a
**wire format** — the Android store must open the same file."* Its risk list then carries
*"FTS5 tokenizer parity — the Mac DB's FTS table must be readable/rebuildable by the bundled
Android SQLite."*

**Under this plan, that is superseded, and the Android port gets easier:**

- The wire format is the **oplog + metadata delta** (both plain JSON over a framed stream),
  **not** the SQLite file. Android keeps its own local database in whatever shape suits it.
- Byte-compatible FTS5 stops being a requirement. Combined with
  [Plan 01](01-correctness-and-durability.md) §4 option (A), the *"FTS5 tokenizer parity"*
  risk is **deleted outright**, not mitigated.
- The "open a Mac-produced `archive.sqlite`" compatibility test is replaced by a stronger,
  cheaper one: **replay a captured op set and assert the same converged state as the Swift
  implementation**. That is a cross-language golden-file test that runs in CI on both sides
  with no device and no Mac artifact.
- PLAN-ANDROID's phasing survives intact and improves: M3 ("reads a Syncthing-replicated
  archive folder") becomes "reads an archive received from the Mac over the P2P link", which
  is both safer (no DB file sync — see §1) and a better user experience.

**Action:** when this plan lands, edit [PLAN-ANDROID.md](PLAN-ANDROID.md) M1 and its risk
list to point here. Two plans in this directory disagreeing is worse than either being wrong.

---

## 8. Ordering, and the one hard dependency

| Phase | Content | Gate |
|---|---|---|
| **0** | [Plan 01](01-correctness-and-durability.md) §1 (WAL + busy timeout) | **Hard prerequisite.** Replay is a write burst against a DB that other handles are reading. Without WAL that is `SQLITE_BUSY` on the default `.immediateError` — the exact failure F1 describes, at higher volume. |
| **1** | §2 schema (device, oplog, `work_copy`), HLC, local op emission | Irreversible. Nothing reads the ops yet. |
| **2** | §3 replay + merge, §4 metadata delta receive, all of §6's tests | Still **zero networking**. Fully verifiable headlessly. |
| **3** | [Plan 04](04-p2p-transport.md) — move bytes | Only starts once §6 is green. |
| **4** | [Plan 05](05-cross-platform-core.md) — second client | — |

**Do not start Phase 3 before Phase 2's tests pass.** Debugging a merge bug through a socket
is an order of magnitude harder than debugging it in a unit test, and every one of §6's
properties is reachable without a network.

## Definition of done (this plan)

- [ ] Migrations `v7`–`v9` land; `swift build` clean, `swift test` + `swift run selftest` green.
- [ ] Every §6 assertion exists in **both** runners.
- [ ] `download_state` is fully derived; no code writes it as a stored flag.
- [ ] The §3.1 `hasUserNavigated` latch is in `ReaderModel` and covered by
      `openingAWorkEmitsNoOp`.
- [ ] ARCHITECTURE gains a new section for the sync model; §3 updated for `work_copy`;
      §10 updated with the reader op-emission invariant; the "cookie never leaves AO3"
      invariant extended to cover the wire.
- [ ] [PLAN-ANDROID.md](PLAN-ANDROID.md) M1 + risks updated per §7.
- [ ] **Nothing on the wire yet** — that is [Plan 04](04-p2p-transport.md), and this plan is
      complete and useful without it (a single-device install is unaffected).

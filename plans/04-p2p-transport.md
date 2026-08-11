# Plan 04 — Peer-to-peer transport (moving the bytes, with no server)

**Goal:** get the oplog, the metadata delta, and the EPUB files from
[Plan 03](03-p2p-sync-foundation.md) between a Mac and an Android phone (and later a
Windows/Linux box) over a direct connection — no server, no account, no relay, no cloud.

**Hard prerequisite:** [Plan 03](03-p2p-sync-foundation.md) Phase 2 complete and its merge
tests green. Do not open a socket before then; a merge bug found through a network stack costs
an order of magnitude more to diagnose than the same bug in a unit test.

---

## 1. The honest scope boundary — read this first

"No servers" is easy on one LAN and genuinely hard across the internet. Being straight about
this up front prevents building the wrong thing.

| Situation | Works without a server? | How |
|---|---|---|
| Both devices on the same Wi-Fi / LAN | **Yes, cleanly** | mDNS discovery + direct TLS (§2–§4). This is the design target. |
| Phone on cellular, laptop at home | **No, not honestly** | NAT traversal needs a rendezvous/STUN/relay host. That *is* a server, however small. |
| Both on a user-provided overlay (Tailscale, WireGuard, ZeroTier) | **Yes** | Peers are mutually routable; §4 works unchanged over the overlay IP. The user runs the overlay — **we** still run nothing. |
| Devices never co-located | Sneakernet | Export/import a signed op bundle (§7). |

**Recommendation: build for LAN, support overlays for free, and say so plainly in the UI.**
"Syncs when your devices are on the same network" is a promise that is always kept. A
half-working hole-punch that fails on symmetric NAT is worse than an honest limitation — and
for the actual use case (a laptop and a phone in the same home) the LAN path covers it.

Do **not** add a rendezvous server later without revisiting the project's privacy claims:
[README.md](../README.md) says *"No accounts, no telemetry, no cloud"*, and that sentence is
part of what this tool is.

---

## 2. Discovery — Bonjour / NSD

Advertise and browse `_ao3archive._tcp` on the local link. Both platforms have this natively;
no dependency.

- **Apple:** `NWListener` with `NWListener.Service(name:type:)`, and `NWBrowser` for
  discovery — `Network.framework`, first-party, no third-party mDNS stack.
- **Android:** `NsdManager.registerService` / `discoverServices`. Requires
  `android.permission.INTERNET` plus `CHANGE_WIFI_MULTICAST_STATE` for reliable mDNS on some
  OEM builds.

TXT record carries: `did` (device id), `name`, `plat`, `pv` (protocol version), and `spki`
(the SHA-256 of the device's public key, base64) — so a browsing device can recognise an
already-paired peer **before** connecting, and show "Athena's MacBook — paired" rather than an
anonymous IP.

**Never put anything sensitive in the TXT record.** It is broadcast in cleartext to the whole
link. Device name and key fingerprint only.

---

## 3. Pairing — the trust decision, made once, by a human

Discovery finds *a* device; pairing establishes *which* device you trust. Everything after
this is automatic, so this is the only step that gets to interrupt the user.

**Flow:**

1. The Mac generates a long-lived P-256 keypair on first launch (Secure Enclave where
   available; Android Keystore with `setUserAuthenticationRequired(false)` on the phone) and
   shows **"Add a device"** → a QR code encoding
   `ao3archive://pair?did=<uuid>&spki=<b64 sha256 of pubkey>&psk=<32 random bytes, b64>&host=<ip>&port=<n>`.
2. The phone scans it. The QR is the out-of-band channel — it carries the fingerprint the
   phone will pin **and** a single-use pre-shared key.
3. Both sides derive a session key from the PSK, connect, and each proves possession of the
   private key matching the advertised `spki`. On success, each writes the other into the
   `device` table (`paired_at`) with the peer's SPKI pinned.
4. The PSK is **discarded immediately**. It authenticates the first connection only; every
   later connection authenticates by the pinned key.
5. Both devices display the same **six-word / six-digit** short authentication string derived
   from the session transcript; the user confirms they match. This is what defeats an active
   attacker on the LAN who raced the QR.

**Why a QR and not "trust on first use":** TOFU on a coffee-shop Wi-Fi is trust-on-first-attacker.
The QR requires physical co-location of the two devices, which for a personal two-device setup
is not a burden — you pair once, ever.

### The headless case — a QR needs a screen and a camera

[Plan 05](05-cross-platform-core.md) §4 proposes a headless always-on peer (a Pi or NAS with
`ao3archiver --serve`). It has **neither a display to show a QR nor a camera to scan one**, so
the flow above cannot pair it. This must be designed in now, not discovered later.

**`ao3archiver --pair`** prints the same payload to stdout in two forms:

- the `ao3archive://pair?…` URI, and
- a **terminal-rendered QR** (any small pure-Swift QR generator, or `qrencode -t ANSIUTF8`
  where available) so a phone can scan it straight off an SSH session — genuinely convenient,
  and it keeps one code path.

Plus a **manual fallback** for both directions: a 6-group base32 code the user can type, with
a checksum group so a typo fails loudly rather than producing a mismatched pin. Same PSK,
same single-use rule, same short-authentication-string confirmation afterwards.

Applies symmetrically to two headless peers (a NAS pairing with a Linux box): both print, a
human carries the code. Rare, but it must not be impossible.

Unpair = delete the `device` row and the pinned key. Ops already received stay (they're
merged); the peer simply stops being contactable.

---

## 4. Transport — pinned TLS, no CA, no PKI

Once paired, connections use TLS 1.3 with **self-signed certificates pinned to the peer's
SPKI hash**. No certificate authority is involved, which is correct: there is no name to
verify and no third party to trust.

- **Apple:** `NWConnection` + `NWProtocolTLS`, with
  `sec_protocol_options_set_verify_block` comparing the peer's SPKI hash to the pinned value.
- **Android:** `SSLContext` with a custom `X509TrustManager` doing the same comparison, plus
  `HostnameVerifier` returning true (there is no hostname; the pin *is* the identity).

Reject any peer whose SPKI doesn't match a `device` row. No fallback, no "continue anyway",
no plaintext mode — not even for debugging. A device the user hasn't paired cannot exchange
a single byte.

**Framing:** length-prefixed messages, `u32` big-endian length + `u8` type + payload.

| Type | Payload | Direction |
|---|---|---|
| `HELLO` | protocol version, device id, capabilities | both |
| `HAVE` | per-device max `seq` vector + metadata watermark | both |
| `OPS` | oplog rows after the peer's known seq, JSON array | both |
| `META` | `work`/`bookmark`/`series`/tag rows newer than watermark | syncer → peer |
| `COPIES` | `work_copy` rows (who holds which EPUB) | both |
| `WANT` | list of `(work_id, sha256)` requested | requester |
| `BLOB` | chunked file body, offset + length + bytes | provider |
| `BYE` | clean close | both |

Protocol version in `HELLO`; refuse mismatched majors with a clear message rather than
guessing. This is the thing that will save you when the Windows client ships two years later.

---

## 5. EPUB transfer — pull from a peer, not from AO3

The capability [Plan 03](03-p2p-sync-foundation.md) §3.4 unlocks, and the reason this whole
effort is worth more than "sync my bookmarks."

After exchanging `COPIES`, each device knows what the fleet holds. If the phone wants work 123
and the laptop has it at the right `updated_at`, it sends `WANT` and receives `BLOB` — **AO3
is not contacted at all**.

- Chunked (256 KB) and **resumable by offset**, because phones move out of Wi-Fi range mid
  transfer.
- On completion, verify `sha256` against the `COPIES` row **before** writing into `works/`,
  then verify ZIP magic via the existing `WorkDownloader.looksLikeEPUB`
  (`WorkDownloader.swift:70`). A peer is trusted to be *your other device*, not to be
  incorruptible — bad bytes should fail closed.
- Write via the existing `FileStore.writeEPUB` (`FileStore.swift:56`) so the naming and
  atomic-write behaviour stay identical to the AO3 path, then insert the local `work_copy` row.
- Prefer a peer over AO3 whenever a peer has the exact `(work_id, updated_at)`. Fall back to
  AO3 only when no peer does.

**Across a fleet, each work is fetched from AO3 exactly once, ever.** That is a larger
politeness win than any tuning of the rate limiter, and it is the strongest argument this
project has for the P2P work being *in character* rather than scope creep.

---

## 6. The "first-party, liquid-glass, instant" feel

The user requirement is that this stays as fast and native-feeling as the Mac app is today.
Three things deliver that, and none of them is a visual effect:

1. **Sync is never on the read path.** The gallery already derives everything by pure compute
   over an in-memory working set (ARCHITECTURE §5); P2P must not introduce a network fetch
   into rendering, ever. A peer being absent, slow, or mid-transfer must be *invisible* to
   browsing. This is the whole feel, and it's already architecturally true — the job is not to
   break it.
2. **Reuse the coalesced-reload machinery.** `SyncController`'s ≤1/1.2 s reload throttle
   (`SyncController.swift:52`, ARCHITECTURE §6) exists precisely so a burst of incoming rows
   doesn't hitch the UI. Incoming P2P ops must go through the same coalescing — not a reload
   per op. After [Plan 01](01-correctness-and-durability.md) §3 the replay itself is off-main,
   so this is cheap.
3. **Ambient, not modal.** Peer presence belongs as a small glass status affordance ("MacBook
   · syncing 12 works"), never a sheet, never a blocking spinner. Pairing is the *only*
   interruption this feature earns. Per [CLAUDE.md](../CLAUDE.md), all of the branching
   (is-a-peer-present, is-transfer-active, counts) lives in an `@Observable` model in the core,
   not in a View.

On Android, [PLAN-ANDROID.md](PLAN-ANDROID.md) already recommends a **sibling identity**
(Material 3 dark) rather than chasing macOS's material — that recommendation is right and this
plan doesn't change it. What makes the app feel first-party on both platforms is that
everything is local and instant, not that the blur radius matches.

---

## 7. Sneakernet fallback — and the Syncthing question

**Op-bundle export/import.** "Export sync bundle" writes the device's oplog + `work_copy`
rows as a single signed JSON file; "Import" replays it. Because replay is order-independent
and idempotent ([Plan 03](03-p2p-sync-foundation.md) §6), this composes with the live path
with no special casing — you can AirDrop a bundle, apply it, and later sync over the LAN and
converge to the same state. Cheap to build once replay exists, and it covers "my phone is on
a different continent."

**Syncthing for the `works/` folder: yes. For the database: no.**

[PLAN-ANDROID.md](PLAN-ANDROID.md) currently assumes a Syncthing-replicated archive folder.
Split that assumption:

- `works/*.epub` — **safe to replicate with any file syncer.** Immutable, content-addressed
  by `(work_id, updated_at)`, byte-identical across devices. Syncthing is a perfectly good
  transport for these and needs zero code. Keep it working as the zero-effort option.
- `archive.sqlite` — **do not.** After [Plan 01](01-correctness-and-durability.md) §1 it is
  three files (`.sqlite`, `-wal`, `-shm`) that are only consistent as a set. A file syncer
  copying them independently, or copying the main file while a WAL is unmerged, produces a
  torn or stale database, and two-way replication produces conflict copies with no merge.
  **This should be an explicit warning in the README's "where your library lives" section**,
  because the current PLAN-ANDROID text actively invites it.

---

## 8. Security review checklist

Run against this before merging — the project's existing posture is strong and P2P adds the
first inbound surface it has ever had.

- [ ] **The session cookie never crosses the wire.** Grep the serializer. This is the
      single most important line in the plan: [README.md](../README.md) promises *"Your login
      never leaves your machine except to talk to AO3 itself."*
- [ ] Unpaired peers cannot exchange any byte beyond the TLS handshake rejection.
- [ ] No plaintext fallback exists in any build configuration.
- [ ] The listener binds to the **local link only** and is **off by default** — an explicit
      user toggle turns sync on. A backup tool must not open a port because it was installed.
- [ ] Incoming `BLOB` paths are never taken from the peer. Filenames are derived locally from
      `work_id` + title via `ArchivePaths.epubFilename` (`ArchivePaths.swift:6`). A
      peer-supplied path is a directory-traversal primitive; the existing zip-slip guard in
      `EpubDocument.extractAll` (`EpubDocument.swift:334`) shows the right instinct — apply it
      here too.
- [ ] Incoming EPUBs are `sha256`-verified **and** ZIP-magic-verified before landing in
      `works/`, and are still `EpubSanitizer`-cleaned at read time (they go through the same
      reader path, so this is inherited — confirm it, don't assume it).
- [ ] Oplog payloads are size-bounded and JSON-schema-validated on receive; a malformed or
      enormous op is dropped and logged, never applied. Fail-soft per-op, exactly as
      `BlurbParser` fails soft per-field.
- [ ] The clock-skew guard from [Plan 03](03-p2p-sync-foundation.md) §2.3 is enforced on
      receive.
- [ ] Pairing PSK is single-use and discarded; the short-authentication-string confirmation
      is mandatory, not skippable.

---

## 9. Verification

The transport layer can't be fully headless, but most of it can:

- **Pure and testable in both runners:** frame encode/decode round-trip (including truncated
  and oversized frames), `HAVE` vector diffing, chunk assembly and offset resumption, the
  sha256 gate, protocol-version negotiation, and every rejection path in §8.
- **Loopback integration test:** two `Store`s + two protocol endpoints over an in-process
  pipe, exercising a full `HELLO`→`BYE` exchange and asserting convergence — no real socket,
  no mDNS, runs in CI.
- **Run-to-confirm on real hardware** (the honest ceiling, matching ARCHITECTURE §8's stance
  on the view layer): mDNS discovery on a real network, QR pairing, a mid-transfer Wi-Fi drop
  and resume, and a phone that has been offline for a week converging correctly.

## Definition of done

- [ ] `swift build` clean; `swift test` + `swift run selftest` green; every pure assertion in
      **both** runners.
- [ ] Sync is **off by default**; no port is opened until the user pairs a device.
- [ ] The §8 checklist is completed and recorded in ARCHITECTURE's security section.
- [ ] README gains an honest "Sync between your devices" section stating the same-network
      limitation plainly, and the `archive.sqlite`-is-not-file-syncable warning.
- [ ] [PLAN-ANDROID.md](PLAN-ANDROID.md) M3's "Syncthing-replicated archive folder" wording
      updated per §7.

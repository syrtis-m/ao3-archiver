# Plan 05 — Cross-platform: Android now, Windows / Linux / headless later

**Goal:** make a second (and third) client cheap, and keep them honest about each other —
without a rewrite per platform and without the two-parsers-drift problem
[PLAN-ANDROID.md](PLAN-ANDROID.md) already worries about.

**Depends on:** [Plan 03](03-p2p-sync-foundation.md) (the wire format is the contract) and
[Plan 04](04-p2p-transport.md) (something to speak it over).

---

## 1. The measurement that changes the strategy

`AO3Kit` is **one file away from being portable**, and the package manifest hides it.

Verified by inspecting every `import` in `Sources/AO3Kit/`:

| File | Platform-bound? |
|---|---|
| `KindleCover.swift` | **Yes** — `CoreGraphics`, `CoreText`, `ImageIO` |
| *Everything else* (23 files) | **No** — `Foundation`, `SwiftSoup`, `GRDB`, `ZIPFoundation`, `Observation` only |

And `AO3Client.swift:2-4` already carries `#if canImport(FoundationNetworking)` — someone
previously thought about non-Apple platforms.

Dependency portability, stated at the confidence each actually deserves:

| Dependency | Linux | Windows |
|---|---|---|
| **SwiftSoup** 2.13.5 | Pure Swift — portable | Pure Swift — portable |
| **ZIPFoundation** 0.9.20 | Supported | Supported |
| **GRDB** 6.29.3 | Supported (documented, CI-tested upstream) | **Unverified — assume nothing** |

> **GRDB on Windows is the open question, and the plan must not paper over it.** GRDB's
> supported-platform list is Apple + Linux; Windows is not a claim upstream makes. If a
> Windows client is ever seriously pursued, **verify this before anything else** — a
> compile-only spike of `AO3Kit` on Windows is a day's work and it decides the whole
> approach. If GRDB doesn't build there, the options are a direct SQLite C-interop shim (the
> `Store` API surface is small and SQL-first, so this is tractable) or — more likely — that
> §3's Compose Multiplatform route wins for desktop and portable-Swift is only ever needed
> for the Linux headless peer (§4), where GRDB *is* supported.
>
> **Nothing else in this plan depends on the Windows answer.** Linux — which is what §4's
> headless peer actually needs — is on solid ground.

**The only real blocker is `Package.swift:13` — `platforms: [.macOS("26.0")]`, declared
package-wide.** That constraint exists for a good reason (ARCHITECTURE §7: one deployment
boundary so Liquid Glass and Observation need no scattered `@available`) — but it is declared
on the *package*, so it also pins the parser, the store, the sync engine, and the gallery model
to macOS 26 when none of them need it.

### Action: split the manifest, not the code

```
AO3Kit          — portable core. No platform floor beyond what GRDB/Swift require.
AO3KitMac       — macOS 26+ only: KindleCover (CoreGraphics/CoreText/ImageIO).
AO3ArchiverApp  — macOS 26+ only: SwiftUI/AppKit/WebKit.
```

`KindleExport` (`KindleExport.swift`) currently calls `KindleCover.renderJPEG` directly at
line 252. Invert it: define a `CoverRenderer` protocol in `AO3Kit`, pass an implementation in
from `AO3KitMac`, and `KindleExport` stays in the portable core (all its OPF/ZIP surgery is
pure Foundation + ZIPFoundation). One small dependency inversion; no logic moves.

**Then add `swift build --triple x86_64-unknown-linux-gnu` (or a Linux CI job) as a
compile-only check on `AO3Kit`.** That single job is what keeps the core portable — otherwise
the next Apple-only import lands unnoticed and the option quietly closes.

> **Value even if no second Swift client is ever built.** This is the cheapest possible
> insurance: it costs a manifest split and a CI job, and it converts "we'd have to see how
> portable it is" into a fact the build verifies on every push.

---

## 2. What actually gets shared — the contract, not the code

Sharing *code* across Swift-on-Mac and Kotlin-on-Android is the trap
[PLAN-ANDROID.md](PLAN-ANDROID.md) correctly rejects (Swift-on-Android is a preview toolchain;
GRDB has no Android support; the UI must be rewritten regardless). That analysis stands.

**Share the contract instead.** After [Plan 03](03-p2p-sync-foundation.md), three artifacts
are language-neutral and are the real shared asset:

1. **The oplog + wire format** — plain JSON, framed (Plan 04 §4). A spec document, not a library.
2. **Conformance vectors** — golden files: an input op set + the exact converged state it must
   produce. Any implementation in any language passes or fails them. This is what replaces
   PLAN-ANDROID M1's *"open a Mac-produced `archive.sqlite` as a compatibility test"* with
   something **stronger and cheaper**: it runs in CI on both sides, needs no emulator, no Mac
   artifact, and no byte-compatible FTS5.
3. **The AO3 HTML fixtures** — `Tests/AO3KitTests/Fixtures/` vendored verbatim, exactly as
   PLAN-ANDROID already plans. SwiftSoup is a port of Jsoup, so selectors translate mechanically.

### Generating the vectors

Add a `swift run conformance-vectors` mode that emits, into `spec/vectors/`:

- `ops-*.json` — op sets exercising every §3 merge rule from
  [Plan 03](03-p2p-sync-foundation.md): LWW ordering, HLC tiebreak by device id, preset
  tombstones, deletion-sighting union, per-device possession, duplicate/replayed ops, and
  out-of-order delivery.
- `expected-*.json` — the converged materialized state for each.

The Swift suite asserts it reproduces them; the Kotlin suite asserts the same. **A merge-rule
divergence becomes a failing test on one side instead of a silently diverging archive.** This
is the single highest-leverage item in the plan.

---

## 3. Per-platform client strategy

| Platform | Core | UI | Status |
|---|---|---|---|
| **macOS** | `AO3Kit` (Swift) | SwiftUI + Liquid Glass | Shipped |
| **Android** | Kotlin `:core` per [PLAN-ANDROID.md](PLAN-ANDROID.md) | Jetpack Compose, Material 3 dark ("sibling, not lookalike") | Planned |
| **Windows / Linux GUI** | **Portable `AO3Kit`** (§1) | Platform-native (see below) | Optional |
| **Headless / "server"** | **Portable `AO3Kit`** | None — see §4 | Nearly free |

**Windows/Linux GUI is the expensive one and should stay optional.** The core is portable
(§1); the UI is not, and there is no Swift GUI story on those platforms worth betting on.
Realistic options, in order of preference:

1. **Don't.** The headless peer (§4) plus the phone may well cover the actual need. Ask what
   the Windows laptop is *for* before building a third gallery.
2. **Kotlin/Compose Multiplatform**, reusing the Android `:core` and Compose UI on desktop.
   This is the cheapest real GUI, because it's the *second* use of code you already wrote —
   and it means the portable-Swift-core work in §1 is only needed for §4.
3. A native Swift + platform-toolkit client. Most work, best fidelity, hardest to justify.

**Note the strategic fork:** if Compose Multiplatform is the likely desktop answer, then
Kotlin `:core` — not `AO3Kit` — is the code that pays off twice. That makes
[PLAN-ANDROID.md](PLAN-ANDROID.md)'s Kotlin rewrite decision *more* right, not less, and it
means §1's value is insurance and the headless peer, not a future Swift GUI. Decide this
before investing beyond §1's manifest split.

---

## 4. The "server version" is nearly free

Worth stating plainly because it reframes the cost: **a headless always-on peer is the
existing CLI plus [Plan 04](04-p2p-transport.md)'s listener.** No new architecture.

`Sources/ao3archiver/main.swift` (113 lines) already drives a bounded `SyncEngine` run from
environment variables. Add the Plan 04 listener and a portable `AO3Kit` (§1) and you have a
box that:

- syncs AO3 politely on a schedule (the *one* device holding the cookie),
- holds the full EPUB archive,
- serves it to the laptop and phone over the LAN,
- never runs a UI, never needs a display, runs on a Raspberry Pi or a NAS.

Which is exactly the topology [Plan 03](03-p2p-sync-foundation.md) §4 recommends anyway
(one designated AO3-syncing device), and it makes [Plan 03](03-p2p-sync-foundation.md) §3.4's
"fetch each work from AO3 once, ever" true for the whole fleet permanently.

**It is still not a *server* in the sense [README.md](../README.md) disclaims** — no account,
no cloud, no third party, no inbound internet exposure; just another of the user's own paired
devices that happens to have no screen. Keep that distinction crisp in the docs, because
"server version" invites exactly the reading the privacy promise rules out.

Scope: `ao3archiver` gains a `--serve` mode, config via the existing env vars, systemd/launchd
unit files in `Packaging/`. Small, and it depends only on §1 + Plan 04.

---

## 5. The two-parsers problem

[PLAN-ANDROID.md](PLAN-ANDROID.md) flags it: *"When AO3 markup drifts, fixtures + expectations
now update in two repos."* Real, and the mitigation it proposes (vendor fixtures once, keep
expectations identical) is right. Two additions:

- **[Plan 03](03-p2p-sync-foundation.md) §4 makes it much less urgent.** If only the Mac (or
  the headless peer) talks to AO3, the phone's parser is dormant — a drift breaks *one*
  implementation, and the phone keeps working off replicated metadata. The Android parser
  becomes needed only if PLAN-ANDROID M5 (phone-side AO3 sync) is ever built, which
  [Plan 03](03-p2p-sync-foundation.md) §3.4 argues may never be necessary.
- **Where a fixture is missing, both implementations are wrong together.** The two
  unverified AO3 behaviours ([Plan 02](02-verification-and-hardening.md) §1–§2) would be
  ported into Kotlin as the same assumptions. **Close those fixtures before porting the
  parser**, or the port doubles the debt.

---

## 6. Sequencing

| Step | Content | Cost | Gate |
|---|---|---|---|
| 1 | §1 manifest split + `CoverRenderer` inversion + Linux compile-only CI | Small | None. Do it early — it's insurance that expires if you wait. |
| 2 | §2 conformance vectors emitted from the Swift implementation | Small | Needs [Plan 03](03-p2p-sync-foundation.md) Phase 2. |
| 3 | [Plan 02](02-verification-and-hardening.md) §1–§2 fixtures | Small | **Before** any parser port (§5). |
| 4 | Android client — [PLAN-ANDROID.md](PLAN-ANDROID.md) M0–M4, minus its M1 schema-compat criterion (superseded by §2) | Large | Needs 2 + 3. |
| 5 | §4 headless `--serve` peer | Small | Needs 1 + [Plan 04](04-p2p-transport.md). |
| 6 | Windows/Linux GUI — **decide first** whether Compose Multiplatform reuse (§3) makes it worth it | Large | Needs 4. |

## Definition of done (§1 and §2 only — the rest is downstream)

- [ ] `AO3Kit` builds with no macOS platform floor; `KindleCover` lives in `AO3KitMac`;
      `KindleExport` takes an injected `CoverRenderer`.
- [ ] A Linux compile-only CI job for `AO3Kit` is green and required.
- [ ] `swift test` + `swift run selftest` unchanged and green on macOS — the split must be
      **pure refactor**, no behaviour change. Kindle export still passes its round-trip test.
- [ ] `spec/` contains the wire-format document and `spec/vectors/`; the Swift suite asserts
      against the vectors in **both** runners.
- [ ] [PLAN-ANDROID.md](PLAN-ANDROID.md) M1 updated to target the vectors rather than the
      SQLite file (per [Plan 03](03-p2p-sync-foundation.md) §7), and its "FTS5 tokenizer
      parity" risk removed.

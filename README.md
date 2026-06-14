# AO3 Archiver

**Keep your own copy of your AO3 bookmarks — every story saved as a real file on your Mac, in a
beautiful gallery you can search and filter however you like, even offline.**

Fanworks disappear: authors delete accounts, works get orphaned, sites go down. AO3 Archiver
quietly downloads the works you've bookmarked as standard `.epub` ebook files (the kind Apple
Books reads) and keeps them in a folder you choose — so your favourites are yours to keep.

It's a native Mac app with a dark, glassy look, and it's **private**: everything stays on your
computer. Your login is stored in the Mac's Keychain and is only ever sent to AO3.

---

## What you can do with it

- **Back up your bookmarks** as ebook files you own, readable in Apple Books and anywhere else.
- **Browse them in a gallery** — each story shows its title, author, rating, tags, summary, word
  count, and your own bookmark notes.
- **Find anything instantly.** Search by any word, or filter by fandom, relationship, character,
  rating, tags, length, kudos, date — and combine as many filters as you want. It stays fast even
  with tens of thousands of bookmarks.
- **Save your favourite filter combinations** ("Smart Bookmarks") and reapply them in one click.
- **Read offline.** Once saved, your works don't need AO3 — or even an internet connection.

> Works you bookmarked that live on *other* sites (external works) can't be saved as ebooks —
> AO3 doesn't host their files — but they're still listed so you have the record.

---

## Getting started

### 1. Download and open the app

You'll need an **Apple Silicon Mac** running **macOS 26 (Tahoe)**.

1. Go to the [**latest release**](https://github.com/syrtis-m/ao3-archiver/releases/latest) and
   download **`AO3-Archiver-v1.1.0.zip`** (under *Assets*).
2. Double-click the downloaded zip to unzip it, then drag **AO3 Archiver.app** into your
   **Applications** folder.
3. The first time you open it, **right-click (or Control-click) the app → Open → Open**. macOS
   asks this once because the app is a free personal tool that isn't signed by a paid Apple
   developer account — it's safe; after the first launch it opens normally with a double-click.

(Prefer to build it yourself? See *For developers* at the bottom.)

### 2. Choose where your library lives

Click the **folder icon** in the toolbar and pick a folder for your archive (the default is a new
**ao3archive** folder inside your Documents). This is where your saved ebooks and the catalog
live. You can reveal it in Finder from the same menu any time.

### 3. Connect to AO3 and sync

Click **Sync**. You'll be asked for:

- **Your AO3 username** — so it knows whose bookmarks to fetch.
- **A login cookie** *(optional)* — only needed to reach **private or restricted** bookmarks.
  Leave it blank to back up your public bookmarks.

Then press **Sync** and watch your bookmark list build up live.

By default, syncing just builds your **catalog** (the list of everything, fast and gentle on AO3).
To actually save a story's ebook file, open it and click **Download EPUB** — or turn on
"Download EPUB files too" to grab them in bulk.

> **A note on patience:** AO3 asks apps to go slowly so they don't overload the site, and this app
> respects that. A big library takes a while, and AO3 may ask it to pause partway — that's normal.
> The app shows you when it's waiting, and if it gets interrupted it picks up where it left off
> next time.

#### Where do I find the login cookie?

If you want your private/restricted bookmarks too, you'll paste one value from your browser:

1. Log in to AO3 in your web browser.
2. Open your browser's developer tools (in most browsers, right-click the page → **Inspect**).
3. Find the **Application** (or **Storage**) section → **Cookies** → `archiveofourown.org`.
4. Copy the **value** of the cookie named **`_otwarchive_session`** and paste it into the app.

The app saves it securely in your Mac's Keychain and only ever sends it to AO3.

### 4. Browse and filter

Use the sidebar on the left to filter, the search box up top to find words, and the sort menu to
order things (newest bookmark, most kudos, title, and so on). Click any story to see its full
details, open the saved ebook in Books, or jump to it on AO3.

Tip: click a filter once to **include** it, again to **exclude** it, once more to clear it.

---

## Your privacy & being a good citizen

- **Everything is local.** No accounts, no telemetry, no cloud. Your works and catalog live only
  on your Mac.
- **Your login never leaves your machine** except to talk to AO3 itself.
- **It's polite to AO3 by design** — slow, one request at a time, and it backs off the moment AO3
  asks. This is a personal backup tool for **your own bookmarks**, in the spirit of AO3's own
  "fans backing up works" guidance — not a bulk scraper.

---

## For developers

The app is a Swift package. Build and run it from the project folder:

```sh
swift build                    # build everything
swift run selftest             # fast headless checks (no Xcode needed)
swift test                     # full test suite (needs Xcode)

./Packaging/make-icon.sh       # once: render the app icon
./Packaging/make-app.sh        # assemble "build/AO3 Archiver.app"
open "build/AO3 Archiver.app"
```

There's also a command-line backup tool (`swift run ao3archiver`) for headless/scripted syncs,
configured by environment variables (`AO3_USERNAME`, `AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`,
`AO3_MIN_INTERVAL`, `AO3_MAX_PAGES`, `AO3_MAX_DOWNLOADS`, …). Syncs are **bounded by default** so a
casual run never crawls a whole account by accident.

- **How it's built:** [ARCHITECTURE.md](ARCHITECTURE.md)
- **What's next:** [PLAN.md](PLAN.md)
- **Contributor conventions:** [CLAUDE.md](CLAUDE.md)

**Requirements:** macOS 26 (Tahoe) + Xcode 26 to build the app (it uses Apple's Liquid Glass).
Dependencies: [SwiftSoup](https://github.com/scinfu/SwiftSoup) (HTML parsing) and
[GRDB](https://github.com/groue/GRDB.swift) (SQLite/FTS5).

---

## Contact

Questions, bugs, or feedback: **syrtis@sysd.info**. (This is also the contact address the app
identifies itself with when it talks to AO3.)

---

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free to use, modify, and share for any
**noncommercial** purpose (personal use, hobby projects, research, nonprofits). Commercial use is
not granted. The noncommercial restriction reflects AO3's own nonprofit, transformative-works
ethos. Dependencies remain under their own MIT licenses.

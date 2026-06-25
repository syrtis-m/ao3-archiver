# AO3 Archiver

**A beautiful local browser for your AO3 bookmarks — search, filter, and read every one of them
offline, and save the works you want to keep as real files on your Mac.**

AO3's own bookmarks page gets unwieldy once you have thousands. AO3 Archiver pulls your bookmarks
into a dark, glassy gallery with instant, combinable filters, and lets you read them right in the
app. And because fanworks disappear — authors delete accounts, works get orphaned, sites go down —
you can save the ones you'd hate to lose as standard `.epub` ebook files (the kind Apple Books
reads), in a folder you choose.

It's a native Mac app with a dark, glassy look, and it's **private**: everything stays on your
computer. Your login is stored in the Mac's Keychain and is only ever sent to AO3.

<img width="1012" height="760" alt="image" src="https://github.com/user-attachments/assets/6e3ef501-3261-43fa-bb86-ff27a64c8c67" />


---

## What you can do with it

- **Browse them in a gallery** — each story shows its title, author, rating, tags, summary, word
  count, and your own bookmark notes.
- **Find anything instantly.** Search by any word, or filter by fandom, relationship, character,
  rating, tags, length, kudos, date — and combine as many filters as you want. It stays fast even
  with tens of thousands of bookmarks. 
- **Save your favourite filter combinations** ("Presets") and reapply them in one click.
- **Save the works you want to keep** as ebook files you own — pick them as you browse, or grab a
  batch — readable in Apple Books and anywhere else.
- **Read right in the app.** A dark, glassy built-in reader opens any saved story in its own
  window — chapter-by-chapter or continuous scroll, with your choice of theme, font, and size, and
  it remembers where you left off. Open as many reader windows as you like.
- **Read offline.** Once saved, your works don't need AO3 or an internet connection.

> Works you bookmarked that live on *other* sites (external works) can't be saved as ebooks —
> AO3 doesn't host their files — but they're still listed so you have the record.

<img width="1408" height="881" alt="image" src="https://github.com/user-attachments/assets/83c3d664-75ac-46ab-82a9-c1a4d80e9052" />
<img width="2306" height="1566" alt="image" src="https://github.com/user-attachments/assets/d1f05963-65eb-4354-ba29-dbfac3be36ac" />


---

## Getting started

### 1. Download and open the app

You'll need an **Apple Silicon Mac** running **macOS 26 (Tahoe)**.

1. Go to the [**latest release**](https://github.com/syrtis-m/ao3-archiver/releases/latest) and
   download **`AO3-Archiver-v1.2.1.zip`** (under *Assets*).
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

By default, syncing just builds your **catalog** (the list of everything, fast and gentle on AO3) —
so you can browse and filter your whole collection without downloading a single file. When you
find a story worth keeping, open it and click **Download EPUB** to save its ebook — or turn on
"Download EPUB files too" to save them as you sync.

> **A note on patience:** AO3 asks apps to go slowly so they don't overload the site, and this app
> respects that. A big library takes a while, and AO3 may ask it to pause partway — that's normal.
> The app shows you when it's waiting, and if it gets interrupted it picks up where it left off
> next time.

<img width="1214" height="772" alt="image" src="https://github.com/user-attachments/assets/9a1433fa-36c5-4c01-8af7-9c0b6a4de8f9" />


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
details, then **Read** to open it in the built-in reader (or open it in Books, or jump to it on
AO3). The reader opens in its own window — use the **list** button for the table of contents and
**Aa** to switch between chapter and scroll modes and adjust theme, font, and size.

Tip: click a filter once to **include** it, again to **exclude** it, once more to clear it.

<img width="286" height="229" alt="image" src="https://github.com/user-attachments/assets/15ec1262-1e68-4947-9266-2c62ad2e2907" />


---

## Your privacy & being a good citizen

- **Everything is local.** No accounts, no telemetry, no cloud. Your works and catalog live only
  on your Mac.
- **Your login never leaves your machine** except to talk to AO3 itself.
- **It's polite to AO3 by design** — slow, one request at a time, and it backs off the moment AO3
  asks. This is a personal backup tool for **your own bookmarks**, in the spirit of AO3's own
  "fans backing up works" guidance — not a bulk scraper. Additionally, it identifies itself to AO3 (via user-agent string) as "`ao3-archiver/0.1 (personal bookmark backup; AO3 user:\[your username is added here]; contact syrtis@sysd.info)`"

---

## For developers

The app is a Swift package. Build and run it from the project folder:

```sh
swift build                    # build everything
swift run selftest             # fast headless checks (no Xcode needed)
swift test                     # full test suite (needs Xcode)

./Packaging/make-icon.sh       # once: render the app icon
./Packaging/make-app.sh 
open "build/AO3 Archiver.app" # final build & launch
```

There's also a command-line backup tool (`swift run ao3archiver`) for headless/scripted syncs,
configured by environment variables (`AO3_USERNAME`, `AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`,
`AO3_MIN_INTERVAL`, `AO3_MAX_PAGES`, `AO3_MAX_DOWNLOADS`, `AO3_MAX_SERIES`, …). Syncs are **bounded by default** so a
casual run never crawls a whole account by accident.

If you fork this tool, please update the user-agent string logic in Sources/AO3Kit/AO3Client.swift to use your own contact information.

- **How it's built:** [ARCHITECTURE.md](ARCHITECTURE.md)

**Requirements:** macOS 26 (Tahoe) + Xcode 26 to build the app (it uses Apple's Liquid Glass).
Dependencies: [SwiftSoup](https://github.com/scinfu/SwiftSoup) (HTML parsing),
[GRDB](https://github.com/groue/GRDB.swift) (SQLite/FTS5), and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (reading EPUB archives for the reader).

---

## Contact

Questions, bugs, or feedback: **syrtis@sysd.info**.

This software is provided as-is. This was a weekend hobby project - I may not maintain over time and will not produce versions for other operating systems. Please see the License section for more information if you wish to Fork or create your own version.

---

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free to use, modify, and share for any
**noncommercial** purpose (personal use, hobby projects, research, nonprofits). Commercial use is
not granted. The noncommercial restriction reflects AO3's own nonprofit, transformative-works
ethos. Dependencies remain under their own MIT licenses.

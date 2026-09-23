# AO3 Archiver

**A fast, private Mac app for your AO3 bookmarks: browse and filter all of them offline, read them
in a built-in reader, and save the ones you want to keep as ebooks you own.**

AO3's bookmarks page gets hard to use once you have thousands. AO3 Archiver pulls your bookmarks
into a dark, glassy gallery with instant filters you can combine however you like. And because
fanworks disappear (authors delete accounts, works get orphaned or locked), you can save the ones
you'd hate to lose as standard `.epub` files in a folder you choose.

Everything stays on your Mac. Your AO3 login lives in the macOS Keychain and is only ever sent to
AO3.

<img width="1012" height="760" alt="The AO3 Archiver gallery" src="https://github.com/user-attachments/assets/6e3ef501-3261-43fa-bb86-ff27a64c8c67" />

---

## What it does

**Browse and find**
- **A gallery of your bookmarks.** Each card shows the title, author, rating, tags, summary, word
  count and your own bookmark notes.
- **Search and filter instantly.** Search any word, or filter by fandom, relationship, character,
  rating, warnings, your own tags, length, kudos, dates and more. Combine as many filters as you
  like; it stays fast even with tens of thousands of bookmarks.
- **Presets.** Save a filter combination and bring it back in one click.

**Keep and read**
- **Save works as ebooks.** Download any work from its detail panel, or filter down to what you
  want and click **Save Visible** to grab the whole view (up to 100 at a time; it tells you roughly
  how long that will take first). The files open in Apple Books or any ebook reader.
- **Read in the app.** The built-in reader opens each work in its own window, chapter by chapter or
  as one continuous scroll, with your choice of theme, font and size. It remembers where you left
  off.
- **Send to Kindle in one click.** With Amazon's *Send to Kindle* Mac app installed, every saved
  work gets a **Send to Kindle** button. AO3's ebooks have no cover, so the app makes one (title,
  author, fandom, ship, word count) and adds an info page with the rating, warnings and stats.
- **Series come with their works.** Open a bookmarked series and click **Fetch works in this
  series**. Quick sync also fills in a few new series each time.

**Stay in step with AO3**
- **Deleted works are flagged.** If a work you bookmarked disappears from AO3, it gets a red badge:
  **Only copy** if you'd already saved it, **Deleted on AO3** if you hadn't. The app waits for two
  separate syncs to agree before saying so, and you can ask it to check again.
- **Un-bookmarked works are removed.** A Full sync notices bookmarks you've removed on AO3 and
  removes them here too. Works you've saved stay, marked **Un-bookmarked**, because the file is
  yours. It only does this after reading your entire bookmark list and matching AO3's own count, so
  an interrupted or glitchy sync can never delete anything.
- **Updates are called out.** When a saved work gains chapters, the sync log says so ("gained 2
  chapters") as the new file is saved.

> Bookmarks of works hosted on other sites ("external works") can't be saved as ebooks, since AO3
> doesn't have the files, but they stay in your catalog so you keep the record.

<img width="1408" height="881" alt="Filtering the gallery" src="https://github.com/user-attachments/assets/83c3d664-75ac-46ab-82a9-c1a4d80e9052" />
<img width="2306" height="1566" alt="The built-in reader" src="https://github.com/user-attachments/assets/d1f05963-65eb-4354-ba29-dbfac3be36ac" />

---

## Getting started

### 1. Install

You'll need an **Apple Silicon Mac** running **macOS 26 (Tahoe)**.

1. Open the [**latest release**](https://github.com/syrtis-m/ao3-archiver/releases/latest) and
   download the **`AO3-Archiver-v….zip`** file under *Assets*.
2. Unzip it and drag **AO3 Archiver.app** into your **Applications** folder.
3. The first time, **right-click (or Control-click) the app → Open → Open**. macOS asks once
   because this free app isn't signed with a paid Apple developer account. After that it opens
   normally.

(Want to build it yourself? See *For developers* below.)

### 2. Choose where your library lives

By default your library is a new **ao3archive** folder in Documents. To use another folder, click
the **folder icon** in the toolbar. The folder holds one catalog file (`archive.sqlite`) and a
`works` folder of saved ebooks, so backing it up is just copying the folder.

### 3. Sync with AO3

Click **Sync** and enter:

- **Your AO3 username** (required), so the app knows whose bookmarks to fetch.
- **Your login cookie** (optional). You only need it for **private or restricted** bookmarks and
  works. Leave it blank to sync your public bookmarks.

Then choose:

- **Full sync** reads your whole bookmark list. Use it the first time, and occasionally after that.
  If it's interrupted, the next Full sync picks up where it stopped. (**Start over** begins again
  from page 1.)
- **Quick sync** catches up cheaply: new bookmarks, saved works that gained chapters, and a few
  series that haven't been fetched yet.

By default a sync only builds your **catalog**, which is quick and gentle on AO3, so you can
browse everything without downloading a single file. When you find something worth keeping, open
it and click **Download EPUB**, use **Save Visible**, or turn on **Download EPUB files too** in the
sync window to save as you go.

> **Be patient with big libraries.** AO3 asks tools to go slowly, and this app does: one request
> every few seconds, and it waits whenever AO3 asks it to (the sync window shows when). If your
> login cookie expires partway through, the sync pauses and asks for a fresh one instead of
> quietly skipping everything after that point. Paste it and click **Resume sync**.

<img width="1214" height="772" alt="The sync window" src="https://github.com/user-attachments/assets/9a1433fa-36c5-4c01-8af7-9c0b6a4de8f9" />

#### Finding your login cookie

1. Log in to AO3 in your web browser.
2. Open the developer tools (in most browsers: right-click the page → **Inspect**).
3. Go to **Application** (or **Storage**) → **Cookies** → `archiveofourown.org`.
4. Copy the **value** of the cookie named **`_otwarchive_session`** and paste it into the app.

The app keeps it in your Mac's Keychain and only ever sends it to AO3.

### 4. Browse, filter and read

- **Filter** with the sidebar. Click a value once to **include** it, again to **exclude** it, and
  once more to clear it.
- **Search** with the box at the top.
- **Sort** with the sort menu: newest bookmark, most kudos, title and so on. The **Ratios** section
  ranks by how two numbers relate, which surfaces fics a single number buries:
  - *Acclaim*: kudos per hit (the quietly beloved hidden gems)
  - *Keeper*: bookmarks per kudos (the ones people keep to reread)
  - *Conversation*: comments per kudos
  - *Density*: kudos per 1,000 words (short fics that punch above their length)
  - *Collector*: bookmarks per hit
- **Open** any story to see everything about it. Click **Read** to open the built-in reader, or
  open it in Books, reveal the file, or view it on AO3.
- **In the reader**, the **list** button shows the table of contents, and **Aa** switches between
  chapter and scroll modes and changes the theme, font and size.

<img width="286" height="229" alt="Include and exclude filters" src="https://github.com/user-attachments/assets/15ec1262-1e68-4947-9266-2c62ad2e2907" />

---

## Privacy, and being polite to AO3

- **Everything is local.** No accounts, no telemetry, no cloud. Your catalog and ebooks live only
  on your Mac.
- **Your login goes nowhere but AO3.** The app refuses to send it anywhere else, even if a web
  page tries to redirect it.
- **It's gentle on AO3 by design.** One request at a time, a few seconds apart, and it backs off
  whenever AO3 asks. It's a personal backup tool for **your own bookmarks**, in the spirit of AO3's
  guidance on fans backing up works, not a bulk scraper.
- **It says who it is.** Every request identifies the app, your AO3 username and a contact
  address: `ao3-archiver/<version> (personal bookmark backup; AO3 user: <you>; contact
  syrtis@sysd.info)`.

---

## For developers

AO3 Archiver is a Swift package. From the project folder:

```sh
swift build                    # build everything
swift test                     # full test suite (needs Xcode)
swift run selftest             # the same checks without Xcode

./Packaging/make-icon.sh       # once: render the app icon
./Packaging/make-app.sh        # build "AO3 Archiver.app" into build/
open "build/AO3 Archiver.app"
```

There's also a command-line sync, `swift run ao3archiver`, configured with environment variables
(`AO3_USERNAME`, `AO3_SESSION_COOKIE`, `AO3_ARCHIVE_DIR`, `AO3_MIN_INTERVAL`, `AO3_MAX_PAGES`,
`AO3_MAX_DOWNLOADS`, `AO3_MAX_SERIES`, …). It's **bounded by default** (2 pages, 3 downloads), so a
casual run never crawls a whole account by accident. It uses the same library folder as the app.

**If you fork this, change the contact address** in the User-Agent (`AO3Config.defaultUserAgent`
in `Sources/AO3Kit/AO3Client.swift`) to your own.

How it's built: [ARCHITECTURE.md](ARCHITECTURE.md). Working on it:
[CLAUDE.md](CLAUDE.md). Roadmap and plans: [plans/](plans/README.md).

**Requirements:** macOS 26 (Tahoe) and Xcode 26 (the app uses Apple's Liquid Glass). Dependencies:
[SwiftSoup](https://github.com/scinfu/SwiftSoup) for HTML parsing,
[GRDB](https://github.com/groue/GRDB.swift) for SQLite, and
[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for reading EPUBs and building the
Kindle versions.

---

## Contact

Questions, bugs or feedback: **syrtis@sysd.info**.

This is a hobby project, provided as-is. I may not keep maintaining it, and I won't be making
versions for other operating systems. If you'd like to fork it or make your own version, see the
license below.

---

## License

[PolyForm Noncommercial License 1.0.0](LICENSE.md): free to use, modify and share for any
**noncommercial** purpose (personal use, hobby projects, research, nonprofits). Commercial use
isn't permitted, in keeping with AO3's own nonprofit, fan-run ethos. The dependencies keep their
own MIT licenses.

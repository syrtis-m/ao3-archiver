import Foundation
import AO3Kit
import ZIPFoundation

// Headless verification of BlurbParser / WorkDownloader against the real captured
// fixture. Runs anywhere Swift builds (no XCTest/Testing dependency). Exits non-zero on
// the first failure so it's CI-friendly.

var failures = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("  ✓ \(name)") }
    else { print("  ✗ \(name)"); failures += 1 }
}

// Locate the fixture relative to this source file, so CWD doesn't matter.
let thisFile = URL(fileURLWithPath: #filePath)
let repoRoot = thisFile.deletingLastPathComponent()   // Sources/selftest
    .deletingLastPathComponent()                      // Sources
    .deletingLastPathComponent()                      // repo root
let fixtureURL = repoRoot
    .appendingPathComponent("Tests/AO3KitTests/Fixtures/works_listing.html")

guard let html = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("could not read fixture at \(fixtureURL.path)\n".utf8))
    exit(3)
}

do {
    let blurbs = try BlurbParser.parseListing(html: html)

    print("BlurbParser — listing")
    check("parses 20 cards", blurbs.count == 20)
    check("every card has id/title/author",
          blurbs.allSatisfy { $0.workID > 0 && !$0.title.isEmpty && !$0.author.isEmpty })

    let b = blurbs[0]
    print("BlurbParser — first card fields")
    check("workID == 85487886", b.workID == 85487886)
    check("title", b.title == "Sarcasm and Sanctuary")
    check("author", b.author == "haleinedelail")
    check("authorURL", b.authorURL == "/users/haleinedelail/pseuds/haleinedelail")
    check("fandoms", b.fandoms == ["Good Omens (TV)"])
    check("rating == Explicit", b.rating == "Explicit")
    check("category == M/M", b.category == "M/M")
    check("isComplete == false (WIP)", b.isComplete == false)
    check("language == English", b.language == "English")
    check("wordCount == 12328", b.wordCount == 12328)
    check("chaptersHave == 4", b.chaptersHave == 4)
    check("chaptersTotal == nil (?)", b.chaptersTotal == nil)
    check("comments == 5", b.comments == 5)
    check("kudos == 18", b.kudos == 18)
    check("bookmarksCount == 2", b.bookmarksCount == 2)
    check("hits == 198", b.hits == 198)
    check("dateText", b.dateText == "13 Jun 2026")
    check("updatedAt == 1781388945", b.updatedAt == 1781388945)
    check("warnings include CNTW", b.warnings.contains("Creator Chose Not To Use Archive Warnings"))
    check("freeforms include Hinduism", b.freeforms.contains("Hinduism"))
    check("relationships count == 2", b.relationships.count == 2)
    check("summary present", b.summary?.contains("Prof. Anthony Crowley") == true)

    print("ArchivePaths")
    check("sanitize illegal chars", ArchivePaths.sanitize("A/B: C?") == "A B C")
    check("sanitize empty → untitled", ArchivePaths.sanitize("   ") == "untitled")

    // Bookmarks page uses li.bookmark.blurb.group containers (+ a bookmarker section).
    // Validates that the same parser handles the real bookmarks markup.
    let bookmarksURL = repoRoot.appendingPathComponent("Tests/AO3KitTests/Fixtures/bookmarks_page.html")
    if let bmHTML = try? String(contentsOf: bookmarksURL, encoding: .utf8) {
        let bm = try BlurbParser.parseListing(html: bmHTML)
        // 20 bookmark cards = 19 AO3 works + 1 external-work bookmark. All are recorded;
        // kind distinguishes them and only .work is downloadable.
        let bmWorks = bm.filter { $0.kind == .work }
        let bmExternal = bm.filter { $0.kind == .external }
        print("BlurbParser — bookmarks page")
        check("parses all 20 bookmark cards", bm.count == 20)
        check("19 are AO3 works", bmWorks.count == 19)
        check("1 is an external work", bmExternal.count == 1)
        check("external card has /external_works/ sourcePath",
              bmExternal.first?.sourcePath.contains("/external_works/") == true)
        check("external card author (plain text) == agrippa", bmExternal.first?.author == "agrippa")
        check("external card has no EPUB-relevant stats", bmExternal.first?.wordCount == nil)
        check("first work bookmark workID == 1413325", bmWorks.first?.workID == 1413325)
        check("first work bookmark title", bmWorks.first?.title == "circus girl without a safety net")
        check("all work bookmarks have stats (wordCount)", bmWorks.allSatisfy { $0.wordCount != nil })

        print("BlurbParser — bookmark-specific fields")
        check("every card has a bookmarkID", bm.allSatisfy { $0.bookmarkID != nil })
        check("every card has a bookmarkedAt date", bm.allSatisfy { $0.bookmarkedAt != nil })
        check("first card bookmarkedAt == 30 May 2026", bmWorks.first?.bookmarkedAt == "30 May 2026")
        check("work date distinct from bookmark date", bmWorks.first?.dateText == "04 Apr 2014")
        check("all 20 are public (none private)", bm.allSatisfy { !$0.isPrivate })
        check("none flagged as rec", bm.allSatisfy { !$0.isRec })

        print("BlurbParser — pagination")
        check("nextPagePath points to page 2",
              (try BlurbParser.nextPagePath(html: bmHTML))?.contains("page=2") == true)
        check("nextPagePath nil on a page with no Next",
              try BlurbParser.nextPagePath(html: "<ol class=\"pagination\"></ol>") == nil)
        check("lastPageNumber reads the total (91)", try BlurbParser.lastPageNumber(html: bmHTML) == 91)
        check("lastPageNumber nil when no pagination",
              try BlurbParser.lastPageNumber(html: "<p>one page</p>") == nil)
    }

    // Series bookmark card (li.bookmark.blurb.group whose heading links to /series/<id>).
    // Captured live from the user's bookmarks after they bookmarked a series.
    let seriesCardURL = repoRoot.appendingPathComponent("Tests/AO3KitTests/Fixtures/series_card.html")
    if let scHTML = try? String(contentsOf: seriesCardURL, encoding: .utf8) {
        let sc = try BlurbParser.parseListing(html: scHTML)
        print("BlurbParser — series bookmark card")
        check("parses 1 series card", sc.count == 1)
        check("kind == series", sc.first?.kind == .series)
        check("series id == 2157402", sc.first?.workID == 2157402)
        check("series title", sc.first?.title == "those who form his fire-side")
        check("worksCount == 6", sc.first?.worksCount == 6)
        check("series total wordCount == 39146", sc.first?.wordCount == 39146)
        check("series bookmarkedAt == 13 Jun 2026", sc.first?.bookmarkedAt == "13 Jun 2026")
        check("series updated date distinct (27 Mar 2026)", sc.first?.dateText == "27 Mar 2026")
    }

    // Series page (/series/<id>): lists member work blurbs with the standard work markup,
    // so the same parser expands a series into its member works.
    let seriesPageURL = repoRoot.appendingPathComponent("Tests/AO3KitTests/Fixtures/series_page.html")
    if let spHTML = try? String(contentsOf: seriesPageURL, encoding: .utf8) {
        let members = try BlurbParser.parseListing(html: spHTML)
        print("BlurbParser — series page (member expansion)")
        check("parses 6 member works", members.count == 6)
        check("all members are AO3 works", members.allSatisfy { $0.kind == .work })
        check("member ids match", members.map(\.workID) ==
              [26762044, 29369769, 35035795, 68591376, 70449741, 81922441])
        check("members carry word counts", members.allSatisfy { $0.wordCount != nil })
    }

    // ── Store: schema, idempotent upsert, stale detection, FTS (all offline) ──────────
    // Reuses the parsed bookmarks fixture (19 works + 1 external). The dispatch here mirrors
    // exactly what SyncEngine's index pass does per card.
    func ingest(_ store: Store, _ cards: [WorkBlurb]) throws {
        for b in cards {
            switch b.kind {
            case .work, .external:
                try store.upsertWork(b)
                try store.upsertBookmark(b, itemKind: b.kind, itemID: b.workID)
            case .series:
                try store.upsertSeries(b)
                try store.upsertBookmark(b, itemKind: .series, itemID: b.workID)
            }
        }
    }

    if let bmHTML = try? String(contentsOf: bookmarksURL, encoding: .utf8) {
        let cards = try BlurbParser.parseListing(html: bmHTML)
        let store = try Store(inMemory: true)
        try ingest(store, cards)

        print("Store — ingest bookmarks fixture")
        check("20 work rows (19 work + 1 external)", try store.count("work") == 20)
        check("20 bookmark rows", try store.count("bookmark") == 20)
        check("tags were normalized", try store.count("tag") > 0)
        check("19 works need download (external excluded)",
              try store.worksNeedingDownload().count == 19)

        // Idempotency: a second full ingest must not duplicate anything.
        try ingest(store, cards)
        check("re-ingest is idempotent (still 20 works)", try store.count("work") == 20)
        check("re-ingest is idempotent (still 20 bookmarks)", try store.count("bookmark") == 20)
        check("re-ingest is idempotent (download queue still 19)",
              try store.worksNeedingDownload().count == 19)

        // Mark one downloaded → it leaves the queue.
        let first = try store.worksNeedingDownload().first!
        try store.markDownloaded(workID: first.id, epubPath: "works/\(first.id).epub",
                                 updatedAt: first.updatedAt)
        check("after one download, 18 remain", try store.worksNeedingDownload().count == 18)

        // Before any update advances, nothing we hold needs RE-downloading.
        check("re-download queue empty until an update lands",
              try store.worksNeedingRedownload().isEmpty)

        // Stale detection: AO3 shows a newer updated_at → it re-enters the queue.
        if var staleCard = cards.first(where: { $0.workID == first.id }) {
            staleCard.updatedAt = (first.updatedAt ?? 0) + 1
            try store.upsertWork(staleCard)
            check("a newer updated_at marks the work stale (back to 19)",
                  try store.worksNeedingDownload().count == 19)
            // The same advance is exactly what the incremental sync re-downloads: this work
            // (already saved, now newer) appears; the 18 never-downloaded works do NOT.
            check("re-download queue is the one updated-and-saved work",
                  try store.worksNeedingRedownload().map(\.id) == [first.id])
        }

        // knownBookmarkIDs distinguishes recorded bookmarks from new ones.
        let someBID = cards.compactMap { $0.bookmarkID }.first!
        check("knownBookmarkIDs finds a recorded bookmark",
              try store.knownBookmarkIDs(among: [someBID]).contains(someBID))
        check("knownBookmarkIDs excludes an unseen id",
              try !store.knownBookmarkIDs(among: [someBID + 999_999]).contains(someBID + 999_999))
        check("knownBookmarkIDs on empty input does no query", try store.knownBookmarkIDs(among: []).isEmpty)

        // A failed download must be RETRYABLE (anon run → add cookie → re-run picks it up):
        // marking failed records the error but must NOT remove it from the download queue.
        let queueBeforeFail = try store.worksNeedingDownload().count
        let toFail = try store.worksNeedingDownload().first!
        try store.markFailed(workID: toFail.id, error: "requires login")
        check("a failed download stays in the queue (retryable across runs)",
              try store.worksNeedingDownload().count == queueBeforeFail)

        // FTS: a word from a real title is findable.
        check("FTS finds 'circus' (work 1413325)", try store.searchWorkIDs("circus").contains(1413325))
        // L1: FTS5 query operators in raw input are quoted as literals, never raise SQLITE_ERROR.
        var ftsThrew = false
        for q in ["circus*", "\"unbalanced", "foo:bar", "a NEAR b", "-x", "()", "  "] {
            do { _ = try store.searchWorkIDs(q) } catch { ftsThrew = true }
        }
        check("FTS tolerates query operators without throwing (L1)", !ftsThrew)
        check("FTS quoted term still matches (L1)", try store.searchWorkIDs("\"circus\"").contains(1413325))

        // Re-bookmark: the same work under a NEW bookmark id (old bookmark deleted, fresh
        // one made) must not trip UNIQUE(item_kind,item_id) — it replaces the stale row.
        if var rebm = cards.first(where: { $0.kind == .work && $0.bookmarkID != nil }) {
            let bookmarksBefore = try store.count("bookmark")
            let oldBID = rebm.bookmarkID!
            rebm.bookmarkID = oldBID + 9_000_000   // a brand-new bookmark id, same work
            check("re-bookmark under a new id does not throw",
                  (try? store.upsertBookmark(rebm, itemKind: .work, itemID: rebm.workID)) != nil)
            check("re-bookmark keeps one row per item (no duplicate)",
                  try store.count("bookmark") == bookmarksBefore)
        }
    }

    // Store — series expansion wiring (card + member page fixtures).
    if let scHTML = try? String(contentsOf: seriesCardURL, encoding: .utf8),
       let spHTML = try? String(contentsOf: seriesPageURL, encoding: .utf8) {
        let card = try BlurbParser.parseListing(html: scHTML).first!
        let members = try BlurbParser.parseListing(html: spHTML)
        let store = try Store(inMemory: true)
        try store.upsertSeries(card)
        try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        for (i, m) in members.enumerated() {
            try store.upsertWork(m)
            try store.linkSeriesWork(seriesID: card.workID, workID: m.workID, part: i + 1)
        }
        print("Store — series expansion")
        check("1 series row", try store.count("series") == 1)
        check("6 member works", try store.count("work") == 6)
        check("6 series_work links", try store.count("series_work") == 6)
        check("series bookmark recorded", try store.count("bookmark") == 1)
        check("all 6 members queued for download", try store.worksNeedingDownload().count == 6)
    }

    // ── Gallery model: the join + pure filter/sort/facet engine (all offline) ─────────
    if let bmHTML = try? String(contentsOf: bookmarksURL, encoding: .utf8) {
        let cards = try BlurbParser.parseListing(html: bmHTML)
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let items = try store.fetchAllListItems()

        print("Gallery — fetchAllListItems join")
        check("one item per bookmark (20)", items.count == 20)
        check("no join fan-out: work 1413325 appears exactly once",
              items.filter { $0.itemID == 1413325 }.count == 1)
        // The flattened item's tags match the parsed blurb's — N tags, one row, not N rows.
        if let blurb = cards.first(where: { $0.workID == 1413325 }),
           let item = items.first(where: { $0.itemID == 1413325 }) {
            check("flattened fandoms match the blurb", item.fandoms == blurb.fandoms)
            check("flattened relationships match the blurb", item.relationships == blurb.relationships)
        }
        check("kind mapping: 19 work", items.filter { $0.kind == .work }.count == 19)
        check("kind mapping: 1 external", items.filter { $0.kind == .external }.count == 1)
        check("bookmark fields carried (bookmarkID set)", items.allSatisfy { $0.bookmarkID != nil })

        print("Gallery — filters compose")
        var f = GalleryFilter()
        f.setInclude(.bookmarkType, ["external"])
        check("type=external → 1 item", f.apply(to: items).count == 1)
        f = GalleryFilter(); f.searchText = "circus"
        check("search 'circus' → the circus work", f.apply(to: items).map(\.itemID) == [1413325])
        // Combined: a fandom AND a search term must AND together, not OR.
        f = GalleryFilter()
        f.setInclude(.bookmarkType, ["work"]); f.completion = .complete
        let composed = f.apply(to: items)
        check("type=work AND completion=complete composes",
              composed.allSatisfy { $0.kind == .work && $0.isComplete == true })
        check("composed ⊆ type=work alone",
              composed.count <= items.filter { $0.kind == .work }.count)

        print("Gallery — sort")
        let byBookmarked = GallerySort.dateBookmarked.sorted(items)
        check("date-bookmarked is newest-first (bookmarkID desc)",
              byBookmarked.first!.bookmarkID! >= byBookmarked.last!.bookmarkID!)
        let byTitle = GallerySort.title.sorted(items).map(\.title)
        check("title sort is alphabetical",
              byTitle == byTitle.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        // Derived ratio sorts: smoothed num/(den+prior) so a tiny fluke can't top the list, and
        // each ratio surfaces a different kind of fic (gem / keeper / short banger).
        let mk: (Int, String, Int, Int, Int, Int, Int) -> WorkListItem =
            { id, t, wc, ku, co, bm, hi in
                WorkListItem(itemID: id, kind: .work, sourcePath: "/w/\(id)", title: t, author: "a",
                             wordCount: wc, kudos: ku, comments: co, bookmarksCount: bm, hits: hi) }
        let ratioItems = [
            mk(1, "Blockbuster gem", 50000, 900, 50, 400, 10000),
            mk(2, "Tiny fluke",        500,   5,  1,   3,     5),  // raw kudos/hits = 100%
            mk(3, "Keeper / discussed", 5000, 100, 80, 300,  4000),
            mk(4, "Short banger",       800, 600, 10,  50,  8000),
        ]
        check("acclaim-rate smoothing: blockbuster beats the 5-hit fluke",
              GallerySort.acclaimRate.sorted(ratioItems).first?.itemID == 1)
        check("acclaim-rate never floats the tiny fluke to the top",
              GallerySort.acclaimRate.sorted(ratioItems).first?.itemID != 2)
        check("keeper-ratio ranks high saves-per-kudos first",
              GallerySort.keeperRatio.sorted(ratioItems).first?.itemID == 3)
        check("conversation-ratio ranks high comments-per-kudos first",
              GallerySort.conversationRatio.sorted(ratioItems).first?.itemID == 3)
        check("acclaim-density ranks the short banger first",
              GallerySort.acclaimDensity.sorted(ratioItems).first?.itemID == 4)
        check("collector-rate ranks high saves-per-hit first",
              GallerySort.collectorRate.sorted(ratioItems).first?.itemID == 3)
        check("isRatio flags only the derived sorts",
              GallerySort.allCases.filter(\.isRatio).count == 5 && !GallerySort.kudos.isRatio)

        print("Gallery — facets")
        let types = Facets.values(for: .bookmarkType, in: items)
        check("type facet counts sum to item count", types.reduce(0) { $0 + $1.count } == 20)
        check("work is the largest type facet", types.first?.name == "work")
        let fandomFacets = Facets.values(for: .fandom, in: items)
        let resorted = fandomFacets.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        check("fandom facets are count-desc", fandomFacets.map(\.name) == resorted.map(\.name))
        // New keyed dimensions (relationships/characters/freeforms/your-tags) come for free.
        check("relationship facets exist", !Facets.values(for: .relationship, in: items).isEmpty)
        check("character facets exist", !Facets.values(for: .character, in: items).isEmpty)
        check("freeform (additional tag) facets exist", !Facets.values(for: .freeform, in: items).isEmpty)

        print("Gallery — view model")
        let vm = GalleryViewModel()
        vm.load(from: store)
        check("VM loads all items", vm.totalCount == 20)
        vm.toggle(.bookmarkType, "external")
        check("VM toggle filters visible set", vm.visibleCount == 1)
        vm.clearFilters()
        check("VM clear restores full set", vm.visibleCount == 20)

        // Keyboard browsing (arrows + WASD map to these directions): step + clamp, no wrap.
        let nav = vm.visibleItems
        if nav.count >= 3 {
            check("neighbor(nil,.next) → first", vm.neighbor(of: nil, .next) == nav.first?.id)
            check("neighbor(nil,.previous) → last", vm.neighbor(of: nil, .previous) == nav.last?.id)
            check("neighbor steps forward one", vm.neighbor(of: nav[1].id, .next) == nav[2].id)
            check("neighbor steps back one", vm.neighbor(of: nav[1].id, .previous) == nav[0].id)
            check("neighbor clamps at top", vm.neighbor(of: nav.first?.id, .previous) == nav.first?.id)
            check("neighbor clamps at bottom", vm.neighbor(of: nav.last?.id, .next) == nav.last?.id)
        }

        // Faceted-search invariant: selecting one value in a dimension must NOT collapse
        // that dimension's facet list — other values stay visible so multi-select (OR) is
        // reachable from the sidebar. (Counts are over the set filtered by all OTHER dims.)
        let allRatings = Set(Facets.values(for: .rating, in: items).map(\.name))
        if allRatings.count > 1, let pick = allRatings.first {
            vm.clearFilters()
            vm.toggle(.rating, pick)
            let shown = Set(vm.facets(for: .rating).map(\.name))
            check("selecting a rating keeps other ratings visible in the facet",
                  shown.count > 1 && shown.isSuperset(of: allRatings))
            check("but the visible list IS narrowed to that rating",
                  vm.visibleItems.allSatisfy { $0.rating == pick })
            vm.clearFilters()
        }

        // Same self-collapse guard, but on a NEW high-cardinality dimension — the regression
        // most likely to slip through the generic refactor (relationships have many values).
        let allRels = Set(Facets.values(for: .relationship, in: items).map(\.name))
        if allRels.count > 1, let pick = allRels.first {
            vm.clearFilters()
            vm.cycle(.relationship, pick)   // → include
            let shown = Set(vm.facets(for: .relationship).map(\.name))
            check("selecting a relationship keeps other relationships visible",
                  shown.isSuperset(of: allRels))
            check("relationship include narrows the visible list",
                  vm.visibleItems.allSatisfy { $0.relationships.contains(pick) })
            vm.clearFilters()
        }

        print("Gallery — AO3 symbol classification")
        check("rating level matches rating text for every item", items.allSatisfy { i in
            let r = (i.rating ?? "").lowercased()
            switch i.ratingLevel {
            case .general:  return r.contains("general")
            case .teen:     return r.contains("teen")
            case .mature:   return r.contains("mature")
            case .explicit: return r.contains("explicit")
            case .notRated: return !["general", "teen", "mature", "explicit"].contains { r.contains($0) }
            }
        })
        check("external bookmark → external warning level",
              items.first { $0.kind == .external }?.warningLevel == .external)
        check("a comma category splits into multiple", items.contains { $0.categories.count >= 2 })
        check("no item exposes 'No category' as a badge",
              items.allSatisfy { !$0.categories.contains("No category") })

        print("Gallery — include / exclude")
        let aFandom = Facets.values(for: .fandom, in: items).first!.name
        var ex = GalleryFilter(); ex.setExclude(.fandom, [aFandom])
        let afterExclude = ex.apply(to: items)
        check("exclude fandom drops those items",
              afterExclude.allSatisfy { !$0.fandoms.contains(aFandom) })
        check("exclude yields a strict subset", afterExclude.count < items.count)
        // include + exclude compose: include rating but exclude fandom is independent.
        var both = GalleryFilter(); both.setInclude(.rating, ["Explicit"]); both.setExclude(.fandom, [aFandom])
        check("include AND exclude compose",
              both.apply(to: items).allSatisfy { $0.rating == "Explicit" && !$0.fandoms.contains(aFandom) })
        // Multi-value dim: selecting two values is AND — a work must carry every one.
        if let crossover = items.first(where: { $0.fandoms.count >= 2 }) {
            let two = Set(crossover.fandoms.prefix(2))
            var af = GalleryFilter(); af.setInclude(.fandom, two)
            let andRes = af.apply(to: items)
            check("multi-value include is AND (work carries all selected fandoms)",
                  andRes.allSatisfy { Set($0.fandoms).isSuperset(of: two) })
            check("the source crossover survives its own two fandoms",
                  andRes.contains { $0.itemID == crossover.itemID })
            var one = GalleryFilter(); one.setInclude(.fandom, [two.first!])
            check("AND of two fandoms is no wider than including one",
                  andRes.count <= one.apply(to: items).count)
        }
        // Single-valued dim: selecting two values stays OR (a work has one rating).
        let twoRatings = Set(Facets.values(for: .rating, in: items).prefix(2).map(\.name))
        if twoRatings.count == 2 {
            var rf = GalleryFilter(); rf.setInclude(.rating, twoRatings)
            let orRes = rf.apply(to: items)
            check("single-valued include is OR (rating in the selected set)",
                  orRes.allSatisfy { twoRatings.contains($0.rating ?? "") })
            check("OR over two ratings keeps something", !orRes.isEmpty)
        }

        print("Gallery — tri-state cycle")
        let vm2 = GalleryViewModel(); vm2.load(from: store)
        check("starts neutral", vm2.state(.fandom, aFandom) == .neutral)
        vm2.cycle(.fandom, aFandom)
        check("cycle 1 → include", vm2.state(.fandom, aFandom) == .include)
        check("include narrows the set", vm2.visibleCount < vm2.totalCount)
        vm2.cycle(.fandom, aFandom)
        check("cycle 2 → exclude", vm2.state(.fandom, aFandom) == .exclude)
        check("exclude removes those items",
              vm2.visibleItems.allSatisfy { !$0.fandoms.contains(aFandom) })
        vm2.cycle(.fandom, aFandom)
        check("cycle 3 → neutral (full set)", vm2.state(.fandom, aFandom) == .neutral && vm2.visibleCount == 20)
        // Cycling back to neutral must leave NO empty set behind (the invariant): filter == fresh.
        check("neutral cycle clears the dimension key (no empty set)", vm2.filter == GalleryFilter())

        print("Gallery — category filter")
        if let aCat = Facets.values(for: .category, in: items).first?.name {
            var cf = GalleryFilter(); cf.setInclude(.category, [aCat])
            check("include category keeps only items with it",
                  cf.apply(to: items).allSatisfy { $0.categories.contains(aCat) })
            check("category facets exist", !Facets.values(for: .category, in: items).isEmpty)
            cf = GalleryFilter(); cf.setExclude(.category, [aCat])
            check("exclude category drops items with it",
                  cf.apply(to: items).allSatisfy { !$0.categories.contains(aCat) })
        }

        print("Gallery — range filters")
        // Word count: items are real fixture works; pick a threshold and check both ends.
        let wcs = items.compactMap(\.wordCount).sorted()
        if let median = wcs.dropFirst(wcs.count / 2).first {
            var rf = GalleryFilter(); rf.setBound(.wordCount, NumericBound(min: Double(median)))
            check("word-count min keeps only >= median",
                  rf.apply(to: items).allSatisfy { ($0.wordCount ?? -1) >= median })
            // A series has no word count → must drop out of an active word-count range.
            check("nil-valued items drop out of an active numeric range",
                  rf.apply(to: items).allSatisfy { $0.wordCount != nil })
            rf = GalleryFilter(); rf.setBound(.wordCount, NumericBound(max: Double(median)))
            check("word-count max keeps only <= median",
                  rf.apply(to: items).allSatisfy { ($0.wordCount ?? .max) <= median })
        }
        // Inactive bound stores no key (mirrors the facet no-empty invariant).
        var rEmpty = GalleryFilter(); rEmpty.setBound(.kudos, NumericBound())
        check("an inactive bound is not stored", rEmpty == GalleryFilter() && !rEmpty.isActive)
        // Date-updated range over the known unix timestamps.
        let ups = items.compactMap(\.updatedAt).sorted()
        if let mid = ups.dropFirst(ups.count / 2).first {
            var df = GalleryFilter(); df.setBound(.dateUpdated, NumericBound(min: Double(mid)))
            check("date-updated min filters by unix ts",
                  df.apply(to: items).allSatisfy { ($0.updatedAt ?? -1) >= mid })
        }

        print("Gallery — download filter (single-select)")
        var d = GalleryFilter(); d.download = .offsite
        check("offsite → the external item", d.apply(to: items).map(\.kind) == [.external])
        d.download = .notDownloaded
        check("not-saved → the 19 pending works", d.apply(to: items).count == 19)
        d.download = .saved
        check("saved → none (nothing downloaded in fixture)", d.apply(to: items).isEmpty)

        print("Gallery — derived / bookmark booleans")
        var cf = GalleryFilter(); cf.crossover = .yes
        check("crossover=only keeps multi-fandom items",
              cf.apply(to: items).allSatisfy { $0.fandoms.count > 1 })
        cf = GalleryFilter(); cf.crossover = .no
        check("crossover=hide keeps single-fandom items",
              cf.apply(to: items).allSatisfy { $0.fandoms.count <= 1 })
        var nf = GalleryFilter(); nf.hasNotes = .yes
        check("notes=with keeps only items with bookmarker notes",
              nf.apply(to: items).allSatisfy { !($0.bookmarkerNotes ?? "").isEmpty })
        nf = GalleryFilter(); nf.hasNotes = .no
        check("notes=without keeps only items lacking notes",
              nf.apply(to: items).allSatisfy { ($0.bookmarkerNotes ?? "").isEmpty })
        // .any never narrows.
        check("crossover=any passes everything", GalleryFilter().apply(to: items).count == items.count)

        print("Gallery — saved presets round-trip")
        var pf = GalleryFilter(); pf.setInclude(.bookmarkType, ["work"]); pf.crossover = .yes
        pf.setBound(.kudos, NumericBound(min: 5))
        try store.savePreset(FilterPreset(name: "Crossover faves", filter: pf, sort: .kudos))
        let loaded = try store.loadPresets()
        check("preset persisted", loaded.count == 1 && loaded.first?.name == "Crossover faves")
        check("preset filter round-trips exactly", loaded.first?.filter == pf)
        check("preset sort round-trips", loaded.first?.sort == .kudos)
        try store.savePreset(FilterPreset(name: "Crossover faves", filter: GalleryFilter(), sort: .title))
        check("same-name save overwrites (no dup)", try store.loadPresets().count == 1)
        try store.deletePreset(name: "Crossover faves")
        check("delete removes the preset", try store.loadPresets().isEmpty)
    }

    // Series bookmark shows as one gallery item (members have no bookmark row → not listed).
    if let scHTML = try? String(contentsOf: seriesCardURL, encoding: .utf8),
       let spHTML = try? String(contentsOf: seriesPageURL, encoding: .utf8) {
        let card = try BlurbParser.parseListing(html: scHTML).first!
        let members = try BlurbParser.parseListing(html: spHTML)
        let store = try Store(inMemory: true)
        try store.upsertSeries(card)
        try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        for (i, m) in members.enumerated() {
            try store.upsertWork(m)
            try store.linkSeriesWork(seriesID: card.workID, workID: m.workID, part: i + 1)
        }
        let items = try store.fetchAllListItems()
        print("Gallery — series as a list item")
        check("series bookmark is one item", items.count == 1)
        check("its kind is series", items.first?.kind == .series)
        check("series item carries worksCount", items.first?.worksCount == 6)
        check("unbookmarked members aren't listed", items.allSatisfy { $0.kind == .series })

        let fetchedMembers = try store.fetchSeriesMembers(seriesID: card.workID)
        check("series members fetched in part order",
              fetchedMembers.map(\.itemID) == [26762044, 29369769, 35035795, 68591376, 70449741, 81922441])
    }

    // ── Scale + memoization: ~2000 synthetic items (real libraries are ~1800) ─────────
    func synthItems(_ n: Int) -> [WorkListItem] {
        let fandoms = ["Good Omens (TV)", "Star Wars", "MDZS", "Naruto", "BNHA"]
        let ratings = ["General Audiences", "Teen And Up Audiences", "Mature", "Explicit", "Not Rated"]
        let cats = ["Gen", "F/F", "F/M", "M/M", "Multi"]
        return (0..<n).map { i -> WorkListItem in
            let fandom: [String] = [fandoms[i % fandoms.count]]
            let freeform: [String] = ["tag\(i % 100)"]
            let rating: String = ratings[i % ratings.count]
            let category: String = cats[i % cats.count]
            return WorkListItem(
                itemID: i, bookmarkID: i, kind: .work,
                sourcePath: "/works/\(i)", title: "Work \(i)", author: "author\(i % 50)",
                fandoms: fandom, freeforms: freeform,
                rating: rating, category: category,
                isComplete: i % 2 == 0, wordCount: i * 10, kudos: i, hits: i * 5,
                updatedAt: 1_700_000_000 + i, downloadState: "pending")
        }
    }

    print("Gallery — scale + memoization (2000 items)")
    let vmBig = GalleryViewModel()
    vmBig.allItems = synthItems(2000)
    check("loads 2000 items", vmBig.totalCount == 2000)
    _ = vmBig.visibleItems                              // first access computes once
    let r0 = vmBig.recomputeCount
    check("first compute happened", r0 >= 1)
    for _ in 0..<200 { _ = vmBig.visibleItems; _ = vmBig.facets(for: .fandom); _ = vmBig.facets(for: .rating); _ = vmBig.facets(for: .bookmarkType) }
    check("200 repeated accesses → no extra recompute (memoized)", vmBig.recomputeCount == r0)
    vmBig.cycle(.rating, "Explicit")
    _ = vmBig.visibleItems
    check("a filter change triggers exactly one recompute", vmBig.recomputeCount == r0 + 1)
    let r1 = vmBig.recomputeCount
    for _ in 0..<200 { _ = vmBig.visibleItems; _ = vmBig.facets(for: .rating) }
    check("memoized again after the change", vmBig.recomputeCount == r1)
    check("correct at scale: only Explicit visible", vmBig.visibleItems.allSatisfy { $0.rating == "Explicit" })
    check("Explicit count == 400 (2000/5)", vmBig.visibleCount == 400)
    check("rating facet doesn't collapse at scale (all 5 listed)",
          Set(vmBig.facets(for: .rating).map(\.name)).count == 5)

    // ── M6/P0: 20k scale baseline + per-recompute regression guard ────────────────────
    // The design target is 20k bookmarks. This prints a baseline (first compute + steady-state
    // recompute = one visible filter+sort + all facet passes) and asserts the recompute stays
    // under a generous budget, so later perf phases (P2 parallel facets, P3 off-main) can prove
    // they moved the number and nothing silently regresses. Generous to survive debug/CI variance.
    print("Gallery — scale baseline (20k items, M6/P0)")
    let big20 = synthItems(20_000)
    let vm20 = GalleryViewModel()
    let t0 = Date()
    vm20.allItems = big20
    _ = vm20.visibleItems                       // first access does the full derive (visible + facets)
    let firstMs = Date().timeIntervalSince(t0) * 1000
    check("loads 20000 items", vm20.totalCount == 20_000)

    func timeRecompute(_ q: String) -> Double {
        let before = vm20.recomputeCount
        vm20.filter.searchText = q              // unique query → forces exactly one recompute
        let t = Date()
        _ = vm20.visibleItems                   // derive runs here (facets computed in the same pass)
        let ms = Date().timeIntervalSince(t) * 1000
        precondition(vm20.recomputeCount == before + 1, "expected exactly one recompute")
        return ms
    }
    var samples: [Double] = []
    for i in 0..<5 { samples.append(timeRecompute("work\(i)_\(Int.random(in: 0..<999999))")) }
    let medianMs = samples.sorted()[samples.count / 2]
    print(String(format: "  · first compute %.0f ms · median recompute %.0f ms (visible + %d facets)",
                 firstMs, medianMs, FacetDimension.allCases.count))
    check("20k full recompute stays under budget (regression guard)", medianMs < 1500)

    // Parallel facet passes must produce byte-identical results to a serial computation
    // (deterministic: each dimension writes its own slot, reassembled in order) — M6/P2.
    vm20.cycle(.rating, "Explicit")             // an active filter, so faceting has real work
    let parallelOK = FacetDimension.allCases.allSatisfy { dim in
        let serial = Facets.values(for: dim, in: vm20.filter.clearing(dim).apply(to: big20))
        let parallel = vm20.facets(for: dim)
        return serial.count == parallel.count
            && zip(serial, parallel).allSatisfy { $0.name == $1.name && $0.count == $1.count }
    }
    check("parallel facets == serial facets (all dimensions)", parallelOK)

    print("Store — meta + index resume")
    let metaStore = try Store(inMemory: true)
    check("meta nil initially", try metaStore.getMeta("k") == nil)
    try metaStore.setMeta("k", "v1"); check("meta set/get", try metaStore.getMeta("k") == "v1")
    try metaStore.setMeta("k", "v2"); check("meta upsert overwrites", try metaStore.getMeta("k") == "v2")
    try metaStore.clearMeta("k"); check("meta clear", try metaStore.getMeta("k") == nil)
    check("pageNumber parses page=16",
          SyncEngine.pageNumber(inPath: "/users/x/bookmarks?view_adult=true&page=16") == 16)
    check("pageNumber nil without page", SyncEngine.pageNumber(inPath: "/users/x/bookmarks") == nil)

    print("SyncEngine — incremental stop conditions")
    // New-bookmarks pass: stop once every bookmark on the page is already known.
    check("noNewBookmarks: all known → stop",
          SyncEngine.noNewBookmarks(pageIDs: [1, 2, 3], known: [1, 2, 3, 4]))
    check("noNewBookmarks: one new → keep going",
          !SyncEngine.noNewBookmarks(pageIDs: [1, 2, 9], known: [1, 2]))
    check("noNewBookmarks: empty page → stop", SyncEngine.noNewBookmarks(pageIDs: [], known: []))
    // Updated-works pass frontier (cards in date-updated order).
    let recent = WorkBlurb(kind: .work, sourcePath: "/works/1", workID: 1, title: "t", author: "a", updatedAt: 200)
    let old = WorkBlurb(kind: .work, sourcePath: "/works/2", workID: 2, title: "t", author: "a", updatedAt: 50)
    check("reachedUpdateFrontier: no watermark → never stop (page cap only)",
          !SyncEngine.reachedUpdateFrontier(pageCards: [old], since: nil))
    check("reachedUpdateFrontier: a card newer than the watermark → keep going",
          !SyncEngine.reachedUpdateFrontier(pageCards: [recent, old], since: 100))
    check("reachedUpdateFrontier: whole page predates the watermark → stop",
          SyncEngine.reachedUpdateFrontier(pageCards: [old], since: 100))
    let undated = WorkBlurb(kind: .work, sourcePath: "/works/3", workID: 3, title: "t", author: "a", updatedAt: nil)
    check("reachedUpdateFrontier: an unparseable date doesn't end the pass early (L4)",
          !SyncEngine.reachedUpdateFrontier(pageCards: [old, undated], since: 100))
    // Date-updated sort is injected into the listing path (brackets percent-encoded).
    check("sortedByDateUpdated appends to an existing query",
          SyncEngine.sortedByDateUpdated("/users/x/bookmarks?page=1")
            == "/users/x/bookmarks?page=1&bookmark_search%5Bsort_column%5D=bookmarkable_date")
    check("sortedByDateUpdated starts a query when none",
          SyncEngine.sortedByDateUpdated("/users/x/bookmarks")
            == "/users/x/bookmarks?bookmark_search%5Bsort_column%5D=bookmarkable_date")

    print("WorkDownloader")
    let menu = """
    <li class="download"><ul>
      <li><a href="/downloads/9/T.azw3?updated_at=1">AZW3</a></li>
      <li><a href="/downloads/9/T.epub?updated_at=1">EPUB</a></li>
    </ul></li>
    """
    check("extracts epub href", try WorkDownloader.epubHref(fromWorkHTML: menu) == "/downloads/9/T.epub?updated_at=1")
    check("nil when no menu", try WorkDownloader.epubHref(fromWorkHTML: "<p>locked</p>") == nil)
    check("epub magic true", WorkDownloader.looksLikeEPUB(Data([0x50, 0x4B, 0x03, 0x04])))
    check("epub magic false", !WorkDownloader.looksLikeEPUB(Data("<htm".utf8)))
    // Security: a hostile work page with no real download menu must NOT yield an off-site
    // absolute href — the anchored `^=/downloads/` selector skips it.
    let evilMenu = #"<p>locked</p><a href="https://evil.example/downloads/x.epub">grab</a>"#
    check("ignores absolute off-site /downloads/ link", try WorkDownloader.epubHref(fromWorkHTML: evilMenu) == nil)
    // L3: an absolute href injected inside a `li.download` wrapper must be skipped by the
    // primary selector too (also anchored `^=/downloads/`), not just the fallback.
    let evilWrapper = #"<li class="download"><a href="https://evil.example/downloads/x.epub">EPUB</a></li>"#
    check("ignores absolute href inside li.download wrapper (L3)",
          try WorkDownloader.epubHref(fromWorkHTML: evilWrapper) == nil)
} catch {
    FileHandle.standardError.write(Data("threw: \(error)\n".utf8))
    exit(1)
}

// Security: host allowlist (cookie / User-Agent / SSRF gate).
check("isAO3Host accepts apex", AO3Client.isAO3Host("archiveofourown.org"))
check("isAO3Host accepts subdomain", AO3Client.isAO3Host("download.archiveofourown.org"))
check("isAO3Host rejects lookalike suffix", !AO3Client.isAO3Host("evil-archiveofourown.org"))
check("isAO3Host rejects foreign host", !AO3Client.isAO3Host("evil.example"))
check("isAO3Host rejects nil", !AO3Client.isAO3Host(nil))

// Security: username path-component encoding (no route/query injection).
check("encodePathComponent passes a clean handle", AO3Config.encodePathComponent("Some_User-1") == "Some_User-1")
check("encodePathComponent escapes a slash", AO3Config.encodePathComponent("a/b") == "a%2Fb")
check("encodePathComponent escapes a query injection", !AO3Config.encodePathComponent("u?page=9").contains("?"))

// Cookie normalization: bare value passes; pasted pair/whitespace/extra cookies get stripped.
check("sanitizeCookie keeps a bare value", AO3Config.sanitizeCookie("abc123") == "abc123")
check("sanitizeCookie trims whitespace/newlines", AO3Config.sanitizeCookie("  abc123\n") == "abc123")
check("sanitizeCookie strips the name= prefix", AO3Config.sanitizeCookie("_otwarchive_session=abc123") == "abc123")
check("sanitizeCookie drops trailing cookies", AO3Config.sanitizeCookie("abc123; other=x") == "abc123")
check("sanitizeCookie strips prefix and trailing junk together",
      AO3Config.sanitizeCookie(" _otwarchive_session=abc123; other=x ") == "abc123")
check("sanitizeCookie finds the session pair when it isn't first",
      AO3Config.sanitizeCookie("view_adult=true; _otwarchive_session=abc123; x=y") == "abc123")
check("sanitizeCookie nil for empty/whitespace", AO3Config.sanitizeCookie("   ") == nil)
check("sanitizeCookie nil for nil", AO3Config.sanitizeCookie(nil) == nil)

// Cloudflare "shields up" detection — surfaced plainly, not retried into a confusing failure.
check("isCloudflareEdge accepts 52x", AO3Client.isCloudflareEdge(525) && AO3Client.isCloudflareEdge(520))
check("isCloudflareEdge accepts 530", AO3Client.isCloudflareEdge(530))
check("isCloudflareEdge rejects origin 503", !AO3Client.isCloudflareEdge(503))
do {
    let url = URL(string: "https://archiveofourown.org/")!
    func resp(_ code: Int, _ h: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: h)!
    }
    let challenge = Data("<title>Just a moment...</title>".utf8)
    check("cf challenge via cf-mitigated header",
          AO3Client.isCloudflareChallenge(resp(403, ["cf-mitigated": "challenge"]), Data()))
    check("cf challenge via served-by-CF + body marker",
          AO3Client.isCloudflareChallenge(resp(503, ["Server": "cloudflare"]), challenge))
    check("real CF-served page is not a challenge",
          !AO3Client.isCloudflareChallenge(resp(200, ["server": "cloudflare", "cf-ray": "x"]),
                                           Data("Log Out".utf8)))
    check("non-CF response is never a challenge",
          !AO3Client.isCloudflareChallenge(resp(503, [:]), challenge))
}
check("cloudflare shields-up message names the cause",
      "\(AO3Error.cloudflare(status: 503, shieldsUp: true))".contains("shields up"))
check("cloudflare edge message names the code",
      "\(AO3Error.cloudflare(status: 525, shieldsUp: false))".contains("525"))
check("cloudflare message omits a zero status", !"\(AO3Error.cloudflare(status: 0, shieldsUp: false))".contains("0"))
check("cloudflareWallKind: challenge body → true",
      AO3Client.cloudflareWallKind(inBody: Data("<title>Just a moment...</title>".utf8)) == true)
check("cloudflareWallKind: error page → false",
      AO3Client.cloudflareWallKind(inBody: Data("<h1>525: SSL handshake failed</h1>".utf8)) == false)
check("cloudflareWallKind: real content → nil",
      AO3Client.cloudflareWallKind(inBody: Data("<html>The Devil's Daughter</html>".utf8)) == nil)
check("cloudflareWallKind: EPUB zip → nil",
      AO3Client.cloudflareWallKind(inBody: Data([0x50, 0x4B, 0x03, 0x04])) == nil)

// Security: count(_:) rejects an unknown table name (interpolated identifier).
if let secStore = try? Store(inMemory: true) {
    check("count rejects an unknown table", (try? secStore.count("work; DROP TABLE work")) == nil)
    check("count still works for a known table", (try? secStore.count("work")) == 0)
}

// Security: parsed sourcePath is canonical (built from the validated id, not the raw href).
let canonHTML = #"<li class="work blurb group" id="work_42"><h4 class="heading"><a href="https://evil.example/works/42/chapters/9">T</a></h4></li>"#
if let canon = try? BlurbParser.parseListing(html: canonHTML).first {
    check("sourcePath is canonical /works/<id>", canon.sourcePath == "/works/42")
}

// EPUB reader (kept in lockstep with EpubReaderTests). Builds a synthetic EPUB in both
// TOC flavours and parses it; exercises the pure ReaderSession/Settings + reading-position
// persistence. Real-AO3-EPUB validation is a manual fixture step (PLAN-READER.md §9).
func makeSyntheticEpub(useNCX: Bool) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("selftest-epub-\(useNCX ? "ncx" : "nav")-\(UUID().uuidString).epub")
    let archive = try Archive(url: url, accessMode: .create)
    func add(_ path: String, _ s: String) throws {
        let data = Data(s.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }
    try add("mimetype", "application/epub+zip")
    try add("META-INF/container.xml", """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
    for (i, n) in ["One", "Two", "Three"].enumerated() {
        try add("OEBPS/ch\(i + 1).xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>Chapter \(n)</h1></body></html>")
    }
    let meta = "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Synthetic Work</dc:title><dc:creator>Test Author</dc:creator><dc:language>en</dc:language></metadata>"
    let manifestItems = "<item id=\"c1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c3\" href=\"ch3.xhtml\" media-type=\"application/xhtml+xml\"/>"
    let spineItems = "<itemref idref=\"c1\"/><itemref idref=\"c2\"/><itemref idref=\"c3\"/>"
    if useNCX {
        try add("OEBPS/content.opf", "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"b\">\(meta)<manifest><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\(manifestItems)</manifest><spine toc=\"ncx\">\(spineItems)</spine></package>")
        try add("OEBPS/toc.ncx", "<?xml version=\"1.0\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><navMap><navPoint id=\"n1\"><navLabel><text>Chapter One</text></navLabel><content src=\"ch1.xhtml\"/></navPoint><navPoint id=\"n2\"><navLabel><text>Chapter Two</text></navLabel><content src=\"ch2.xhtml\"/></navPoint><navPoint id=\"n3\"><navLabel><text>Chapter Three</text></navLabel><content src=\"ch3.xhtml\"/></navPoint></navMap></ncx>")
    } else {
        try add("OEBPS/content.opf", "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"b\">\(meta)<manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\(manifestItems)</manifest><spine>\(spineItems)</spine></package>")
        try add("OEBPS/nav.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml\">Chapter One</a></li><li><a href=\"ch2.xhtml\">Chapter Two</a></li><li><a href=\"ch3.xhtml\">Chapter Three</a></li></ol></nav></body></html>")
    }
    return url
}

// Mirrors a real AO3/calibre EPUB: 5 spine docs [preface, titlePage, ch1, ch2, afterword]
// where the NCX lists Preface/Ch1/Ch2/Afterword but NOT the title page. Chapter 1 carries a
// `&nbsp;` entity and a remote image, to exercise entity-safe rendering + sanitization.
func makeAO3LikeEpub() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ao3like-\(UUID().uuidString).epub")
    let archive = try Archive(url: url, accessMode: .create)
    func add(_ path: String, _ s: String) throws {
        let data = Data(s.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }
    func page(_ body: String) -> String {
        "<?xml version='1.0' encoding='utf-8'?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title></head><body>\(body)</body></html>"
    }
    try add("mimetype", "application/epub+zip")
    try add("META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
    try add("split_000.xhtml", page("<h2>Preface</h2><p>tags and summary</p>"))
    try add("split_001.xhtml", page("<h1>The Work Title</h1>"))   // title page, absent from NCX
    try add("split_002.xhtml", page("<h2>Chapter 1</h2><p>Before&nbsp;<span>AFTER the entity</span></p><img src=\"https://evil.example/t.png\"/>"))
    try add("split_003.xhtml", page("<h2>Chapter 2</h2><p>more</p>"))
    try add("split_004.xhtml", page("<h2>Afterword</h2><p>end notes</p>"))
    let items = (0...4).map { "<item id=\"h\($0)\" href=\"split_00\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
    let spine = (0...4).map { "<itemref idref=\"h\($0)\"/>" }.joined()
    try add("content.opf", "<?xml version='1.0'?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"b\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>The Work Title</dc:title><dc:creator>Auth</dc:creator></metadata><manifest>\(items)<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/></manifest><spine toc=\"ncx\">\(spine)</spine></package>")
    try add("toc.ncx", "<?xml version='1.0'?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><navMap><navPoint id=\"a\"><navLabel><text>Preface</text></navLabel><content src=\"split_000.xhtml\"/></navPoint><navPoint id=\"b\"><navLabel><text>Chapter 1</text></navLabel><content src=\"split_002.xhtml\"/></navPoint><navPoint id=\"c\"><navLabel><text>Chapter 2</text></navLabel><content src=\"split_003.xhtml\"/></navPoint><navPoint id=\"d\"><navLabel><text>Afterword</text></navLabel><content src=\"split_004.xhtml\"/></navPoint></navMap></ncx>")
    return url
}

print("EpubDocument — synthetic EPUB (nav + ncx)")
for useNCX in [false, true] {
    if let url = try? makeSyntheticEpub(useNCX: useNCX), let doc = try? EpubDocument(url: url) {
        let flavour = useNCX ? "ncx" : "nav"
        check("[\(flavour)] title parsed", doc.metadata.title == "Synthetic Work")
        check("[\(flavour)] author parsed", doc.metadata.author == "Test Author")
        check("[\(flavour)] opfDirectory == OEBPS", doc.opfDirectory == "OEBPS")
        check("[\(flavour)] spine has 3 docs", doc.spine.count == 3)
        check("[\(flavour)] spine paths", doc.spine.map(\.path) == ["OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/ch3.xhtml"])
        check("[\(flavour)] 3 reading sections", doc.sectionCount == 3)
        check("[\(flavour)] section titles", doc.sectionTitles == ["Chapter One", "Chapter Two", "Chapter Three"])
        check("[\(flavour)] chapter body readable", (try? doc.bodyHTML(forSpineIndex: 0).contains("Chapter One")) == true)
        let whole = doc.wholeWorkHTML(css: "x{}")
        check("[\(flavour)] whole-work doc has all sections", whole.contains("ao3-sec-0") && whole.contains("ao3-sec-2"))
        // WASD scrolling (mirrors arrow keys) ships in both reading modes.
        check("[\(flavour)] whole-work doc has WASD scrolling", whole.contains("window.scrollBy"))
        check("[\(flavour)] chapter doc has WASD scrolling", doc.chapterHTML(sectionIndex: 0, css: "x{}").contains("window.scrollBy"))
        try? FileManager.default.removeItem(at: url)
    } else {
        check("synthetic EPUB (\(useNCX ? "ncx" : "nav")) builds + parses", false)
    }
}

print("EpubSanitizer — no-remote-requests invariant")
let dirty = "<html><body><img src=\"https://evil.example/t.png\"/><img src=\"local.png\"/><script>fetch('https://evil.example')</script><a href=\"https://evil.example\">x</a><p onload=\"fetch('x')\">h</p></body></html>"
let cleaned = EpubSanitizer.sanitize(dirty)
check("strips remote refs", !cleaned.contains("evil.example"))
check("strips <script>", !cleaned.lowercased().contains("<script"))
check("strips on* handlers", !cleaned.lowercased().contains("onload"))
check("keeps local resources", cleaned.contains("local.png"))
check("isRemote classifies https", EpubSanitizer.isRemote("https://x/a.png"))
check("isRemote classifies protocol-relative", EpubSanitizer.isRemote("//x/a.png"))
check("isRemote keeps relative local", !EpubSanitizer.isRemote("images/a.png"))

// Remote CSS (zero-click subresource loads) — <style> blocks and inline style="…url()", incl.
// the escaped form (\68ttps://) that a host-matching denylist would miss.
let dirtyCSS = "<html><head><style>@import url(\"https://evil.example/b.css\");p{background:url(https://evil.example/x.png)}</style></head><body><p style=\"background:url(https://evil.example/t.png)\">a</p><p style=\"background:url(//evil.example/t2.png)\">b</p><p style=\"background:url(\\68ttps://evil.example/esc.png)\">e</p><p style=\"color:red\">c</p><div style=\"background:url(images/local.png)\">d</div></body></html>"
let cleanedCSS = EpubSanitizer.sanitize(dirtyCSS)
check("strips remote CSS refs (incl. escaped)", !cleanedCSS.contains("evil.example"))
check("drops <style> element", !cleanedCSS.lowercased().contains("<style"))
check("keeps benign inline style", cleanedCSS.contains("color:red"))
check("drops any url()-bearing inline style", !cleanedCSS.contains("images/local.png"))
check("keeps the element under a dropped style", cleanedCSS.contains("<div"))
// Script-executing schemes in href/action — never reach the WebView nav delegate.
let dirtyScheme = "<html><body><a href=\"javascript:fetch('https://evil.example/')\">x</a><a href=\"VBScript:x\">y</a><a href=\"ch2.xhtml#top\">l</a><form action=\"javascript:steal()\"></form></body></html>"
let cleanedScheme = EpubSanitizer.sanitize(dirtyScheme)
check("strips javascript: href", !cleanedScheme.lowercased().contains("javascript:"))
check("strips vbscript: href", !cleanedScheme.lowercased().contains("vbscript:"))
check("keeps local href", cleanedScheme.contains("ch2.xhtml#top"))
check("hasDangerousScheme classifies javascript:", EpubSanitizer.hasDangerousScheme("javascript:x"))
check("hasDangerousScheme sees through tab obfuscation", EpubSanitizer.hasDangerousScheme("java\tscript:x"))
check("hasDangerousScheme ignores https", !EpubSanitizer.hasDangerousScheme("https://x/a"))
check("styleMayLoadResource classifies remote url()", EpubSanitizer.styleMayLoadResource("background:url(https://x/a.png)"))
check("styleMayLoadResource classifies escaped url()", EpubSanitizer.styleMayLoadResource("background:url(\\68ttps://x/a.png)"))
check("styleMayLoadResource catches even local url()", EpubSanitizer.styleMayLoadResource("background:url(images/a.png)"))
check("styleMayLoadResource keeps benign style", !EpubSanitizer.styleMayLoadResource("color:red"))

print("EpubDocument — path helpers")
check("resolvePath joins", EpubDocument.resolvePath(base: "OEBPS", href: "ch1.xhtml") == "OEBPS/ch1.xhtml")
check("resolvePath handles ..", EpubDocument.resolvePath(base: "OEBPS/text", href: "../img/x.png") == "OEBPS/img/x.png")
check("directory(of:)", EpubDocument.directory(of: "OEBPS/content.opf") == "OEBPS")

print("EpubDocument — section folding (front matter / title page)")
// AO3 shape: spine [preface, titlePage, ch1, ch2, afterword]; NCX skips the title page.
if let foldURL = try? makeAO3LikeEpub(), let fdoc = try? EpubDocument(url: foldURL) {
    check("spine has 5 docs", fdoc.spine.count == 5)
    check("folds into 4 sections (title page absorbed)", fdoc.sectionCount == 4)
    check("section titles from NCX", fdoc.sectionTitles == ["Preface", "Chapter 1", "Chapter 2", "Afterword"])
    check("Preface section absorbs title page (spine 0+1)", fdoc.sections.first?.spineIndices == [0, 1])
    // Entity safety: a chapter with &nbsp; renders fully (no XML truncation) once generated.
    let chHTML = fdoc.chapterHTML(sectionIndex: 1, css: "")
    check("nbsp chapter not truncated", chHTML.contains("AFTER the entity"))
    // Generated doc carries no remote refs (built from sanitized bodies).
    check("generated doc has no remote refs", !chHTML.contains("evil.example"))
    // Scroll mode carries the scroll reporter; chapter mode doesn't.
    check("scroll doc has reporter", fdoc.wholeWorkHTML(css: "x{}").contains("messageHandlers.reader"))
    check("chapter doc has no reporter", !chHTML.contains("messageHandlers.reader"))
    // bodyHTML is cached/stable across calls.
    check("bodyHTML stable when cached", (try? fdoc.bodyHTML(forSpineIndex: 2)) == (try? fdoc.bodyHTML(forSpineIndex: 2)))
    try? FileManager.default.removeItem(at: foldURL)
} else {
    check("AO3-like EPUB builds + parses", false)
}

print("ReaderSession — navigation")
var rs = ReaderSession(unitCount: 3)
check("starts at 0", rs.index == 0 && !rs.canGoPrevious)
_ = rs.goNext(); _ = rs.goNext()
check("advances and clamps at end", rs.index == 2 && !rs.canGoNext && rs.goNext() == false)
check("progress at end == 1", rs.progress == 1.0)
_ = rs.goPrevious()
check("goPrevious works", rs.index == 1)
check("init clamps over-range start", ReaderSession(unitCount: 3, index: 99).index == 2)
var empty = ReaderSession(unitCount: 0)
check("empty session is safe", empty.goNext() == false && empty.progress == 0)

print("ReaderSettings — CSS + clamping")
let clamped = ReaderSettings(theme: .sepia, fontScale: 9, lineSpacing: 0.1, fontFamily: "Palatino")
check("fontScale clamps high", clamped.fontScale == ReaderSettings.fontScaleRange.upperBound)
check("lineSpacing clamps low", clamped.lineSpacing == ReaderSettings.lineSpacingRange.lowerBound)
check("CSS encodes theme + font %", clamped.injectedCSS.contains("theme: sepia") && clamped.injectedCSS.contains("200%"))
check("CSS styles reader sections", clamped.injectedCSS.contains("section.ao3-chapter"))
check("CSS quotes named serif face", clamped.injectedCSS.contains("\"Palatino\", Georgia") && clamped.injectedCSS.contains("serif;"))
let ao3Font = ReaderSettings(fontFamily: ReaderSettings.ao3FontName)
check("CSS emits AO3 sans stack", ao3Font.injectedCSS.contains("'Lucida Grande'") && ao3Font.injectedCSS.contains("sans-serif;") && !ao3Font.injectedCSS.contains("\"AO3\""))
check("AO3 is offered in font catalog", ReaderSettings.availableFonts.contains(ReaderSettings.ao3FontName))
check("CSS round-trips Codable", (try? JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(clamped))) == clamped)

print("Store — reading position")
if let posStore = try? Store(inMemory: true) {
    try? posStore.upsertWork(WorkBlurb(workID: 7, title: "W", author: "A"))
    check("no position before save", (try? posStore.readingPosition(workID: 7)) ?? nil == nil)
    try? posStore.saveReadingPosition(workID: 7, spineIndex: 2, progress: 0.5)
    check("position persists", (try? posStore.readingPosition(workID: 7))??.spineIndex == 2)
    try? posStore.saveReadingPosition(workID: 7, spineIndex: 4, progress: 0.8)
    check("position upserts", (try? posStore.readingPosition(workID: 7))??.spineIndex == 4)
}

print("KindleExport — title building")
check("abbrev nil/0 omits", KindleExport.abbreviateWords(nil) == nil && KindleExport.abbreviateWords(0) == nil)
check("abbrev <1k", KindleExport.abbreviateWords(999) == "<1k words")
check("abbrev 10k", KindleExport.abbreviateWords(10_000) == "10k words")
check("abbrev 1.5M", KindleExport.abbreviateWords(1_500_000) == "1.5M words")
check("suffix fandom + words", KindleExport.titleSuffix(fandoms: ["Harry Potter - J. K. Rowling", "Cyberpunk 2077"], wordCount: 10_000) == "(Harry Potter/Cyberpunk 2077, 10k words)")
check("suffix caps to 2 fandoms with +", KindleExport.titleSuffix(fandoms: ["A", "B", "C"], wordCount: nil) == "(A/B+)")
check("suffix empty → nil", KindleExport.titleSuffix(fandoms: [], wordCount: nil) == nil)
check("title appends", KindleExport.kindleTitle("My Fic", fandoms: ["Marvel"], wordCount: 3_000) == "My Fic (Marvel, 3k words)")
check("splice escapes &", KindleExport.spliceTitle(in: "<dc:title>Old</dc:title>", to: "X & Y") == "<dc:title>X &amp; Y</dc:title>")

check("info page is well-formed XML + escapes &", {
    let html = KindleExport.infoPageXHTML(for: .init(title: "A & B", author: "X", rating: "Explicit", wordCount: 12_345))
    return (try? XMLDocument(xmlString: html)) != nil && html.contains("A &amp; B") && html.contains("12,345 words")
}())
check("chapterText WIP", KindleExport.chapterText(have: 3, total: nil) == "3/? chapters")
check("cover renders as JPEG", {
    guard let d = KindleCover.renderJPEG(for: .init(title: "A Fic", author: "Auth", fandoms: ["Marvel"], wordCount: 10_000)) else { return false }
    return d.prefix(2) == Data([0xFF, 0xD8]) && d.count > 1_000
}())

print("KindleExport — EPUB round-trip")
if let kSrc = try? makeSyntheticEpub(useNCX: true),
   let kSpine = try? EpubDocument(url: kSrc).spine.count,
   let kOut = try? KindleExport.makeKindleEPUB(source: kSrc, work: .init(title: "Synthetic Work", author: "Auth", fandoms: ["Harry Potter - J. K. Rowling"], wordCount: 10_000)),
   let kDoc = try? EpubDocument(url: kOut) {
    check("Kindle EPUB reopens with badged title", kDoc.metadata.title == "Synthetic Work (Harry Potter, 10k words)")
    check("Kindle EPUB prepends info page as first spine item", kDoc.spine.count == kSpine + 1 && (kDoc.spine.first?.path.hasSuffix(KindleExport.infoPageFilename) ?? false))
    try? FileManager.default.removeItem(at: kOut)
} else {
    check("KindleExport round-trip", false)
}

print("")
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}

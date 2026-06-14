import Foundation
import AO3Kit

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

        // Stale detection: AO3 shows a newer updated_at → it re-enters the queue.
        if var staleCard = cards.first(where: { $0.workID == first.id }) {
            staleCard.updatedAt = (first.updatedAt ?? 0) + 1
            try store.upsertWork(staleCard)
            check("a newer updated_at marks the work stale (back to 19)",
                  try store.worksNeedingDownload().count == 19)
        }

        // A failed download must be RETRYABLE (anon run → add cookie → re-run picks it up):
        // marking failed records the error but must NOT remove it from the download queue.
        let queueBeforeFail = try store.worksNeedingDownload().count
        let toFail = try store.worksNeedingDownload().first!
        try store.markFailed(workID: toFail.id, error: "requires login")
        check("a failed download stays in the queue (retryable across runs)",
              try store.worksNeedingDownload().count == queueBeforeFail)

        // FTS: a word from a real title is findable.
        check("FTS finds 'circus' (work 1413325)", try store.searchWorkIDs("circus").contains(1413325))
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
        f.bookmarkTypes = [.external]
        check("type=external → 1 item", f.apply(to: items).count == 1)
        f = GalleryFilter(); f.searchText = "circus"
        check("search 'circus' → the circus work", f.apply(to: items).map(\.itemID) == [1413325])
        // Combined: a fandom AND a search term must AND together, not OR.
        f = GalleryFilter()
        f.bookmarkTypes = [.work]; f.completion = .complete
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

        print("Gallery — facets")
        let types = Facets.bookmarkTypes(items)
        check("type facet counts sum to item count", types.reduce(0) { $0 + $1.count } == 20)
        check("work is the largest type facet", types.first?.name == "work")
        let fandomFacets = Facets.fandoms(items)
        let resorted = fandomFacets.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        check("fandom facets are count-desc", fandomFacets.map(\.name) == resorted.map(\.name))

        print("Gallery — view model")
        let vm = GalleryViewModel()
        vm.load(from: store)
        check("VM loads all items", vm.totalCount == 20)
        vm.toggleType(.external)
        check("VM toggle filters visible set", vm.visibleCount == 1)
        vm.clearFilters()
        check("VM clear restores full set", vm.visibleCount == 20)

        // Faceted-search invariant: selecting one value in a dimension must NOT collapse
        // that dimension's facet list — other values stay visible so multi-select (OR) is
        // reachable from the sidebar. (Counts are over the set filtered by all OTHER dims.)
        let allRatings = Set(Facets.ratings(items).map(\.name))
        if allRatings.count > 1, let pick = allRatings.first {
            vm.clearFilters()
            vm.toggleRating(pick)
            let shown = Set(vm.ratingFacets.map(\.name))
            check("selecting a rating keeps other ratings visible in the facet",
                  shown.count > 1 && shown.isSuperset(of: allRatings))
            check("but the visible list IS narrowed to that rating",
                  vm.visibleItems.allSatisfy { $0.rating == pick })
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
        let aFandom = Facets.fandoms(items).first!.name
        var ex = GalleryFilter(); ex.excludeFandoms = [aFandom]
        let afterExclude = ex.apply(to: items)
        check("exclude fandom drops those items",
              afterExclude.allSatisfy { !$0.fandoms.contains(aFandom) })
        check("exclude yields a strict subset", afterExclude.count < items.count)
        // include + exclude compose: include fandom A but exclude tag-set is independent.
        var both = GalleryFilter(); both.ratings = ["Explicit"]; both.excludeFandoms = [aFandom]
        check("include AND exclude compose",
              both.apply(to: items).allSatisfy { $0.rating == "Explicit" && !$0.fandoms.contains(aFandom) })

        print("Gallery — tri-state cycle")
        let vm2 = GalleryViewModel(); vm2.load(from: store)
        check("starts neutral", vm2.fandomState(aFandom) == .neutral)
        vm2.cycleFandom(aFandom)
        check("cycle 1 → include", vm2.fandomState(aFandom) == .include)
        check("include narrows the set", vm2.visibleCount < vm2.totalCount)
        vm2.cycleFandom(aFandom)
        check("cycle 2 → exclude", vm2.fandomState(aFandom) == .exclude)
        check("exclude removes those items",
              vm2.visibleItems.allSatisfy { !$0.fandoms.contains(aFandom) })
        vm2.cycleFandom(aFandom)
        check("cycle 3 → neutral (full set)", vm2.fandomState(aFandom) == .neutral && vm2.visibleCount == 20)

        print("Gallery — download filter (single-select)")
        var d = GalleryFilter(); d.download = .offsite
        check("offsite → the external item", d.apply(to: items).map(\.kind) == [.external])
        d.download = .notDownloaded
        check("not-saved → the 19 pending works", d.apply(to: items).count == 19)
        d.download = .saved
        check("saved → none (nothing downloaded in fixture)", d.apply(to: items).isEmpty)
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
} catch {
    FileHandle.standardError.write(Data("threw: \(error)\n".utf8))
    exit(1)
}

print("")
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}

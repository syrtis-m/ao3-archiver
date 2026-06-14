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

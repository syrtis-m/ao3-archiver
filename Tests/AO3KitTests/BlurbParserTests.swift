import Testing
import Foundation
@testable import AO3Kit

/// Tests run against real AO3 HTML captured into Fixtures/works_listing.html, so they
/// pin the parser to the actual markup rather than to assumptions.
@Suite struct BlurbParserTests {

    func fixtureHTML() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "works_listing", withExtension: "html", subdirectory: "Fixtures"),
            "fixture not found in test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesAllCardsOnPage() throws {
        let blurbs = try BlurbParser.parseListing(html: fixtureHTML())
        #expect(blurbs.count == 20)   // AO3 renders 20 works per listing page
    }

    @Test func firstCardFieldsMatchSource() throws {
        let b = try #require(BlurbParser.parseListing(html: fixtureHTML()).first)

        #expect(b.workID == 85487886)
        #expect(b.title == "Sarcasm and Sanctuary")
        #expect(b.author == "haleinedelail")
        #expect(b.authorURL == "/users/haleinedelail/pseuds/haleinedelail")
        #expect(b.fandoms == ["Good Omens (TV)"])
        #expect(b.rating == "Explicit")
        #expect(b.category == "M/M")
        #expect(b.isComplete == false)                  // "Work in Progress" symbol
        #expect(b.language == "English")
        #expect(b.wordCount == 12328)                   // from "12,328"
        #expect(b.chaptersHave == 4)
        #expect(b.chaptersTotal == nil)                 // "4/?" ⇒ unknown total
        #expect(b.comments == 5)
        #expect(b.kudos == 18)
        #expect(b.bookmarksCount == 2)
        #expect(b.hits == 198)
        #expect(b.dateText == "13 Jun 2026")
        #expect(b.updatedAt == 1781388945)              // from "<!-- updated_at=… -->"

        #expect(b.warnings.contains("Creator Chose Not To Use Archive Warnings"))
        #expect(b.freeforms.contains("Hinduism"))
        #expect(b.characters.contains("New Universe Anthony Crowley (Good Omens)"))
        #expect(b.relationships.count == 2)
        #expect(b.summary?.contains("Prof. Anthony Crowley") == true)
    }

    @Test func parsesRealBookmarksPage() throws {
        let url = try #require(
            Bundle.module.url(forResource: "bookmarks_page", withExtension: "html", subdirectory: "Fixtures"))
        let blurbs = try BlurbParser.parseListing(html: String(contentsOf: url, encoding: .utf8))
        // 20 bookmark cards = 19 AO3 works + 1 external-work bookmark. All recorded;
        // `kind` distinguishes them so external bookmarks are filterable, not lost.
        #expect(blurbs.count == 20)
        #expect(blurbs.filter { $0.kind == .work }.count == 19)
        let external = blurbs.filter { $0.kind == .external }
        #expect(external.count == 1)
        #expect(external.first?.author == "agrippa")             // plain-text author
        #expect(external.first?.sourcePath.contains("/external_works/") == true)
        #expect(external.first?.wordCount == nil)
        #expect(blurbs.first?.workID == 1413325)
        #expect(blurbs.first?.title == "circus girl without a safety net")
    }

    @Test func bookmarkSpecificFieldsAndPagination() throws {
        let url = try #require(
            Bundle.module.url(forResource: "bookmarks_page", withExtension: "html", subdirectory: "Fixtures"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let blurbs = try BlurbParser.parseListing(html: html)
        // Every bookmark card carries a bookmark id and the (distinct) bookmark date.
        #expect(blurbs.allSatisfy { $0.bookmarkID != nil })
        #expect(blurbs.allSatisfy { $0.bookmarkedAt != nil })
        let first = try #require(blurbs.first)
        #expect(first.bookmarkedAt == "30 May 2026")     // bookmark date…
        #expect(first.dateText == "04 Apr 2014")         // …distinct from the work date
        #expect(blurbs.allSatisfy { !$0.isPrivate })     // all 20 public in this capture
        #expect(blurbs.allSatisfy { !$0.isRec })
        // Pagination: the Next link resolves; absence yields nil.
        #expect(try BlurbParser.nextPagePath(html: html)?.contains("page=2") == true)
        #expect(try BlurbParser.nextPagePath(html: "<ol class=\"pagination\"></ol>") == nil)
        // Total page count (for "page N of T" progress).
        #expect(try BlurbParser.lastPageNumber(html: html) == 91)
        #expect(try BlurbParser.lastPageNumber(html: "<p>one page</p>") == nil)
    }

    @Test func parsesSeriesBookmarkCard() throws {
        let url = try #require(
            Bundle.module.url(forResource: "series_card", withExtension: "html", subdirectory: "Fixtures"))
        let sc = try BlurbParser.parseListing(html: String(contentsOf: url, encoding: .utf8))
        let s = try #require(sc.first)
        #expect(sc.count == 1)
        #expect(s.kind == .series)
        #expect(s.workID == 2157402)
        #expect(s.title == "those who form his fire-side")
        #expect(s.worksCount == 6)                        // "Works:" stat, not chapters
        #expect(s.wordCount == 39146)                     // series total
        #expect(s.bookmarkedAt == "13 Jun 2026")
    }

    @Test func expandsSeriesPageIntoMemberWorks() throws {
        let url = try #require(
            Bundle.module.url(forResource: "series_page", withExtension: "html", subdirectory: "Fixtures"))
        let members = try BlurbParser.parseListing(html: String(contentsOf: url, encoding: .utf8))
        #expect(members.count == 6)
        #expect(members.allSatisfy { $0.kind == .work })
        #expect(members.map(\.workID) == [26762044, 29369769, 35035795, 68591376, 70449741, 81922441])
    }

    @Test func everyCardHasIDTitleAuthor() throws {
        let blurbs = try BlurbParser.parseListing(html: fixtureHTML())
        for b in blurbs {
            #expect(b.workID > 0)
            #expect(!b.title.isEmpty)
            #expect(!b.author.isEmpty)
        }
    }

    @Test func intParsingStripsCommas() {
        #expect(BlurbParser.parseInt("1,234,567") == 1234567)
        #expect(BlurbParser.parseInt("18") == 18)
        #expect(BlurbParser.parseInt("—") == nil)
    }

    @Test func workIDFromHrefVariants() {
        #expect(BlurbParser.workID(fromWorkHref: "/works/85487886") == 85487886)
        #expect(BlurbParser.workID(fromWorkHref: "/works/123/chapters/456") == 123)
        #expect(BlurbParser.workID(fromWorkHref: "/users/foo") == nil)
    }

    @Test func sanitizeFilename() {
        #expect(ArchivePaths.sanitize("A/B: C?") == "A B C")
        #expect(ArchivePaths.sanitize("   ") == "untitled")
    }
}

/// Verifies EPUB download-link extraction against a faithful copy of AO3's download menu.
@Suite struct WorkDownloaderTests {
    @Test func extractsEPUBHref() throws {
        let html = """
        <ul class="actions">
          <li class="download">
            <a>Download</a>
            <ul class="menu">
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.azw3?updated_at=1781388945">AZW3</a></li>
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.epub?updated_at=1781388945">EPUB</a></li>
              <li><a href="/downloads/85487886/Sarcasm_and_Sanctuary.pdf?updated_at=1781388945">PDF</a></li>
            </ul>
          </li>
        </ul>
        """
        let href = try WorkDownloader.epubHref(fromWorkHTML: html)
        #expect(href == "/downloads/85487886/Sarcasm_and_Sanctuary.epub?updated_at=1781388945")
    }

    @Test func noDownloadMenuReturnsNil() throws {
        #expect(try WorkDownloader.epubHref(fromWorkHTML: "<html><body>locked</body></html>") == nil)
    }

    @Test func epubMagicDetection() {
        #expect(WorkDownloader.looksLikeEPUB(Data([0x50, 0x4B, 0x03, 0x04, 0x00])))
        #expect(!WorkDownloader.looksLikeEPUB(Data("<html".utf8)))
        #expect(!WorkDownloader.looksLikeEPUB(Data()))
    }

    @Test func ignoresAbsoluteOffSiteDownloadLink() throws {
        // No legit `li.download` menu; the anchored `^=/downloads/` fallback must skip an
        // attacker-supplied absolute href so we never form an off-AO3 request.
        let html = #"<p>locked</p><a href="https://evil.example/downloads/x.epub">grab</a>"#
        #expect(try WorkDownloader.epubHref(fromWorkHTML: html) == nil)
    }

    @Test func ignoresAbsoluteHrefInsideDownloadWrapper() throws {
        // L3: an attacker-injected `li.download` wrapping an absolute href must be skipped by
        // the *primary* selector too (now anchored `^=/downloads/`), not rely on the host
        // allowlist one layer down.
        let html = #"<li class="download"><a href="https://evil.example/downloads/x.epub">EPUB</a></li>"#
        #expect(try WorkDownloader.epubHref(fromWorkHTML: html) == nil)
    }
}

/// Security regression tests: the cookie/SSRF host gate, username path encoding, the
/// table-name allowlist, and canonical (non-raw-href) source paths.
@Suite struct SecurityTests {
    @Test func ao3HostAllowlist() {
        #expect(AO3Client.isAO3Host("archiveofourown.org"))
        #expect(AO3Client.isAO3Host("download.archiveofourown.org"))
        #expect(!AO3Client.isAO3Host("evil-archiveofourown.org"))   // lookalike suffix
        #expect(!AO3Client.isAO3Host("evil.example"))
        #expect(!AO3Client.isAO3Host(nil))
    }

    @Test func usernamePathEncoding() {
        #expect(AO3Config.encodePathComponent("Some_User-1") == "Some_User-1")
        #expect(AO3Config.encodePathComponent("a/b") == "a%2Fb")
        #expect(!AO3Config.encodePathComponent("u?page=9").contains("?"))
    }

    @Test func cookieSanitization() {
        #expect(AO3Config.sanitizeCookie("abc123") == "abc123")
        #expect(AO3Config.sanitizeCookie("  abc123\n") == "abc123")
        #expect(AO3Config.sanitizeCookie("_otwarchive_session=abc123") == "abc123")
        #expect(AO3Config.sanitizeCookie("abc123; other=x") == "abc123")
        #expect(AO3Config.sanitizeCookie(" _otwarchive_session=abc123; other=x ") == "abc123")
        // The session pair isn't first in a pasted Cookie header / document.cookie — find it
        // anyway (anchoring to the start would keep the wrong pair → an anonymous request).
        #expect(AO3Config.sanitizeCookie("view_adult=true; _otwarchive_session=abc123; x=y") == "abc123")
        #expect(AO3Config.sanitizeCookie("   ") == nil)
        #expect(AO3Config.sanitizeCookie(nil) == nil)
    }

    @Test func cloudflareDetection() throws {
        // Edge 5xx (transient, retried then surfaced) vs ordinary codes.
        #expect(AO3Client.isCloudflareEdge(525))
        #expect(AO3Client.isCloudflareEdge(520))
        #expect(AO3Client.isCloudflareEdge(530))
        #expect(!AO3Client.isCloudflareEdge(503))   // origin 5xx, not a CF edge code
        #expect(!AO3Client.isCloudflareEdge(200))

        let url = URL(string: "https://archiveofourown.org/")!
        func resp(_ code: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
        }
        // The explicit Cloudflare header is enough, whatever the status.
        #expect(AO3Client.isCloudflareChallenge(resp(403, ["cf-mitigated": "challenge"]), Data()))
        // Cloudflare-served + interstitial body markers.
        let challengeBody = Data("<html><head><title>Just a moment...</title></head>".utf8)
        #expect(AO3Client.isCloudflareChallenge(resp(503, ["Server": "cloudflare"]), challengeBody))
        // A genuine AO3 page served via Cloudflare without challenge markers is NOT a challenge.
        let realPage = Data("<html><body>Log Out</body></html>".utf8)
        #expect(!AO3Client.isCloudflareChallenge(resp(200, ["server": "cloudflare", "cf-ray": "abc"]), realPage))
        // Not served by Cloudflare → never a challenge, even with a suggestive body.
        #expect(!AO3Client.isCloudflareChallenge(resp(503, [:]), challengeBody))

        // The surfaced messages name the cause, not a cookie problem.
        #expect("\(AO3Error.cloudflare(status: 503, shieldsUp: true))".contains("shields up"))
        #expect("\(AO3Error.cloudflare(status: 525, shieldsUp: false))".contains("525"))
        #expect(!"\(AO3Error.cloudflare(status: 0, shieldsUp: false))".contains("0"))  // no "error 0"

        // Body-only detection (used where only the HTML body is available): a challenge → true,
        // a Cloudflare error page → false, real content / a binary EPUB → nil.
        #expect(AO3Client.cloudflareWallKind(inBody: Data("<title>Just a moment...</title>".utf8)) == true)
        #expect(AO3Client.cloudflareWallKind(inBody: Data("<h1>525: SSL handshake failed</h1>".utf8)) == false)
        #expect(AO3Client.cloudflareWallKind(inBody: Data("<html>The Devil's Daughter</html>".utf8)) == nil)
        #expect(AO3Client.cloudflareWallKind(inBody: Data([0x50, 0x4B, 0x03, 0x04])) == nil)  // EPUB zip
    }

    @Test func countRejectsUnknownTable() throws {
        let store = try Store(inMemory: true)
        #expect(throws: (any Error).self) { try store.count("work; DROP TABLE work") }
        #expect(try store.count("work") == 0)
    }

    @Test func sourcePathIsCanonical() throws {
        let html = #"<li class="work blurb group" id="work_42"><h4 class="heading"><a href="https://evil.example/works/42/chapters/9">T</a></h4></li>"#
        let blurb = try BlurbParser.parseListing(html: html).first
        #expect(blurb?.sourcePath == "/works/42")
    }
}

/// Store tests run entirely offline against an in-memory DB, ingesting the same captured
/// fixtures. They mirror Sources/selftest so CLT and CI assert the same behavior.
@Suite struct StoreTests {

    func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Mirrors SyncEngine's per-card ingest dispatch.
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

    @Test func ingestIsIdempotentAndExcludesExternalFromQueue() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)

        #expect(try store.count("work") == 20)          // 19 work + 1 external
        #expect(try store.count("bookmark") == 20)
        #expect(try store.worksNeedingDownload().count == 19)   // external excluded

        try ingest(store, cards)                         // second pass
        #expect(try store.count("work") == 20)
        #expect(try store.count("bookmark") == 20)
        #expect(try store.worksNeedingDownload().count == 19)
    }

    @Test func downloadAndStaleDetection() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)

        let first = try #require(try store.worksNeedingDownload().first)
        try store.markDownloaded(workID: first.id, epubPath: "works/\(first.id).epub", updatedAt: first.updatedAt)
        #expect(try store.worksNeedingDownload().count == 18)
        #expect(try store.worksNeedingRedownload().isEmpty)   // nothing we hold is stale yet

        var stale = try #require(cards.first { $0.workID == first.id })
        stale.updatedAt = (first.updatedAt ?? 0) + 1     // AO3 shows a newer revision
        try store.upsertWork(stale)
        #expect(try store.worksNeedingDownload().count == 19)
        // The incremental sync re-downloads exactly the saved-but-now-stale work — not the
        // 18 never-downloaded works in the backlog.
        #expect(try store.worksNeedingRedownload().map(\.id) == [first.id])
    }

    @Test func knownBookmarkIDsDistinguishesNew() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let bid = try #require(cards.compactMap { $0.bookmarkID }.first)
        #expect(try store.knownBookmarkIDs(among: [bid]).contains(bid))
        #expect(try !store.knownBookmarkIDs(among: [bid + 999_999]).contains(bid + 999_999))
        #expect(try store.knownBookmarkIDs(among: []).isEmpty)
    }

    @Test func incrementalStopConditions() {
        // New-bookmarks pass: stop once the page adds nothing we don't already have.
        #expect(SyncEngine.noNewBookmarks(pageIDs: [1, 2, 3], known: [1, 2, 3, 4]))
        #expect(!SyncEngine.noNewBookmarks(pageIDs: [1, 2, 9], known: [1, 2]))
        #expect(SyncEngine.noNewBookmarks(pageIDs: [], known: []))

        // Updated-works pass frontier (cards arrive in date-updated order).
        let recent = WorkBlurb(kind: .work, sourcePath: "/works/1", workID: 1, title: "t", author: "a", updatedAt: 200)
        let old = WorkBlurb(kind: .work, sourcePath: "/works/2", workID: 2, title: "t", author: "a", updatedAt: 50)
        #expect(!SyncEngine.reachedUpdateFrontier(pageCards: [old], since: nil))        // no watermark → page cap only
        #expect(!SyncEngine.reachedUpdateFrontier(pageCards: [recent, old], since: 100)) // a fresh card → keep going
        #expect(SyncEngine.reachedUpdateFrontier(pageCards: [old], since: 100))          // all stale → stop
        // L4: an unparseable date (nil) counts as "unknown", not "old" — never ends the pass early.
        let undated = WorkBlurb(kind: .work, sourcePath: "/works/3", workID: 3, title: "t", author: "a", updatedAt: nil)
        #expect(!SyncEngine.reachedUpdateFrontier(pageCards: [old, undated], since: 100))

        // Date-updated sort injected into the listing path (brackets percent-encoded).
        #expect(SyncEngine.sortedByDateUpdated("/users/x/bookmarks?page=1")
                == "/users/x/bookmarks?page=1&bookmark_search%5Bsort_column%5D=bookmarkable_date")
        #expect(SyncEngine.sortedByDateUpdated("/users/x/bookmarks")
                == "/users/x/bookmarks?bookmark_search%5Bsort_column%5D=bookmarkable_date")
    }

    @Test func failedDownloadIsRetryableAcrossRuns() throws {
        // The run-anonymously-then-add-a-cookie workflow: a .requiresLogin failure must not
        // be terminal — marking failed records the error but keeps the work in the queue.
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let before = try store.worksNeedingDownload().count
        let work = try #require(try store.worksNeedingDownload().first)
        try store.markFailed(workID: work.id, error: "requires login")
        #expect(try store.worksNeedingDownload().count == before)
    }

    @Test func fullTextSearchFindsTitle() throws {
        let store = try Store(inMemory: true)
        try ingest(store, try BlurbParser.parseListing(html: fixture("bookmarks_page")))
        #expect(try store.searchWorkIDs("circus").contains(1413325))
    }

    @Test func fullTextSearchToleratesFTS5Operators() throws {
        // L1: raw text with FTS5 query operators must not raise SQLITE_ERROR — terms are
        // quoted as literal phrases, so these run cleanly and a bare word still matches.
        let store = try Store(inMemory: true)
        try ingest(store, try BlurbParser.parseListing(html: fixture("bookmarks_page")))
        for q in ["circus*", "\"unbalanced", "foo:bar", "a NEAR b", "-x", "()", "  "] {
            #expect(throws: Never.self) { _ = try store.searchWorkIDs(q) }
        }
        #expect(try store.searchWorkIDs("\"circus\"").contains(1413325))
    }

    @Test func reBookmarkUnderNewIdReplacesStaleRow() throws {
        // A work re-bookmarked on AO3 (old bookmark deleted, fresh one made) arrives with a
        // brand-new bookmark id but the same (item_kind,item_id). That must replace the stale
        // row, not trip its UNIQUE constraint and abort the whole sync (SQLite error 19).
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let before = try store.count("bookmark")

        var rebm = try #require(cards.first { $0.kind == .work && $0.bookmarkID != nil })
        rebm.bookmarkID = rebm.bookmarkID! + 9_000_000      // a brand-new bookmark id, same work
        try store.upsertBookmark(rebm, itemKind: .work, itemID: rebm.workID)

        #expect(try store.count("bookmark") == before)      // replaced, not duplicated
    }

    @Test func seriesExpansionLinksMembers() throws {
        let card = try #require(try BlurbParser.parseListing(html: fixture("series_card")).first)
        let members = try BlurbParser.parseListing(html: fixture("series_page"))
        let store = try Store(inMemory: true)
        try store.upsertSeries(card)
        try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        for (i, m) in members.enumerated() {
            try store.upsertWork(m)
            try store.linkSeriesWork(seriesID: card.workID, workID: m.workID, part: i + 1)
        }
        #expect(try store.count("series") == 1)
        #expect(try store.count("work") == 6)
        #expect(try store.count("series_work") == 6)
        #expect(try store.worksNeedingDownload().count == 6)
    }
}

/// Gallery read/filter/sort model — the layer beneath the SwiftUI views. Runs offline
/// against the same fixtures so the gallery's data is verified without rendering anything.
@Suite struct GalleryModelTests {

    func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

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

    func loadedItems() throws -> ([WorkBlurb], [WorkListItem]) {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        return (cards, try store.fetchAllListItems())
    }

    @Test func joinHasNoFanOut() throws {
        let (cards, items) = try loadedItems()
        #expect(items.count == 20)                                   // one item per bookmark
        #expect(items.filter { $0.itemID == 1413325 }.count == 1)    // not duplicated per tag
        let blurb = try #require(cards.first { $0.workID == 1413325 })
        let item = try #require(items.first { $0.itemID == 1413325 })
        #expect(item.fandoms == blurb.fandoms)                       // N tags, one row
        #expect(item.kind == .work)
    }

    @Test func kindMappingIsCorrect() throws {
        let (_, items) = try loadedItems()
        #expect(items.filter { $0.kind == .work }.count == 19)
        #expect(items.filter { $0.kind == .external }.count == 1)
    }

    @Test func filtersComposeWithAnd() throws {
        let (_, items) = try loadedItems()
        var f = GalleryFilter()
        f.setInclude(.bookmarkType, ["external"])
        #expect(f.apply(to: items).count == 1)

        f = GalleryFilter(); f.searchText = "circus"
        #expect(f.apply(to: items).map(\.itemID) == [1413325])

        f = GalleryFilter(); f.setInclude(.bookmarkType, ["work"]); f.completion = .complete
        let composed = f.apply(to: items)
        #expect(composed.allSatisfy { $0.kind == .work && $0.isComplete == true })
        #expect(composed.count <= items.filter { $0.kind == .work }.count)
    }

    @Test func sortAndFacets() throws {
        let (_, items) = try loadedItems()
        let byBk = GallerySort.dateBookmarked.sorted(items)
        #expect(byBk.first!.bookmarkID! >= byBk.last!.bookmarkID!)

        let types = Facets.values(for: .bookmarkType, in: items)
        #expect(types.reduce(0) { $0 + $1.count } == 20)
        #expect(types.first?.name == "work")
    }

    @Test func seriesBookmarkIsOneItem() throws {
        let card = try #require(try BlurbParser.parseListing(html: fixture("series_card")).first)
        let members = try BlurbParser.parseListing(html: fixture("series_page"))
        let store = try Store(inMemory: true)
        try store.upsertSeries(card)
        try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        for (i, m) in members.enumerated() {
            try store.upsertWork(m)
            try store.linkSeriesWork(seriesID: card.workID, workID: m.workID, part: i + 1)
        }
        let items = try store.fetchAllListItems()
        #expect(items.count == 1)                       // members aren't separately listed
        #expect(items.first?.kind == .series)
        #expect(items.first?.worksCount == 6)
    }

    @Test func viewModelDerivesVisibleSet() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let vm = GalleryViewModel()
        vm.load(from: store)
        #expect(vm.totalCount == 20)
        vm.toggle(.bookmarkType, "external")
        #expect(vm.visibleCount == 1)
        vm.clearFilters()
        #expect(vm.visibleCount == 20)
    }

    @Test func keyboardNeighborWalksVisibleList() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let vm = GalleryViewModel(); vm.load(from: store)
        let items = vm.visibleItems
        try #require(items.count >= 3)

        // No selection: .next lands on the first item, .previous on the last.
        #expect(vm.neighbor(of: nil, .next) == items.first?.id)
        #expect(vm.neighbor(of: nil, .previous) == items.last?.id)
        // Steps forward/back by one.
        #expect(vm.neighbor(of: items[1].id, .next) == items[2].id)
        #expect(vm.neighbor(of: items[1].id, .previous) == items[0].id)
        // Clamps at the ends (no wrap-around).
        #expect(vm.neighbor(of: items.first?.id, .previous) == items.first?.id)
        #expect(vm.neighbor(of: items.last?.id, .next) == items.last?.id)
    }

    /// Faceted-search invariant: selecting one value in a dimension must keep that
    /// dimension's other values visible (so a multi-select — AND within a multi-value dim,
    /// OR within a single-valued one — is reachable from the sidebar), while still
    /// narrowing the visible item list. Guards against facet self-collapse.
    @Test func facetsDoNotSelfCollapse() throws {
        let (_, items) = try loadedItems()
        let store = try Store(inMemory: true)
        try ingest(store, try BlurbParser.parseListing(html: fixture("bookmarks_page")))
        let vm = GalleryViewModel(); vm.load(from: store)

        let allRatings = Set(Facets.values(for: .rating, in: items).map(\.name))
        try #require(allRatings.count > 1)
        let pick = try #require(allRatings.first)
        vm.toggle(.rating, pick)

        let shownInFacet = Set(vm.facets(for: .rating).map(\.name))
        #expect(shownInFacet.isSuperset(of: allRatings))            // other ratings stay listed
        #expect(vm.visibleItems.allSatisfy { $0.rating == pick })    // but the list narrows

        // Same guard on a NEW high-cardinality dimension (the generic-refactor regression risk).
        vm.clearFilters()
        let allRels = Set(Facets.values(for: .relationship, in: items).map(\.name))
        try #require(allRels.count > 1)
        let rel = try #require(allRels.first)
        vm.cycle(.relationship, rel)
        #expect(Set(vm.facets(for: .relationship).map(\.name)).isSuperset(of: allRels))
        #expect(vm.visibleItems.allSatisfy { $0.relationships.contains(rel) })
    }

    /// AO3 corner-symbol classification (for the colour coding): rating level tracks the
    /// rating text, and external bookmarks report the "external" warning level.
    @Test func symbolClassification() throws {
        let (_, items) = try loadedItems()
        for i in items {
            let r = (i.rating ?? "").lowercased()
            switch i.ratingLevel {
            case .general:  #expect(r.contains("general"))
            case .teen:     #expect(r.contains("teen"))
            case .mature:   #expect(r.contains("mature"))
            case .explicit: #expect(r.contains("explicit"))
            case .notRated: #expect(!["general", "teen", "mature", "explicit"].contains { r.contains($0) })
            }
        }
        #expect(items.first { $0.kind == .external }?.warningLevel == .external)
    }

    @Test func categorySplitsAndExcludesNoCategory() throws {
        let (_, items) = try loadedItems()
        #expect(items.contains { $0.categories.count >= 2 })                     // "F/M, Gen" → 2
        #expect(items.allSatisfy { !$0.categories.contains("No category") })     // never a badge
    }

    @Test func includeExcludeAndTriStateCycle() throws {
        let cards = try BlurbParser.parseListing(html: fixture("bookmarks_page"))
        let store = try Store(inMemory: true)
        try ingest(store, cards)
        let items = try store.fetchAllListItems()
        let fandom = try #require(Facets.values(for: .fandom, in: items).first?.name)

        // Exclude drops matching items; include + exclude compose.
        var ex = GalleryFilter(); ex.setExclude(.fandom, [fandom])
        #expect(ex.apply(to: items).allSatisfy { !$0.fandoms.contains(fandom) })
        #expect(ex.apply(to: items).count < items.count)

        // Tri-state: neutral → include → exclude → neutral.
        let vm = GalleryViewModel(); vm.load(from: store)
        #expect(vm.state(.fandom, fandom) == .neutral)
        vm.cycle(.fandom, fandom); #expect(vm.state(.fandom, fandom) == .include)
        #expect(vm.visibleCount < vm.totalCount)
        vm.cycle(.fandom, fandom); #expect(vm.state(.fandom, fandom) == .exclude)
        #expect(vm.visibleItems.allSatisfy { !$0.fandoms.contains(fandom) })
        vm.cycle(.fandom, fandom); #expect(vm.state(.fandom, fandom) == .neutral)
        #expect(vm.visibleCount == vm.totalCount)
        #expect(vm.filter == GalleryFilter())   // neutral leaves no empty set behind (invariant)
    }

    /// Multi-select within a dimension: AND for multi-value dims (fandom/tags/category — a
    /// work must carry every selected value), OR for single-valued dims (rating/language/
    /// type — a work has only one, so AND would match nothing).
    @Test func multiSelectAndWithinDimension() throws {
        let (_, items) = try loadedItems()

        // Multi-value: pick a crossover's two fandoms → only works with BOTH survive.
        let crossover = try #require(items.first { $0.fandoms.count >= 2 })
        let two = Set(crossover.fandoms.prefix(2))
        var af = GalleryFilter(); af.setInclude(.fandom, two)
        let andRes = af.apply(to: items)
        #expect(andRes.allSatisfy { Set($0.fandoms).isSuperset(of: two) })   // AND
        #expect(andRes.contains { $0.itemID == crossover.itemID })           // source survives
        var one = GalleryFilter(); one.setInclude(.fandom, [two.first!])
        #expect(andRes.count <= one.apply(to: items).count)                  // no wider than one

        // Single-valued: two ratings stay OR (a work matches if its rating is either).
        let twoRatings = Set(Facets.values(for: .rating, in: items).prefix(2).map(\.name))
        try #require(twoRatings.count == 2)
        var rf = GalleryFilter(); rf.setInclude(.rating, twoRatings)
        let orRes = rf.apply(to: items)
        #expect(orRes.allSatisfy { twoRatings.contains($0.rating ?? "") })   // OR
        #expect(!orRes.isEmpty)
    }

    @Test func derivedSetIsMemoized() throws {
        let vm = GalleryViewModel()
        vm.allItems = (0..<500).map { i in
            WorkListItem(itemID: i, kind: .work, sourcePath: "/works/\(i)", title: "W\(i)",
                         author: "a", fandoms: ["F\(i % 5)"],
                         rating: ["General Audiences", "Explicit"][i % 2])
        }
        _ = vm.visibleItems
        let r0 = vm.recomputeCount
        for _ in 0..<100 { _ = vm.visibleItems; _ = vm.facets(for: .rating); _ = vm.facets(for: .fandom) }
        #expect(vm.recomputeCount == r0)             // repeated access is memoized
        vm.cycle(.rating, "Explicit"); _ = vm.visibleItems
        #expect(vm.recomputeCount == r0 + 1)          // exactly one recompute on change
        #expect(vm.visibleItems.allSatisfy { $0.rating == "Explicit" })
        #expect(vm.visibleCount == 250)               // half are Explicit
    }

    @Test func categoryFilterIncludeExclude() throws {
        let (_, items) = try loadedItems()
        let cat = try #require(Facets.values(for: .category, in: items).first?.name)
        var f = GalleryFilter(); f.setInclude(.category, [cat])
        #expect(f.apply(to: items).allSatisfy { $0.categories.contains(cat) })
        f = GalleryFilter(); f.setExclude(.category, [cat])
        #expect(f.apply(to: items).allSatisfy { !$0.categories.contains(cat) })
    }

    @Test func downloadFilterSingleSelect() throws {
        let (_, items) = try loadedItems()
        var f = GalleryFilter(); f.download = .offsite
        #expect(f.apply(to: items).map(\.kind) == [.external])
        f.download = .notDownloaded
        #expect(f.apply(to: items).count == 19)
        f.download = .saved
        #expect(f.apply(to: items).isEmpty)
    }

    @Test func numericAndDateRangeFilters() throws {
        let (_, items) = try loadedItems()
        let wcs = items.compactMap(\.wordCount).sorted()
        let median = try #require(wcs.dropFirst(wcs.count / 2).first)

        var f = GalleryFilter(); f.setBound(.wordCount, NumericBound(min: Double(median)))
        let kept = f.apply(to: items)
        #expect(kept.allSatisfy { ($0.wordCount ?? -1) >= median })
        #expect(kept.allSatisfy { $0.wordCount != nil })   // nil value drops out of an active range
        #expect(kept.count < items.count)

        // Both ends compose into an inclusive window.
        f = GalleryFilter(); f.setBound(.kudos, NumericBound(min: 1, max: 100))
        #expect(f.apply(to: items).allSatisfy { ($0.kudos ?? -1) >= 1 && ($0.kudos ?? .max) <= 100 })

        // An inactive bound is never stored (mirrors the facet no-empty-key invariant).
        var g = GalleryFilter(); g.setBound(.hits, NumericBound())
        #expect(g == GalleryFilter())
        #expect(!g.isActive)

        // Date-updated range filters by the parsed unix timestamp.
        let ups = items.compactMap(\.updatedAt).sorted()
        let mid = try #require(ups.dropFirst(ups.count / 2).first)
        var d = GalleryFilter(); d.setBound(.dateUpdated, NumericBound(min: Double(mid)))
        #expect(d.apply(to: items).allSatisfy { ($0.updatedAt ?? -1) >= mid })
    }

    @Test func bookmarkDateParses() throws {
        // AO3's "04 Apr 2014" → a real Date (UTC, POSIX); garbage → nil (fail-soft).
        #expect(WorkListItem.parseBookmarkDate("04 Apr 2014") != nil)
        #expect(WorkListItem.parseBookmarkDate("not a date") == nil)
        #expect(WorkListItem.parseBookmarkDate(nil) == nil)
        let (_, items) = try loadedItems()
        #expect(items.contains { $0.bookmarkedDate != nil })   // the fixture's dates parsed
    }

    @Test func derivedBookmarkBooleanFilters() throws {
        let (_, items) = try loadedItems()
        var f = GalleryFilter(); f.crossover = .yes
        #expect(f.apply(to: items).allSatisfy { $0.fandoms.count > 1 })
        f = GalleryFilter(); f.crossover = .no
        #expect(f.apply(to: items).allSatisfy { $0.fandoms.count <= 1 })
        f = GalleryFilter(); f.hasNotes = .yes
        #expect(f.apply(to: items).allSatisfy { !($0.bookmarkerNotes ?? "").isEmpty })
        f = GalleryFilter(); f.hasNotes = .no
        #expect(f.apply(to: items).allSatisfy { ($0.bookmarkerNotes ?? "").isEmpty })
        #expect(!GalleryFilter().isActive)   // all-.any is inert
    }

    @Test func savedPresetsRoundTrip() throws {
        let store = try Store(inMemory: true)
        #expect(try store.loadPresets().isEmpty)

        var pf = GalleryFilter()
        pf.setInclude(.fandom, ["Good Omens (TV)"]); pf.setExclude(.rating, ["Explicit"])
        pf.setBound(.wordCount, NumericBound(min: 1000, max: 50000))
        pf.crossover = .no; pf.hasNotes = .yes; pf.searchText = "circus"
        try store.savePreset(FilterPreset(name: "My preset", filter: pf, sort: .wordCount))

        let loaded = try store.loadPresets()
        #expect(loaded.count == 1)
        #expect(loaded.first?.filter == pf)        // the whole filter round-trips through JSON
        #expect(loaded.first?.sort == .wordCount)

        // Same name overwrites; delete removes.
        try store.savePreset(FilterPreset(name: "My preset", filter: GalleryFilter(), sort: .title))
        #expect(try store.loadPresets().count == 1)
        try store.deletePreset(name: "My preset")
        #expect(try store.loadPresets().isEmpty)
    }

    @Test func viewModelPresetApply() throws {
        let store = try Store(inMemory: true)
        try ingest(store, try BlurbParser.parseListing(html: fixture("bookmarks_page")))
        let vm = GalleryViewModel(); vm.load(from: store)

        vm.cycle(.bookmarkType, "external")
        vm.sort = .title
        vm.savePreset(named: "Externals", to: store)
        #expect(vm.presets.map(\.name) == ["Externals"])

        vm.clearFilters(); vm.sort = .dateBookmarked
        #expect(vm.visibleCount == vm.totalCount)
        vm.applyPreset(try #require(vm.presets.first))
        #expect(vm.sort == .title)
        #expect(vm.visibleItems.allSatisfy { $0.kind == .external })
    }

    @Test func metaStoreAndPageNumber() throws {
        let store = try Store(inMemory: true)
        #expect(try store.getMeta("k") == nil)
        try store.setMeta("k", "a"); #expect(try store.getMeta("k") == "a")
        try store.setMeta("k", "b"); #expect(try store.getMeta("k") == "b")   // upsert
        try store.clearMeta("k"); #expect(try store.getMeta("k") == nil)
        #expect(SyncEngine.pageNumber(inPath: "/u/x/bookmarks?view_adult=true&page=16") == 16)
        #expect(SyncEngine.pageNumber(inPath: "/u/x/bookmarks") == nil)
    }

    @Test func seriesMembersFetchedInOrder() throws {
        let card = try #require(try BlurbParser.parseListing(html: fixture("series_card")).first)
        let members = try BlurbParser.parseListing(html: fixture("series_page"))
        let store = try Store(inMemory: true)
        try store.upsertSeries(card)
        for (i, m) in members.enumerated() {
            try store.upsertWork(m)
            try store.linkSeriesWork(seriesID: card.workID, workID: m.workID, part: i + 1)
        }
        let fetched = try store.fetchSeriesMembers(seriesID: card.workID)
        #expect(fetched.map(\.itemID) == [26762044, 29369769, 35035795, 68591376, 70449741, 81922441])
    }
}

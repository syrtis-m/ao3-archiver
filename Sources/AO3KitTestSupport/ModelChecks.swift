import Foundation
import AO3Kit

/// Synchronous model-level checks shared by both runners (see `EngineScenarios`).
public enum ModelChecks {
    /// Each prune guard in isolation (pure — `SyncEngine.pruneDecision`).
    public static func pruneGuards() -> [EngineScenarios.Check] {
        var ok = SyncEngine.IndexCoverage()
        ok.reachedEnd = true; ok.listingTotal = 3; ok.seenBookmarkIDs = [1, 2, 3]; ok.seenPrivate = 1
        let census = Store.BookmarkCensus(active: 100, activePrivate: 5, notSeenSince: 2)
        func decide(_ c: SyncEngine.IndexCoverage, cookie: Bool = true,
                    _ cen: Store.BookmarkCensus = census) -> Bool {
            SyncEngine.pruneDecision(coverage: c, hasCookie: cookie, census: cen) == .prune
        }
        var resumed = ok; resumed.startedAtFirstPage = false
        var truncated = ok; truncated.reachedEnd = false
        var noTotal = ok; noTotal.listingTotal = nil
        var short = ok; short.listingTotal = 4
        var noPrivate = ok; noPrivate.seenPrivate = 0
        return [
            ("prunes when every guard passes", decide(ok)),
            ("needs a cookie", !decide(ok, cookie: false)),
            ("not after a resumed pass", !decide(resumed)),
            ("not unless the listing was read to the end", !decide(truncated)),
            ("not without AO3's total", !decide(noTotal)),
            ("not when fewer bookmarks were seen than AO3 reports", !decide(short)),
            ("not when private bookmarks vanished", !decide(noPrivate)),
            ("private guard only applies if we hold private ones",
                decide(noPrivate, .init(active: 100, activePrivate: 0, notSeenSince: 2))),
            ("caps the damage", !decide(ok, .init(active: 1000, activePrivate: 5, notSeenSince: 51))
                && decide(ok, .init(active: 1000, activePrivate: 5, notSeenSince: 50))
                && decide(ok, .init(active: 10, activePrivate: 5, notSeenSince: 10))),
        ]
    }

    public static func saveVisiblePlan() -> [EngineScenarios.Check] {
        func w(_ id: Int, saved: Bool = false, kind: BookmarkKind = .work) -> WorkListItem {
            WorkListItem(itemID: id, kind: kind, sourcePath: "/x/\(id)", title: "T", author: "A",
                         epubPath: saved ? "works/\(id).epub" : nil)
        }
        let visible = [w(1), w(2, saved: true), w(3, kind: .external), w(4, kind: .series), w(5), w(6)]
        let plan = SaveVisiblePlan(visible: visible, cap: 2)
        let none = SaveVisiblePlan(visible: [w(2, saved: true)])
        return [
            ("only unsaved AO3 works, in view order, capped", plan.workIDs == [1, 5] && plan.totalUnsaved == 3),
            ("reports the cap", plan.isCapped && plan.message(interval: 5).contains("1 more")),
            ("estimate: 2 works × 2 requests × 5s → 1 minute", plan.estimatedMinutes(interval: 5) == 1),
            ("nothing to save → empty", none.workIDs.isEmpty && !none.isCapped),
        ]
    }

    /// The orphan sweep removes only works nothing refers to.
    public static func orphanSweep() throws -> [EngineScenarios.Check] {
        let store = try Store(inMemory: true)
        func work(_ id: Int, bookmark: Int? = nil) throws {
            let b = WorkBlurb(sourcePath: "/works/\(id)", workID: id, title: "W\(id)", author: "a", bookmarkID: bookmark)
            if bookmark != nil { try store.upsertWorkAndBookmark(b) } else { try store.upsertWork(b) }
        }
        try work(1)                                   // orphan (e.g. from a crawl of another listing)
        try work(2, bookmark: 20)                     // bookmarked
        try work(3); try store.markDownloaded(workID: 3, epubPath: "works/3 - W3.epub", updatedAt: nil)
        try work(4); try store.saveReadingPosition(workID: 4, spineIndex: 0)
        try store.upsertSeries(WorkBlurb(kind: .series, workID: 9, title: "S", author: "a"))
        try store.upsertSeriesMember(WorkBlurb(sourcePath: "/works/5", workID: 5, title: "W5", author: "a"),
                                     seriesID: 9, part: 1)
        let removed = try store.deleteOrphanWorks()
        let left = try [1, 2, 3, 4, 5].filter { try store.pendingWork(workID: $0) != nil }
        return [
            ("sweeps exactly the orphan", removed == 1 && left == [2, 3, 4, 5]),
            ("idempotent", try store.deleteOrphanWorks() == 0),
        ]
    }

    /// The bookmark total comes from AO3's heading (the real captured page reports 1,811).
    public static func listingTotal(bookmarksFixtureHTML: String) -> [EngineScenarios.Check] {
        let decoy = "<html><body><h2 class=\"heading\">1 - 1 of 7 Bookmarks by x</h2>"
            + "<blockquote class=\"summary\">one of 999 Bookmarks</blockquote></body></html>"
        return [
            ("reads the real page's total", BlurbParser.listingTotal(html: bookmarksFixtureHTML) == 1811),
            ("heading only, never body text", BlurbParser.listingTotal(html: decoy) == 7),
            ("nil without a heading", BlurbParser.listingTotal(html: "<p>of 3 Bookmarks</p>") == nil),
        ]
    }

    /// Only runs older than the cutoff are closed; a recent one may be a live CLI sync.
    public static func staleSyncRuns() throws -> [EngineScenarios.Check] {
        let store = try Store(inMemory: true)
        let iso = ISO8601DateFormatter()
        let old = try store.beginSyncRun(now: iso.string(from: Date().addingTimeInterval(-24 * 3600)))
        let recent = try store.beginSyncRun(now: iso.string(from: Date().addingTimeInterval(-600)))
        let closed = try store.closeStaleSyncRuns(olderThanHours: 6)
        let again = try store.closeStaleSyncRuns(olderThanHours: 6)
        return [
            ("closes only the stale run", closed == 1 && again == 0),
            ("distinct run ids", old != recent),
        ]
    }

    public static func presentation() -> [EngineScenarios.Check] {
        let saved = WorkListItem(itemID: 1, kind: .work, sourcePath: "/works/1", title: "T", author: "A",
                                 wordCount: 12_328, chaptersHave: 4, downloadState: "failed",
                                 epubPath: "works/1 - T.epub", deletedOnAO3: true)
        let unsaved = WorkListItem(itemID: 2, kind: .work, sourcePath: "/works/2", title: "T", author: "A",
                                   chaptersHave: 3, chaptersTotal: 3, deletedOnAO3: true)
        let series = WorkListItem(itemID: 3, kind: .series, sourcePath: "/series/3", title: "S", author: "A",
                                  worksCount: 7, downloadState: "series")
        let blank: String? = "  \n", none: String? = nil
        return [
            ("isSaved keys on the file, not the state cache", saved.isSaved && !unsaved.isSaved && !series.isSaved),
            ("deleted badge wording", saved.deletedBadgeText == "Only copy"
                && unsaved.deletedBadgeText == "Deleted on AO3" && series.deletedBadgeText == nil),
            ("deleted banner wording", saved.deletedBannerText?.contains("only one left") == true
                && unsaved.deletedBannerText?.contains("before you could save it") == true),
            ("statsLine", saved.statsLine.hasSuffix("words · 4/? chapters") && unsaved.statsLine == "3/3 chapters"
                && series.statsLine == "7 works"),
            ("nonBlank", blank.nonBlank == nil && none.nonBlank == nil && "x".nonBlank == "x"),
            ("completion labels", CompletionFilter.allCases.map(\.label) == ["Any", "Complete", "WIP"]),
            ("User-Agent reports the tool version",
                AO3Config.defaultUserAgent(ao3User: "u").hasPrefix("ao3-archiver/\(AO3Config.toolVersion) ")),
        ]
    }
}

import Foundation

/// Orchestrates a backup run: page through a listing, ingest each card into the `Store`,
/// expand bookmarked series into their member works, then download EPUBs for everything
/// that needs one — all through the single polite `AO3Client`.
///
/// **Resumable & bounded.** Every page and every EPUB is committed immediately, and
/// "needs download" is recomputed from the DB, so an interrupted run resumes without
/// re-fetching finished work. `maxPages` is a hard bound (politeness + a guard against a
/// pathological listing); this user alone has ~91 bookmark pages, so an unbounded crawl is
/// never an implicit default.
/// An `actor`, not a class: `chapterGains` below is mutated across `await` boundaries, and
/// the previous `final class … @unchecked Sendable` made "no overlapping runs" a promise in a
/// comment that the compiler never checked. Actor isolation makes it real, and it also stops
/// the whole engine from silently inheriting the caller's actor — the GUI's sync task used to
/// inherit `@MainActor`, so every HTML parse, DB write, and EPUB write ran on the main thread.
public actor SyncEngine {
    let client: AO3Client
    let store: Store
    let files: FileStore
    let downloader: WorkDownloader

    /// workID → chapters gained since the last sync, recorded during ingest and consumed by
    /// the following download pass to report "gained N chapters" instead of a bare file-size
    /// line. Scoped to one `run`/`incrementalSync` call (reset at its start); actor isolation
    /// is what guarantees two runs can't interleave over it.
    private var chapterGains: [Int: Int] = [:]

    /// Identity recorded with each 404 sighting. Deletion needs `Store.deletedConfirmThreshold`
    /// sightings from *distinct* sources, so every sync run must record under its own id —
    /// with one fixed source the second sighting just overwrote the first and the threshold
    /// could never be reached. Set per run in `run`/`incrementalSync`.
    private var sightingSource = "local"
    public static func sightingSource(runID: Int64) -> String { "run-\(runID)" }

    /// Hard cap on pages fetched per series during expansion (AO3 paginates series at 20
    /// works per page), so one enormous series can't turn into an unbounded crawl.
    public static let maxSeriesPages = 10

    /// AO3's logged-out page chrome plausibly carries its own `action="/users/login"` form
    /// (it's site-wide navigation), so an anonymous sync hitting a legitimately-empty page
    /// must never be misread as "your cookie expired" — gate the login-page check on a
    /// cookie actually having been supplied in the first place.
    private var hasCookie: Bool {
        AO3Config.sanitizeCookie(client.config.sessionCookie) != nil
    }

    public init(client: AO3Client, store: Store, files: FileStore) {
        self.client = client
        self.store = store
        self.files = files
        self.downloader = WorkDownloader(client: client)
    }

    public struct Options: Sendable {
        /// Hard cap on listing pages fetched in one index pass.
        public var maxPages: Int
        /// Cap on EPUB downloads in one content pass (nil = all that need one).
        public var maxDownloads: Int?
        /// Fetch each bookmarked series' page and back up its member works.
        public var expandSeries: Bool
        /// Continue the index from where the last run left off (resume-from-page) instead of
        /// restarting at page 1 — for large accounts AO3 throttles mid-index.
        public var resumeIndex: Bool
        /// Hard cap on the number of bookmarked series fetched in one expansion pass — each
        /// series is its own request, so without this an account with many series could issue
        /// an unbounded number of requests in a single run (the rate limiter keeps them polite
        /// but bounded-by-default is the contract).
        public var maxSeries: Int
        /// Full run only: after a *verified complete* index, reconcile bookmarks you removed
        /// on AO3 (see `pruneDecision` for the guards). Off by default — the GUI's Full sync
        /// opts in; the CLI's bounded runs never see the whole listing anyway.
        public var pruneRemovedBookmarks: Bool
        /// Quick sync only: expand up to this many *never-expanded* bookmarked series (one
        /// request each, plus pages), so series don't stay metadata-only until a Full sync.
        public var expandNewSeries: Int
        public init(maxPages: Int = 5, maxDownloads: Int? = nil, expandSeries: Bool = true,
                    resumeIndex: Bool = false, maxSeries: Int = 50,
                    pruneRemovedBookmarks: Bool = false, expandNewSeries: Int = 0) {
            self.maxPages = maxPages
            self.maxDownloads = maxDownloads
            self.expandSeries = expandSeries
            self.resumeIndex = resumeIndex
            self.maxSeries = maxSeries
            self.pruneRemovedBookmarks = pruneRemovedBookmarks
            self.expandNewSeries = expandNewSeries
        }
    }

    public static let resumeKey = "index_resume_path"

    /// Absolute page number embedded in a listing URL (`…&page=N`), for progress + resume.
    public static func pageNumber(inPath path: String) -> Int? {
        guard let r = path.range(of: #"page=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(path[r].dropFirst("page=".count))
    }

    public struct Result: Sendable, Equatable {
        public var pagesScanned = 0
        public var cardsSeen = 0
        public var works = 0
        public var external = 0
        public var series = 0
        public var seriesExpanded = 0
        public var epubsDownloaded = 0
        public var downloadsFailed = 0
        /// Of `downloadsFailed`, how many failed because AO3 returned a genuine 404 — the work
        /// was deleted by its author, not a transient/auth failure. A subset, not additional.
        public var worksDeleted = 0
        /// Bookmarks reconciled as removed on AO3: kept-but-flagged (still saved locally) and
        /// deleted outright. Both 0 when pruning was off or skipped.
        public var bookmarksFlaggedRemoved = 0
        public var bookmarksDeleted = 0
        public init() {}
    }

    /// Structured progress for the CLI log and the sync-status UI.
    public enum Event: Sendable {
        case page(Int, total: Int?, cards: Int)
        case expandingSeries(id: Int, members: Int)
        case downloaded(workID: Int, bytes: Int, title: String)
        case downloadFailed(workID: Int, reason: String)
        case message(String)
    }

    // MARK: - Full run

    /// Index → (series expansion) → content download. Records a `sync_run` row.
    @discardableResult
    public func run(listPath: String, options: Options = Options(),
                    onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        let runID = try store.beginSyncRun()
        chapterGains = [:]
        sightingSource = Self.sightingSource(runID: runID)
        var result = Result()
        do {
            let indexStart = Store.nowISO()
            result = try await indexSync(listPath: listPath, options: options, onEvent: onEvent)
            if options.pruneRemovedBookmarks {
                result = try pruneRemovedBookmarks(since: indexStart, into: result, onEvent: onEvent)
            }
            if options.expandSeries {
                result = try await expandSeries(into: result, maxSeries: options.maxSeries, onEvent: onEvent)
            }
            let (downloaded, failed, deleted) = try await contentSync(limit: options.maxDownloads, onEvent: onEvent)
            result.epubsDownloaded = downloaded
            result.downloadsFailed = failed
            result.worksDeleted = deleted
            try store.finishSyncRun(id: runID, pages: result.pagesScanned, worksSeen: result.works,
                                    downloaded: downloaded, status: "ok", message: nil)
            return result
        } catch {
            try? store.finishSyncRun(id: runID, pages: result.pagesScanned, worksSeen: result.works,
                                     downloaded: result.epubsDownloaded, status: "error",
                                     message: String(describing: error))
            throw error
        }
    }

    // MARK: - Incremental ("Quick") sync

    /// Meta key: unix ts of the last *successful* incremental sync — the frontier the
    /// updated-works pass walks back to.
    public static let lastIncrementalSyncKey = "last_incremental_sync_at"

    /// AO3 bookmark sort column for "Date Updated" (newest revision first), vs. the default
    /// "Date Bookmarked". Brackets are percent-encoded so `URL(string:)` accepts the path.
    static let dateUpdatedSortQuery = "bookmark_search%5Bsort_column%5D=bookmarkable_date"

    /// Append the date-updated sort to a bookmarks listing path.
    public static func sortedByDateUpdated(_ path: String) -> String {
        path + (path.contains("?") ? "&" : "?") + dateUpdatedSortQuery
    }

    /// A bounded, two-pass catch-up that stays cheap on AO3:
    ///   1. **New bookmarks** — page the default (date-bookmarked) listing, stopping the moment
    ///      a page introduces no bookmark we haven't already recorded.
    ///   2. **Updated works** — page the *date-updated* listing, stopping once a page is entirely
    ///      older than our last successful run; re-ingesting bumps `updated_at`, which re-arms the
    ///      download for anything whose chapters changed.
    ///   3. **Re-download** — fetch fresh EPUBs for the already-downloaded works that just went
    ///      stale (only those; the never-downloaded backlog is left for a Full sync).
    /// Both index passes are hard-capped by `options.maxPages`. The frontier watermark is the
    /// run's *start* time, persisted only on success, so a work updated mid-run isn't skipped.
    @discardableResult
    public func incrementalSync(listPath: String, options: Options = Options(),
                                onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        let runID = try store.beginSyncRun()
        chapterGains = [:]
        sightingSource = Self.sightingSource(runID: runID)
        let runStart = Int(Date().timeIntervalSince1970)
        let watermark = (try? store.getMeta(Self.lastIncrementalSyncKey)).flatMap { $0 }.flatMap { Int($0) }
        var result = Result()
        do {
            result = try await indexNewBookmarks(listPath: listPath, options: options,
                                                 into: result, onEvent: onEvent)
            result = try await indexUpdatedWorks(listPath: listPath, since: watermark,
                                                 options: options, into: result, onEvent: onEvent)
            if options.expandNewSeries > 0 {
                let fresh = Array(try store.unexpandedSeriesIDs().prefix(options.expandNewSeries))
                if !fresh.isEmpty {
                    result = try await expandSeries(into: result, seriesIDs: fresh, onEvent: onEvent)
                }
            }
            let (downloaded, failed, deleted) = try await redownloadUpdated(limit: options.maxDownloads, onEvent: onEvent)
            result.epubsDownloaded = downloaded
            result.downloadsFailed = failed
            result.worksDeleted = deleted
            try store.setMeta(Self.lastIncrementalSyncKey, String(runStart))   // persist frontier on success
            try store.finishSyncRun(id: runID, pages: result.pagesScanned, worksSeen: result.works,
                                    downloaded: downloaded, status: "ok", message: nil)
            return result
        } catch {
            try? store.finishSyncRun(id: runID, pages: result.pagesScanned, worksSeen: result.works,
                                     downloaded: result.epubsDownloaded, status: "error",
                                     message: String(describing: error))
            throw error
        }
    }

    /// Pass 1: page the default (date-bookmarked) listing, stopping once a page adds nothing new.
    public func indexNewBookmarks(listPath: String, options: Options, into base: Result,
                                  onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = base
        var nextPath: String? = listPath
        var total: Int?
        var pages = 0
        while let path = nextPath, pages < options.maxPages {
            let html = try await client.getHTML(path: path)
            if total == nil { total = try BlurbParser.lastPageNumber(html: html) }
            let cards = try BlurbParser.parseListing(html: html)
            if hasCookie, BlurbParser.looksLikeLoginPage(html: html, cardCount: cards.count) {
                throw AO3Error.sessionExpired
            }
            let ids = cards.compactMap { $0.bookmarkID }
            let known = try store.knownBookmarkIDs(among: ids)
            for card in cards { try ingest(card, onEvent: onEvent) }
            pages += 1
            let absPage = Self.pageNumber(inPath: path) ?? pages
            result.pagesScanned = max(result.pagesScanned, absPage)
            result.cardsSeen += cards.count
            result.works += cards.filter { $0.kind == .work }.count
            result.external += cards.filter { $0.kind == .external }.count
            result.series += cards.filter { $0.kind == .series }.count
            onEvent(.page(absPage, total: total, cards: cards.count))
            if Self.noNewBookmarks(pageIDs: ids, known: known) { break }   // reached known territory
            nextPath = try BlurbParser.nextPagePath(html: html)
        }
        return result
    }

    /// Pass 2: page the date-updated listing, ingesting cards (which re-arms downloads for any
    /// whose `updated_at` advanced), stopping once a whole page predates the last run.
    public func indexUpdatedWorks(listPath: String, since watermark: Int?, options: Options,
                                  into base: Result,
                                  onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = base
        var nextPath: String? = Self.sortedByDateUpdated(listPath)
        var pages = 0
        while let path = nextPath, pages < options.maxPages {
            let html = try await client.getHTML(path: path)
            let cards = try BlurbParser.parseListing(html: html)
            if hasCookie, BlurbParser.looksLikeLoginPage(html: html, cardCount: cards.count) {
                throw AO3Error.sessionExpired
            }
            for card in cards { try ingest(card, onEvent: onEvent) }
            pages += 1
            let absPage = Self.pageNumber(inPath: path) ?? pages
            result.pagesScanned = max(result.pagesScanned, absPage)
            onEvent(.message("Checked \(cards.count) recently-updated bookmarks"))
            if Self.reachedUpdateFrontier(pageCards: cards, since: watermark) { break }
            nextPath = try BlurbParser.nextPagePath(html: html)
        }
        return result
    }

    /// Stop the new-bookmarks pass when every bookmark on the page is already recorded (in
    /// date-bookmarked order, new bookmarks cluster at the top, so this means we've caught up).
    public static func noNewBookmarks(pageIDs: [Int], known: Set<Int>) -> Bool {
        pageIDs.allSatisfy { known.contains($0) }
    }

    /// Stop the updated-works pass when the whole page predates our last successful run. With no
    /// watermark (first ever run) we never stop early — the page cap is the only bound. A card
    /// whose `updatedAt` failed to parse (nil) is treated as "unknown", NOT "old": it doesn't
    /// count toward the frontier, so parser drift can't silently end the pass early (it just
    /// keeps paging to the cap — fail-soft in the safe direction).
    public static func reachedUpdateFrontier(pageCards: [WorkBlurb], since watermark: Int?) -> Bool {
        guard let watermark else { return false }
        return pageCards.allSatisfy { card in card.updatedAt.map { $0 < watermark } ?? false }
    }

    // MARK: - Index sync (paginated)

    /// Page through the listing, ingesting cards, until the "Next" link disappears or
    /// `maxPages` is hit.
    public func indexSync(listPath: String, options: Options,
                          onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = Result()
        // Resume from the saved page if asked and present; else start at page 1.
        var nextPath: String? = listPath
        var coverage = IndexCoverage()
        if options.resumeIndex, let saved = try store.getMeta(Self.resumeKey), !saved.isEmpty,
           Self.sameListing(saved, listPath) {
            nextPath = saved
            coverage.startedAtFirstPage = false
        }
        lastIndexCoverage = nil
        var total: Int?
        var pagesThisRun = 0
        while let path = nextPath, pagesThisRun < options.maxPages {
            let html = try await client.getHTML(path: path)
            if total == nil { total = try BlurbParser.lastPageNumber(html: html) }   // "page N of T"
            let cards = try BlurbParser.parseListing(html: html)
            if hasCookie, BlurbParser.looksLikeLoginPage(html: html, cardCount: cards.count) {
                throw AO3Error.sessionExpired
            }
            for card in cards { try ingest(card, onEvent: onEvent) }
            if coverage.listingTotal == nil { coverage.listingTotal = BlurbParser.listingTotal(html: html) }
            for card in cards { if let id = card.bookmarkID { coverage.seenBookmarkIDs.insert(id) } }
            coverage.seenPrivate += cards.filter(\.isPrivate).count
            pagesThisRun += 1
            let absPage = Self.pageNumber(inPath: path) ?? pagesThisRun
            result.pagesScanned = absPage
            result.cardsSeen += cards.count
            result.works += cards.filter { $0.kind == .work }.count
            result.external += cards.filter { $0.kind == .external }.count
            result.series += cards.filter { $0.kind == .series }.count
            onEvent(.page(absPage, total: total, cards: cards.count))
            let np = try BlurbParser.nextPagePath(html: html)
            // Persist where to continue next time; clear it once the index is complete, so a
            // later run re-indexes from page 1 (picking up new bookmarks). Only a resumable
            // full index touches this — a quick sync (latest pages) leaves it untouched.
            if options.resumeIndex {
                if let np { try store.setMeta(Self.resumeKey, np) } else { try store.clearMeta(Self.resumeKey) }
            }
            nextPath = np
            if np == nil { coverage.reachedEnd = true }
        }
        lastIndexCoverage = coverage
        return result
    }

    // MARK: - Removed-bookmark reconciliation

    /// What one `indexSync` pass provably saw — the evidence `pruneDecision` weighs.
    public struct IndexCoverage: Sendable, Equatable {
        public var startedAtFirstPage = true
        public var reachedEnd = false
        public var listingTotal: Int?
        public var seenBookmarkIDs: Set<Int> = []
        public var seenPrivate = 0
        public init() {}
    }
    private var lastIndexCoverage: IndexCoverage?

    public enum PruneDecision: Sendable, Equatable {
        case prune
        case skip(String)
    }

    /// Whether it's safe to treat "not seen this run" as "removed on AO3". Deleting on a
    /// partial view would destroy real bookmarks, so every guard must pass:
    /// - a session cookie — AO3 shows *private* bookmarks only to their logged-in owner, and an
    ///   expired cookie on your own listing serves the public ones rather than a login page;
    /// - the pass started at page 1 (not a resumed cursor) and ran until there was no Next link;
    /// - it saw exactly as many distinct bookmarks as AO3's heading says exist (a page that
    ///   shifted mid-run, or a truncated listing, fails this);
    /// - if we hold private bookmarks, the pass saw private ones too;
    /// - and the removal is small: at most 5% of bookmarks (min 25) — a big drop is far more
    ///   likely a parse or auth problem than you un-bookmarking hundreds of works at once.
    public static func pruneDecision(coverage: IndexCoverage, hasCookie: Bool,
                                     census: Store.BookmarkCensus) -> PruneDecision {
        guard hasCookie else { return .skip("no session cookie (private bookmarks would look removed)") }
        guard coverage.startedAtFirstPage else { return .skip("this run resumed mid-listing") }
        guard coverage.reachedEnd else { return .skip("the listing wasn't read to the end") }
        guard let total = coverage.listingTotal else { return .skip("AO3 didn't report a bookmark total") }
        guard coverage.seenBookmarkIDs.count == total else {
            return .skip("saw \(coverage.seenBookmarkIDs.count) of \(total) bookmarks")
        }
        guard census.activePrivate == 0 || coverage.seenPrivate > 0 else {
            return .skip("no private bookmarks were visible (is the cookie still valid?)")
        }
        let cap = max(25, census.active / 20)
        guard census.notSeenSince <= cap else {
            return .skip("\(census.notSeenSince) bookmarks would be removed — more than the \(cap) safety cap")
        }
        return .prune
    }

    private func pruneRemovedBookmarks(since cutoff: String, into base: Result,
                                       onEvent: @Sendable (Event) -> Void) throws -> Result {
        var result = base
        guard let coverage = lastIndexCoverage else { return result }
        let census = try store.bookmarkCensus(notSeenSince: cutoff)
        guard census.notSeenSince > 0 else { return result }
        switch Self.pruneDecision(coverage: coverage, hasCookie: hasCookie, census: census) {
        case .skip(let why):
            onEvent(.message("Not removing \(census.notSeenSince) bookmark(s) missing from AO3 — \(why)"))
        case .prune:
            let (flagged, deleted) = try store.applyBookmarkRemovals(notSeenSince: cutoff)
            result.bookmarksFlaggedRemoved = flagged
            result.bookmarksDeleted = deleted
            onEvent(.message("Removed \(deleted) bookmark(s) you un-bookmarked on AO3"
                + (flagged > 0 ? "; kept \(flagged) saved work(s), marked no longer bookmarked" : "")))
        }
        return result
    }

    /// Whether a saved resume cursor belongs to the listing we're about to index. The cursor
    /// used to be followed verbatim, so after a run over a different list (the anonymous
    /// demo tag, or another username) a Full sync silently resumed *that* list instead.
    public static func sameListing(_ a: String, _ b: String) -> Bool {
        func base(_ p: String) -> Substring { p.split(separator: "?", maxSplits: 1).first ?? "" }
        return base(a) == base(b)
    }

    /// Persist one parsed card: the item row (work/external/series) plus its bookmark row.
    /// A work whose chapter count grew since we last saw it is recorded in `chapterGains`, so
    /// the download pass that follows can report "gained N chapters" once the file is actually
    /// (re)saved, instead of claiming it before the bytes are on disk.
    private func ingest(_ card: WorkBlurb, onEvent: @Sendable (Event) -> Void) throws {
        switch card.kind {
        case .work, .external:
            let change = card.bookmarkID == nil ? try store.upsertWork(card) : try store.upsertWorkAndBookmark(card)
            if let gained = change.newChapters { chapterGains[card.workID] = gained }
        case .series:
            try store.upsertSeries(card)
            try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        }
    }

    // MARK: - Series expansion

    /// For each bookmarked series (capped at `maxSeries`), fetch its page, ingest the member
    /// works, and link them.
    public func expandSeries(into base: Result, maxSeries: Int = .max, seriesIDs: [Int]? = nil,
                             onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = base
        for seriesID in try (seriesIDs ?? store.bookmarkedSeriesIDs()).prefix(maxSeries) {
            // AO3 paginates a series' works; follow "Next" (bounded) so parts past the first
            // page aren't silently dropped. `part` keeps counting across pages.
            var nextPath: String? = "/series/\(seriesID)?view_adult=true"
            var part = 0, pages = 0
            while let path = nextPath, pages < Self.maxSeriesPages {
                let html = try await client.getHTML(path: path)
                for member in try BlurbParser.parseListing(html: html) {
                    part += 1
                    guard member.kind == .work else { continue }
                    try store.upsertSeriesMember(member, seriesID: seriesID, part: part)
                }
                pages += 1
                nextPath = try BlurbParser.nextPagePath(html: html)
            }
            result.seriesExpanded += 1
            // Member works land in the store (and the download queue); they're not folded
            // into the page-card breakdown, which counts only what the listing pages showed.
            onEvent(.expandingSeries(id: seriesID, members: part))
        }
        return result
    }

    // MARK: - Content sync (download queue)

    /// Download EPUBs for every work that needs one (the full backlog), committing each
    /// immediately. Returns (downloaded, failed, deleted).
    public func contentSync(limit: Int?,
                            onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> (Int, Int, Int) {
        try await download(store.worksNeedingDownload(limit: limit), onEvent: onEvent)
    }

    /// Re-download only works we already hold whose `updated_at` advanced (a new chapter /
    /// revision). The download cap applies *here* — it never gets eaten by the never-downloaded
    /// backlog, so a Quick sync reliably refreshes stale files within its query budget.
    public func redownloadUpdated(limit: Int?,
                                  onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> (Int, Int, Int) {
        try await download(store.worksNeedingRedownload(limit: limit), onEvent: onEvent)
    }

    /// Hard cap on one "save these works" request — each work is two polite requests.
    public static let maxSelectedDownloads = 100

    /// Download the given works (e.g. everything currently visible in the gallery), capped at
    /// `maxSelectedDownloads`, skipping ones already saved and up to date. Recorded as a sync
    /// run so deletion sightings and bookkeeping behave exactly like a normal pass.
    @discardableResult
    public func downloadSelected(workIDs: [Int],
                                 onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        let runID = try store.beginSyncRun()
        chapterGains = [:]
        sightingSource = Self.sightingSource(runID: runID)
        var result = Result()
        do {
            let pending = try workIDs.lazy.compactMap { try self.store.pendingWork(workID: $0) }
                .filter { !$0.isCurrent }
                .prefix(Self.maxSelectedDownloads)
            let (downloaded, failed, deleted) = try await download(Array(pending), onEvent: onEvent)
            result.epubsDownloaded = downloaded
            result.downloadsFailed = failed
            result.worksDeleted = deleted
            try store.finishSyncRun(id: runID, pages: 0, worksSeen: 0, downloaded: downloaded,
                                    status: "ok", message: nil)
            return result
        } catch {
            try? store.finishSyncRun(id: runID, pages: 0, worksSeen: 0, downloaded: result.epubsDownloaded,
                                     status: "error", message: String(describing: error))
            throw error
        }
    }

    /// Download, save and record ONE work — the single path both the sync loop and the detail
    /// view's Download button use (the button used to carry its own copy of these steps).
    /// Removes the file a re-download under a new title supersedes. Throws on any failure;
    /// the caller decides how to surface it. Returns the EPUB's size in bytes.
    @discardableResult
    public func downloadWork(_ work: Store.PendingWork) async throws -> Int {
        let data = try await downloader.downloadEPUB(workID: work.id)
        let rel = try files.writeEPUB(data, workID: work.id, title: work.title)
        try store.markDownloaded(workID: work.id, epubPath: rel, updatedAt: work.updatedAt)
        files.removeSupersededEPUB(previous: work.epubPath, current: rel, workID: work.id)
        return data.count
    }

    /// Shared download loop for a pre-computed pending list. A genuine 404 means the work was
    /// deleted by its author (not a transient/auth failure) — recorded distinctly so we stop
    /// re-requesting it and the UI can flag "your saved copy is the only one left".
    private func download(_ pending: [Store.PendingWork],
                          onEvent: @Sendable (Event) -> Void) async throws -> (Int, Int, Int) {
        var downloaded = 0, failed = 0, deleted = 0
        for work in pending {
            try Task.checkCancellation()
            do {
                let bytes = try await downloadWork(work)
                downloaded += 1
                onEvent(.downloaded(workID: work.id, bytes: bytes, title: work.title))
                if let gained = chapterGains.removeValue(forKey: work.id) {
                    onEvent(.message("\(work.title) gained \(gained) chapter\(gained == 1 ? "" : "s") — saved"))
                }
            } catch is CancellationError {
                // The user pressed Cancel. Stop the batch — the catch-all below used to park
                // this as a per-work failure and carry on, marking every remaining queued work
                // failed and then reporting the run "ok"/"Done".
                throw CancellationError()
            } catch AO3Error.http(404) {
                // A 404 is evidence, not proof — AO3 also 404s during deploys and for works
                // flipped to registered-users-only. Only a corroborated sighting latches the
                // work out of the download queues, and the log line says which we have.
                let confirmed = (try? store.recordDeletedSighting(workID: work.id, source: sightingSource)) ?? false
                failed += 1
                let msg: String
                if confirmed {
                    deleted += 1
                    msg = work.hasDownload
                        ? "\(work.title) was deleted on AO3 — your saved copy is the only one left"
                        : "\(work.title) was deleted on AO3 before you could save it"
                } else {
                    msg = "\(work.title) wasn't found on AO3 — will re-check next sync before "
                        + "marking it deleted"
                }
                onEvent(.message(msg))
                onEvent(.downloadFailed(workID: work.id,
                                        reason: confirmed ? "deleted on AO3" : "not found (unconfirmed)"))
            } catch {
                // Park ANY failure on one work so the rest of the batch still runs: restricted/
                // locked works (no cookie, an AO3Error), but also a disk-write failure or a DB
                // hiccup — none of which should abort the whole content pass. `last_error` records
                // why; the bookkeeping write is `try?` so a failure there can't re-abort the loop.
                let reason = String(describing: error)
                try? store.markFailed(workID: work.id, error: reason)
                failed += 1
                onEvent(.downloadFailed(workID: work.id, reason: reason))
            }
        }
        return (downloaded, failed, deleted)
    }
}

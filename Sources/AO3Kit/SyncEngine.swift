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
public final class SyncEngine: @unchecked Sendable {
    let client: AO3Client
    let store: Store
    let files: FileStore
    let downloader: WorkDownloader

    /// workID → chapters gained since the last sync, recorded during ingest and consumed by
    /// the following download pass to report "gained N chapters" instead of a bare file-size
    /// line. Scoped to one `run`/`incrementalSync` call (reset at its start) — SyncEngine
    /// doesn't support overlapping runs (SyncController already guards against starting a
    /// second one while the first is in flight).
    private var chapterGains: [Int: Int] = [:]

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
        public init(maxPages: Int = 5, maxDownloads: Int? = nil, expandSeries: Bool = true,
                    resumeIndex: Bool = false, maxSeries: Int = 50) {
            self.maxPages = maxPages
            self.maxDownloads = maxDownloads
            self.expandSeries = expandSeries
            self.resumeIndex = resumeIndex
            self.maxSeries = maxSeries
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
        var result = Result()
        do {
            result = try await indexSync(listPath: listPath, options: options, onEvent: onEvent)
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
        let runStart = Int(Date().timeIntervalSince1970)
        let watermark = (try? store.getMeta(Self.lastIncrementalSyncKey)).flatMap { $0 }.flatMap { Int($0) }
        var result = Result()
        do {
            result = try await indexNewBookmarks(listPath: listPath, options: options,
                                                 into: result, onEvent: onEvent)
            result = try await indexUpdatedWorks(listPath: listPath, since: watermark,
                                                 options: options, into: result, onEvent: onEvent)
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
        if options.resumeIndex, let saved = try store.getMeta(Self.resumeKey), !saved.isEmpty {
            nextPath = saved
        }
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
        }
        return result
    }

    /// Persist one parsed card: the item row (work/external/series) plus its bookmark row.
    /// A work whose chapter count grew since we last saw it is recorded in `chapterGains`, so
    /// the download pass that follows can report "gained N chapters" once the file is actually
    /// (re)saved, instead of claiming it before the bytes are on disk.
    private func ingest(_ card: WorkBlurb, onEvent: @Sendable (Event) -> Void) throws {
        switch card.kind {
        case .work, .external:
            let change = try store.upsertWork(card)
            try store.upsertBookmark(card, itemKind: card.kind, itemID: card.workID)
            if let gained = change.newChapters { chapterGains[card.workID] = gained }
        case .series:
            try store.upsertSeries(card)
            try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        }
    }

    // MARK: - Series expansion

    /// For each bookmarked series (capped at `maxSeries`), fetch its page, ingest the member
    /// works, and link them.
    public func expandSeries(into base: Result, maxSeries: Int = .max,
                             onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = base
        for seriesID in try store.bookmarkedSeriesIDs().prefix(maxSeries) {
            let html = try await client.getHTML(path: "/series/\(seriesID)?view_adult=true")
            let members = try BlurbParser.parseListing(html: html)
            for (i, member) in members.enumerated() where member.kind == .work {
                try store.upsertWork(member)
                try store.linkSeriesWork(seriesID: seriesID, workID: member.workID, part: i + 1)
            }
            result.seriesExpanded += 1
            // Member works land in the store (and the download queue); they're not folded
            // into the page-card breakdown, which counts only what the listing pages showed.
            onEvent(.expandingSeries(id: seriesID, members: members.count))
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

    /// Shared download loop for a pre-computed pending list. A genuine 404 means the work was
    /// deleted by its author (not a transient/auth failure) — recorded distinctly so we stop
    /// re-requesting it and the UI can flag "your saved copy is the only one left".
    private func download(_ pending: [Store.PendingWork],
                          onEvent: @Sendable (Event) -> Void) async throws -> (Int, Int, Int) {
        var downloaded = 0, failed = 0, deleted = 0
        for work in pending {
            do {
                let data = try await downloader.downloadEPUB(workID: work.id)
                let rel = try files.writeEPUB(data, workID: work.id, title: work.title)
                try store.markDownloaded(workID: work.id, epubPath: rel, updatedAt: work.updatedAt)
                downloaded += 1
                onEvent(.downloaded(workID: work.id, bytes: data.count, title: work.title))
                if let gained = chapterGains.removeValue(forKey: work.id) {
                    onEvent(.message("\(work.title) gained \(gained) chapter\(gained == 1 ? "" : "s") — saved"))
                }
            } catch AO3Error.http(404) {
                try? store.markDeletedOnAO3(workID: work.id)
                failed += 1
                deleted += 1
                let msg = work.hasDownload
                    ? "\(work.title) was deleted on AO3 — your saved copy is the only one left"
                    : "\(work.title) was deleted on AO3 before you could save it"
                onEvent(.message(msg))
                onEvent(.downloadFailed(workID: work.id, reason: "deleted on AO3"))
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

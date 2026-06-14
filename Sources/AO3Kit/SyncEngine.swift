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
        public init(maxPages: Int = 5, maxDownloads: Int? = nil, expandSeries: Bool = true) {
            self.maxPages = maxPages
            self.maxDownloads = maxDownloads
            self.expandSeries = expandSeries
        }
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
        var result = Result()
        do {
            result = try await indexSync(listPath: listPath, options: options, onEvent: onEvent)
            if options.expandSeries {
                result = try await expandSeries(into: result, onEvent: onEvent)
            }
            let (downloaded, failed) = try await contentSync(limit: options.maxDownloads, onEvent: onEvent)
            result.epubsDownloaded = downloaded
            result.downloadsFailed = failed
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

    // MARK: - Index sync (paginated)

    /// Page through the listing, ingesting cards, until the "Next" link disappears or
    /// `maxPages` is hit.
    public func indexSync(listPath: String, options: Options,
                          onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = Result()
        var nextPath: String? = listPath
        var page = 0
        var total: Int?
        while let path = nextPath, page < options.maxPages {
            let html = try await client.getHTML(path: path)
            if page == 0 { total = try BlurbParser.lastPageNumber(html: html) }   // "page N of T"
            let cards = try BlurbParser.parseListing(html: html)
            for card in cards { try ingest(card) }
            page += 1
            result.pagesScanned = page
            result.cardsSeen += cards.count
            result.works += cards.filter { $0.kind == .work }.count
            result.external += cards.filter { $0.kind == .external }.count
            result.series += cards.filter { $0.kind == .series }.count
            onEvent(.page(page, total: total, cards: cards.count))
            nextPath = try BlurbParser.nextPagePath(html: html)
        }
        return result
    }

    /// Persist one parsed card: the item row (work/external/series) plus its bookmark row.
    private func ingest(_ card: WorkBlurb) throws {
        switch card.kind {
        case .work, .external:
            try store.upsertWork(card)
            try store.upsertBookmark(card, itemKind: card.kind, itemID: card.workID)
        case .series:
            try store.upsertSeries(card)
            try store.upsertBookmark(card, itemKind: .series, itemID: card.workID)
        }
    }

    // MARK: - Series expansion

    /// For each bookmarked series, fetch its page, ingest the member works, and link them.
    public func expandSeries(into base: Result,
                             onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var result = base
        for seriesID in try store.bookmarkedSeriesIDs() {
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

    /// Download EPUBs for every work that needs one, committing each immediately.
    /// Returns (downloaded, failed).
    public func contentSync(limit: Int?,
                            onEvent: @Sendable (Event) -> Void = { _ in }) async throws -> (Int, Int) {
        let pending = try store.worksNeedingDownload(limit: limit)
        var downloaded = 0, failed = 0
        for work in pending {
            do {
                let data = try await downloader.downloadEPUB(workID: work.id)
                let rel = try files.writeEPUB(data, workID: work.id, title: work.title)
                try store.markDownloaded(workID: work.id, epubPath: rel, updatedAt: work.updatedAt)
                downloaded += 1
                onEvent(.downloaded(workID: work.id, bytes: data.count, title: work.title))
            } catch let e as AO3Error {
                // Restricted/locked works (no cookie) and the like: park them so the queue
                // doesn't spin on the same failure. last_error records why.
                try store.markFailed(workID: work.id, error: String(describing: e))
                failed += 1
                onEvent(.downloadFailed(workID: work.id, reason: String(describing: e)))
            }
        }
        return (downloaded, failed)
    }
}

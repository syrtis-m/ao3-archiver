import Foundation
import Observation
import AO3Kit

/// Drives a sync from the GUI: runs the tested `SyncEngine` off the main actor and publishes
/// rich, live progress for the sync sheet — page N of T, a rate-limit banner (so a backoff
/// doesn't look like a stall), and a torrent-style activity feed of recent events. The
/// orchestration/correctness lives in `SyncEngine` (unit-tested); this is the UI wrapper.
@Observable
@MainActor
final class SyncController {
    enum Phase: Equatable { case idle, running, done, failed, cancelled }

    var phase: Phase = .idle
    var statusLine = ""
    var currentPage = 0
    var totalPages: Int?
    var downloaded = 0
    var failed = 0
    var lastError: String?
    /// Non-nil while AO3 is throttling us and we're sleeping before a retry.
    var rateLimit: String?
    /// Recent events, newest first (capped) — the "what's happening right now" feed.
    var activity: [String] = []

    private var task: Task<Void, Never>?
    /// Refreshes the gallery from the store. Called live as pages index (so the list builds
    /// up before your eyes) and whenever a run ends — even partial/cancelled, so whatever got
    /// indexed is shown.
    private var reload: () -> Void = {}

    /// Coalesces the live "grow the gallery" reloads (M6/P3-B). Each `reload()` is a full
    /// `fetchAllListItems` + recompute; at scale that rebuild is expensive, and a burst of
    /// pages/downloads would fire one per event. We cap it to one reload per ~1.2s — the list
    /// still grows visibly, just in batches — and `endRun` does a final immediate flush so the
    /// complete result is never left behind.
    private var pendingReload: Task<Void, Never>?
    private var lastReload: Date = .distantPast
    private static let reloadInterval: TimeInterval = 1.2

    private func scheduleReload() {
        guard pendingReload == nil else { return }   // one already queued for this window
        let delay = max(0, Self.reloadInterval - Date().timeIntervalSince(lastReload))
        pendingReload = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            self.reload()
        }
    }

    private func flushReload() {
        pendingReload?.cancel(); pendingReload = nil
        lastReload = Date()
        reload()
    }

    var isRunning: Bool { phase == .running }

    /// `downloadEPUBs == false` is an **index-only** run: page through bookmarks and record
    /// the lightweight metadata in the DB, no EPUB downloads (faster, gentler on AO3 — get
    /// the list first, download works individually or in a later full sync). `interval` is
    /// the seconds between requests (politeness; raise it if AO3 throttles you).
    func start(store: Store, username: String?, cookie: String?, archiveRoot: URL,
               interval: TimeInterval, downloadEPUBs: Bool, maxPages: Int = 999,
               resumeIndex: Bool = true, incremental: Bool = false,
               reload: @escaping () -> Void) {
        guard phase != .running else { return }
        self.reload = reload
        phase = .running; statusLine = downloadEPUBs ? "Starting…" : "Building bookmark list…"
        currentPage = 0; totalPages = nil; downloaded = 0; failed = 0
        lastError = nil; rateLimit = nil; activity = []

        let userAgent = AO3Config.defaultUserAgent(ao3User: username)
        let listPath = username.flatMap { $0.isEmpty ? nil : "/users/\($0)/bookmarks?page=1" }
            ?? "/tags/Good%20Omens%20(TV)/works"   // anonymous demo when no username

        task = Task { [weak self] in
            do {
                // maxRetries bumped: a long index reliably hits AO3's throttle, and we want
                // it to wait it out (visibly) rather than give up.
                let client = AO3Client(config: AO3Config(
                    userAgent: userAgent, sessionCookie: cookie,
                    minRequestInterval: interval, maxRetries: 8))
                client.onRateLimit = { secs, attempt, max in
                    Task { @MainActor in self?.noteRateLimit(secs, attempt: attempt, max: max) }
                }
                let files = FileStore(root: archiveRoot)
                try files.ensureDirectories()
                let engine = SyncEngine(client: client, store: store, files: files)
                let onEvent: @Sendable (SyncEngine.Event) -> Void = { event in
                    Task { @MainActor in self?.apply(event) }
                }
                let result: SyncEngine.Result
                if incremental {
                    // Quick sync: bounded two-pass catch-up. expandSeries OFF (one query per
                    // series defeats "limited queries"); downloads are re-downloads only, capped
                    // to keep the run cheap — any overflow drains on the next quick sync.
                    let options = SyncEngine.Options(maxPages: maxPages, maxDownloads: 25,
                                                     expandSeries: false, resumeIndex: false)
                    result = try await engine.incrementalSync(listPath: listPath, options: options, onEvent: onEvent)
                } else {
                    let options = SyncEngine.Options(maxPages: maxPages,
                                                     maxDownloads: downloadEPUBs ? 50 : 0,
                                                     expandSeries: downloadEPUBs,
                                                     resumeIndex: resumeIndex)
                    result = try await engine.run(listPath: listPath, options: options, onEvent: onEvent)
                }
                self?.finish(result: result)
            } catch is CancellationError {
                self?.endRun(.cancelled)
            } catch {
                self?.lastError = String(describing: error)
                self?.push("Stopped: \(error)")
                self?.endRun(.failed)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if phase == .running { statusLine = "Cancelled"; endRun(.cancelled) }
    }

    private func finish(result: SyncEngine.Result) {
        downloaded = result.epubsDownloaded
        failed = result.downloadsFailed
        statusLine = "Done — \(result.works) works listed, \(result.epubsDownloaded) saved"
            + (result.downloadsFailed > 0 ? " (\(result.downloadsFailed) need a cookie)" : "")
        push(statusLine)
        endRun(.done)
    }

    private func endRun(_ phase: Phase) {
        self.phase = phase
        rateLimit = nil
        flushReload()   // final, immediate — show whatever got indexed, even on cancel/fail
    }

    private func noteRateLimit(_ seconds: TimeInterval, attempt: Int, max: Int) {
        rateLimit = "AO3 asked us to slow down — waiting \(Int(seconds))s (retry \(attempt)/\(max))"
        push("Rate limited — waiting \(Int(seconds))s")
    }

    private func apply(_ event: SyncEngine.Event) {
        switch event {
        case let .page(n, total, cards):
            rateLimit = nil                 // got a page through → not throttled right now
            currentPage = n; totalPages = total
            statusLine = "Indexing page \(n)\(total.map { " of \($0)" } ?? "")"
            push("Page \(n)\(total.map { " of \($0)" } ?? ""): \(cards) bookmarks")
            scheduleReload()                // grow the gallery live (coalesced) as pages index
        case let .expandingSeries(id, members):
            statusLine = "Expanding series"
            push("Series \(id): \(members) works")
        case let .downloaded(_, bytes, title):
            downloaded += 1
            statusLine = "Saved \(downloaded)"
            push("Saved (\(bytes / 1024) KB): \(title)")
            scheduleReload()                // reflect saved state in the gallery (coalesced)
        case let .downloadFailed(workID, reason):
            failed += 1
            push("Couldn't download \(workID): \(reason)")
        case let .message(message):
            push(message)
        }
    }

    private func push(_ line: String) {
        activity.insert(line, at: 0)
        if activity.count > 40 { activity.removeLast() }
    }
}

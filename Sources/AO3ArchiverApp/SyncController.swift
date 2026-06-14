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

    var isRunning: Bool { phase == .running }

    func start(store: Store, username: String?, cookie: String?, archiveRoot: URL,
               maxPages: Int = 999, maxDownloads: Int = 50,
               onFinished: @escaping () -> Void) {
        guard phase != .running else { return }
        phase = .running; statusLine = "Starting…"
        currentPage = 0; totalPages = nil; downloaded = 0; failed = 0
        lastError = nil; rateLimit = nil; activity = []

        let userAgent = "ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)"
        let listPath = username.flatMap { $0.isEmpty ? nil : "/users/\($0)/bookmarks?page=1" }
            ?? "/tags/Good%20Omens%20(TV)/works"   // anonymous demo when no username

        task = Task { [weak self] in
            do {
                // maxRetries bumped: a 130-page index reliably hits AO3's throttle, and we
                // want it to wait it out (visibly) rather than give up.
                let client = AO3Client(config: AO3Config(
                    userAgent: userAgent, sessionCookie: cookie, maxRetries: 8))
                client.onRateLimit = { secs, attempt, max in
                    Task { @MainActor in self?.noteRateLimit(secs, attempt: attempt, max: max) }
                }
                let files = FileStore(root: archiveRoot)
                try files.ensureDirectories()
                let engine = SyncEngine(client: client, store: store, files: files)
                let options = SyncEngine.Options(maxPages: maxPages, maxDownloads: maxDownloads,
                                                 expandSeries: true)
                let result = try await engine.run(listPath: listPath, options: options) { event in
                    Task { @MainActor in self?.apply(event) }
                }
                self?.finish(result: result, onFinished: onFinished)
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed
                self?.lastError = String(describing: error)
                self?.push("Stopped: \(error)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        if phase == .running { phase = .cancelled; statusLine = "Cancelled" }
    }

    private func finish(result: SyncEngine.Result, onFinished: @escaping () -> Void) {
        downloaded = result.epubsDownloaded
        failed = result.downloadsFailed
        rateLimit = nil
        statusLine = "Done — \(result.works) works seen, \(result.epubsDownloaded) saved"
            + (result.downloadsFailed > 0 ? " (\(result.downloadsFailed) need a cookie)" : "")
        phase = .done
        push(statusLine)
        onFinished()
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
        case let .expandingSeries(id, members):
            statusLine = "Expanding series"
            push("Series \(id): \(members) works")
        case let .downloaded(_, bytes, title):
            downloaded += 1
            statusLine = "Saved \(downloaded)"
            push("Saved (\(bytes / 1024) KB): \(title)")
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

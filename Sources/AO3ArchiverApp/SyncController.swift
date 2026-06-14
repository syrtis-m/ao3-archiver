import Foundation
import Observation
import AO3Kit

/// Drives a sync from the GUI: runs the tested `SyncEngine` off the main actor and publishes
/// observable progress for the sync sheet. The orchestration/correctness lives in
/// `SyncEngine` (unit-tested); this is the thin UI-facing wrapper.
@Observable
@MainActor
final class SyncController {
    enum Phase: Equatable { case idle, running, done, failed, cancelled }

    var phase: Phase = .idle
    var statusLine = ""
    var pagesScanned = 0
    var downloaded = 0
    var failed = 0
    var lastError: String?

    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    /// Start a bounded sync into `archiveRoot`, writing through the app's existing `store`
    /// (single connection, so the gallery reload sees the new rows). `maxDownloads` caps
    /// EPUBs per run (click again to fetch more); `maxPages` is wide so the whole account
    /// gets indexed.
    func start(store: Store, username: String?, cookie: String?, archiveRoot: URL,
               maxPages: Int = 999, maxDownloads: Int = 50,
               onFinished: @escaping () -> Void) {
        guard phase != .running else { return }
        phase = .running; statusLine = "Starting…"
        pagesScanned = 0; downloaded = 0; failed = 0; lastError = nil

        let userAgent = "ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)"
        let listPath = username.flatMap { $0.isEmpty ? nil : "/users/\($0)/bookmarks?page=1" }
            ?? "/tags/Good%20Omens%20(TV)/works"   // anonymous demo when no username

        task = Task { [weak self] in
            do {
                let client = AO3Client(config: AO3Config(userAgent: userAgent, sessionCookie: cookie))
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
        statusLine = "Done — \(result.works) works seen, \(result.epubsDownloaded) saved"
            + (result.downloadsFailed > 0 ? " (\(result.downloadsFailed) need a cookie)" : "")
        phase = .done
        onFinished()
    }

    private func apply(_ event: SyncEngine.Event) {
        switch event {
        case let .page(n, cards):
            pagesScanned = n; statusLine = "Indexing page \(n) — \(cards) bookmarks"
        case let .expandingSeries(id, members):
            statusLine = "Expanding series \(id) — \(members) works"
        case let .downloaded(_, _, title):
            downloaded += 1; statusLine = "Saved: \(title)"
        case let .downloadFailed(workID, reason):
            failed += 1; statusLine = "Couldn't download \(workID): \(reason)"
        case let .message(message):
            statusLine = message
        }
    }
}

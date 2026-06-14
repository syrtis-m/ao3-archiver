import Foundation
import AO3Kit

// ─────────────────────────────────────────────────────────────────────────────
// M1 CLI: a real, bounded backup run.
//
//   1. authenticate (with or without a session cookie),
//   2. page through bookmarks (bounded by AO3_MAX_PAGES), ingesting every card into
//      the SQLite store — works, external works, and series alike,
//   3. expand each bookmarked series into its member works,
//   4. download EPUBs for everything that needs one (bounded by AO3_MAX_DOWNLOADS),
//      writing files under the archive folder and recording state in the DB.
//
// Everything flows through the one polite, rate-limited AO3Client. Bounds default low
// because politeness is a hard requirement (this user alone has ~91 bookmark pages).
// Configuration is via environment variables (so cookies never land in shell history).
// ─────────────────────────────────────────────────────────────────────────────

func env(_ key: String) -> String? {
    let v = ProcessInfo.processInfo.environment[key]
    return (v?.isEmpty == false) ? v : nil
}
func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let username   = env("AO3_USERNAME")
let cookie     = env("AO3_SESSION_COOKIE")
let userAgent  = env("AO3_USER_AGENT")
    ?? AO3Config.defaultUserAgent(ao3User: username)
// Default to ~/Documents/ao3archive (same as the app), so CLI sync and the GUI share a folder.
let defaultArchiveDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    .first?.appendingPathComponent("ao3archive").path
    ?? FileManager.default.currentDirectoryPath + "/archive"
let archiveDir = env("AO3_ARCHIVE_DIR") ?? defaultArchiveDir
let interval   = env("AO3_MIN_INTERVAL").flatMap(Double.init) ?? 4
let maxPages   = env("AO3_MAX_PAGES").flatMap(Int.init) ?? 2
let maxDownloads = env("AO3_MAX_DOWNLOADS").flatMap(Int.init) ?? 3
let expandSeries = (env("AO3_EXPAND_SERIES") ?? "1") != "0"

// List source: explicit override > the user's bookmarks > a public demo listing.
let demoPath = "/tags/Good%20Omens%20(TV)/works"
let listPath: String = {
    if let override = env("AO3_LIST_PATH") { return override }
    if let username { return "/users/\(username)/bookmarks?page=1" }
    return demoPath
}()

stderr("AO3 Archiver — M1 sync")
stderr("  source:    \(listPath)")
stderr("  auth:      \(cookie != nil ? "session cookie present" : "anonymous (public only)")")
stderr("  rate:      1 request / \(interval)s")
stderr("  archive:   \(archiveDir)")
stderr("  bounds:    \(maxPages) page(s), \(maxDownloads) download(s), expandSeries=\(expandSeries)")
if username == nil && env("AO3_LIST_PATH") == nil {
    stderr("  note:      no AO3_USERNAME set — using a public demo listing.\n")
} else {
    stderr("")
}

let client = AO3Client(config: AO3Config(
    userAgent: userAgent,
    sessionCookie: cookie,
    minRequestInterval: interval
))

do {
    let files = FileStore(root: URL(fileURLWithPath: archiveDir))
    try files.ensureDirectories()
    let store = try Store(path: files.databaseURL.path)
    let engine = SyncEngine(client: client, store: store, files: files)
    let options = SyncEngine.Options(maxPages: maxPages, maxDownloads: maxDownloads,
                                     expandSeries: expandSeries)

    stderr("→ syncing…")
    let result = try await engine.run(listPath: listPath, options: options) { event in
        switch event {
        case let .page(n, total, cards):
            stderr("  • page \(n)\(total.map { " of \($0)" } ?? ""): \(cards) cards")
        case let .expandingSeries(id, members):
            stderr("  • series \(id): \(members) member works")
        case let .downloaded(workID, bytes, title):
            stderr("  ✓ \(workID) (\(bytes) bytes) — \(title)")
        case let .downloadFailed(workID, reason):
            stderr("  ✗ \(workID): \(reason)")
        case let .message(m):
            stderr("  • \(m)")
        }
    }

    stderr("""

    ── sync complete ─────────────────────────────────────────
      pages scanned:     \(result.pagesScanned)
      cards seen:        \(result.cardsSeen)  (\(result.works) work / \(result.external) external / \(result.series) series)
      series expanded:   \(result.seriesExpanded)
      EPUBs downloaded:  \(result.epubsDownloaded)\(result.downloadsFailed > 0 ? "  (\(result.downloadsFailed) failed — likely need a cookie)" : "")
    ── store totals ──────────────────────────────────────────
      works:             \(try store.count("work"))
      series:            \(try store.count("series"))
      bookmarks:         \(try store.count("bookmark"))
      tags:              \(try store.count("tag"))
      still to download: \(try store.worksNeedingDownload().count)
    ──────────────────────────────────────────────────────────
      database:          \(files.databaseURL.path)
    """)
    stderr("\nM1 OK — paginated index sync + series expansion + content download all working.")
} catch let e as AO3Error {
    stderr("✗ \(e)")
    exit(1)
} catch {
    stderr("✗ \(error)")
    exit(1)
}

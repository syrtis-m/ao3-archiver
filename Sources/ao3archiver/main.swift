import Foundation
import AO3Kit

// ─────────────────────────────────────────────────────────────────────────────
// M0 spike CLI.
//
// Proves the riskiest mechanics end-to-end before any SwiftUI exists:
//   1. authenticate (with or without a session cookie),
//   2. fetch + parse one page of bookmarks (or a public listing as a no-creds demo),
//   3. download one work's server-rendered EPUB through the polite rate limiter.
//
// Configuration is via environment variables (so cookies never land in shell history
// files / argv). See README for usage.
// ─────────────────────────────────────────────────────────────────────────────

func env(_ key: String) -> String? {
    let v = ProcessInfo.processInfo.environment[key]
    return (v?.isEmpty == false) ? v : nil
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func printTable(_ blurbs: [WorkBlurb]) {
    func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s.padding(toLength: n, withPad: " ", startingAt: 0)
                     : String(s.prefix(n - 1)) + "…"
    }
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    stderr("  \(clip("title", 34))  \(clip("author", 18))  \(pad("words", 7))  \(pad("kudos", 6))  done")
    stderr("  " + String(repeating: "─", count: 78))
    for b in blurbs.prefix(20) {
        let words = pad(b.wordCount.map(String.init) ?? "—", 7)
        let kudos = pad(b.kudos.map(String.init) ?? "—", 6)
        let done: String
        switch b.kind {
        case .external: done = "ext"
        case .series:   done = "ser"
        case .work:     done = b.isComplete == nil ? " ? " : (b.isComplete! ? "yes" : "wip")
        }
        stderr("  \(clip(b.title, 34))  \(clip(b.author, 18))  \(words)  \(kudos)  \(done)")
    }
}

let username   = env("AO3_USERNAME")
let cookie     = env("AO3_SESSION_COOKIE")
let userAgent  = env("AO3_USER_AGENT")
    ?? "ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)"
let archiveDir = env("AO3_ARCHIVE_DIR") ?? FileManager.default.currentDirectoryPath + "/archive"
let interval   = env("AO3_MIN_INTERVAL").flatMap(Double.init) ?? 4

// List source: explicit override > the user's bookmarks > a public demo listing.
let demoPath = "/tags/Good%20Omens%20(TV)/works"
let listPath: String = {
    if let override = env("AO3_LIST_PATH") { return override }
    if let username { return "/users/\(username)/bookmarks?page=1" }
    return demoPath
}()

stderr("AO3 Archiver — M0 spike")
stderr("  source:   \(listPath)")
stderr("  auth:     \(cookie != nil ? "session cookie present" : "anonymous (public only)")")
stderr("  rate:     1 request / \(interval)s")
stderr("  archive:  \(archiveDir)")
if username == nil && env("AO3_LIST_PATH") == nil {
    stderr("  note:     no AO3_USERNAME set — using a public demo listing.\n")
} else {
    stderr("")
}

let client = AO3Client(config: AO3Config(
    userAgent: userAgent,
    sessionCookie: cookie,
    minRequestInterval: interval
))

do {
    // 1 + 2. Fetch and parse the listing.
    stderr("→ fetching listing…")
    let html = try await client.getHTML(path: listPath)
    let blurbs = try BlurbParser.parseListing(html: html)
    guard !blurbs.isEmpty else {
        stderr("✗ parsed 0 works. If this is your bookmarks page, the cookie may be missing/expired.")
        exit(2)
    }
    let works    = blurbs.filter { $0.kind == .work }
    let external = blurbs.filter { $0.kind == .external }
    let series   = blurbs.filter { $0.kind == .series }
    stderr("✓ parsed \(blurbs.count) cards — \(works.count) works, \(external.count) external, \(series.count) series\n")
    printTable(blurbs)

    // 3. Download the first *downloadable* work's EPUB (external/series have no EPUB).
    guard let target = works.first else {
        stderr("\nNo downloadable AO3 works on this page (external/series only) — nothing to download.")
        stderr("\nM0 OK — auth + parse all working.")
        exit(0)
    }
    stderr("\n→ downloading EPUB for first work: \(target.workID) “\(target.title)”…")
    let downloader = WorkDownloader(client: client)
    let data = try await downloader.downloadEPUB(workID: target.workID)

    try FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
    let filename = ArchivePaths.epubFilename(workID: target.workID, title: target.title)
    let outURL = URL(fileURLWithPath: archiveDir).appendingPathComponent(filename)
    try data.write(to: outURL)

    stderr("✓ saved \(data.count) bytes → \(outURL.path)")
    stderr("✓ valid EPUB: \(WorkDownloader.looksLikeEPUB(data))")
    stderr("\nM0 OK — auth + parse + rate-limited download all working.")
} catch let e as AO3Error {
    stderr("✗ \(e)")
    exit(1)
} catch {
    stderr("✗ \(error)")
    exit(1)
}

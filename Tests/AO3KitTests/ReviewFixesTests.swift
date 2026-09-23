import Testing
import Foundation
@testable import AO3Kit

/// Regression coverage for the September 2026 review fixes. Mirrored check-for-check in
/// `Sources/selftest/main.swift` ("Review fixes") per the lockstep rule.
@Suite struct ReviewFixesTests {

    private func fixtureCard() throws -> WorkBlurb {
        let url = try #require(Bundle.module.url(forResource: "bookmarks_page", withExtension: "html",
                                                 subdirectory: "Fixtures"))
        return try #require(try BlurbParser.parseListing(html: String(contentsOf: url, encoding: .utf8))
            .first { $0.kind == .work })
    }

    private func item(_ store: Store, _ id: Int) throws -> WorkListItem? {
        try store.fetchAllListItems().first { $0.itemID == id }
    }

    /// A failed *refresh* of a work we already hold must not demote it to 'failed' — that hid
    /// Read / Open / Kindle and dropped it from the Saved filter while the file was on disk.
    @Test func failedRefreshKeepsSavedWorkSaved() throws {
        let card = try fixtureCard()
        let store = try Store(inMemory: true)
        try store.upsertWork(card)
        try store.upsertBookmark(card, itemKind: .work, itemID: card.workID)

        try store.markFailed(workID: card.workID, error: "HTTP 525")
        #expect(try item(store, card.workID)?.downloadState == "failed")   // nothing saved yet

        try store.markDownloaded(workID: card.workID, epubPath: "works/x.epub", updatedAt: card.updatedAt)
        try store.markFailed(workID: card.workID, error: "HTTP 525")
        let after = try item(store, card.workID)
        #expect(after?.downloadState == "downloaded")
        #expect(DownloadFilter.saved.matches(after?.downloadState ?? ""))
    }

    /// Each run records under its own source, so two runs' 404s reach the threshold — with a
    /// single fixed source the second sighting overwrote the first and deletion never confirmed.
    @Test func sightingsFromTwoRunsConfirmDeletion() throws {
        #expect(SyncEngine.sightingSource(runID: 1) != SyncEngine.sightingSource(runID: 2))
        let card = try fixtureCard()
        let store = try Store(inMemory: true)
        try store.upsertWork(card)
        #expect(try store.recordDeletedSighting(workID: card.workID, source: SyncEngine.sightingSource(runID: 1)) == false)
        #expect(try store.recordDeletedSighting(workID: card.workID, source: SyncEngine.sightingSource(runID: 1)) == false)
        #expect(try store.recordDeletedSighting(workID: card.workID, source: SyncEngine.sightingSource(runID: 2)) == true)
    }

    /// A successful download proves the work exists: stale sightings must not linger and
    /// combine with an unrelated future 404.
    @Test func successfulDownloadClearsSightings() throws {
        let card = try fixtureCard()
        let store = try Store(inMemory: true)
        try store.upsertWork(card)
        try store.recordDeletedSighting(workID: card.workID, source: "run-1")
        try store.markDownloaded(workID: card.workID, epubPath: "works/x.epub", updatedAt: card.updatedAt)
        #expect(try store.deletedSightingCount(workID: card.workID) == 0)
        #expect(try store.recordDeletedSighting(workID: card.workID, source: "run-9") == false)
    }

    /// A work re-confirmed deleted after its recheck window must get a fresh timestamp, or
    /// the exclusion never re-applies and it's re-requested every sync forever.
    @Test func reconfirmationAfterRecheckWindowReExcludes() throws {
        let card = try fixtureCard()
        let store = try Store(inMemory: true)
        try store.upsertWork(card)
        try store.recordDeletedSighting(workID: card.workID, source: "run-1")
        try store.recordDeletedSighting(workID: card.workID, source: "run-2")
        let stale = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(Store.deletedRecheckDays + 1) * 86_400))
        try store.backdateDeletedConfirmation(workID: card.workID, to: stale)
        #expect(try store.worksNeedingDownload().contains { $0.id == card.workID })
        #expect(try store.recordDeletedSighting(workID: card.workID, source: "run-3") == true)
        #expect(!(try store.worksNeedingDownload().contains { $0.id == card.workID }))
    }

    @Test func resumeCursorOnlyAppliesToSameListing() {
        #expect(SyncEngine.sameListing("/users/a/bookmarks?page=7", "/users/a/bookmarks?page=1"))
        #expect(!SyncEngine.sameListing("/tags/Good%20Omens%20(TV)/works?page=7", "/users/a/bookmarks?page=1"))
        #expect(!SyncEngine.sameListing("/users/b/bookmarks?page=7", "/users/a/bookmarks?page=1"))
    }

    @Test func filenamesStayWithinAPFSLimits() {
        let zalgo = String(repeating: "a\u{0301}\u{0302}\u{0303}\u{0304}", count: 120)
        #expect(ArchivePaths.epubFilename(workID: 123456789, title: zalgo).utf16.count <= 255)
        #expect(!ArchivePaths.sanitize(".hack//SIGN").hasPrefix("."))
        #expect(ArchivePaths.sanitize("...") == "untitled")
        #expect(ArchivePaths.sanitize("A/B: C?") == "A B C")   // unchanged behaviour
    }

    @Test func removesOnlyTheSupersededFileForThisWork() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileStore(root: root)
        let old = try files.writeEPUB(Data("PK\u{3}\u{4}".utf8), workID: 7, title: "Old Name")
        let new = try files.writeEPUB(Data("PK\u{3}\u{4}".utf8), workID: 7, title: "New Name")
        let other = try files.writeEPUB(Data("PK\u{3}\u{4}".utf8), workID: 8, title: "Old Name")
        files.removeSupersededEPUB(previous: other, current: new, workID: 7)   // wrong work: kept
        files.removeSupersededEPUB(previous: new, current: new, workID: 7)     // same path: kept
        files.removeSupersededEPUB(previous: old, current: new, workID: 7)
        #expect(!files.fileExists(relativePath: old))
        #expect(files.fileExists(relativePath: new))
        #expect(files.fileExists(relativePath: other))
    }

    @Test func searchMatchesWarnings() {
        let item = WorkListItem(itemID: 1, kind: .work, sourcePath: "/works/1", title: "T", author: "A",
                                warnings: ["Major Character Death"])
        #expect(item.searchHaystack.contains("major character death"))
    }

    /// WebKit resolves URLs by WHATWG rules, so prefix matching missed several remote forms.
    @Test func sanitizerClassifiesURLsLikeWebKit() {
        for remote in ["https:evil.com/x.png", "ht\ttps://evil.com/x", "https:\\\\evil.com\\x",
                       "  HTTPS://evil.com", "ftp://x", "wss://x"] {
            #expect(EpubSanitizer.isRemote(remote), "\(remote)")
        }
        for local in ["images/a.png", "ch2.xhtml?from=https://x", "#top", "data:image/png;base64,AA",
                      "mailto:a@b.c", "ch 1:2.html", ""] {
            #expect(!EpubSanitizer.isRemote(local), "\(local)")
        }
    }

    @Test func sanitizerCoversSVGAndSrcsetAndLinks() {
        let clean = EpubSanitizer.sanitize("""
            <html><body>
            <svg><image xlink:href="https://evil.example/a.png"/><a xlink:href="javascript:alert(1)">x</a>
            <set attributeName="href" to="https://evil.example/s"/><animate attributeName="href" values="javascript:x"/></svg>
            <img srcset="local.png 1x, https:evil.example/b.png 2x"/><img srcset="local.png 1x, local@2x.png 2x"/>
            <link rel="stylesheet" href="local.css"/><a ping="https://evil.example/p" href="ch2.xhtml">n</a>
            </body></html>
            """)
        #expect(!clean.contains("evil.example"))
        #expect(!clean.lowercased().contains("javascript:"))
        #expect(!clean.lowercased().contains("<link"))
        #expect(clean.contains("local@2x.png"))
        #expect(clean.contains("ch2.xhtml"))
    }

    @Test func languageTagCannotInjectMarkup() {
        #expect(EpubDocument.safeLanguageTag("en-GB") == "en-GB")
        #expect(EpubDocument.safeLanguageTag(nil) == "en")
        #expect(EpubDocument.safeLanguageTag("en\"><script>fetch(1)</script>") == "en")
    }

    /// Two exports of the same title used to share one temp path and race (copy "already
    /// exists" / one deleting the other's file mid-hand-off).
    @Test func sameTitleKindleExportsDoNotCollide() throws {
        let src = try SyntheticEpub.makeAO3Like()
        let info = KindleExport.WorkInfo(title: "Same", author: "A", fandoms: ["X"], wordCount: 1_000)
        let a = try KindleExport.makeKindleEPUB(source: src, work: info)
        let b = try KindleExport.makeKindleEPUB(source: src, work: info)
        defer { for u in [a, b] { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) } }
        #expect(a != b)
        #expect(a.lastPathComponent == b.lastPathComponent)   // filename still the badged title
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func rateLimiterThrowsWhenCancelled() async {
        let limiter = RateLimiter()
        let task = Task {
            try await limiter.waitTurn(minInterval: 10)
            try await limiter.waitTurn(minInterval: 10)   // must sleep ~10s — cancellation cuts it
        }
        task.cancel()
        let result = await task.result
        #expect((try? result.get()) == nil)
    }
}

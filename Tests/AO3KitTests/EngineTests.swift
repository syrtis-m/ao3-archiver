import Testing
import Foundation
import AO3Kit
import AO3KitTestSupport

/// End-to-end `SyncEngine` runs against a stub AO3 (no network). The scenarios live in
/// `AO3KitTestSupport/EngineScenarios.swift` and are shared verbatim with `selftest`.
@Suite struct EngineTests {
    @Test(arguments: EngineScenarios.all.indices)
    func scenario(_ index: Int) async throws {
        let (name, run) = EngineScenarios.all[index]
        for check in try await run() {
            #expect(check.ok, "\(name): \(check.name)")
        }
    }
}

@Suite struct ReaderScenarioTests {
    @MainActor @Test func galleryReloadOffMain() async throws {
        for check in try await ReaderScenarios.galleryReload() { #expect(check.ok, "\(check.name)") }
    }

    @MainActor @Test func extractionIsOffMainAndFailuresSurface() async throws {
        let url = try SyntheticEpub.make(flavour: .nav)
        defer { try? FileManager.default.removeItem(at: url) }
        for check in try await ReaderScenarios.extraction(epubURL: url) {
            #expect(check.ok, "\(check.name)")
        }
    }
}

@Suite struct ModelCheckTests {
    @Test func presentation() {
        for check in ModelChecks.presentation() { #expect(check.ok, "\(check.name)") }
    }
    @Test func saveVisiblePlan() {
        for check in ModelChecks.saveVisiblePlan() { #expect(check.ok, "\(check.name)") }
    }
    @Test func singleFileArchive() throws {
        for check in try ModelChecks.singleFileArchive() { #expect(check.ok, "\(check.name)") }
    }
    @Test func migrationSurvivesDanglingRows() throws {
        for check in try ModelChecks.migrationSurvivesDanglingRows() { #expect(check.ok, "\(check.name)") }
    }
    @Test func pruneGuards() {
        for check in ModelChecks.pruneGuards() { #expect(check.ok, "\(check.name)") }
    }
    @Test func orphanSweep() throws {
        for check in try ModelChecks.orphanSweep() { #expect(check.ok, "\(check.name)") }
    }
    @Test func listingTotal() throws {
        let url = try #require(Bundle.module.url(forResource: "bookmarks_page", withExtension: "html",
                                                 subdirectory: "Fixtures"))
        for check in ModelChecks.listingTotal(bookmarksFixtureHTML: try String(contentsOf: url, encoding: .utf8)) {
            #expect(check.ok, "\(check.name)")
        }
    }
    @Test func staleSyncRuns() throws {
        for check in try ModelChecks.staleSyncRuns() { #expect(check.ok, "\(check.name)") }
    }
}

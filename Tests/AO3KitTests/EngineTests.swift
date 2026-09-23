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
    @Test func staleSyncRuns() throws {
        for check in try ModelChecks.staleSyncRuns() { #expect(check.ok, "\(check.name)") }
    }
}

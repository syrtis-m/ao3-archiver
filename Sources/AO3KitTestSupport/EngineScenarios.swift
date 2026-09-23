import Foundation
import AO3Kit

/// End-to-end `SyncEngine` scenarios against `StubAO3`, written ONCE and run by both test
/// runners (`AO3KitTests/EngineTests.swift` and `selftest`) — the lockstep rule by
/// construction. Each scenario returns named checks; a runner asserts every one is true.
public enum EngineScenarios {
    public typealias Check = (name: String, ok: Bool)

    /// Every scenario, by name, for runners that want to iterate.
    public static let all: [(String, @Sendable () async throws -> [Check])] = [
        ("deletion confirms only across two runs", deletionConfirmsAcrossTwoRuns),
        ("cancel mid-download marks nothing failed", cancelDuringDownloadsMarksNothingFailed),
        ("series pagination is followed", seriesPaginationIsFollowed),
        ("resume cursor from another listing is ignored", resumeCursorFromOtherListingIsIgnored),
    ]

    // MARK: - Fixtures

    struct Env {
        let stub = StubAO3()
        let store: Store
        let files: FileStore
        let root: URL
        init() throws {
            store = try Store(inMemory: true)
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("engine-\(UUID())")
            files = FileStore(root: root)
            try files.ensureDirectories()
        }
        func engine(cookie: String? = "stub-cookie") -> SyncEngine {
            SyncEngine(client: stub.client(cookie: cookie), store: store, files: files)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static let listPath = "/users/u/bookmarks?page=1"

    static func state(_ store: Store, _ id: Int) throws -> String? {
        try store.fetchAllListItems().first { $0.itemID == id }?.downloadState
    }

    // MARK: - Scenarios

    /// Two 404s within ONE run are one sighting; a second run confirms. (With a fixed sighting
    /// source the threshold was unreachable — only a Store-level test with two made-up sources
    /// ever reached it.)
    public static func deletionConfirmsAcrossTwoRuns() async throws -> [Check] {
        let env = try Env(); defer { env.cleanup() }
        env.stub.route([
            "/users/u/bookmarks": .html(StubAO3.bookmarksPage([(1, 101, "Gone", false)])),
            "/works/101": .notFound,
        ])
        let opts = SyncEngine.Options(maxPages: 1, expandSeries: false)
        let r1 = try await env.engine().run(listPath: listPath, options: opts)
        let after1 = try env.store.deletedSightingCount(workID: 101)
        let queued1 = try env.store.worksNeedingDownload().contains { $0.id == 101 }
        let r2 = try await env.engine().run(listPath: listPath, options: opts)
        let after2 = try env.store.deletedSightingCount(workID: 101)
        let queued2 = try env.store.worksNeedingDownload().contains { $0.id == 101 }
        let badged = try env.store.fetchAllListItems().first { $0.itemID == 101 }?.deletedOnAO3 == true
        return [
            ("run 1: one sighting, not confirmed", after1 == 1 && r1.worksDeleted == 0 && queued1),
            ("run 2: second sighting confirms and dequeues", after2 == 2 && r2.worksDeleted == 1 && !queued2),
            ("confirmed work is badged deleted", badged),
            ("no unexpected requests", env.stub.unmatched.isEmpty),
        ]
    }

    /// Cancel while downloading: the run stops (throws `CancellationError`), and the works it
    /// didn't get to are left exactly as they were — not parked as failed.
    public static func cancelDuringDownloadsMarksNothingFailed() async throws -> [Check] {
        let env = try Env(); defer { env.cleanup() }
        env.stub.route([
            "/users/u/bookmarks": .html(StubAO3.bookmarksPage([(3, 203, "C", false), (2, 202, "B", false),
                                                              (1, 201, "A", false)])),
            "/works/201": .html(StubAO3.workPage(201)),
            "/downloads/201/Stub.epub": .epub,
            "/works/202": .html(StubAO3.workPage(202)),
            "/downloads/202/Stub.epub": .epub,
            "/works/203": .html(StubAO3.workPage(203)),
            "/downloads/203/Stub.epub": .epub,
        ])
        let engine = env.engine()
        let box = TaskBox()
        // Cancel the moment the *second* work's page is requested.
        let firstWork = LockedFlag()
        env.stub.onRequest = { key in
            guard key.hasPrefix("/works/") else { return }
            if firstWork.testAndSet() { box.cancel() }
        }
        let task = Task { try await engine.run(listPath: listPath,
                                               options: .init(maxPages: 1, expandSeries: false)) }
        box.set(task)
        var threwCancellation = false
        do { _ = try await task.value } catch is CancellationError { threwCancellation = true } catch {}
        let states = try [201, 202, 203].map { try state(env.store, $0) }
        return [
            ("run throws CancellationError", threwCancellation),
            ("nothing marked failed", !states.contains("failed")),
            ("unstarted works stay pending", states.filter { $0 == "pending" }.count >= 2),
            ("no unexpected requests", env.stub.unmatched.isEmpty),
        ]
    }

    /// A series spanning two pages links members from both, numbering parts continuously.
    public static func seriesPaginationIsFollowed() async throws -> [Check] {
        let env = try Env(); defer { env.cleanup() }
        try env.store.upsertSeries(WorkBlurb(kind: .series, sourcePath: "/series/9", workID: 9,
                                             title: "S", author: "a", bookmarkID: 900))
        env.stub.handler = { comps in
            guard comps.path == "/series/9" else { return nil }
            return (comps.query ?? "").contains("page=2")
                ? .html(StubAO3.seriesPage([(303, "P3")]))
                : .html(StubAO3.seriesPage([(301, "P1"), (302, "P2")], next: "/series/9?page=2"))
        }
        let r = try await env.engine().expandSeries(into: .init())
        let members = try env.store.fetchSeriesMembers(seriesID: 9).map(\.itemID)
        return [
            ("both pages fetched", env.stub.requests.count == 2),
            ("all members linked in order", members == [301, 302, 303]),
            ("series counted once", r.seriesExpanded == 1),
            ("no unexpected requests", env.stub.unmatched.isEmpty),
        ]
    }

    /// A saved Full-sync cursor from a different listing must not hijack this one.
    public static func resumeCursorFromOtherListingIsIgnored() async throws -> [Check] {
        let env = try Env(); defer { env.cleanup() }
        try env.store.setMeta(SyncEngine.resumeKey, "/tags/Other/works?page=7")
        env.stub.route(["/users/u/bookmarks": .html(StubAO3.bookmarksPage([(1, 101, "A", false)]))])
        _ = try await env.engine().indexSync(listPath: listPath,
                                             options: .init(maxPages: 1, expandSeries: false, resumeIndex: true))
        return [
            ("indexed the requested listing", env.stub.requests.first?.hasPrefix("/users/u/bookmarks") == true),
            ("never touched the stale listing", !env.stub.requests.contains { $0.hasPrefix("/tags/") }),
        ]
    }
}

/// Holds a task so a stub callback (on URLSession's queue) can cancel it.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SyncEngine.Result, Error>?
    private var cancelRequested = false
    func set(_ t: Task<SyncEngine.Result, Error>) {
        let cancelNow = lock.withLock { task = t; return cancelRequested }
        if cancelNow { t.cancel() }
    }
    func cancel() {
        let t = lock.withLock { cancelRequested = true; return task }
        t?.cancel()
    }
}

/// First call returns false, every later call true.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    func testAndSet() -> Bool { lock.withLock { defer { seen = true }; return seen } }
}

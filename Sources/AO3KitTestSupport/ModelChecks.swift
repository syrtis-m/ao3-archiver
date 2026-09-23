import Foundation
import AO3Kit

/// Synchronous model-level checks shared by both runners (see `EngineScenarios`).
public enum ModelChecks {
    /// Only runs older than the cutoff are closed; a recent one may be a live CLI sync.
    public static func staleSyncRuns() throws -> [EngineScenarios.Check] {
        let store = try Store(inMemory: true)
        let iso = ISO8601DateFormatter()
        let old = try store.beginSyncRun(now: iso.string(from: Date().addingTimeInterval(-24 * 3600)))
        let recent = try store.beginSyncRun(now: iso.string(from: Date().addingTimeInterval(-600)))
        let closed = try store.closeStaleSyncRuns(olderThanHours: 6)
        let again = try store.closeStaleSyncRuns(olderThanHours: 6)
        return [
            ("closes only the stale run", closed == 1 && again == 0),
            ("distinct run ids", old != recent),
        ]
    }

    public static func presentation() -> [EngineScenarios.Check] {
        let saved = WorkListItem(itemID: 1, kind: .work, sourcePath: "/works/1", title: "T", author: "A",
                                 wordCount: 12_328, chaptersHave: 4, downloadState: "failed",
                                 epubPath: "works/1 - T.epub", deletedOnAO3: true)
        let unsaved = WorkListItem(itemID: 2, kind: .work, sourcePath: "/works/2", title: "T", author: "A",
                                   chaptersHave: 3, chaptersTotal: 3, deletedOnAO3: true)
        let series = WorkListItem(itemID: 3, kind: .series, sourcePath: "/series/3", title: "S", author: "A",
                                  worksCount: 7, downloadState: "series")
        let blank: String? = "  \n", none: String? = nil
        return [
            ("isSaved keys on the file, not the state cache", saved.isSaved && !unsaved.isSaved && !series.isSaved),
            ("deleted badge wording", saved.deletedBadgeText == "Only copy"
                && unsaved.deletedBadgeText == "Deleted on AO3" && series.deletedBadgeText == nil),
            ("deleted banner wording", saved.deletedBannerText?.contains("only one left") == true
                && unsaved.deletedBannerText?.contains("before you could save it") == true),
            ("statsLine", saved.statsLine.hasSuffix("words · 4/? chapters") && unsaved.statsLine == "3/3 chapters"
                && series.statsLine == "7 works"),
            ("nonBlank", blank.nonBlank == nil && none.nonBlank == nil && "x".nonBlank == "x"),
            ("completion labels", CompletionFilter.allCases.map(\.label) == ["Any", "Complete", "WIP"]),
            ("User-Agent reports the tool version",
                AO3Config.defaultUserAgent(ao3User: "u").hasPrefix("ao3-archiver/\(AO3Config.toolVersion) ")),
        ]
    }
}

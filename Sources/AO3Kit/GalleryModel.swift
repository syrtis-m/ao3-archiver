import Foundation
import Observation
import GRDB

// The gallery's read/filter/sort layer. Everything here is below the SwiftUI line and
// unit-tested: the denormalized display model, the join that reassembles it, the pure
// filter/sort/facet engine, and the @Observable view model that wires them together. The
// SwiftUI views are a thin skin over this.

/// One row in the gallery — a single bookmark, flattened for display. Works, external
/// works, and series all become a `WorkListItem`; `kind` distinguishes them and the
/// work-only fields are nil for the others.
public struct WorkListItem: Sendable, Identifiable, Equatable, Hashable {
    public var itemID: Int            // work id or series id (namespace depends on kind)
    public var bookmarkID: Int?       // AO3 bookmark id; orders "date bookmarked"
    public var kind: BookmarkKind
    public var sourcePath: String     // /works/… /external_works/… /series/…
    public var title: String
    public var author: String
    public var authorURL: String?

    public var fandoms: [String]
    public var relationships: [String]
    public var characters: [String]
    public var freeforms: [String]
    public var warnings: [String]
    public var rating: String?
    public var category: String?
    public var isComplete: Bool?
    public var language: String?

    public var wordCount: Int?
    public var worksCount: Int?       // series only
    public var chaptersHave: Int?
    public var chaptersTotal: Int?
    public var kudos: Int?
    public var comments: Int?
    public var bookmarksCount: Int?
    public var hits: Int?

    public var summary: String?
    public var updatedAt: Int?
    public var dateText: String?
    public var bookmarkedAt: String?
    public var bookmarkTags: [String]
    public var bookmarkerNotes: String?
    public var isRec: Bool
    public var isPrivate: Bool

    /// work: pending|downloaded|failed|unavailable. series → "series" (no own file).
    public var downloadState: String
    public var epubPath: String?

    /// Stable, list-unique id (bookmark ids are unique; fall back for safety).
    public var id: String { bookmarkID.map(String.init) ?? "\(kind.rawValue)-\(itemID)" }

    /// Full AO3 URL for "view on AO3".
    public var ao3URL: URL? { URL(string: "https://archiveofourown.org" + sourcePath) }

    /// Concatenated text the search box matches against (built once at load).
    public var searchHaystack: String {
        ([title, author, summary ?? "", bookmarkerNotes ?? ""]
         + fandoms + relationships + characters + freeforms + bookmarkTags)
            .joined(separator: " ").lowercased()
    }
}

// MARK: - Loading (the join — the bug-prone part, tested)

extension Store {
    /// Load every bookmark as a flat `WorkListItem`. Tags are grouped in memory (one query
    /// each) so a work with N tags yields exactly one item with N tags — never N rows.
    public func fetchAllListItems() throws -> [WorkListItem] {
        try dbQueue.read { db in
            // Work tags grouped by work id.
            var tagsByWork: [Int: (f: [String], r: [String], c: [String], k: [String], w: [String])] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT wt.work_id AS wid, t.type AS type, t.name AS name
                FROM work_tag wt JOIN tag t ON t.id = wt.tag_id ORDER BY t.name
                """) {
                let wid: Int = row["wid"], type: String = row["type"], name: String = row["name"]
                var e = tagsByWork[wid] ?? ([], [], [], [], [])
                switch type {
                case "fandom":       e.f.append(name)
                case "relationship": e.r.append(name)
                case "character":    e.c.append(name)
                case "freeform":     e.k.append(name)
                case "warning":      e.w.append(name)
                default: break
                }
                tagsByWork[wid] = e
            }
            // Bookmarker tags grouped by bookmark id.
            var btagsByBookmark: [Int: [String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT bookmark_id AS bid, name FROM bookmark_tag ORDER BY name") {
                let bid: Int = row["bid"]
                btagsByBookmark[bid, default: []].append(row["name"])
            }

            var items: [WorkListItem] = []

            // Work / external bookmarks.
            for row in try Row.fetchAll(db, sql: """
                SELECT b.bookmark_id AS bid, b.bookmarked_at AS bat, b.bookmarker_notes AS bnotes,
                       b.is_rec AS brec, b.is_private AS bpriv, w.*
                FROM bookmark b JOIN work w ON b.item_kind = 'work' AND b.item_id = w.id
                """) {
                let wid: Int = row["id"]
                let t = tagsByWork[wid] ?? ([], [], [], [], [])
                let bid: Int = row["bid"]
                let complete: Int? = row["is_complete"]
                items.append(WorkListItem(
                    itemID: wid, bookmarkID: bid,
                    kind: BookmarkKind(rawValue: row["kind"]) ?? .work,
                    sourcePath: row["source_path"], title: row["title"], author: row["author"],
                    authorURL: row["author_url"],
                    fandoms: t.f, relationships: t.r, characters: t.c, freeforms: t.k, warnings: t.w,
                    rating: row["rating"], category: row["category"],
                    isComplete: complete.map { $0 != 0 }, language: row["language"],
                    wordCount: row["word_count"], worksCount: nil,
                    chaptersHave: row["chapters_have"], chaptersTotal: row["chapters_total"],
                    kudos: row["kudos"], comments: row["comments"],
                    bookmarksCount: row["bookmarks_count"], hits: row["hits"],
                    summary: row["summary"], updatedAt: row["updated_at"], dateText: row["date_text"],
                    bookmarkedAt: row["bat"], bookmarkTags: btagsByBookmark[bid] ?? [],
                    bookmarkerNotes: row["bnotes"],
                    isRec: (row["brec"] as Int? ?? 0) != 0, isPrivate: (row["bpriv"] as Int? ?? 0) != 0,
                    downloadState: row["download_state"], epubPath: row["epub_path"]))
            }

            // Series bookmarks.
            for row in try Row.fetchAll(db, sql: """
                SELECT b.bookmark_id AS bid, b.bookmarked_at AS bat, b.bookmarker_notes AS bnotes,
                       b.is_rec AS brec, b.is_private AS bpriv, s.*
                FROM bookmark b JOIN series s ON b.item_kind = 'series' AND b.item_id = s.id
                """) {
                let sid: Int = row["id"]
                let bid: Int = row["bid"]
                items.append(WorkListItem(
                    itemID: sid, bookmarkID: bid, kind: .series,
                    sourcePath: "/series/\(sid)", title: row["title"], author: row["author"] ?? "",
                    authorURL: nil,
                    fandoms: [], relationships: [], characters: [], freeforms: [], warnings: [],
                    rating: nil, category: nil, isComplete: nil, language: nil,
                    wordCount: nil, worksCount: row["works_count"],
                    chaptersHave: nil, chaptersTotal: nil,
                    kudos: nil, comments: nil, bookmarksCount: nil, hits: nil,
                    summary: row["summary"], updatedAt: nil, dateText: row["date_text"],
                    bookmarkedAt: row["bat"], bookmarkTags: btagsByBookmark[bid] ?? [],
                    bookmarkerNotes: row["bnotes"],
                    isRec: (row["brec"] as Int? ?? 0) != 0, isPrivate: (row["bpriv"] as Int? ?? 0) != 0,
                    downloadState: "series", epubPath: nil))
            }

            return items
        }
    }
}

// MARK: - AO3 required-tags classification (the colour-coded corner symbols)

/// First square — content rating. Maps the blurb's rating text to AO3's scheme so the UI
/// can colour it (G green / T yellow / M orange / E red / none grey).
public enum RatingLevel: String, Sendable { case general, teen, mature, explicit, notRated }

/// Third square — content warnings. AO3 shows a single symbol: "applies" (red, at least one
/// of graphic violence / major death / rape-noncon / underage), "chose not to warn" (yellow),
/// "external" (globe), or none.
public enum WarningLevel: String, Sendable { case none, choseNotToWarn, applies, external }

extension WorkListItem {
    public var ratingLevel: RatingLevel {
        guard let r = rating?.lowercased() else { return .notRated }
        if r.contains("general")  { return .general }
        if r.contains("teen")     { return .teen }
        if r.contains("mature")   { return .mature }
        if r.contains("explicit") { return .explicit }
        return .notRated
    }

    public var warningLevel: WarningLevel {
        if kind == .external { return .external }
        let lower = warnings.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("chose not to") || $0.contains("choose not to") }) {
            return .choseNotToWarn
        }
        let serious = ["graphic depictions of violence", "major character death",
                       "rape/non-con", "underage"]
        if lower.contains(where: { w in serious.contains(where: { w.contains($0) }) }) {
            return .applies
        }
        return .none
    }
}

// MARK: - Filter / sort (pure, tested)

/// Completion facet. `.any` doesn't filter; series (isComplete == nil) pass `.any` only.
public enum CompletionFilter: String, Sendable, CaseIterable { case any, complete, wip }

/// A combinable set of gallery filters. Empty sets mean "no constraint on this dimension";
/// multiple values within a dimension are OR'd, and dimensions are AND'd together.
public struct GalleryFilter: Sendable, Equatable {
    public var bookmarkTypes: Set<BookmarkKind> = []
    public var fandoms: Set<String> = []
    public var ratings: Set<String> = []
    public var downloadStates: Set<String> = []
    public var completion: CompletionFilter = .any
    public var searchText: String = ""

    public init() {}

    public var isActive: Bool {
        !bookmarkTypes.isEmpty || !fandoms.isEmpty || !ratings.isEmpty
            || !downloadStates.isEmpty || completion != .any
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func matches(_ item: WorkListItem) -> Bool {
        if !bookmarkTypes.isEmpty, !bookmarkTypes.contains(item.kind) { return false }
        if !ratings.isEmpty, !(item.rating.map(ratings.contains) ?? false) { return false }
        if !downloadStates.isEmpty, !downloadStates.contains(item.downloadState) { return false }
        if !fandoms.isEmpty, fandoms.isDisjoint(with: item.fandoms) { return false }
        switch completion {
        case .any:      break
        case .complete: if item.isComplete != true { return false }
        case .wip:      if item.isComplete != false { return false }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, !item.searchHaystack.contains(q) { return false }
        return true
    }

    public func apply(to items: [WorkListItem]) -> [WorkListItem] {
        isActive ? items.filter(matches) : items
    }

    // Copies with one dimension cleared, for true faceted counts: a dimension's facet list
    // is computed against everything EXCEPT its own selection, so picking one value never
    // hides that dimension's other values (multi-select OR stays reachable).
    public func clearingBookmarkTypes() -> GalleryFilter { var c = self; c.bookmarkTypes = []; return c }
    public func clearingRatings() -> GalleryFilter { var c = self; c.ratings = []; return c }
    public func clearingFandoms() -> GalleryFilter { var c = self; c.fandoms = []; return c }
    public func clearingDownloadStates() -> GalleryFilter { var c = self; c.downloadStates = []; return c }
}

/// Sort options. "Date bookmarked" uses the monotonic bookmark id (reliable; the stored
/// bookmark date is human text), newest first.
public enum GallerySort: String, Sendable, CaseIterable {
    case dateBookmarked, dateUpdated, title, author, wordCount, kudos, hits

    public var label: String {
        switch self {
        case .dateBookmarked: return "Date bookmarked"
        case .dateUpdated:    return "Date updated"
        case .title:          return "Title"
        case .author:         return "Author"
        case .wordCount:      return "Word count"
        case .kudos:          return "Kudos"
        case .hits:           return "Hits"
        }
    }

    public func sorted(_ items: [WorkListItem]) -> [WorkListItem] {
        switch self {
        case .dateBookmarked: return items.sorted { ($0.bookmarkID ?? 0) > ($1.bookmarkID ?? 0) }
        case .dateUpdated:    return items.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        case .title:          return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:         return items.sorted { $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending }
        case .wordCount:      return items.sorted { ($0.wordCount ?? 0) > ($1.wordCount ?? 0) }
        case .kudos:          return items.sorted { ($0.kudos ?? 0) > ($1.kudos ?? 0) }
        case .hits:           return items.sorted { ($0.hits ?? 0) > ($1.hits ?? 0) }
        }
    }
}

/// Facet counts over a given set of items (the caller passes the currently-filtered set,
/// so counts reflect what's shown). Sorted by count desc, then name. Pure & tested.
public enum Facets {
    public static func counts(_ values: (WorkListItem) -> [String], in items: [WorkListItem]) -> [(name: String, count: Int)] {
        var tally: [String: Int] = [:]
        for item in items { for v in values(item) where !v.isEmpty { tally[v, default: 0] += 1 } }
        return tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    public static func fandoms(_ items: [WorkListItem]) -> [(name: String, count: Int)] {
        counts({ $0.fandoms }, in: items)
    }
    public static func ratings(_ items: [WorkListItem]) -> [(name: String, count: Int)] {
        counts({ $0.rating.map { [$0] } ?? [] }, in: items)
    }
    public static func bookmarkTypes(_ items: [WorkListItem]) -> [(name: String, count: Int)] {
        counts({ [$0.kind.rawValue] }, in: items)
    }
    public static func downloadStates(_ items: [WorkListItem]) -> [(name: String, count: Int)] {
        counts({ [$0.downloadState] }, in: items)
    }
}

// MARK: - View model (@Observable, thin wrapper over the tested engine)

/// Holds the loaded working set in memory and derives the visible list by pure compute, so
/// filter/sort/typeahead never touch disk on the hot path. SwiftUI observes the stored
/// `filter`/`sort`/`allItems`; `visibleItems` recomputes when they change.
@Observable
public final class GalleryViewModel {
    public var allItems: [WorkListItem] = []
    public var filter = GalleryFilter()
    public var sort: GallerySort = .dateBookmarked
    public var loadError: String?

    public init() {}

    /// Load (or reload) the working set from the store on disk.
    public func load(from store: Store) {
        do { allItems = try store.fetchAllListItems(); loadError = nil }
        catch { loadError = String(describing: error) }
    }

    /// The currently-visible, filtered + sorted items.
    public var visibleItems: [WorkListItem] { sort.sorted(filter.apply(to: allItems)) }

    /// Facet rows for the sidebar. Each dimension is counted against the set filtered by all
    /// OTHER dimensions, so selecting a value keeps that dimension's other values visible.
    public var fandomFacets: [(name: String, count: Int)] {
        Facets.fandoms(filter.clearingFandoms().apply(to: allItems))
    }
    public var ratingFacets: [(name: String, count: Int)] {
        Facets.ratings(filter.clearingRatings().apply(to: allItems))
    }
    public var typeFacets: [(name: String, count: Int)] {
        Facets.bookmarkTypes(filter.clearingBookmarkTypes().apply(to: allItems))
    }
    public var downloadFacets: [(name: String, count: Int)] {
        Facets.downloadStates(filter.clearingDownloadStates().apply(to: allItems))
    }

    public var totalCount: Int { allItems.count }
    public var visibleCount: Int { visibleItems.count }

    // Toggle helpers the sidebar binds to.
    public func toggleType(_ k: BookmarkKind) { toggle(&filter.bookmarkTypes, k) }
    public func toggleFandom(_ f: String) { toggle(&filter.fandoms, f) }
    public func toggleRating(_ r: String) { toggle(&filter.ratings, r) }
    public func toggleDownloadState(_ s: String) { toggle(&filter.downloadStates, s) }
    public func clearFilters() { filter = GalleryFilter() }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ v: T) {
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
    }
}

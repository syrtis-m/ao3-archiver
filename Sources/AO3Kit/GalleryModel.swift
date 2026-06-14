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
    public var bookmarkedDate: Date?  // parsed from bookmarkedAt at load (range filters / nil-safe)
    public var bookmarkTags: [String]
    public var bookmarkerNotes: String?
    public var isRec: Bool
    public var isPrivate: Bool

    /// work: pending|downloaded|failed|unavailable. series → "series" (no own file).
    public var downloadState: String
    public var epubPath: String?

    // ── Precomputed once at construction (perf: M6/P1) ──────────────────────────────
    /// Concatenated, lowercased text the search box matches against. Built ONCE in `init`
    /// (not per access) — at 20k items, rebuilding+lowercasing ~10 arrays per keystroke per
    /// item was the dominant search cost.
    public let searchHaystack: String
    /// Lowercased title/author, so title/author sorts compare with a plain `<` instead of a
    /// per-comparison `localizedCaseInsensitiveCompare` (O(n log n) of locale bridging).
    public let titleSortKey: String
    public let authorSortKey: String

    /// Public initializer with defaults for the long tail of fields, so the app and tests
    /// can construct items without spelling out all ~33 parameters.
    public init(
        itemID: Int, bookmarkID: Int? = nil, kind: BookmarkKind, sourcePath: String,
        title: String, author: String, authorURL: String? = nil,
        fandoms: [String] = [], relationships: [String] = [], characters: [String] = [],
        freeforms: [String] = [], warnings: [String] = [],
        rating: String? = nil, category: String? = nil, isComplete: Bool? = nil,
        language: String? = nil, wordCount: Int? = nil, worksCount: Int? = nil,
        chaptersHave: Int? = nil, chaptersTotal: Int? = nil, kudos: Int? = nil,
        comments: Int? = nil, bookmarksCount: Int? = nil, hits: Int? = nil,
        summary: String? = nil, updatedAt: Int? = nil, dateText: String? = nil,
        bookmarkedAt: String? = nil, bookmarkedDate: Date? = nil,
        bookmarkTags: [String] = [], bookmarkerNotes: String? = nil,
        isRec: Bool = false, isPrivate: Bool = false,
        downloadState: String = "pending", epubPath: String? = nil
    ) {
        self.itemID = itemID; self.bookmarkID = bookmarkID; self.kind = kind
        self.sourcePath = sourcePath; self.title = title; self.author = author
        self.authorURL = authorURL; self.fandoms = fandoms; self.relationships = relationships
        self.characters = characters; self.freeforms = freeforms; self.warnings = warnings
        self.rating = rating; self.category = category; self.isComplete = isComplete
        self.language = language; self.wordCount = wordCount; self.worksCount = worksCount
        self.chaptersHave = chaptersHave; self.chaptersTotal = chaptersTotal; self.kudos = kudos
        self.comments = comments; self.bookmarksCount = bookmarksCount; self.hits = hits
        self.summary = summary; self.updatedAt = updatedAt; self.dateText = dateText
        self.bookmarkedAt = bookmarkedAt; self.bookmarkedDate = bookmarkedDate
        self.bookmarkTags = bookmarkTags
        self.bookmarkerNotes = bookmarkerNotes; self.isRec = isRec; self.isPrivate = isPrivate
        self.downloadState = downloadState; self.epubPath = epubPath
        // Derived, computed once (see field docs).
        self.searchHaystack = ([title, author, summary ?? "", bookmarkerNotes ?? ""]
            + fandoms + relationships + characters + freeforms + bookmarkTags)
            .joined(separator: " ").lowercased()
        self.titleSortKey = title.lowercased()
        self.authorSortKey = author.lowercased()
    }

    /// Stable, list-unique id (bookmark ids are unique; fall back for safety).
    public var id: String { bookmarkID.map(String.init) ?? "\(kind.rawValue)-\(itemID)" }

    /// Full AO3 URL for "view on AO3".
    public var ao3URL: URL? { URL(string: "https://archiveofourown.org" + sourcePath) }

    /// A crossover = bookmarked across more than one fandom.
    public var isCrossover: Bool { fandoms.count > 1 }

    /// Shared formatter for AO3's "04 Apr 2014" bookmark dates — built once, not per row
    /// (a `DateFormatter` per item over thousands of rows is a real stall). POSIX + UTC so
    /// parsing is locale-stable; `nil` on an odd date (fail-soft, drops out of date ranges).
    private static let bookmarkDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd MMM yyyy"
        return f
    }()
    public static func parseBookmarkDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return bookmarkDateFormatter.date(from: text)
    }
}

// MARK: - Faceted dimensions (the generic keyed filter mechanism)

/// Every multi-value filter dimension, keyed once. The filter, the facet counts, the view
/// model, and the sidebar all drive off this single enum instead of a hand-written property
/// per dimension — so adding a dimension is one `case` + one line in `values(for:)`.
public enum FacetDimension: String, Sendable, CaseIterable, Hashable, Codable {
    case bookmarkType, rating, category, language
    case fandom, warning, relationship, character, freeform, bookmarkTag

    public var title: String {
        switch self {
        case .bookmarkType: return "Bookmark type"
        case .rating:       return "Rating"
        case .category:     return "Category"
        case .language:     return "Language"
        case .fandom:       return "Fandom"
        case .warning:      return "Warnings"
        case .relationship: return "Relationships"
        case .character:    return "Characters"
        case .freeform:     return "Additional tags"
        case .bookmarkTag:  return "Your tags"
        }
    }

    /// High-cardinality dimensions (thousands of distinct values) get a typeahead field +
    /// a render cap in the sidebar; the rest are short enough to list in full.
    public var isHighCardinality: Bool {
        switch self {
        case .fandom, .relationship, .character, .freeform, .bookmarkTag: return true
        default: return false
        }
    }
}

/// A numeric/date filterable field. Counts are plain ints; dates are compared as unix
/// seconds (works' `updatedAt` is already unix; the bookmark date is parsed at load), so one
/// `Double?` extractor + one `min/max` bound covers them all.
public enum RangeField: String, Sendable, CaseIterable, Hashable, Codable {
    case wordCount, kudos, comments, bookmarks, hits, dateUpdated, dateBookmarked

    public var title: String {
        switch self {
        case .wordCount:      return "Word count"
        case .kudos:          return "Kudos"
        case .comments:       return "Comments"
        case .bookmarks:      return "Bookmarks"
        case .hits:           return "Hits"
        case .dateUpdated:    return "Date updated"
        case .dateBookmarked: return "Date bookmarked"
        }
    }

    public var isDate: Bool { self == .dateUpdated || self == .dateBookmarked }
}

/// Inclusive `[min, max]` bound; either end may be open. An item whose value is `nil` (e.g. a
/// series has no word count) fails an *active* bound — it drops out rather than sneaking in.
public struct NumericBound: Sendable, Equatable, Codable {
    public var min: Double?
    public var max: Double?
    public init(min: Double? = nil, max: Double? = nil) { self.min = min; self.max = max }

    public var isActive: Bool { min != nil || max != nil }

    public func contains(_ value: Double?) -> Bool {
        guard let value else { return false }
        if let min, value < min { return false }
        if let max, value > max { return false }
        return true
    }
}

extension WorkListItem {
    /// The item's comparable value for a range field (`nil` when it has none).
    public func value(for field: RangeField) -> Double? {
        switch field {
        case .wordCount:      return wordCount.map(Double.init)
        case .kudos:          return kudos.map(Double.init)
        case .comments:       return comments.map(Double.init)
        case .bookmarks:      return bookmarksCount.map(Double.init)
        case .hits:           return hits.map(Double.init)
        case .dateUpdated:    return updatedAt.map(Double.init)
        case .dateBookmarked: return bookmarkedDate?.timeIntervalSince1970
        }
    }

    /// The item's values along one dimension (the set a filter matches against, the multiset
    /// facet counts tally). Empty when the item has no value there.
    public func values(for dim: FacetDimension) -> [String] {
        switch dim {
        case .bookmarkType: return [kind.rawValue]
        case .rating:       return rating.map { [$0] } ?? []
        case .category:     return categories
        case .language:     return language.map { [$0] } ?? []
        case .fandom:       return fandoms
        case .warning:      return warnings
        case .relationship: return relationships
        case .character:    return characters
        case .freeform:     return freeforms
        case .bookmarkTag:  return bookmarkTags
        }
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
                    bookmarkedAt: row["bat"], bookmarkedDate: WorkListItem.parseBookmarkDate(row["bat"]),
                    bookmarkTags: btagsByBookmark[bid] ?? [],
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
                    bookmarkedAt: row["bat"], bookmarkedDate: WorkListItem.parseBookmarkDate(row["bat"]),
                    bookmarkTags: btagsByBookmark[bid] ?? [],
                    bookmarkerNotes: row["bnotes"],
                    isRec: (row["brec"] as Int? ?? 0) != 0, isPrivate: (row["bpriv"] as Int? ?? 0) != 0,
                    downloadState: "series", epubPath: nil))
            }

            return items
        }
    }
}

extension Store {
    /// Member works of a series, in series order (by `part`). Used by the detail view to
    /// list "the works in this series". Members aren't necessarily bookmarked, so these are
    /// built straight from the `work` rows (no bookmark fields, no tags).
    public func fetchSeriesMembers(seriesID: Int) throws -> [WorkListItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.* FROM series_work sw JOIN work w ON w.id = sw.work_id
                WHERE sw.series_id = ? ORDER BY sw.part
                """, arguments: [seriesID])
            return rows.map { row in
                let complete: Int? = row["is_complete"]
                return WorkListItem(
                    itemID: row["id"], bookmarkID: nil,
                    kind: BookmarkKind(rawValue: row["kind"]) ?? .work,
                    sourcePath: row["source_path"], title: row["title"], author: row["author"],
                    authorURL: row["author_url"],
                    fandoms: [], relationships: [], characters: [], freeforms: [], warnings: [],
                    rating: row["rating"], category: row["category"],
                    isComplete: complete.map { $0 != 0 }, language: row["language"],
                    wordCount: row["word_count"], worksCount: nil,
                    chaptersHave: row["chapters_have"], chaptersTotal: row["chapters_total"],
                    kudos: row["kudos"], comments: row["comments"],
                    bookmarksCount: row["bookmarks_count"], hits: row["hits"],
                    summary: row["summary"], updatedAt: row["updated_at"], dateText: row["date_text"],
                    bookmarkedAt: nil, bookmarkTags: [], bookmarkerNotes: nil,
                    isRec: false, isPrivate: false,
                    downloadState: row["download_state"], epubPath: row["epub_path"])
            }
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

    /// Second square — relationship categories. AO3 packs multiple into one comma-joined
    /// symbol ("F/M, M/M"); split it so each can be shown (and coloured) separately.
    /// "No category" / empty yields none (AO3's blank square).
    public var categories: [String] {
        guard let category, !category.isEmpty,
              category.caseInsensitiveCompare("No category") != .orderedSame else { return [] }
        return category.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
public enum CompletionFilter: String, Sendable, CaseIterable, Codable { case any, complete, wip }

/// A yes/no/either filter over a boolean property (crossover, rec'd, has-notes, private).
/// `.yes` keeps items where the property is true, `.no` where false, `.any` doesn't filter.
public enum TriFilter: String, Sendable, CaseIterable, Codable {
    case any, yes, no
    public func allows(_ value: Bool) -> Bool {
        switch self { case .any: return true; case .yes: return value; case .no: return !value }
    }
}

/// Download/archive state, single-select (like completion) — tri-state include/exclude over
/// these is more confusing than useful.
public enum DownloadFilter: String, Sendable, CaseIterable, Codable {
    case any, saved, notDownloaded, offsite

    public var label: String {
        switch self {
        case .any:           return "Any"
        case .saved:         return "Saved"
        case .notDownloaded: return "Not saved"
        case .offsite:       return "Off-site"
        }
    }

    public func matches(_ downloadState: String) -> Bool {
        switch self {
        case .any:           return true
        case .saved:         return downloadState == "downloaded"
        case .notDownloaded: return downloadState == "pending"
        case .offsite:       return downloadState == "unavailable"
        }
    }
}

/// A combinable set of gallery filters. Every multi-value dimension lives in one keyed pair
/// of maps: `include[dim]` (OR within a dim, AND across dims) and `exclude[dim]` (an item
/// matching any excluded value is dropped). **Invariant: a dim key never maps to an empty
/// set** — emptying a set removes the key (kept by `cycle`/the mutators), so `==` and
/// `isActive` stay honest. Exclude wins over include. `Codable` for saved presets.
public struct GalleryFilter: Sendable, Equatable, Codable {
    public var include: [FacetDimension: Set<String>] = [:]
    public var exclude: [FacetDimension: Set<String>] = [:]
    public var ranges: [RangeField: NumericBound] = [:]   // invariant: no inactive bound stored
    public var completion: CompletionFilter = .any
    public var download: DownloadFilter = .any
    // Derived / bookmark-specific booleans (yes = crossover / rec'd / has-notes / private).
    public var crossover: TriFilter = .any
    public var recd: TriFilter = .any
    public var hasNotes: TriFilter = .any
    public var isPrivate: TriFilter = .any
    public var searchText: String = ""

    public init() {}

    public func included(_ dim: FacetDimension) -> Set<String> { include[dim] ?? [] }
    public func excluded(_ dim: FacetDimension) -> Set<String> { exclude[dim] ?? [] }
    public func bound(_ field: RangeField) -> NumericBound { ranges[field] ?? NumericBound() }

    /// Set a range bound, dropping the key when inactive (mirrors the include/exclude invariant).
    public mutating func setBound(_ field: RangeField, _ bound: NumericBound) {
        ranges[field] = bound.isActive ? bound : nil
    }

    /// Set a dimension's include/exclude set, dropping the key when empty (the invariant).
    public mutating func setInclude(_ dim: FacetDimension, _ values: Set<String>) {
        include[dim] = values.isEmpty ? nil : values
    }
    public mutating func setExclude(_ dim: FacetDimension, _ values: Set<String>) {
        exclude[dim] = values.isEmpty ? nil : values
    }

    public var isActive: Bool {
        include.values.contains { !$0.isEmpty } || exclude.values.contains { !$0.isEmpty }
            || ranges.values.contains { $0.isActive }
            || completion != .any || download != .any
            || crossover != .any || recd != .any || hasNotes != .any || isPrivate != .any
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func matches(_ item: WorkListItem) -> Bool {
        // Keyed include/exclude over every dimension. Include: item must carry ANY included
        // value. Exclude: item must carry NONE. (`where !$0.isEmpty` keeps a stray empty set
        // harmless even though the invariant should prevent one.)
        for (dim, inc) in include where !inc.isEmpty {
            if Set(item.values(for: dim)).isDisjoint(with: inc) { return false }
        }
        for (dim, exc) in exclude where !exc.isEmpty {
            if !Set(item.values(for: dim)).isDisjoint(with: exc) { return false }
        }
        // Numeric / date ranges.
        for (field, bound) in ranges where bound.isActive {
            if !bound.contains(item.value(for: field)) { return false }
        }
        // Download / archive state (single-select).
        if !download.matches(item.downloadState) { return false }
        // Derived / bookmark booleans.
        if !crossover.allows(item.isCrossover) { return false }
        if !recd.allows(item.isRec) { return false }
        if !hasNotes.allows(!(item.bookmarkerNotes ?? "").trimmingCharacters(in: .whitespaces).isEmpty) { return false }
        if !isPrivate.allows(item.isPrivate) { return false }
        // Completion.
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

    /// Copy with one dimension's include+exclude cleared, for true faceted counts: a
    /// dimension's facet list is computed against everything EXCEPT its own selection, so
    /// picking/excluding one value never hides that dimension's other values.
    public func clearing(_ dim: FacetDimension) -> GalleryFilter {
        var c = self; c.include[dim] = nil; c.exclude[dim] = nil; return c
    }
}

/// A saved filter + sort ("Smart Bookmark"), persisted by `Store`. Codable so the whole
/// `GalleryFilter` round-trips to JSON in one shot.
public struct FilterPreset: Sendable, Equatable, Codable, Identifiable {
    public var name: String
    public var filter: GalleryFilter
    public var sort: GallerySort
    public var id: String { name }
    public init(name: String, filter: GalleryFilter, sort: GallerySort) {
        self.name = name; self.filter = filter; self.sort = sort
    }
}

/// Sort options. "Date bookmarked" uses the monotonic bookmark id (reliable; the stored
/// bookmark date is human text), newest first.
public enum GallerySort: String, Sendable, CaseIterable, Codable {
    case dateBookmarked, dateUpdated, title, author, wordCount, kudos, comments, bookmarks, hits

    public var label: String {
        switch self {
        case .dateBookmarked: return "Date bookmarked"
        case .dateUpdated:    return "Date updated"
        case .title:          return "Title"
        case .author:         return "Author"
        case .wordCount:      return "Word count"
        case .kudos:          return "Kudos"
        case .comments:       return "Comments"
        case .bookmarks:      return "Bookmarks"
        case .hits:           return "Hits"
        }
    }

    public func sorted(_ items: [WorkListItem]) -> [WorkListItem] {
        switch self {
        case .dateBookmarked: return items.sorted { ($0.bookmarkID ?? 0) > ($1.bookmarkID ?? 0) }
        case .dateUpdated:    return items.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        case .title:          return items.sorted { $0.titleSortKey < $1.titleSortKey }
        case .author:         return items.sorted { $0.authorSortKey < $1.authorSortKey }
        case .wordCount:      return items.sorted { ($0.wordCount ?? 0) > ($1.wordCount ?? 0) }
        case .kudos:          return items.sorted { ($0.kudos ?? 0) > ($1.kudos ?? 0) }
        case .comments:       return items.sorted { ($0.comments ?? 0) > ($1.comments ?? 0) }
        case .bookmarks:      return items.sorted { ($0.bookmarksCount ?? 0) > ($1.bookmarksCount ?? 0) }
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

    /// Facet rows for any dimension — the one entry point now that every dimension is keyed.
    public static func values(for dim: FacetDimension, in items: [WorkListItem]) -> [(name: String, count: Int)] {
        counts({ $0.values(for: dim) }, in: items)
    }
}

// MARK: - View model (@Observable, thin wrapper over the tested engine)

/// Holds the loaded working set in memory and derives the visible list by pure compute, so
/// filter/sort/typeahead never touch disk on the hot path. SwiftUI observes the stored
/// `filter`/`sort`/`allItems`; `visibleItems` recomputes when they change.
@Observable
public final class GalleryViewModel {
    public var allItems: [WorkListItem] = [] { didSet { loadGeneration &+= 1 } }
    public var filter = GalleryFilter()
    public var sort: GallerySort = .dateBookmarked
    public var loadError: String?
    /// Bumped whenever `allItems` changes; part of the memo key (cheaper than diffing arrays).
    public private(set) var loadGeneration = 0

    public init() {}

    /// Saved filter presets ("Smart Bookmarks"), loaded from the store.
    public private(set) var presets: [FilterPreset] = []

    /// Load (or reload) the working set + presets from the store on disk.
    public func load(from store: Store) {
        do { allItems = try store.fetchAllListItems(); loadError = nil }
        catch { loadError = String(describing: error) }
        loadPresets(from: store)
    }

    public func loadPresets(from store: Store) { presets = (try? store.loadPresets()) ?? [] }

    /// Save the current filter + sort under `name` (overwrites an existing one).
    public func savePreset(named name: String, to store: Store) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? store.savePreset(FilterPreset(name: trimmed, filter: filter, sort: sort))
        loadPresets(from: store)
    }

    public func applyPreset(_ preset: FilterPreset) { filter = preset.filter; sort = preset.sort }

    public func deletePreset(_ preset: FilterPreset, from store: Store) {
        try? store.deletePreset(name: preset.name)
        loadPresets(from: store)
    }

    // MARK: - Memoized derived working set

    /// The visible list + all facet counts, computed together and cached per (filter, sort,
    /// items) change — NOT per render/access. Without this, every render recomputes ~5 full
    /// `O(n)` filter+count passes; at ~1800 bookmarks and many facets, repeated renders
    /// (typing, resizing) would stutter. `recomputeCount` lets tests prove the memo holds.
    private struct Derived {
        var visible: [WorkListItem] = []
        var facets: [FacetDimension: [(name: String, count: Int)]] = [:]
    }
    private struct MemoKey: Equatable { var filter: GalleryFilter; var sort: GallerySort; var gen: Int }

    @ObservationIgnored private var cached: Derived?
    @ObservationIgnored private var cachedKey: MemoKey?
    @ObservationIgnored public private(set) var recomputeCount = 0

    private var derived: Derived {
        // Read the observed inputs up front so SwiftUI still registers dependencies on a
        // cache hit (else views wouldn't re-render when the filter changes).
        let key = MemoKey(filter: filter, sort: sort, gen: loadGeneration)
        if let cached, cachedKey == key { return cached }
        var d = Derived()
        d.visible = sort.sorted(filter.apply(to: allItems))
        // Each dimension counted against the set filtered by all OTHER dims (faceted search).
        for dim in FacetDimension.allCases {
            d.facets[dim] = Facets.values(for: dim, in: filter.clearing(dim).apply(to: allItems))
        }
        cached = d; cachedKey = key; recomputeCount += 1
        return d
    }

    /// The currently-visible, filtered + sorted items.
    public var visibleItems: [WorkListItem] { derived.visible }

    /// Facet rows for one dimension. Counted against the set filtered by all OTHER
    /// dimensions, so selecting a value keeps that dimension's other values visible.
    public func facets(for dim: FacetDimension) -> [(name: String, count: Int)] {
        derived.facets[dim] ?? []
    }

    public var totalCount: Int { allItems.count }
    public var visibleCount: Int { derived.visible.count }

    public func clearFilters() { filter = GalleryFilter() }

    /// Range-bound accessors for the sidebar's min/max fields and date pickers.
    public func bound(_ field: RangeField) -> NumericBound { filter.bound(field) }
    public func setBound(_ field: RangeField, _ bound: NumericBound) {
        var f = filter; f.setBound(field, bound); filter = f
    }

    /// Include-only toggle (simple uses / tests): neutral → include → neutral.
    public func toggle(_ dim: FacetDimension, _ value: String) {
        var inc = filter.included(dim)
        if inc.contains(value) { inc.remove(value) } else { inc.insert(value) }
        filter.setInclude(dim, inc)
    }

    public func state(_ dim: FacetDimension, _ value: String) -> FacetState {
        filter.included(dim).contains(value) ? .include
            : (filter.excluded(dim).contains(value) ? .exclude : .neutral)
    }

    /// Tri-state cycle: neutral → include (green ✓) → exclude (red ⊘) → neutral. Mutates a
    /// local copy of `filter` (single write-back) and drops emptied sets to keep the
    /// no-empty-key invariant — so `isActive`/`==`/preset round-trips stay correct.
    public func cycle(_ dim: FacetDimension, _ value: String) {
        var f = filter
        var inc = f.included(dim), exc = f.excluded(dim)
        if inc.contains(value) { inc.remove(value); exc.insert(value) }
        else if exc.contains(value) { exc.remove(value) }
        else { inc.insert(value) }
        f.setInclude(dim, inc); f.setExclude(dim, exc)
        filter = f
    }
}

/// Tri-state of a facet value in the sidebar.
public enum FacetState: Sendable, Equatable { case neutral, include, exclude }

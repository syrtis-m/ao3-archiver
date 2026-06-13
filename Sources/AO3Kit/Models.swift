import Foundation

/// What a bookmark points at. Only `.work` has a downloadable AO3 EPUB; the others are
/// recorded as metadata so they're never lost and can be filtered to.
public enum BookmarkKind: String, Sendable, Codable {
    case work       // /works/<id> — an AO3-hosted work (downloadable)
    case external   // /external_works/<id> — a fanwork hosted off-site (no EPUB)
    case series     // /series/<id> — a series bookmark
}

/// One parsed card ("blurb") as it appears in an AO3 listing — works search, a tag's
/// works page, or a user's bookmarks page. The same markup is reused across all of them,
/// so one parser covers every list source.
///
/// Most fields describe AO3 works; external/series bookmarks populate what AO3 renders
/// for them (title, author, fandoms, rating) and leave work-only stats nil. Fields that
/// only exist on a *bookmarks* page (the bookmarker's own tags/notes) are best-effort and
/// empty elsewhere.
public struct WorkBlurb: Sendable, Codable, Equatable {
    public var kind: BookmarkKind
    /// The card's identity path, e.g. "/works/123", "/external_works/456", "/series/789".
    public var sourcePath: String
    /// Numeric id within its namespace (AO3 work id for `.work`; external_works/series id
    /// otherwise).
    public var workID: Int
    public var title: String
    public var author: String
    public var authorURL: String?

    public var fandoms: [String]
    /// Rating symbol title, e.g. "Explicit", "Teen And Up Audiences". (Blurbs expose
    /// rating only as the single required-tags symbol.)
    public var rating: String?
    public var warnings: [String]
    /// Category symbol title, e.g. "M/M", "Gen", or "Multi" when more than one applies.
    /// The individual category list is only available on the full work page.
    public var category: String?
    /// nil when AO3 doesn't render the WIP symbol; true = "Complete Work".
    public var isComplete: Bool?

    public var relationships: [String]
    public var characters: [String]
    public var freeforms: [String]
    public var summary: String?

    public var language: String?
    public var wordCount: Int?
    public var chaptersHave: Int?
    /// nil represents AO3's "?" — a WIP with unknown final chapter count.
    public var chaptersTotal: Int?
    public var comments: Int?
    public var kudos: Int?
    public var bookmarksCount: Int?
    public var hits: Int?

    /// Human date string shown on the card, e.g. "13 Jun 2026".
    public var dateText: String?
    /// Unix timestamp from the `<!-- updated_at=… -->` comment. Doubles as the EPUB
    /// download cache key (the download URL carries the same value).
    public var updatedAt: Int?

    // Bookmarks-page only (best-effort; empty on non-bookmark listings).
    public var bookmarkTags: [String]
    public var bookmarkerNotes: String?

    public init(
        kind: BookmarkKind = .work,
        sourcePath: String = "",
        workID: Int,
        title: String,
        author: String,
        authorURL: String? = nil,
        fandoms: [String] = [],
        rating: String? = nil,
        warnings: [String] = [],
        category: String? = nil,
        isComplete: Bool? = nil,
        relationships: [String] = [],
        characters: [String] = [],
        freeforms: [String] = [],
        summary: String? = nil,
        language: String? = nil,
        wordCount: Int? = nil,
        chaptersHave: Int? = nil,
        chaptersTotal: Int? = nil,
        comments: Int? = nil,
        kudos: Int? = nil,
        bookmarksCount: Int? = nil,
        hits: Int? = nil,
        dateText: String? = nil,
        updatedAt: Int? = nil,
        bookmarkTags: [String] = [],
        bookmarkerNotes: String? = nil
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.workID = workID
        self.title = title
        self.author = author
        self.authorURL = authorURL
        self.fandoms = fandoms
        self.rating = rating
        self.warnings = warnings
        self.category = category
        self.isComplete = isComplete
        self.relationships = relationships
        self.characters = characters
        self.freeforms = freeforms
        self.summary = summary
        self.language = language
        self.wordCount = wordCount
        self.chaptersHave = chaptersHave
        self.chaptersTotal = chaptersTotal
        self.comments = comments
        self.kudos = kudos
        self.bookmarksCount = bookmarksCount
        self.hits = hits
        self.dateText = dateText
        self.updatedAt = updatedAt
        self.bookmarkTags = bookmarkTags
        self.bookmarkerNotes = bookmarkerNotes
    }
}

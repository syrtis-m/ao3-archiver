import Foundation
import SwiftSoup

/// Parses AO3 listing HTML into `WorkBlurb`s. Selectors were derived from real fetched
/// markup (see Tests/.../Fixtures/works_listing.html), not from another library.
///
/// The same blurb structure appears on works-search pages, tag pages, and bookmark
/// pages, so this one parser serves every list source the app uses.
public enum BlurbParser {

    /// Parse every work card on a listing page, in document order.
    public static func parseListing(html: String) throws -> [WorkBlurb] {
        let doc = try SwiftSoup.parse(html)
        // Works listings use `li.work.blurb.group`; bookmark listings use
        // `li.bookmark.blurb.group`. Match either, top of the card.
        let cards = try doc.select("li.work.blurb.group, li.bookmark.blurb.group")
        var out: [WorkBlurb] = []
        out.reserveCapacity(cards.size())
        for card in cards.array() {
            if let blurb = try parseCard(card) {
                out.append(blurb)
            }
        }
        return out
    }

    /// Parse a single card element. Returns nil only if the heading has no recognizable
    /// link at all, so one malformed card never aborts a page. Work, external-work, and
    /// series bookmarks are all captured (distinguished by `kind`); only `.work` is
    /// downloadable.
    static func parseCard(_ el: Element) throws -> WorkBlurb? {
        guard let titleLink = try el.select("h4.heading a[href]").first() else {
            return nil
        }
        let href = try titleLink.attr("href")
        guard let (kind, itemID) = classify(href: href) else {
            return nil
        }

        let title = try titleLink.text()

        // Authors: AO3 works use rel="author" links (multiple for co-authors). External
        // works and anonymous works render the author as plain text after the title.
        let authorLinks = try el.select("a[rel=author]").array()
        let author: String
        let authorURL: String?
        if authorLinks.isEmpty {
            author = authorFromHeaderText(try el.select("h4.heading").first()?.text(), title: title)
            authorURL = nil
        } else {
            author = try authorLinks.map { try $0.text() }.joined(separator: ", ")
            authorURL = try authorLinks.first?.attr("href")
        }
        let workID = itemID

        let fandoms = try texts(in: el, "h5.fandoms a.tag")

        // Required-tags symbols.
        let rating = try el.select("ul.required-tags span.rating").first()?.attr("title")
        let category = try el.select("ul.required-tags span.category").first()?.attr("title")
        let isComplete: Bool? = try {
            guard let wip = try el.select("ul.required-tags span.iswip").first() else { return nil }
            return try wip.className().contains("complete-yes")
        }()

        // Tag lists (authoritative warnings live here, not in the single symbol).
        let warnings = try texts(in: el, "ul.tags li.warnings a.tag")
        let relationships = try texts(in: el, "ul.tags li.relationships a.tag")
        let characters = try texts(in: el, "ul.tags li.characters a.tag")
        let freeforms = try texts(in: el, "ul.tags li.freeforms a.tag")

        let summary = try el.select("blockquote.summary").first()?.text()

        // Stats.
        let language = try el.select("dl.stats dd.language").first()?.text()
        let wordCount = try intText(in: el, "dl.stats dd.words")
        let (have, total) = try chapters(in: el)
        let comments = try intText(in: el, "dl.stats dd.comments")
        let kudos = try intText(in: el, "dl.stats dd.kudos")
        let bookmarksCount = try intText(in: el, "dl.stats dd.bookmarks")
        let hits = try intText(in: el, "dl.stats dd.hits")
        // Series cards carry a "Works:" stat instead of (or alongside) chapters.
        let worksCount = try intText(in: el, "dl.stats dd.works")

        // The work's own date is the FIRST p.datetime (in the work blurb). On a bookmarks
        // page a second p.datetime — the bookmark date — lives in the bookmarker section
        // below; it's captured as `bookmarkedAt`, not here.
        let dateText = try el.select("p.datetime").first()?.text()
        let updatedAt = updatedAtTimestamp(inOuterHTML: try el.outerHtml())

        // Bookmark-specific bits (present only on bookmark cards; nil/empty otherwise).
        // The card id is "bookmark_<id>" on bookmark pages, "work_<id>" elsewhere.
        let bookmarkID: Int? = {
            let id = (try? el.attr("id")) ?? ""
            guard id.hasPrefix("bookmark_") else { return nil }
            return Int(id.dropFirst("bookmark_".count))
        }()
        // The bookmarker's own tags, notes, and bookmark date are scoped to their section
        // (div.user.module.group) so work tags/dates can't leak in.
        let userModule = try el.select("div.user.module.group").first()
        let bookmarkedAt = try userModule?.select("p.datetime").first()?.text()
        let bookmarkTags = try userModule.map { try texts(in: $0, "ul.meta a.tag") } ?? []
        let bookmarkerNotes = try userModule?.select("blockquote").first()?.text()
        // Status symbols: private vs public, and the "rec" flag.
        let isPrivate = try el.select("p.status span.private").first() != nil
        let isRec = try el.select("p.status span.rec").first() != nil

        return WorkBlurb(
            kind: kind,
            sourcePath: href,
            workID: workID,
            title: title,
            author: author,
            authorURL: authorURL,
            fandoms: fandoms,
            rating: rating,
            warnings: warnings,
            category: category,
            isComplete: isComplete,
            relationships: relationships,
            characters: characters,
            freeforms: freeforms,
            summary: summary,
            language: language,
            wordCount: wordCount,
            chaptersHave: have,
            chaptersTotal: total,
            comments: comments,
            kudos: kudos,
            bookmarksCount: bookmarksCount,
            hits: hits,
            worksCount: worksCount,
            dateText: dateText,
            updatedAt: updatedAt,
            bookmarkTags: bookmarkTags,
            bookmarkerNotes: bookmarkerNotes,
            bookmarkID: bookmarkID,
            bookmarkedAt: bookmarkedAt,
            isRec: isRec,
            isPrivate: isPrivate
        )
    }

    /// Site-relative path of the next listing page, from the pagination control
    /// (`li.next a[href]`), or nil on the last page. Drives full bookmark pagination.
    public static func nextPagePath(html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        guard let a = try doc.select("ol.pagination li.next a[href]").first() else { return nil }
        let href = try a.attr("href")
        return href.isEmpty ? nil : href
    }

    // MARK: - Helpers

    /// Classify a heading href into a bookmark kind + numeric id within its namespace.
    static func classify(href: String) -> (BookmarkKind, Int)? {
        for (prefix, kind) in [("/works/", BookmarkKind.work),
                               ("/external_works/", .external),
                               ("/series/", .series)] {
            if let range = href.range(of: "\(prefix)(\\d+)", options: .regularExpression) {
                if let id = Int(href[range].dropFirst(prefix.count)) { return (kind, id) }
            }
        }
        return nil
    }

    /// For cards without a rel="author" link, pull the author from the heading text,
    /// which reads "Title by SomeAuthor". Falls back to "Anonymous".
    static func authorFromHeaderText(_ headerText: String?, title: String) -> String {
        guard let headerText else { return "Anonymous" }
        var rest = headerText
        if rest.hasPrefix(title) { rest = String(rest.dropFirst(title.count)) }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("by ") { rest = String(rest.dropFirst(3)) }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "Anonymous" : rest
    }

    private static func texts(in el: Element, _ selector: String) throws -> [String] {
        try el.select(selector).array().map { try $0.text() }
    }

    private static func intText(in el: Element, _ selector: String) throws -> Int? {
        guard let raw = try el.select(selector).first()?.text() else { return nil }
        return parseInt(raw)
    }

    /// "1,234" → 1234; keeps only digits.
    static func parseInt(_ s: String) -> Int? {
        let digits = s.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// dd.chapters text is like "4/?" or "12/12".
    private static func chapters(in el: Element) throws -> (Int?, Int?) {
        guard let raw = try el.select("dl.stats dd.chapters").first()?.text() else { return (nil, nil) }
        let parts = raw.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let have = parts.first.flatMap { parseInt($0) }
        let total = parts.count > 1 ? parseInt(parts[1]) : nil   // "?" yields nil
        return (have, total)
    }

    /// From "/works/85487886" or "/works/85487886/chapters/229369871".
    /// (Kept for the test suite; `classify` is the primary path now.)
    static func workID(fromWorkHref href: String) -> Int? {
        guard let range = href.range(of: #"/works/(\d+)"#, options: .regularExpression) else { return nil }
        return Int(href[range].dropFirst("/works/".count))
    }

    /// AO3 embeds `<!-- updated_at=1781388945 -->` inside each card's header.
    static func updatedAtTimestamp(inOuterHTML html: String) -> Int? {
        guard let range = html.range(of: #"updated_at=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(html[range].dropFirst("updated_at=".count))
    }
}

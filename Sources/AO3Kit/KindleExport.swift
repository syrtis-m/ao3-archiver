import Foundation
import ZIPFoundation

/// Prepares a work's EPUB for a one-button hand-off to Amazon's "Send to Kindle" Mac app:
///
///  1. Prepends a generated **info page** as the first spine item (and marks it the start-reading
///     location), so opening the book on the Kindle lands you on a clean summary of the work —
///     fandom, ship, rating/warnings, and stats — before the story.
///  2. Optionally folds a compact `(Fandom, 10k words)` **badge** into the `<dc:title>` so the
///     library *list* view carries the same at-a-glance detail before you even open it.
///
/// The on-device title and start page come from the EPUB's OPF (which Amazon reads during
/// EPUB→KFX conversion), so both edits are surgical string splices of the OPF — never a full
/// SwiftSoup re-serialize, which would risk mangling the `xmlns:dc`/`xmlns:opf` namespaces.
/// The `mimetype` entry is left untouched (stays first + stored), so the archive stays valid.
public enum KindleExport {
    /// Amazon's "Send to Kindle" Mac app. Launch by bundle id, not name — `Amazon Kindle.app`
    /// is also installed and a name lookup is ambiguous.
    public static let sendToKindleBundleID = "com.amazon.SendToKindle"

    /// Everything the info page (and the title badge) needs about a work. Mirrors the
    /// `WorkListItem` fields the app already has in hand at send time.
    public struct WorkInfo: Sendable {
        public var title: String
        public var author: String
        public var fandoms: [String]
        public var relationships: [String]
        public var rating: String?
        public var warnings: [String]
        public var category: String?
        public var wordCount: Int?
        public var chaptersHave: Int?
        public var chaptersTotal: Int?
        public var isComplete: Bool?
        public var updated: String?
        public var kudos: Int?
        public var hits: Int?

        public init(title: String, author: String, fandoms: [String] = [],
                    relationships: [String] = [], rating: String? = nil, warnings: [String] = [],
                    category: String? = nil, wordCount: Int? = nil, chaptersHave: Int? = nil,
                    chaptersTotal: Int? = nil, isComplete: Bool? = nil, updated: String? = nil,
                    kudos: Int? = nil, hits: Int? = nil) {
            self.title = title; self.author = author; self.fandoms = fandoms
            self.relationships = relationships; self.rating = rating; self.warnings = warnings
            self.category = category; self.wordCount = wordCount; self.chaptersHave = chaptersHave
            self.chaptersTotal = chaptersTotal; self.isComplete = isComplete; self.updated = updated
            self.kudos = kudos; self.hits = hits
        }
    }

    // MARK: - Title badge (pure)

    /// Compact word-count badge in k/M: `<1k`, `10k`, `1.5M`. nil for nil/0 (caller omits it).
    public static func abbreviateWords(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        if count >= 1_000_000 {
            let m = (Double(count) / 1_000_000).rounded(toPlaces: 1)
            return "\(trimZero(m))M words"
        }
        if count >= 1_000 {
            return "\(Int((Double(count) / 1_000).rounded()))k words"
        }
        return "<1k words"
    }

    /// The parenthesised metadata suffix, e.g. `(Harry Potter/Cyberpunk, 10k words)`. nil when
    /// there's nothing useful to add. Bounded so a many-fandom crossover or a giant fandom name
    /// can't blow up the title and overflow the Kindle list cell: at most `maxFandoms` fandoms
    /// (a trailing `+` marks the rest) and the joined fandom segment is truncated to `maxFandomChars`.
    public static func titleSuffix(fandoms: [String], wordCount: Int?,
                                   maxFandoms: Int = 2, maxFandomChars: Int = 40) -> String? {
        let cleaned = fandoms.map(shortFandom).filter { !$0.isEmpty }
        var fandomSeg = cleaned.prefix(maxFandoms).joined(separator: "/")
        if cleaned.count > maxFandoms { fandomSeg += "+" }
        if fandomSeg.count > maxFandomChars {
            fandomSeg = String(fandomSeg.prefix(maxFandomChars - 1)) + "…"
        }

        var parts: [String] = []
        if !fandomSeg.isEmpty { parts.append(fandomSeg) }
        if let words = abbreviateWords(wordCount) { parts.append(words) }
        guard !parts.isEmpty else { return nil }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    /// The full Kindle-facing title: the work title with the metadata suffix appended. Returns
    /// the unchanged title when there's nothing useful to add.
    public static func kindleTitle(_ title: String, fandoms: [String], wordCount: Int?) -> String {
        guard let suffix = titleSuffix(fandoms: fandoms, wordCount: wordCount) else { return title }
        return "\(title) \(suffix)"
    }

    /// AO3 fandom names often carry a disambiguating `" - Author"`/`" - All Media Types"` tail
    /// ("Harry Potter - J. K. Rowling"); the head is the recognisable name. Drop the tail.
    static func shortFandom(_ fandom: String) -> String {
        let head = fandom.components(separatedBy: " - ").first ?? fandom
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Info page (pure)

    /// The internal name of the prepended info-page document (lives next to the OPF).
    public static let infoPageFilename = "kindle-info.xhtml"
    static let infoPageManifestID = "kindle-info-page"
    /// The generated cover image (lives next to the OPF).
    static let coverFilename = "kindle-cover.jpg"
    static let coverManifestID = "kindle-cover-img"

    /// A self-contained, reflowable XHTML info page. Reflowable + relative (`em`) sizing so it
    /// inherits the reader's font/size and stays crisp on a Paperwhite; no tables/flexbox (KF8
    /// reflow mangles them) — just stacked label/value blocks and a couple of centered stat lines.
    public static func infoPageXHTML(for w: WorkInfo) -> String {
        func field(_ label: String, _ value: String?) -> String {
            guard let value, !value.isEmpty else { return "" }
            return "<div class=\"field\"><p class=\"label\">\(xmlEscape(label))</p>"
                + "<p class=\"value\">\(xmlEscape(value))</p></div>\n"
        }

        var stats: [String] = []
        if let wc = w.wordCount, wc > 0 { stats.append("\(grouped(wc)) words") }
        if let ch = chapterText(have: w.chaptersHave, total: w.chaptersTotal) { stats.append(ch) }
        if let c = w.isComplete { stats.append(c ? "Complete" : "Work in Progress") }

        var meta: [String] = []
        if let u = w.updated, !u.isEmpty { meta.append("Updated \(u)") }
        if let k = w.kudos, k > 0 { meta.append("\(grouped(k)) kudos") }
        if let h = w.hits, h > 0 { meta.append("\(grouped(h)) hits") }

        var body = ""
        body += field("Fandom", list(w.fandoms))
        body += field("Relationships", list(w.relationships))
        body += field("Rating", w.rating)
        body += field("Warnings", list(w.warnings))
        body += field("Category", w.category)

        var tail = ""
        if !stats.isEmpty { tail += "<p class=\"stats\">\(xmlEscape(stats.joined(separator: " · ")))</p>\n" }
        if !meta.isEmpty { tail += "<p class=\"meta\">\(xmlEscape(meta.joined(separator: " · ")))</p>\n" }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscape(w.title))</title>
        <style type="text/css">
        body { margin: 1.4em 1.1em; line-height: 1.5; }
        .work-title { font-size: 1.7em; font-weight: bold; text-align: center; margin: 0 0 0.25em; line-height: 1.25; }
        .byline { font-size: 1.05em; font-style: italic; text-align: center; margin: 0 0 1.1em; }
        .rule { border: 0; border-top: 1px solid #999; margin: 1.1em 0; }
        .field { margin: 0 0 1em; }
        .label { font-size: 0.74em; letter-spacing: 0.09em; text-transform: uppercase; color: #444; margin: 0 0 0.18em; }
        .value { font-size: 1.06em; margin: 0; }
        .stats { font-size: 1.02em; text-align: center; margin: 0.3em 0 0; }
        .meta { font-size: 0.92em; text-align: center; color: #555; margin: 0.35em 0 0; }
        </style>
        </head>
        <body>
        <p class="work-title">\(xmlEscape(w.title))</p>
        <p class="byline">by \(xmlEscape(w.author))</p>
        <hr class="rule"/>
        \(body)<hr class="rule"/>
        \(tail)</body>
        </html>
        """
    }

    /// "5/5 chapters", "3/? chapters" (WIP, unknown total), "1 chapter", or nil when unknown.
    public static func chapterText(have: Int?, total: Int?) -> String? {
        guard let have, have > 0 else { return nil }
        if let total {
            let unit = total == 1 ? "chapter" : "chapters"
            return "\(have)/\(total) \(unit)"
        }
        return "\(have)/? chapters"  // AO3 "?" — WIP with unknown final count
    }

    private static func list(_ items: [String]) -> String? {
        let joined = items.filter { !$0.isEmpty }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    private static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    // MARK: - EPUB build

    public enum ExportError: Error {
        case copyFailed(String)
        case rewriteFailed(String)
    }

    /// Produce a temp `.epub` copy of `source` with the info page prepended (and, when
    /// `addTitleBadge`, the `(Fandom, Nk words)` suffix folded into `<dc:title>`), ready to hand
    /// to Send to Kindle. The file is named after the (possibly badged) title too — belt-and-
    /// suspenders, in case a device labels by filename. Returns the copy's URL.
    public static func makeKindleEPUB(source: URL, work: WorkInfo,
                                      addTitleBadge: Bool = true) throws -> URL {
        let newTitle = addTitleBadge
            ? kindleTitle(work.title, fandoms: work.fandoms, wordCount: work.wordCount)
            : work.title
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ao3-kindle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sweepStaleExports(in: dir)  // we can't delete post-send (the async hand-off reads the file), so sweep old ones
        let dest = dir.appendingPathComponent(ArchivePaths.sanitize(newTitle) + ".epub")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw ExportError.copyFailed(String(describing: error))
        }

        do {
            try augment(epub: dest, work: work, newTitle: addTitleBadge ? newTitle : nil)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw ExportError.rewriteFailed(String(describing: error))
        }
        return dest
    }

    /// Write the info page into `epub` and splice the OPF to register it as the first spine item
    /// + start-reading location; optionally rewrite `<dc:title>` to `newTitle`. Best-effort — a
    /// missing OPF or unparseable structure leaves the (already-valid) copy alone rather than
    /// throwing, so the book still reaches the device.
    static func augment(epub: URL, work: WorkInfo, newTitle: String?) throws {
        let archive = try Archive(url: epub, accessMode: .update)
        guard let containerData = entryData("META-INF/container.xml", in: archive),
              let opfPath = opfPath(fromContainer: containerData),
              archive[opfPath] != nil,
              let opfData = entryData(opfPath, in: archive),
              var opf = String(data: opfData, encoding: .utf8) else {
            return
        }
        let opfDir = directory(of: opfPath)
        let pageZipPath = opfDir.isEmpty ? infoPageFilename : opfDir + "/" + infoPageFilename

        // 1. Write the info page document.
        let pageData = Data(infoPageXHTML(for: work).utf8)
        try addOrReplaceEntry(pageZipPath, data: pageData, in: archive)

        // 2. Add it to the TOC (NCX / EPUB3 nav) as the first entry. Kindle's converter often
        //    auto-skips spine front matter to "chapter 1"; being a real TOC entry makes it treat
        //    the page as content, not skippable front matter. Best-effort, same-directory only.
        insertIntoTOC(opf: opf, opfDir: opfDir, in: archive)

        // 3. Generate + register a cover image — AO3 epubs ship none, so the Kindle homescreen
        //    has nothing to thumbnail. Only when the book doesn't already declare a cover.
        if !opf.contains("name=\"cover\""), let cover = KindleCover.renderJPEG(for: work) {
            let coverZipPath = opfDir.isEmpty ? coverFilename : opfDir + "/" + coverFilename
            try addOrReplaceEntry(coverZipPath, data: cover, in: archive)
            opf = registerCover(in: opf, href: coverFilename)
        }

        // 4. Register the info page in the OPF (manifest + spine-first + start-reading guide); badge title.
        opf = registerInfoPage(in: opf, href: infoPageFilename)
        if let newTitle { opf = spliceTitle(in: opf, to: newTitle) ?? opf }

        // Re-fetch + replace the OPF last: the TOC/page edits above shifted central-directory
        // offsets, so a stale `Entry` captured earlier would point at the wrong bytes.
        try addOrReplaceEntry(opfPath, data: Data(opf.utf8), in: archive)
    }

    /// Register a cover image in the OPF: a manifest `<item>` plus the `<meta name="cover">` hint
    /// that Amazon's converter reads to pick the homescreen thumbnail. `href` is relative to the OPF.
    static func registerCover(in opf: String, href: String) -> String {
        var out = opf
        let item = "<item id=\"\(coverManifestID)\" href=\"\(href)\" "
            + "media-type=\"image/jpeg\" properties=\"cover-image\"/>"
        out = insertAfter(#"<manifest\b[^>]*>"#, in: out, fragment: item) ?? out
        let meta = "<meta name=\"cover\" content=\"\(coverManifestID)\"/>"
        out = insertAfter(#"<metadata\b[^>]*>"#, in: out, fragment: meta) ?? out
        return out
    }

    /// Insert the info page into the OPF: a manifest `<item>`, a spine `<itemref>` placed *first*,
    /// and a `<guide>` `text` reference so EPUB readers open there. `href` is relative to the OPF.
    static func registerInfoPage(in opf: String, href: String) -> String {
        var out = opf
        let item = "<item id=\"\(infoPageManifestID)\" href=\"\(href)\" "
            + "media-type=\"application/xhtml+xml\"/>"
        out = insertAfter(#"<manifest\b[^>]*>"#, in: out, fragment: item) ?? out

        let itemref = "<itemref idref=\"\(infoPageManifestID)\"/>"
        out = insertAfter(#"<spine\b[^>]*>"#, in: out, fragment: itemref) ?? out

        let ref = "<reference type=\"text\" title=\"About this work\" href=\"\(href)\"/>"
        if out.range(of: #"<guide\b[^>]*>"#, options: .regularExpression) != nil {
            out = insertAfter(#"<guide\b[^>]*>"#, in: out, fragment: ref) ?? out
        } else if let close = out.range(of: "</package>") {
            out.replaceSubrange(close, with: "<guide>\(ref)</guide></package>")
        }
        return out
    }

    /// Add the info page as the first TOC entry in the NCX (and EPUB3 nav, if present). Only when
    /// the TOC file sits in the same directory as the OPF (so a bare filename href is correct) —
    /// otherwise skip rather than risk a wrong relative path. Best-effort: failures are ignored.
    static func insertIntoTOC(opf: String, opfDir: String, in archive: Archive) {
        let title = "About this work"
        func resolved(_ href: String) -> String { opfDir.isEmpty ? href : opfDir + "/" + href }

        // NCX: media-type application/x-dtbncx+xml
        if let ncxHref = manifestHref(inOPF: opf, matching: { $0.contains("application/x-dtbncx+xml") }),
           !ncxHref.contains("/"),                       // same dir as OPF → bare-filename src is correct
           var ncx = entryString(resolved(ncxHref), in: archive),
           let r = ncx.range(of: #"<navMap\b[^>]*>"#, options: .regularExpression) {
            let np = "<navPoint id=\"\(infoPageManifestID)-nav\" playOrder=\"0\"><navLabel><text>"
                + "\(xmlEscape(title))</text></navLabel><content src=\"\(infoPageFilename)\"/></navPoint>"
            ncx.insert(contentsOf: np, at: r.upperBound)
            try? addOrReplaceEntry(resolved(ncxHref), data: Data(ncx.utf8), in: archive)
        }
        // EPUB3 nav: manifest item with properties containing "nav"
        if let navHref = manifestHref(inOPF: opf, matching: { $0.contains("properties=") && $0.contains("nav") }),
           !navHref.contains("/"),
           var nav = entryString(resolved(navHref), in: archive),
           let r = nav.range(of: #"(?s)<nav\b[^>]*epub:type\s*=\s*"[^"]*toc[^"]*"[^>]*>.*?<ol\b[^>]*>"#,
                             options: .regularExpression) {
            let li = "<li><a href=\"\(infoPageFilename)\">\(xmlEscape(title))</a></li>"
            nav.insert(contentsOf: li, at: r.upperBound)
            try? addOrReplaceEntry(resolved(navHref), data: Data(nav.utf8), in: archive)
        }
    }

    /// The href of the first manifest `<item>` whose tag text satisfies `matches`, e.g. by
    /// media-type or properties. nil if none.
    private static func manifestHref(inOPF opf: String, matching: (String) -> Bool) -> String? {
        for tag in regexMatches(#"<item\b[^>]*>"#, in: opf) where matching(tag) {
            if let r = tag.range(of: #"href\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let frag = String(tag[r])
                if let q1 = frag.firstIndex(of: "\""), let q2 = frag.lastIndex(of: "\""), q1 < q2 {
                    return String(frag[frag.index(after: q1)..<q2])
                }
            }
        }
        return nil
    }

    /// All substrings matching `pattern` (dot matches newlines).
    private static func regexMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func entryString(_ path: String, in archive: Archive) -> String? {
        entryData(path, in: archive).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Delete export copies older than an hour — the async Send-to-Kindle hand-off needs the file
    /// to outlive `makeKindleEPUB`, so we can't delete on the way out, but old ones shouldn't pile up.
    private static func sweepStaleExports(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in urls {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Insert `fragment` immediately after the first regex match of `opening`. nil if no match.
    private static func insertAfter(_ opening: String, in s: String, fragment: String) -> String? {
        guard let r = s.range(of: opening, options: .regularExpression) else { return nil }
        var out = s
        out.insert(contentsOf: fragment, at: r.upperBound)
        return out
    }

    /// Replace the inner text of the first `<dc:title>…</dc:title>` with `newTitle` (XML-escaped),
    /// preserving the opening tag's attributes. nil if there's no such element.
    public static func spliceTitle(in opf: String, to newTitle: String) -> String? {
        guard let range = opf.range(of: #"(?s)(<dc:title\b[^>]*>).*?(</dc:title>)"#,
                                    options: .regularExpression) else { return nil }
        let match = String(opf[range])
        guard let openEnd = match.range(of: ">") else { return nil }
        let openTag = String(match[..<openEnd.upperBound])
        return opf.replacingCharacters(in: range, with: openTag + xmlEscape(newTitle) + "</dc:title>")
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - small zip/xml helpers (local copies so this file stands alone)

    private static func addOrReplaceEntry(_ path: String, data: Data, in archive: Archive) throws {
        if let existing = archive[path] { try archive.remove(existing) }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }

    private static func entryData(_ path: String, in archive: Archive) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        do { _ = try archive.extract(entry) { data.append($0) } } catch { return nil }
        return data
    }

    /// Directory portion of a zip path (`OEBPS/x.opf` → `OEBPS`; `x.opf` → `""`).
    private static func directory(of path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// The OPF path from `META-INF/container.xml` (`rootfile/@full-path`), via a tolerant scan.
    private static func opfPath(fromContainer data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let r = xml.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let frag = String(xml[r])
        guard let q1 = frag.firstIndex(of: "\""), let q2 = frag.lastIndex(of: "\""), q1 < q2 else { return nil }
        return String(frag[frag.index(after: q1)..<q2])
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}

/// "1.0" → "1", "1.5" → "1.5".
private func trimZero(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(d)
}

import Foundation
import SwiftSoup
import ZIPFoundation

/// Reads the structure of an EPUB (which is a ZIP of XHTML + CSS described by an OPF
/// package) so the in-app reader can render it: the ordered reading **spine**, a **table of
/// contents** (EPUB3 `nav` or EPUB2 `toc.ncx`, falling back to spine order), and the
/// bibliographic **metadata**. It can also extract the archive to a directory so a
/// `WKWebView` can load the chapter files (and their relative CSS/images) directly.
///
/// This is the read-side counterpart to `BlurbParser`: pinned-by-fixture, **fail-soft**
/// (a missing TOC degrades to spine order rather than throwing), and pure enough to test
/// headlessly. AO3 renders EPUBs server-side and they're uniform, but we parse defensively
/// so a layout drift never crashes the reader.
///
/// > Internally everything is keyed by **full path within the zip** (e.g. `OEBPS/ch1.xhtml`)
/// > so spine ⇄ TOC matching and on-disk extraction need no relative-path gymnastics at the
/// > API boundary.
public enum EpubError: Error, CustomStringConvertible, Equatable {
    case cannotOpen(String)
    case missingContainer
    case missingPackage(String)
    case missingEntry(String)
    case emptySpine

    public var description: String {
        switch self {
        case .cannotOpen(let s):    return "cannot open EPUB: \(s)"
        case .missingContainer:     return "EPUB has no META-INF/container.xml"
        case .missingPackage(let p): return "EPUB package not found at \(p)"
        case .missingEntry(let p):  return "EPUB entry not found: \(p)"
        case .emptySpine:           return "EPUB spine is empty (nothing to read)"
        }
    }
}

/// Bibliographic metadata from the OPF `<metadata>` (all optional — fail soft).
public struct EpubMetadata: Sendable, Equatable {
    public let title: String?
    public let author: String?
    public let language: String?
}

/// One content document in reading order. `path` is the full path within the zip.
public struct EpubSpineItem: Sendable, Equatable {
    public let idref: String
    public let path: String
    public let mediaType: String?
}

/// One table-of-contents entry. `path` is the full zip path (no fragment); `spineIndex`
/// is the matched index into the spine when the target is a spine document.
public struct EpubChapter: Sendable, Equatable {
    public let title: String
    public let path: String
    public let fragment: String?
    public let spineIndex: Int?
}

/// A **reading unit** — what the reader navigates by. Built from the TOC (nav/ncx), not the
/// raw spine: AO3 EPUBs split a work into front-matter + per-chapter spine files and a
/// *title page* that the NCX omits, so navigating the spine directly mislabels "Preface" /
/// title pages as chapters. A section folds the spine files between one TOC anchor and the
/// next into a single titled unit (so the title page lands inside "Preface").
public struct ReaderSection: Sendable, Equatable {
    public let title: String
    public let spineIndices: [Int]
}

public final class EpubDocument {
    public let url: URL
    public let metadata: EpubMetadata
    /// Directory of the OPF within the zip (e.g. `OEBPS`, or `""` at the root).
    public let opfDirectory: String
    public let spine: [EpubSpineItem]
    public let toc: [EpubChapter]
    /// TOC-derived reading units (front matter folded in). The reader navigates these.
    public let sections: [ReaderSection]

    private let archive: Archive
    /// Sanitized body HTML per spine index — `bodyHTML` doesn't depend on CSS, so caching it
    /// makes settings-change rebuilds (re-wrap + concatenate) cheap; only cold open pays the
    /// SwiftSoup parse. Single-threaded use (main actor / tests).
    private var bodyCache: [Int: String] = [:]

    /// Number of reading units (sections), not raw spine documents.
    public var sectionCount: Int { sections.count }
    public var sectionTitles: [String] { sections.map(\.title) }

    // MARK: - Open & parse

    public init(url: URL) throws {
        self.url = url
        do {
            self.archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EpubError.cannotOpen(String(describing: error))
        }

        // 1. META-INF/container.xml → the OPF package path.
        guard let containerData = Self.entryData("META-INF/container.xml", in: archive) else {
            throw EpubError.missingContainer
        }
        let container = try SwiftSoup.parseXML(String(decoding: containerData, as: UTF8.self), "")
        let rootfileEls = try Self.allElements(container, tag: "rootfile")
        let opfPath = (try? rootfileEls.first?.attr("full-path")) ?? nil ?? ""
        guard !opfPath.isEmpty, let opfData = Self.entryData(opfPath, in: archive) else {
            throw EpubError.missingPackage(opfPath)
        }
        self.opfDirectory = Self.directory(of: opfPath)

        // 2. Parse the OPF: metadata + manifest + spine.
        let opf = try SwiftSoup.parseXML(String(decoding: opfData, as: UTF8.self), "")

        self.metadata = EpubMetadata(
            title: Self.firstText(opf, tag: "dc:title"),
            author: Self.firstText(opf, tag: "dc:creator"),
            language: Self.firstText(opf, tag: "dc:language"))

        // manifest: id → (full path, media type, properties)
        struct ManifestItem { let path: String; let mediaType: String?; let properties: String }
        var manifest: [String: ManifestItem] = [:]
        for item in try Self.allElements(opf, tag: "item") {
            let id = (try? item.attr("id")) ?? ""
            let href = (try? item.attr("href")) ?? ""
            guard !id.isEmpty, !href.isEmpty else { continue }
            manifest[id] = ManifestItem(
                path: Self.resolvePath(base: opfDirectory, href: href),
                mediaType: nonEmpty(try? item.attr("media-type")),
                properties: (try? item.attr("properties")) ?? "")
        }

        // spine: ordered itemrefs → manifest items.
        let spineEl = try Self.allElements(opf, tag: "spine").first
        var spineItems: [EpubSpineItem] = []
        for ref in try Self.allElements(opf, tag: "itemref") {
            let idref = (try? ref.attr("idref")) ?? ""
            guard let m = manifest[idref] else { continue }
            spineItems.append(EpubSpineItem(idref: idref, path: m.path, mediaType: m.mediaType))
        }
        guard !spineItems.isEmpty else { throw EpubError.emptySpine }
        self.spine = spineItems

        // 3. TOC: prefer EPUB3 nav, then EPUB2 ncx, else fall back to spine order.
        let spineIndexByPath = Dictionary(spineItems.enumerated().map { ($0.element.path, $0.offset) },
                                          uniquingKeysWith: { a, _ in a })

        var chapters: [EpubChapter] = []
        if let navItem = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let navData = Self.entryData(navItem.path, in: archive) {
            chapters = Self.parseNav(navData, navPath: navItem.path, spineIndexByPath: spineIndexByPath)
        }
        if chapters.isEmpty {
            // EPUB2: spine `toc` attribute → ncx id, else any ncx-typed manifest item.
            let ncxID = (try? spineEl?.attr("toc")) ?? ""
            let ncxItem = manifest[ncxID] ?? manifest.values.first(where: {
                $0.mediaType == "application/x-dtbncx+xml" || $0.path.lowercased().hasSuffix(".ncx")
            })
            if let ncxItem, let ncxData = Self.entryData(ncxItem.path, in: archive) {
                chapters = Self.parseNCX(ncxData, ncxPath: ncxItem.path, spineIndexByPath: spineIndexByPath)
            }
        }
        if chapters.isEmpty {
            // Last resort: one entry per spine document.
            chapters = spineItems.enumerated().map { idx, item in
                EpubChapter(title: "Section \(idx + 1)", path: item.path, fragment: nil, spineIndex: idx)
            }
        }
        self.toc = chapters
        self.sections = Self.buildSections(spineCount: spineItems.count, toc: chapters)
    }

    /// Fold spine documents into TOC-titled reading units (see `ReaderSection`). Spine items
    /// before the first TOC anchor (the title page) fold into the first unit.
    static func buildSections(spineCount: Int, toc: [EpubChapter]) -> [ReaderSection] {
        var seen = Set<Int>()
        let anchors = toc
            .compactMap { ch in ch.spineIndex.map { (title: ch.title, index: $0) } }
            .sorted { $0.index < $1.index }
            .filter { seen.insert($0.index).inserted }   // keep the first label per spine index

        guard !anchors.isEmpty else {
            return (0..<spineCount).map { ReaderSection(title: "Section \($0 + 1)", spineIndices: [$0]) }
        }

        return anchors.enumerated().map { idx, anchor in
            let start = idx == 0 ? 0 : anchor.index    // fold leading front matter / title page in
            let end = idx + 1 < anchors.count ? anchors[idx + 1].index : spineCount
            return ReaderSection(title: anchor.title, spineIndices: Array(start..<max(start + 1, end)))
        }
    }

    // MARK: - Reading content

    /// Raw bytes of a spine item.
    public func data(forSpineIndex index: Int) throws -> Data {
        let item = spine[index]
        guard let data = Self.entryData(item.path, in: archive) else {
            throw EpubError.missingEntry(item.path)
        }
        return data
    }

    /// A spine item decoded as text (UTF-8, falling back to Latin-1 then lossy UTF-8).
    public func html(forSpineIndex index: Int) throws -> String {
        let data = try data(forSpineIndex: index)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// The sanitized inner-`<body>` HTML of a spine item (no remote refs, no scripts). Cached.
    public func bodyHTML(forSpineIndex index: Int) throws -> String {
        if let cached = bodyCache[index] { return cached }
        let clean = EpubSanitizer.sanitizedBody(try html(forSpineIndex: index))
        bodyCache[index] = clean
        return clean
    }

    /// All spine indices reachable from the sections, in order (what scroll mode renders).
    public var allSectionSpineIndices: [Int] { sections.flatMap(\.spineIndices) }

    /// Raw (unsanitized) HTML for the given spine indices — gathered on the main actor (cheap
    /// zip reads) so the expensive sanitize can be done off-main and fed back via `seedBodyCache`.
    public func rawHTML(forSpineIndices indices: [Int]) -> [Int: String] {
        var out: [Int: String] = [:]
        for i in indices where bodyCache[i] == nil {
            if let s = try? html(forSpineIndex: i) { out[i] = s }
        }
        return out
    }

    /// Seed the body cache with already-sanitized bodies (computed off the main thread). After
    /// this, `wholeWorkHTML`/`chapterHTML` are pure string concatenation — no SwiftSoup parse.
    public func seedBodyCache(_ sanitizedBySpineIndex: [Int: String]) {
        for (i, body) in sanitizedBySpineIndex { bodyCache[i] = body }
    }

    // MARK: - Reader document (a single generated text/html page)

    /// Build a self-contained `text/html` document from the given sections, with the reader
    /// stylesheet inlined in `<head>`. Generating fresh HTML (rather than re-serving the
    /// EPUB's `.xhtml`) is deliberate: it renders under the lenient HTML parser, so undefined
    /// XHTML entities like `&nbsp;` no longer truncate the chapter, and there are no remote
    /// references because each body is `EpubSanitizer`-cleaned. Each section is wrapped in an
    /// anchored `<section>` so the TOC can scroll to it in scroll mode.
    public func readerHTML(sectionIndices: [Int], css: String, scrollReporter: Bool = false) -> String {
        let body = sectionIndices.compactMap { s -> String? in
            guard sections.indices.contains(s) else { return nil }
            let inner = sections[s].spineIndices
                .compactMap { try? bodyHTML(forSpineIndex: $0) }
                .joined(separator: "\n")
            return "<section class=\"ao3-chapter\" id=\"ao3-sec-\(s)\">\n\(inner)\n</section>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="\(metadata.language ?? "en")">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>\(css)</style>
        </head>
        <body>
        \(body)
        \(scrollReporter ? Self.scrollReporterScript : "")
        </body>
        </html>
        """
    }

    /// One reading unit (chapter-by-chapter mode).
    public func chapterHTML(sectionIndex: Int, css: String) -> String {
        readerHTML(sectionIndices: [sectionIndex], css: css)
    }

    /// The whole work, all sections concatenated (infinite-scroll mode). Lazy *rendering* is via
    /// the `content-visibility` CSS on each section (the browser skips off-screen layout/paint);
    /// the reporter script posts the topmost-visible section index back for scroll-position resume.
    public func wholeWorkHTML(css: String) -> String {
        readerHTML(sectionIndices: Array(sections.indices), css: css, scrollReporter: true)
    }

    /// One-way, debounced (250ms) scroll reporter: posts `{i: topmostVisibleSectionIndex}` to the
    /// native `reader` message handler so the reader can persist where you actually scrolled to
    /// (section-granular — robust across font changes, unlike a pixel fraction).
    static let scrollReporterScript = """
    <script>
    (function(){var t;function r(){var s=document.querySelectorAll('section.ao3-chapter'),b=0;
    for(var k=0;k<s.length;k++){if(s[k].getBoundingClientRect().top<=120){b=k;}else{break;}}
    try{window.webkit.messageHandlers.reader.postMessage({i:b});}catch(e){}}
    window.addEventListener('scroll',function(){clearTimeout(t);t=setTimeout(r,250);},{passive:true});})();
    </script>
    """

    // MARK: - Extraction (for WKWebView file-URL loading)

    /// Extract every entry into `directory` (created if needed), preserving the internal
    /// layout so chapter files resolve their relative CSS/images. (X)HTML entries are run
    /// through `EpubSanitizer` first, so the on-disk files the reader loads carry **no remote
    /// resource references** — the reader's no-network invariant enforced by construction,
    /// not by hoping a WebView delegate intercepts every subresource. Refuses any entry whose
    /// path would escape `directory` (zip-slip guard). Returns `directory`.
    @discardableResult
    public func extractAll(to directory: URL, sanitizeHTML: Bool = true, includeHTML: Bool = true) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootPath = directory.standardizedFileURL.path
        for entry in archive {
            let isHTML = Self.isHTMLPath(entry.path)
            // The reader loads a generated doc, not the EPUB's own (X)HTML — so callers can
            // skip extracting it entirely and avoid putting raw, unsanitized markup on disk.
            if isHTML, !includeHTML { continue }
            let dest = directory.appendingPathComponent(entry.path).standardizedFileURL
            // zip-slip: a malicious "../" path must never write outside the extraction root.
            guard dest.path == rootPath || dest.path.hasPrefix(rootPath + "/") else { continue }
            switch entry.type {
            case .directory:
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            default:
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                if sanitizeHTML, isHTML, let data = Self.entryData(entry.path, in: archive) {
                    let clean = EpubSanitizer.sanitize(String(decoding: data, as: UTF8.self))
                    try Data(clean.utf8).write(to: dest, options: .atomic)
                } else {
                    _ = try archive.extract(entry, to: dest)
                }
            }
        }
        return directory
    }

    private static func isHTMLPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".xhtml") || p.hasSuffix(".html") || p.hasSuffix(".htm")
    }

    /// The on-disk URL of a spine item after `extractAll(to:)`.
    public func fileURL(forSpineIndex index: Int, extractedTo directory: URL) -> URL {
        directory.appendingPathComponent(spine[index].path)
    }

    /// The on-disk URL for a TOC chapter after `extractAll(to:)`.
    public func fileURL(for chapter: EpubChapter, extractedTo directory: URL) -> URL {
        directory.appendingPathComponent(chapter.path)
    }

    // MARK: - Nav / NCX parsing

    private static func parseNav(_ data: Data, navPath: String,
                                 spineIndexByPath: [String: Int]) -> [EpubChapter] {
        guard let doc = try? SwiftSoup.parse(String(decoding: data, as: UTF8.self), "") else { return [] }
        // Prefer the <nav epub:type="toc">, else the first <nav>.
        let navs = (try? allElements(doc, tag: "nav")) ?? []
        let tocNav = navs.first(where: {
            ((try? $0.attr("epub:type")) ?? "").contains("toc")
        }) ?? navs.first
        guard let tocNav else { return [] }
        let navDir = directory(of: navPath)
        let links = (try? tocNav.select("a[href]").array()) ?? []
        return links.compactMap { link in
            chapter(fromHref: (try? link.attr("href")) ?? "",
                    title: ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    baseDir: navDir, spineIndexByPath: spineIndexByPath)
        }
    }

    private static func parseNCX(_ data: Data, ncxPath: String,
                                 spineIndexByPath: [String: Int]) -> [EpubChapter] {
        guard let doc = try? SwiftSoup.parseXML(String(decoding: data, as: UTF8.self), "") else { return [] }
        let ncxDir = directory(of: ncxPath)
        // navPoints in document order; each carries a navLabel/text and a content[src].
        return ((try? allElements(doc, tag: "navPoint")) ?? []).compactMap { point in
            let label = (try? allElements(point, tag: "text").first?.text()) ?? nil
            let src = (try? allElements(point, tag: "content").first?.attr("src")) ?? nil
            return chapter(fromHref: src ?? "",
                           title: (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           baseDir: ncxDir, spineIndexByPath: spineIndexByPath)
        }
    }

    /// Build a chapter from a TOC href relative to `baseDir`, splitting off any `#fragment`
    /// and matching the target document to a spine index.
    private static func chapter(fromHref href: String, title: String, baseDir: String,
                                spineIndexByPath: [String: Int]) -> EpubChapter? {
        guard !href.isEmpty else { return nil }
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        guard !rawPath.isEmpty else { return nil }
        let full = resolvePath(base: baseDir, href: rawPath)
        return EpubChapter(title: title.isEmpty ? full : title,
                           path: full, fragment: fragment,
                           spineIndex: spineIndexByPath[full])
    }

    // MARK: - Zip / path helpers

    private static func entryData(_ path: String, in archive: Archive) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        do { _ = try archive.extract(entry) { data.append($0) } } catch { return nil }
        return data
    }

    /// Directory portion of a zip path (`OEBPS/x.opf` → `OEBPS`; `x.opf` → `""`).
    public static func directory(of path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// Resolve `href` (relative, possibly with `./` and `../`) against directory `base`,
    /// percent-decoding it, into a normalized full zip path.
    public static func resolvePath(base: String, href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        var stack: [String] = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for comp in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".":  continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default:   stack.append(String(comp))
            }
        }
        return stack.joined(separator: "/")
    }

    // MARK: - SwiftSoup traversal (case-insensitive, namespace-safe)

    /// Descendant elements whose tag name matches `tag` case-insensitively — robust to the
    /// XML parser preserving namespaced/mixed-case names (`dc:title`, `navPoint`) where a CSS
    /// `select` would choke on the `:` or normalize the case away.
    static func allElements(_ root: Element, tag: String) throws -> [Element] {
        let want = tag.lowercased()
        return try root.getAllElements().array().filter { $0.tagName().lowercased() == want }
    }

    static func firstText(_ root: Element, tag: String) -> String? {
        guard let el = try? allElements(root, tag: tag).first else { return nil }
        return nonEmpty(try? el.text())
    }
}

/// nil if the optional string is nil/empty, else the trimmed-of-nothing value.
private func nonEmpty(_ s: String??) -> String? {
    guard let s = s ?? nil, !s.isEmpty else { return nil }
    return s
}
private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}

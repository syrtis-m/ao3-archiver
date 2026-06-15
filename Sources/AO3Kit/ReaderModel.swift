import Foundation

/// The reader's `@Observable` view model. It owns an opened `EpubDocument`, the pure
/// `ReaderSession` navigation state (over reading *units*, not raw spine docs), the live
/// `ReaderSettings`, the on-disk extraction the `WKWebView` loads resources from, and resume
/// persistence via `Store`. Every decision (bounds, progress, the generated HTML) comes from
/// the tested value types; the view binds.
///
/// Rendering: it writes a generated `text/html` document (current chapter, or the whole work
/// in scroll mode) into the extracted EPUB directory and hands the view that file URL — so the
/// content renders under the lenient HTML parser (no `&nbsp;` truncation) and carries no remote
/// references (`EpubSanitizer` cleans every body it concatenates).
@MainActor
@Observable
public final class ReaderModel {
    /// What the view should load: a file URL, the read-access root, and an optional anchor to
    /// scroll to (the current section, in scroll mode).
    public struct RenderTarget: Equatable {
        public let file: URL
        public let readAccess: URL
        /// Changes whenever the document's *content* changes. The WebView reloads on a new
        /// version — the file path is reused, so path equality can't detect a rewrite.
        public let version: String
        public let anchor: String?
    }

    public let document: EpubDocument
    public let workID: Int
    public let workTitle: String

    public private(set) var session: ReaderSession
    public var settings: ReaderSettings {
        didSet { session.settings = settings; persistSettings() }
    }

    private let store: Store?
    private let settingsKey = "readerSettings"
    @ObservationIgnored private var extractedDirectory: URL?
    @ObservationIgnored private var readerDocURL: URL?
    /// The content key last written to disk, so we only regenerate when something changed.
    @ObservationIgnored private var writtenKey: String?
    /// Whether the whole-work bodies have been sanitized + cached (scroll mode needs them all).
    @ObservationIgnored private var bodiesPrepared = false

    public init(epubURL: URL, workID: Int, workTitle: String, store: Store?) throws {
        self.document = try EpubDocument(url: epubURL)
        self.workID = workID
        self.workTitle = workTitle
        self.store = store
        let loaded = Self.loadSettings()
        self.settings = loaded

        let saved = try? store?.readingPosition(workID: workID)
        self.session = ReaderSession(unitCount: document.sectionCount,
                                     index: saved?.spineIndex ?? 0, settings: loaded)
    }

    // MARK: - Derived view inputs

    public var sectionTitles: [String] { document.sectionTitles }
    public var isScroll: Bool { settings.layout == .scroll }
    public var currentIndex: Int { session.index }
    public var unitCount: Int { session.unitCount }
    public var canGoNext: Bool { session.canGoNext }
    public var canGoPrevious: Bool { session.canGoPrevious }
    public var progress: Double { session.progress }
    public var author: String? { document.metadata.author }
    public var metadataTitle: String { document.metadata.title ?? workTitle }

    /// The reader's heading: the work title in scroll mode, the current unit's title otherwise.
    public var currentTitle: String {
        guard !isScroll, document.sections.indices.contains(session.index) else { return metadataTitle }
        return document.sections[session.index].title
    }

    /// Changes whenever the rendered document must be rebuilt (mode, current unit, or styling).
    /// The view observes this to know when to re-fetch `renderTarget()`.
    public var renderKey: String {
        let unit = isScroll ? -1 : session.index
        return "\(settings.layout.rawValue)|\(unit)|\(settings.injectedCSS.hashValue)"
    }

    // MARK: - Rendering

    /// True while scroll mode still needs its bodies sanitized off-main (show a spinner). Chapter
    /// mode parses a single section on demand, so it's never "preparing".
    public var isPreparing: Bool { isScroll && !bodiesPrepared }

    /// Sanitize all the work's bodies **off the main thread** (the SwiftSoup parse is the cost —
    /// ~2.6s for a 247-chapter work) and seed the cache, so scroll mode can build instantly and
    /// without freezing the UI. No-op outside scroll mode (a chapter parses one section, cheaply)
    /// or once prepared. Idempotent.
    public func prepareScrollBodiesIfNeeded() async {
        guard isScroll, !bodiesPrepared else { return }
        let raw = document.rawHTML(forSpineIndices: document.allSectionSpineIndices)   // main: zip reads
        if !raw.isEmpty {
            let clean = await Task.detached(priority: .userInitiated) {
                raw.mapValues { EpubSanitizer.sanitizedBody($0) }                      // off-main: parse
            }.value
            document.seedBodyCache(clean)
        }
        bodiesPrepared = true
    }

    /// Generate (if needed) and return the document the WebView should load. Returns `nil` while
    /// scroll mode is still preparing (see `isPreparing`) — call `prepareScrollBodiesIfNeeded()`.
    public func renderTarget() -> RenderTarget? {
        guard let dir = ensureExtracted(), let docURL = readerDocURL else { return nil }
        if isScroll && !bodiesPrepared { return nil }
        let key = renderKey
        if writtenKey != key {
            let html = isScroll
                ? document.wholeWorkHTML(css: settings.injectedCSS)
                : document.chapterHTML(sectionIndex: session.index, css: settings.injectedCSS)
            guard (try? Data(html.utf8).write(to: docURL, options: .atomic)) != nil else { return nil }
            writtenKey = key
        }
        // In scroll mode, land on (or jump to) the current section's anchor.
        let anchor = isScroll ? "ao3-sec-\(session.index)" : nil
        return RenderTarget(file: docURL, readAccess: dir, version: key, anchor: anchor)
    }

    // MARK: - Navigation (persisted)

    public func goNext()      { if session.goNext() { persistPosition() } }
    public func goPrevious()  { if session.goPrevious() { persistPosition() } }
    public func jump(toSection index: Int) { if session.jump(to: index) { persistPosition() } }

    /// Called as the reader scrolls (scroll mode): record the section actually being read so
    /// resume lands there, not on the last TOC selection. Doesn't change `renderKey`, so it
    /// never triggers a reload — and we don't re-emit a scroll anchor (the user is scrolling).
    public func recordVisibleSection(_ index: Int) {
        guard isScroll, index != session.index, session.jump(to: index) else { return }
        persistPosition()
    }

    // MARK: - Lifecycle

    /// Remove the extracted temp directory. Call on reader dismissal.
    public func cleanup() {
        if let dir = extractedDirectory { try? FileManager.default.removeItem(at: dir) }
        extractedDirectory = nil
        writtenKey = nil
    }

    // MARK: - Private

    private func ensureExtracted() -> URL? {
        if let dir = extractedDirectory { return dir }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ao3-reader", isDirectory: true)
            .appendingPathComponent("\(workID)-\(UUID().uuidString)", isDirectory: true)
        do {
            // Resources only (CSS/images); the reader doc is generated, so skip the EPUB's
            // own (X)HTML — keeps raw, unsanitized markup off disk.
            try document.extractAll(to: base, includeHTML: false)
            // The generated doc lives next to the content (the OPF directory) so relative
            // resource refs (`images/x.png`) resolve against the right base.
            let docDir = document.opfDirectory.isEmpty ? base
                : base.appendingPathComponent(document.opfDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            readerDocURL = docDir.appendingPathComponent("__ao3reader.html")
            extractedDirectory = base
            return base
        } catch {
            return nil
        }
    }

    private func persistPosition() {
        try? store?.saveReadingPosition(workID: workID, spineIndex: session.index,
                                        progress: session.progress)
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private static func loadSettings() -> ReaderSettings {
        guard let data = UserDefaults.standard.data(forKey: "readerSettings"),
              let s = try? JSONDecoder().decode(ReaderSettings.self, from: data) else {
            return ReaderSettings()
        }
        return s
    }
}

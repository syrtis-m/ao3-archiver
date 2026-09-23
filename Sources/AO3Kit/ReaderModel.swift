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
    private static let settingsKey = "readerSettings"
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

    /// True while resources are still being extracted, or scroll mode still needs its bodies
    /// sanitized off-main (show a spinner).
    public var isPreparing: Bool { extractedDirectory == nil || (isScroll && !bodiesPrepared) }

    /// Why the reader can't render (e.g. the EPUB's resources couldn't be extracted), or nil.
    /// Previously a failed extraction returned nil forever and the window just stayed blank.
    public private(set) var renderError: String?

    /// Extract the EPUB's resources (images/fonts) **off the main thread** — for an
    /// image-heavy work this was a visible freeze on open. Uses its own archive handle (see
    /// `EpubDocument.extractResources`). Idempotent; records `renderError` on failure.
    public func prepareExtractionIfNeeded() async {
        guard extractedDirectory == nil, renderError == nil else { return }
        // Two rebuilds can race here (initial load + a settings change); share one extraction
        // rather than unpacking twice and orphaning the loser's temp directory.
        if let extracting { return await extracting.value }
        let job = Task { await extract() }
        extracting = job
        await job.value
        extracting = nil
    }

    @ObservationIgnored private var extracting: Task<Void, Never>?

    private func extract() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ao3-reader", isDirectory: true)
            .appendingPathComponent("\(workID)-\(UUID().uuidString)", isDirectory: true)
        // The generated doc lives next to the content (the OPF directory) so relative
        // resource refs (`images/x.png`) resolve against the right base.
        let docDir = document.opfDirectory.isEmpty ? base
            : base.appendingPathComponent(document.opfDirectory, isDirectory: true)
        let source = document.url
        do {
            try await Task.detached(priority: .userInitiated) {
                try EpubDocument.extractResources(from: source, to: base)
                try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            }.value
            readerDocURL = docDir.appendingPathComponent("__ao3reader.html")
            extractedDirectory = base
        } catch {
            try? FileManager.default.removeItem(at: base)
            renderError = "Couldn't prepare this work for reading: \(error)"
        }
    }

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
        guard let dir = extractedDirectory, let docURL = readerDocURL else { return nil }
        if isScroll && !bodiesPrepared { return nil }
        let key = renderKey
        if writtenKey != key {
            let html = isScroll
                ? document.wholeWorkHTML(css: settings.injectedCSS)
                : document.chapterHTML(sectionIndex: session.index, css: settings.injectedCSS)
            do { try Data(html.utf8).write(to: docURL, options: .atomic) }
            catch { renderError = "Couldn't write the reader page: \(error)"; return nil }
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

    /// Why the last resume write failed, or nil if the last one succeeded. Non-fatal but
    /// deliberately **not silent**: a dropped reading position is a user-visible feature
    /// failing, and the bare `try?` this replaces is exactly what let it fail invisibly when
    /// a concurrent sync held the write lock (see `Store.makeConfiguration`).
    public private(set) var lastPersistError: String?

    /// Whether to show the "couldn't save your place" affordance. Branching lives here, not
    /// in the View.
    public var showsPersistWarning: Bool { lastPersistError != nil }

    private func persistPosition() {
        guard let store else { return }
        do {
            try store.saveReadingPosition(workID: workID, spineIndex: session.index,
                                          progress: session.progress)
            lastPersistError = nil
        } catch {
            lastPersistError = String(describing: error)
        }
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private static func loadSettings() -> ReaderSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(ReaderSettings.self, from: data) else {
            return ReaderSettings()
        }
        return s
    }
}

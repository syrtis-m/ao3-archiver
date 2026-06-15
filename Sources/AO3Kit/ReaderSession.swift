import Foundation

/// Pure, value-type reading state and rendering settings for the in-app EPUB reader. This
/// is the **tested logic below the SwiftUI line**: navigation over reading *units* (sections,
/// not raw spine docs — see `ReaderSection`), progress, and the reader stylesheet string.
/// `ReaderModel` and the `WKWebView` view are thin skins over this.

/// What the reader looks like. `Codable` so it round-trips through `UserDefaults`.
public struct ReaderSettings: Sendable, Equatable, Codable {
    public enum Theme: String, Sendable, Codable, CaseIterable {
        case darkGlass, black, sepia
        public var label: String {
            switch self {
            case .darkGlass: return "Dark"
            case .black:     return "Black"
            case .sepia:     return "Sepia"
            }
        }
    }
    /// How much is rendered at once: one chapter, or the whole work in one continuous scroll.
    public enum Layout: String, Sendable, Codable, CaseIterable {
        case chapter, scroll
        public var label: String { self == .chapter ? "Chapters" : "Scroll" }
    }

    public var theme: Theme
    /// Body font size as a multiple of the base (clamped 0.7…2.0).
    public var fontScale: Double
    /// Line height multiple (clamped 1.2…2.2).
    public var lineSpacing: Double
    public var fontFamily: String
    public var layout: Layout

    public static let fontScaleRange = 0.7...2.0
    public static let lineSpacingRange = 1.2...2.2

    public init(theme: Theme = .darkGlass, fontScale: Double = 1.0, lineSpacing: Double = 1.6,
                fontFamily: String = "Georgia", layout: Layout = .scroll) {
        self.theme = theme
        self.fontScale = fontScale.clamped(to: Self.fontScaleRange)
        self.lineSpacing = lineSpacing.clamped(to: Self.lineSpacingRange)
        self.fontFamily = fontFamily
        self.layout = layout
    }

    /// Clamp in place — call after any +/- adjustment from the UI.
    public mutating func normalize() {
        fontScale = fontScale.clamped(to: Self.fontScaleRange)
        lineSpacing = lineSpacing.clamped(to: Self.lineSpacingRange)
    }

    // Theme palette: (background, foreground, link, faint separator).
    private var palette: (bg: String, fg: String, link: String, rule: String) {
        switch theme {
        case .darkGlass: return ("#14161c", "#e7e8ec", "#9fb8ff", "rgba(255,255,255,0.12)")
        case .black:     return ("#000000", "#cdcdcd", "#7fa8ff", "rgba(255,255,255,0.10)")
        case .sepia:     return ("#f4ecd8", "#3b3a36", "#7a5a2e", "rgba(0,0,0,0.12)")
        }
    }

    /// The reader stylesheet, inlined into the generated document's `<head>`. Numeric values
    /// are emitted verbatim so tests can pin them.
    public var injectedCSS: String {
        let p = palette
        let pct = Int((fontScale * 100).rounded())
        return """
        /* ao3-reader theme: \(theme.rawValue) layout: \(layout.rawValue) */
        :root { color-scheme: \(theme == .sepia ? "light" : "dark"); }
        html, body { background: \(p.bg); color: \(p.fg); margin: 0; }
        body {
          font-family: "\(fontFamily)", Georgia, "Times New Roman", serif;
          font-size: \(pct)%;
          line-height: \(lineSpacing);
        }
        section.ao3-chapter {
          max-width: 42rem;
          margin: 0 auto;
          padding: 2.75rem 1.5rem 3rem;
        }
        /* Keep scroll position stable when content above the viewport reflows. */
        html { overflow-anchor: auto; }
        section.ao3-chapter + section.ao3-chapter { border-top: 1px solid \(p.rule); }
        a { color: \(p.link); }
        img { max-width: 100%; height: auto; }
        h1, h2, h3 { line-height: 1.25; }
        """
    }
}

/// Where in the work the reader is (which reading unit), and how to move between units.
public struct ReaderSession: Sendable, Equatable {
    /// Number of reading units (sections).
    public let unitCount: Int
    public private(set) var index: Int
    public var settings: ReaderSettings

    public init(unitCount: Int, index: Int = 0, settings: ReaderSettings = .init()) {
        self.unitCount = max(0, unitCount)
        self.index = self.unitCount == 0 ? 0 : index.clamped(to: 0...(self.unitCount - 1))
        self.settings = settings
    }

    public var canGoNext: Bool { index < unitCount - 1 }
    public var canGoPrevious: Bool { index > 0 }

    @discardableResult public mutating func goNext() -> Bool {
        guard canGoNext else { return false }
        index += 1; return true
    }
    @discardableResult public mutating func goPrevious() -> Bool {
        guard canGoPrevious else { return false }
        index -= 1; return true
    }
    /// Jump to a unit index, clamped to range; no-op on an empty work.
    @discardableResult public mutating func jump(to newIndex: Int) -> Bool {
        guard unitCount > 0 else { return false }
        index = newIndex.clamped(to: 0...(unitCount - 1))
        return true
    }

    /// Unit-granular progress 0…1 (0 for empty; 1 for a single-unit work).
    public var progress: Double {
        guard unitCount > 1 else { return unitCount == 0 ? 0 : 1 }
        return Double(index) / Double(unitCount - 1)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

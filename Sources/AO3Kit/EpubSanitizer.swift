import Foundation
import SwiftSoup

/// Strips a chapter's (X)HTML of everything that could make the reader reach off-disk: remote
/// resource references (a hotlinked `<img src="https://…">` is common in AO3 works) and active
/// content (`<script>`, inline `on*` handlers, embeddings). Local/relative refs are preserved,
/// so the extracted EPUB's own CSS and images still resolve via `file://`.
///
/// This is the **enforcement layer for the reader's "no remote requests" invariant**, done by
/// construction in the parsed DOM rather than hoping a `WKWebView` navigation delegate catches
/// subresource loads (it doesn't). Pure and headless-testable — see `EpubReaderTests`.
public enum EpubSanitizer {
    /// Elements removed outright (active content / embeddings).
    private static let strippedTags = ["script", "iframe", "frame", "object", "embed", "noscript", "base"]
    /// Attributes that can trigger a resource load when they hold a remote URL.
    private static let resourceAttrs = ["src", "srcset", "poster", "background", "data-src", "data-original"]

    /// Sanitize one document's HTML. Falls back to the input if parsing fails (the WebView's
    /// own delegate is the backstop), but in practice AO3 XHTML parses cleanly.
    public static func sanitize(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html, "") else { return html }
        sanitize(doc)
        return (try? doc.outerHtml()) ?? html
    }

    /// Sanitize and return only the `<body>` inner HTML — what the reader concatenates into
    /// its generated `text/html` document (so the rendered content is what's been cleaned).
    public static func sanitizedBody(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html, "") else { return html }
        sanitize(doc)
        return (try? doc.body()?.html()) ?? ((try? doc.outerHtml()) ?? html)
    }

    /// Strip remote-resource and active-content vectors from a parsed document, in place.
    static func sanitize(_ doc: Document) {
        for tag in strippedTags { _ = try? doc.select(tag).remove() }

        // Remote stylesheet/preload/prefetch links can't resolve offline — drop them.
        for link in (try? doc.select("link").array()) ?? [] where isRemote((try? link.attr("href")) ?? "") {
            _ = try? link.remove()
        }

        for el in (try? doc.getAllElements().array()) ?? [] {
            for attr in resourceAttrs where isRemote((try? el.attr(attr)) ?? "") {
                _ = try? el.removeAttr(attr)
            }
            if isRemote((try? el.attr("href")) ?? "") { _ = try? el.removeAttr("href") }
            // Inline event handlers (onload/onerror/…) can fetch — strip them all.
            let handlerKeys = (el.getAttributes()?.map { $0.getKey() } ?? [])
                .filter { $0.lowercased().hasPrefix("on") }
            for key in handlerKeys { _ = try? el.removeAttr(key) }
        }
    }

    /// A URL/attribute value that would load over the network: absolute `http(s):`,
    /// protocol-relative `//host/…`, or other remote schemes. Relative paths, `#fragments`,
    /// and `data:`/`mailto:` (no network) are treated as safe and kept.
    public static func isRemote(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return false }
        return v.hasPrefix("http://") || v.hasPrefix("https://") || v.hasPrefix("//")
            || v.hasPrefix("ftp:") || v.contains("https://") || v.contains("http://")
    }
}

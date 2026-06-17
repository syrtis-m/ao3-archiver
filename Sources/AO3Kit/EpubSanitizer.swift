import Foundation
import SwiftSoup

/// Strips a chapter's (X)HTML of everything that could make the reader reach off-disk: remote
/// resource references (a hotlinked `<img src="https://…">` is common in AO3 works), remote CSS
/// (`<style>` blocks and inline `style="…url(https://…)"` — these fetch with **no click**), and
/// active content (`<script>`, inline `on*` handlers, `javascript:` links, embeddings).
/// Local/relative refs are preserved, so the extracted EPUB's own CSS and images still resolve
/// via `file://`.
///
/// This is the **enforcement layer for the reader's "no remote requests" invariant**, done by
/// construction in the parsed DOM rather than hoping a `WKWebView` navigation delegate catches
/// subresource loads (it can't — CSS `url()` fetches and a `javascript:` link's `fetch()` never
/// surface as navigations). Pure and headless-testable — see `EpubReaderTests`.
public enum EpubSanitizer {
    /// Elements removed outright (active content / embeddings). `<style>` is here because its CSS
    /// can `@import`/`url()` a remote resource that loads on render — and a denylist regex over CSS
    /// is trivially obfuscated, so we drop the element wholesale (the reader supplies its own theme).
    private static let strippedTags = ["script", "style", "iframe", "frame", "object", "embed", "noscript", "base"]
    /// Attributes that can trigger a resource load when they hold a remote URL.
    private static let resourceAttrs = ["src", "srcset", "poster", "background", "data-src", "data-original"]
    /// Navigation/submission targets — dropped when remote or carrying a script-executing scheme.
    private static let navAttrs = ["href", "action", "formaction"]

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
            // href/action/formaction: remote target, or a script-executing scheme (a
            // `javascript:` link evaluates in-page and never reaches the WebView's nav delegate).
            for attr in navAttrs {
                let val = (try? el.attr(attr)) ?? ""
                if isRemote(val) || hasDangerousScheme(val) { _ = try? el.removeAttr(attr) }
            }
            // Inline `style="…"` that could pull in a resource (`url(…)` / `@import`) loads on
            // render with no click — drop the whole attribute.
            if styleMayLoadResource((try? el.attr("style")) ?? "") { _ = try? el.removeAttr("style") }
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

    /// A scheme that *executes* rather than navigates — `javascript:`/`vbscript:` in an `href`
    /// runs in-page (the WebView nav delegate never sees it), so it must be stripped here.
    /// Whitespace and C0 control chars are removed first: WebKit ignores them inside a scheme, so
    /// `java&#9;script:` (a literal tab) would otherwise slip a naive `hasPrefix`. (`data:` is
    /// deliberately not listed: navigating to a `data:` URL is a navigation the delegate cancels.)
    public static func hasDangerousScheme(_ value: String) -> Bool {
        let stripped = String(String.UnicodeScalarView(
            value.lowercased().unicodeScalars.filter { $0.value > 0x20 }))
        return stripped.hasPrefix("javascript:") || stripped.hasPrefix("vbscript:")
    }

    /// True if an inline `style="…"` value could pull in a resource at render time — any `url(…)`
    /// or `@import`. We can't reliably tell a remote `url()` from a local one once CSS escapes are
    /// in play (`url(\68ttps://…)` decodes to `https://…`) or whitespace is inserted (`url( //…`),
    /// so — exactly as with `<style>` — we drop the whole attribute rather than run a bypassable
    /// denylist. The reader supplies its own theme CSS, so losing a rare local inline `url()` is
    /// a non-issue. The literal `url(`/`@import` token survives value-escaping (the escape lives
    /// inside the parens), which is what makes this check, unlike a host match, robust.
    public static func styleMayLoadResource(_ css: String) -> Bool {
        let v = css.lowercased()
        return v.contains("url(") || v.contains("@import")
    }
}

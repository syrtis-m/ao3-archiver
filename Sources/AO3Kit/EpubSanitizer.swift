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
    /// `<link>` goes wholesale too: the reader inlines its own stylesheet, and a *local*
    /// stylesheet link could still `@import` a remote one. SVG `<set>`/`<animate>` can rewrite
    /// an `href` to a remote or `javascript:` value after sanitizing, so they're dropped as well.
    private static let strippedTags = ["script", "style", "iframe", "frame", "object", "embed", "noscript",
                                       "base", "link", "set", "animate"]
    /// Attributes that can trigger a resource load (or a ping) when they hold a remote URL.
    private static let resourceAttrs: Set<String> = ["src", "poster", "background", "data-src",
                                                     "data-original", "ping", "manifest"]
    /// Candidate lists (`url descriptor, url descriptor, …`) — every candidate is checked.
    private static let srcsetAttrs: Set<String> = ["srcset", "imagesrcset"]
    /// Navigation/submission targets — dropped when remote or carrying a script-executing scheme.
    /// Any attribute *ending* in `href` is treated the same (catches SVG `xlink:href`).
    private static let navAttrs: Set<String> = ["action", "formaction"]
    /// Schemes that never touch the network. Anything else with a scheme counts as remote.
    private static let localSchemes: Set<String> = ["data", "mailto", "about", "blob", "cid", "tel"]

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

        for el in (try? doc.getAllElements().array()) ?? [] {
            // Walk the element's *actual* attributes rather than probing a fixed list, so
            // namespaced ones (`xlink:href`) can't slip past.
            for attr in el.getAttributes()?.asList() ?? [] {
                let key = attr.getKey(), k = key.lowercased(), val = attr.getValue()
                let drop: Bool
                if srcsetAttrs.contains(k) {
                    drop = srcsetIsRemote(val)
                } else if resourceAttrs.contains(k) {
                    drop = isRemote(val)
                } else if navAttrs.contains(k) || k.hasSuffix("href") {
                    // Remote target, or a script-executing scheme (a `javascript:` link
                    // evaluates in-page and never reaches the WebView's nav delegate).
                    drop = isRemote(val) || hasDangerousScheme(val)
                } else {
                    drop = false
                }
                if drop { _ = try? el.removeAttr(key) }
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

    /// A URL/attribute value that could load over the network. Classified the way WebKit will
    /// *resolve* it (WHATWG URL parsing), not by string prefix — the parser drops tabs/newlines
    /// anywhere, trims C0/space, and treats `\` like `/`, so `https:evil.com`, `ht<TAB>tps://…`
    /// and `https:\\evil.com` all load remotely even though none starts with `https://`.
    /// Rule: protocol-relative (`//…`) or **any scheme** other than the no-network ones
    /// (`data:`, `mailto:`, …) is remote; everything else is a relative path and is kept —
    /// including a local href that merely *contains* `https://` in its query string.
    public static func isRemote(_ value: String) -> Bool {
        // WHATWG: strip ASCII tab/LF/CR anywhere, then leading/trailing C0 controls and space.
        let noTabs = String.UnicodeScalarView(value.lowercased().unicodeScalars.filter {
            $0 != "\t" && $0 != "\n" && $0 != "\r" })
        let v = String(noTabs).trimmingCharacters(in: CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x20)))
            .replacingOccurrences(of: "\\", with: "/")
        guard !v.isEmpty else { return false }
        if v.hasPrefix("//") { return true }
        guard let colon = v.firstIndex(of: ":") else { return false }
        let scheme = v[..<colon]
        // A scheme is ASCII: a letter, then letters/digits/`+-.`. Anything else before the
        // first ":" (e.g. "ch 1:2.html", "1:2.html") isn't a scheme, so it's a relative path.
        guard let first = scheme.unicodeScalars.first, first.isASCII,
              CharacterSet.lowercaseLetters.contains(first),
              scheme.unicodeScalars.allSatisfy({ $0.isASCII
                  && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return false }
        return !localSchemes.contains(String(scheme))
    }

    /// `srcset`: a comma-separated list of `url [descriptor]` candidates — remote if any is.
    static func srcsetIsRemote(_ value: String) -> Bool {
        value.split(separator: ",").contains { candidate in
            let url = candidate.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return isRemote(url)
        }
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

import Foundation
import SwiftSoup

/// Resolves and fetches the server-rendered EPUB for a work.
///
/// AO3 generates the EPUB itself, so we never build one — we read the download menu on
/// the work page (`li.download a[href$=.epub]`) and GET that link. The link is shaped
/// `/downloads/<id>/<slug>.epub?updated_at=<ts>` and 301-redirects to
/// download.archiveofourown.org (URLSession follows it).
public struct WorkDownloader {
    let client: AO3Client

    public init(client: AO3Client) {
        self.client = client
    }

    /// Parse the EPUB href out of a work page's download menu. Returns a site-relative
    /// path (e.g. "/downloads/123/Title.epub?updated_at=...").
    public static func epubHref(fromWorkHTML html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        // Real AO3 hrefs are ".../Title.epub?updated_at=<ts>", so an ends-with selector
        // would miss them — match on the *path* (before "?") ending in .epub. Prefer the
        // download menu, then fall back to a site-relative /downloads/ link. Both selectors
        // are anchored with `^=/downloads/` (not `*=`) so neither can pick up an attacker-
        // supplied absolute href — even one injected into a `li.download` wrapper inside work
        // content (e.g. https://evil/downloads/x.epub). The AO3Client host allowlist is the
        // backstop, but anchoring here avoids even forming the request.
        let candidates = try doc.select("li.download a[href^=/downloads/]").array()
                       + doc.select("a[href^=/downloads/]").array()
        for a in candidates {
            let href = try a.attr("href")
            let path = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
            if path.lowercased().hasSuffix(".epub") { return href }
        }
        return nil
    }

    /// Fetch the work page (bypassing the adult-content interstitial) and return the
    /// EPUB download path, or nil if none is present (e.g. login required).
    public func resolveEPUBHref(workID: Int) async throws -> String? {
        let html = try await client.getHTML(path: "/works/\(workID)?view_adult=true")
        return try Self.epubHref(fromWorkHTML: html)
    }

    /// Download the EPUB bytes for a work. Throws `AO3Error.requiresLogin` when the work
    /// page exposes no download (restricted/locked works need a session cookie).
    public func downloadEPUB(workID: Int) async throws -> Data {
        guard let href = try await resolveEPUBHref(workID: workID) else {
            throw AO3Error.requiresLogin
        }
        let data = try await client.getData(path: href)
        guard Self.looksLikeEPUB(data) else {
            // A non-ZIP body here usually means we got an interstitial/redirect page,
            // i.e. the content needs auth.
            throw AO3Error.requiresLogin
        }
        return data
    }

    /// EPUB is a ZIP container — verify the "PK\x03\x04" magic before trusting bytes.
    public static func looksLikeEPUB(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AO3Kit

/// A fake AO3 for end-to-end `SyncEngine` tests — no network, ever.
///
/// Each `StubAO3` claims a unique `*.archiveofourown.org` subdomain (so it passes
/// `AO3Client.isAO3Host`) and registers itself in a process-wide table keyed by that host, which
/// lets parallel tests each run their own stub without sharing routes. Requests are answered by
/// `handler`; anything it returns `nil` for is recorded in `unmatched` and failed with a
/// non-retryable error, so a test can assert it never asked for something unexpected.
public final class StubAO3: @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public init(status: Int = 200, body: Data) { self.status = status; self.body = body }
        public static func html(_ s: String, status: Int = 200) -> Response { .init(status: status, body: Data(s.utf8)) }
        public static let notFound = Response.html("<html><body>404</body></html>", status: 404)
        /// Minimal bytes that pass `WorkDownloader.looksLikeEPUB` (ZIP magic).
        public static let epub = Response(body: Data([0x50, 0x4B, 0x03, 0x04]) + Data("stub-epub".utf8))
    }

    public let host: String
    private let lock = NSLock()
    private var _handler: @Sendable (URLComponents) -> Response? = { _ in nil }
    private var _requests: [String] = []
    private var _unmatched: [String] = []
    /// Called (on URLSession's queue) with the path+query of every request before it's answered.
    public var onRequest: (@Sendable (String) -> Void)?

    public init() {
        host = "stub-\(UUID().uuidString.lowercased().prefix(12)).archiveofourown.org"
        StubURLProtocol.register(self)
    }
    deinit { StubURLProtocol.unregister(host) }

    public var handler: @Sendable (URLComponents) -> Response? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    public var requests: [String] { lock.withLock { _requests } }
    public var unmatched: [String] { lock.withLock { _unmatched } }

    /// Route by exact path (query ignored) — the common case.
    public func route(_ table: [String: Response]) {
        handler = { comps in table[comps.path] }
    }

    /// An `AO3Client` wired to this stub: private limiter, no spacing, no retries.
    public func client(cookie: String? = "stub-cookie") -> AO3Client {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return AO3Client(
            config: AO3Config(userAgent: "ao3-archiver-tests", sessionCookie: cookie,
                              minRequestInterval: 0, maxRetries: 0,
                              baseURL: URL(string: "https://\(host)")!),
            limiter: RateLimiter(), sessionConfiguration: cfg)
    }

    fileprivate func answer(_ url: URL) -> Response? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let key = comps.path + (comps.query.map { "?" + $0 } ?? "")
        lock.withLock { _requests.append(key) }
        onRequest?(key)
        let r = handler(comps)
        if r == nil { lock.withLock { _unmatched.append(key) } }
        return r
    }

    // MARK: - Canned HTML

    /// A bookmarks-style listing: `li.bookmark.blurb.group` cards, AO3's "1 - n of N Bookmarks"
    /// heading, and an optional Next link.
    public static func bookmarksPage(_ cards: [(bookmarkID: Int, workID: Int, title: String, isPrivate: Bool)],
                                     total: Int? = nil, next: String? = nil, updatedAt: Int = 1_700_000_000) -> String {
        let items = cards.map { c in
            """
            <li id="bookmark_\(c.bookmarkID)" class="bookmark blurb group" role="article">
              <p class="status">\(c.isPrivate ? "<span class=\"private\" title=\"Private Bookmark\"></span>" : "")</p>
              <div class="header module"><h4 class="heading"><a href="/works/\(c.workID)">\(c.title)</a> by
                <!-- do not cache --><a rel="author" href="/users/a/pseuds/a">a</a></h4>
                <!--updated_at=\(updatedAt)--><p class="datetime">01 Jan 2024</p></div>
              <dl class="stats"><dd class="chapters">1/1</dd></dl>
              <div class="user module group"><p class="datetime">02 Jan 2024</p></div>
            </li>
            """
        }.joined(separator: "\n")
        let n = total ?? cards.count
        return """
            <html><body><div id="main">
            <h2 class="heading">1 - \(cards.count) of \(n) Bookmarks by stub</h2>
            <ol class="bookmark index group">\(items)</ol>
            \(pagination(next))
            </div></body></html>
            """
    }

    /// A series page: `li.work.blurb.group` member cards and an optional Next link.
    public static func seriesPage(_ works: [(workID: Int, title: String)], next: String? = nil) -> String {
        let items = works.map { w in
            """
            <li id="work_\(w.workID)" class="work blurb group" role="article">
              <div class="header module"><h4 class="heading"><a href="/works/\(w.workID)">\(w.title)</a> by
                <a rel="author" href="/users/a/pseuds/a">a</a></h4><!--updated_at=1700000000--></div>
            </li>
            """
        }.joined(separator: "\n")
        return "<html><body><ol class=\"index group\">\(items)</ol>\(pagination(next))</body></html>"
    }

    /// A work page whose download menu links this work's EPUB.
    public static func workPage(_ workID: Int) -> String {
        """
        <html><body><ul class="work navigation actions"><li class="download"><ul>
        <li><a href="/downloads/\(workID)/Stub.epub?updated_at=1700000000">EPUB</a></li>
        </ul></li></ul><div id="workskin">text</div></body></html>
        """
    }

    private static func pagination(_ next: String?) -> String {
        guard let next else { return "" }
        let escaped = next.replacingOccurrences(of: "&", with: "&amp;")
        return "<ol class=\"pagination actions\"><li class=\"next\"><a href=\"\(escaped)\">Next →</a></li></ol>"
    }
}

/// The `URLProtocol` behind `StubAO3`. Only ever installed on stub clients' sessions.
public final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var stubs: [String: StubAO3] = [:]
    private static let lock = NSLock()

    static func register(_ s: StubAO3) { lock.withLock { stubs[s.host] = s } }
    static func unregister(_ host: String) { lock.withLock { _ = stubs.removeValue(forKey: host) } }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let url = request.url,
              let stub = Self.lock.withLock({ Self.stubs[url.host ?? ""] }),
              let r = stub.answer(url),
              let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": "text/html"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}

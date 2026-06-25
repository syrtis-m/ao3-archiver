import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AO3Config: Sendable {
    public var baseURL: URL
    public var userAgent: String
    /// Value of the `_otwarchive_session` cookie. nil ⇒ anonymous (public content only).
    public var sessionCookie: String?
    public var minRequestInterval: TimeInterval
    public var maxRetries: Int
    public var requestTimeout: TimeInterval

    public init(
        userAgent: String,
        sessionCookie: String? = nil,
        minRequestInterval: TimeInterval = 4,
        maxRetries: Int = 5,
        requestTimeout: TimeInterval = 45,
        baseURL: URL = URL(string: "https://archiveofourown.org")!
    ) {
        self.userAgent = userAgent
        self.sessionCookie = sessionCookie
        self.minRequestInterval = minRequestInterval
        self.maxRetries = maxRetries
        self.requestTimeout = requestTimeout
        self.baseURL = baseURL
    }

    /// Honest, descriptive User-Agent. Includes the requester's AO3 username when known, so AO3
    /// can identify whose account is making the (polite) requests; `contact` stays the tool
    /// maintainer's address. Anonymous runs omit the user clause.
    public static func defaultUserAgent(ao3User: String? = nil,
                                        contact: String = "syrtis@sysd.info") -> String {
        let user = ao3User?.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = (user?.isEmpty == false) ? "AO3 user: \(user!); " : ""
        return "ao3-archiver/0.1 (personal bookmark backup; \(who)contact \(contact))"
    }

    /// Normalize a pasted `_otwarchive_session` cookie down to the bare value the `Cookie`
    /// header expects. People paste the whole `name=value` pair, trailing `; other=cookie`
    /// junk, or stray whitespace/newlines from copying — any of which would be sent as a
    /// malformed header and silently treated as anonymous (→ `requiresLogin` on locked works).
    /// Returns nil for empty/whitespace-only input (i.e. "anonymous").
    public static func sanitizeCookie(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // Find the session pair wherever it sits — a pasted Cookie header / document.cookie
        // often has other pairs before it (e.g. "view_adult=true; _otwarchive_session=…").
        // Anchoring to the start would silently keep the wrong pair → an anonymous request.
        if let r = s.range(of: "_otwarchive_session=") { s = String(s[r.upperBound...]) }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }  // trailing cookies
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Percent-encode a value (e.g. an AO3 username) for safe interpolation into a URL path.
    /// Encodes everything outside AO3's handle charset — `/ ? # &` and whitespace included —
    /// so a stray character can't alter the route or inject a query parameter.
    public static func encodePathComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_-")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

public enum AO3Error: Error, CustomStringConvertible {
    case http(Int)
    case rateLimited(retryAfter: TimeInterval)
    case requiresLogin
    case badURL(String)
    case disallowedHost(String)
    case network(String)
    /// AO3 is behind a Cloudflare wall. `shieldsUp` = an Under-Attack / firewall **challenge**
    /// we can't pass programmatically (surface immediately); otherwise a transient edge 5xx.
    case cloudflare(status: Int, shieldsUp: Bool)

    public var description: String {
        switch self {
        case .http(let code):           return "HTTP \(code)"
        case .rateLimited(let s):       return "rate limited (retry after \(Int(s))s, exhausted retries)"
        case .requiresLogin:            return "this content requires a logged-in session cookie"
        case .badURL(let u):            return "bad URL: \(u)"
        case .disallowedHost(let h):    return "refused request to non-AO3 host: \(h)"
        case .network(let m):           return "network error: \(m)"
        case .cloudflare(let code, let shieldsUp):
            return shieldsUp
                ? "AO3 is in Cloudflare \u{201C}shields up\u{201D} mode (Under-Attack / firewall "
                  + "challenge) and is blocking automated access. This isn't a cookie problem — "
                  + "wait a few minutes and try again."
                : "Cloudflare edge error \(code) — AO3's servers are temporarily unreachable. "
                  + "Try again shortly."
        }
    }
}

/// Re-attaches the session cookie when URLSession follows a redirect to a different host.
/// EPUB downloads 301 from archiveofourown.org → download.archiveofourown.org, and
/// URLSession strips a manually-set `Cookie` header on cross-host redirects — which would
/// silently break downloads of *restricted* works (the public ones don't need the cookie,
/// so the failure would hide until a logged-in user hit a locked work).
///
/// It also **refuses any redirect that leaves AO3** — a hostile work page could otherwise
/// 30x us (or supply an off-site download href) toward an attacker host and we'd hand over
/// the session cookie / honest User-Agent. Only AO3's own hosts are followed.
final class RedirectCookieReattacher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let cookie: String?
    init(cookie: String?) { self.cookie = cookie }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard AO3Client.isAO3Host(request.url?.host) else {
            completionHandler(nil)   // cancel the redirect: it points off AO3
            return
        }
        guard let cookie, !cookie.isEmpty,
              request.value(forHTTPHeaderField: "Cookie") == nil
        else { completionHandler(request); return }
        var req = request
        req.setValue("_otwarchive_session=\(cookie)", forHTTPHeaderField: "Cookie")
        completionHandler(req)
    }
}

/// The only component that touches the network. Owns the rate limiter, 429/5xx backoff,
/// cookie injection, and a descriptive User-Agent. Everything else consumes raw HTML/bytes.
public final class AO3Client: @unchecked Sendable {
    public let config: AO3Config
    private let limiter: RateLimiter
    private let session: URLSession
    /// Diagnostics sink (defaults to stderr). Replaceable so the GUI can route
    /// "AO3 asked us to slow down" into the sync status UI.
    public var log: @Sendable (String) -> Void = { msg in
        FileHandle.standardError.write(Data(("[AO3Client] " + msg + "\n").utf8))
    }

    /// Called when AO3 throttles us (429/5xx) and we're about to sleep `seconds` before retry
    /// `attempt`/`max`. Lets the UI show a live "rate limited — waiting Ns" instead of looking
    /// stalled. (seconds, attempt, max)
    public var onRateLimit: @Sendable (TimeInterval, Int, Int) -> Void = { _, _, _ in }

    public init(config: AO3Config) {
        self.config = config
        self.limiter = RateLimiter(minInterval: config.minRequestInterval)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = config.requestTimeout
        cfg.httpShouldSetCookies = false          // we set the session cookie explicitly
        cfg.httpAdditionalHeaders = ["User-Agent": config.userAgent]
        // URLSession follows the 301 to download.archiveofourown.org for us; the delegate
        // re-attaches the cookie across that cross-host hop (see RedirectCookieReattacher).
        self.session = URLSession(
            configuration: cfg,
            delegate: RedirectCookieReattacher(cookie: AO3Config.sanitizeCookie(config.sessionCookie)),
            delegateQueue: nil)
    }

    /// True only for AO3's own hosts — the apex and its subdomains (e.g.
    /// `download.archiveofourown.org`). Used to gate cookie/User-Agent attachment and to
    /// reject SSRF: a bare `hasSuffix("archiveofourown.org")` would also match a lookalike
    /// like `evil-archiveofourown.org`, so the apex is matched exactly and subdomains require
    /// the leading dot.
    public static func isAO3Host(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "archiveofourown.org" || host.hasSuffix(".archiveofourown.org")
    }

    // MARK: - Public API

    /// GET a path (e.g. "/users/foo/bookmarks?page=1") and return decoded HTML.
    public func getHTML(path: String) async throws -> String {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw AO3Error.badURL(path)
        }
        let (data, _) = try await perform(URLRequest(url: url))
        return String(decoding: data, as: UTF8.self)
    }

    /// GET a path and return raw bytes (used for EPUB downloads).
    public func getData(path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw AO3Error.badURL(path)
        }
        let (data, _) = try await perform(URLRequest(url: url))
        return data
    }

    // MARK: - Request engine (retry + backoff)

    private func perform(_ request: URLRequest, attempt: Int = 0) async throws -> (Data, HTTPURLResponse) {
        // Never let the session cookie (or the username-bearing User-Agent) leave AO3, and
        // never fetch off-site: an absolute href resolves against no base, so a hostile work
        // page could otherwise point us at an attacker host. Refuse anything not on AO3.
        guard Self.isAO3Host(request.url?.host) else {
            throw AO3Error.disallowedHost(request.url?.host ?? request.url?.absoluteString ?? "?")
        }

        await limiter.waitTurn()

        var req = request
        if let cookie = AO3Config.sanitizeCookie(config.sessionCookie) {
            req.setValue("_otwarchive_session=\(cookie)", forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AO3Error.network("non-HTTP response")
            }

            // Cloudflare "shields up" (Under-Attack / firewall challenge) can land on any status
            // — 403, 429, 503, even 200 with a JS interstitial. We can't solve the challenge, so
            // surface it plainly instead of retrying uselessly or mis-reporting it as HTTP 403 /
            // requiresLogin (a non-EPUB challenge body would otherwise look like a locked work).
            if Self.isCloudflareChallenge(http, data) {
                log("Cloudflare challenge (\"shields up\") on HTTP \(http.statusCode) — surfacing")
                throw AO3Error.cloudflare(status: http.statusCode, shieldsUp: true)
            }

            switch http.statusCode {
            case 200..<300:
                return (data, http)

            case 429:
                let wait = Self.retryAfter(http) ?? Self.backoff(attempt)
                await limiter.penalize(seconds: wait)
                guard attempt < config.maxRetries else {
                    throw AO3Error.rateLimited(retryAfter: wait)
                }
                log("429 from AO3 — backing off \(Int(wait))s (attempt \(attempt + 1)/\(config.maxRetries))")
                onRateLimit(wait, attempt + 1, config.maxRetries)
                try await sleep(wait)
                return try await perform(request, attempt: attempt + 1)

            // Transient origin/edge 5xx — incl. Cloudflare's own 520–527/530. Retry with backoff,
            // then surface (as a Cloudflare edge error for the 52x codes, plain HTTP otherwise).
            case 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 527, 530:
                guard attempt < config.maxRetries else {
                    throw Self.isCloudflareEdge(http.statusCode)
                        ? AO3Error.cloudflare(status: http.statusCode, shieldsUp: false)
                        : AO3Error.http(http.statusCode)
                }
                let wait = Self.backoff(attempt)
                log("HTTP \(http.statusCode) — retrying in \(Int(wait))s (attempt \(attempt + 1)/\(config.maxRetries))")
                onRateLimit(wait, attempt + 1, config.maxRetries)
                try await sleep(wait)
                return try await perform(request, attempt: attempt + 1)

            default:
                throw AO3Error.http(http.statusCode)
            }
        } catch let error as AO3Error {
            throw error
        } catch {
            // Transient network failure (e.g. timeout) — retry with backoff.
            guard attempt < config.maxRetries else { throw AO3Error.network(String(describing: error)) }
            let wait = Self.backoff(attempt)
            log("network error (\(error.localizedDescription)) — retrying in \(Int(wait))s (attempt \(attempt + 1)/\(config.maxRetries))")
            try await sleep(wait)
            return try await perform(request, attempt: attempt + 1)
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Honor an explicit `Retry-After` header (delta-seconds form).
    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let secs = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return secs
    }

    /// Exponential backoff with jitter, capped at 60s.
    private static func backoff(_ attempt: Int) -> TimeInterval {
        let base = min(60.0, pow(2.0, Double(attempt)))
        return base + Double.random(in: 0...1)
    }

    /// Cloudflare's own edge status codes (origin unreachable / handshake failures). Distinct
    /// from a *challenge*: these are transient, so they're retried before being surfaced.
    public static func isCloudflareEdge(_ code: Int) -> Bool {
        (520...527).contains(code) || code == 530
    }

    /// True when the response is a Cloudflare **challenge** ("shields up" / Under-Attack mode or
    /// a firewall block) rather than real AO3 content. Such a page can't be solved without a
    /// browser, so we surface it instead of retrying. Detected by the `cf-mitigated: challenge`
    /// header (Cloudflare's explicit signal) or, for a Cloudflare-served response, the
    /// interstitial's tell-tale body markers. A genuine AO3 429/5xx or a binary EPUB won't match.
    public static func isCloudflareChallenge(_ http: HTTPURLResponse, _ data: Data) -> Bool {
        if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
            return true
        }
        let server = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        let servedByCloudflare = server.contains("cloudflare")
            || http.value(forHTTPHeaderField: "cf-ray") != nil
        guard servedByCloudflare else { return false }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        let markers = ["just a moment", "cf-browser-verification", "challenge-platform",
                       "attention required", "enable javascript and cookies",
                       "checking your browser", "cf_chl_opt"]
        return markers.contains { head.contains($0) }
    }
}

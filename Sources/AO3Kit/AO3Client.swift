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
}

public enum AO3Error: Error, CustomStringConvertible {
    case http(Int)
    case rateLimited(retryAfter: TimeInterval)
    case requiresLogin
    case badURL(String)
    case network(String)

    public var description: String {
        switch self {
        case .http(let code):           return "HTTP \(code)"
        case .rateLimited(let s):       return "rate limited (retry after \(Int(s))s, exhausted retries)"
        case .requiresLogin:            return "this content requires a logged-in session cookie"
        case .badURL(let u):            return "bad URL: \(u)"
        case .network(let m):           return "network error: \(m)"
        }
    }
}

/// Re-attaches the session cookie when URLSession follows a redirect to a different host.
/// EPUB downloads 301 from archiveofourown.org → download.archiveofourown.org, and
/// URLSession strips a manually-set `Cookie` header on cross-host redirects — which would
/// silently break downloads of *restricted* works (the public ones don't need the cookie,
/// so the failure would hide until a logged-in user hit a locked work).
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
        guard let cookie, !cookie.isEmpty,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.url?.host?.hasSuffix("archiveofourown.org") == true
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
            delegate: RedirectCookieReattacher(cookie: config.sessionCookie),
            delegateQueue: nil)
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
        await limiter.waitTurn()

        var req = request
        if let cookie = config.sessionCookie, !cookie.isEmpty {
            req.setValue("_otwarchive_session=\(cookie)", forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AO3Error.network("non-HTTP response")
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

            case 502, 503, 504:
                guard attempt < config.maxRetries else { throw AO3Error.http(http.statusCode) }
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
}

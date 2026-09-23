import Foundation

/// Enforces a minimum spacing between outbound requests, process-wide.
///
/// AO3 actively rate-limits and returns HTTP 429 when pushed; politeness is the whole
/// point of this tool existing without getting the user's IP throttled. The limiter
/// hands out time *slots*: each `waitTurn()` reserves the next slot and sleeps until it
/// arrives, so even highly concurrent callers are serialized to one-every-`minInterval`.
///
/// **One limiter per process (`shared`), not per client.** The app builds a fresh
/// `AO3Client` for every sync *and* for every single-work Download click; with a limiter
/// per client, clicking Download on three works (or on one during a sync) sent concurrent
/// requests to AO3. Each caller passes its own interval, and all of them queue on the same
/// slot clock.
public actor RateLimiter {
    public static let shared = RateLimiter()

    private var nextSlot: Date = .distantPast

    public init() {}

    /// Reserve the next slot and sleep until it. **Throws on cancellation** — previously the
    /// sleep was `try?`, so a cancelled task sailed straight through with no spacing at all.
    public func waitTurn(minInterval: TimeInterval) async throws {
        try Task.checkCancellation()
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(max(0, minInterval))
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Push the next allowed request out by `seconds` (used when AO3 explicitly asks us
    /// to back off via a 429 / Retry-After).
    public func penalize(seconds: TimeInterval) {
        let candidate = Date().addingTimeInterval(seconds)
        if candidate > nextSlot { nextSlot = candidate }
    }
}

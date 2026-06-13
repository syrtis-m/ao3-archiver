import Foundation

/// Enforces a minimum spacing between outbound requests, process-wide.
///
/// AO3 actively rate-limits and returns HTTP 429 when pushed; politeness is the whole
/// point of this tool existing without getting the user's IP throttled. The limiter
/// hands out time *slots*: each `waitTurn()` reserves the next slot and sleeps until it
/// arrives, so even highly concurrent callers are serialized to one-every-`minInterval`.
public actor RateLimiter {
    private let minInterval: TimeInterval
    private var nextSlot: Date = .distantPast

    public init(minInterval: TimeInterval) {
        self.minInterval = max(0, minInterval)
    }

    public func waitTurn() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Push the next allowed request out by `seconds` (used when AO3 explicitly asks us
    /// to back off via a 429 / Retry-After).
    public func penalize(seconds: TimeInterval) {
        let candidate = Date().addingTimeInterval(seconds)
        if candidate > nextSlot { nextSlot = candidate }
    }
}

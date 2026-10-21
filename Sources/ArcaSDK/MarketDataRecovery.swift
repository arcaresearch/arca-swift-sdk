import Foundation

extension Arca {
    /// Hint that usable connectivity returned. Advances only a pending public Hyperliquid retry,
    /// with 250–499 ms jitter and a 30 s cooldown. Never creates an owner, interrupts a live
    /// connection, or resets failure backoff. Call on restoration events, not a timer.
    /// Does not reconnect the authenticated Arca transport or establish price freshness.
    public func notifyMarketDataNetworkAvailable() async { await ws.notifyMarketDataNetworkAvailable() }
}

/// Source-actor state. A token fences sleepers already queued when cancellation occurs.
struct MarketRetryWindow {
    struct Plan { let token: UInt64; let delayMs: Int }
    private var token: UInt64 = 0
    private var deadline: UInt64?
    private var lastAdvance: UInt64?
    mutating func schedule(now: UInt64, delayMs: Int) -> Plan {
        deadline = now + UInt64(delayMs) * 1_000_000
        token += 1
        return Plan(token: token, delayMs: delayMs)
    }
    mutating func advance(now: UInt64, jitterMs: Int) -> Plan? {
        guard let due = deadline else { return nil }
        if let lastAdvance, now - lastAdvance < 30_000_000_000 { return nil }
        let delayMs = 250 + min(249, max(0, jitterMs))
        guard due > now, due - now > UInt64(delayMs) * 1_000_000 else { return nil }
        lastAdvance = now
        return schedule(now: now, delayMs: delayMs)
    }
    mutating func take(_ expected: UInt64) -> Bool {
        guard deadline != nil, token == expected else { return false }
        deadline = nil
        return true
    }
    mutating func cancel() { deadline = nil; token += 1 }
}

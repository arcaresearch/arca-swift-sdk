import Foundation

/// An exact published value with local transport receipt and SDK publication times.
/// Nanoseconds use DispatchTime.now().uptimeNanoseconds, never Unix time. Carry the record with
/// the value when measuring UI delay; never match a rendered value against a later snapshot.
/// Revision is local to one observer. Quiet values retain their record. Only BBO supplies venueTimeMs.
public struct PriceDeliveryDiagnostic: Sendable, Equatable {
    public let price: String
    public let revision: UInt64
    public let source: MarketDataPreference
    public let receivedAtNanos: UInt64
    public let publishedAtNanos: UInt64
    public let venueTimeMs: Int?
}

extension Arca {
    /// Observe existing watches for up to 512 explicit canonical markets. Creates no network interest.
    /// Start before watchPrices to capture its initial values; older cached values are omitted until
    /// they change. Full snapshots, newest-only buffering; cancellation releases this observer.
    /// Measures changed price publication, not latest feed activity or venue-to-screen latency.
    public func watchPriceDeliveryDiagnostics(markets: Set<String>) async throws -> AsyncStream<[String: PriceDeliveryDiagnostic]> {
        try await ws.watchPriceDeliveryDiagnostics(markets: markets)
    }
}

struct PriceDeliveryRecorder {
    let markets: Set<String>
    private struct Pending { let price: String; let source: MarketDataPreference; let received: UInt64; let venue: Int? }
    private var pending: [String: Pending] = [:]
    private var published: [String: PriceDeliveryDiagnostic] = [:]
    private var revision: UInt64 = 0
    init(markets: Set<String>) throws {
        guard markets.count <= 512, markets.allSatisfy(isCanonicalMarketId) else {
            throw ArcaError.validation(message: "Use at most 512 explicit canonical markets", errorId: nil)
        }
        self.markets = markets
    }
    mutating func stage(_ prices: [String: String], source: MarketDataPreference, received: UInt64, venue: Int?) {
        for (market, price) in prices where markets.contains(market) { pending[market] = Pending(price: price, source: source, received: received, venue: venue) }
    }
    mutating func clearDirectPending(keep: Set<String> = []) {
        pending = pending.filter { $0.value.source != .hyperliquid || keep.contains($0.key) }
    }
    mutating func publish(_ prices: [String: String], now: UInt64, committed: Set<String>) -> [String: PriceDeliveryDiagnostic]? {
        var next = published.filter { prices[$0.key] == $0.value.price }
        for (market, p) in pending where committed.contains(market) && prices[market] == p.price {
            revision += 1
            next[market] = PriceDeliveryDiagnostic(price: p.price, revision: revision, source: p.source, receivedAtNanos: p.received, publishedAtNanos: now, venueTimeMs: p.venue)
        }
        pending = pending.filter { !committed.contains($0.key) || prices[$0.key] != $0.value.price }
        guard next != published else { return nil }
        published = next
        return published
    }
    mutating func clear() { pending = [:]; published = [:] }
}

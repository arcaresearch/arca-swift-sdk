import Foundation

/// Cumulative diagnostics for one SDK client lifetime. Payload bytes exclude TLS/framing;
/// Arca bytes cover its whole shared socket. Values count routed interested quotes,
/// not price movement, venue latency, or GPU presentation. No per-market identifiers.
public struct MarketDataDiagnostics: Sendable {
    public var elapsedMs: Int = 0
    public var preference: MarketDataPreference = .arca
    public var requestedPriceMarkets: Int = 0
    public var directSubscriptions: Int = 0
    public var arcaServingMarkets: Int = 0
    public var hyperliquidServingMarkets: Int = 0
    public var arcaConnected = false
    public var arcaDisconnects = 0
    public var hyperliquidRecoveries = 0
    public var hyperliquidRecoveryMs = 0
    public var firstPriceMs: Int? = nil
    public var arcaPriceValues: Int = 0
    public var hyperliquidPriceValues: Int = 0
    public var arcaCandleFrames: Int = 0
    public var hyperliquidCandleFrames: Int = 0
    public var hyperliquidFailures: Int = 0
    public var arcaPayloadBytes: Int = 0
    public var hyperliquidPayloadBytes: Int = 0
    public init() {}
}

/// Constant-size counters plus a bounded-by-interest source map; serialized by the WS actor.
struct MarketDataDiagnosticsRecorder {
    private let start = ProcessInfo.processInfo.systemUptime
    private var counters = MarketDataDiagnostics()
    private var serving: [String: Bool] = [:]
    private var failedAtMs: Int?
    mutating func retain(_ interests: Set<String>) { serving = serving.filter { interests.contains($0.key) } }
    mutating func suspend() { failedAtMs = nil }
    mutating func connected(_ connected: Bool) {
        if counters.arcaConnected && !connected { counters.arcaDisconnects += 1 }
        counters.arcaConnected = connected
    }
    mutating func recovered() {
        guard let failedAtMs else { return }
        counters.hyperliquidRecoveries += 1
        counters.hyperliquidRecoveryMs += max(0, elapsedMs - failedAtMs)
        self.failedAtMs = nil
    }
    mutating func prices(_ prices: [String: String], direct: Bool, interests: Set<String>) {
        var count = 0
        for market in prices.keys where interests.contains(market) {
            serving[market] = direct; count += 1
        }
        guard count > 0 else { return }
        if counters.firstPriceMs == nil { counters.firstPriceMs = elapsedMs }
        if direct { counters.hyperliquidPriceValues += count } else { counters.arcaPriceValues += count }
    }
    mutating func candle(direct: Bool) {
        if direct { counters.hyperliquidCandleFrames += 1 } else { counters.arcaCandleFrames += 1 }
    }
    mutating func bytes(_ bytes: Int, direct: Bool) {
        if direct { counters.hyperliquidPayloadBytes += max(0, bytes) } else { counters.arcaPayloadBytes += max(0, bytes) }
    }
    mutating func failure() { counters.hyperliquidFailures += 1; if failedAtMs == nil { failedAtMs = elapsedMs } }
    private var elapsedMs: Int { Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
    mutating func snapshot(router: MarketDataRouter) -> MarketDataDiagnostics {
        let interests = router.priceInterestMarkets
        serving = serving.filter { interests.contains($0.key) }
        var result = counters
        result.elapsedMs = elapsedMs
        result.preference = router.preference
        result.requestedPriceMarkets = interests.count
        result.directSubscriptions = router.subscriptions.count
        result.hyperliquidServingMarkets = serving.values.filter { $0 }.count
        result.arcaServingMarkets = serving.count - result.hyperliquidServingMarkets
        return result
    }
}

extension Arca {
    /// Current cumulative counters. A read does not request network data.
    public var marketDataDiagnostics: MarketDataDiagnostics { get async { await ws.marketDataDiagnostics } }
    /// Initial snapshot, then at most one update/second while frames arrive, plus
    /// source/interest transitions. Newest-only buffering; cancellation releases the observer.
    /// No timer, polling, socket, or market subscription is created by observing.
    public func watchMarketDataDiagnostics() async -> AsyncStream<MarketDataDiagnostics> {
        await ws.watchMarketDataDiagnostics()
    }
}

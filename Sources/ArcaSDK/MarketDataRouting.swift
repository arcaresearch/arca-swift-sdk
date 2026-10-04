import Foundation

/// Reversible preference for public display prices and open candles. Financial authority is unchanged.
public enum MarketDataPreference: Sendable { case arca, hyperliquid }

/// Explicit venue network; never inferred from a realm name or API hostname.
public enum HyperliquidNetwork: Sendable {
    case mainnet, testnet
    var websocketURL: URL {
        URL(string: self == .mainnet ? "wss://api.hyperliquid.xyz/ws" : "wss://api.hyperliquid-testnet.xyz/ws")!
    }
}

/// Source-selection diagnostics. No exchange timestamp is invented for Arca frames.
public struct MarketDataSourceStatus: Sendable {
    public let preference: MarketDataPreference
    public let directSubscriptions: Int
    public let directPriceMarkets: Set<String>
    public let directCandleMarkets: Set<String>
    public let lastError: String?
}

struct PublicMarketSubscription: Hashable, Sendable {
    let market: String
    let coin: String
    var interval: CandleInterval? = nil
}
enum PublicMarketUpdate: Sendable {
    case quote(market: String, price: String, timeMs: Int)
    case bar(market: String, interval: CandleInterval, candle: Candle)
    case unavailable(String)
}

/// Provider boundary: wire format/reconnection belongs to the source; preference belongs to the router.
protocol PublicMarketSource: Sendable {
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) async
    func close() async
}

/// Pure routing state, serialized by WebSocketManager. Both providers feed the same SDK event bus.
struct MarketDataRouter {
    var preference: MarketDataPreference = .arca
    private var mapping: [String: String] = [:]
    private struct Interest { var revision: UInt64 = 0; var markets: Set<String> = [] }
    private var interests: [UUID: Interest] = [:]
    private struct BarKey: Hashable { let market: String; let interval: CandleInterval }
    private var candles: [BarKey: Int] = [:]
    private var quoteTimes: [String: Int] = [:]
    private var bars: [BarKey: Candle] = [:]
    private var closedBars: [BarKey: Int] = [:]
    private(set) var subscriptions: Set<PublicMarketSubscription> = []
    private(set) var lastError: String?

    mutating func configure(_ preference: MarketDataPreference, markets: [Market]) {
        self.preference = preference
        let valid = markets.filter {
            $0.name.range(of: "^hl:[0-9]+:[^:\\s]+$", options: .regularExpression) != nil && !($0.venueSymbol ?? "").isEmpty
        }
        // Exact metadata mapping. Never reconstruct venue symbols from a display ticker/dex index.
        let unique = Dictionary(grouping: valid, by: { $0.venueSymbol! }).values.filter { $0.count == 1 }.flatMap { $0 }
        mapping = Dictionary(uniqueKeysWithValues: Dictionary(grouping: unique, by: \.name).values.filter { $0.count == 1 }.map { ($0[0].name, $0[0].venueSymbol!) })
        unavailable(nil)
        refresh()
    }
    mutating func register(_ owner: UUID) { interests[owner] = Interest() }
    mutating func update(_ owner: UUID, markets: Set<String>, revision: UInt64) {
        guard let current = interests[owner], revision >= current.revision else { return }
        interests[owner] = Interest(revision: revision, markets: markets)
        refresh()
    }
    mutating func release(_ owner: UUID) { interests.removeValue(forKey: owner); refresh() }
    mutating func acquireCandles(_ markets: [String], intervals: [CandleInterval]) {
        for market in markets { for interval in intervals { candles[BarKey(market: market, interval: interval), default: 0] += 1 } }
        refresh()
    }
    mutating func releaseCandles(_ markets: [String], intervals: [CandleInterval]) {
        for market in markets { for interval in intervals {
            let key = BarKey(market: market, interval: interval)
            let count = (candles[key] ?? 0) - 1
            if count <= 0 { candles.removeValue(forKey: key) } else { candles[key] = count }
        } }
        refresh()
    }
    func candleRetained(_ market: String, interval: CandleInterval) -> Bool { (candles[BarKey(market: market, interval: interval)] ?? 0) > 0 }
    private mutating func refresh() {
        var wanted: [PublicMarketSubscription] = []
        if preference == .hyperliquid {
            for market in Set(interests.values.flatMap { $0.markets }).sorted() {
                if let coin = mapping[market] { wanted.append(PublicMarketSubscription(market: market, coin: coin)) }
            }
            for key in candles.keys.sorted(by: { ($0.market, $0.interval.rawValue) < ($1.market, $1.interval.rawValue) }) {
                if key.interval != .fifteenSeconds, let coin = mapping[key.market] {
                    wanted.append(PublicMarketSubscription(market: key.market, coin: coin, interval: key.interval))
                }
            }
        }
        // Bound phone network/decode work. Overflow remains subscribed through Arca.
        subscriptions = Set(wanted.prefix(64))
        let quoteMarkets = Set(subscriptions.filter { $0.interval == nil }.map(\.market))
        quoteTimes = quoteTimes.filter { quoteMarkets.contains($0.key) }
        let barKeys = Set(subscriptions.compactMap { s in s.interval.map { BarKey(market: s.market, interval: $0) } })
        bars = bars.filter { barKeys.contains($0.key) }
        closedBars = closedBars.filter { candles[$0.key] != nil }
    }
    mutating func unavailable(_ reason: String?) { quoteTimes.removeAll(); bars.removeAll(); lastError = reason }
    func arcaPrices(_ prices: [String: String]) -> [String: String] { prices.filter { quoteTimes[$0.key] == nil } }
    mutating func arcaCandle(_ event: RealmEvent) -> Bool {
        if event.type == "candle.closed" {
            if let market = event.market, let raw = event.interval, let interval = CandleInterval(rawValue: raw), let candle = event.candle {
                let key = BarKey(market: market, interval: interval)
                if candles[key] != nil { closedBars[key] = max(closedBars[key] ?? 0, candle.t) }
            }
            return true
        }
        guard let market = event.market, let raw = event.interval, let interval = CandleInterval(rawValue: raw),
              let incoming = event.candle else { return true }
        let key = BarKey(market: market, interval: interval)
        if incoming.t <= (closedBars[key] ?? 0) { return false }
        guard let direct = bars[key] else { return true }
        return incoming.t > direct.t
    }
    mutating func direct(_ update: PublicMarketUpdate, nowMs: Int) -> RealmEvent? {
        switch update {
        case .unavailable(let reason): unavailable(reason); return nil
        case let .quote(market, price, timeMs):
            guard subscriptions.contains(where: { $0.market == market && $0.interval == nil }),
                  timeMs > 0, timeMs <= nowMs + 30_000, timeMs >= (quoteTimes[market] ?? 0) else { return nil }
            quoteTimes[market] = timeMs; lastError = nil
            return RealmEvent(type: "mids.updated", mids: [market: price])
        case let .bar(market, interval, candle):
            let key = BarKey(market: market, interval: interval)
            guard subscriptions.contains(where: { $0.market == market && $0.interval == interval }),
                  candle.t > 0, candle.t % interval.milliseconds == 0, candle.t > (closedBars[key] ?? 0),
                  candle.t <= nowMs, candle.t > nowMs - interval.milliseconds else { return nil }
            if let previous = bars[key], candle.t < previous.t || candle.t == previous.t && candle.n < previous.n { return nil }
            bars[key] = candle; lastError = nil
            return RealmEvent(type: "candle.updated", market: market, interval: interval.rawValue, candle: candle)
        }
    }
    var status: MarketDataSourceStatus {
        MarketDataSourceStatus(preference: preference, directSubscriptions: subscriptions.count,
                               directPriceMarkets: Set(quoteTimes.keys), directCandleMarkets: Set(bars.keys.map(\.market)), lastError: lastError)
    }
}

extension Arca {
    /// Choose the public data preference without replacing watches. Arca remains subscribed for
    /// fallback and finalized candles. Metadata is a finite read, never a polling loop.
    public func setMarketDataPreference(_ preference: MarketDataPreference, network: HyperliquidNetwork = .mainnet) async throws {
        let epoch = await ws.beginMarketDataConfiguration()
        let markets = preference == .hyperliquid ? Array(try await ensureMetaLoaded().values) : []
        await ws.configureMarketData(epoch: epoch, preference: preference, network: network, markets: markets)
    }
    public var marketDataSourceStatus: MarketDataSourceStatus { get async { await ws.marketDataSourceStatus } }
}

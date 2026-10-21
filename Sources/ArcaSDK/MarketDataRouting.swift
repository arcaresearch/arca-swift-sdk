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
    var dex: String? = nil
}
enum PublicMarketUpdate: Sendable {
    indirect case received(PublicMarketUpdate, atNanos: UInt64, attemptAtNanos: UInt64? = nil, openedAtNanos: UInt64? = nil)
    case connection(attemptAtNanos: UInt64? = nil, openedAtNanos: UInt64? = nil, retryAtNanos: UInt64? = nil, retryDelayMs: Int? = nil)
    case quote(market: String, price: String, timeMs: Int)
    case mids(dex: String, prices: [String: String])
    case cost(key: String, bytes: Int)
    case bar(market: String, interval: CandleInterval, candle: Candle)
    case unavailable(String)
    case traffic(bytes: Int)
}

/// Provider boundary: wire format/reconnection belongs to the source; preference belongs to the router.
protocol PublicMarketSource: Sendable {
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) async
    func networkAvailable() async
    func close() async
}
extension PublicMarketSource { func networkAvailable() async {} }

/// Whether a string has the shape of a canonical market id (`{exchange}:{native}`,
/// alphabetic exchange prefix) — the only keys a mids map can carry. Used to
/// pick the market-priced rows out of an aggregate's breakdown when declaring
/// price interest; never to construct or guess an id.
func isCanonicalMarketId(_ id: String) -> Bool {
    guard let colon = id.firstIndex(of: ":"), colon > id.startIndex, id.index(after: colon) < id.endIndex else { return false }
    return id[..<colon].allSatisfy(\.isLetter) && !id.contains(where: \.isWhitespace)
}

/// Pure routing state, serialized by WebSocketManager. Both providers feed the same SDK event bus.
struct MarketDataRouter {
    var preference: MarketDataPreference = .arca
    private var mapping: [String: String] = [:]
    private var budget: MarketDataBudget?
    private var costs = PublicFeedCosts()
    private var lastBudgetRefreshMs: Int?
    private var coarseMarkets: Set<String> = []
    var directCoverageMarkets: Set<String> {
        Set(subscriptions.filter { $0.interval == nil && $0.dex == nil }.map(\.market)).union(
            mapping.filter { pair in subscriptions.contains { $0.dex == venueDex(pair.value) } }.keys)
    }
    mutating func setBudget(_ value: MarketDataBudget?) { budget = value; refresh() }
    private struct Interest { var revision: UInt64 = 0; var markets: Set<String> = [] }
    private var interests: [UUID: Interest] = [:]
    var priceInterestMarkets: Set<String> { Set(interests.values.flatMap { $0.markets }) }
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
        let interested = priceInterestMarkets
        if preference == .hyperliquid {
            let priceMapping = mapping.filter { interested.contains($0.key) }
            let candleSubscriptions = candles.keys.sorted { ($0.market, $0.interval.rawValue) < ($1.market, $1.interval.rawValue) }.compactMap { key -> PublicMarketSubscription? in
                guard key.interval != .fifteenSeconds, let coin = mapping[key.market] else { return nil }
                return PublicMarketSubscription(market: key.market, coin: coin, interval: key.interval)
            }.prefix(64)
            if let budget {
                costs.retain(Set(priceMapping.keys).union(priceMapping.values.map { "@" + venueDex($0) }))
                wanted += candleSubscriptions
                wanted += budgetSubscriptions(mapping: priceMapping, budget: budget, costs: costs, previous: subscriptions, slots: 64 - wanted.count)
            } else {
                for market in priceMapping.keys.sorted() { wanted.append(.init(market: market, coin: priceMapping[market]!)) }
                wanted += candleSubscriptions
            }
        }
        subscriptions = Set(wanted.prefix(64))
        let quoteMarkets = Set(subscriptions.filter { $0.interval == nil && $0.dex == nil }.map(\.market))
        quoteTimes = quoteTimes.filter { quoteMarkets.contains($0.key) }
        coarseMarkets = coarseMarkets.intersection(mapping.filter { pair in interested.contains(pair.key) && subscriptions.contains { $0.dex == venueDex(pair.value) } }.keys)
        let barKeys = Set(subscriptions.compactMap { s in s.interval.map { BarKey(market: s.market, interval: $0) } })
        bars = bars.filter { barKeys.contains($0.key) }
        closedBars = closedBars.filter { candles[$0.key] != nil }
    }
    mutating func unavailable(_ reason: String?) { quoteTimes.removeAll(); coarseMarkets.removeAll(); bars.removeAll(); lastError = reason }
    func arcaPrices(_ prices: [String: String]) -> [String: String] { prices.filter { quoteTimes[$0.key] == nil && !coarseMarkets.contains($0.key) } }
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
    mutating func direct(_ update: PublicMarketUpdate, nowMs: Int, costNowMs: Int? = nil) -> RealmEvent? {
        switch update {
        case .traffic, .received, .connection: return nil
        case let .cost(key, bytes):
            let clock = costNowMs ?? nowMs
            if costs.record(key, bytes: bytes, nowMs: clock), lastBudgetRefreshMs.map({ clock - $0 >= 10_000 }) ?? true {
                lastBudgetRefreshMs = clock; refresh()
            }
            return nil
        case let .mids(dex, prices):
            guard subscriptions.contains(where: { $0.dex == dex }) else { return nil }
            let interested = priceInterestMarkets
            let mids = Dictionary(uniqueKeysWithValues: mapping.compactMap { market, coin -> (String, String)? in
                guard interested.contains(market), venueDex(coin) == dex, quoteTimes[market] == nil, let price = prices[coin] else { return nil }
                return (market, price)
            })
            coarseMarkets.formUnion(mids.keys)
            guard !mids.isEmpty else { return nil }
            lastError = nil
            return RealmEvent(type: "mids.updated", mids: mids)
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
                               directPriceMarkets: Set(quoteTimes.keys).union(coarseMarkets), directCandleMarkets: Set(bars.keys.map(\.market)), lastError: lastError)
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

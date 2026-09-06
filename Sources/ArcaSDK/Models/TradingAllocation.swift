import Foundation

/// Arca capital-allocation intent. This setting does not change venue liquidation.
public enum LeveragePreferenceMode: String, Codable, Sendable {
    case venueDefault = "venue-default"
    case fixed
}

public struct TradingLeveragePreference: Codable, Sendable {
    public let mode: LeveragePreferenceMode
    /// Original fixed intent, preserved across venue cap changes and closure.
    public let leverage: Int?
}

public struct PositionAllocation: Codable, Sendable {
    public let market: String
    public let preference: TradingLeveragePreference
    public let effectiveLeverage: Int
    public let venueInitialMargin: String
    public let allocatedMargin: String
    public let extraMargin: String
    public let reservedMargin: String
    public let reservedExtra: String
}

public struct TradingAllocationProjection: Codable, Sendable {
    public let revision: String
    public let positions: [String: PositionAllocation]
    public let venueInitialMargin: String
    public let positionAllocatedMargin: String
    public let allocatedMargin: String
    public let extraMargin: String
    public let pendingMargin: String
    public let pendingCosts: String
    public let reservedExtra: String
    public let availableToTrade: String
}

public struct TradingAllocationState: Codable, Sendable {
    public let asOf: String?
    public let validUntil: String?
    public let revision: String
    /// Preferences remain present when a market is flat.
    public let preferences: [String: TradingLeveragePreference]
    public let projection: TradingAllocationProjection?
    /// A missing projection means unavailable risk facts, never zero margin.
    public let projectionUnavailable: Bool
}

public struct TradingLeverageSelection: Codable, Sendable {
    public let mode: LeveragePreferenceMode?
    public let leverage: Int?
    public init(mode: LeveragePreferenceMode? = nil, leverage: Int? = nil) {
        self.mode = mode; self.leverage = leverage
    }
}

public struct TradingAllocationRead: Codable, Sendable {
    public let enabled: Bool
    public let inputId: String
    public let allocation: TradingAllocationState
    public let unavailableReason: String?
}

/// Estimates only. Market quotes use the mirror mark; limit quotes require price.
public struct TradingAllocationQuoteRequest: Codable, Sendable {
    public let market: String
    public let side: OrderSide
    /// Lowercase "market" or "limit".
    public let orderType: String
    public let price: String?
    public let size: String?
    public let slippageBps: Int?
    public let reduceOnly: Bool
    public let selection: TradingLeverageSelection
    public init(market: String, side: OrderSide, orderType: String, price: String? = nil, size: String? = nil, slippageBps: Int? = nil, reduceOnly: Bool = false, selection: TradingLeverageSelection = .init()) {
        self.market = market; self.side = side; self.orderType = orderType
        self.price = price; self.size = size; self.slippageBps = slippageBps
        self.reduceOnly = reduceOnly; self.selection = selection
    }
}

public struct TradingAllocationMaximum: Codable, Sendable {
    public let revision: String
    public let maxSize: String
    public let maxNotional: String
    public let projection: TradingAllocationProjection?
}

public struct TradingAllocationQuote: Codable, Sendable {
    public let inputId: String
    public let market: String
    public let referencePrice: String
    public let limitPrice: String
    public let allocation: TradingAllocationState
    public let maximum: TradingAllocationMaximum
    public let affordable: Bool?
    public let orderProjection: TradingAllocationProjection?
}

public extension TradingAllocationState {
    /// Remaining observation lifetime, capped by the server's original budget.
    /// Nil supports older payloads without a deadline; invalid dates are expired.
    func remainingValidity(at now: Date = Date()) -> TimeInterval? {
        guard let validUntil else { return nil }
        func parse(_ raw: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        guard let until = parse(validUntil) else { return 0 }
        guard let asOf else { return max(0, until.timeIntervalSince(now)) }
        guard let observed = parse(asOf) else { return 0 }
        return max(0, min(until.timeIntervalSince(now), until.timeIntervalSince(observed)))
    }
}

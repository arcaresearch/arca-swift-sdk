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
    public let revision: String
    /// Preferences remain present when a market is flat.
    public let preferences: [String: TradingLeveragePreference]
    public let projection: TradingAllocationProjection?
    /// A missing projection means unavailable risk facts, never zero margin.
    public let projectionUnavailable: Bool
}

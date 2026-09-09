import Foundation

public struct ExchangeCapabilities: Codable, Sendable, Equatable {
    public let objectId: String
    public let orderTypes: [String]
    public let timeInForce: [String]
    public let marginModes: [String]
    public let leverageSelection: Bool
    public let positionTriggers: Bool
    public let brackets: Bool
    public let orderKeyRetirement: Bool
}

extension Arca {
    /// Account-adapter authority for optional controls. Unknown is not unsupported.
    public func getExchangeCapabilities(objectId: String) async throws -> ExchangeCapabilities {
        let result: ExchangeCapabilities = try await client.get("/objects/\(objectId)/exchange/capabilities")
        guard result.objectId == objectId else { throw OrderSizingError.missingMarket }
        return result
    }
}

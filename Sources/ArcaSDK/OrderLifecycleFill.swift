import Foundation

/// Canonical fill bytes from the original-order server projection.
public struct OrderLifecycleFill: Codable, Sendable, Equatable {
    public let id: String
    public let orderId: String
    public let realmId: String
    public let objectId: String
    public let operationId: String
    public let leg: String
    public let accountId: String
    public let market: String
    public let side: String
    public let size: String
    public let price: String
    public let fee: String
    public let platformFee: String?
    public let builderFee: String?
    public let realizedPnl: String?
    public let createdAt: String?
    var fill: SimFill {
        SimFill(id: SimFillID(id), orderId: SimOrderID(orderId), cloid: nil,
            accountId: SimAccountID(accountId), realmId: RealmID(realmId), market: market,
            side: OrderSide(rawValue: side)!, price: price, size: size, fee: fee, builderFee: builderFee,
            platformFee: platformFee, realizedPnl: realizedPnl, isLiquidation: false, createdAt: createdAt)
    }
}

import Foundation

/// The retained operation identity; neither form submits an order.
public enum OriginalOrderReference: Sendable {
    case id(String)
    case path(String)
}

public struct OrderLifecycleIntent: Codable, Sendable, Equatable {
    public let realmId: String
    public let objectId: String
    public let operationId: String
    public let leg: String
    public let venue: String
    public let venueAccountId: String
    public let market: String
    public let requestedSize: String
    public let orderType: String
    public let side: String
    public let timeInForce: String
    public let executionTimeInForce: String?
    public let clientOrderId: String?
    public let requestRef: String?
    public let price: String?
    public let triggerKind: String?
    public let triggerPrice: String?
    public let ocoGroupId: String?
    public let isTrigger: Bool
    public let isMarketTrigger: Bool
    public let sizeToMax: Bool
    public let reduceOnly: Bool
}

public struct OrderLifecycle: Codable, Sendable, Equatable {
    public let intent: OrderLifecycleIntent
    public let venueOrderId: String?
    public let submission: String
    public let working: Bool
    public let execution: String
    public let terminal: Bool
    public let executedSize: String
    public let executionQuantityFinal: Bool
    public let requestedSizeKnown: Bool
    public let remainingSize: String?
    public let remainingDisposition: String
    public let accountedSize: String
    public let accountingComplete: Bool
    public let averagePrice: String?
    public let averagePriceFinal: Bool
    public let recoveryRequired: Bool
    public let executionReceipt: OrderLifecycleReceipt?
    public let committedFills: [OrderLifecycleFill]?
}

private struct OrderLifecycleResponse: Decodable { let lifecycle: OrderLifecycle }

extension OrderLifecycle {
    func validate(realm: String, objectId: String, operationId: String?, leg: Int) throws {
        guard intent.realmId == realm, intent.objectId == objectId,
              !intent.operationId.isEmpty, intent.operationId.count <= 128,
              operationId == nil || intent.operationId == operationId,
              intent.leg == String(leg), !intent.venue.isEmpty, !intent.venueAccountId.isEmpty,
              !intent.market.isEmpty, ["MARKET", "LIMIT"].contains(intent.orderType),
              ["buy", "sell"].contains(intent.side) else {
            throw ArcaError.validation(message: "Original order evidence does not match the requested account and operation", errorId: nil)
        }
        for fill in committedFills ?? [] {
            guard !fill.id.isEmpty, fill.realmId == realm, fill.objectId == objectId,
                  fill.operationId == intent.operationId, fill.leg == intent.leg,
                  fill.accountId == intent.venueAccountId, !fill.orderId.isEmpty, fill.orderId == venueOrderId,
                  fill.market == intent.market, fill.side == intent.side,
                  [fill.size, fill.price].allSatisfy({ $0.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil }) else {
                throw ArcaError.validation(message: "Committed fill does not match original order", errorId: nil)
            }
        }
        if let receipt = executionReceipt {
            guard receipt.objectId == objectId, receipt.operationId == intent.operationId, receipt.leg == intent.leg,
                  receipt.market == intent.market, receipt.orderId == (venueOrderId ?? ""), receipt.filledSize == executedSize,
                  receipt.fillsComplete == accountingComplete, receipt.averagePriceFinal == averagePriceFinal else {
                throw ArcaError.validation(message: "Original order receipt does not match its server view", errorId: nil)
            }
        }
        let quantities = [intent.requestedSize, executedSize, accountedSize] + [remainingSize, averagePrice].compactMap { $0 }
        guard quantities.allSatisfy({ $0.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil }) else {
            throw ArcaError.validation(message: "Original order quantity is invalid", errorId: nil)
        }
    }
}

extension Arca {
    /// Read the server's execution and accounting projection after placement or reconnect.
    /// Amounts remain exact strings. This method never repeats placement.
    public func getOrderLifecycle(objectId: String, operation: OriginalOrderReference, leg: Int = 0) async throws -> OrderLifecycle {
        guard !objectId.isEmpty, objectId.count <= 128, leg >= 0 else {
            throw ArcaError.validation(message: "An account and a nonnegative original order leg are required", errorId: nil)
        }
        var query = ["leg": String(leg)]
        let expectedId: String?
        switch operation {
        case .id(let id):
            guard !id.isEmpty, id.count <= 128 else { throw ArcaError.validation(message: "Original operation ID is required", errorId: nil) }
            query["operationId"] = id; expectedId = id
        case .path(let path):
            guard path.hasPrefix("/"), path.count <= 1024 else { throw ArcaError.validation(message: "Original absolute operation path is required", errorId: nil) }
            query["operationPath"] = path; expectedId = nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let escapedId = objectId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ArcaError.validation(message: "Invalid account ID", errorId: nil)
        }
        let response: OrderLifecycleResponse = try await client.get("/objects/\(escapedId)/exchange/order-lifecycle", query: query)
        try response.lifecycle.validate(realm: realm, objectId: objectId, operationId: expectedId, leg: leg)
        return response.lifecycle
    }
}

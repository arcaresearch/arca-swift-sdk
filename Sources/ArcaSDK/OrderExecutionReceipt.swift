import Foundation

/// Execution proof is separate from complete order metadata and journaled fills.
public struct OrderExecutionReceipt: Codable, Sendable {
    public let objectId: String
    public let operationId: String
    public let orderId: String
    public let status: String
    public let filledSize: String
    public let requestedSize: String?
    public let remainingSize: String?
    public let executionState: String
    public let fulfillmentState: String
    public let remainingDisposition: String
    public let avgFillPrice: String?
    public let averagePriceFinal: Bool
    public let averagePriceSource: String
    public let fillsComplete: Bool

    /// Restore an execution receipt received from your backend or persistence.
    public init(objectId: String, operationId: String, orderId: String, status: String,
                filledSize: String, requestedSize: String? = nil, remainingSize: String? = nil,
                executionState: String, fulfillmentState: String, remainingDisposition: String,
                avgFillPrice: String? = nil, averagePriceFinal: Bool = false,
                averagePriceSource: String = "venue_aggregate", fillsComplete: Bool = false) {
        self.objectId = objectId
        self.operationId = operationId
        self.orderId = orderId
        self.status = status
        self.filledSize = filledSize
        self.requestedSize = requestedSize
        self.remainingSize = remainingSize
        self.executionState = executionState
        self.fulfillmentState = fulfillmentState
        self.remainingDisposition = remainingDisposition
        self.avgFillPrice = avgFillPrice
        self.averagePriceFinal = averagePriceFinal
        self.averagePriceSource = averagePriceSource
        self.fillsComplete = fillsComplete
    }

    static func decimal(_ text: String?) -> Decimal? {
        guard let text, text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let digits = text.filter { $0 != "." }.drop(while: { $0 == "0" })
        // Foundation Decimal has 38 significant digits. Refuse precision loss.
        guard digits.count <= 38 else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func from(_ operation: Operation, objectId: String, update: OrderExecutionUpdate.Value? = nil, originalInput: String? = nil) -> Self? {
        guard operation.state == .completed || update != nil else { return nil }
        struct Intent: Decodable {
            let exchangeObjectId: String?
            let size: String?
            let timeInForce: String?
            struct Prepared: Decodable {
                struct Request: Decodable { let Effect: Int? }
                let request: Request
            }
            let gllPrepared: Prepared?
        }
        func parseIntent(_ value: String?) -> Intent? {
            value.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Intent.self, from: $0) }
        }
        let observedIntent = parseIntent(operation.input)
        if let account = observedIntent?.exchangeObjectId, account != objectId { return nil }
        let intent = originalInput == nil ? observedIntent : parseIntent(originalInput)
        if let account = intent?.exchangeObjectId, account != objectId { return nil }
        let value = update ?? operation.outcome.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(OrderExecutionUpdate.Value.self, from: $0) }
        guard let value, let orderId = value.orderId ?? value.id, !orderId.isEmpty,
              let quantity = decimal(value.filledSize) else { return nil }
        let rawStatus = value.status.uppercased()
        let status = rawStatus == "REJECTED" ? "FAILED" : ["EXPIRED", "CANCELED"].contains(rawStatus) ? "CANCELLED" : rawStatus
        guard ["FILLED", "CANCELLED", "FAILED", "REJECTED"].contains(status) else { return nil }
        let requested = decimal(intent?.size)
        let partial = requested.map { quantity < $0 } ?? false
        let ioc = intent?.timeInForce == "IOC" || intent?.gllPrepared?.request.Effect == 1
        let cancelled = ["CANCELLED", "FAILED", "REJECTED"].contains(status) || ioc && partial
        guard status != "FILLED" || quantity > 0 || cancelled else { return nil }
        let fulfillment = requested == nil ? "unknown" : quantity == 0 ? "none" : partial ? "partial" : "full"
        let remaining = requested.flatMap { $0 >= quantity ? NSDecimalNumber(decimal: $0 - quantity).stringValue : nil }
        return Self(objectId: objectId, operationId: operation.id.rawValue, orderId: orderId, status: status, filledSize: value.filledSize,
                    requestedSize: requested == nil ? nil : intent?.size, remainingSize: remaining,
                    executionState: quantity == 0 ? (["FAILED", "REJECTED"].contains(status) ? "rejected" : "no_fill") : partial || cancelled ? "partial" : "filled",
                    fulfillmentState: fulfillment, remainingDisposition: cancelled ? "cancelled" : fulfillment == "full" ? "filled" : "unknown",
                    avgFillPrice: decimal(value.avgFillPrice) == nil ? nil : value.avgFillPrice,
                    averagePriceFinal: false, averagePriceSource: "venue_aggregate", fillsComplete: false)
    }
}

/// Sparse venue evidence, deliberately not decoded as a complete SimOrder.
public struct OrderExecutionUpdate: Codable, Sendable {
    public struct Value: Codable, Sendable {
        public let id: String?
        public let orderId: String?
        public let status: String
        public let filledSize: String
        public let avgFillPrice: String?
    }
    public let order: Value
    public let fillsComplete: Bool?
}

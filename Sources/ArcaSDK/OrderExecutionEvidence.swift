import Foundation

/// Serializes identity learned from HTTP with account-scoped pushes that can
/// precede it. Original intent is immutable even when venue history is rewritten.
actor OrderExecutionEvidence {
    let operation: Operation
    let objectId: String
    private(set) var orderId: String?
    private var early: [RealmEvent] = []

    init(operation: Operation, objectId: String, orderId: String?) {
        self.operation = operation
        self.objectId = objectId
        self.orderId = orderId
    }

    private func belongs(_ candidate: Operation) -> Bool {
        guard candidate.id == operation.id else { return false }
        guard let raw = candidate.input else { return true }
        guard let data = raw.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (input["exchangeObjectId"] as? String).map { $0 == objectId } ?? true
    }

    func receive(_ event: RealmEvent) throws -> OrderExecutionReceipt? {
        if let candidate = event.operation, belongs(candidate) {
            if candidate.state == .failed || candidate.state == .expired {
                throw ArcaError.operationFailed(operation: candidate)
            }
            if let receipt = OrderExecutionReceipt.from(candidate, objectId: objectId, originalInput: operation.input),
               orderId == nil || receipt.orderId == orderId { return receipt }
            if orderId == nil, let raw = candidate.outcome?.data(using: .utf8),
               let outcome = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let learned = outcome["orderId"] as? String, !learned.isEmpty {
                orderId = learned
                if let receipt = try replay() { return receipt }
            }
        }
        guard event.entityId == objectId, let update = event.order?.order else { return nil }
        guard let orderId else {
            if early.count == 256 { early.removeFirst() }
            early.append(event)
            return nil
        }
        guard (update.orderId ?? update.id) == orderId else { return nil }
        return OrderExecutionReceipt.from(operation, objectId: objectId, update: update)
    }

    func snapshot(_ detail: SimOrderWithFills) throws -> OrderExecutionReceipt? {
        guard orderId == nil || detail.order.id.rawValue == orderId else { return nil }
        orderId = detail.order.id.rawValue
        if let receipt = try replay() { return receipt }
        return OrderExecutionReceipt.from(operation, objectId: objectId,
            update: .init(id: detail.order.id.rawValue, orderId: detail.order.id.rawValue, status: detail.order.status.rawValue,
                          filledSize: detail.order.filledSize, avgFillPrice: detail.order.avgFillPrice))
    }

    private func replay() throws -> OrderExecutionReceipt? {
        let buffered = early
        early.removeAll()
        for event in buffered { if let receipt = try receive(event) { return receipt } }
        return nil
    }
}

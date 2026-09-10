import Foundation

/// A complete server projection, or an explicit loss of current evidence.
public struct OrderLifecycleUpdate: Sendable {
    public let lifecycle: OrderLifecycle?
    public let unavailable: Bool
    public let recoverable: Bool
    public let reason: String?
}

/// A read-only attachment to one retained operation and leg. Slow readers see
/// the latest complete projection. Stopping releases the server attachment.
public struct OrderLifecycleWatch: Sendable {
    public let updates: AsyncStream<OrderLifecycleUpdate>
    private let cancel: @Sendable () async -> Void

    init(updates: AsyncStream<OrderLifecycleUpdate>, cancel: @escaping @Sendable () async -> Void) {
        self.updates = updates; self.cancel = cancel
    }
    public func stop() async { await cancel() }
}

// Confined to the WebSocketManager actor; this is transport state, not a second
// order ledger. Neither this registration nor recovery can place an order.
final class OrderLifecycleRegistration {
    let realm: String, objectId: String, operationId: String
    let leg: Int
    let snapshotTimeoutNs: UInt64
    let continuation: AsyncStream<OrderLifecycleUpdate>.Continuation
    var requestId = ""
    var original: OrderLifecycleIntent?
    var deadline: Task<Void, Never>?
    var retry: Task<Void, Never>?
    var retryNs: UInt64 = 250_000_000

    init(realm: String, objectId: String, operationId: String, leg: Int, snapshotTimeoutNs: UInt64,
         continuation: AsyncStream<OrderLifecycleUpdate>.Continuation) {
        self.realm = realm; self.objectId = objectId; self.operationId = operationId
        self.leg = leg; self.snapshotTimeoutNs = snapshotTimeoutNs; self.continuation = continuation
    }
}

private struct OrderLifecycleFrame: Decodable {
    let type: String
    let watchId: String?
    let requestId: String
    let realmId: String?
    let objectId: String?
    let operationId: String?
    let leg: String?
    let lifecycle: OrderLifecycle?
    let unavailable: Bool?
    let recoverable: Bool?
    let reason: String?
    let message: String?
}

extension WebSocketManager {
    func watchOrderLifecycle(realm: String, objectId: String, operationId: String, leg: Int,
                             snapshotTimeoutNs: UInt64 = 45_000_000_000) throws -> OrderLifecycleWatch {
        guard orderLifecycleReaders.count < 16 else {
            throw ArcaError.validation(message: "At most 16 original order watches may be attached", errorId: nil)
        }
        let id = "order-lifecycle-" + UUID().uuidString
        let stream = AsyncStream<OrderLifecycleUpdate>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in Task { await self?.stopOrderLifecycleWatch(id) } }
            orderLifecycleReaders[id] = OrderLifecycleRegistration(realm: realm, objectId: objectId,
                operationId: operationId, leg: leg, snapshotTimeoutNs: snapshotTimeoutNs, continuation: continuation)
        }
        orderLifecycleInterestChanged(starting: true)
        attachOrderLifecycle(id)
        return OrderLifecycleWatch(updates: stream) { [weak self] in await self?.stopOrderLifecycleWatch(id) }
    }

    func stopOrderLifecycleWatch(_ id: String) {
        guard let entry = orderLifecycleReaders.removeValue(forKey: id) else { return }
        entry.deadline?.cancel(); entry.retry?.cancel()
        sendOrderLifecycleMessage(.unwatchOrderLifecycle(watchId: id))
        entry.continuation.finish()
        orderLifecycleInterestChanged(starting: false)
    }

    func stopOrderLifecycleWatches() {
        for id in Array(orderLifecycleReaders.keys) { stopOrderLifecycleWatch(id) }
    }

    func reattachOrderLifecycleWatches() {
        for id in Array(orderLifecycleReaders.keys) { attachOrderLifecycle(id) }
    }

    func recoverOrderLifecycleWatches() {
        for id in Array(orderLifecycleReaders.keys) { scheduleOrderLifecycleRecovery(id, after: 0) }
    }

    private func attachOrderLifecycle(_ id: String) {
        guard let entry = orderLifecycleReaders[id] else { return }
        entry.deadline?.cancel(); entry.retry?.cancel(); entry.retry = nil
        let requestId = id + "/" + UUID().uuidString
        entry.requestId = requestId
        let timeout = entry.snapshotTimeoutNs
        entry.deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            await self?.orderLifecycleTimeout(id, requestId: requestId)
        }
        guard status == .connected else { return }
        sendOrderLifecycleMessage(.watchOrderLifecycle(watchId: id, requestId: requestId,
            objectId: entry.objectId, operationId: entry.operationId, leg: String(entry.leg)))
    }

    private func orderLifecycleTimeout(_ id: String, requestId: String) {
        guard orderLifecycleReaders[id]?.requestId == requestId else { return }
        orderLifecycleUnavailable(id, reason: "snapshot_timeout", recoverable: true)
    }

    private func scheduleOrderLifecycleRecovery(_ id: String, after delay: UInt64) {
        guard let entry = orderLifecycleReaders[id], entry.retry == nil else { return }
        let requestId = entry.requestId
        entry.retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.retryOrderLifecycle(id, requestId: requestId)
        }
    }

    private func retryOrderLifecycle(_ id: String, requestId: String) {
        guard orderLifecycleReaders[id]?.requestId == requestId else { return }
        attachOrderLifecycle(id)
    }

    private func orderLifecycleUnavailable(_ id: String, reason: String?, recoverable: Bool) {
        guard let entry = orderLifecycleReaders[id] else { return }
        entry.deadline?.cancel(); entry.deadline = nil
        entry.continuation.yield(OrderLifecycleUpdate(lifecycle: nil, unavailable: true, recoverable: recoverable, reason: reason))
        if recoverable {
            scheduleOrderLifecycleRecovery(id, after: entry.retryNs)
            entry.retryNs = min(entry.retryNs * 2, 10_000_000_000)
        } else { stopOrderLifecycleWatch(id) }
    }

    func deliverOrderLifecycle(_ data: Data, json: [String: Any]) -> Bool {
        let kind = json["type"] as? String ?? ""
        let requestId = json["requestId"] as? String ?? ""
        guard kind == "order.lifecycle.updated" || kind == "order_lifecycle_watch_created" ||
              (kind == "error" && requestId.hasPrefix("order-lifecycle-")) else { return false }
        if let seq = json["deliverySeq"] as? Int { checkDeliveryGap(seq) }
        // Stale attachment replies, including errors, must not affect another
        // watch or the healthy connection after rotation/disposal.
        guard let (id, entry) = orderLifecycleReaders.first(where: { $0.value.requestId == requestId }) else { return true }
        guard let frame = try? JSONDecoder().decode(OrderLifecycleFrame.self, from: data) else {
            orderLifecycleUnavailable(id, reason: "invalid_order_evidence", recoverable: false); return true
        }
        if kind == "order_lifecycle_watch_created" { return true } // ACK is not a snapshot.
        if kind == "error" {
            orderLifecycleUnavailable(id, reason: frame.message, recoverable: false); return true
        }
        guard frame.watchId == id, frame.realmId == entry.realm, frame.objectId == entry.objectId,
              frame.operationId == entry.operationId, frame.leg == String(entry.leg) else { return true }
        if frame.unavailable == true {
            orderLifecycleUnavailable(id, reason: frame.reason, recoverable: frame.recoverable == true); return true
        }
        guard let view = frame.lifecycle,
              (try? view.validate(realm: entry.realm, objectId: entry.objectId, operationId: entry.operationId, leg: entry.leg)) != nil else {
            orderLifecycleUnavailable(id, reason: "invalid_order_evidence", recoverable: false); return true
        }
        guard entry.original == nil || entry.original == view.intent else {
            orderLifecycleUnavailable(id, reason: "original_intent_changed", recoverable: false); return true
        }
        entry.original = view.intent
        entry.deadline?.cancel(); entry.deadline = nil
        entry.retryNs = 250_000_000
        // A normal frame does not cancel recovery already required by a gap.
        entry.continuation.yield(OrderLifecycleUpdate(lifecycle: view, unavailable: false, recoverable: false, reason: nil))
        return true
    }
}

extension Arca {
    /// Subscribe to an original order. Path lookup happens once; every reconnect
    /// then uses the same immutable operation ID and leg. No placement is retried.
    public func watchOrderLifecycle(objectId: String, operation: OriginalOrderReference, leg: Int = 0) async throws -> OrderLifecycleWatch {
        guard !objectId.isEmpty, objectId.count <= 128, leg >= 0 else {
            throw ArcaError.validation(message: "An account and a nonnegative original order leg are required", errorId: nil)
        }
        let operationId: String
        switch operation {
        case .id(let id): operationId = id
        case .path:
            operationId = try await getOrderLifecycle(objectId: objectId, operation: operation, leg: leg).intent.operationId
        }
        guard !operationId.isEmpty, operationId.count <= 128 else {
            throw ArcaError.validation(message: "Original operation ID is required", errorId: nil)
        }
        try Task.checkCancellation()
        let watch = try await ws.watchOrderLifecycle(realm: realm, objectId: objectId, operationId: operationId, leg: leg)
        do { try Task.checkCancellation(); return watch }
        catch { await watch.stop(); throw error }
    }
}

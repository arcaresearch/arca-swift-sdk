import Foundation

/// Retains execution evidence across submission/settlement. Starting this capture
/// installs local observers before POST without waiting for a network ACK.
actor OrderEventCapture {
    private let ws: WebSocketManager
    private var setup: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var operation: Operation?
    private var objectId: String?
    private var acquired = false
    private var closed = false
    private var replay: [RealmEvent] = []
    private var observers: [UUID: AsyncStream<RealmEvent>.Continuation] = [:]
    private let mapOperation: @Sendable (Operation) -> Operation
    init(ws: WebSocketManager, mapOperation: @escaping @Sendable (Operation) -> Operation = { $0 }) {
        self.ws = ws
        self.mapOperation = mapOperation
    }
    func submit(objectId: String, action: @Sendable () async throws -> OrderOperationResponse) async throws -> OrderOperationResponse {
        await start()
        do {
            try Task.checkCancellation()
            let response = try await action()
            await submitted(response.operation, objectId: objectId)
            return response
        } catch { await stop(); throw error }
    }
    func start() async {
        if setup == nil { setup = Task { await install() } }
        await setup?.value
    }
    private func install() async {
        guard !closed else { return }
        let input = await ws.orderExecutionEvents()
        guard !closed else { return }
        await ws.watchPath("/")
        if closed { await ws.unwatchPath("/"); return }
        acquired = true
        consumer = Task { [weak self] in
            for await event in input {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
    }
    func submitted(_ operation: Operation, objectId: String) async {
        let operation = mapOperation(operation)
        self.operation = operation; self.objectId = objectId
        if OrderExecutionReceipt.from(operation, objectId: objectId) != nil || operation.state == .failed || operation.state == .expired || replay.contains(where: terminal) { await stop() }
    }
    private func terminal(_ event: RealmEvent) -> Bool {
        guard let operation, let objectId else { return false }
        struct Identity: Decodable { let orderId: String? }
        let orderId = operation.outcome.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Identity.self, from: $0).orderId }
        if let update = event.operation, update.id == operation.id {
            if let raw = update.input {
                guard let data = raw.data(using: .utf8), let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                if let account = input["exchangeObjectId"] as? String, account != objectId { return false }
            }
            if update.state == .failed || update.state == .expired { return true }
            if let receipt = OrderExecutionReceipt.from(update, objectId: objectId, originalInput: operation.input),
               orderId == nil || receipt.orderId == orderId { return true }
        }
        guard let orderId, event.entityId == objectId, let update = event.order?.order, (update.orderId ?? update.id) == orderId else { return false }
        return OrderExecutionReceipt.from(operation, objectId: objectId, update: update) != nil
    }
    private func receive(_ event: RealmEvent) async {
        guard !closed else { return }
        let event = event.operation.map { event.withOperation(mapOperation($0)) } ?? event
        if replay.count == 256 { replay.removeFirst() }
        replay.append(event)
        for observer in observers.values { observer.yield(event) }
        if terminal(event) { await stop() }
    }
    func fillEvents() async -> AsyncStream<(SimFill, RealmEvent)> {
        // Register live delivery before copying replay; overlapping delivery is
        // intentional and is deduplicated by stable execution identity.
        let live = await ws.fillEvents()
        await ws.watchPath("/")
        let captured = replay.compactMap { event in event.executionFill.map { ($0, event) } }
        let ws = self.ws
        return AsyncStream { continuation in
            let task = Task {
                for value in captured { continuation.yield(value) }
                for await value in live { continuation.yield(value) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await ws.unwatchPath("/") }
            }
        }
    }
    func awaitReady() async throws {
        await start()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await ws.awaitPathReady("/")
    }
    func events() -> AsyncStream<RealmEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            for event in replay { continuation.yield(event) }
            if closed { continuation.finish(); return }
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }
    private func remove(_ id: UUID) { observers.removeValue(forKey: id) }
    func stop() async {
        guard !closed else { return }
        closed = true
        consumer?.cancel()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
        if acquired { acquired = false; await ws.unwatchPath("/") }
    }
}

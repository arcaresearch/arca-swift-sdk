import XCTest
@testable import ArcaSDK

final class OrderLifecycleWatchTests: XCTestCase {
    private let wire = #"{"intent":{"realmId":"realm","objectId":"account","operationId":"original","leg":"0","venue":"gll-testnet","venueAccountId":"123","market":"gllt:3","requestedSize":"9007199254740993.123456789","orderType":"MARKET","side":"buy","timeInForce":"GTC","executionTimeInForce":"IOC","isTrigger":false,"isMarketTrigger":false,"sizeToMax":false,"reduceOnly":false},"venueOrderId":"3:order","submission":"accepted","working":false,"execution":"partial","terminal":true,"executedSize":"3.123456789","executionQuantityFinal":true,"requestedSizeKnown":true,"remainingSize":"9007199254740990","remainingDisposition":"canceled","accountedSize":"0","accountingComplete":false,"averagePrice":"2000.000000001","averagePriceFinal":false,"recoveryRequired":false}"#

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { XCTFail("Condition did not become true", file: file, line: line); throw CancellationError() }
    }
    private func requests(_ socket: MockWebSocketTransport) -> [[String: Any]] {
        socket.sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "watch_order_lifecycle" }
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    private func frame(_ request: [String: Any], seq: Int, view: String? = nil) throws -> String {
        try json(["type": "order.lifecycle.updated", "watchId": request["watchId"]!, "requestId": request["requestId"]!,
                  "realmId": "realm", "objectId": "account", "operationId": "original", "leg": "0", "deliverySeq": seq,
                  "lifecycle": try JSONSerialization.jsonObject(with: Data((view ?? wire).utf8))])
    }
    private func setup(timeout: UInt64 = 150_000_000) async throws -> (WebSocketManager, MockTransportFactory, OrderLifecycleWatch) {
        let ws = WebSocketManager(baseURL: URL(string: "http://order-watch.test")!, token: "test", realmId: "realm", connectionLifetime: 0)
        let factory = MockTransportFactory()
        await ws.setTransportFactory(factory.make())
        let watch = try await ws.watchOrderLifecycle(realm: "realm", objectId: "account", operationId: "original", leg: 0, snapshotTimeoutNs: timeout)
        try await waitFor { factory.socket(0)?.sentActions.contains("auth") == true }
        factory.socket(0)!.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { !self.requests(factory.socket(0)!).isEmpty }
        return (ws, factory, watch)
    }

    func testQuietSnapshotGapRotationAndStaleErrorsKeepOriginalIdentity() async throws {
        let (ws, factory, watch) = try await setup()
        let updates = SendableBox<[OrderLifecycleUpdate]>([])
        let reader = Task { for await update in watch.updates { updates.update { $0.append(update) } } }
        defer { reader.cancel(); Task { await ws.disconnect() } }
        let socket = factory.socket(0)!, first = requests(factory.socket(0)!).last!
        socket.deliver(try frame(first, seq: 1))
        try await waitFor { updates.value.count == 1 }
        XCTAssertEqual(updates.value[0].lifecycle?.intent.requestedSize, "9007199254740993.123456789")
        XCTAssertEqual(updates.value[0].lifecycle?.remainingSize, "9007199254740990")
        XCTAssertEqual(updates.value[0].lifecycle?.averagePriceFinal, false)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(requests(socket).count, 1, "Healthy watches must remain quiet beyond the snapshot deadline")
        socket.deliver(#"{"type":"stream.resync","deliverySeq":4}"#)
        try await waitFor { self.requests(socket).count == 2 }
        let second = requests(socket).last!
        XCTAssertEqual(second["watchId"] as? String, first["watchId"] as? String)
        XCTAssertNotEqual(second["requestId"] as? String, first["requestId"] as? String)
        socket.deliver(try json(["type":"error", "requestId":first["requestId"]!, "message":"stale denial"]))
        socket.deliver(try frame(first, seq: 5))
        socket.deliver(try frame(second, seq: 6))
        try await waitFor { updates.value.count == 2 }
        let started = await ws.rotateConnection(); XCTAssertTrue(started)
        try await waitFor { factory.socket(1)?.sentActions.contains("auth") == true }
        let replacement = factory.socket(1)!
        replacement.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { replacement.sentActions.contains("ping") }
        XCTAssertTrue(requests(replacement).isEmpty, "A warming socket cannot replace current evidence")
        replacement.deliver(#"{"type":"pong"}"#)
        try await waitFor { self.requests(replacement).count == 1 }
        let third = requests(replacement).last!
        XCTAssertEqual(third["operationId"] as? String, "original")
        XCTAssertEqual(third["objectId"] as? String, "account")
        XCTAssertEqual(third["leg"] as? String, "0")
        replacement.deliver(try json(["type":"error", "requestId":second["requestId"]!, "message":"stale denial"]))
        replacement.deliver(try frame(third, seq: 1))
        try await waitFor { updates.value.count == 3 }
        await ws.reconnect()
        try await waitFor { factory.socket(2)?.sentActions.contains("auth") == true }
        let reconnected = factory.socket(2)!
        reconnected.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { self.requests(reconnected).count == 1 }
        reconnected.deliver(try json(["type":"error", "requestId":third["requestId"]!, "message":"stale denial"]))
        reconnected.deliver(try frame(requests(reconnected).last!, seq: 1))
        try await waitFor { updates.value.count == 4 }
        XCTAssertTrue(updates.value.allSatisfy { !$0.unavailable })
        await watch.stop(); await reader.value
        let sent = requests(reconnected).count
        reconnected.deliver(#"{"type":"stream.resync","deliverySeq":2}"#)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(requests(reconnected).count, sent)
        XCTAssertTrue(reconnected.sentActions.contains("unwatch_order_lifecycle"))
        let status = await ws.status; XCTAssertEqual(status, .connected)
    }

    func testAckAloneTimesOutAndDisconnectFinishesRecovery() async throws {
        let (ws, factory, watch) = try await setup(timeout: 50_000_000)
        let updates = SendableBox<[OrderLifecycleUpdate]>([]), finished = SendableBox(false)
        let reader = Task { for await update in watch.updates { updates.update { $0.append(update) } }; finished.update { $0 = true } }
        defer { reader.cancel(); Task { await ws.disconnect() } }
        let socket = factory.socket(0)!, first = requests(factory.socket(0)!).last!
        socket.deliver(try json(["type":"order_lifecycle_watch_created", "requestId":first["requestId"]!, "watchId":first["watchId"]!]))
        try await waitFor { updates.value.first?.reason == "snapshot_timeout" }
        XCTAssertTrue(updates.value[0].recoverable)
        try await waitFor { self.requests(socket).count == 2 }
        socket.deliver(try frame(requests(socket).last!, seq: 1))
        try await waitFor { updates.value.last?.lifecycle != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(requests(socket).count, 2)
        let active = requests(socket).last!
        socket.deliver(try json(["type":"order.lifecycle.updated", "requestId":active["requestId"]!, "watchId":active["watchId"]!,
            "realmId":"realm", "objectId":"account", "operationId":"original", "leg":"0", "deliverySeq":2,
            "unavailable":true, "recoverable":true, "reason":"source_unavailable"]))
        try await waitFor { updates.value.last?.reason == "source_unavailable" }
        try await waitFor { self.requests(socket).count == 3 }
        socket.deliver(try frame(requests(socket).last!, seq: 3))
        try await waitFor { updates.value.last?.lifecycle != nil }
        await ws.disconnect()
        try await waitFor { finished.value }
        let count = requests(socket).count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(socket).count, count)
    }

    func testForeignEvidenceMissingFinalityAndChangedIntentCannotBeAdopted() async throws {
        for defect in ["foreign", "missing", "changed"] {
            let (ws, factory, watch) = try await setup(timeout: 1_000_000_000)
            let updates = SendableBox<[OrderLifecycleUpdate]>([])
            let reader = Task { for await update in watch.updates { updates.update { $0.append(update) } } }
            defer { reader.cancel(); Task { await ws.disconnect() } }
            let socket = factory.socket(0)!, request = requests(factory.socket(0)!).last!
            if defect == "changed" {
                socket.deliver(try frame(request, seq: 1)); try await waitFor { updates.value.count == 1 }
            }
            var bad = wire
            if defect == "foreign" { bad = wire.replacingOccurrences(of: #""objectId":"account""#, with: #""objectId":"foreign""#) }
            if defect == "missing" { bad = wire.replacingOccurrences(of: #""executionQuantityFinal":true,"#, with: "") }
            if defect == "changed" { bad = wire.replacingOccurrences(of: #""orderType":"MARKET""#, with: #""orderType":"LIMIT""#) }
            socket.deliver(try frame(request, seq: defect == "changed" ? 2 : 1, view: bad))
            try await waitFor { updates.value.last?.unavailable == true }
            XCTAssertEqual(updates.value.last?.recoverable, false)
            XCTAssertEqual(updates.value.last?.reason, defect == "changed" ? "original_intent_changed" : "invalid_order_evidence")
            await reader.value
            XCTAssertTrue(socket.sentActions.contains("unwatch_order_lifecycle"))
            await ws.disconnect()
        }
    }
}

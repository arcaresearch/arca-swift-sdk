import XCTest
@testable import ArcaSDK

final class OrderCaptureLifecycleTests: XCTestCase {
    private func operation(outcome: String? = nil, account: String = "account") throws -> ArcaSDK.Operation {
        var body: [String: Any] = ["id": "op", "realmId": "realm", "path": "/op", "type": "order", "state": "pending", "input": "{\"exchangeObjectId\":\"\(account)\",\"size\":\"3\",\"timeInForce\":\"IOC\"}", "createdAt": "2026-01-01", "updatedAt": "2026-01-01"]
        body["outcome"] = outcome
        return try JSONDecoder().decode(ArcaSDK.Operation.self, from: JSONSerialization.data(withJSONObject: body))
    }
    private func operationEvent(_ operation: ArcaSDK.Operation) throws -> String {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation))
        return String(data: try JSONSerialization.data(withJSONObject: ["type": "operation.updated", "operation": body]), encoding: .utf8)!
    }
    private func terminal(order: String = "venue", account: String = "account") -> String {
        "{\"type\":\"order.updated\",\"entityId\":\"\(account)\",\"order\":{\"order\":{\"id\":\"\(order)\",\"status\":\"FILLED\",\"filledSize\":\"1\"}}}"
    }
    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let passed = await condition(); XCTAssertTrue(passed)
    }
    private func harness() async throws -> (WebSocketManager, MockWebSocketTransport, OrderEventCapture) {
        let factory = MockTransportFactory()
        let ws = WebSocketManager(baseURL: URL(string: "http://localhost:19999")!, token: "test", realmId: "realm", connectionLifetime: 0)
        await ws.setTransportFactory(factory.make()); await ws.connect()
        try await waitFor { factory.count > 0 }
        let socket = factory.socket(0)!
        socket.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { await ws.status == .connected }
        let capture = OrderEventCapture(ws: ws); await capture.start()
        return (ws, socket, capture)
    }
    func testSubmittedOnlyLearnsIdentityAndReleasesOnTerminalInEitherOrder() async throws {
        for terminalFirst in [false, true] {
            let (ws, socket, capture) = try await harness()
            await capture.submitted(try operation(), objectId: "account")
            if terminalFirst { await ws.injectMessage(terminal()) }
            await ws.injectMessage(try operationEvent(operation(outcome: #"{"orderId":"venue","status":"OPEN","filledSize":"0"}"#)))
            if !terminalFirst { await ws.injectMessage(terminal()) }
            try await waitFor { socket.sentActions.contains("unwatch") }
            await capture.stop(); await ws.disconnect()
        }
    }
    func testBufferedBeforeSubmissionAndWrongAccountOrderDoNotLeakOrReleaseEarly() async throws {
        let (ws, socket, capture) = try await harness()
        await ws.injectMessage(terminal())
        await ws.injectMessage(try operationEvent(operation(outcome: #"{"orderId":"wrong"}"#, account: "foreign")))
        await capture.submitted(try operation(), objectId: "account")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(socket.sentActions.contains("unwatch"))
        await ws.injectMessage(terminal(order: "other"))
        await ws.injectMessage(terminal(account: "foreign"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(socket.sentActions.contains("unwatch"))
        await ws.injectMessage(try operationEvent(operation(outcome: #"{"orderId":"venue","status":"OPEN","filledSize":"0"}"#)))
        try await waitFor { socket.sentActions.contains("unwatch") }
        await capture.stop(); await ws.disconnect()
    }
    func testKnownOrderCannotBeReplacedByAnotherLegAndKeepsOtherWatchOwner() async throws {
        let (ws, socket, capture) = try await harness()
        await ws.watchPath("/") // another consumer owns the same shared path
        await capture.submitted(try operation(outcome: #"{"orderId":"venue","status":"OPEN","filledSize":"0"}"#), objectId: "account")
        await ws.injectMessage(try operationEvent(operation(outcome: #"{"orderId":"other","status":"OPEN","filledSize":"0"}"#)))
        await ws.injectMessage(terminal(order: "other"))
        try await Task.sleep(nanoseconds: 30_000_000)
        await ws.unwatchPath("/") // if capture released incorrectly this sends unwatch
        XCTAssertFalse(socket.sentActions.contains("unwatch"))
        await ws.injectMessage(terminal())
        try await waitFor { socket.sentActions.contains("unwatch") }
        await capture.stop(); await ws.disconnect()
    }
    func testReceiptTimeoutStillReleasesLaterWithoutRetry() async throws {
        let (ws, socket, capture) = try await harness()
        let original = try operation()
        await capture.submitted(original, objectId: "account")
        let inner = OperationHandle(submit: { OrderOperationResponse(operation: original) }, waitForSettlement: { _ in original })
        let deps = OrderHandleDeps(getOrder: { _, _ in throw CancellationError() }, fillEvents: { AsyncStream { $0.finish() } },
            cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() },
            waitForSettlement: { _ in original }, listFills: { _ in .init(fills: [], total: 0, cursor: nil) },
            releaseExecution: { await capture.stop() }, awaitExecutionReady: {}, executionEvents: { await capture.events() },
            getExecutionOperation: { _ in original })
        let handle = OrderHandle(inner: inner, objectId: "account", placementPath: "/op", deps: deps)
        do { _ = try await handle.executionReceipt(timeoutSeconds: 0.02); XCTFail("expected timeout") }
        catch ArcaError.unknown(let code, _, _) { XCTAssertEqual(code, "TIMEOUT") }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(socket.sentActions.contains("unwatch"))
        await ws.injectMessage(try operationEvent(operation(outcome: #"{"orderId":"venue","status":"OPEN","filledSize":"0"}"#)))
        await ws.injectMessage(terminal())
        try await waitFor { socket.sentActions.contains("unwatch") }
        _ = try await handle.submitted // keep the handle alive; deinit cannot mask ownership
        await ws.disconnect()
    }
}

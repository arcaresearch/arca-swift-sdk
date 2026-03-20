import XCTest
@testable import ArcaSDK

private typealias ArcaOperation = ArcaSDK.Operation

// MARK: - Test Helpers

private func makeOrderOperation(
    id: String = "op_order_1",
    state: OperationState = .completed,
    outcome: String? = "ord_abc"
) -> ArcaOperation {
    ArcaOperation(
        id: OperationID(id),
        realmId: RealmID("rlm_test"),
        path: "/op/order/btc-buy-1",
        type: .order,
        state: state,
        sourceArcaPath: nil,
        targetArcaPath: nil,
        input: nil,
        outcome: outcome,
        parsedOutcome: nil,
        failureMessage: nil,
        actorType: "user",
        actorId: nil,
        tokenJti: nil,
        createdAt: "2026-03-08T00:00:00.000000Z",
        updatedAt: "2026-03-08T00:00:00.000000Z"
    )
}

private func makeFill(
    id: String = "fill_1",
    orderId: String = "ord_abc",
    size: String = "0.5",
    price: String = "50000"
) -> SimFill {
    SimFill(
        id: SimFillID(id),
        orderId: SimOrderID(orderId),
        accountId: SimAccountID("acc_1"),
        realmId: RealmID("rlm_test"),
        coin: "BTC",
        side: .buy,
        price: price,
        size: size,
        fee: "0.50",
        builderFee: nil,
        realizedPnl: nil,
        isLiquidation: false,
        createdAt: "2026-03-08T00:00:00.000000Z"
    )
}

private func makeSimOrder(
    id: String = "ord_abc",
    status: OrderStatus = .filled,
    size: String = "1.0",
    filledSize: String = "1.0",
    timeInForce: TimeInForce = .ioc
) -> SimOrder {
    SimOrder(
        id: SimOrderID(id),
        accountId: SimAccountID("acc_1"),
        realmId: RealmID("rlm_test"),
        coin: "ETH",
        side: .sell,
        orderType: .market,
        price: nil,
        size: size,
        filledSize: filledSize,
        avgFillPrice: "2000",
        status: status,
        reduceOnly: false,
        timeInForce: timeInForce,
        leverage: 5,
        builderFeeBps: nil,
        createdAt: "2026-03-08T00:00:00.000000Z",
        updatedAt: "2026-03-08T00:00:00.000000Z"
    )
}

// MARK: - OrderHandle Tests

final class OrderHandleTests: XCTestCase {

    func testSettledDelegatesToInner() async throws {
        let op = makeOrderOperation(state: .completed)
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        let result = try await handle.settled
        XCTAssertEqual(result.operation.state, .completed)
    }

    func testSubmittedDelegatesToInner() async throws {
        let op = makeOrderOperation(state: .pending)
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in
                try await Task.sleep(nanoseconds: 500_000_000)
                return makeOrderOperation(state: .completed)
            }
        )

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        let submitted = try await handle.submitted
        XCTAssertEqual(submitted.operation.state, .pending)
    }

    func testOnFillReceivesMatchingFills() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let fillExpectation = expectation(description: "fill received")
        let matchingFill = makeFill(orderId: "ord_abc", size: "0.5")

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: {
                AsyncStream { continuation in
                    let event = RealmEvent(
                        realmId: "rlm_test",
                        type: "exchange.fill",
                        entityId: "fill_1",
                        entityPath: nil,
                        summary: nil,
                        operation: nil,
                        event: nil,
                        object: nil,
                        mids: nil,
                        exchangeState: nil,
                        valuation: nil,
                        path: nil,
                        watchId: nil,
                        aggregation: nil,
                        coin: nil,
                        interval: nil,
                        candle: nil,
                        fill: matchingFill,
                        funding: nil
                    )
                    continuation.yield((matchingFill, event))
                    continuation.finish()
                }
            },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        var receivedFill: SimFill?
        let unsub = handle.onFill { fill in
            receivedFill = fill
            fillExpectation.fulfill()
        }

        await fulfillment(of: [fillExpectation], timeout: 2.0)
        XCTAssertEqual(receivedFill?.size, "0.5")
        XCTAssertEqual(receivedFill?.orderId.rawValue, "ord_abc")
        unsub()
    }

    func testCancelGeneratesCorrectPath() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        var capturedCancelPath: String?
        var capturedObjectId: String?
        var capturedOrderId: String?

        let cancelOp = makeOrderOperation(id: "op_cancel_1", state: .completed)
        let cancelResponse = OrderOperationResponse(operation: cancelOp)

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { path, objId, ordId in
                capturedCancelPath = path
                capturedObjectId = objId
                capturedOrderId = ordId
                return OperationHandle<OrderOperationResponse>(
                    submit: { cancelResponse },
                    waitForSettlement: { _ in cancelOp }
                )
            },
            waitForSettlement: { _ in cancelOp },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        let cancelHandle = handle.cancel()
        let result = try await cancelHandle.settled

        XCTAssertEqual(capturedCancelPath, "/op/order/btc-buy-1/cancel")
        XCTAssertEqual(capturedObjectId, "obj_exchange")
        XCTAssertEqual(capturedOrderId, "ord_abc")
        XCTAssertEqual(result.operation.state, .completed)
    }

    func testCancelWithCustomPath() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        var capturedCancelPath: String?
        let cancelOp = makeOrderOperation(id: "op_cancel_2", state: .completed)
        let cancelResponse = OrderOperationResponse(operation: cancelOp)

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { path, _, _ in
                capturedCancelPath = path
                return OperationHandle<OrderOperationResponse>(
                    submit: { cancelResponse },
                    waitForSettlement: { _ in cancelOp }
                )
            },
            waitForSettlement: { _ in cancelOp },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        let cancelHandle = handle.cancel(path: "/op/order/custom-cancel")
        _ = try await cancelHandle.settled

        XCTAssertEqual(capturedCancelPath, "/op/order/custom-cancel")
    }

    // MARK: - IOC Partial Fill Tests

    func testFilledReturnsOnIOCPartialFill() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let partialOrder = makeSimOrder(
            status: .cancelled,
            size: "1.372",
            filledSize: "1.1932",
            timeInForce: .ioc
        )
        let orderWithFills = SimOrderWithFills(
            order: partialOrder,
            fills: [makeFill(orderId: "ord_abc", size: "1.1932", price: "2000")]
        )

        let deps = OrderHandleDeps(
            getOrder: { _, _ in orderWithFills },
            fillEvents: { AsyncStream { $0.finish() } },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/eth-sell-1",
            deps: deps
        )

        let result = try await handle.filled(timeoutSeconds: 2)
        XCTAssertEqual(result.order.status, .cancelled)
        XCTAssertEqual(result.order.filledSize, "1.1932")
        XCTAssertTrue(result.order.isPartiallyFilled)
        XCTAssertTrue(result.order.isTerminalWithFills)
    }

    func testFilledThrowsOnCancelledWithNoFills() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let cancelledOrder = makeSimOrder(
            status: .cancelled,
            size: "1.0",
            filledSize: "0"
        )
        let orderWithFills = SimOrderWithFills(order: cancelledOrder, fills: [])

        let deps = OrderHandleDeps(
            getOrder: { _, _ in orderWithFills },
            fillEvents: { AsyncStream { $0.finish() } },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/eth-sell-2",
            deps: deps
        )

        do {
            _ = try await handle.filled(timeoutSeconds: 2)
            XCTFail("Expected error for cancelled order with no fills")
        } catch {
            let arcaError = error as? ArcaError
            switch arcaError {
            case .unknown(let code, _, _):
                XCTAssertEqual(code, "ORDER_CANCELLED")
            default:
                break
            }
        }
    }

    func testSimOrderIsPartiallyFilled() {
        let partial = makeSimOrder(status: .cancelled, size: "1.372", filledSize: "1.1932")
        XCTAssertTrue(partial.isPartiallyFilled)
        XCTAssertTrue(partial.isTerminalWithFills)

        let full = makeSimOrder(status: .filled, size: "1.0", filledSize: "1.0")
        XCTAssertFalse(full.isPartiallyFilled)
        XCTAssertTrue(full.isTerminalWithFills)

        let noFill = makeSimOrder(status: .cancelled, size: "1.0", filledSize: "0")
        XCTAssertFalse(noFill.isPartiallyFilled)
        XCTAssertFalse(noFill.isTerminalWithFills)

        let open = makeSimOrder(status: .open, size: "1.0", filledSize: "0")
        XCTAssertFalse(open.isPartiallyFilled)
        XCTAssertFalse(open.isTerminalWithFills)
    }
}

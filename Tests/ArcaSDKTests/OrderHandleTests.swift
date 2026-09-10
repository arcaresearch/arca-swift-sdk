import XCTest
@testable import ArcaSDK

private typealias ArcaOperation = ArcaSDK.Operation

// MARK: - Test Helpers

private func makeOrderOperation(
    id: String = "op_order_1",
    state: OperationState = .completed,
    outcome: String? = "ord_abc",
    input: String? = nil
) -> ArcaOperation {
    ArcaOperation(
        id: OperationID(id),
        realmId: RealmID("rlm_test"),
        path: "/op/order/btc-buy-1",
        type: .order,
        state: state,
        sourceArcaPath: nil,
        targetArcaPath: nil,
        input: input,
        outcome: outcome,
        parsedOutcome: nil,
        failureMessage: nil,
        actorType: "user",
        actorId: nil,
        tokenJti: nil,
        createdAt: "2026-03-08T00:00:00.000000Z",
        updatedAt: "2026-03-08T00:00:00.000000Z",
        context: nil
    )
}

private func makeFill(
    id: String = "fill_1",
    orderId: String = "ord_abc",
    cloid: String? = nil,
    size: String = "0.5",
    price: String = "50000"
) -> SimFill {
    SimFill(
        id: SimFillID(id),
        orderId: SimOrderID(orderId),
        cloid: cloid,
        accountId: SimAccountID("acc_1"),
        realmId: RealmID("rlm_test"),
        market: "BTC",
        side: .buy,
        price: price,
        size: size,
        fee: "0.50",
        builderFee: nil,
        platformFee: nil,
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
        market: "ETH",
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
        isTrigger: nil,
        triggerPx: nil,
        isMarket: nil,
        tpsl: nil,
        sizeToMax: nil,
        ocoGroupId: nil,
        cancelReason: nil,
        createdAt: "2026-03-08T00:00:00.000000Z",
        updatedAt: "2026-03-08T00:00:00.000000Z"
    )
}

// MARK: - OrderHandle Tests

final class OrderHandleTests: XCTestCase {

    func testTerminalReceiptsPreserveOriginalIOCSizesWithoutOrderRead() async throws {
        for (requested, filled, remaining) in [("40.110692", "4.041", "36.069692"), ("286.522911", "1.809", "284.713911"), ("47.700441", "3.825", "43.875441")] {
            let op = makeOrderOperation(outcome: "{\"orderId\":\"ord_abc\",\"status\":\"filled\",\"filledSize\":\"\(filled)\",\"avgFillPrice\":\"328\"}", input: "{\"exchangeObjectId\":\"obj_exchange\",\"size\":\"\(requested)\",\"gllPrepared\":{\"request\":{\"Effect\":1}}}")
            let inner = OperationHandle<OrderOperationResponse>(submit: { OrderOperationResponse(operation: op) }, waitForSettlement: { _ in XCTFail("No settlement wait"); return op })
            let deps = OrderHandleDeps(getOrder: { _, _ in fatalError("Terminal receipt must not read order") }, fillEvents: { AsyncStream { $0.finish() } }, cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() }, waitForSettlement: { _ in fatalError() }, listFills: { _ in fatalError() })
            let handle = OrderHandle(inner: inner, objectId: "obj_exchange", placementPath: "/order", deps: deps)
            let receipt = try await handle.executionReceipt(timeoutSeconds: 1)
            XCTAssertEqual(receipt.requestedSize, requested)
            XCTAssertEqual(receipt.remainingSize, remaining)
            XCTAssertEqual(receipt.fulfillmentState, "partial")
            XCTAssertEqual(receipt.remainingDisposition, "cancelled")
            XCTAssertFalse(receipt.averagePriceFinal)
            XCTAssertFalse(receipt.fillsComplete)
        }
    }

    func testTerminalPushWinsWhileWatchAcknowledgementIsPending() async throws {
        let op = makeOrderOperation(state: .pending, outcome: #"{"orderId":"ord_abc"}"#)
        let inner = OperationHandle<OrderOperationResponse>(submit: { OrderOperationResponse(operation: op) }, waitForSettlement: { _ in fatalError("Must not wait for settlement") })
        var deps = OrderHandleDeps(getOrder: { _, _ in fatalError("Read must await ACK") }, fillEvents: { AsyncStream { $0.finish() } }, cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() }, waitForSettlement: { _ in fatalError() }, listFills: { _ in fatalError() })
        deps.awaitExecutionReady = { try await Task.sleep(nanoseconds: 60_000_000_000) }
        deps.executionEvents = { AsyncStream { continuation in
            continuation.yield(RealmEvent(type: "order.updated", entityId: "obj_exchange", order: OrderExecutionUpdate(order: .init(id: "ord_abc", orderId: nil, status: "FILLED", filledSize: "3.825", avgFillPrice: "251"), fillsComplete: false)))
        } }
        let handle = OrderHandle(inner: inner, objectId: "obj_exchange", placementPath: "/order", deps: deps)
        let receipt = try await handle.executionReceipt(timeoutSeconds: 1)
        XCTAssertEqual(receipt.filledSize, "3.825")
    }

    func testLateIdentityRechecksBufferedEvidenceAndPreservesOriginalIntent() async throws {
        let original = makeOrderOperation(state: .pending, outcome: "{}", input: #"{"exchangeObjectId":"obj_exchange","size":"40","timeInForce":"IOC"}"#)
        let evidence = OrderExecutionEvidence(operation: original, objectId: "obj_exchange", orderId: nil)
        let event = RealmEvent(type: "order.updated", entityId: "obj_exchange", order: OrderExecutionUpdate(order: .init(id: "ord_abc", orderId: nil, status: "FILLED", filledSize: "4.041", avgFillPrice: nil), fillsComplete: false))
        let early = try await evidence.receive(event)
        XCTAssertNil(early)
        let foreign = makeOrderOperation(state: .failed, outcome: nil, input: #"{"exchangeObjectId":"foreign"}"#)
        let rejected = try await evidence.receive(RealmEvent(type: "operation.updated", operation: foreign))
        XCTAssertNil(rejected)
        let learned = makeOrderOperation(outcome: #"{"orderId":"ord_abc","status":"OPEN","filledSize":"0"}"#, input: #"{"exchangeObjectId":"obj_exchange","size":"4.041"}"#)
        let receipt = try await evidence.receive(RealmEvent(type: "operation.updated", operation: learned))
        XCTAssertEqual(receipt?.orderId, "ord_abc")
        XCTAssertEqual(receipt?.requestedSize, "40")
        XCTAssertEqual(receipt?.filledSize, "4.041")
    }

    func testHealthyOpenIsQuietAndActualGapUsesFreshBarrier() async throws {
        let op = makeOrderOperation(outcome: #"{"orderId":"ord_abc"}"#)
        let (gaps, gap) = AsyncStream<Void>.makeStream()
        let seeded = expectation(description: "one initial order read")
        let reads = SendableBox(0), fresh = SendableBox(0)
        var deps = recoveryDeps(getOrder: { _, _ in
            reads.update { $0 += 1 }
            if reads.value == 1 { seeded.fulfill() }
            return SimOrderWithFills(order: makeSimOrder(status: reads.value == 1 ? .open : .filled), fills: [])
        })
        deps.executionGaps = { gaps }
        deps.recoverExecutionReady = { fresh.update { $0 += 1 } }
        let task = Task { try await self.recoveryHandle(op, deps: deps).executionReceipt(timeoutSeconds: 1) }
        await fulfillment(of: [seeded], timeout: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(reads.value, 1)
        gap.yield(())
        let receipt = try await task.value
        XCTAssertEqual(receipt.orderId, "ord_abc")
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(fresh.value, 1)
        gap.finish()
    }

    func testFailedAcknowledgementRecoversAndPendingOperationDoesNotReadOrderId() async throws {
        let op = makeOrderOperation(state: .pending, outcome: "{}", input: #"{"exchangeObjectId":"obj_exchange","size":"40"}"#)
        let fresh = SendableBox(0), reads = SendableBox(0)
        var deps = recoveryDeps(getOrder: { _, _ in XCTFail("operation ID is not an order ID"); throw CancellationError() })
        deps.awaitExecutionReady = { throw ArcaError.unknown(code: "DISCONNECTED", message: "fixture", errorId: nil) }
        deps.recoverExecutionReady = { fresh.update { $0 += 1 } }
        deps.getExecutionOperation = { id in
            XCTAssertEqual(id, op.id.rawValue)
            reads.update { $0 += 1 }
            return makeOrderOperation(outcome: #"{"orderId":"ord_abc","status":"FILLED","filledSize":"4.041"}"#)
        }
        let receipt = try await recoveryHandle(op, deps: deps).executionReceipt(timeoutSeconds: 1)
        XCTAssertEqual(receipt.requestedSize, "40")
        XCTAssertEqual(receipt.filledSize, "4.041")
        XCTAssertEqual(fresh.value, 1)
        XCTAssertEqual(reads.value, 1)
    }

    func testUnavailableRecoveryHasFiniteBudget() async throws {
        let reads = SendableBox(0)
        let deps = recoveryDeps(getOrder: { _, _ in
            reads.update { $0 += 1 }
            throw ArcaError.unknown(code: "UNAVAILABLE", message: "fixture", errorId: nil)
        })
        do {
            _ = try await recoveryHandle(makeOrderOperation(outcome: #"{"orderId":"ord_abc"}"#), deps: deps).executionReceipt(timeoutSeconds: 0.9)
            XCTFail("expected timeout")
        } catch let error as ArcaError {
            guard case .unknown(let code, _, _) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(code, "TIMEOUT")
        }
        XCTAssertEqual(reads.value, 3)
    }

    private func recoveryDeps(getOrder: @escaping @Sendable (String, String) async throws -> SimOrderWithFills) -> OrderHandleDeps {
        OrderHandleDeps(getOrder: getOrder, fillEvents: { AsyncStream { $0.finish() } },
            cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() },
            waitForSettlement: { _ in fatalError() }, listFills: { _ in fatalError() },
            executionEvents: { AsyncStream { _ in } })
    }

    private func recoveryHandle(_ operation: ArcaOperation, deps: OrderHandleDeps) -> OrderHandle {
        let inner = OperationHandle<OrderOperationResponse>(submit: { OrderOperationResponse(operation: operation) }, waitForSettlement: { _ in fatalError("must not resubmit") })
        return OrderHandle(inner: inner, objectId: "obj_exchange", placementPath: "/order", deps: deps)
    }

    func testTimeoutRetainsCaptureForConfirmationRetry() async throws {
        let op = makeOrderOperation(state: .pending, outcome: #"{"orderId":"ord_abc"}"#)
        let inner = OperationHandle<OrderOperationResponse>(submit: { OrderOperationResponse(operation: op) }, waitForSettlement: { _ in fatalError("No resubmission or settlement wait") })
        let attempts = SendableBox(0)
        let releases = SendableBox(0)
        var deps = OrderHandleDeps(getOrder: { _, _ in fatalError("Read awaits ACK") }, fillEvents: { AsyncStream { $0.finish() } }, cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() }, waitForSettlement: { _ in fatalError() }, listFills: { _ in fatalError() })
        deps.awaitExecutionReady = { try await Task.sleep(nanoseconds: 60_000_000_000) }
        deps.releaseExecution = { releases.update { $0 += 1 } }
        deps.executionEvents = {
            attempts.update { $0 += 1 }
            return AsyncStream { continuation in
                if attempts.value > 1 {
                    continuation.yield(RealmEvent(type: "order.updated", entityId: "obj_exchange", order: OrderExecutionUpdate(order: .init(id: "ord_abc", orderId: nil, status: "FILLED", filledSize: "3.825", avgFillPrice: nil), fillsComplete: false)))
                }
            }
        }
        let handle = OrderHandle(inner: inner, objectId: "obj_exchange", placementPath: "/order", deps: deps)
        do { _ = try await handle.executionReceipt(timeoutSeconds: 0.01); XCTFail("Expected deadline") } catch {}
        XCTAssertEqual(releases.value, 0)
        let receipt = try await handle.executionReceipt(timeoutSeconds: 1)
        XCTAssertEqual(receipt.filledSize, "3.825")
        XCTAssertEqual(releases.value, 1)
    }

    func testFillStreamDeduplicatesPreviewAndRecordedWithoutPerFillReads() async throws {
        let op = makeOrderOperation(outcome: #"{"orderId":"ord_abc","status":"filled","filledSize":"1"}"#)
        let inner = OperationHandle<OrderOperationResponse>(submit: { OrderOperationResponse(operation: op) }, waitForSettlement: { _ in fatalError() })
        var aggregate = makeFill(id: "aggregate", size: "1"); aggregate.isOptimistic = true
        let first = makeFill(id: "venue-1", size: "0.3")
        var recorded = makeFill(id: "ledger-1", size: "0.3"); recorded.fillId = "venue-1"
        let second = makeFill(id: "venue-2", size: "0.7")
        let values = [aggregate, first, recorded, second]
        let reads = SendableBox(0)
        let deps = OrderHandleDeps(getOrder: { _, _ in reads.update { $0 += 1 }; try await Task.sleep(nanoseconds: 60_000_000_000); throw CancellationError() }, fillEvents: {
            AsyncStream { c in for fill in values { c.yield((fill, RealmEvent(type: "fill.previewed"))) }; c.finish() }
        }, cancelOrder: { _, _, _ in fatalError() }, modifyOrder: { _, _, _, _ in fatalError() }, waitForSettlement: { _ in fatalError() }, listFills: { _ in fatalError() })
        let handle = OrderHandle(inner: inner, objectId: "obj_exchange", placementPath: "/order", deps: deps)
        var received: [String] = []
        for try await fill in handle.fills(timeoutSeconds: 1) { received.append(fill.id.rawValue) }
        XCTAssertEqual(received, ["venue-1", "venue-2"])
        XCTAssertLessThanOrEqual(reads.value, 1)
    }

    func testOperationUpdateKeepsOriginalRequestedQuantity() {
        let original = #"{"exchangeObjectId":"obj_exchange","size":"40.110692","timeInForce":"IOC"}"#
        let updated = makeOrderOperation(outcome: #"{"orderId":"ord_abc","status":"FILLED","filledSize":"4.041"}"#, input: #"{"exchangeObjectId":"obj_exchange","size":"4.041"}"#)
        let receipt = OrderExecutionReceipt.from(updated, objectId: "obj_exchange", originalInput: original)
        XCTAssertEqual(receipt?.requestedSize, "40.110692")
        XCTAssertEqual(receipt?.remainingSize, "36.069692")
        XCTAssertEqual(receipt?.fulfillmentState, "partial")
        let foreign = makeOrderOperation(outcome: updated.outcome, input: #"{"exchangeObjectId":"other","size":"4.041"}"#)
        XCTAssertNil(OrderExecutionReceipt.from(foreign, objectId: "obj_exchange", originalInput: original))
    }

    func testTerminalVenueStatusAliases() {
        for (status, canonical, state) in [("REJECTED", "FAILED", "rejected"), ("EXPIRED", "CANCELLED", "no_fill"), ("CANCELED", "CANCELLED", "no_fill")] {
            let op = makeOrderOperation(outcome: "{\"orderId\":\"ord_abc\",\"status\":\"\(status)\",\"filledSize\":\"0\"}")
            let receipt = OrderExecutionReceipt.from(op, objectId: "obj_exchange")
            XCTAssertEqual(receipt?.status, canonical)
            XCTAssertEqual(receipt?.executionState, state)
            XCTAssertEqual(receipt?.remainingDisposition, "cancelled")
        }
    }

    func testReceiptUnknownIntentAndDecimalZero() {
        let unknown = makeOrderOperation(outcome: #"{"orderId":"ord_abc","status":"filled","filledSize":"4.041","avgFillPrice":"328"}"#)
        let receipt = OrderExecutionReceipt.from(unknown, objectId: "obj_exchange")
        XCTAssertEqual(receipt?.fulfillmentState, "unknown")
        XCTAssertNil(receipt?.requestedSize)
        for quantity in ["0", "0.0", "0.000"] {
            let op = makeOrderOperation(outcome: "{\"orderId\":\"ord_abc\",\"status\":\"cancelled\",\"filledSize\":\"\(quantity)\"}")
            XCTAssertEqual(OrderExecutionReceipt.from(op, objectId: "obj_exchange")?.executionState, "no_fill")
        }
        for quantity in ["1/2", "0x10", "1e2", "-1"] { XCTAssertNil(OrderExecutionReceipt.decimal(quantity)) }
    }

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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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
                        type: "fill.previewed",
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
                        market: nil,
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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

    func testOnFillMatchesPendingBracketChildByCloid() async throws {
        // Pending normalTpsl child: outcome carries the cloid but NO venue
        // orderId, so extractOrderId falls back to the raw outcome. Only cloid
        // identity can correlate the fill once the venue arms the child.
        let cloid = "0xdeadbeefdeadbeefdeadbeefdeadbeef"
        let op = makeOrderOperation(state: .completed,
            outcome: "{\"orderId\":\"\",\"cloid\":\"\(cloid)\",\"tpsl\":\"tp\"}")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let fillExpectation = expectation(description: "cloid-matched fill received")
        // The fill's venue orderId is a real oid (not the operation id); only
        // its cloid ties it to this handle.
        let matchingFill = makeFill(orderId: "venue-oid-999", cloid: cloid, size: "0.01", price: "72000")

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: {
                AsyncStream { continuation in
                    let event = RealmEvent(
                        realmId: "rlm_test", type: "fill.recorded", entityId: "fill_1",
                        entityPath: nil, summary: nil, operation: nil, event: nil, object: nil,
                        mids: nil, exchangeState: nil, valuation: nil, path: nil, watchId: nil,
                        aggregation: nil, market: nil, interval: nil, candle: nil,
                        fill: matchingFill, funding: nil
                    )
                    continuation.yield((matchingFill, event))
                    continuation.finish()
                }
            },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
            waitForSettlement: { _ in fatalError("unexpected") },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner, objectId: "obj_exchange",
            placementPath: "/op/order/bracket-1", deps: deps
        )

        var receivedFill: SimFill?
        let unsub = handle.onFill { fill in
            receivedFill = fill
            fillExpectation.fulfill()
        }
        await fulfillment(of: [fillExpectation], timeout: 2.0)
        XCTAssertEqual(receivedFill?.cloid, cloid)
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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

    // MARK: - Resize Tests

    func testResizeForwardsNewSizeAndAutoPath() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        var capturedPath: String?
        var capturedObjectId: String?
        var capturedOrderId: String?
        var capturedNewSize: String?

        let modifyOp = makeOrderOperation(id: "op_modify_1", state: .completed)
        let modifyResponse = OrderOperationResponse(operation: modifyOp)

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            modifyOrder: { path, objId, ordId, newSize in
                capturedPath = path
                capturedObjectId = objId
                capturedOrderId = ordId
                capturedNewSize = newSize
                return OperationHandle<OrderOperationResponse>(
                    submit: { modifyResponse },
                    waitForSettlement: { _ in modifyOp }
                )
            },
            waitForSettlement: { _ in modifyOp },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        let resizeHandle = handle.resize("0.75")
        let result = try await resizeHandle.settled

        XCTAssertEqual(capturedPath, "/op/modify/btc-buy-1-0.75")
        XCTAssertEqual(capturedObjectId, "obj_exchange")
        XCTAssertEqual(capturedOrderId, "ord_abc")
        XCTAssertEqual(capturedNewSize, "0.75")
        XCTAssertEqual(result.operation.state, .completed)
    }

    func testResizeWithCustomPath() async throws {
        let op = makeOrderOperation(state: .completed, outcome: "ord_abc")
        let response = OrderOperationResponse(operation: op)

        let inner = OperationHandle<OrderOperationResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        var capturedPath: String?
        let modifyOp = makeOrderOperation(id: "op_modify_2", state: .completed)
        let modifyResponse = OrderOperationResponse(operation: modifyOp)

        let deps = OrderHandleDeps(
            getOrder: { _, _ in fatalError("unexpected") },
            fillEvents: { fatalError("unexpected") },
            cancelOrder: { _, _, _ in fatalError("unexpected") },
            modifyOrder: { path, _, _, _ in
                capturedPath = path
                return OperationHandle<OrderOperationResponse>(
                    submit: { modifyResponse },
                    waitForSettlement: { _ in modifyOp }
                )
            },
            waitForSettlement: { _ in modifyOp },
            listFills: { _ in fatalError("unexpected") }
        )

        let handle = OrderHandle(
            inner: inner,
            objectId: "obj_exchange",
            placementPath: "/op/order/btc-buy-1",
            deps: deps
        )

        _ = try await handle.resize("2", path: "/op/modify/custom").settled

        XCTAssertEqual(capturedPath, "/op/modify/custom")
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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
            modifyOrder: { _, _, _, _ in fatalError("unexpected") },
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

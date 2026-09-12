import XCTest
@testable import ArcaSDK

final class PositionViewTests: XCTestCase {
    static func snapshot(_ size: String, tick: Int = 1, market: String = "BTC") throws -> ExchangeState {
        let position: [String: Any] = ["id": "p", "market": market, "side": size.hasPrefix("-") ? "short" : "long", "size": size.replacingOccurrences(of: "-", with: ""), "entryPrice": "100", "leverage": 5, "marginUsed": "90"]
        let json: [String: Any] = [
            "account": ["id": "venue", "realmId": "r", "name": "", "createdAt": "", "updatedAt": ""],
            "marginSummary": ["equity": "999", "initialMarginUsed": "90", "maintenanceMarginRequired": "10", "availableToWithdraw": "800", "totalNtlPos": "100", "totalUnrealizedPnl": "5"],
            "positions": size == "0" ? [] : [position], "openOrders": [], "pendingIntents": [],
            "tradingAllocation": ["asOf": "2026-09-11T10:00:00." + String(format: "%09d", tick) + "Z", "validUntil": "2099-01-01T00:00:00Z", "revision": "1", "preferences": [:], "projectionUnavailable": false]
        ]
        return try JSONDecoder().decode(ExchangeState.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func operation(_ id: String, side: OrderSide) throws -> ArcaSDK.Operation {
        let input = String(data: try JSONSerialization.data(withJSONObject: ["exchangeObjectId": "a", "market": "BTC", "side": side.rawValue]), encoding: .utf8)!
        return try JSONDecoder().decode(ArcaSDK.Operation.self, from: JSONSerialization.data(withJSONObject: ["id": id, "realmId": "r", "path": "/op/"+id, "type": "order", "state": "completed", "input": input, "createdAt": "2026-09-11T10:00:01Z", "updatedAt": ""]))
    }
    private func bind(_ view: PositionView, _ side: OrderSide, _ id: String = "op") throws -> PositionUpdate {
        let token = try view.begin(market: "BTC", side: side)
        try view.bind(token, operation: operation(id, side: side), objectId: "a")
        return token
    }
    private func receipt(_ view: PositionView, _ token: PositionUpdate, _ size: String, _ op: String = "op", status: String = "FILLED") {
        view.receive(token, receipt: .init(objectId: "a", operationId: op, orderId: "order-"+op, status: status, filledSize: size, executionState: "filled", fulfillmentState: "full", remainingDisposition: "filled"))
    }
    private func size(_ view: PositionView) -> String { view.current.value.positions.first { $0.market == "BTC" }?.signedSize ?? "0" }

    func testTransitionsAcrossBothAccountReceiptOrderingsAndLateSnapshots() async throws {
        let cases: [(String, OrderSide, String, String)] = [("0",.buy,"2","2"),("2",.buy,"1","3"),("2",.sell,"1","1"),("2",.sell,"2","0"),("2",.sell,"3","-1"),("-2",.buy,"3","1"),("0.1",.buy,"0.2","0.3")]
        for (base, side, executed, expected) in cases {
            for accountFirst in [false, true] {
                let authoritative = try Self.snapshot(base)
                let view = PositionView(objectId: "a") { try Self.snapshot(expected, tick: 3) }
                view.observe(authoritative)
                let token = try bind(view, side)
                if accountFirst { view.observe(try Self.snapshot(expected, tick: 2)) }
                receipt(view, token, executed)
                if !accountFirst { view.observe(try Self.snapshot(base, tick: 2)) }
                XCTAssertEqual(size(view), expected)
                XCTAssertEqual(view.current.value.coverage.first?.status, "execution")
                XCTAssertTrue(view.current.value.positions.allSatisfy { $0.source == "execution" && $0.authoritativePosition == nil })
                XCTAssertEqual(authoritative.marginSummary.equity, "999")
                await view.accounted(token)
                XCTAssertEqual(size(view), expected); XCTAssertEqual(view.current.value.pendingMarkets, [])
                XCTAssertEqual(view.current.value.coverage.first?.status, "accounted")
                view.observe(try Self.snapshot(base)); receipt(view, token, executed)
                XCTAssertEqual(size(view), expected)
            }
        }
    }
    func testMixedAccountingDoesNotDropAnotherConfirmedFill() async throws {
        let reads = SendableBox(0)
        let view = PositionView(objectId: "a") { reads.update { $0 += 1 }; return try Self.snapshot("1", tick: 4) }
        view.observe(try Self.snapshot("2"))
        let a = try bind(view, .sell, "a"), b = try bind(view, .buy, "b")
        receipt(view,a,"2","a"); receipt(view,b,"1","b")
        await view.accounted(a); view.observe(try Self.snapshot("0", tick: 2))
        XCTAssertEqual(size(view),"1"); XCTAssertEqual(reads.value,0)
        await view.accounted(b); XCTAssertEqual(size(view),"1"); XCTAssertEqual(reads.value,1)
    }
    func testReadInFlightCannotRetireNewScope() async throws {
        let started = expectation(description: "read started")
        let response = SendableBox<CheckedContinuation<ExchangeState, Never>?>(nil)
        let actual = PositionView(objectId: "a") {
            await withCheckedContinuation { continuation in response.update { $0 = continuation }; started.fulfill() }
        }
        actual.observe(try Self.snapshot("2")); let a = try bind(actual,.sell,"a"); receipt(actual,a,"2","a")
        let task = Task { await actual.accounted(a) }
        await fulfillment(of: [started], timeout: 2)
        let b = try bind(actual,.buy,"b"); receipt(actual,b,"1","b")
        response.value?.resume(returning: try Self.snapshot("0",tick:2)); await task.value
        XCTAssertEqual(size(actual),"1"); XCTAssertEqual(actual.current.value.coverage.count,2)
    }
    func testCumulativePartialAndIdentityDeduplication() throws {
        let view = PositionView(objectId:"a") { try Self.snapshot("0") }; view.observe(try Self.snapshot("2"))
        let token = try bind(view,.sell)
        receipt(view,token,"0.5",status:"CANCELLED"); receipt(view,token,"0.5",status:"CANCELLED"); XCTAssertEqual(size(view),"1.5")
        receipt(view,token,"1",status:"CANCELLED"); receipt(view,token,"0.2"); receipt(view,token,"10","foreign"); XCTAssertEqual(size(view),"1")
    }
    func testUnrelatedFillRequiresAuthoritativeReconciliation() async throws {
        let view = PositionView(objectId:"a") { try Self.snapshot("4",tick:3) }; view.observe(try Self.snapshot("2"))
        let token = try bind(view,.buy); receipt(view,token,"1")
        view.observeFill(market:"BTC",operationId:"external",orderId:"external-order"); view.observe(try Self.snapshot("4",tick:2))
        XCTAssertEqual(view.current.value.unavailableMarkets,["BTC"]); XCTAssertEqual(view.current.value.coverage.first?.status,"unavailable")
        XCTAssertThrowsError(try view.begin(market:"BTC",side:.buy))
        await view.accounted(token); XCTAssertEqual(size(view),"4"); XCTAssertEqual(view.current.value.unavailableMarkets,[])
    }
    func testRecordedFillBeforeAttachmentAndReset() async throws {
        let view = PositionView(objectId:"a") { try Self.snapshot("0",tick:3) }
        XCTAssertThrowsError(try view.begin(market:"BTC",side:.buy)); view.observe(try Self.snapshot("2"))
        let token = try view.begin(market:"BTC",side:.sell)
        view.observeFill(market:"BTC",operationId:"op",orderId:"order-op"); XCTAssertEqual(view.current.value.unavailableMarkets,["BTC"])
        try view.bind(token,operation:operation("op",side:.sell),objectId:"a"); receipt(view,token,"2")
        XCTAssertEqual(view.current.value.unavailableMarkets,[]); XCTAssertEqual(size(view),"0")
        view.invalidate(); XCTAssertEqual(view.current.value.coverage.first?.status,"unavailable")
        view.reset(); view.observe(try Self.snapshot("2",tick:9)); receipt(view,token,"2"); await view.accounted(token)
        XCTAssertEqual(view.current.value.positions.count,0); XCTAssertEqual(view.current.value.coverage.count,0)
    }
    func testBoundedReservationsAndCancellation() throws {
        let view = PositionView(objectId:"a") { try Self.snapshot("0") }; view.observe(try Self.snapshot("0"))
        try view.begin(market:"BTC",side:.buy).cancelBeforeSubmission(); XCTAssertEqual(view.current.value.pendingMarkets,[])
        let token = try bind(view,.buy); token.cancelBeforeSubmission(); XCTAssertEqual(view.current.value.pendingMarkets,["BTC"])
        for _ in 1..<128 { _ = try view.begin(market:"BTC",side:.buy) }
        XCTAssertThrowsError(try view.begin(market:"BTC",side:.buy))
    }
    func testContradictorySnapshotAndAlreadyIncludedFill() throws {
        let view = PositionView(objectId:"a") { try Self.snapshot("0") }; view.observe(try Self.snapshot("2"))
        let token = try bind(view,.buy); receipt(view,token,"1")
        view.observeFill(market:"BTC",operationId:"older",orderId:"older-order",recordedAt:"2026-01-01T00:00:00Z")
        XCTAssertEqual(view.current.value.unavailableMarkets,[])
        view.observe(try Self.snapshot("4",tick:2)); XCTAssertEqual(view.current.value.unavailableMarkets,["BTC"])
    }

    func testDirectFillTapDrainsWithoutAsyncBufferAndUnregisters() async {
        let ws = WebSocketManager(baseURL: URL(string: "http://localhost:3052")!, token: "test", realmId: "r")
        let count = SendableBox(0)
        let observer = await ws.observePositionFills { _, _ in count.update { $0 += 1 } }
        let frame = #"{"type":"fill.recorded","entityId":"a","fill":{"id":"fill","market":"BTC"}}"#
        for _ in 0..<2048 { await ws.injectMessage(frame) }
        XCTAssertEqual(count.value, 2048)
        await ws.removePositionFillObserver(observer)
        await ws.injectMessage(frame)
        XCTAssertEqual(count.value, 2048)
        await ws.disconnect()
    }

    private func failed(_ outcome: String, id: String = "rejected") throws -> ArcaSDK.Operation {
        let base = try JSONEncoder().encode(operation(id, side: .buy))
        var json = try JSONSerialization.jsonObject(with: base) as! [String: Any]
        json["state"] = "failed"; json["outcome"] = outcome
        return try JSONDecoder().decode(ArcaSDK.Operation.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testRejectedScopeUnblocksAlreadyAccountedPeerWithoutDroppingItsExecution() async throws {
        let reads = SendableBox(0)
        let view = PositionView(objectId: "a") { reads.update { $0 += 1 }; return try Self.snapshot("3", tick: 4) }
        view.observe(try Self.snapshot("2"))
        let rejected = try bind(view, .buy, "rejected"), successful = try bind(view, .buy, "successful")
        receipt(view, successful, "1", "successful"); await view.accounted(successful)
        XCTAssertEqual(reads.value, 0); XCTAssertEqual(size(view), "3")
        let proof = try failed(#"{"definitiveRejection":true,"filledSize":"0","status":"FAILED"}"#)
        let retired = await view.retireNoExecution(rejected, operation: proof)
        XCTAssertTrue(retired); XCTAssertEqual(reads.value, 1); XCTAssertEqual(view.current.value.pendingMarkets, [])
        XCTAssertEqual(size(view), "3")
        XCTAssertEqual(view.current.value.coverage.first { $0.operationId == "rejected" }?.status, "no_execution")
        XCTAssertEqual(view.current.value.coverage.first { $0.operationId == "rejected" }?.orderId, "")
        XCTAssertEqual(view.current.value.coverage.first { $0.operationId == "successful" }?.status, "accounted")
        let again = await view.retireNoExecution(rejected, operation: proof)
        XCTAssertFalse(again); XCTAssertEqual(reads.value, 1)
    }

    func testAmbiguousOrContradictoryFailureCannotRetire() async throws {
        for outcome in [#"{"error":"response timeout"}"#, #"{"definitiveRejection":true,"filledSize":"1"}"#,
            #"{"definitiveRejection":true,"filledSize":"garbage"}"#, #"{"definitiveRejection":true,"executionQuantityFinal":false}"#,
            #"{"definitiveRejection":true,"venueOutcome":"unknown"}"#, #"{"definitiveRejection":true,"status":"FILLED"}"#,
            #"{"definitiveRejection":true,"status":{}}"#, #"{"definitiveRejection":"true"}"#, #"{"definitiveRejection":1}"#, #"{"definitiveRejection":true,"orderId":7}"#] {
            let view = PositionView(objectId: "a") { XCTFail("unsafe reconciliation"); return try Self.snapshot("2") }
            view.observe(try Self.snapshot("2")); let token = try bind(view, .buy, "rejected")
            let retired = await view.retireNoExecution(token, operation: try failed(outcome))
            XCTAssertFalse(retired, outcome); XCTAssertEqual(view.current.value.pendingMarkets, ["BTC"])
        }
        for recorded in [false, true] {
            let view = PositionView(objectId: "a") { XCTFail("contradictory execution"); return try Self.snapshot("2") }
            view.observe(try Self.snapshot("2")); let token = try bind(view, .buy, "rejected")
            if recorded { view.observeFill(market: "BTC", operationId: "rejected", orderId: "venue") }
            else { receipt(view, token, "0.1", "rejected") }
            let retired = await view.retireNoExecution(token, operation: try failed(#"{"definitiveRejection":true}"#))
            XCTAssertFalse(retired)
        }
    }

    func testNewScopeDuringRetirementReadRemainsPending() async throws {
        let started = expectation(description: "read started")
        let response = SendableBox<CheckedContinuation<ExchangeState, Never>?>(nil)
        let actual = PositionView(objectId: "a") {
            await withCheckedContinuation { continuation in response.update { $0 = continuation }; started.fulfill() }
        }
        actual.observe(try Self.snapshot("2")); let token = try bind(actual, .buy, "rejected")
        let proof = try failed(#"{"definitiveRejection":true}"#)
        let retirement = Task { await actual.retireNoExecution(token, operation: proof) }
        await fulfillment(of: [started], timeout: 2)
        let later = try bind(actual, .buy, "later"); receipt(actual, later, "1", "later")
        response.value?.resume(returning: try Self.snapshot("2", tick: 2))
        let retired = await retirement.value
        XCTAssertTrue(retired); XCTAssertEqual(size(actual), "3"); XCTAssertEqual(actual.current.value.pendingMarkets, ["BTC"])
        XCTAssertEqual(actual.current.value.coverage.first { $0.operationId == "later" }?.status, "execution")
    }

    func testOriginalOrderProofRequiresMatchingTerminalCompleteZero() async throws {
        for variant in 0..<7 {
            let view = PositionView(objectId: "a") { try Self.snapshot("2", tick: 4) }; view.observe(try Self.snapshot("2"))
            let token = try bind(view, .buy, "rejected")
            var order: [String: Any] = ["id":"venue", "market":"BTC", "side":"buy", "orderType":"MARKET", "size":"1", "filledSize":"0", "status":"CANCELLED", "reduceOnly":false, "timeInForce":"IOC", "leverage":1, "createdAt":"", "updatedAt":""]
            if variant == 1 { order["status"] = "PENDING" }
            if variant == 2 { order["filledSize"] = "0.1" }
            if variant == 3 { order["market"] = "ETH" }
            if variant == 4 { order["side"] = "sell" }
            let json: [String: Any] = ["order":order, "fills":[], "fillsComplete": variant != 5]
            let detail = try JSONDecoder().decode(SimOrderWithFills.self, from: JSONSerialization.data(withJSONObject: json))
            let proof = try failed(variant == 6 ? #"{"orderId":"other"}"# : #"{"error":"response timeout"}"#)
            let retired = await view.retireNoExecution(token, operation: proof, detail: detail)
            XCTAssertEqual(retired, variant == 0, "variant \(variant)")
        }
    }

    func testLateContradictionFencesRetirementRead() async throws {
        let started = expectation(description: "read started")
        let response = SendableBox<CheckedContinuation<ExchangeState, Never>?>(nil)
        let view = PositionView(objectId: "a") { await withCheckedContinuation { c in response.update { $0 = c }; started.fulfill() } }
        view.observe(try Self.snapshot("2")); let token = try bind(view, .buy, "rejected")
        let proof = try failed(#"{"definitiveRejection":true}"#)
        let retirement = Task { await view.retireNoExecution(token, operation: proof) }
        await fulfillment(of: [started], timeout: 2)
        view.observeFill(market: "BTC", operationId: "rejected", orderId: "venue")
        response.value?.resume(returning: try Self.snapshot("2", tick: 4)); _ = await retirement.value
        XCTAssertEqual(view.current.value.unavailableMarkets, ["BTC"]); XCTAssertEqual(view.current.value.pendingMarkets, ["BTC"])
        XCTAssertFalse(view.current.value.coverage.contains { $0.status == "no_execution" })
    }

}

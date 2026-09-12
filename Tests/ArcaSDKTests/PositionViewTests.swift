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

}

import XCTest
@testable import ArcaSDK

final class ProjectionWatchTests: XCTestCase {

    // MARK: - Decoding

    func testProjectedValuationDecodesAllFields() throws {
        let json = #"""
        {
          "objectId": "obj_1",
          "path": "/users/alice",
          "type": "exchange",
          "midsComplete": false,
          "pricingMode": "client",
          "equity": "1050",
          "realizedValue": "1000",
          "unrealizedValue": "50",
          "positions": [
            {"market": "hl:0:BTC", "side": "long", "size": "1", "entryPrice": "100", "markPrice": "150", "unrealizedPnl": "50", "valueUsd": "50"}
          ]
        }
        """#
        let v = try JSONDecoder().decode(ProjectedValuation.self, from: Data(json.utf8))
        XCTAssertEqual(v.objectId.rawValue, "obj_1")
        XCTAssertEqual(v.path, "/users/alice")
        XCTAssertEqual(v.type, "exchange")
        XCTAssertEqual(v.midsComplete, false)
        XCTAssertEqual(v.pricingMode, .client)
        XCTAssertEqual(v.equity, "1050")
        XCTAssertEqual(v.realizedValue, "1000")
        XCTAssertEqual(v.unrealizedValue, "50")
        XCTAssertEqual(v.positions?.count, 1)
    }

    func testProjectedValuationDecodesIdentityOnly() throws {
        let json = #"{"objectId": "obj_2", "path": "/users/bob", "type": "exchange"}"#
        let v = try JSONDecoder().decode(ProjectedValuation.self, from: Data(json.utf8))
        XCTAssertEqual(v.path, "/users/bob")
        XCTAssertNil(v.equity)
        XCTAssertNil(v.realizedValue)
        XCTAssertNil(v.unrealizedValue)
        XCTAssertNil(v.positions)
    }

    func testRealmEventDecodesProjectionDeltaFrame() throws {
        let json = #"""
        {
          "type": "object.valuation",
          "watchId": "w1",
          "projection": "board",
          "valuations": {
            "/users/alice": {"objectId": "obj_1", "path": "/users/alice", "type": "exchange", "equity": "1050"}
          },
          "removed": ["/users/gone"]
        }
        """#
        let event = try JSONDecoder().decode(RealmEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.watchId, "w1")
        XCTAssertEqual(event.projection, "board")
        XCTAssertEqual(event.valuations?.count, 1)
        XCTAssertEqual(event.valuations?["/users/alice"]?.equity, "1050")
        XCTAssertEqual(event.removed, ["/users/gone"])
    }

    // MARK: - Revalue math

    func testRevaluedRecomputesEquityFromRealizedPlusPnl() {
        let v = projected(
            equity: "1050", realized: "1000", unrealized: "50",
            positions: [position(market: "hl:0:BTC", side: "long", size: "1", entry: "100", pnl: "50")]
        )
        let out = v.revalued(with: ["hl:0:BTC": "300"])
        // long 1 @ entry 100, mark 300 → pnl 200; equity = 1000 + 200
        XCTAssertEqual(out.unrealizedValue, "200")
        XCTAssertEqual(out.equity, "1200")
        XCTAssertEqual(out.positions?.first?.markPrice, "300")
        XCTAssertEqual(out.realizedValue, "1000")
    }

    func testRevaluedShiftsEquityByPnlDeltaWithoutRealized() {
        let v = projected(
            equity: "1050", realized: nil, unrealized: nil,
            positions: [position(market: "hl:0:BTC", side: "long", size: "1", entry: "100", pnl: "50")]
        )
        let out = v.revalued(with: ["hl:0:BTC": "300"])
        // pnl 50 → 200, delta +150; equity 1050 + 150; unrealized not projected → stays nil
        XCTAssertEqual(out.equity, "1200")
        XCTAssertNil(out.unrealizedValue)
    }

    func testRevaluedWithoutPositionsIsIdentity() {
        let v = projected(equity: "500", realized: nil, unrealized: nil, positions: nil)
        let out = v.revalued(with: ["hl:0:BTC": "300"])
        XCTAssertEqual(out.equity, "500")
    }

    func testRevaluedShortPosition() {
        let v = projected(
            equity: "1000", realized: "1000", unrealized: "0",
            positions: [position(market: "hl:0:ETH", side: "short", size: "2", entry: "100", pnl: "0")]
        )
        let out = v.revalued(with: ["hl:0:ETH": "90"])
        // short 2 @ 100 → mark 90: pnl = -2 * (90-100) = 20
        XCTAssertEqual(out.unrealizedValue, "20")
        XCTAssertEqual(out.equity, "1020")
    }

    // MARK: - Stream behavior (delta merge / removed / other-watch)

    func testProjectionStreamMergesDeltaAndDropsRemoved() async throws {
        let arca = makeArca()
        let stream = try await startProjectionStream(arca)

        // Initial snapshot from the watch reply.
        XCTAssertEqual(stream.valuations.value.count, 2)
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.equity, "1000")
        XCTAssertEqual(stream.valuations.value["/users/bob"]?.equity, "2000")

        // Partial frame: only alice changes; bob must survive.
        let merged = expectation(description: "delta merged")
        let obs1 = stream.valuations.onChange { vals in
            if vals["/users/alice"]?.equity == "1111" && vals["/users/bob"]?.equity == "2000" {
                merged.fulfill()
            }
        }
        await arca.ws.injectMessage(#"""
        {"type": "object.valuation", "watchId": "w1", "projection": "board",
         "valuations": {"/users/alice": {"objectId": "obj_1", "path": "/users/alice", "type": "exchange", "equity": "1111"}}}
        """#)
        await fulfillment(of: [merged], timeout: 2.0)
        stream.valuations.removeObserver(obs1)

        // Removal frame: bob deleted, alice updated in the same frame.
        let removedApplied = expectation(description: "removed applied")
        let obs2 = stream.valuations.onChange { vals in
            if vals["/users/bob"] == nil && vals["/users/alice"]?.equity == "1200" {
                removedApplied.fulfill()
            }
        }
        await arca.ws.injectMessage(#"""
        {"type": "object.valuation", "watchId": "w1", "projection": "board",
         "valuations": {"/users/alice": {"objectId": "obj_1", "path": "/users/alice", "type": "exchange", "equity": "1200"}},
         "removed": ["/users/bob"]}
        """#)
        await fulfillment(of: [removedApplied], timeout: 2.0)
        stream.valuations.removeObserver(obs2)
        XCTAssertEqual(stream.valuations.value.count, 1)

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testProjectionStreamIgnoresOtherWatchIds() async throws {
        let arca = makeArca()
        let stream = try await startProjectionStream(arca)

        await arca.ws.injectMessage(#"""
        {"type": "object.valuation", "watchId": "other-watch", "projection": "board",
         "valuations": {"/users/alice": {"objectId": "obj_1", "path": "/users/alice", "type": "exchange", "equity": "9999"}},
         "removed": ["/users/bob"]}
        """#)
        // Give the event loop a beat, then confirm nothing changed.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stream.valuations.value["/users/alice"]?.equity, "1000")
        XCTAssertEqual(stream.valuations.value["/users/bob"]?.equity, "2000")

        await stream.stop()
        await arca.ws.disconnect()
    }

    func testProjectionStreamRemarksOnMidsTick() async throws {
        let arca = makeArca()
        let stream = try await startProjectionStream(arca, valuationsJSON: #"""
        [{"objectId": "obj_1", "path": "/users/alice", "type": "exchange",
          "equity": "1050", "realizedValue": "1000", "unrealizedValue": "50",
          "positions": [{"market": "hl:0:BTC", "side": "long", "size": "1", "entryPrice": "100", "markPrice": "150", "unrealizedPnl": "50", "valueUsd": "50"}]}]
        """#)

        let remarked = expectation(description: "re-marked on mids")
        let obs = stream.valuations.onChange { vals in
            if vals["/users/alice"]?.equity == "1200" {
                remarked.fulfill()
            }
        }
        await arca.ws.injectMessage(#"{"type": "mids.updated", "mids": {"hl:0:BTC": "300"}}"#)
        await fulfillment(of: [remarked], timeout: 2.0)
        stream.valuations.removeObserver(obs)

        await stream.stop()
        await arca.ws.disconnect()
    }

    // MARK: - Helpers

    /// Starts a projection watch by resolving the pending `watch_projection`
    /// request with an injected `projection_watch_created` reply. Request IDs
    /// are deterministic per manager ("proj-1" for the first request).
    private func startProjectionStream(
        _ arca: Arca,
        valuationsJSON: String? = nil
    ) async throws -> ProjectionWatchStream {
        let snapshot = valuationsJSON ?? #"""
        [{"objectId": "obj_1", "path": "/users/alice", "type": "exchange", "equity": "1000"},
         {"objectId": "obj_2", "path": "/users/bob", "type": "exchange", "equity": "2000"}]
        """#
        let reply = #"""
        {"type": "projection_watch_created", "requestId": "proj-1", "watchId": "w1",
         "projection": "board", "fields": ["equity", "realizedValue", "unrealizedValue", "positions"],
         "valuations": \#(snapshot)}
        """#

        let streamTask = Task { try await arca.watchProjection(name: "board") }
        // The pending request registers synchronously inside the actor call;
        // injecting twice with a pause covers scheduling races (the second
        // inject is a no-op once the request has resolved).
        try? await Task.sleep(nanoseconds: 150_000_000)
        await arca.ws.injectMessage(reply)
        try? await Task.sleep(nanoseconds: 150_000_000)
        await arca.ws.injectMessage(reply)
        return try await streamTask.value
    }

    private func projected(
        equity: String?, realized: String?, unrealized: String?, positions: [PositionValue]?
    ) -> ProjectedValuation {
        ProjectedValuation(
            objectId: ObjectID("obj_1"),
            path: "/users/alice",
            type: "exchange",
            equity: equity,
            realizedValue: realized,
            unrealizedValue: unrealized,
            positions: positions
        )
    }

    private func position(market: String, side: String, size: String, entry: String, pnl: String) -> PositionValue {
        let json = #"{"market": "\#(market)", "side": "\#(side)", "size": "\#(size)", "entryPrice": "\#(entry)", "markPrice": "\#(entry)", "unrealizedPnl": "\#(pnl)", "valueUsd": "\#(pnl)"}"#
        return try! JSONDecoder().decode(PositionValue.self, from: Data(json.utf8))
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: .ephemeral
        )
    }

    private func fakeJwt() -> String {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"realmId":"rlm_test","sub":"usr_test"}"#)
        return "\(header).\(payload).fakesig"
    }

    private func base64url(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

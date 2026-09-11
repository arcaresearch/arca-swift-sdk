import XCTest
@testable import ArcaSDK

final class ExchangeStateWatchTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ExchangeStateWatchProtocol.self] + (sessionConfig.protocolClasses ?? [])
        ExchangeStateWatchProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        ExchangeStateWatchProtocol.reset()
        super.tearDown()
    }

    func testWatchExchangeStateUsesInlineStateWhenPendingIntentsPresent() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)

        let updated = expectation(description: "inline exchange state applied")
        let observer = stream.exchangeState.onChange { state in
            if state?.pendingIntents?.count == 1 {
                updated.fulfill()
            }
        }

        await arca.ws.injectMessage(#"""
        {
          "type": "exchange.updated",
          "entityId": "obj_1",
          "entityPath": "/exchanges/main",
          "exchangeState": {
            "account": {
              "id": "act_1",
              "realmId": "rlm_test",
              "name": "main",
              "createdAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            },
            "marginSummary": {
              "equity": "1200",
              "initialMarginUsed": "0",
              "maintenanceMarginRequired": "0",
              "availableToWithdraw": "1200",
              "totalNtlPos": "0",
              "totalUnrealizedPnl": "0"
            },
            "positions": [],
            "openOrders": [],
            "pendingIntents": [
              {
                "operationId": "op_1",
                "operationPath": "/ops/1",
                "market": "hl:0:BTC",
                "side": "buy",
                "size": "0.1",
                "orderType": "MARKET",
                "reduceOnly": false,
                "createdAt": "2026-01-01T00:00:00Z"
              }
            ]
          }
        }
        """#)

        await fulfillment(of: [updated], timeout: 1.0)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)

        stream.exchangeState.removeObserver(observer)
        await stream.stop()
        await arca.ws.disconnect()
    }

    func testUnavailableStateClearsMoneyWithoutRefetchAndRecoversOnPush() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        let initial = try XCTUnwrap(stream.exchangeState.value)
        let cleared = expectation(description: "previous observation cleared")
        let observer = stream.exchangeState.onChange { state in
            if state == nil { cleared.fulfill() }
        }
        await arca.ws.injectMessage(#"{"type":"exchange.updated","entityId":"obj_1","exchangeStateUnavailable":true}"#)
        await fulfillment(of: [cleared], timeout: 1)
        stream.exchangeState.removeObserver(observer)
        XCTAssertNil(stream.exchangeState.value)
        XCTAssertEqual(stream.state.value, .reconnecting)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)

        let restored = expectation(description: "fresh observation restored")
        let restoreObserver = stream.exchangeState.onChange { state in
            if state != nil { restored.fulfill() }
        }
        let event = RealmEvent(type: "exchange.updated", entityId: "obj_1", exchangeState: initial)
        let data = try JSONEncoder().encode(event)
        await arca.ws.injectMessage(String(decoding: data, as: UTF8.self))
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(stream.exchangeState.value?.marginSummary.equity, "1000")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        stream.exchangeState.removeObserver(restoreObserver)
        await stream.stop()
        await arca.ws.disconnect()
    }

    func testQuietMirrorObservationExpiresWithoutRefetch() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        let initial = try XCTUnwrap(stream.exchangeState.value)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        state["tradingAllocation"] = ["revision": "1", "preferences": [:], "projectionUnavailable": false,
                                      "asOf": formatter.string(from: now), "validUntil": formatter.string(from: now.addingTimeInterval(0.1))] as [String: Any]
        let expired = expectation(description: "quiet mirror expired")
        let observer = stream.exchangeState.onChange { state in if state == nil { expired.fulfill() } }
        let data = try JSONSerialization.data(withJSONObject: ["type": "exchange.updated", "entityId": "obj_1", "exchangeState": state])
        await arca.ws.injectMessage(String(decoding: data, as: UTF8.self))
        await fulfillment(of: [expired], timeout: 1)
        XCTAssertNil(stream.exchangeState.value)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        stream.exchangeState.removeObserver(observer)
        await stream.stop()
        await arca.ws.disconnect()
    }

    /// `exchange.updated` has no durable log and a deferred enrichment is
    /// dropped without a deliverySeq, so after an invalidation the next push
    /// is not guaranteed. The bounded recovery read is the only way back.
    func testInvalidatedObservationRecoversThroughBoundedReadWhenNoPushArrives() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        let cleared = expectation(description: "observation cleared")
        let observer = stream.exchangeState.onChange { state in if state == nil { cleared.fulfill() } }
        await arca.ws.injectMessage(#"{"type":"exchange.updated","entityId":"obj_1","exchangeStateUnavailable":true}"#)
        await fulfillment(of: [cleared], timeout: 1)
        stream.exchangeState.removeObserver(observer)
        // Not immediate: the first attempt waits ~1s.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        XCTAssertEqual(stream.state.value, .reconnecting)

        let deadline = Date().addingTimeInterval(3)
        while stream.exchangeState.value == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(stream.exchangeState.value, "recovery read must restore the observation")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 2)
        // A restored state cancels the schedule: no further reads.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 2)
        await stream.stop()
        await arca.ws.disconnect()
    }

    func testServerResyncMarkerTriggersReRead() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        let reapplied = expectation(description: "re-read applied after the resync marker")
        reapplied.assertForOverFulfill = false
        let observer = stream.exchangeState.onChange { state in if state != nil { reapplied.fulfill() } }
        await arca.ws.injectMessage(#"{"type":"stream.resync"}"#)
        await fulfillment(of: [reapplied], timeout: 2)
        stream.exchangeState.removeObserver(observer)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 2)
        await stream.stop()
        await arca.ws.disconnect()
    }

    func testRefreshHookAndRegistryReReadUntilStop() async throws {
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 1)
        XCTAssertEqual(arca.exchangeStateRefreshers.value["obj_1"]?.count, 1)

        stream.refresh()
        var deadline = Date().addingTimeInterval(2)
        while ExchangeStateWatchProtocol.stateRequestCount < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 2)

        // The client-level nudge an accounted order uses.
        arca.refreshExchangeStateWatches(objectId: "obj_1")
        deadline = Date().addingTimeInterval(2)
        while ExchangeStateWatchProtocol.stateRequestCount < 3 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 3)
        arca.refreshExchangeStateWatches(objectId: "obj_other")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 3)

        await stream.stop()
        XCTAssertTrue(arca.exchangeStateRefreshers.value.isEmpty, "stop must unregister the hook")
        arca.refreshExchangeStateWatches(objectId: "obj_1")
        stream.refresh()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 3, "a stopped stream never reads")
        await arca.ws.disconnect()
    }

    func testQuietPaperRefreshLearnsPolicyAndStopsAtTeardown() async throws {
        ExchangeStateWatchProtocol.refreshScenario = .quiet
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        XCTAssertNil(stream.exchangeState.value?.collateralModel)
        let refreshed = expectation(description: "quiet policy refresh")
        let observer = stream.exchangeState.onChange { state in
            if state?.collateralModel?.crossDexReservationEnforced == true { refreshed.fulfill() }
        }
        await fulfillment(of: [refreshed], timeout: 7)
        stream.exchangeState.removeObserver(observer)
        XCTAssertEqual(stream.exchangeState.value?.collateralModel?.crossDexAvailableUsd, "0")
        await stream.stop()
        let count = ExchangeStateWatchProtocol.stateRequestCount
        try await Task.sleep(nanoseconds: 5_200_000_000)
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, count)
        await arca.ws.disconnect()
    }

    func testDelayedQuietRefreshCannotReplaceNewerExchangeEvent() async throws {
        ExchangeStateWatchProtocol.refreshScenario = .delayed
        let arca = makeArca()
        let stream = try await arca.watchExchangeState(objectId: "obj_1")
        let deadline = Date().addingTimeInterval(7)
        while ExchangeStateWatchProtocol.stateRequestCount < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ExchangeStateWatchProtocol.stateRequestCount, 2)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stream.exchangeState.value!)) as? [String: Any])
        var summary = state["marginSummary"] as! [String: Any]
        summary["equity"] = "1200"
        state["marginSummary"] = summary
        let event = try JSONSerialization.data(withJSONObject: ["type": "exchange.updated", "entityId": "obj_1", "exchangeState": state])
        await arca.ws.injectMessage(String(decoding: event, as: UTF8.self))
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(stream.exchangeState.value?.marginSummary.equity, "1200")
        XCTAssertNil(stream.exchangeState.value?.collateralModel, "stale refresh must be discarded")
        await stream.stop()
        await arca.ws.disconnect()
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig
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

private final class ExchangeStateWatchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _stateRequestCount = 0
    enum RefreshScenario { case normal, quiet, delayed }
    private static var _refreshScenario = RefreshScenario.normal
    private let stopped = SendableBox(false)

    static var refreshScenario: RefreshScenario {
        get { lock.lock(); defer { lock.unlock() }; return _refreshScenario }
        set { lock.lock(); _refreshScenario = newValue; lock.unlock() }
    }

    static var stateRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stateRequestCount
    }

    static func reset() {
        lock.lock()
        _stateRequestCount = 0
        _refreshScenario = .normal
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.hasPrefix("/api/v1/objects/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var body: String
        var delay: TimeInterval = 0
        switch url.path {
        case "/api/v1/objects/obj_1":
            body = #"""
            {
              "success": true,
              "data": {
                "object": {
                  "id": "obj_1",
                  "realmId": "rlm_test",
                  "path": "/exchanges/main",
                  "type": "exchange",
                  "denomination": "USD",
                  "status": "active",
                  "metadata": null,
                  "deletedAt": null,
                  "systemOwned": false,
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-01T00:00:00Z"
                },
                "operations": [],
                "events": [],
                "deltas": [],
                "balances": []
              }
            }
            """#
        case "/api/v1/objects/obj_1/exchange/state":
            Self.lock.lock()
            Self._stateRequestCount += 1
            Self.lock.unlock()
            body = #"""
            {
              "success": true,
              "data": {
                "account": {
                  "id": "act_1",
                  "realmId": "rlm_test",
                  "name": "main",
                  "createdAt": "2026-01-01T00:00:00Z",
                  "updatedAt": "2026-01-01T00:00:00Z"
                },
                "marginSummary": {
                  "equity": "1000",
                  "initialMarginUsed": "0",
                  "maintenanceMarginRequired": "0",
                  "availableToWithdraw": "1000",
                  "totalNtlPos": "0",
                  "totalUnrealizedPnl": "0"
                },
                "positions": [],
                "openOrders": [],
                "pendingIntents": []
              }
            }
            """#
        default:
            body = #"{"success":false,"error":{"code":"NOT_FOUND","message":"Not found"}}"#
        }

        if url.path.hasSuffix("/exchange/state"), Self.refreshScenario != .normal {
            body = body.replacingOccurrences(of: "\"account\":", with: "\"stateRefreshIntervalMs\":5000,\"account\":")
            if Self.stateRequestCount > 1 {
                let model = #""collateralModel":{"crossDexReservationEnforced":true,"crossDexReservationRate":"0.1","totalCollateralUsd":"1000","nativeAvailableUsd":"500","crossDexAvailableUsd":"0"},"#
                body = body.replacingOccurrences(of: "\"account\":", with: model + "\"account\":")
                if Self.refreshScenario == .delayed { delay = 1 }
            }
        }

        let statusCode = url.path == "/api/v1/objects/obj_1" || url.path == "/api/v1/objects/obj_1/exchange/state" ? 200 : 404
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let responseBody = Data(body.utf8)
        let send: @Sendable () -> Void = { [self] in
            guard !stopped.value else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: send) }
        else { send() }
    }

    override func stopLoading() { stopped.update { $0 = true } }
}

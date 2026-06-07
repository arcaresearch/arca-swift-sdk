import XCTest
@testable import ArcaSDK

/// Exercises the position TP/SL helpers (`setStopLoss`, `setTakeProfit`,
/// `setPositionTpsl`, `clearPositionTpsl`) end-to-end through the HTTP client
/// using a configurable URLProtocol mock that records the order POST bodies and
/// the order cancellations the helpers issue.
final class ArcaExchangeTpslTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [TpslMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        TpslMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        TpslMockProtocol.reset()
        super.tearDown()
    }

    // MARK: - setStopLoss / setTakeProfit

    func testSetStopLossLongPlacesSellPositionTpsl() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/1", objectId: "obj_1", market: "hl:0:BTC",
            triggerPx: "55000", isolated: false
        )
        _ = try await handle.submitted

        let posts = TpslMockProtocol.capturedPosts
        XCTAssertEqual(posts.count, 1)
        let b = posts[0]
        XCTAssertEqual(b["side"] as? String, "sell", "long closes with sell")
        XCTAssertEqual(b["tpsl"] as? String, "sl")
        XCTAssertEqual(b["sizeToMax"] as? Bool, true)
        XCTAssertEqual(b["reduceOnly"] as? Bool, true)
        XCTAssertEqual(b["size"] as? String, "0", "unsized: closes whole position")
        XCTAssertEqual(b["isTrigger"] as? Bool, true)
        XCTAssertEqual(b["isMarket"] as? Bool, true)
        XCTAssertEqual(b["orderType"] as? String, "MARKET")
        XCTAssertEqual(b["triggerPx"] as? String, "55000")
        XCTAssertEqual(b["leverage"] as? Int, 5, "leverage carried from position")
        XCTAssertEqual(TpslMockProtocol.capturedDeletes.count, 0)
    }

    func testSetTakeProfitShortPlacesBuy() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(shortETH)],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setTakeProfit(
            path: "/op/tp/1", objectId: "obj_1", market: "hl:0:ETH",
            triggerPx: "2000", isolated: false
        )
        _ = try await handle.submitted

        let b = TpslMockProtocol.capturedPosts[0]
        XCTAssertEqual(b["side"] as? String, "buy", "short closes with buy")
        XCTAssertEqual(b["tpsl"] as? String, "tp")
    }

    func testSetStopLossNoPositionThrowsNotFound() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[],"total":0}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/2", objectId: "obj_1", market: "hl:0:BTC", triggerPx: "55000", isolated: false
        )
        do {
            _ = try await handle.submitted
            XCTFail("expected notFound")
        } catch let error as ArcaError {
            guard case .notFound = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(TpslMockProtocol.capturedPosts.count, 0)
    }

    func testReplaceCancelsExisting() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        TpslMockProtocol.ordersBody = envelope(#"{"orders":[\#(restingSL("ord_old_sl"))],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/3", objectId: "obj_1", market: "hl:0:BTC", triggerPx: "54000", isolated: false
        )
        _ = try await handle.submitted

        XCTAssertEqual(TpslMockProtocol.capturedDeletes, ["ord_old_sl"])
        XCTAssertEqual(TpslMockProtocol.capturedPosts.count, 1)
    }

    func testNoReplaceSkipsCancel() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        TpslMockProtocol.ordersBody = envelope(#"{"orders":[\#(restingSL("ord_old_sl"))],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/4", objectId: "obj_1", market: "hl:0:BTC", triggerPx: "54000",
            replace: false, isolated: false
        )
        _ = try await handle.submitted

        XCTAssertEqual(TpslMockProtocol.capturedDeletes.count, 0, "replace:false must not cancel")
        XCTAssertEqual(TpslMockProtocol.capturedPosts.count, 1)
    }

    func testTriggerLimitRequiresLimitPrice() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/5", objectId: "obj_1", market: "hl:0:BTC", triggerPx: "54000",
            isMarket: false // limit trigger but no limitPrice
        )
        do {
            _ = try await handle.submitted
            XCTFail("expected validation error")
        } catch let error as ArcaError {
            guard case .validation = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(TpslMockProtocol.capturedPosts.count, 0)
    }

    func testTriggerLimitUsesLimitPrice() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/6", objectId: "obj_1", market: "hl:0:BTC", triggerPx: "54000",
            isMarket: false, limitPrice: "53900", isolated: false
        )
        _ = try await handle.submitted

        let b = TpslMockProtocol.capturedPosts[0]
        XCTAssertEqual(b["orderType"] as? String, "LIMIT")
        XCTAssertEqual(b["price"] as? String, "53900")
        XCTAssertEqual(b["isMarket"] as? Bool, false)
    }

    func testInfersIsolatedFromMeta() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longCL)],"total":1}"#)
        TpslMockProtocol.metaBody = envelope(#"{"universe":[{"name":"hl:1:CL","symbol":"CL","exchange":"hl","index":0,"szDecimals":2,"maxLeverage":5,"onlyIsolated":true}]}"#)
        let arca = makeArca()

        let handle = arca.setStopLoss(
            path: "/op/sl/7", objectId: "obj_1", market: "hl:1:CL", triggerPx: "60"
        )
        _ = try await handle.submitted

        XCTAssertEqual(TpslMockProtocol.capturedPosts[0]["isolated"] as? Bool, true)
    }

    // MARK: - setPositionTpsl

    func testSetPositionTpslPlacesBothLegs() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        TpslMockProtocol.metaBody = envelope(#"{"universe":[{"name":"hl:0:BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}]}"#)
        let arca = makeArca()

        let result = try await arca.setPositionTpsl(
            path: "/op/tpsl/1", objectId: "obj_1", market: "hl:0:BTC",
            stopLossPx: "54000", takeProfitPx: "70000"
        )
        XCTAssertNotNil(result.stopLoss)
        XCTAssertNotNil(result.takeProfit)

        let posts = TpslMockProtocol.capturedPosts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0]["tpsl"] as? String, "sl")
        XCTAssertEqual(posts[0]["path"] as? String, "/op/tpsl/1/sl")
        XCTAssertEqual(posts[1]["tpsl"] as? String, "tp")
        XCTAssertEqual(posts[1]["path"] as? String, "/op/tpsl/1/tp")
    }

    func testSetPositionTpslRequiresOnePrice() async throws {
        let arca = makeArca()
        do {
            _ = try await arca.setPositionTpsl(path: "/op/tpsl/2", objectId: "obj_1", market: "hl:0:BTC")
            XCTFail("expected validation error")
        } catch let error as ArcaError {
            guard case .validation = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    /// Pins the true one-cancels-the-other linkage: `setPositionTpsl` must stamp
    /// BOTH legs with the same non-empty `ocoGroupId` so a fill (even partial)
    /// on one leg cancels the sibling. Without a shared id the bracket only
    /// falls back to position-state reconcile.
    func testSetPositionTpslSharesOcoGroupId() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        TpslMockProtocol.metaBody = envelope(#"{"universe":[{"name":"hl:0:BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}]}"#)
        let arca = makeArca()

        _ = try await arca.setPositionTpsl(
            path: "/op/tpsl/oco", objectId: "obj_1", market: "hl:0:BTC",
            stopLossPx: "54000", takeProfitPx: "70000"
        )

        let posts = TpslMockProtocol.capturedPosts
        XCTAssertEqual(posts.count, 2)
        let slGroup = posts[0]["ocoGroupId"] as? String
        let tpGroup = posts[1]["ocoGroupId"] as? String
        XCTAssertNotNil(slGroup, "SL leg must carry an ocoGroupId")
        XCTAssertFalse(slGroup?.isEmpty ?? true, "ocoGroupId must be non-empty")
        XCTAssertEqual(slGroup, tpGroup, "both legs must share one ocoGroupId")
    }

    /// Pins that an explicit `ocoGroupId` overrides the auto-minted one and is
    /// applied verbatim to both legs.
    func testSetPositionTpslExplicitOcoGroupId() async throws {
        TpslMockProtocol.positionsBody = envelope(#"{"positions":[\#(longBTC)],"total":1}"#)
        TpslMockProtocol.metaBody = envelope(#"{"universe":[{"name":"hl:0:BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}]}"#)
        let arca = makeArca()

        _ = try await arca.setPositionTpsl(
            path: "/op/tpsl/oco2", objectId: "obj_1", market: "hl:0:BTC",
            stopLossPx: "54000", takeProfitPx: "70000", ocoGroupId: "oco_explicit"
        )

        let posts = TpslMockProtocol.capturedPosts
        XCTAssertEqual(posts[0]["ocoGroupId"] as? String, "oco_explicit")
        XCTAssertEqual(posts[1]["ocoGroupId"] as? String, "oco_explicit")
    }

    /// Pins the advisory passthrough on the general order path: an `ocoGroupId`
    /// on `placeOrder` reaches the request body (forwarded to the venue, never
    /// part of the signed digest).
    func testPlaceOrderForwardsOcoGroupId() async throws {
        let arca = makeArca()

        let handle = arca.placeOrder(
            path: "/op/place/oco", objectId: "obj_1", market: "hl:0:BTC",
            side: .sell, orderType: .market, size: "0", ocoGroupId: "oco_grp_99"
        )
        _ = try await handle.submitted

        let posts = TpslMockProtocol.capturedPosts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0]["ocoGroupId"] as? String, "oco_grp_99")
    }

    /// Pins the read-on-demand surface: a CANCELLED order decodes its
    /// `ocoGroupId` and `cancelReason`, which `getOrder`/`listOrders` expose.
    func testSimOrderDecodesOcoAndCancelReason() throws {
        let json = #"""
        {"id":"ord_1","market":"hl:0:BTC","side":"sell","orderType":"MARKET",
         "size":"0","filledSize":"0","status":"CANCELLED","reduceOnly":true,
         "timeInForce":"GTC","leverage":5,
         "ocoGroupId":"oco_abc","cancelReason":"sibling_filled"}
        """#
        let order = try JSONDecoder().decode(SimOrder.self, from: Data(json.utf8))
        XCTAssertEqual(order.ocoGroupId, "oco_abc")
        XCTAssertEqual(order.cancelReason, "sibling_filled")
    }

    // MARK: - clearPositionTpsl

    func testClearPositionTpslCancelsBothLegs() async throws {
        TpslMockProtocol.ordersBody = envelope("""
        {"orders":[\(restingSL("ord_sl")),\(restingTP("ord_tp")),\(sizedSL("ord_other")),\(restingSLForCoin("ord_eth", "hl:0:ETH"))],"total":4}
        """)
        let arca = makeArca()

        let cleared = try await arca.clearPositionTpsl(path: "/op/clear/1", objectId: "obj_1", market: "hl:0:BTC")
        XCTAssertEqual(cleared.count, 2, "only unsized orders for hl:0:BTC")
        XCTAssertEqual(Set(TpslMockProtocol.capturedDeletes), Set(["ord_sl", "ord_tp"]))
    }

    func testClearPositionTpslFilterByLeg() async throws {
        TpslMockProtocol.ordersBody = envelope("""
        {"orders":[\(restingSL("ord_sl")),\(restingTP("ord_tp"))],"total":2}
        """)
        let arca = makeArca()

        let cleared = try await arca.clearPositionTpsl(
            path: "/op/clear/2", objectId: "obj_1", market: "hl:0:BTC", tpsl: .stopLoss
        )
        XCTAssertEqual(cleared.count, 1)
        XCTAssertEqual(cleared.first?.id.rawValue, "ord_sl")
        XCTAssertEqual(TpslMockProtocol.capturedDeletes, ["ord_sl"])
    }

    // MARK: - Fixtures

    private let longBTC = #"{"id":"pos_1","market":"hl:0:BTC","side":"long","size":"0.5","entryPrice":"60000","leverage":5,"marginUsed":"6000"}"#
    private let shortETH = #"{"id":"pos_2","market":"hl:0:ETH","side":"short","size":"2","entryPrice":"2500","leverage":3,"marginUsed":"1666"}"#
    private let longCL = #"{"id":"pos_cl","market":"hl:1:CL","side":"long","size":"1","entryPrice":"60","leverage":2,"marginUsed":"30"}"#

    private func restingSL(_ id: String) -> String { restingSLForCoin(id, "hl:0:BTC") }
    private func restingSLForCoin(_ id: String, _ market: String) -> String {
        #"{"id":"\#(id)","market":"\#(market)","side":"sell","orderType":"MARKET","size":"0","filledSize":"0","status":"WAITING_FOR_TRIGGER","reduceOnly":true,"timeInForce":"GTC","leverage":5,"tpsl":"sl","sizeToMax":true}"#
    }
    private func restingTP(_ id: String) -> String {
        #"{"id":"\#(id)","market":"hl:0:BTC","side":"sell","orderType":"MARKET","size":"0","filledSize":"0","status":"WAITING_FOR_TRIGGER","reduceOnly":true,"timeInForce":"GTC","leverage":5,"tpsl":"tp","sizeToMax":true}"#
    }
    private func sizedSL(_ id: String) -> String {
        #"{"id":"\#(id)","market":"hl:0:BTC","side":"sell","orderType":"MARKET","size":"0.5","filledSize":"0","status":"WAITING_FOR_TRIGGER","reduceOnly":true,"timeInForce":"GTC","leverage":5,"tpsl":"sl","sizeToMax":false}"#
    }

    private func envelope(_ data: String) -> String { #"{"success":true,"data":\#(data)}"# }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19998")!,
            urlSessionConfiguration: sessionConfig
        )
    }

    private func fakeJwt() -> String {
        let header = base64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64url(#"{"realmId":"rlm_test","sub":"usr_test"}"#)
        return "\(header).\(payload).fakesig"
    }

    private func base64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Mock URLProtocol

private final class TpslMockProtocol: URLProtocol {
    private static let lock = NSLock()
    static var positionsBody = #"{"success":true,"data":{"positions":[],"total":0}}"#
    static var ordersBody = #"{"success":true,"data":{"orders":[],"total":0}}"#
    static var metaBody = #"{"success":true,"data":{"universe":[]}}"#
    private static var _posts: [[String: Any]] = []
    private static var _deletes: [String] = []

    static var capturedPosts: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return _posts
    }
    static var capturedDeletes: [String] {
        lock.lock(); defer { lock.unlock() }; return _deletes
    }

    static func reset() {
        lock.lock()
        positionsBody = #"{"success":true,"data":{"positions":[],"total":0}}"#
        ordersBody = #"{"success":true,"data":{"orders":[],"total":0}}"#
        metaBody = #"{"success":true,"data":{"universe":[]}}"#
        _posts = []
        _deletes = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host == "localhost" && url.path.contains("/exchange/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private func respond(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 8192
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }

    private static let opEnvelope = #"{"success":true,"data":{"operation":{"id":"op_1","realmId":"rlm_test","path":"/op/x","type":"order","state":"completed","createdAt":"2026-01-01T00:00:00.000000Z","updatedAt":"2026-01-01T00:00:00.000000Z"}}}"#

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        if method == "GET", path.hasSuffix("/exchange/positions") {
            respond(Self.positionsBody)
        } else if method == "GET", path.hasSuffix("/exchange/market/meta") {
            respond(Self.metaBody)
        } else if method == "GET", path.hasSuffix("/exchange/orders") {
            respond(Self.ordersBody)
        } else if method == "DELETE", let range = path.range(of: "/exchange/orders/") {
            let id = String(path[range.upperBound...])
            Self.lock.lock(); Self._deletes.append(id); Self.lock.unlock()
            respond(Self.opEnvelope)
        } else if method == "POST", path.hasSuffix("/exchange/orders") {
            if let data = Self.readBody(request),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.lock.lock(); Self._posts.append(obj); Self.lock.unlock()
            }
            respond(Self.opEnvelope)
        } else {
            respond(#"{"success":true,"data":{}}"#)
        }
    }

    override func stopLoading() {}
}

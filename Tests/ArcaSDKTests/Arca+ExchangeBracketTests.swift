import XCTest
@testable import ArcaSDK

/// Exercises `openWithBracket` end-to-end through the HTTP client using a
/// URLProtocol mock that answers the atomic batch endpoint with a bracket
/// operation whose outcome lists one order summary per leg. Pins the
/// SDK contract: ONE batch call carrying [entry, tp, sl] under a grouping, and
/// one OrderHandle per leg, each resolving to its OWN orderId though all three
/// share the single bracket operation.
final class ArcaExchangeBracketTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [BracketMockProtocol.self] + (sessionConfig.protocolClasses ?? [])
        BracketMockProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        BracketMockProtocol.reset()
        super.tearDown()
    }

    func testOpenWithBracketIssuesOneCallWithEntryAndTriggers() async throws {
        let arca = makeArca()

        let result = try arca.openWithBracket(
            path: "/op/bracket/1", objectId: "obj_1", market: "hl:0:BTC",
            side: .buy, size: "0.01", takeProfitPx: "72000", stopLossPx: "58000"
        )
        // Resolve all three handles; only ONE HTTP call must be made.
        _ = try await result.entry.submitted
        _ = try await result.takeProfit?.submitted
        _ = try await result.stopLoss?.submitted

        let posts = BracketMockProtocol.capturedBatchPosts
        XCTAssertEqual(posts.count, 1, "exactly one batch POST")
        let body = posts[0]
        XCTAssertEqual(body["grouping"] as? String, "normalTpsl")
        let orders = body["orders"] as? [[String: Any]] ?? []
        XCTAssertEqual(orders.count, 3)

        // Entry leg first, not reduce-only.
        XCTAssertEqual(orders[0]["side"] as? String, "buy")
        XCTAssertEqual(orders[0]["orderType"] as? String, "MARKET")
        XCTAssertEqual(orders[0]["size"] as? String, "0.01")
        XCTAssertNil(orders[0]["reduceOnly"], "entry must not be reduce-only")

        let tp = orders.first { ($0["tpsl"] as? String) == "tp" }
        XCTAssertEqual(tp?["side"] as? String, "sell")
        XCTAssertEqual(tp?["reduceOnly"] as? Bool, true)
        XCTAssertEqual(tp?["sizeToMax"] as? Bool, true)
        XCTAssertEqual(tp?["isTrigger"] as? Bool, true)
        XCTAssertEqual(tp?["triggerPx"] as? String, "72000")
        XCTAssertEqual(tp?["size"] as? String, "0")

        let sl = orders.first { ($0["tpsl"] as? String) == "sl" }
        XCTAssertEqual(sl?["side"] as? String, "sell")
        XCTAssertEqual(sl?["triggerPx"] as? String, "58000")
        XCTAssertEqual(sl?["reduceOnly"] as? Bool, true)
    }

    func testOpenWithBracketHandlesResolveOwnOrderId() async throws {
        let arca = makeArca()

        let result = try arca.openWithBracket(
            path: "/op/bracket/2", objectId: "obj_1", market: "hl:0:BTC",
            side: .buy, size: "0.01", takeProfitPx: "72000", stopLossPx: "58000"
        )
        XCTAssertNotNil(result.takeProfit)
        XCTAssertNotNil(result.stopLoss)

        // Each leg handle's operation outcome is rewritten to its own summary,
        // so the carried orderId differs per leg even though op id is shared.
        let entryResp = try await result.entry.submitted
        let tpResp = try await result.takeProfit!.submitted
        let slResp = try await result.stopLoss!.submitted
        XCTAssertEqual(try orderId(of: entryResp), "ord_entry")
        XCTAssertEqual(try orderId(of: tpResp), "ord_tp")
        XCTAssertEqual(try orderId(of: slResp), "ord_sl")
    }

    func testOpenWithBracketSizedTakeProfitIsPartial() async throws {
        let arca = makeArca()

        let result = try arca.openWithBracket(
            path: "/op/bracket/sized", objectId: "obj_1", market: "hl:0:BTC",
            side: .buy, size: "0.02",
            takeProfitPx: "72000", stopLossPx: "58000",
            takeProfitSz: "0.01" // scale out half; SL stays whole-position
        )
        _ = try await result.entry.submitted

        let orders = BracketMockProtocol.capturedBatchPosts[0]["orders"] as? [[String: Any]] ?? []
        let tp = orders.first { ($0["tpsl"] as? String) == "tp" }
        XCTAssertEqual(tp?["size"] as? String, "0.01")
        XCTAssertNil(tp?["sizeToMax"], "sized TP must NOT carry sizeToMax")
        XCTAssertEqual(tp?["reduceOnly"] as? Bool, true)

        let sl = orders.first { ($0["tpsl"] as? String) == "sl" }
        XCTAssertEqual(sl?["size"] as? String, "0")
        XCTAssertEqual(sl?["sizeToMax"] as? Bool, true)
    }

    func testOpenWithBracketOnlyStopLossOmitsTpLeg() async throws {
        let arca = makeArca()

        let result = try arca.openWithBracket(
            path: "/op/bracket/3", objectId: "obj_1", market: "hl:0:BTC",
            side: .buy, size: "0.01", stopLossPx: "58000"
        )
        _ = try await result.entry.submitted

        let orders = BracketMockProtocol.capturedBatchPosts[0]["orders"] as? [[String: Any]] ?? []
        XCTAssertEqual(orders.count, 2, "entry + sl only")
        XCTAssertFalse(orders.contains { ($0["tpsl"] as? String) == "tp" })
        XCTAssertNil(result.takeProfit)
        XCTAssertNotNil(result.stopLoss)
    }

    func testOpenWithBracketRequiresATrigger() async throws {
        let arca = makeArca()
        do {
            _ = try arca.openWithBracket(
                path: "/op/bracket/4", objectId: "obj_1", market: "hl:0:BTC", side: .buy, size: "0.01"
            )
            XCTFail("expected a validation error with no TP/SL")
        } catch let error as ArcaError {
            guard case .validation = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(BracketMockProtocol.capturedBatchPosts.count, 0, "no network call expected")
    }

    func testOpenWithBracketLimitEntryRequiresPrice() async throws {
        let arca = makeArca()
        do {
            _ = try arca.openWithBracket(
                path: "/op/bracket/5", objectId: "obj_1", market: "hl:0:BTC",
                side: .buy, size: "0.01", orderType: .limit, takeProfitPx: "72000"
            )
            XCTFail("expected a validation error for LIMIT entry without price")
        } catch let error as ArcaError {
            guard case .validation = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(BracketMockProtocol.capturedBatchPosts.count, 0)
    }

    // MARK: - Helpers

    private func orderId(of resp: OrderOperationResponse) throws -> String {
        let raw = try XCTUnwrap(resp.operation.outcome)
        let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        return try XCTUnwrap(obj?["orderId"] as? String)
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19997")!,
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

// MARK: - Mock URLProtocol (batch endpoint)

private final class BracketMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _posts: [[String: Any]] = []

    static var capturedBatchPosts: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return _posts
    }

    static func reset() {
        lock.lock(); _posts = []; lock.unlock()
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

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        if method == "POST", path.hasSuffix("/exchange/orders/batch") {
            if let data = Self.readBody(request),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.lock.lock(); Self._posts.append(obj); Self.lock.unlock()
            }
            // Bracket operation whose outcome lists one order summary per leg,
            // each carrying its own orderId — what lets each leg handle resolve
            // to its own order off the single shared operation.
            let outcome = "{\"grouping\":\"normalTpsl\",\"orders\":[" +
                "{\"orderId\":\"ord_entry\"}," +
                "{\"orderId\":\"ord_tp\",\"tpsl\":\"tp\"}," +
                "{\"orderId\":\"ord_sl\",\"tpsl\":\"sl\"}]}"
            let op: [String: Any] = [
                "id": "op_bracket", "realmId": "rlm_test", "path": "/op/bracket",
                "type": "order", "state": "completed", "outcome": outcome,
                "createdAt": "2026-01-01T00:00:00.000000Z", "updatedAt": "2026-01-01T00:00:00.000000Z",
            ]
            let env: [String: Any] = ["success": true, "data": ["operation": op]]
            let data = try! JSONSerialization.data(withJSONObject: env)
            respond(String(data: data, encoding: .utf8)!)
        } else {
            respond(#"{"success":true,"data":{}}"#)
        }
    }

    override func stopLoading() {}
}

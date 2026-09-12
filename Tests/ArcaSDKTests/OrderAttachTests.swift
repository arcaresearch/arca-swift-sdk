import XCTest
@testable import ArcaSDK

/// `arca.orderHandle(objectId:operationId:)` — attaching to an order this
/// client did not place. The load-bearing property is that attaching is a
/// read: an integration whose backend submits its orders must be able to
/// obtain a handle without placing, cancelling or resizing anything.
final class OrderAttachTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [OrderAttachProtocol.self] + (sessionConfig.protocolClasses ?? [])
        OrderAttachProtocol.reset()
    }

    override func tearDown() {
        sessionConfig = nil
        OrderAttachProtocol.reset()
        super.tearDown()
    }

    func testAttachesWithASingleReadAndNoMutation() async throws {
        let arca = makeArca()
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        let submitted = try await order.submitted
        XCTAssertEqual(submitted.operation.id.rawValue, "op_place")
        XCTAssertEqual(OrderAttachProtocol.requests, ["GET /api/v1/operations/op_place"])
        await arca.ws.disconnect()
    }

    func testAttachedReceiptUpdatesSharedDisplayBeforeReturning() async throws {
        let arca = makeArca()
        let view = arca.positionView(objectId: "obj-1")
        view.observe(try PositionViewTests.snapshot("0", market: "hl:0:BTC"))
        let update = try view.begin(market: "hl:0:BTC", side: .buy)
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        try await order.trackPositionUpdate(update)
        let receipt = try await order.executionReceipt(timeoutSeconds: 2)
        XCTAssertEqual(view.current.value.positions.first?.signedSize, receipt.filledSize)
        XCTAssertEqual(view.current.value.coverage.first?.operationId, "op_place")
        XCTAssertEqual(view.current.value.coverage.first?.status, "execution")
        XCTAssertTrue(OrderAttachProtocol.requests.allSatisfy { $0.hasPrefix("GET ") })
        arca.resetPositionView(objectId: "obj-1")
        await arca.ws.disconnect()
    }

    func testAccountedResolvesOnAnAlreadyRecordedOrder() async throws {
        OrderAttachProtocol.fillsComplete = [true]
        let arca = makeArca()
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        let detail = try await order.accounted(timeoutSeconds: 5)
        XCTAssertEqual(detail.fillsComplete, true)
        for request in OrderAttachProtocol.requests {
            XCTAssertTrue(request.hasPrefix("GET "), "attach + accounted issued a mutation: \(request)")
        }
        await arca.ws.disconnect()
    }

    func testAccountedConvergesOnAPendingOrder() async throws {
        OrderAttachProtocol.fillsComplete = [false, true]
        let arca = makeArca()
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        let detail = try await order.accounted(timeoutSeconds: 5)
        XCTAssertEqual(detail.fillsComplete, true)
        await arca.ws.disconnect()
    }

    func testRefusesAnotherAccountsOperation() async throws {
        // An id from another account must never resolve into a handle on this one.
        let arca = makeArca()
        do {
            _ = try await arca.orderHandle(objectId: "obj-other", operationId: "op_place")
            XCTFail("expected ORDER_IDENTITY_MISMATCH")
        } catch let error as ArcaError {
            guard case .unknown(let code, _, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "ORDER_IDENTITY_MISMATCH")
        }
        XCTAssertEqual(OrderAttachProtocol.requests, ["GET /api/v1/operations/op_place"])
        await arca.ws.disconnect()
    }

    func testRefusesANonOrderOperation() async throws {
        OrderAttachProtocol.operationType = "transfer"
        let arca = makeArca()
        do {
            _ = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
            XCTFail("expected ORDER_IDENTITY_MISMATCH")
        } catch let error as ArcaError {
            guard case .unknown(let code, let message, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "ORDER_IDENTITY_MISMATCH")
            XCTAssertTrue(message.contains("not an order"), "message should name the actual type: \(message)")
        }
        await arca.ws.disconnect()
    }

    func testAcceptsAnOperationWithNoRecordedAccount() async throws {
        // Absent input is not a mismatch — an older operation may not carry it.
        OrderAttachProtocol.includeInput = false
        let arca = makeArca()
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        let submitted = try await order.submitted
        XCTAssertEqual(submitted.operation.id.rawValue, "op_place")
        await arca.ws.disconnect()
    }

    func testFailedReceiptAutomaticallyRetiresVerifiedRejection() async throws {
        OrderAttachProtocol.rejectionOutcome = #"{\"definitiveRejection\":true,\"filledSize\":\"0\",\"status\":\"FAILED\"}"#
        let arca = makeArca(), view = arca.positionView(objectId: "obj-1")
        view.observe(try PositionViewTests.snapshot("0", market: "hl:0:BTC"))
        let token = try view.begin(market: "hl:0:BTC", side: .buy)
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        try await order.trackPositionUpdate(token)
        do { _ = try await order.executionReceipt(timeoutSeconds: 2); XCTFail("rejection must still fail") }
        catch let error as ArcaError { guard case .operationFailed = error else { return XCTFail("unexpected \(error)") } }
        XCTAssertEqual(view.current.value.coverage.first?.status, "no_execution")
        XCTAssertEqual(view.current.value.coverage.first?.orderId, "")
        XCTAssertTrue(OrderAttachProtocol.requests.allSatisfy { $0.hasPrefix("GET ") })
        arca.resetPositionView(objectId: "obj-1"); await arca.ws.disconnect()
    }

    func testOriginalOperationReadMustProveTerminalZeroExecution() async throws {
        OrderAttachProtocol.rejectionOutcome = #"{\"error\":\"response timeout\"}"#
        let arca = makeArca(), view = arca.positionView(objectId: "obj-1")
        view.observe(try PositionViewTests.snapshot("0", market: "hl:0:BTC"))
        let token = try view.begin(market: "hl:0:BTC", side: .buy)
        let order = try await arca.orderHandle(objectId: "obj-1", operationId: "op_place")
        try await order.trackPositionUpdate(token)
        let ambiguous = try await order.retirePositionUpdateIfNoExecution()
        XCTAssertFalse(ambiguous); XCTAssertEqual(view.current.value.pendingMarkets, ["hl:0:BTC"])
        OrderAttachProtocol.originalNoExecution = true
        let proven = try await order.retirePositionUpdateIfNoExecution()
        XCTAssertTrue(proven); XCTAssertEqual(view.current.value.coverage.first?.status, "no_execution")
        XCTAssertTrue(OrderAttachProtocol.requests.contains("GET /api/v1/objects/obj-1/exchange/orders/op_place"))
        XCTAssertTrue(OrderAttachProtocol.requests.allSatisfy { $0.hasPrefix("GET ") })
        arca.resetPositionView(objectId: "obj-1"); await arca.ws.disconnect()
    }

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
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class OrderAttachProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [String] = []
    private static var _fillsComplete: [Bool] = [true]
    private static var _operationType = "order"
    private static var _includeInput = true
    private static var _rejectionOutcome: String?
    private static var _originalNoExecution = false
    static var rejectionOutcome: String? {
        get { lock.lock(); defer { lock.unlock() }; return _rejectionOutcome }
        set { lock.lock(); _rejectionOutcome = newValue; lock.unlock() }
    }
    static var originalNoExecution: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _originalNoExecution }
        set { lock.lock(); _originalNoExecution = newValue; lock.unlock() }
    }

    static var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static var fillsComplete: [Bool] {
        get { lock.lock(); defer { lock.unlock() }; return _fillsComplete }
        set { lock.lock(); _fillsComplete = newValue; lock.unlock() }
    }

    static var operationType: String {
        get { lock.lock(); defer { lock.unlock() }; return _operationType }
        set { lock.lock(); _operationType = newValue; lock.unlock() }
    }

    static var includeInput: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _includeInput }
        set { lock.lock(); _includeInput = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock()
        _requests = []
        _fillsComplete = [true]
        _operationType = "order"
        _includeInput = true
        _rejectionOutcome = nil; _originalNoExecution = false
        lock.unlock()
    }

    private static func nextComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = _fillsComplete.first else { return true }
        if _fillsComplete.count > 1 { _fillsComplete.removeFirst() }
        return value
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost" && request.url?.port == 19998
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self._requests.append("\(request.httpMethod ?? "GET") \(url.path)")
        Self.lock.unlock()

        let input = #"{\"exchangeObjectId\":\"obj-1\",\"market\":\"hl:0:BTC\",\"side\":\"buy\",\"size\":\"0.01\",\"orderType\":\"MARKET\"}"#
        let outcome = Self.rejectionOutcome ?? #"{\"orderId\":\"ord_abc\",\"status\":\"filled\",\"filledSize\":\"0.01\",\"avgFillPrice\":\"50000\"}"#
        let body: String
        var status = 200
        switch url.path {
        case "/api/v1/operations/op_place":
            body = """
            {"success": true, "data": {"operation": {
              "id": "op_place", "realmId": "rlm_test", "path": "/op/order/btc-1",
              "type": "\(Self.operationType)", "state": "\(Self.rejectionOutcome == nil ? "completed" : "failed")",
              \(Self.includeInput ? "\"input\": \"\(input)\"," : "")
              "outcome": "\(outcome)",
              "createdAt": "2026-09-11T10:00:01.000000Z", "updatedAt": "2026-09-11T10:00:01.000000Z"
            }, "events": [], "deltas": []}}
            """
        case "/api/v1/objects/obj-1/exchange/orders/op_place":
            body = """
            {"success":true,"data":{"order":{"id":"","market":"hl:0:BTC","side":"buy","orderType":"MARKET","size":"1","filledSize":"0","status":"\(Self.originalNoExecution ? "FAILED" : "PENDING")","reduceOnly":false,"timeInForce":"IOC","leverage":1,"createdAt":"","updatedAt":""},"fills":[],"fillsComplete":\(Self.originalNoExecution)}}
            """
        case "/api/v1/objects/obj-1/exchange/orders/ord_abc":
            body = """
            {"success": true, "data": {
              "order": {"id": "ord_abc", "accountId": "acc-1", "realmId": "rlm_test", "market": "hl:0:BTC",
                        "side": "buy", "orderType": "MARKET", "price": null, "size": "0.01",
                        "filledSize": "0.01", "avgFillPrice": "50000", "status": "FILLED",
                        "reduceOnly": false, "timeInForce": "IOC", "leverage": 1,
                        "createdAt": "", "updatedAt": ""},
              "fills": [],
              "fillsComplete": \(Self.nextComplete())
            }}
            """
        default:
            status = 404
            body = #"{"success":false,"error":{"code":"NOT_FOUND","message":"Not found"}}"#
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

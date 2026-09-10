import XCTest
@testable import ArcaSDK

enum LifecycleHandleFixture {
    static let requested = "9007199254740993.123456789"
    static func view(complete: Bool = false) -> [String: Any] {
        let receipt: [String: Any] = ["objectId":"account", "operationId":"original", "leg":"0", "market":"gllt:3", "orderId":"3:order", "status":"FILLED",
            "filledSize":"3.123456789", "requestedSize":requested, "remainingSize":"9007199254740990", "executionState":"partial", "fulfillmentState":"partial",
            "remainingDisposition":"cancelled", "avgFillPrice":"2000.000000001", "averagePriceFinal":complete, "averagePriceSource":complete ? "ledger_vwap" : "venue_aggregate", "fillsComplete":complete]
        return ["intent":["realmId":"realm", "objectId":"account", "operationId":"original", "leg":"0", "venue":"gll-testnet", "venueAccountId":"123", "market":"gllt:3",
            "requestedSize":requested, "orderType":"MARKET", "side":"buy", "timeInForce":"GTC", "executionTimeInForce":"IOC", "isTrigger":false, "isMarketTrigger":false, "sizeToMax":false, "reduceOnly":false],
            "venueOrderId":"3:order", "submission":"accepted", "working":false, "execution":"partial", "terminal":true, "executedSize":"3.123456789", "executionQuantityFinal":true,
            "requestedSizeKnown":true, "remainingSize":"9007199254740990", "remainingDisposition":"cancelled", "accountedSize":complete ? "3.123456789" : "0", "accountingComplete":complete,
            "averagePrice":"2000.000000001", "averagePriceFinal":complete, "recoveryRequired":false, "executionReceipt":receipt]
    }
    static func json(_ value: [String:Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject:value), encoding:.utf8)! }
}

private final class LifecycleHandleProtocol: URLProtocol, @unchecked Sendable {
    static let calls = SendableBox<[String]>([])
    static let lost = SendableBox(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        Self.calls.update { $0.append(method + " " + (request.url?.absoluteString ?? path)) }
        var status = 200
        var data: [String:Any] = [:]
        if method == "POST" && (path.hasSuffix("/exchange/orders") || path.hasSuffix("/exchange/orders/batch")) {
            if Self.lost.value { status = 504 }
            else { data = ["operation":["id":"original", "realmId":"realm", "path":"/alice/original", "type":"order", "state":"completed", "actorType":"user", "createdAt":"2026-09-09T00:00:00Z", "updatedAt":"2026-09-09T00:00:00Z"]] }
        } else if path.hasSuffix("/exchange/order-lifecycle") {
            data = ["lifecycle":LifecycleHandleFixture.view()]
        } else if path.hasSuffix("/exchange/orders/3:order") {
            data = ["order":["id":"3:order", "accountId":"123", "realmId":"realm", "market":"gllt:3", "side":"buy", "orderType":"MARKET", "size":LifecycleHandleFixture.requested,
                "filledSize":"3.123456789", "avgFillPrice":"2000.000000001", "status":"FILLED", "reduceOnly":false, "timeInForce":"GTC", "leverage":1, "createdAt":"2026-09-09T00:00:00Z", "updatedAt":"2026-09-09T00:00:00Z"], "fills":[], "fillsComplete":true]
        } else { status = 404 }
        let body: [String:Any] = status == 200 ? ["success":true, "data":data] : ["success":false, "error":["code":"GATEWAY_TIMEOUT", "message":"response unavailable"]]
        let response = HTTPURLResponse(url:request.url!, statusCode:status, httpVersion:nil, headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive:response, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad:try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OrderLifecycleHandleTests: XCTestCase {
    private func makeArca() throws -> Arca {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LifecycleHandleProtocol.self]
        func b64(_ text:String)->String { Data(text.utf8).base64EncodedString().replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_") }
        return try Arca(token:"\(b64("{}" )).\(b64(#"{"realmId":"realm","sub":"user"}"#)).signature", baseURL:URL(string:"http://order-handle.test")!, urlSessionConfiguration:config)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertTrue(condition())
        if !condition() { throw CancellationError() }
    }
    private func requests(_ socket: MockWebSocketTransport) -> [[String:Any]] {
        socket.sent.compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }.filter { $0["action"] as? String == "watch_order_lifecycle" }
    }
    private func push(_ socket: MockWebSocketTransport, complete: Bool) throws {
        try push(socket, snapshot: LifecycleHandleFixture.view(complete:complete))
    }
    private func push(_ socket: MockWebSocketTransport, snapshot: [String:Any]) throws {
        let request = requests(socket).last!
        socket.deliver(try LifecycleHandleFixture.json(["type":"order.lifecycle.updated", "watchId":request["watchId"]!, "requestId":request["requestId"]!, "realmId":"realm", "objectId":"account", "operationId":"original", "leg":"0", "lifecycle":snapshot]))
    }

    func testFactoryUsesOriginalReceiptAndWaitsForAccountingAfterLostHTTP() async throws {
        for lost in [false,true] {
            LifecycleHandleProtocol.calls.update { $0 = [] }; LifecycleHandleProtocol.lost.update { $0 = lost }
            let arca = try makeArca(), factory = MockTransportFactory()
            await arca.ws.setTransportFactory(factory.make())
            let handle = arca.placeOrder(path:"/alice/original", objectId:"account", market:"gllt:3", side:.buy, orderType:.market, size:LifecycleHandleFixture.requested)
            let prompt = Task { try await handle.executionReceipt(timeoutSeconds:3) }
            try await waitFor { factory.socket(0)?.sentActions.contains("auth") == true }
            let socket = factory.socket(0)!; socket.deliver(#"{"type":"authenticated"}"#)
            try await waitFor { self.requests(socket).count == 1 }; try push(socket, complete:false)
            let receipt = try await prompt.value
            XCTAssertEqual(receipt.requestedSize,LifecycleHandleFixture.requested); XCTAssertFalse(receipt.fillsComplete); XCTAssertFalse(receipt.averagePriceFinal)
            let done = SendableBox(false)
            let filled = Task { let result = try await handle.filled(timeoutSeconds:3); done.update { $0 = true }; return result }
            try await waitFor { self.requests(socket).count == 2 }; try push(socket, complete:false)
            try await Task.sleep(nanoseconds:50_000_000)
            XCTAssertFalse(done.value); XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.contains("/orders/3") }.count,0)
            try push(socket, complete:true)
            let detail = try await filled.value; XCTAssertEqual(detail.fillsComplete,true)
            XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.hasPrefix("POST ") }.count,1)
            XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.contains("/orders/3") }.count,1)
            XCTAssertEqual(socket.sentActions.filter { $0 == "unwatch_order_lifecycle" }.count,2)
            if lost { XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.contains("operationPath=") }.count,2) }
            await arca.ws.disconnect()
        }
    }

    func testCancellationDoesNotWaitForOrAttachAfterLateSubmission() async throws {
        let submission = Task { try await Task.sleep(nanoseconds:10_000_000_000); return 1 }
        let continued = SendableBox(false)
        let waiting = Task { try await withOrderLifecycleDeadline(5) { _ = try await submission.value; try Task.checkCancellation(); continued.update { $0 = true }; return 1 } }
        try await Task.sleep(nanoseconds:20_000_000); waiting.cancel()
        do { _ = try await waiting.value; XCTFail("cancellation must end the wait") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(continued.value); submission.cancel()
    }

    func testBracketStopLossFollowsItsOriginalLeg() async throws {
        LifecycleHandleProtocol.calls.update { $0 = [] }; LifecycleHandleProtocol.lost.update { $0 = false }
        let arca = try makeArca(), factory = MockTransportFactory()
        await arca.ws.setTransportFactory(factory.make())
        let bracket = try arca.openWithBracket(path:"/alice/original",objectId:"account",market:"gllt:3",side:.buy,size:"10",takeProfitPx:"2100",stopLossPx:"1900")
        let attachment = Task { try await bracket.stopLoss!.lifecycleUpdates() }
        try await waitFor { factory.socket(0)?.sentActions.contains("auth") == true }
        let socket = factory.socket(0)!; socket.deliver(#"{"type":"authenticated"}"#)
        let watch = try await attachment.value
        try await waitFor { self.requests(socket).count == 1 }
        XCTAssertEqual(requests(socket)[0]["leg"] as? String,"2")
        XCTAssertEqual(requests(socket)[0]["operationId"] as? String,"original")
        XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.hasPrefix("POST ") }.count,1)
        await watch.stop(); await arca.ws.disconnect()
    }
    func testFillStreamRecoversCanonicalFillsOnceAfterLostHTTP() async throws {
        LifecycleHandleProtocol.calls.update { $0 = [] }; LifecycleHandleProtocol.lost.update { $0 = true }
        let arca = try makeArca(), factory = MockTransportFactory()
        await arca.ws.setTransportFactory(factory.make())
        let handle = arca.placeOrder(path:"/alice/original",objectId:"account",market:"gllt:3",side:.buy,orderType:.market,size:"10")
        let received = SendableBox<[String]>([])
        let consumer = Task { for try await fill in handle.fills(timeoutSeconds:3) {
            XCTAssertEqual(fill.fee,"0.123456789"); received.update { $0.append(fill.id.rawValue) }
        } }
        try await waitFor { factory.socket(0)?.sentActions.contains("auth") == true }
        let socket=factory.socket(0)!;socket.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { self.requests(socket).count == 1 }
        func fill(_ id:String,_ size:String)->[String:Any] {
            ["id":id,"orderId":"3:order","realmId":"realm","objectId":"account","operationId":"original","leg":"0","accountId":"123","market":"gllt:3","side":"buy","size":size,"price":"2000.000000001","fee":"0.123456789"]
        }
        var partial=LifecycleHandleFixture.view();partial["committedFills"]=[fill("a","1")];partial["accountedSize"]="1"
        try push(socket,snapshot:partial);try await waitFor { received.value == ["a"] };try push(socket,snapshot:partial)
        var final=LifecycleHandleFixture.view(complete:true);final["committedFills"]=[fill("a","1"),fill("b","1"),fill("c","1.123456789")]
        try push(socket,snapshot:final);try await consumer.value
        XCTAssertEqual(received.value,["a","b","c"])
        XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.hasPrefix("POST ") }.count,1)
        XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.contains("/orders/3") }.count,0)
        XCTAssertEqual(socket.sentActions.filter { $0 == "unwatch_order_lifecycle" }.count,1)
        await arca.ws.disconnect()
    }

    func testFillStreamCancellationReleasesPendingWatch() async throws {
        LifecycleHandleProtocol.calls.update { $0 = [] };LifecycleHandleProtocol.lost.update { $0 = false }
        let arca=try makeArca(),factory=MockTransportFactory();await arca.ws.setTransportFactory(factory.make())
        let handle=arca.placeOrder(path:"/alice/original",objectId:"account",market:"gllt:3",side:.buy,orderType:.market,size:"10")
        let consumer=Task { for try await _ in handle.fills(timeoutSeconds:3) { XCTFail("no committed fills were sent") } }
        try await waitFor { factory.socket(0)?.sentActions.contains("auth") == true }
        let socket=factory.socket(0)!;socket.deliver(#"{"type":"authenticated"}"#)
        try await waitFor { self.requests(socket).count == 1 }
        consumer.cancel();_ = try? await consumer.value
        try await waitFor { socket.sentActions.contains("unwatch_order_lifecycle") }
        XCTAssertEqual(LifecycleHandleProtocol.calls.value.filter { $0.hasPrefix("POST ") }.count,1)
        await arca.ws.disconnect()
    }

}

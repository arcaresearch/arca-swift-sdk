import XCTest
@testable import ArcaSDK

final class MemoryLeakTests: XCTestCase {

    private var sessionConfig: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockSuccessProtocol.self] + (sessionConfig.protocolClasses ?? [])
    }

    override func tearDown() {
        sessionConfig = nil
        super.tearDown()
    }

    private func makeArca() -> Arca {
        try! Arca(
            token: fakeJwt(),
            baseURL: URL(string: "http://localhost:19999")!,
            urlSessionConfiguration: sessionConfig,
            logLevel: .warning
        )
    }

    private func fakeJwt() -> String {
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString()
        let payload = Data(#"{"realmId":"rlm_test","sub":"usr_test"}"#.utf8).base64EncodedString()
        return "\(header).\(payload).fakesig"
    }

    func testWatchFillsDoesNotRetainArca() async throws {
        weak var weakArca: Arca?
        
        try await {
            let arca = makeArca()
            weakArca = arca
            
            // This should not create a retain cycle even if we don't call stop()
            _ = try await arca.watchFills(objectId: "obj_test")
        }()
        
        // Wait a bit to ensure async cleanup happens if needed
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertNil(weakArca, "Arca should be deallocated when dropped, breaking the fetchFills retain cycle")
    }

    func testOrderHandleFillsTimeoutDoesNotLeak() async throws {
        weak var weakArca: Arca?
        
        try await {
            let arca = makeArca()
            weakArca = arca
            
            let handle = arca.placeOrder(
                path: "/op/test",
                objectId: "obj_test",
                coin: "hl:BTC",
                side: .buy,
                orderType: .limit,
                size: "1",
                price: "50000"
            )
            
            let stream = handle.fills(timeoutSeconds: 60)
            var iterator = stream.makeAsyncIterator()
            // Pull one event or just drop the stream early
            _ = try? await iterator.next()
        }()
        
        // Without the fix, the timeout task would keep Arca alive for 60s
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertNil(weakArca, "Arca should be deallocated immediately when the fills stream is dropped")
    }

    func testMergedWatchObjectsUnsubscribesChildren() async throws {
        let arca = makeArca()
        
        let merged = try await arca.watchObjects(paths: ["obj_1", "obj_2"])
        
        let stream1 = merged.childStreams[0]
        let stream2 = merged.childStreams[1]
        
        // At this point, child streams should have callbacks registered
        XCTAssertFalse(stream1.updateCallbacks.value.isEmpty)
        XCTAssertFalse(stream2.updateCallbacks.value.isEmpty)
        
        // Dropping or stopping the merged stream should clear the child callbacks
        var iterator = merged.updates.makeAsyncIterator()
        _ = await iterator.next() // Get initial emit
        
        await merged.stop()
        
        // Allow continuations to process
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertTrue(stream1.updateCallbacks.value.isEmpty, "Merged stream should remove its onUpdate callback from child 1")
        XCTAssertTrue(stream2.updateCallbacks.value.isEmpty, "Merged stream should remove its onUpdate callback from child 2")
    }
}

// MARK: - Mocks

private final class MockSuccessProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    
    override func startLoading() {
        let data = """
        {
            "success": true,
            "data": {
                "object": {
                    "id": "obj_test",
                    "realmId": "rlm_test",
                    "path": "/users/test",
                    "type": "user",
                    "status": "active",
                    "systemOwned": false,
                    "createdAt": "2026-03-08T00:00:00.000000Z",
                    "updatedAt": "2026-03-08T00:00:00.000000Z"
                },
                "fills": [],
                "operations": [],
                "balances": [],
                "events": [],
                "deltas": []
            }
        }
        """.data(using: .utf8)!
        
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {}
}
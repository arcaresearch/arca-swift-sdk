import XCTest
@testable import ArcaSDK

final class LatestSnapshotCalculationTests: XCTestCase {
    func testSlowMidsConsumerKeepsDisjointMarketsAndNewLifetimeHasNoOldReplay() async {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "token", realmId: "realm")
        var iterator = await manager.midsEvents().makeAsyncIterator()
        await manager.injectMessage(#"{"type":"mids.snapshot","mids":{"A":"0","B":"0"}}"#)
        let first = await iterator.next()
        XCTAssertEqual(first, ["A": "0", "B": "0"])
        for i in 1...1000 {
            await manager.injectMessage("{\"type\":\"mids.updated\",\"mids\":{\"\(i % 2 == 0 ? "A" : "B")\":\"\(i)\"}}")
        }
        let latest = await iterator.next()
        XCTAssertEqual(latest, ["A": "1000", "B": "999"], "one queued complete snapshot, including the quiet market")
        await manager.unsubscribeMids()
        var nextLifetime = await manager.midsEvents().makeAsyncIterator()
        await manager.injectMessage(#"{"type":"mids.snapshot","mids":{"C":"1"}}"#)
        let fresh = await nextLifetime.next()
        XCTAssertEqual(fresh, ["C": "1"])
        await manager.disconnect()
    }

    func testEqualPriceObservationsRemainObservableWhenConsumerKeepsUp() async {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "token", realmId: "realm")
        var iterator = await manager.midsEvents().makeAsyncIterator()
        for _ in 0..<2 {
            await manager.injectMessage(#"{"type":"mids.updated","mids":{"A":"1"}}"#)
            let observed = await iterator.next()
            XCTAssertEqual(observed, ["A": "1"])
        }
        await manager.disconnect()
    }

    func testOverloadCompletesActiveWorkThenOnlyNewestPending() async {
        let entered = expectation(description: "first calculation entered")
        let completed = expectation(description: "first and newest publish")
        completed.expectedFulfillmentCount = 2
        let gate = SnapshotTestGate()
        let started = SendableBox<[Int]>([]), published = SendableBox<[Int]>([])
        let worker = LatestSnapshotCalculation<Int, Int>(calculate: { value in
            XCTAssertFalse(Thread.isMainThread)
            started.update { $0.append(value) }
            if value == 1 { await gate.pause(entered) }
            return value
        }, publish: { _, value in published.update { $0.append(value) }; completed.fulfill() })
        worker.submit(1)
        await fulfillment(of: [entered], timeout: 2)
        for value in 2...1000 { worker.submit(value) }
        await gate.resume()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(started.value, [1, 1000])
        XCTAssertEqual(published.value, [1, 1000], "continuous arrivals must not starve output")
        worker.stop()
    }

    func testStopRejectsNonCooperativeCompletionAndPendingWork() async {
        let entered = expectation(description: "calculation entered")
        let returned = expectation(description: "cancelled calculation returned")
        let noPublication = expectation(description: "stopped work must not publish")
        noPublication.isInverted = true
        let gate = SnapshotTestGate(), started = SendableBox<[Int]>([])
        let worker = LatestSnapshotCalculation<Int, Int>(calculate: { value in
            started.update { $0.append(value) }
            await gate.pause(entered)
            returned.fulfill()
            return value
        }, publish: { _, _ in noPublication.fulfill() })
        worker.submit(1)
        await fulfillment(of: [entered], timeout: 2)
        worker.submit(2)
        worker.stop()
        await gate.resume()
        await fulfillment(of: [returned, noPublication], timeout: 0.1)
        XCTAssertEqual(started.value, [1])
    }
}

private actor SnapshotTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause(_ entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

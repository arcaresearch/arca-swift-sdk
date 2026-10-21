import XCTest
@testable import ArcaSDK

final class MarketDataRecoveryTests: XCTestCase {
    func testRestoredNetworkAdvancesPendingBackoffAndFencesOldSleeper() throws {
        var retry = MarketRetryWindow()
        let old = retry.schedule(now: 1_000_000_000, delayMs: 16_000)
        let fast = try XCTUnwrap(retry.advance(now: 4_000_000_000, jitterMs: 123))
        XCTAssertEqual(fast.delayMs, 373)
        XCTAssertFalse(retry.take(old.token))
        XCTAssertTrue(retry.take(fast.token))
        XCTAssertFalse(retry.take(fast.token))
    }

    func testHintNeverCreatesRetryOrInterruptsAttemptAfterTimerWasConsumed() {
        var retry = MarketRetryWindow()
        XCTAssertNil(retry.advance(now: 1_000_000_000, jitterMs: 0))
        let pending = retry.schedule(now: 1_000_000_000, delayMs: 2_000)
        XCTAssertTrue(retry.take(pending.token))
        XCTAssertNil(retry.advance(now: 3_000_000_000, jitterMs: 0))
    }

    func testRestorationNeverDelaysSoonerOrAlreadyDueRetry() {
        var retry = MarketRetryWindow()
        let pending = retry.schedule(now: 1_000_000_000, delayMs: 400)
        XCTAssertNil(retry.advance(now: 1_100_000_000, jitterMs: 100))
        XCTAssertNil(retry.advance(now: 1_500_000_000, jitterMs: 0))
        XCTAssertTrue(retry.take(pending.token))
    }

    func testNetworkFlappingDoesNotKeepBypassingBackoffAndCancelPreservesCooldown() throws {
        var retry = MarketRetryWindow()
        _ = retry.schedule(now: 1_000_000_000, delayMs: 60_000)
        let fast = try XCTUnwrap(retry.advance(now: 2_000_000_000, jitterMs: 0))
        XCTAssertNil(retry.advance(now: 2_100_000_000, jitterMs: 0))
        XCTAssertTrue(retry.take(fast.token))
        // The next failure still supplies its exponential delay. A failed
        // accelerated attempt must not make repeated OS callbacks bypass it.
        retry.cancel()
        let next = retry.schedule(now: 3_000_000_000, delayMs: 60_000)
        XCTAssertNil(retry.advance(now: 31_999_999_999, jitterMs: 0))
        XCTAssertNotNil(retry.advance(now: 32_000_000_000, jitterMs: 249))
        XCTAssertFalse(retry.take(next.token))
    }

    func testCancelledOrReplacedSleeperCannotResurrectRetiredConnection() {
        var retry = MarketRetryWindow()
        let cancelled = retry.schedule(now: 1_000_000_000, delayMs: 2_000)
        retry.cancel()
        XCTAssertFalse(retry.take(cancelled.token))
        XCTAssertNil(retry.advance(now: 2_000_000_000, jitterMs: 0))
        let replaced = retry.schedule(now: 2_000_000_000, delayMs: 4_000)
        let current = retry.schedule(now: 3_000_000_000, delayMs: 8_000)
        XCTAssertFalse(retry.take(replaced.token))
        XCTAssertTrue(retry.take(current.token))
    }

    func testHintJitterStaysBounded() throws {
        for (jitter, expected) in [(-20, 250), (0, 250), (249, 499), (1_000, 499)] {
            var retry = MarketRetryWindow()
            _ = retry.schedule(now: 1_000_000_000, delayMs: 60_000)
            XCTAssertEqual(try XCTUnwrap(retry.advance(now: 2_000_000_000, jitterMs: jitter)).delayMs, expected)
        }
    }

    func testSourceRestorationReplacesPendingTimerAndLateCancelledSleeperCannotDial() async throws {
        let oldWait = expectation(description: "ordinary retry"), fastWait = expectation(description: "accelerated retry")
        let noOldDial = expectation(description: "cancelled timer must not dial"); noOldDial.isInverted = true
        let newDial = expectation(description: "accelerated attempt")
        let stage = SendableBox(0), attempts = SendableBox(0)
        let sleeps = RecoverySleeper { ns in
            if ns >= 2_000_000_000 { if stage.value == 0 { oldWait.fulfill() } }
            else { fastWait.fulfill() }
        }
        // Port 1 is intentionally refused locally: exercise URLSession's real
        // failure path without contacting a venue or opening an account stream.
        let source = HyperliquidMarketSource(url: URL(string: "ws://127.0.0.1:1")!, retrySleep: sleeps.sleep) { _, update in
            guard case let .connection(_, opened, retry, _) = update, opened == nil, retry == nil else { return }
            attempts.update { $0 += 1 }
            if stage.value == 1 { noOldDial.fulfill() }
            if stage.value == 2 { newDial.fulfill() }
        }
        await source.subscribe([.init(market: "hl:0:BTC", coin: "BTC")], revision: 1)
        await fulfillment(of: [oldWait], timeout: 3)
        stage.update { $0 = 1 }
        await source.networkAvailable()
        await fulfillment(of: [fastWait], timeout: 1)
        let delays = await sleeps.delays
        XCTAssertEqual(delays.count, 2)
        XCTAssertTrue((250_000_000...499_000_000).contains(delays.last ?? 0))
        await sleeps.release(index: 0)
        await fulfillment(of: [noOldDial], timeout: 0.1)
        XCTAssertEqual(attempts.value, 1)
        stage.update { $0 = 2 }
        await sleeps.release(index: 1)
        await fulfillment(of: [newDial], timeout: 1)
        await source.close()
        await sleeps.finish()
        XCTAssertEqual(attempts.value, 2)
    }

    func testSourceCloseCancelsAcceleratedRetryEvenIfSleeperIgnoresCancellation() async {
        let oldWait = expectation(description: "ordinary retry"), fastWait = expectation(description: "accelerated retry")
        let lateDial = expectation(description: "closed source must not dial"); lateDial.isInverted = true
        let closed = SendableBox(false)
        let sleeps = RecoverySleeper { ns in
            if ns >= 2_000_000_000 { oldWait.fulfill() } else { fastWait.fulfill() }
        }
        let source = HyperliquidMarketSource(url: URL(string: "ws://127.0.0.1:1")!, retrySleep: sleeps.sleep) { _, update in
            if closed.value, case let .connection(_, opened, retry, _) = update, opened == nil, retry == nil { lateDial.fulfill() }
        }
        await source.subscribe([.init(market: "hl:0:BTC", coin: "BTC")], revision: 1)
        await fulfillment(of: [oldWait], timeout: 3)
        await source.networkAvailable()
        await fulfillment(of: [fastWait], timeout: 1)
        await source.close(); closed.update { $0 = true }
        await source.networkAvailable()
        await sleeps.finish()
        await fulfillment(of: [lateDial], timeout: 0.1)
    }

    func testHintsRequireExistingOwnerAndCannotReachRetiredOrBackgroundSource() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "test", realmId: "test")
        let sources = SendableBox<[RecoveryPublicSource]>([])
        await manager.setPublicSourceFactory { _, _ in
            let source = RecoveryPublicSource()
            sources.update { $0.append(source) }
            return source
        }
        let market = try JSONDecoder().decode(Market.self, from: Data(#"{"name":"hl:0:BTC","venueSymbol":"BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}"#.utf8))
        let config = await manager.beginMarketDataConfiguration()
        await manager.configureMarketData(epoch: config, preference: .hyperliquid, network: .mainnet, markets: [market])
        await manager.notifyMarketDataNetworkAvailable()
        XCTAssertTrue(sources.value.isEmpty)
        let owner = await manager.registerPriceMarkets()
        await manager.updatePriceMarkets(owner, markets: [market.name])
        let first = try XCTUnwrap(sources.value.first)
        await manager.notifyMarketDataNetworkAvailable()
        let firstHints = await first.hints
        XCTAssertEqual(firstHints, 1)
        await manager.handleAppDidEnterBackground()
        await manager.notifyMarketDataNetworkAvailable()
        XCTAssertEqual(sources.value.count, 1)
        await manager.handleAppWillEnterForeground()
        await manager.notifyMarketDataNetworkAvailable()
        XCTAssertEqual(sources.value.count, 2)
        let second = try XCTUnwrap(sources.value.last)
        let retiredHints = await first.hints
        let newHints = await second.hints
        XCTAssertEqual(retiredHints, 1)
        XCTAssertEqual(newHints, 1)
        await manager.releasePriceMarkets(owner)
        await manager.notifyMarketDataNetworkAvailable()
        let releasedHints = await second.hints
        XCTAssertEqual(releasedHints, 1)
        XCTAssertEqual(sources.value.count, 2)
        await manager.disconnect()
    }
}

private actor RecoveryPublicSource: PublicMarketSource {
    private(set) var hints = 0
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) {}
    func networkAvailable() { hints += 1 }
    func close() {}
}

// Deliberately uncooperative cancellation proves source generation/timer fencing.
private actor RecoverySleeper {
    private var waits: [CheckedContinuation<Void, Never>?] = []
    private(set) var delays: [UInt64] = []
    private var finished = false
    let entered: @Sendable (UInt64) -> Void
    init(entered: @escaping @Sendable (UInt64) -> Void) { self.entered = entered }
    func sleep(_ ns: UInt64) async throws {
        guard !finished else { throw CancellationError() }
        await withCheckedContinuation { continuation in
            waits.append(continuation); delays.append(ns); entered(ns)
        }
    }
    func release(index: Int) {
        guard waits.indices.contains(index) else { return }
        let continuation = waits[index]; waits[index] = nil; continuation?.resume()
    }
    func finish() {
        finished = true
        for index in waits.indices { release(index: index) }
    }
}

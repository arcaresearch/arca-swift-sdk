import XCTest
@testable import ArcaSDK

final class PriceDeliveryDiagnosticsTests: XCTestCase {
    private let btc = "hl:0:BTC", eth = "hl:0:ETH"
    func testOptionalMainnetReceiptAndRecoveryTimingProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ARCA_PUBLIC_TIMING_PROBE"] == "1")
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "unused", realmId: "unused")
        let stream = try await manager.watchPriceDeliveryDiagnostics(markets: [btc])
        let finished = expectation(description: "first real receipt record")
        let reader = Task {
            var count = 0
            for await snapshot in stream {
                guard let value = snapshot["hl:0:BTC"] else { continue }
                XCTAssertGreaterThanOrEqual(value.publishedAtNanos, value.receivedAtNanos); XCTAssertNotNil(value.venueTimeMs)
                print("PUBLIC_TIMING_PROBE swift HL-mainnet revision=\(value.revision) receipt_to_publish_ms=\(Double(value.publishedAtNanos - value.receivedAtNanos) / 1e6)")
                count += 1
                if count == 1 { finished.fulfill() }
                if count == 5 { break }
            }
        }
        let owner = await manager.registerPriceMarkets(); await manager.updatePriceMarkets(owner, markets: [btc])
        let market = try JSONDecoder().decode(Market.self, from: Data(#"{"name":"hl:0:BTC","venueSymbol":"BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}"#.utf8))
        await manager.configureMarketData(epoch: manager.beginMarketDataConfiguration(), preference: .hyperliquid, network: .mainnet, markets: [market])
        await fulfillment(of: [finished], timeout: 20)
        // Bounded sampling, not a requirement that a quiet market change five times.
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let diagnostics = await manager.marketDataDiagnostics
        XCTAssertEqual(diagnostics.hyperliquidFailures, 0)
        let timing = diagnostics.hyperliquidConnection
        if let opened = timing.openedAtNanos, let attempt = timing.attemptAtNanos, let price = timing.firstPriceAtNanos {
            print("PUBLIC_TIMING_CONNECTION swift HL-mainnet handshake_ms=\(Double(opened - attempt) / 1e6) open_to_price_ms=\((Double(price) - Double(opened)) / 1e6)")
        } else { XCTFail("Missing actual connection timing") }
        reader.cancel(); await manager.disconnect()
    }
    func testExactValuesKeepReceiptsAcrossQuietSnapshotsAndABAChanges() throws {
        var r = try PriceDeliveryRecorder(markets: [btc, eth])
        r.stage([btc: "100", eth: "10", "hl:0:SOL": "1"], source: .arca, received: 10, venue: nil)
        let first = try XCTUnwrap(r.publish([btc: "100", eth: "10"], now: 20, committed: [btc, eth]))
        XCTAssertEqual(first.count, 2); XCTAssertEqual(first[btc]?.receivedAtNanos, 10)
        XCTAssertNil(r.publish([btc: "100", eth: "10"], now: 30, committed: [btc, eth]))
        r.stage([btc: "101"], source: .hyperliquid, received: 40, venue: 123)
        let second = try XCTUnwrap(r.publish([btc: "101", eth: "10"], now: 50, committed: [btc]))
        XCTAssertEqual(first[eth], second[eth]); XCTAssertEqual(second[btc]?.venueTimeMs, 123)
        r.stage([btc: "100"], source: .hyperliquid, received: 60, venue: nil)
        let third = try XCTUnwrap(r.publish([btc: "100", eth: "10"], now: 70, committed: [btc]))
        XCTAssertGreaterThan(third[btc]!.revision, first[btc]!.revision)
        XCTAssertEqual(third[btc]?.receivedAtNanos, 60); XCTAssertNil(third[btc]?.venueTimeMs)
        XCTAssertEqual(first[btc]?.price, "100")
    }
    func testUnrelatedPublicationCannotFlushDirectPendingAndFailureDiscardsIt() throws {
        var r = try PriceDeliveryRecorder(markets: [btc, eth])
        r.stage([btc: "100"], source: .hyperliquid, received: 10, venue: nil)
        XCTAssertNil(r.publish([btc: "100", eth: "10"], now: 20, committed: [eth]))
        r.clearDirectPending()
        XCTAssertNil(r.publish([btc: "100"], now: 30, committed: [btc]))
        r.stage([btc: "101", eth: "11"], source: .hyperliquid, received: 40, venue: nil)
        r.clearDirectPending(keep: [eth])
        XCTAssertEqual(Set(r.publish([btc: "101", eth: "11"], now: 50, committed: [btc, eth])!.keys), [eth])
        XCTAssertEqual(r.publish([:], now: 60, committed: []), [:])
        r.clear(); XCTAssertNil(r.publish([btc: "101"], now: 70, committed: [btc]))
    }
    func testObserverScopeIsExplicitAndBounded() throws {
        XCTAssertThrowsError(try PriceDeliveryRecorder(markets: ["BTC"]))
        XCTAssertThrowsError(try PriceDeliveryRecorder(markets: Set((0...512).map { "hl:0:ASSET\($0)" })))
        _ = try PriceDeliveryRecorder(markets: Set((0...511).map { "hl:0:ASSET\($0)" }))
    }
    func testCachedValuesAreNotRestampedAndObservationOpensNoSocket() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "test", realmId: "test")
        await manager.setPublicSourceFactory { _, _ in fatalError("Diagnostics cannot subscribe") }
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"100"}}"#)
        var updates = try await manager.watchPriceDeliveryDiagnostics(markets: [btc, eth]).makeAsyncIterator()
        let empty = await updates.next(); XCTAssertEqual(empty, [:])
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"100","hl:0:ETH":"10"}}"#)
        let first = await updates.next(); XCTAssertEqual(Set(first!.keys), [eth])
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"101"}}"#)
        let second = await updates.next()
        XCTAssertEqual(first?[eth], second?[eth]); XCTAssertEqual(second?[btc]?.price, "101")
        XCTAssertGreaterThanOrEqual(second![btc]!.publishedAtNanos, second![btc]!.receivedAtNanos)
        await manager.unsubscribeMids(); let cleared = await updates.next(); XCTAssertEqual(cleared, [:])
        await manager.disconnect()
    }
    func testDirectBatchKeepsRawReceiptAndRejectsFailedEpochWhileUnchangedQuoteProvesRecovery() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "test", realmId: "test")
        let callback = SendableBox<(@Sendable (UInt64, PublicMarketUpdate) async -> Void)?>(nil)
        await manager.setPublicSourceFactory { _, receive in callback.update { $0 = receive }; return TimingFakePublicSource() }
        let owner = await manager.registerPriceMarkets(); await manager.updatePriceMarkets(owner, markets: [btc])
        let market = try JSONDecoder().decode(Market.self, from: Data(#"{"name":"hl:0:BTC","venueSymbol":"BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}"#.utf8))
        await manager.configureMarketData(epoch: manager.beginMarketDataConfiguration(), preference: .hyperliquid, network: .mainnet, markets: [market])
        let receive = try XCTUnwrap(callback.value)
        var updates = try await manager.watchPriceDeliveryDiagnostics(markets: [btc]).makeAsyncIterator()
        _ = await updates.next()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func quote(_ epoch: UInt64, _ price: String, _ receipt: UInt64) async {
            await receive(epoch, .received(.quote(market: btc, price: price, timeMs: now), atNanos: receipt))
        }
        await quote(1, "100", 100); let first = await updates.next()
        await quote(1, "101", 200); await quote(1, "102", 300); await manager.flushPublicPrices()
        let batch = await updates.next()
        XCTAssertEqual(batch?[btc]?.price, "102"); XCTAssertEqual(batch?[btc]?.receivedAtNanos, 300); XCTAssertEqual(batch?[btc]?.venueTimeMs, now)
        await quote(1, "999", 400); await receive(2, .unavailable("offline"))
        await quote(1, "998", 500); await manager.flushPublicPrices()
        var recoveryUpdates = await manager.watchMarketDataDiagnostics().makeAsyncIterator()
        await receive(3, .connection(attemptAtNanos: 600))
        await quote(3, "102", 700)
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:ETH":"10"}}"#)
        let diagnostics = await recoveryUpdates.next()
        XCTAssertEqual(diagnostics?.hyperliquidConnection.firstPriceAtNanos, 700,
            "first accepted unchanged quote must notify immediately, without waiting for another frame")
        await quote(3, "103", 800); await manager.flushPublicPrices()
        let recovered = await updates.next()
        XCTAssertEqual(recovered?[btc]?.price, "103"); XCTAssertEqual(recovered?[btc]?.receivedAtNanos, 800)
        XCTAssertEqual(recovered?[btc]?.revision, first![btc]!.revision + 2)
        await manager.setMarketDataBudget(.init(bytesPerSecond: 100_000, messagesPerSecond: 0.4))
        await receive(3, .received(.mids(dex: "", prices: ["BTC": "104"]), atNanos: 900)); await manager.flushPublicPrices()
        let coarse = await updates.next()
        XCTAssertEqual(coarse?[btc]?.price, "104"); XCTAssertEqual(coarse?[btc]?.receivedAtNanos, 900); XCTAssertNil(coarse?[btc]?.venueTimeMs)
        _ = await manager.beginMarketDataConfiguration(); await quote(3, "999", 1000)
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"105"}}"#)
        let fallback = await updates.next()
        XCTAssertEqual(fallback?[btc]?.price, "105"); XCTAssertEqual(fallback?[btc]?.source, .arca); XCTAssertNil(fallback?[btc]?.venueTimeMs)
        await manager.disconnect()
    }
    func testRecoveryTimelineSurvivesLateUpgradeCallbackAndNewAttemptResetsIt() {
        var r = MarketDataDiagnosticsRecorder(); let router = MarketDataRouter()
        r.connection(.connection(attemptAtNanos: 100)); r.response(150); r.acceptedPrice(160)
        r.connection(.connection(attemptAtNanos: 100, openedAtNanos: 140))
        r.connection(.connection(attemptAtNanos: 100, retryAtNanos: 200, retryDelayMs: 4000))
        var s = r.snapshot(router: router).hyperliquidConnection
        XCTAssertEqual(s.openedAtNanos, 140); XCTAssertEqual(s.firstMessageAtNanos, 150); XCTAssertEqual(s.firstPriceAtNanos, 160)
        XCTAssertEqual(s.lastRetryDelayMs, 4000)
        r.connection(.connection(attemptAtNanos: 300)); r.connection(.connection(attemptAtNanos: 100, openedAtNanos: 140))
        s = r.snapshot(router: router).hyperliquidConnection
        XCTAssertEqual(s.attemptAtNanos, 300); XCTAssertNil(s.openedAtNanos); XCTAssertNil(s.firstPriceAtNanos); XCTAssertEqual(s.lastRetryDelayMs, 4000)
        r.suspend(); XCTAssertNil(r.snapshot(router: router).hyperliquidConnection.attemptAtNanos)
    }
}

private actor TimingFakePublicSource: PublicMarketSource {
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) {}
    func close() {}
}

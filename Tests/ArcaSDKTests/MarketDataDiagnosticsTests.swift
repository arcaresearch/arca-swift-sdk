import XCTest
@testable import ArcaSDK

final class MarketDataDiagnosticsTests: XCTestCase {
    func testPreferredSourceDoesNotMislabelFallbackAndQuietPriceIsNotFailure() {
        var router = MarketDataRouter(), recorder = MarketDataDiagnosticsRecorder()
        let owner = UUID(); router.register(owner); router.update(owner, markets: ["hl:0:BTC"], revision: 1)
        router.configure(.hyperliquid, markets: [])
        recorder.prices(["hl:0:BTC": "100", "hl:0:ETH": "10"], direct: false, interests: router.priceInterestMarkets)
        var s = recorder.snapshot(router: router)
        XCTAssertEqual(s.preference, .hyperliquid); XCTAssertEqual(s.arcaServingMarkets, 1)
        XCTAssertEqual(s.arcaPriceValues, 1); XCTAssertEqual(s.hyperliquidFailures, 0)
        recorder.prices(["hl:0:BTC": "101"], direct: true, interests: router.priceInterestMarkets)
        recorder.failure(); recorder.failure()
        recorder.prices(["hl:0:BTC": "101"], direct: false, interests: router.priceInterestMarkets)
        recorder.recovered(); recorder.recovered()
        s = recorder.snapshot(router: router)
        XCTAssertEqual(s.arcaServingMarkets, 1); XCTAssertEqual(s.hyperliquidServingMarkets, 0)
        XCTAssertEqual(s.hyperliquidFailures, 2); XCTAssertEqual(s.hyperliquidRecoveries, 1)
        XCTAssertNotNil(s.firstPriceMs)
        router.release(owner); recorder.retain(router.priceInterestMarkets)
        XCTAssertEqual(recorder.snapshot(router: router).arcaServingMarkets, 0)
        XCTAssertEqual(recorder.snapshot(router: router).arcaPriceValues, 2)
    }
    func testCumulativeCountersSurviveDroppedSnapshotsAndSuspendDoesNotCountRecovery() {
        var r = MarketDataDiagnosticsRecorder(); let router = MarketDataRouter()
        for _ in 0..<100 { r.bytes(100, direct: true); r.candle(direct: true) }
        r.bytes(400, direct: false); r.connected(true); r.connected(false); r.connected(false)
        r.failure(); r.suspend(); r.recovered()
        let s = r.snapshot(router: router)
        XCTAssertEqual(s.hyperliquidPayloadBytes, 10_000); XCTAssertEqual(s.hyperliquidCandleFrames, 100)
        XCTAssertEqual(s.arcaPayloadBytes, 400); XCTAssertEqual(s.arcaDisconnects, 1)
        XCTAssertEqual(s.hyperliquidRecoveries, 0)
    }
    func testWatchingDiagnosticsDoesNotSubscribeOrOpenASocket() async {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "test", realmId: "test")
        await manager.setPublicSourceFactory { _, _ in fatalError("Observation must not open a public socket") }
        var updates = await manager.watchMarketDataDiagnostics().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial?.requestedPriceMarkets, 0)
        let owner = await manager.registerPriceMarkets()
        await manager.updatePriceMarkets(owner, markets: ["hl:0:BTC"])
        let changed = await updates.next()
        XCTAssertEqual(changed?.requestedPriceMarkets, 1)
        XCTAssertEqual(changed?.directSubscriptions, 0)
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"100"}}"#)
        let current = await manager.marketDataDiagnostics
        XCTAssertEqual(current.arcaPriceValues, 1); XCTAssertGreaterThan(current.arcaPayloadBytes, 0)
        await manager.disconnect()
    }
}

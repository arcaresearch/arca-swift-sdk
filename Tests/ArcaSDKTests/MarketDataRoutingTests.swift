import XCTest
@testable import ArcaSDK

final class MarketDataRoutingTests: XCTestCase {
    func testOptionalMainnetPublicStreamProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ARCA_PUBLIC_STREAM_PROBE"] == "1")
        let counts = SendableBox((quotes: 0, bars: 0, errors: 0))
        let source = HyperliquidMarketSource(url: HyperliquidNetwork.mainnet.websocketURL) { _, update in
            counts.update { value in
                switch update { case .quote: value.quotes += 1; case .bar: value.bars += 1; case .unavailable: value.errors += 1 }
            }
        }
        await source.subscribe([.init(market: "hl:0:BTC", coin: "BTC"), .init(market: "hl:0:BTC", coin: "BTC", interval: .oneMinute)], revision: 1)
        do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { await source.close(); throw error }
        await source.close()
        let result = counts.value
        print("PUBLIC_STREAM_PROBE swift network=HL-mainnet duration_s=35 quotes=\(result.quotes) candles=\(result.bars) errors=\(result.errors)")
        XCTAssertGreaterThan(result.quotes, 0); XCTAssertGreaterThan(result.bars, 0); XCTAssertEqual(result.errors, 0)
    }

    private func market(_ name: String = "hl:0:BTC", _ coin: String = "BTC") throws -> Market {
        try JSONDecoder().decode(Market.self, from: Data("""
        {"name":"\(name)","venueSymbol":"\(coin)","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}
        """.utf8))
    }
    private func router(_ markets: [Market]) -> (MarketDataRouter, UUID) {
        var r = MarketDataRouter(); let owner = UUID()
        r.configure(.hyperliquid, markets: markets); r.register(owner); r.update(owner, markets: Set(markets.map(\.name)), revision: 0)
        return (r, owner)
    }
    func testStaleArcaFramesCannotOverwriteSelectedPriceAndFailureUsesNextLiveFrame() throws {
        var (r, _) = router([try market()]); let prices = ["hl:0:BTC": "90", "gllt:3": "12"]
        XCTAssertEqual(r.arcaPrices(prices), prices)
        XCTAssertEqual(r.direct(.quote(market: "hl:0:BTC", price: "100", timeMs: 1000), nowMs: 1000)?.mids?["hl:0:BTC"], "100")
        XCTAssertEqual(r.arcaPrices(prices), ["gllt:3": "12"])
        XCTAssertNil(r.direct(.quote(market: "hl:0:BTC", price: "99", timeMs: 999), nowMs: 1000))
        XCTAssertNil(r.direct(.unavailable("offline"), nowMs: 1000))
        XCTAssertEqual(r.arcaPrices(prices), prices)
        r.configure(.arca, markets: [])
        XCTAssertTrue(r.subscriptions.isEmpty)
        XCTAssertNil(r.direct(.quote(market: "hl:0:BTC", price: "101", timeMs: 1001), nowMs: 1001))
    }
    func testRoutingPreservesArcaEnvelope() async {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "token", realmId: "realm")
        var events = await manager.events.makeAsyncIterator()
        await manager.injectMessage(#"{"type":"mids.updated","mids":{"hl:0:BTC":"100"},"realmId":"realm","eventId":"event","sequence":7,"deliverySeq":8,"timestamp":"2026-10-04T00:00:00Z"}"#)
        let event = await events.next()
        XCTAssertEqual(event?.realmId, "realm"); XCTAssertEqual(event?.eventId, "event")
        XCTAssertEqual(event?.sequence, 7); XCTAssertEqual(event?.deliverySeq, 8)
        XCTAssertEqual(event?.timestamp, "2026-10-04T00:00:00Z")
        let selected = event?.withMids(["hl:0:ETH": "10"])
        XCTAssertEqual(selected?.eventId, "event"); XCTAssertEqual(selected?.mids, ["hl:0:ETH": "10"])
        await manager.disconnect()
    }
    func testLateMetadataConfigurationCannotUndoRollback() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "token", realmId: "realm")
        let opened = SendableBox(false), fake = FakePublicSource()
        await manager.setPublicSourceFactory { _, _ in opened.update { $0 = true }; return fake }
        let owner = await manager.registerPriceMarkets(); await manager.updatePriceMarkets(owner, markets: ["hl:0:BTC"])
        let old = await manager.beginMarketDataConfiguration(), current = await manager.beginMarketDataConfiguration()
        await manager.configureMarketData(epoch: current, preference: .arca, network: .mainnet, markets: [])
        await manager.configureMarketData(epoch: old, preference: .hyperliquid, network: .mainnet, markets: [try market()])
        let status = await manager.marketDataSourceStatus
        XCTAssertEqual(status.preference, .arca); XCTAssertFalse(opened.value)
        await manager.disconnect()
    }
    func testExactMetadataSeparatesSameTickerAndRejectsAmbiguousMapping() throws {
        let (r, _) = router(try [market(), market("hl:1:BTC", "xyz:BTC"), market("hl:2:BAD", "same"), market("hl:3:BAD", "same"), market("hl:4:DUP", "a"), market("hl:4:DUP", "b")])
        XCTAssertEqual(r.subscriptions, [PublicMarketSubscription(market: "hl:0:BTC", coin: "BTC"), PublicMarketSubscription(market: "hl:1:BTC", coin: "xyz:BTC")])
    }
    func testReleasedWatchCannotReopenFromLateUpdateAndSubscriptionsAreBounded() throws {
        var (r, owner) = router(try (0..<100).map { try market("hl:0:C\($0)", "C\($0)") })
        XCTAssertEqual(r.subscriptions.count, 64)
        r.update(owner, markets: ["hl:0:C1"], revision: 2); r.update(owner, markets: ["hl:0:C2"], revision: 1)
        XCTAssertEqual(r.subscriptions.first?.market, "hl:0:C1")
        r.release(owner); r.update(owner, markets: ["hl:0:C1"], revision: 3)
        XCTAssertTrue(r.subscriptions.isEmpty)
    }
    func testOneCandleWatchStoppingCannotRemoveAnotherAndClosedBarWins() throws {
        var (r, _) = router([try market()])
        for _ in 0..<2 { r.acquireCandles(["hl:0:BTC"], intervals: [.oneMinute, .fifteenSeconds]) }
        r.releaseCandles(["hl:0:BTC"], intervals: [.oneMinute, .fifteenSeconds])
        XCTAssertEqual(r.subscriptions.count, 2)
        let c = Candle(t: 60_000, o: "100", h: "101", l: "99", c: "101", v: "2", n: 2, s: nil)
        XCTAssertNotNil(r.direct(.bar(market: "hl:0:BTC", interval: .oneMinute, candle: c), nowMs: 61_000))
        XCTAssertFalse(r.arcaCandle(RealmEvent(type: "candle.updated", market: "hl:0:BTC", interval: "1m", candle: c)))
        XCTAssertTrue(r.arcaCandle(RealmEvent(type: "candle.closed", market: "hl:0:BTC", interval: "1m", candle: c)))
        XCTAssertNil(r.direct(.bar(market: "hl:0:BTC", interval: .oneMinute, candle: c), nowMs: 61_000))
        r.releaseCandles(["hl:0:BTC"], intervals: [.oneMinute, .fifteenSeconds])
        XCTAssertEqual(r.subscriptions.count, 1)
    }
    func testPublicBurstPublishesImmediateThenLatestBatchAndFailureCancelsPending() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "token", realmId: "realm")
        let callback = SendableBox<(@Sendable (UInt64, PublicMarketUpdate) async -> Void)?>(nil)
        let fake = FakePublicSource()
        await manager.setPublicSourceFactory { _, receive in callback.update { $0 = receive }; return fake }
        let owner = await manager.registerPriceMarkets(); await manager.updatePriceMarkets(owner, markets: ["hl:0:BTC"])
        let epoch = await manager.beginMarketDataConfiguration()
        await manager.configureMarketData(epoch: epoch, preference: .hyperliquid, network: .mainnet, markets: [try market()])
        let stream = await manager.midsEvents(), values = SendableBox<[String]>([])
        let first = expectation(description: "immediate"), last = expectation(description: "latest")
        let reader = Task { for await mids in stream {
            guard let price = mids["hl:0:BTC"] else { continue }
            values.update { $0.append(price) }
            if price == "100" { first.fulfill() }; if price == "600" { last.fulfill() }
        } }
        let receive = try XCTUnwrap(callback.value), now = Int(Date().timeIntervalSince1970 * 1000)
        await receive(1, .quote(market: "hl:0:BTC", price: "100", timeMs: now))
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(values.value, ["100"])
        let start = ProcessInfo.processInfo.systemUptime
        for i in 1...500 { await receive(1, .quote(market: "hl:0:BTC", price: String(100 + i), timeMs: now + i)) }
        let allowed = 2 + Int((ProcessInfo.processInfo.systemUptime - start) / 0.1)
        await fulfillment(of: [last], timeout: 1)
        XCTAssertLessThanOrEqual(values.value.count, allowed)
        let count = values.value.count
        await receive(1, .quote(market: "hl:0:BTC", price: "999", timeMs: now + 501))
        await receive(2, .unavailable("offline"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(values.value.count, count)
        reader.cancel(); await manager.disconnect()
    }
    func testBBODecoderPreservesHalfDollarAndNeverCopiesSymbolIntoCandleProvenance() throws {
        let subs: Set<PublicMarketSubscription> = [.init(market: "hl:1:BTC", coin: "xyz:BTC"), .init(market: "hl:1:BTC", coin: "xyz:BTC", interval: .oneMinute)]
        func decode(_ json: String) throws -> PublicMarketUpdate? { decodePublicMarketUpdate(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any], subscriptions: subs) }
        let bbo = #"{"channel":"bbo","data":{"coin":"xyz:BTC","time":1000,"bbo":[{"px":"84970"},{"px":"84971"}]}}"#
        guard case .quote(_, let price, _) = try decode(bbo) else { return XCTFail("Missing BBO") }
        XCTAssertEqual(price, "84970.5")
        XCTAssertNil(try decode(bbo.replacingOccurrences(of: "84970", with: "1e99999999")))
        XCTAssertNil(try decode(bbo.replacingOccurrences(of: "84970", with: "90000")))
        XCTAssertNil(try decode(bbo.replacingOccurrences(of: "xyz:BTC", with: "BTC")))
        guard case .bar(_, _, let candle) = try decode(#"{"channel":"candle","data":{"s":"xyz:BTC","i":"1m","t":60000,"o":"100","h":"101","l":"99","c":"101","v":"2","n":2}}"#) else { return XCTFail("Missing candle") }
        XCTAssertNil(candle.s)
    }
    func testSelectedSourceFeedsSharedValuationBusAndOldConnectionCannotReturnAfterFailure() async throws {
        let manager = WebSocketManager(baseURL: URL(string: "http://localhost:1")!, token: "private-token", realmId: "realm")
        let callback = SendableBox<(@Sendable (UInt64, PublicMarketUpdate) async -> Void)?>(nil)
        let fake = FakePublicSource()
        await manager.setPublicSourceFactory { _, receive in callback.update { $0 = receive }; return fake }
        let owner = await manager.registerPriceMarkets()
        await manager.updatePriceMarkets(owner, markets: ["hl:0:BTC"])
        let epoch = await manager.beginMarketDataConfiguration()
        await manager.configureMarketData(epoch: epoch, preference: .hyperliquid, network: .mainnet, markets: [try market()])
        let stream = await manager.midsEvents()
        let values = SendableBox<[String]>([])
        let complete = expectation(description: "all selected frames")
        let reader = Task { for await mids in stream {
            if let price = mids["hl:0:BTC"] { values.update { $0.append(price) }; if price == "107" { complete.fulfill(); break } }
        } }
        let receive = try XCTUnwrap(callback.value)
        func arca(_ price: String) async { await manager.injectMessage("{\"type\":\"mids.updated\",\"mids\":{\"hl:0:BTC\":\"\(price)\"}}") }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        await arca("100"); await receive(1, .quote(market: "hl:0:BTC", price: "101", timeMs: now)); await arca("102")
        await receive(1, .quote(market: "hl:0:BTC", price: "101", timeMs: now))
        await receive(2, .unavailable("offline")); await receive(1, .quote(market: "hl:0:BTC", price: "999", timeMs: now))
        await arca("103"); await receive(3, .quote(market: "hl:0:BTC", price: "105", timeMs: now + 1)); await arca("104")
        await manager.flushPublicPrices()
        _ = await manager.beginMarketDataConfiguration()
        await receive(3, .quote(market: "hl:0:BTC", price: "999", timeMs: now + 2)); await arca("107")
        await fulfillment(of: [complete], timeout: 2)
        XCTAssertEqual(values.value, ["100", "101", "103", "105", "107"])
        let base = try JSONDecoder().decode(ExchangeState.self, from: Data(#"{"account":{"id":"a1","realmId":"r1","name":"main","createdAt":"2026-09-06","updatedAt":"2026-09-06"},"marginSummary":{"equity":"1000","initialMarginUsed":"50","maintenanceMarginRequired":"0","availableToWithdraw":"950","totalNtlPos":"1000","totalUnrealizedPnl":"0","totalRawUsd":"1000"},"positions":[{"id":"p1","market":"hl:0:BTC","side":"long","size":"10","entryPrice":"100","leverage":20,"marginUsed":"50","positionValue":"1000","unrealizedPnl":"0"}],"openOrders":[]}"#.utf8))
        let marked = base.revalued(with: ["hl:0:BTC": values.value.last!])
        XCTAssertEqual(Double(marked.marginSummary.equity), 1070)
        XCTAssertEqual(Double(marked.positions[0].unrealizedPnl!), 70)
        XCTAssertNotEqual(deriveActiveAssetData(from: base, market: "hl:0:BTC", markPx: 100, leverage: 20, side: .buy)?.maxBuySize,
                          deriveActiveAssetData(from: marked, market: "hl:0:BTC", markPx: 107, leverage: 20, side: .buy)?.maxBuySize)
        reader.cancel(); await manager.disconnect()
    }
}

private actor FakePublicSource: PublicMarketSource {
    private(set) var subscriptions: Set<PublicMarketSubscription> = []
    func subscribe(_ subscriptions: Set<PublicMarketSubscription>, revision: UInt64) { self.subscriptions = subscriptions }
    func close() { subscriptions = [] }
}

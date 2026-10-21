import XCTest
@testable import ArcaSDK

final class MarketDataBudgetTests: XCTestCase {
    func testOptionalSharedSocketAllMidsAndBboProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ARCA_PUBLIC_BUDGET_PROBE"] == "1")
        let counts = SendableBox((native: 0, xyz: 0, quotes: 0, failures: 0))
        let source = HyperliquidMarketSource(url: HyperliquidNetwork.mainnet.websocketURL) { _, incoming in
            let update: PublicMarketUpdate
            if case .received(let value, _, _, _) = incoming { update = value } else { update = incoming }
            counts.update { value in
                switch update {
                case let .mids(dex, prices):
                    if dex.isEmpty && prices["BTC"] != nil { value.native += 1 }
                    if dex == "xyz" && prices["xyz:TSLA"] != nil { value.xyz += 1 }
                case .quote: value.quotes += 1
                case .unavailable: value.failures += 1
                default: break
                }
            }
        }
        await source.subscribe([.init(market: "", coin: "", dex: ""), .init(market: "", coin: "", dex: "xyz"),
                                .init(market: "hl:0:BTC", coin: "BTC")], revision: 1)
        do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { await source.close(); throw error }
        await source.close()
        let value = counts.value
        print("PUBLIC_BUDGET_PROBE network=HL-mainnet seconds=12 native=\(value.native) xyz=\(value.xyz) bbo=\(value.quotes) errors=\(value.failures)")
        XCTAssertGreaterThan(value.native, 0); XCTAssertGreaterThan(value.xyz, 0)
        XCTAssertGreaterThan(value.quotes, 0); XCTAssertEqual(value.failures, 0)
    }

    private func router(native: Int = 20, xyz: Int = 3) throws -> (MarketDataRouter, UUID) {
        let pairs = (0..<native).map { ("hl:0:C\($0)", "C\($0)") } + (0..<xyz).map { ("hl:1:C\($0)", "xyz:C\($0)") }
        let markets = try pairs.map { id, coin in try JSONDecoder().decode(Market.self, from: Data("""
        {"name":"\(id)","venueSymbol":"\(coin)","symbol":"same","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}
        """.utf8)) }
        var r = MarketDataRouter(); let owner = UUID()
        r.configure(.hyperliquid, markets: markets); r.register(owner); r.update(owner, markets: Set(pairs.map { $0.0 }), revision: 0)
        return (r, owner)
    }
    func testWeakDeviceKeepsCoarseCoverageDespiteFastConnection() throws {
        var (r, _) = try router(); r.setBudget(.init(bytesPerSecond: 100_000, messagesPerSecond: 0.4, priorities: ["hl:0:C0": 100]))
        XCTAssertEqual(Set(r.subscriptions.compactMap(\.dex)), ["", "xyz"]); XCTAssertEqual(r.subscriptions.count, 2)
    }
    func testHighestVisibleDemandWinsAndOtherDexKeepsCoverage() throws {
        var (r, _) = try router(); r.setBudget(.init(bytesPerSecond: 6_300, messagesPerSecond: 8, priorities: ["hl:0:C9": 100, "hl:0:C0": 10]))
        XCTAssertEqual(Set(r.subscriptions.filter { $0.dex == nil }.map(\.market)), ["hl:0:C9"])
        XCTAssertEqual(r.subscriptions.count, 3)
    }
    func testSmallScopeUsesBboOnlyWhenCheaperAndReceiveBudgetAllows() throws {
        var (r, _) = try router(native: 2); r.setBudget(.init(bytesPerSecond: 2_000, messagesPerSecond: 9))
        XCTAssertEqual(Set(r.subscriptions.filter { $0.dex == nil }.map(\.market)), ["hl:0:C0", "hl:0:C1"])
        XCTAssertEqual(r.subscriptions.compactMap(\.dex), ["xyz"])
    }
    func testMidsIsOneCanonicalBatchAndNeverReplaysOverEstablishedBbo() throws {
        var (r, owner) = try router(); r.setBudget(.init(bytesPerSecond: 6_300, messagesPerSecond: 8, priorities: ["hl:0:C0": 100]))
        let mids = PublicMarketUpdate.mids(dex: "", prices: ["C0": "100", "C1": "200", "xyz:C0": "999", "UNKNOWN": "10"])
        XCTAssertEqual(r.direct(mids, nowMs: 1000)?.mids, ["hl:0:C0": "100", "hl:0:C1": "200"])
        _ = r.direct(.quote(market: "hl:0:C0", price: "101", timeMs: 1000), nowMs: 1000)
        XCTAssertEqual(r.direct(mids, nowMs: 90_000)?.mids, ["hl:0:C1": "200"])
        r.setBudget(.init(bytesPerSecond: 100_000, messagesPerSecond: 0.4))
        XCTAssertEqual(r.direct(mids, nowMs: 90_001)?.mids?["hl:0:C0"], "100")
        r.release(owner); XCTAssertNil(r.direct(mids, nowMs: 90_002)); XCTAssertTrue(r.subscriptions.isEmpty)
    }
    func testExpensiveMeasuredFeedYieldsToCheaperVisibleAsset() throws {
        var (r, _) = try router(xyz: 0); r.setBudget(.init(bytesPerSecond: 5_700, messagesPerSecond: 12, priorities: ["hl:0:C0": 100, "hl:0:C1": 90]))
        _ = r.direct(.cost(key: "hl:0:C0", bytes: 200_000), nowMs: 0)
        _ = r.direct(.cost(key: "hl:0:C0", bytes: 100), nowMs: 10_000)
        XCTAssertEqual(Set(r.subscriptions.filter { $0.dex == nil }.map(\.market)), ["hl:0:C1"])
        r.setBudget(nil); XCTAssertEqual(r.subscriptions.count, 20)
    }
    func testBestBudgetCanPromoteEveryRequiredAssetIncludingPassiveOnes() throws {
        var (r, _) = try router(); r.setBudget(.init(bytesPerSecond: 100_000, messagesPerSecond: 200))
        XCTAssertEqual(r.subscriptions.count, 23); XCTAssertTrue(r.subscriptions.allSatisfy { $0.dex == nil })
    }
    func testMalformedAndUnrequestedMidsNeverReachCanonicalBus() throws {
        let subs: Set<PublicMarketSubscription> = [.init(market: "", coin: "", dex: "xyz")]
        XCTAssertNil(decodePublicMarketUpdate(["channel": "allMids", "data": ["mids": ["BTC": "1"]]], subscriptions: subs))
        let update = decodePublicMarketUpdate(["channel": "allMids", "data": ["dex": "xyz", "mids": ["xyz:C0": "10", "bad": "NaN", "zero": "0", "exponent": "1e100"]]], subscriptions: subs)
        guard case let .mids(_, prices) = update else { return XCTFail("expected one coarse frame") }
        XCTAssertEqual(prices, ["xyz:C0": "10"])
    }
}

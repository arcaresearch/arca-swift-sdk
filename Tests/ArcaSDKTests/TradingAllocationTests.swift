import XCTest
@testable import ArcaSDK

final class TradingAllocationTests: XCTestCase {
    private let allocationJSON = #"""
    {"revision":"9007199254740993","preferences":{"gllt:3":{"mode":"fixed","leverage":1},"gllt:11":{"mode":"fixed","leverage":8}},"projectionUnavailable":false,"projection":{"revision":"9007199254740993","positions":{"gllt:3":{"market":"gllt:3","preference":{"mode":"fixed","leverage":1},"effectiveLeverage":1,"venueInitialMargin":"100","allocatedMargin":"1000","extraMargin":"900","reservedMargin":"1000","reservedExtra":"900"}},"venueInitialMargin":"100","positionAllocatedMargin":"1000","allocatedMargin":"1000","extraMargin":"900","pendingMargin":"0","pendingCosts":"0","reservedExtra":"900","availableToTrade":"0"}}
    """#

    func testDecodesExactRevisionIntentAndSeparateVenueMargin() throws {
        let state = try JSONDecoder().decode(TradingAllocationState.self, from: Data(allocationJSON.utf8))
        XCTAssertEqual(state.revision, "9007199254740993")
        XCTAssertEqual(state.preferences["gllt:11"]?.leverage, 8)
        XCTAssertNil(state.projection?.positions["gllt:11"])
        XCTAssertEqual(state.projection?.positions["gllt:3"]?.venueInitialMargin, "100")
        XCTAssertEqual(state.projection?.positions["gllt:3"]?.allocatedMargin, "1000")
        XCTAssertEqual(state.projection?.extraMargin, "900")
        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(TradingAllocationState.self, from: encoded)
        XCTAssertEqual(restored.projection?.revision, state.revision)
    }

    func testUnavailableProjectionIsNotZeroAndPreservesFlatIntent() throws {
        let json = #"{"revision":"5","preferences":{"gllt:11":{"mode":"fixed","leverage":8}},"projectionUnavailable":true}"#
        let state = try JSONDecoder().decode(TradingAllocationState.self, from: Data(json.utf8))
        XCTAssertTrue(state.projectionUnavailable)
        XCTAssertNil(state.projection)
        XCTAssertEqual(state.preferences["gllt:11"]?.mode, .fixed)
    }

    func testLocalMidsCannotSeparateAccountMoneyFromMirrorAllocation() throws {
        let json = """
        {"account":{"id":"a1","realmId":"r1","name":"main","createdAt":"2026-09-06T00:00:00Z","updatedAt":"2026-09-06T00:00:00Z"},"marginSummary":{"equity":"1000","initialMarginUsed":"100","maintenanceMarginRequired":"50","availableToWithdraw":"900","totalNtlPos":"1000","totalUnrealizedPnl":"0","totalRawUsd":"1000"},"positions":[{"id":"p1","market":"gllt:3","side":"long","size":"1","entryPrice":"1000","leverage":10,"marginUsed":"100","unrealizedPnl":"0"}],"openOrders":[],"tradingAllocation":\(allocationJSON)}
        """
        let state = try JSONDecoder().decode(ExchangeState.self, from: Data(json.utf8))
        let marked = state.revalued(with: ["gllt:3": "2000"])
        XCTAssertEqual(marked.marginSummary.equity, "1000")
        XCTAssertEqual(marked.positions[0].unrealizedPnl, "0")
        XCTAssertEqual(marked.tradingAllocation?.projection?.availableToTrade, "0")
        XCTAssertNil(deriveActiveAssetData(from: state, market: "gllt:3", markPx: 1000, leverage: 10, side: .buy))
    }
}

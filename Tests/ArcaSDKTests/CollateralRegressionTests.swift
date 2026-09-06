import XCTest
@testable import ArcaSDK

final class CollateralRegressionTests: XCTestCase {
    private let fixture = #"{"account":{"id":"act_margin","realmId":"rlm_margin","name":"margin","createdAt":"2026-09-06","updatedAt":"2026-09-06"},"marginSummary":{"equity":"1000","initialMarginUsed":"600","maintenanceMarginRequired":"0","availableToWithdraw":"1000","totalNtlPos":"12000","totalUnrealizedPnl":"0","totalRawUsd":"1000"},"positions":[{"id":"pos_btc","market":"hl:0:BTC","side":"long","size":"100","entryPrice":"100","leverage":20,"marginUsed":"500","marginMode":"cross","positionValue":"10000","unrealizedPnl":"0"},{"id":"pos_xyz","market":"hl:1:XYZ","side":"long","size":"20","entryPrice":"100","leverage":20,"marginUsed":"100","marginMode":"cross","positionValue":"2000","unrealizedPnl":"0"}],"openOrders":[],"collateralModel":{"crossDexReservationEnforced":true,"crossDexReservationRate":"0.1","totalCollateralUsd":"1000","nativeAvailableUsd":"400","crossDexAvailableUsd":"0"},"stateRefreshIntervalMs":15000,"crossMarginSummary":{"equity":"1000","initialMarginUsed":"600","maintenanceMarginRequired":"0","availableToWithdraw":"1000","totalNtlPos":"12000","totalUnrealizedPnl":"0","totalRawUsd":"1000"}}"#
    private func book() throws -> ExchangeState { try JSONDecoder().decode(ExchangeState.self, from: Data(fixture.utf8)) }

    func testReversalKeepsCloseWithoutInventingOpeningCapacity() throws {
        for side in ["long", "short"] {
            let state = try JSONDecoder().decode(ExchangeState.self, from: Data(fixture.replacingOccurrences(of: "\"side\":\"long\"", with: "\"side\":\"\(side)\"").utf8))
            let data = try XCTUnwrap(deriveActiveAssetData(from: state, market: "hl:1:XYZ", markPx: 100, leverage: 20, side: .sell))
            XCTAssertEqual(Double(side == "long" ? data.maxSellSize : data.maxBuySize), 20)
            XCTAssertEqual(Double(side == "long" ? data.maxBuySize : data.maxSellSize), 0)
        }
    }

    func testRevaluationExcludesIsolatedProfitAndLossAndKeepsCapabilities() throws {
        var positions = try book().positions
        positions[1].marginMode = .isolated
        positions[1].isolatedMargin = "100"
        let summary = SimMarginSummary(equity: "900", initialMarginUsed: "500", maintenanceMarginRequired: "0", availableToWithdraw: "900", totalNtlPos: "10000", totalUnrealizedPnl: "0", totalRawUsd: "900")
        let base = try book()
        let state = ExchangeState(account: base.account, marginSummary: base.marginSummary, crossMarginSummary: summary, crossMaintenanceMarginUsed: nil, positions: positions, openOrders: [], feeRates: nil, pendingIntents: nil, collateralModel: base.collateralModel, stateRefreshIntervalMs: 15000)
        for mark in ["95", "105"] {
            let marked = state.revalued(with: ["hl:0:BTC": "100", "hl:1:XYZ": mark])
            XCTAssertEqual(Double(marked.crossMarginSummary!.equity), 900)
            XCTAssertEqual(marked.collateralModel?.totalCollateralUsd, "1000")
            XCTAssertEqual(marked.stateRefreshIntervalMs, 15000)
        }
    }
}

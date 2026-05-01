import XCTest
@testable import ArcaSDK

final class ActiveAssetDerivationTests: XCTestCase {

    private func makeState(
        equity: String = "10000",
        initialMarginUsed: String = "0",
        positions: [SimPosition] = [],
        takerRate: String = "0.00035",
        platformFee: String? = "0.0001"
    ) -> ExchangeState {
        ExchangeState(
            account: SimAccount(
                id: SimAccountID("act_1"),
                realmId: RealmID("rlm_1"),
                name: "test",
                createdAt: "2026-01-01T00:00:00.000000Z",
                updatedAt: "2026-01-01T00:00:00.000000Z"
            ),
            marginSummary: SimMarginSummary(
                equity: equity,
                initialMarginUsed: initialMarginUsed,
                maintenanceMarginRequired: "0",
                availableToWithdraw: equity,
                totalNtlPos: "0",
                totalUnrealizedPnl: "0",
                totalRawUsd: nil
            ),
            crossMarginSummary: nil,
            crossMaintenanceMarginUsed: nil,
            positions: positions,
            openOrders: [],
            feeRates: SimFeeRates(
                taker: takerRate,
                maker: "0.0001",
                platformFee: platformFee,
                tier: nil,
                tierLabel: nil,
                volume14d: nil,
                schedule: nil
            ),
            pendingIntents: nil
        )
    }

    private func makePosition(coin: String, side: PositionSide, size: String, marginUsed: String) -> SimPosition {
        SimPosition(
            id: SimPositionID("pos_1"),
            accountId: SimAccountID("act_1"),
            realmId: RealmID("rlm_1"),
            coin: coin,
            side: side,
            size: size,
            entryPrice: "50000",
            leverage: 10,
            marginUsed: marginUsed,
            liquidationPrice: nil,
            unrealizedPnl: nil,
            returnOnEquity: nil,
            positionValue: nil,
            error: nil,
            cumulativeFunding: nil,
            cumulativeFee: nil,
            cumulativeExchangeFee: nil,
            cumulativePlatformFee: nil,
            cumulativeBuilderFee: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    func testUsesEquityMinusInitialMargin_NotAvailableToWithdraw() {
        // availableToWithdraw (equity - maintenance) is a withdrawal metric.
        // Max order size must use equity - initialMarginUsed instead.
        let state = ExchangeState(
            account: SimAccount(id: SimAccountID("act_1"), realmId: RealmID("rlm_1"), name: "test",
                                createdAt: "2026-01-01T00:00:00.000000Z", updatedAt: "2026-01-01T00:00:00.000000Z"),
            marginSummary: SimMarginSummary(
                equity: "500", initialMarginUsed: "400", maintenanceMarginRequired: "12",
                availableToWithdraw: "488", totalNtlPos: "10000", totalUnrealizedPnl: "0", totalRawUsd: nil),
            crossMarginSummary: nil, crossMaintenanceMarginUsed: nil,
            positions: [], openOrders: [],
            feeRates: SimFeeRates(taker: "0.00035", maker: "0.0001", platformFee: "0.0001",
                                  tier: nil, tierLabel: nil, volume14d: nil, schedule: nil),
            pendingIntents: nil)

        let result = deriveActiveAssetData(from: state, coin: "hl:BTC", markPx: 80000, leverage: 5, side: .buy)
        guard let data = result else { XCTFail("expected non-nil"); return }
        let maxBuyUsd = Double(data.maxBuyUsd)!
        // available = equity - initialMarginUsed = 100, NOT availableToWithdraw = 488
        // At 5x: ~$500 notional, not ~$2,440
        XCTAssertTrue(maxBuyUsd < 600, "max notional (\(maxBuyUsd)) should be based on equity-margin (100), not availableToWithdraw (488)")
        XCTAssertTrue(maxBuyUsd > 400, "max notional (\(maxBuyUsd)) should be positive (~$500 at 5x)")
    }

    func testNoPosition_SymmetricMaxSizes() {
        let state = makeState(equity: "1000")
        let result = deriveActiveAssetData(
            from: state,
            coin: "hl:BTC",
            markPx: 50000,
            leverage: 10,
            side: .buy
        )

        XCTAssertNotNil(result)
        guard let data = result else { return }
        XCTAssertEqual(data.coin, "hl:BTC")
        XCTAssertEqual(data.leverage.type, .cross)
        XCTAssertEqual(data.leverage.value, 10)
        XCTAssertEqual(data.maxBuySize, data.maxSellSize, "without a position, buy and sell max should be equal")
        XCTAssertTrue(Double(data.maxBuySize)! > 0)
    }

    func testLongPosition_SellMaxIncludesClose() {
        let pos = makePosition(coin: "hl:BTC", side: .long, size: "0.1", marginUsed: "500")
        let state = makeState(equity: "1500", initialMarginUsed: "500", positions: [pos])
        let result = deriveActiveAssetData(
            from: state,
            coin: "hl:BTC",
            markPx: 50000,
            leverage: 10,
            side: .sell
        )

        guard let data = result else { XCTFail("expected non-nil"); return }
        let sellMax = Double(data.maxSellSize)!
        let buyMax = Double(data.maxBuySize)!
        XCTAssertTrue(sellMax > buyMax, "sell max should exceed buy max when long (can close position + open short)")
    }

    func testShortPosition_BuyMaxIncludesClose() {
        let pos = makePosition(coin: "hl:BTC", side: .short, size: "0.1", marginUsed: "500")
        let state = makeState(equity: "1500", initialMarginUsed: "500", positions: [pos])
        let result = deriveActiveAssetData(
            from: state,
            coin: "hl:BTC",
            markPx: 50000,
            leverage: 10,
            side: .buy
        )

        guard let data = result else { XCTFail("expected non-nil"); return }
        let buyMax = Double(data.maxBuySize)!
        let sellMax = Double(data.maxSellSize)!
        XCTAssertTrue(buyMax > sellMax, "buy max should exceed sell max when short (can close position + open long)")
    }

    func testInvalidMarkPx_ReturnsNil() {
        let state = makeState()
        XCTAssertNil(deriveActiveAssetData(from: state, coin: "hl:BTC", markPx: 0, leverage: 10, side: .buy))
        XCTAssertNil(deriveActiveAssetData(from: state, coin: "hl:BTC", markPx: -1, leverage: 10, side: .buy))
    }

    func testInvalidLeverage_ReturnsNil() {
        let state = makeState()
        XCTAssertNil(deriveActiveAssetData(from: state, coin: "hl:BTC", markPx: 50000, leverage: 0, side: .buy))
    }

    func testZeroAvailable_ReturnsZeroMax() {
        let state = makeState(equity: "500", initialMarginUsed: "500")
        let result = deriveActiveAssetData(
            from: state,
            coin: "hl:BTC",
            markPx: 50000,
            leverage: 10,
            side: .buy
        )

        guard let data = result else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(data.maxBuySize, "0")
        XCTAssertEqual(data.maxSellSize, "0")
    }

    func testBuilderFeeBps_ReducesMaxSize() {
        let state = makeState(equity: "1000")
        let withoutFee = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 50000, leverage: 10, side: .buy, builderFeeBps: 0
        )
        let withFee = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 50000, leverage: 10, side: .buy, builderFeeBps: 100
        )

        guard let a = withoutFee, let b = withFee else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(Double(a.maxBuySize)! > Double(b.maxBuySize)!, "builder fee should reduce max size")
    }

    func testMaxNotional_NeverExceedsAvailable() {
        let state = makeState(equity: "282.51")
        let result = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 68995, leverage: 1, side: .sell, szDecimals: 4
        )
        guard let data = result else { XCTFail("expected non-nil"); return }
        let sellMax = Double(data.maxSellSize)!
        let notional = sellMax * 68995
        XCTAssertTrue(notional <= 282.51, "max notional (\(notional)) must not exceed available (282.51)")
        XCTAssertTrue(sellMax > 0, "max should be positive")
    }

    func testFloorToDecimals_NoFloatingPointOvershoot() {
        // Craft an input where available / costPerToken is epsilon above a tick
        // boundary in IEEE 754. Without the floor fix, this overshoots by one tick.
        let state = makeState(equity: "1000")
        for markPx in stride(from: 50000.0, to: 70000.0, by: 137.0) {
            let result = deriveActiveAssetData(
                from: state, coin: "hl:BTC", markPx: markPx, leverage: 1, side: .buy, szDecimals: 4
            )
            guard let data = result else { continue }
            let buyMax = Double(data.maxBuySize)!
            let notional = buyMax * markPx
            XCTAssertTrue(notional <= 1000,
                "max notional (\(notional)) must not exceed available (1000) at markPx=\(markPx)")
        }
    }

    func testDefaultPlatformFee_UsedWhenMissing() {
        let state = makeState(equity: "1000", platformFee: nil)
        let result = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 50000, leverage: 10, side: .buy
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(Double(result!.maxBuySize)! > 0)
    }

    func testFeeScale_ReducesMaxSize() {
        let state = makeState(equity: "1000")
        let withoutScale = deriveActiveAssetData(
            from: state, coin: "hl:1:TSLA", markPx: 250, leverage: 10, side: .buy, feeScale: 1
        )
        let withScale = deriveActiveAssetData(
            from: state, coin: "hl:1:TSLA", markPx: 250, leverage: 10, side: .buy, feeScale: 2
        )

        guard let a = withoutScale, let b = withScale else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(Double(a.maxBuySize)! > Double(b.maxBuySize)!,
                       "higher feeScale should reduce max size")
    }

    func testLeverage10x_200Account_YieldsApprox2KNotional() {
        // Regression: builder reported ~2.8 tokens ($198 notional) at 10x leverage,
        // which matches 1x behavior. At 10x the notional should be ~$2,000.
        let state = makeState(equity: "200")
        let result = deriveActiveAssetData(
            from: state, coin: "hl:1:SILVER", markPx: 70.87, leverage: 10,
            side: .buy, builderFeeBps: 40, szDecimals: 5
        )

        guard let data = result else { XCTFail("expected non-nil"); return }
        let maxBuy = Double(data.maxBuySize)!
        let maxBuyUsd = Double(data.maxBuyUsd)!

        XCTAssertTrue(maxBuy > 25,
            "at 10x leverage, max buy (\(maxBuy)) must be well above 2.8 (1x level)")
        XCTAssertTrue(maxBuyUsd > 1800 && maxBuyUsd < 2100,
            "notional buying power (\(maxBuyUsd)) should be ~$2,000, not ~$200")
        XCTAssertEqual(data.leverage.value, 10)
    }

    func testFeeScale_DefaultsToOne() {
        let state = makeState(equity: "1000")
        let explicit = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 50000, leverage: 10, side: .buy, feeScale: 1
        )
        let implicit = deriveActiveAssetData(
            from: state, coin: "hl:BTC", markPx: 50000, leverage: 10, side: .buy
        )

        guard let a = explicit, let b = implicit else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(a.maxBuySize, b.maxBuySize, "omitting feeScale should behave like feeScale=1")
    }

    // MARK: - orderBreakdown tests

    func testOrderBreakdown_SpendMode() {
        let result = Arca.orderBreakdown(options: OrderBreakdownOptions(
            amount: "200", amountType: .spend, leverage: 10,
            feeRate: "0.00045", price: "70.87", side: .buy, szDecimals: 5
        ))
        let total = Double(result.totalSpend)!
        XCTAssertTrue(abs(total - 200) < 1, "totalSpend (\(total)) should be ~200")
        let notional = Double(result.notionalUsd)!
        XCTAssertTrue(notional > 1900 && notional < 2000, "notional (\(notional)) should be ~1991")
        XCTAssertTrue(Double(result.tokens)! > 0)
        XCTAssertEqual(result.price, "70.87")
        XCTAssertEqual(result.feeRate, "0.00045")
    }

    func testOrderBreakdown_NotionalMode() {
        let result = Arca.orderBreakdown(options: OrderBreakdownOptions(
            amount: "2000", amountType: .notional, leverage: 10,
            feeRate: "0.00045", price: "100", side: .sell, szDecimals: 3
        ))
        XCTAssertEqual(Double(result.tokens)!, 20, accuracy: 0.001)
        XCTAssertEqual(Double(result.notionalUsd)!, 2000, accuracy: 0.01)
        XCTAssertEqual(Double(result.marginRequired)!, 200, accuracy: 0.01)
        XCTAssertTrue(abs(Double(result.estimatedFee)! - 0.9) < 0.1)
    }

    func testOrderBreakdown_TokensMode() {
        let result = Arca.orderBreakdown(options: OrderBreakdownOptions(
            amount: "5", amountType: .tokens, leverage: 2,
            feeRate: "0.001", price: "50", side: .buy, szDecimals: 2
        ))
        XCTAssertEqual(Double(result.tokens)!, 5, accuracy: 0.01)
        XCTAssertEqual(Double(result.notionalUsd)!, 250, accuracy: 0.01)
        XCTAssertEqual(Double(result.marginRequired)!, 125, accuracy: 0.01)
        XCTAssertEqual(Double(result.estimatedFee)!, 0.25, accuracy: 0.001)
        XCTAssertEqual(Double(result.totalSpend)!, 125.25, accuracy: 0.01)
    }

    func testOrderBreakdown_ZeroAmount_ReturnsZeros() {
        let result = Arca.orderBreakdown(options: OrderBreakdownOptions(
            amount: "0", amountType: .spend, leverage: 10,
            feeRate: "0.001", price: "100", side: .buy
        ))
        XCTAssertEqual(result.tokens, "0")
        XCTAssertEqual(result.totalSpend, "0")
    }

    // MARK: - Maintenance margin rate

    func testThreadsMaintenanceMarginRateThrough() {
        // Backend derives MMR per-asset from its margin table
        // (0.5 / firstTier.maxLeverage). The client-side derivation must
        // honor the value the caller resolved for the asset, not hardcode
        // 0.03 — which would feed a wrong number into Arca.orderBreakdown's
        // liquidation estimate for tiered assets like BTC (true MMR ~= 0.01).
        let derived = deriveActiveAssetData(
            from: makeState(),
            coin: "BTC", markPx: 80000, leverage: 5, side: .buy,
            maintenanceMarginRate: "0.01"
        )
        XCTAssertNotNil(derived)
        XCTAssertEqual(derived?.maintenanceMarginRate, "0.01")
    }

    func testDefaultsMaintenanceMarginRateTo003WhenOmitted() {
        // Backwards-compat: callers that don't yet pass MMR (or callers
        // that can't resolve it) get the same global default the backend
        // uses for assets without a margin table.
        let derived = deriveActiveAssetData(
            from: makeState(),
            coin: "BTC", markPx: 80000, leverage: 5, side: .buy
        )
        XCTAssertNotNil(derived)
        XCTAssertEqual(derived?.maintenanceMarginRate, "0.03")
    }
}

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

    private func makePosition(market: String, side: PositionSide, size: String, marginUsed: String) -> SimPosition {
        SimPosition(
            id: SimPositionID("pos_1"),
            accountId: SimAccountID("act_1"),
            realmId: RealmID("rlm_1"),
            market: market,
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

        let result = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy)
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
            market: "hl:0:BTC",
            markPx: 50000,
            leverage: 10,
            side: .buy
        )

        XCTAssertNotNil(result)
        guard let data = result else { return }
        XCTAssertEqual(data.market, "hl:0:BTC")
        XCTAssertEqual(data.leverage.type, .cross)
        XCTAssertEqual(data.leverage.value, 10)
        XCTAssertEqual(data.maxBuySize, data.maxSellSize, "without a position, buy and sell max should be equal")
        XCTAssertTrue(Double(data.maxBuySize)! > 0)
    }

    func testLongPosition_SellMaxIncludesClose() {
        let pos = makePosition(market: "hl:0:BTC", side: .long, size: "0.1", marginUsed: "500")
        let state = makeState(equity: "1500", initialMarginUsed: "500", positions: [pos])
        let result = deriveActiveAssetData(
            from: state,
            market: "hl:0:BTC",
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
        let pos = makePosition(market: "hl:0:BTC", side: .short, size: "0.1", marginUsed: "500")
        let state = makeState(equity: "1500", initialMarginUsed: "500", positions: [pos])
        let result = deriveActiveAssetData(
            from: state,
            market: "hl:0:BTC",
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
        XCTAssertNil(deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 0, leverage: 10, side: .buy))
        XCTAssertNil(deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: -1, leverage: 10, side: .buy))
    }

    func testInvalidLeverage_ReturnsNil() {
        let state = makeState()
        XCTAssertNil(deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 50000, leverage: 0, side: .buy))
    }

    func testZeroAvailable_ReturnsZeroMax() {
        let state = makeState(equity: "500", initialMarginUsed: "500")
        let result = deriveActiveAssetData(
            from: state,
            market: "hl:0:BTC",
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
            from: state, market: "hl:0:BTC", markPx: 50000, leverage: 10, side: .buy, builderFeeBps: 0
        )
        let withFee = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 50000, leverage: 10, side: .buy, builderFeeBps: 100
        )

        guard let a = withoutFee, let b = withFee else { XCTFail("expected non-nil"); return }
        XCTAssertTrue(Double(a.maxBuySize)! > Double(b.maxBuySize)!, "builder fee should reduce max size")
    }

    func testMaxNotional_NeverExceedsAvailable() {
        let state = makeState(equity: "282.51")
        let result = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 68995, leverage: 1, side: .sell, szDecimals: 4
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
                from: state, market: "hl:0:BTC", markPx: markPx, leverage: 1, side: .buy, szDecimals: 4
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
            from: state, market: "hl:0:BTC", markPx: 50000, leverage: 10, side: .buy
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(Double(result!.maxBuySize)! > 0)
    }

    func testFeeScale_ReducesMaxSize() {
        let state = makeState(equity: "1000")
        let withoutScale = deriveActiveAssetData(
            from: state, market: "hl:1:TSLA", markPx: 250, leverage: 10, side: .buy, feeScale: 1
        )
        let withScale = deriveActiveAssetData(
            from: state, market: "hl:1:TSLA", markPx: 250, leverage: 10, side: .buy, feeScale: 2
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
            from: state, market: "hl:1:SILVER", markPx: 70.87, leverage: 10,
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
            from: state, market: "hl:0:BTC", markPx: 50000, leverage: 10, side: .buy, feeScale: 1
        )
        let implicit = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 50000, leverage: 10, side: .buy
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
            market: "BTC", markPx: 80000, leverage: 5, side: .buy,
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
            market: "BTC", markPx: 80000, leverage: 5, side: .buy
        )
        XCTAssertNotNil(derived)
        XCTAssertEqual(derived?.maintenanceMarginRate, "0.03")
    }

    // MARK: - Directional spread pricing

    func testAskRatioShrinksMaxBuySize() {
        // ask = mid * 1.001 (10 bps above mid). Buys execute at the ask, so the
        // same budget buys fewer tokens than a mid-priced estimate assumes.
        let state = makeState(equity: "10000")
        let mid = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy)
        let askAware = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy,
            askRatio: 1.001, bidRatio: 1
        )
        guard let m = mid, let a = askAware else { XCTFail("expected non-nil"); return }
        XCTAssertLessThan(Double(a.maxBuySize)!, Double(m.maxBuySize)!)
        // Reduction tracks the ask premium (~0.1%), not a wild swing.
        let ratio = Double(a.maxBuySize)! / Double(m.maxBuySize)!
        XCTAssertGreaterThan(ratio, 0.995)
        XCTAssertLessThan(ratio, 1)
        XCTAssertEqual(Double(a.askPx!)!, 80000 * 1.001, accuracy: 1)
    }

    func testBidRatioGrowsMaxSellSizeTowardServerParity() {
        // bid = mid * 0.999 (10 bps below mid). Sells execute at the bid, so the
        // same (price-independent) max notional fits *more* tokens than at the
        // mid — mirrors the server (sellCostPerToken uses the bid).
        let state = makeState(equity: "10000")
        let mid = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .sell)
        let bidAware = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .sell,
            askRatio: 1, bidRatio: 0.999
        )
        guard let m = mid, let b = bidAware else { XCTFail("expected non-nil"); return }
        XCTAssertGreaterThan(Double(b.maxSellSize)!, Double(m.maxSellSize)!)
        XCTAssertEqual(Double(b.bidPx!)!, 80000 * 0.999, accuracy: 1)
    }

    func testDefaultRatiosReproduceMidBasedSizing() {
        let state = makeState(equity: "10000")
        let explicit = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy,
            askRatio: 1, bidRatio: 1
        )
        let implicit = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy)
        guard let e = explicit, let i = implicit else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(e.maxBuySize, i.maxBuySize)
        XCTAssertEqual(e.maxSellSize, i.maxSellSize)
        // With no spread, the directional prices collapse to the mid.
        XCTAssertEqual(e.bidPx, i.markPx)
        XCTAssertEqual(e.askPx, i.markPx)
    }

    func testIgnoresNonPositiveRatios() {
        let state = makeState(equity: "10000")
        let bad = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy,
            askRatio: 0, bidRatio: Double.nan
        )
        let mid = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy)
        guard let bd = bad, let m = mid else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(bd.maxBuySize, m.maxBuySize)
    }

    func testSpreadRatioAppliesToLiveMidNotSnapshotMid() {
        // A ratio resolved at one mid keeps adjusting after the mid moves —
        // proving the ratio (not a stale absolute ask) is what's applied.
        let state = makeState(equity: "10000")
        let askRatio = 1.002
        let atSnapshot = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 80000, leverage: 5, side: .buy, askRatio: askRatio, bidRatio: 1
        )
        let afterMove = deriveActiveAssetData(
            from: state, market: "hl:0:BTC", markPx: 90000, leverage: 5, side: .buy, askRatio: askRatio, bidRatio: 1
        )
        guard let s0 = atSnapshot, let s1 = afterMove else { XCTFail("expected non-nil"); return }
        XCTAssertEqual(Double(s0.askPx!)!, 80000 * askRatio, accuracy: 1)
        XCTAssertEqual(Double(s1.askPx!)!, 90000 * askRatio, accuracy: 1)
    }

    // MARK: - Reduce / open split

    func testNoPositionReportsZeroReduceOnBothSides() {
        let state = makeState(equity: "10000")
        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .buy) else {
            XCTFail("expected non-nil"); return
        }
        XCTAssertEqual(d.maxBuyReduceSize, "0")
        XCTAssertEqual(d.maxSellReduceSize, "0")
        XCTAssertEqual(d.maxBuyOpenSize, d.maxBuySize)
        XCTAssertEqual(d.maxSellOpenSize, d.maxSellSize)
    }

    func testLongPositionSplitsTheSellSideOnly() {
        let pos = makePosition(market: "hl:0:BTC", side: .long, size: "0.02", marginUsed: "320")
        let state = makeState(equity: "10000", initialMarginUsed: "320", positions: [pos])
        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .sell) else {
            XCTFail("expected non-nil"); return
        }
        // A sell closes the long, so the whole position is reducible. The tick
        // must survive: 0.02, not 0.01999 — a user has to be able to fully close.
        XCTAssertEqual(Double(d.maxSellReduceSize!)!, 0.02, accuracy: 1e-12)
        XCTAssertTrue(Double(d.maxSellOpenSize!)! > 0)
        // A buy adds to the long; there is nothing on that side to reduce.
        XCTAssertEqual(d.maxBuyReduceSize, "0")
        XCTAssertEqual(d.maxBuyOpenSize, d.maxBuySize)
    }

    func testTotalEqualsReducePlusOpen() {
        let pos = makePosition(market: "hl:0:BTC", side: .long, size: "0.02", marginUsed: "320")
        let state = makeState(equity: "10000", initialMarginUsed: "320", positions: [pos])
        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .sell) else {
            XCTFail("expected non-nil"); return
        }
        XCTAssertEqual(Double(d.maxSellSize)!,
                       Double(d.maxSellReduceSize!)! + Double(d.maxSellOpenSize!)!, accuracy: 1e-10)
        XCTAssertEqual(Double(d.maxBuySize)!,
                       Double(d.maxBuyReduceSize!)! + Double(d.maxBuyOpenSize!)!, accuracy: 1e-10)
    }

    // The reported bug in its client-side form: an account below its
    // initial-margin requirement can open nothing, but it can always close what
    // it holds. A slider reading only the total must still offer the trim.
    func testReduceLegSurvivesWhenNothingCanBeOpened() {
        let pos = makePosition(market: "hl:0:BTC", side: .long, size: "0.5", marginUsed: "4000")
        let state = makeState(equity: "100", initialMarginUsed: "5000", positions: [pos])
        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .sell) else {
            XCTFail("expected non-nil"); return
        }
        XCTAssertEqual(Double(d.maxSellReduceSize!)!, 0.5, accuracy: 1e-12)
        XCTAssertTrue(Double(d.maxSellSize)! >= 0.5)
    }

    // MARK: - Isolated positions

    // Isolated collateral and P&L are locked to their own position: the server
    // budgets orders from cross equity alone (PositionService.AvailableBalance).
    // Deriving from the account-wide summary let an isolated position's profit
    // inflate the previewed max above what the venue would accept.
    func testPrefersCrossBucketOverAccountWideSummary() {
        let state = ExchangeState(
            account: SimAccount(id: SimAccountID("act_1"), realmId: RealmID("rlm_1"), name: "test",
                                createdAt: "2026-01-01T00:00:00.000000Z", updatedAt: "2026-01-01T00:00:00.000000Z"),
            // Account-wide: $9,000 free, most of it locked inside an isolated position.
            marginSummary: SimMarginSummary(
                equity: "10000", initialMarginUsed: "1000", maintenanceMarginRequired: "0",
                availableToWithdraw: "9000", totalNtlPos: "0", totalUnrealizedPnl: "0", totalRawUsd: nil),
            // Cross bucket: only $500 is actually spendable.
            crossMarginSummary: SimMarginSummary(
                equity: "1500", initialMarginUsed: "1000", maintenanceMarginRequired: "0",
                availableToWithdraw: "500", totalNtlPos: "0", totalUnrealizedPnl: "0", totalRawUsd: nil),
            crossMaintenanceMarginUsed: nil,
            positions: [], openOrders: [],
            feeRates: SimFeeRates(taker: "0.00035", maker: "0.0001", platformFee: "0.0001",
                                  tier: nil, tierLabel: nil, volume14d: nil, schedule: nil),
            pendingIntents: nil)

        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .buy) else {
            XCTFail("expected non-nil"); return
        }
        // $500 of cross collateral at 5x is ~$2.5k of notional, not the ~$45k
        // the account-wide summary would have implied.
        XCTAssertTrue(Double(d.maxBuyUsd)! < 3000, "derived \(d.maxBuyUsd) from the wrong bucket")
        XCTAssertEqual(Double(d.availableToTrade)!, 500, accuracy: 1e-6)
    }

    // An account on a venue with a cross-dex reservation has exactly TWO buying
    // power numbers: the native dex's own budget, and one pool shared by every
    // other perp dex. Every case below is a reading taken from Hyperliquid
    // mainnet on 2026-08-28 — three live accounts plus states driven
    // deliberately on a test account.
    private static let hlRate = "0.1"

    private func crossDexState(totalCollateral: String, equity: String,
                               initialMarginUsed: String, positions: [SimPosition],
                               declaresModel: Bool = true) -> ExchangeState {
        ExchangeState(
            account: SimAccount(id: SimAccountID("act_1"), realmId: RealmID("rlm_1"), name: "test",
                                createdAt: "2026-01-01T00:00:00.000000Z",
                                updatedAt: "2026-01-01T00:00:00.000000Z"),
            marginSummary: SimMarginSummary(
                equity: equity, initialMarginUsed: initialMarginUsed,
                maintenanceMarginRequired: "0", availableToWithdraw: "0",
                totalNtlPos: "0", totalUnrealizedPnl: "0", totalRawUsd: nil),
            crossMarginSummary: nil, crossMaintenanceMarginUsed: nil,
            positions: positions, openOrders: [],
            feeRates: SimFeeRates(taker: "0.00035", maker: "0.0001", platformFee: "0.0001",
                                  tier: nil, tierLabel: nil, volume14d: nil, schedule: nil),
            pendingIntents: nil,
            collateralModel: declaresModel
                ? CollateralModel(crossDexReservationEnforced: true,
                                  crossDexReservationRate: Self.hlRate,
                                  totalCollateralUsd: totalCollateral)
                : nil)
    }

    private func dexPosition(_ market: String, marginUsed: String, positionValue: String) -> SimPosition {
        SimPosition(
            id: SimPositionID("pos_\(market)"), accountId: SimAccountID("act_1"),
            realmId: RealmID("rlm_1"), market: market, side: .long, size: "1",
            entryPrice: "1", leverage: 20, marginUsed: marginUsed,
            liquidationPrice: nil, unrealizedPnl: nil, returnOnEquity: nil,
            positionValue: positionValue, error: nil, cumulativeFunding: nil,
            cumulativeFee: nil, cumulativeExchangeFee: nil, cumulativePlatformFee: nil,
            cumulativeBuilderFee: nil, createdAt: nil, updatedAt: nil)
    }

    /// The venue's own answer for each state, on a non-native (HIP-3) market.
    func testCrossDexAvailableMatchesMainnet() {
        let cases: [(String, ExchangeState, Double)] = [
            // The Gobi letter tester: 40x native swallows the entire balance.
            ("letter tester 40x", crossDexState(totalCollateral: "21.647938", equity: "21.647938",
                initialMarginUsed: "9.931551",
                positions: [dexPosition("hl:0:BTC", marginUsed: "9.931551", positionValue: "397.262040")]), 0),
            ("lab, headroom", crossDexState(totalCollateral: "9.749047", equity: "9.749047",
                initialMarginUsed: "3.087293",
                positions: [dexPosition("hl:0:BTC", marginUsed: "3.087293", positionValue: "73.436720")]), 2.405375),
            // Two dexes — the account that falsified the previous formula.
            ("tester2 native+xyz", crossDexState(totalCollateral: "8.696417", equity: "8.668287",
                initialMarginUsed: "4.072284",
                positions: [dexPosition("hl:0:BTC", marginUsed: "2.397960", positionValue: "23.979600"),
                            dexPosition("hl:1:NVDA", marginUsed: "1.674324", positionValue: "33.486480")]), 4.624133),
            ("native 20x", crossDexState(totalCollateral: "14.753099", equity: "14.753099",
                initialMarginUsed: "4.994187",
                positions: [dexPosition("hl:0:BTC", marginUsed: "4.994187", positionValue: "99.883750")]), 4.764724),
            // Below 1/rate the margin term wins — the branch that proves the max().
            ("native 8x", crossDexState(totalCollateral: "14.700599", equity: "14.700599",
                initialMarginUsed: "12.479531",
                positions: [dexPosition("hl:0:BTC", marginUsed: "12.479531", positionValue: "99.836250")]), 2.221068),
            // A HIP-3 position is never charged the notional floor.
            ("HIP-3 only", crossDexState(totalCollateral: "14.563936", equity: "14.563936",
                initialMarginUsed: "0.679900",
                positions: [dexPosition("hl:1:NVDA", marginUsed: "0.679900", positionValue: "13.597800")]), 13.884036),
            ("two HIP-3 dexes", crossDexState(totalCollateral: "14.4957", equity: "14.4957",
                initialMarginUsed: "1.3362",
                positions: [dexPosition("hl:1:NVDA", marginUsed: "0.6807", positionValue: "13.6140"),
                            dexPosition("hl:9:US500", marginUsed: "0.6555", positionValue: "13.1109")]), 13.1595),
            ("all three dexes", crossDexState(totalCollateral: "14.4519", equity: "14.4519",
                initialMarginUsed: "6.3333",
                positions: [dexPosition("hl:0:BTC", marginUsed: "4.9971", positionValue: "99.9425"),
                            dexPosition("hl:1:NVDA", marginUsed: "0.6807", positionValue: "13.6134"),
                            dexPosition("hl:9:US500", marginUsed: "0.6555", positionValue: "13.1109")]), 3.12145),
        ]
        for (name, state, want) in cases {
            guard let d = deriveActiveAssetData(from: state, market: "hl:1:NVDA",
                                                markPx: 226.59, leverage: 20, side: .buy) else {
                XCTFail("\(name): expected non-nil"); continue
            }
            XCTAssertEqual(Double(d.availableToTrade)!, want, accuracy: 0.001, name)
            XCTAssertEqual(Double(d.availability!.crossDexAvailableUsd)!, want, accuracy: 0.001, name)
        }
    }

    /// Every non-native dex reads the SAME number, including one never touched.
    func testEveryNonNativeDexSharesOneNumber() {
        let st = crossDexState(totalCollateral: "14.4519", equity: "14.4519", initialMarginUsed: "6.3333",
            positions: [dexPosition("hl:0:BTC", marginUsed: "4.9971", positionValue: "99.9425"),
                        dexPosition("hl:1:NVDA", marginUsed: "0.6807", positionValue: "13.6134"),
                        dexPosition("hl:9:US500", marginUsed: "0.6555", positionValue: "13.1109")])
        let nvda = deriveActiveAssetData(from: st, market: "hl:1:NVDA", markPx: 226.59, leverage: 20, side: .buy)!
        let us500 = deriveActiveAssetData(from: st, market: "hl:9:US500", markPx: 771.22, leverage: 20, side: .buy)!
        let gold = deriveActiveAssetData(from: st, market: "hl:2:GOLD", markPx: 4153.2, leverage: 20, side: .buy)!
        XCTAssertEqual(nvda.availableToTrade, us500.availableToTrade)
        XCTAssertEqual(gold.availableToTrade, nvda.availableToTrade)
    }

    /// The native dex keeps its own, larger budget (measured 8.115 vs 3.120).
    func testNativeDexKeepsItsOwnBudget() {
        let st = crossDexState(totalCollateral: "14.4519", equity: "14.4519", initialMarginUsed: "6.3333",
            positions: [dexPosition("hl:0:BTC", marginUsed: "4.9971", positionValue: "99.9425"),
                        dexPosition("hl:1:NVDA", marginUsed: "0.6807", positionValue: "13.6134"),
                        dexPosition("hl:9:US500", marginUsed: "0.6555", positionValue: "13.1109")])
        let btc = deriveActiveAssetData(from: st, market: "hl:0:BTC", markPx: 79954, leverage: 20, side: .buy)!
        XCTAssertEqual(Double(btc.availableToTrade)!, 8.1186, accuracy: 0.001)
        XCTAssertFalse(btc.availability!.reservationEnforced)
        XCTAssertEqual(Double(btc.availability!.crossDexAvailableUsd)!, 3.12145, accuracy: 0.001)
    }

    /// A single-pool venue declares no model and must be left entirely alone.
    func testNoModelMeansNoReservation() {
        let sim = crossDexState(totalCollateral: "14.4519", equity: "14.4519", initialMarginUsed: "6.3333",
            positions: [dexPosition("hl:0:BTC", marginUsed: "4.9971", positionValue: "99.9425"),
                        dexPosition("hl:1:NVDA", marginUsed: "0.6807", positionValue: "13.6134")],
            declaresModel: false)
        let d = deriveActiveAssetData(from: sim, market: "hl:1:NVDA", markPx: 226.59, leverage: 20, side: .buy)!
        XCTAssertEqual(Double(d.availableToTrade)!, 8.1186, accuracy: 0.001)
        XCTAssertFalse(d.availability!.reservationEnforced)
    }

    func testFallsBackToAccountWideSummaryWhenNoCrossBucket() {
        // Older servers, and any account with nothing isolated, where the two
        // are identical by construction.
        let state = makeState(equity: "1000")
        guard let d = deriveActiveAssetData(from: state, market: "hl:0:BTC", markPx: 80000,
                                            leverage: 5, side: .buy) else {
            XCTFail("expected non-nil"); return
        }
        XCTAssertEqual(Double(d.availableToTrade)!, 1000, accuracy: 1e-6)
    }

    // An isolated position can hold more collateral than its leverage implies
    // after updateIsolatedMargin; closing releases the whole amount. Mirrors the
    // server's lockedCollateral().
    func testReleasesIsolatedMarginNotMarginUsedIntoTheReversingBudget() {
        var withTopUp = makePosition(market: "hl:0:BTC", side: .long, size: "0.02", marginUsed: "320")
        withTopUp.isolatedMargin = "2000"
        let plainPos = makePosition(market: "hl:0:BTC", side: .long, size: "0.02", marginUsed: "320")

        let topUpState = makeState(equity: "1000", initialMarginUsed: "320", positions: [withTopUp])
        let plainState = makeState(equity: "1000", initialMarginUsed: "320", positions: [plainPos])

        guard let topUp = deriveActiveAssetData(from: topUpState, market: "hl:0:BTC", markPx: 80000,
                                                leverage: 5, side: .sell),
              let plain = deriveActiveAssetData(from: plainState, market: "hl:0:BTC", markPx: 80000,
                                                leverage: 5, side: .sell) else {
            XCTFail("expected non-nil"); return
        }
        // The extra $1,680 of dedicated collateral is released by the close and
        // is spendable on the reversing leg, so the open portion grows.
        XCTAssertTrue(Double(topUp.maxSellOpenSize!)! > Double(plain.maxSellOpenSize!)!)
        // The reduce leg is the position either way — collateral doesn't change it.
        XCTAssertEqual(topUp.maxSellReduceSize, plain.maxSellReduceSize)
    }
}

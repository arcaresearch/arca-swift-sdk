import XCTest
@testable import ArcaSDK

final class OrderBreakdownTests: XCTestCase {

    func testSpendMode() {
        let opts = OrderBreakdownOptions(
            amount: "200",
            amountType: .spend,
            leverage: 10,
            feeRate: "0.00045",
            price: "70.87",
            side: .buy,
            szDecimals: 5
        )
        let result = Arca.orderBreakdown(options: opts)

        XCTAssertEqual(result.price, "70.87")
        XCTAssertEqual(result.feeRate, "0.00045")
        XCTAssertTrue(Double(result.totalSpend)! > 199.9 && Double(result.totalSpend)! <= 200.1)
        XCTAssertTrue(Double(result.notionalUsd)! > 1990 && Double(result.notionalUsd)! < 1995)
        XCTAssertTrue(Double(result.marginRequired)! > 199 && Double(result.marginRequired)! < 199.5)
        XCTAssertTrue(Double(result.estimatedFee)! > 0.8 && Double(result.estimatedFee)! < 1.0)
        XCTAssertTrue(Double(result.tokens)! > 0)
        XCTAssertNil(result.estimatedLiquidationPrice)
    }

    // MARK: - Cross-margin liquidation estimates

    func testCrossMarginLiqLong_NoOtherPositions() {
        // equity = marginRequired + fee = 50000 + 225 = 50225
        // mmMerged = 0.03 * 10 * 50000 = 15000
        // equityPost = 50000, marginAvail = 35000
        // LONG liq = 50000 - 35000/10 = 46500
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .buy, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "50225", otherMaintenanceMargin: "0"
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 46500, accuracy: 0.5)
    }

    func testCrossMarginLiqShort_NoOtherPositions() {
        // SHORT liq = 50000 + 35000/10 = 53500
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .sell, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "50225", otherMaintenanceMargin: "0"
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 53500, accuracy: 0.5)
    }

    func testCrossMarginLiqAccountsForOtherPositionsMM() {
        // equity 60000, otherMM 5000
        // equityPost 59775, marginAvail = 59775 - 5000 - 15000 = 39775
        // LONG liq = 50000 - 39775/10 = 46022.5
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .buy, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "60000", otherMaintenanceMargin: "5000"
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 46022.5, accuracy: 0.5)
    }

    func testSameSideMergeBlendsEntryPrice() {
        // existing LONG 5 @ 40000, new BUY 10 @ 50000
        // mergedSize 15, mergedEntry = 46666.667
        // mmMerged = 0.03 * 15 * 46666.667 = 21000
        // equity 100000, fee = 225
        // marginAvail = 99775 - 21000 = 78775
        // LONG liq = 50000 - 78775/15 ~= 44748.333
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .buy, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "100000", otherMaintenanceMargin: "0",
                existingPosition: OrderBreakdownExistingPosition(
                    side: .long, size: "5", entryPrice: "40000"
                )
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 44748.333, accuracy: 1)
    }

    func testOppositeSideReduceKeepsExistingEntry() {
        // existing LONG 10 @ 50000, new SELL 4 @ 50000
        // surviving LONG 6 @ 50000
        // fee = 200000 * 0.00045 = 90, mmMerged = 9000
        // equityPost = 59910, marginAvail = 50910
        // LONG liq = 50000 - 50910/6 = 41515
        let opts = OrderBreakdownOptions(
            amount: "4", amountType: .tokens, leverage: 5,
            feeRate: "0.00045", price: "50000", side: .sell, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "60000", otherMaintenanceMargin: "0",
                existingPosition: OrderBreakdownExistingPosition(
                    side: .long, size: "10", entryPrice: "50000"
                )
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 41515, accuracy: 0.5)
    }

    func testOppositeSideEqualCloseYieldsNil() {
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .sell, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "60000", otherMaintenanceMargin: "0",
                existingPosition: OrderBreakdownExistingPosition(
                    side: .long, size: "10", entryPrice: "50000"
                )
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertNil(result.estimatedLiquidationPrice)
    }

    func testOppositeSideLargerFlipsSide() {
        // existing LONG 4 @ 50000, new SELL 10 @ 50000
        // resulting SHORT 6 @ 50000
        // fee 225, mmMerged 9000
        // equityPost 59775, marginAvail 50775
        // SHORT liq = 50000 + 50775/6 = 58462.5
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .sell, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "60000", otherMaintenanceMargin: "0",
                existingPosition: OrderBreakdownExistingPosition(
                    side: .long, size: "4", entryPrice: "50000"
                )
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertEqual(Double(result.estimatedLiquidationPrice ?? "")!, 58462.5, accuracy: 0.5)
    }

    func testOmitsLiqWhenMarginAvailNonPositive() {
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .buy, szDecimals: 5,
            maintenanceMarginRate: "0.03",
            accountContext: OrderBreakdownAccountContext(
                equity: "10000", otherMaintenanceMargin: "0"
            )
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertNil(result.estimatedLiquidationPrice)
    }

    func testOmitsLiqWhenMmrNotProvided() {
        let opts = OrderBreakdownOptions(
            amount: "10", amountType: .tokens, leverage: 10,
            feeRate: "0.00045", price: "50000", side: .buy, szDecimals: 5
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertNil(result.estimatedLiquidationPrice)
    }
}

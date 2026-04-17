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

    func testEstimatesLiquidationPriceForLong() {
        let opts = OrderBreakdownOptions(
            amount: "10",
            amountType: .tokens,
            leverage: 10,
            feeRate: "0.00045",
            price: "50000",
            side: .buy,
            szDecimals: 5,
            maintenanceMarginRate: "0.03"
        )
        let result = Arca.orderBreakdown(options: opts)
        // drop = (1 - 0.03) / 10 = 0.097
        // liq = 50000 * (1 - 0.097) = 50000 * 0.903 = 45150
        XCTAssertEqual(result.estimatedLiquidationPrice, "45150")
    }

    func testEstimatesLiquidationPriceForShort() {
        let opts = OrderBreakdownOptions(
            amount: "10",
            amountType: .tokens,
            leverage: 10,
            feeRate: "0.00045",
            price: "50000",
            side: .sell,
            szDecimals: 5,
            maintenanceMarginRate: "0.03"
        )
        let result = Arca.orderBreakdown(options: opts)
        // drop = (1 - 0.03) / 10 = 0.097
        // liq = 50000 * (1 + 0.097) = 50000 * 1.097 = 54850
        XCTAssertEqual(result.estimatedLiquidationPrice, "54850")
    }

    func testClampsNegativeLongLiqToOmitted() {
        let opts = OrderBreakdownOptions(
            amount: "10",
            amountType: .tokens,
            leverage: 1,
            feeRate: "0.00045",
            price: "50000",
            side: .buy,
            szDecimals: 5,
            maintenanceMarginRate: "-0.03"
        )
        let result = Arca.orderBreakdown(options: opts)
        XCTAssertNil(result.estimatedLiquidationPrice)
    }
}

import XCTest
import ArcaSDK

final class OrderReceiptRefinementTests: XCTestCase {
    private func receipt(size: String = "3", status: String = "FILLED", final: Bool = false) -> OrderExecutionReceipt {
        OrderExecutionReceipt(objectId: "account", operationId: "original", orderId: "order", status: status,
            filledSize: size, requestedSize: "10", remainingSize: "7", executionState: "partial",
            fulfillmentState: "partial", remainingDisposition: "cancelled", avgFillPrice: "100",
            averagePriceFinal: final)
    }
    private func fill(_ id: String = "a", size: String = "1", price: String = "100", order: String = "order",
                      original: String? = "original", recorded: String? = "fill-operation", stable: String? = nil) throws -> Fill {
        var json: [String: Any] = ["id": id, "orderId": order, "market": "gll:test:1", "size": size, "price": price, "side": "buy"]
        json["operationId"] = recorded; json["orderOperationId"] = original; json["fillId"] = stable
        return try JSONDecoder().decode(Fill.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func assertPreserved(_ original: OrderExecutionReceipt, _ result: OrderExecutionReceipt, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(original), try encoder.encode(result), file: file, line: line)
    }
    func testCompleteRecordedFillsRefinePriceAndPreserveOriginalPartialIOC() throws {
        let original = receipt()
        let result = original.refined(using: try [fill(size: "1", price: "100"), fill("b", size: "2", price: "103")])
        XCTAssertEqual(result.avgFillPrice, "102")
        XCTAssertTrue(result.averagePriceFinal); XCTAssertTrue(result.fillsComplete)
        XCTAssertEqual(result.averagePriceSource, "ledger_vwap")
        XCTAssertEqual(result.objectId, original.objectId); XCTAssertEqual(result.operationId, original.operationId)
        XCTAssertEqual(result.orderId, original.orderId); XCTAssertEqual(result.status, original.status)
        XCTAssertEqual(result.filledSize, "3"); XCTAssertEqual(result.requestedSize, "10"); XCTAssertEqual(result.remainingSize, "7")
        XCTAssertEqual(result.executionState, "partial"); XCTAssertEqual(result.fulfillmentState, "partial")
        XCTAssertEqual(result.remainingDisposition, "cancelled")
    }
    func testPreviewReplayAndOtherBracketLegsDoNotDoubleCount() throws {
        let fills = try [fill(size: "3", recorded: nil), fill("row1", size: "3", price: "102", stable: "venue1"),
                         fill("row2", size: "3.0", price: "102.0", stable: "venue1"), fill("child", size: "50", order: "other")]
        XCTAssertEqual(receipt().refined(using: fills).avgFillPrice, "102")
        XCTAssertTrue(receipt().refined(using: fills).averagePriceFinal)
    }
    func testIncompleteOverfilledForeignConflictingAndUnrecordedEvidencePreserveProvisional() throws {
        let original = receipt()
        let cases = try [[fill(size: "2")], [fill(size: "4")], [fill(size: "3", original: "foreign")],
                         [fill(size: "3", original: nil)], [fill(size: "3", recorded: nil)],
                         [fill("a", size: "3", stable: "venue"), fill("b", size: "3", price: "101", stable: "venue")],
                         [fill(size: "invalid")], [fill(size: "3", price: "0")],
                         [fill(size: "3", price: String(repeating: "9", count: 39))]]
        for fills in cases { try assertPreserved(original, original.refined(using: fills)) }
    }
    func testNoFillOpenAndAlreadyFinalNeverChange() throws {
        for original in [receipt(size: "0"), receipt(status: "OPEN"), receipt(final: true)] {
            try assertPreserved(original, original.refined(using: [fill(size: "3", price: "105")]))
        }
    }
    func testRepeatingAverageUsesEighteenFractionalDigits() throws {
        let result = receipt().refined(using: try [fill(size: "1", price: "1"), fill("b", size: "2", price: "2")])
        XCTAssertTrue(result.averagePriceFinal)
        XCTAssertEqual(result.avgFillPrice, "1.666666666666666667")
    }
}

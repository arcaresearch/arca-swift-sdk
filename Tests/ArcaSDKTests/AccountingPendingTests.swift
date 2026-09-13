import XCTest
@testable import ArcaSDK

final class AccountingPendingTests: XCTestCase {
    private func state(positions: [(market: String, side: String, size: String, entry: String)], pending: [AccountingPendingExecution]? = nil) throws -> ExchangeState {
        let rows = positions.map { #"{"id":"pos_\#($0.market)","market":"\#($0.market)","side":"\#($0.side)","size":"\#($0.size)","entryPrice":"\#($0.entry)","leverage":10,"marginUsed":"500"}"# }
        let pendingJSON = try pending.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        let json = #"{"account":{"id":"act","realmId":"rlm","name":"a","createdAt":"2026-09-12","updatedAt":"2026-09-12"},"marginSummary":{"equity":"10001","initialMarginUsed":"500","maintenanceMarginRequired":"50","availableToWithdraw":"8971","totalNtlPos":"5000","totalUnrealizedPnl":"-0.13","totalRawUsd":"10001"},"positions":[\#(rows.joined(separator: ","))],"openOrders":[],"accountingPending":\#(pendingJSON)}"#
        return try JSONDecoder().decode(ExchangeState.self, from: Data(json.utf8))
    }
    private func close(accounted: String, unaccounted: String) -> AccountingPendingExecution {
        AccountingPendingExecution(operationId: "op", orderId: "order", market: "gllt:13", side: "sell",
            executedSize: "1.148517", accountedSize: accounted, unaccountedSize: unaccounted, executionFinal: true, averagePrice: "4353.4")
    }

    /// The invariant the field exists for: the execution-time frame, every
    /// per-fill frame, and the settled frame compose to the same book.
    func testProjectedPositionsAreIdenticalAcrossTheAccountingWindow() throws {
        let frames = [
            try state(positions: [("gllt:13", "long", "1.148517", "4353.6")], pending: [close(accounted: "0", unaccounted: "1.148517")]),
            try state(positions: [("gllt:13", "long", "0.088517", "4353.6")], pending: [close(accounted: "1.06", unaccounted: "0.088517")]),
            try state(positions: [("gllt:13", "long", "0.000517", "4353.6")], pending: [close(accounted: "1.148", unaccounted: "0.000517")]),
            try state(positions: []),
        ]
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(frame.projectedPositions().isEmpty, "frame \(index) should compose flat")
            XCTAssertEqual(frame.isAccountingSettled, index == frames.count - 1, "frame \(index)")
        }
    }

    func testReduceIncreaseOpenAndReverse() throws {
        let reduce = try state(positions: [("gllt:13", "long", "1.148517", "4353.6")],
            pending: [AccountingPendingExecution(operationId: "op", market: "gllt:13", side: "sell", executedSize: "1.06", accountedSize: "0", unaccountedSize: "1.06", executionFinal: true, averagePrice: "4300")])
        let reduced = reduce.projectedPositions()
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced[0].size, Decimal(string: "0.088517"))
        XCTAssertEqual(reduced[0].side, .long)
        XCTAssertEqual(reduced[0].entryPrice, Decimal(string: "4353.6"), "a reduction keeps its entry")
        XCTAssertEqual(reduced[0].source, .execution)
        XCTAssertEqual(reduced[0].ledger?.id.rawValue, "pos_gllt:13")

        let increase = try state(positions: [("gllt:13", "long", "2", "100")],
            pending: [AccountingPendingExecution(operationId: "op", market: "gllt:13", side: "buy", executedSize: "1", accountedSize: "0", unaccountedSize: "1", executionFinal: true, averagePrice: "200")])
        let increased = increase.projectedPositions()
        XCTAssertEqual(increased[0].size, 3)
        XCTAssertEqual(increased[0].entryPrice.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0, 400.0 / 3, accuracy: 1e-9, "an increase blends the entry")

        let open = try state(positions: [("gllt:14", "short", "3", "40")],
            pending: [AccountingPendingExecution(operationId: "op", market: "gllt:13", side: "buy", executedSize: "2", accountedSize: "0", unaccountedSize: "2", executionFinal: true, averagePrice: "4353.4")])
        let opened = open.projectedPositions()
        XCTAssertEqual(opened.map(\.market), ["gllt:14", "gllt:13"], "ledger rows first, then opened markets")
        XCTAssertEqual(opened[0].source, .ledger)
        XCTAssertEqual(opened[1].side, .long)
        XCTAssertEqual(opened[1].size, 2)
        XCTAssertEqual(opened[1].entryPrice, Decimal(string: "4353.4"))
        XCTAssertNil(opened[1].ledger)

        let reverse = try state(positions: [("gllt:13", "long", "2", "100")],
            pending: [AccountingPendingExecution(operationId: "op", market: "gllt:13", side: "sell", executedSize: "5", accountedSize: "0", unaccountedSize: "5", executionFinal: true, averagePrice: "90")])
        let reversed = reverse.projectedPositions()
        XCTAssertEqual(reversed.count, 1)
        XCTAssertEqual(reversed[0].side, .short)
        XCTAssertEqual(reversed[0].size, 3)
        XCTAssertEqual(reversed[0].entryPrice, 90)
    }

    func testMalformedEntriesNeverInventOrEraseAPosition() throws {
        let broken = try state(positions: [("gllt:13", "long", "1", "100")],
            pending: [AccountingPendingExecution(operationId: "op", market: "gllt:13", side: "sell", executedSize: "1", accountedSize: "0", unaccountedSize: "not-a-number", executionFinal: true),
                      AccountingPendingExecution(operationId: "op2", market: "gllt:99", side: "sideways", executedSize: "1", accountedSize: "0", unaccountedSize: "1", executionFinal: true)])
        let rows = broken.projectedPositions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .ledger)
        XCTAssertEqual(rows[0].size, 1)
        XCTAssertFalse(broken.isAccountingSettled, "malformed entries still mean the observation is not settled")
    }

    func testFieldSurvivesRevaluationAndIsAbsentWhenSettled() throws {
        let pending = try state(positions: [("gllt:13", "long", "1", "100")], pending: [close(accounted: "0", unaccounted: "1.148517")])
        XCTAssertEqual(pending.revalued(with: ["gllt:13": "101"]).accountingPending?.count, 1, "any field added to ExchangeState must be carried through revaluation")
        let settled = try state(positions: [("gllt:13", "long", "1", "100")])
        XCTAssertNil(settled.accountingPending)
        XCTAssertTrue(settled.isAccountingSettled)
        XCTAssertEqual(settled.projectedPositions().map(\.source), [.ledger])
    }
}

import XCTest
@testable import ArcaSDK

private typealias ArcaOperation = ArcaSDK.Operation

final class OperationDisplayTests: XCTestCase {

    // MARK: - transferDirection

    func testTransferDirectionIncoming() {
        let op = makeTransfer(source: "/wallets/main", target: "/exchanges/strat-1")
        XCTAssertEqual(op.transferDirection(for: "/exchanges/strat-1"), .incoming)
    }

    func testTransferDirectionOutgoing() {
        let op = makeTransfer(source: "/exchanges/strat-1", target: "/wallets/main")
        XCTAssertEqual(op.transferDirection(for: "/exchanges/strat-1"), .outgoing)
    }

    func testTransferDirectionNilForNonTransfer() {
        let op = makeOperation(type: .fill, source: "/exchanges/main", target: nil)
        XCTAssertNil(op.transferDirection(for: "/exchanges/main"))
    }

    func testTransferDirectionNilWhenNoPathMatch() {
        let op = makeTransfer(source: "/wallets/a", target: "/wallets/b")
        XCTAssertNil(op.transferDirection(for: "/exchanges/strat-1"))
    }

    // MARK: - counterpartyLabel

    func testCounterpartyLabelVault() {
        let op = makeTransfer(source: "/wallets/main", target: "/exchanges/strat-1")
        XCTAssertEqual(op.counterpartyLabel(for: "/exchanges/strat-1"), "Vault")
    }

    func testCounterpartyLabelStrategyName() {
        let op = makeTransfer(source: "/exchanges/strat-1", target: "/wallets/main")
        XCTAssertEqual(op.counterpartyLabel(for: "/wallets/main"), "strat-1")
    }

    func testCounterpartyLabelNilForNonTransfer() {
        let op = makeOperation(type: .order, source: nil, target: "/exchanges/main")
        XCTAssertNil(op.counterpartyLabel(for: "/exchanges/main"))
    }

    func testCounterpartyLabelDeepPath() {
        let op = makeTransfer(source: "/users/abc/wallets/main", target: "/users/abc/exchanges/strat-2")
        XCTAssertEqual(op.counterpartyLabel(for: "/users/abc/exchanges/strat-2"), "Vault")
    }

    func testCounterpartyLabelNilWhenNoPathMatch() {
        let op = makeTransfer(source: "/wallets/main", target: "/exchanges/strat-1")
        XCTAssertNil(op.counterpartyLabel(for: "/unrelated/path"))
    }

    // MARK: - OperationContext convenience

    func testTransferContextAccessors() {
        let ctx = OperationContext(
            type: "transfer",
            fill: nil,
            transfer: TransferContext(amount: "5000", denomination: "USD", sourceArcaPath: "/a", targetArcaPath: "/b", feeAmount: "0.05"),
            deposit: nil,
            withdrawal: nil,
            order: nil,
            cancel: nil,
            delete: nil
        )
        XCTAssertEqual(ctx.transferAmount, "5000")
        XCTAssertEqual(ctx.transferFee, "0.05")
        XCTAssertEqual(ctx.transferDenomination, "USD")
    }

    func testTransferContextAccessorsNilForFill() {
        let ctx = OperationContext(
            type: "fill",
            fill: FillContext(coin: "BTC", side: "buy", size: "1", price: "50000", market: "BTC", dir: nil, orderId: nil, orderOperationId: nil, realizedPnl: "0", fee: "5", feeBreakdown: nil, netBalanceChange: "-50005", startPosition: nil, resultingPosition: nil, isLiquidation: false),
            transfer: nil,
            deposit: nil,
            withdrawal: nil,
            order: nil,
            cancel: nil,
            delete: nil
        )
        XCTAssertNil(ctx.transferAmount)
        XCTAssertNil(ctx.transferFee)
    }

    // MARK: - Helpers

    private func makeTransfer(source: String, target: String) -> ArcaOperation {
        makeOperation(type: .transfer, source: source, target: target)
    }

    private func makeOperation(type: OperationType, source: String?, target: String?) -> ArcaOperation {
        ArcaOperation(
            id: "op_test",
            realmId: "realm_test",
            path: "/op/test/1",
            type: type,
            state: .completed,
            sourceArcaPath: source,
            targetArcaPath: target,
            input: nil,
            outcome: nil,
            parsedOutcome: nil,
            failureMessage: nil,
            actorType: "builder",
            actorId: "user_test",
            tokenJti: nil,
            createdAt: "2026-03-18T00:00:00.000000Z",
            updatedAt: "2026-03-18T00:00:00.000000Z",
            context: nil
        )
    }
}

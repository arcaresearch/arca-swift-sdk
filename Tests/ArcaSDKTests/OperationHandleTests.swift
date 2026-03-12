import XCTest
@testable import ArcaSDK

// Use a typealias to disambiguate from Foundation.Operation
private typealias ArcaOperation = ArcaSDK.Operation

// MARK: - Test Helpers

private func makeOperation(
    id: String = "op_123",
    state: OperationState = .completed
) -> ArcaOperation {
    ArcaOperation(
        id: OperationID(id),
        realmId: RealmID("rlm_test"),
        path: "/op/test/1",
        type: .transfer,
        state: state,
        sourceArcaPath: "/wallets/a",
        targetArcaPath: "/wallets/b",
        input: nil,
        outcome: nil,
        actorType: "user",
        actorId: nil,
        tokenJti: nil,
        createdAt: "2026-03-08T00:00:00.000000Z",
        updatedAt: "2026-03-08T00:00:00.000000Z"
    )
}

private struct TestResponse: Codable, Sendable, OperationResponse {
    let operation: ArcaOperation
    let value: String

    func withOperation(_ op: ArcaOperation) -> Self {
        .init(operation: op, value: value)
    }
}

// MARK: - OperationHandle Tests

final class OperationHandleTests: XCTestCase {

    func testSettledResolvesImmediatelyForNonPendingOperation() async throws {
        let op = makeOperation(state: .completed)
        let response = TestResponse(operation: op, value: "hello")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in
                XCTFail("waitForSettlement should not be called for non-pending operations")
                return op
            }
        )

        let result = try await handle.settled
        XCTAssertEqual(result.value, "hello")
        XCTAssertEqual(result.operation.state, .completed)
    }

    func testSettledWaitsForPendingOperation() async throws {
        let pendingOp = makeOperation(state: .pending)
        let completedOp = makeOperation(state: .completed)
        let response = TestResponse(operation: pendingOp, value: "world")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { operationId in
                XCTAssertEqual(operationId, "op_123")
                return completedOp
            }
        )

        let result = try await handle.settled
        XCTAssertEqual(result.value, "world")
        XCTAssertEqual(result.operation.state, .completed)
    }

    func testSubmittedResolvesBeforeSettlement() async throws {
        let pendingOp = makeOperation(state: .pending)
        let response = TestResponse(operation: pendingOp, value: "early")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return makeOperation(state: .completed)
            }
        )

        let submitted = try await handle.submitted
        XCTAssertEqual(submitted.value, "early")
        XCTAssertEqual(submitted.operation.state, .pending)
    }

    func testSettledPropagatesSubmitError() async throws {
        let handle = OperationHandle<TestResponse>(
            submit: {
                throw ArcaError.validation(message: "bad input", errorId: nil)
            },
            waitForSettlement: { _ in
                XCTFail("Should not reach settlement")
                return makeOperation()
            }
        )

        do {
            _ = try await handle.settled
            XCTFail("Expected error")
        } catch {
            if case ArcaError.validation(let msg, _) = error {
                XCTAssertEqual(msg, "bad input")
            } else {
                XCTFail("Expected validation error, got \(error)")
            }
        }
    }

    func testSettledPropagatesSettlementError() async throws {
        let failedOp = makeOperation(state: .failed)
        let pendingOp = makeOperation(state: .pending)
        let response = TestResponse(operation: pendingOp, value: "will fail")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in
                throw ArcaError.operationFailed(operation: failedOp)
            }
        )

        do {
            _ = try await handle.settled
            XCTFail("Expected operation failed error")
        } catch {
            if case ArcaError.operationFailed(let op) = error {
                XCTAssertEqual(op.state, .failed)
            } else {
                XCTFail("Expected operationFailed, got \(error)")
            }
        }
    }

    func testSettledWithTimeoutSucceeds() async throws {
        let op = makeOperation(state: .completed)
        let response = TestResponse(operation: op, value: "fast")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in op }
        )

        let result = try await handle.settled(timeoutSeconds: 5)
        XCTAssertEqual(result.value, "fast")
    }

    func testSettledWithTimeoutThrows() async throws {
        let pendingOp = makeOperation(state: .pending)
        let response = TestResponse(operation: pendingOp, value: "slow")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return makeOperation(state: .completed)
            }
        )

        do {
            _ = try await handle.settled(timeoutSeconds: 0.1)
            XCTFail("Expected timeout")
        } catch {
            if case ArcaError.unknown(let code, _, _) = error {
                XCTAssertEqual(code, "TIMEOUT")
            } else {
                XCTFail("Expected TIMEOUT error, got \(error)")
            }
        }
    }

    func testMultipleSettledCallsReturnSameResult() async throws {
        let op = makeOperation(state: .pending)
        let response = TestResponse(operation: op, value: "cached")

        let handle = OperationHandle<TestResponse>(
            submit: { response },
            waitForSettlement: { _ in makeOperation(state: .completed) }
        )

        let r1 = try await handle.settled
        let r2 = try await handle.settled
        XCTAssertEqual(r1.value, "cached")
        XCTAssertEqual(r2.value, "cached")
    }

    func testAsyncLetBatching() async throws {
        let op1 = makeOperation(id: "op_1", state: .completed)
        let op2 = makeOperation(id: "op_2", state: .completed)
        let resp1 = TestResponse(operation: op1, value: "first")
        let resp2 = TestResponse(operation: op2, value: "second")

        let handle1 = OperationHandle<TestResponse>(
            submit: { resp1 },
            waitForSettlement: { _ in op1 }
        )
        let handle2 = OperationHandle<TestResponse>(
            submit: { resp2 },
            waitForSettlement: { _ in op2 }
        )

        async let r1 = handle1.settled
        async let r2 = handle2.settled
        let (result1, result2) = try await (r1, r2)

        XCTAssertEqual(result1.value, "first")
        XCTAssertEqual(result2.value, "second")
    }
}

// MARK: - OperationResponse Conformance Tests

final class OperationResponseConformanceTests: XCTestCase {

    func testTransferResponseConformance() {
        let original = TransferResponse(operation: makeOperation(state: .pending), fee: nil)
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
    }

    func testFundAccountResponseConformance() {
        let original = FundAccountResponse(
            operation: makeOperation(state: .pending),
            poolAddress: "0xabc",
            tokenAddress: "0xdef",
            chain: "ethereum",
            expiresAt: "2026-03-08T01:00:00.000000Z"
        )
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
        XCTAssertEqual(updated.poolAddress, "0xabc")
        XCTAssertEqual(updated.tokenAddress, "0xdef")
        XCTAssertEqual(updated.chain, "ethereum")
    }

    func testDefundAccountResponseConformance() {
        let original = DefundAccountResponse(
            operation: makeOperation(state: .pending),
            txHash: "0x123"
        )
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
        XCTAssertEqual(updated.txHash, "0x123")
    }

    func testCreateArcaObjectResponseConformance() {
        let obj = ArcaObject(
            id: ObjectID("obj_1"), realmId: RealmID("rlm_test"),
            path: "/wallets/main", type: .denominated, denomination: "USD",
            status: .active, metadata: nil, deletedAt: nil, systemOwned: false,
            createdAt: "2026-03-08T00:00:00.000000Z",
            updatedAt: "2026-03-08T00:00:00.000000Z"
        )
        let original = CreateArcaObjectResponse(object: obj, operation: makeOperation(state: .pending))
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
        XCTAssertEqual(updated.object.path, "/wallets/main")
    }

    func testDeleteArcaObjectResponseConformance() {
        let obj = ArcaObject(
            id: ObjectID("obj_1"), realmId: RealmID("rlm_test"),
            path: "/wallets/old", type: .denominated, denomination: "USD",
            status: .deleted, metadata: nil, deletedAt: "2026-03-08T00:00:00.000000Z",
            systemOwned: false,
            createdAt: "2026-03-08T00:00:00.000000Z",
            updatedAt: "2026-03-08T00:00:00.000000Z"
        )
        let original = DeleteArcaObjectResponse(object: obj, operation: makeOperation(state: .pending))
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
    }

    func testOrderOperationResponseConformance() {
        let original = OrderOperationResponse(operation: makeOperation(state: .pending))
        let updated = original.withOperation(makeOperation(state: .completed))
        XCTAssertEqual(updated.operation.state, .completed)
    }
}

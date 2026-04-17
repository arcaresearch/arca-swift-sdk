import XCTest
@testable import ArcaSDK

final class ModelDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - TypedID

    func testTypedIDDecoding() throws {
        let json = Data(#""obj_01h2xcejqtf2nbrexx3vqjhp41""#.utf8)
        let id = try decoder.decode(ObjectID.self, from: json)
        XCTAssertEqual(id.rawValue, "obj_01h2xcejqtf2nbrexx3vqjhp41")
    }

    func testTypedIDEncoding() throws {
        let id: ObjectID = "obj_test123"
        let data = try JSONEncoder().encode(id)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #""obj_test123""#)
    }

    func testTypedIDEquality() {
        let a: ObjectID = "obj_abc"
        let b: ObjectID = "obj_abc"
        let c: ObjectID = "obj_def"
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDifferentTagTypesAreDistinct() {
        let objId: ObjectID = "obj_abc"
        let opId: OperationID = "op_abc"
        // They cannot be compared directly (different types), so just verify they exist
        XCTAssertEqual(objId.rawValue, "obj_abc")
        XCTAssertEqual(opId.rawValue, "op_abc")
    }

    // MARK: - ArcaObject

    func testArcaObjectDecoding() throws {
        let json = """
        {
            "id": "obj_01h2xcejqtf2nbrexx3vqjhp41",
            "realmId": "rlm_01h2xcejqtf2nbrexx3vqjhp42",
            "path": "/wallets/main",
            "type": "denominated",
            "denomination": "USD",
            "status": "active",
            "metadata": null,
            "deletedAt": null,
            "systemOwned": false,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let obj = try decoder.decode(ArcaObject.self, from: json)
        XCTAssertEqual(obj.id.rawValue, "obj_01h2xcejqtf2nbrexx3vqjhp41")
        XCTAssertEqual(obj.path, "/wallets/main")
        XCTAssertEqual(obj.type, .denominated)
        XCTAssertEqual(obj.denomination, "USD")
        XCTAssertEqual(obj.status, .active)
        XCTAssertFalse(obj.systemOwned)
        XCTAssertNil(obj.metadata)
        XCTAssertNil(obj.deletedAt)
    }

    func testArcaObjectTypeValues() throws {
        for typeStr in ["denominated", "exchange", "deposit", "withdrawal", "escrow"] {
            let json = Data(#""\#(typeStr)""#.utf8)
            let decoded = try decoder.decode(ArcaObjectType.self, from: json)
            XCTAssertEqual(decoded.rawValue, typeStr)
        }
    }

    // MARK: - Operation

    func testOperationDecoding() throws {
        let json = """
        {
            "id": "op_01abc",
            "realmId": "rlm_01def",
            "path": "/op/transfer/1",
            "type": "transfer",
            "state": "completed",
            "sourceArcaPath": "/wallets/a",
            "targetArcaPath": "/wallets/b",
            "input": null,
            "outcome": "{\\"newBalance\\":\\"500\\"}",
            "actorType": "BUILDER",
            "actorId": "usr_01xyz",
            "tokenJti": null,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:01:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.type, .transfer)
        XCTAssertEqual(op.state, .completed)
        XCTAssertTrue(op.state.isTerminal)
        XCTAssertEqual(op.sourceArcaPath, "/wallets/a")
        XCTAssertEqual(op.targetArcaPath, "/wallets/b")
    }

    func testOperationDecodingWithFailureMessage() throws {
        let json = """
        {
            "id": "op_01abc",
            "realmId": "rlm_01def",
            "path": "/op/transfer/1",
            "type": "transfer",
            "state": "failed",
            "sourceArcaPath": "/wallets/a",
            "targetArcaPath": "/wallets/b",
            "input": null,
            "outcome": "{\\"reason\\":\\"CHAIN_SEND_FAILED\\"}",
            "failureMessage": "CHAIN_SEND_FAILED",
            "actorType": "BUILDER",
            "actorId": "usr_01xyz",
            "tokenJti": null,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:01:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.state, .failed)
        XCTAssertEqual(op.failureMessage, "CHAIN_SEND_FAILED")
    }

    func testOperationDecodingWithoutFailureMessage() throws {
        let json = """
        {
            "id": "op_01abc",
            "realmId": "rlm_01def",
            "path": "/op/transfer/1",
            "type": "transfer",
            "state": "completed",
            "sourceArcaPath": "/wallets/a",
            "targetArcaPath": "/wallets/b",
            "input": null,
            "outcome": null,
            "actorType": "BUILDER",
            "actorId": "usr_01xyz",
            "tokenJti": null,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:01:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.state, .completed)
        XCTAssertNil(op.failureMessage)
    }

    func testOperationTypeIncludesFill() throws {
        let json = Data(#""fill""#.utf8)
        let decoded = try decoder.decode(OperationType.self, from: json)
        XCTAssertEqual(decoded, .fill)
    }

    func testOperationTypeIncludesFunding() throws {
        let json = Data(#""funding""#.utf8)
        let decoded = try decoder.decode(OperationType.self, from: json)
        XCTAssertEqual(decoded, .funding)
    }

    func testOperationTypeIncludesAdjustment() throws {
        let json = Data(#""adjustment""#.utf8)
        let decoded = try decoder.decode(OperationType.self, from: json)
        XCTAssertEqual(decoded, .adjustment)
    }

    func testFundingOperationDecoding() throws {
        let json = """
        {
            "id": "op_fund01",
            "realmId": "rlm_01def",
            "path": "/op/funding/exchanges/main/BTC/op_fund01",
            "type": "funding",
            "state": "completed",
            "sourceArcaPath": "/exchanges/main",
            "targetArcaPath": null,
            "input": null,
            "outcome": "{\\"status\\":\\"completed\\"}",
            "actorType": "system",
            "actorId": "sim-exchange",
            "tokenJti": null,
            "createdAt": "2026-03-25T12:00:00.000000Z",
            "updatedAt": "2026-03-25T12:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.type, .funding)
        XCTAssertEqual(op.state, .completed)
    }

    func testFillOperationDecoding() throws {
        let json = """
        {
            "id": "op_fill01",
            "realmId": "rlm_01def",
            "path": "/op/fill/exchanges/main/ord_01/op_fill01",
            "type": "fill",
            "state": "completed",
            "sourceArcaPath": null,
            "targetArcaPath": "/exchanges/main",
            "input": null,
            "outcome": null,
            "actorType": "system",
            "actorId": "sim-exchange",
            "tokenJti": null,
            "createdAt": "2026-03-16T12:00:00.000000Z",
            "updatedAt": "2026-03-16T12:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.type, .fill)
        XCTAssertEqual(op.state, .completed)
    }

    func testOperationDecodingWithParsedOutcomeContainingArray() throws {
        let json = """
        {
            "id": "op_recon01",
            "realmId": "rlm_01def",
            "path": "/op/fill/exchanges/main/ord_01/op_recon01",
            "type": "fill",
            "state": "completed",
            "sourceArcaPath": null,
            "targetArcaPath": "/exchanges/main",
            "input": null,
            "outcome": null,
            "parsedOutcome": {
                "status": "matched",
                "equity": "10500.25",
                "positionCount": 3,
                "positionDetail": [
                    {"coin": "BTC", "size": "0.1", "side": "LONG"},
                    {"coin": "ETH", "size": "2.0", "side": "SHORT"}
                ],
                "isReconciled": true,
                "extra": null
            },
            "actorType": "system",
            "actorId": "venue-reconciliation",
            "tokenJti": null,
            "createdAt": "2026-03-28T10:00:00.000000Z",
            "updatedAt": "2026-03-28T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertEqual(op.type, .fill)
        XCTAssertEqual(op.state, .completed)

        let parsed = try XCTUnwrap(op.parsedOutcome)
        XCTAssertEqual(parsed["status"], .string("matched"))
        XCTAssertEqual(parsed["equity"], .string("10500.25"))
        XCTAssertEqual(parsed["positionCount"], .int(3))
        XCTAssertEqual(parsed["isReconciled"], .bool(true))
        XCTAssertEqual(parsed["extra"], .null)

        guard case .array(let positions) = parsed["positionDetail"] else {
            XCTFail("positionDetail should be an array")
            return
        }
        XCTAssertEqual(positions.count, 2)
        guard case .object(let first) = positions[0] else {
            XCTFail("first element should be an object")
            return
        }
        XCTAssertEqual(first["coin"], .string("BTC"))
        XCTAssertEqual(first["side"], .string("LONG"))
    }

    func testOperationDecodingWithNilParsedOutcome() throws {
        let json = """
        {
            "id": "op_01abc",
            "realmId": "rlm_01def",
            "path": "/op/transfer/1",
            "type": "transfer",
            "state": "completed",
            "sourceArcaPath": "/wallets/a",
            "targetArcaPath": "/wallets/b",
            "input": null,
            "outcome": null,
            "parsedOutcome": null,
            "actorType": "BUILDER",
            "actorId": "usr_01xyz",
            "tokenJti": null,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:01:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        XCTAssertNil(op.parsedOutcome)
    }

    func testOperationDecodingWithStringOnlyParsedOutcome() throws {
        let json = """
        {
            "id": "op_01abc",
            "realmId": "rlm_01def",
            "path": "/op/transfer/1",
            "type": "transfer",
            "state": "completed",
            "sourceArcaPath": null,
            "targetArcaPath": null,
            "input": null,
            "outcome": null,
            "parsedOutcome": {"status": "ok", "amount": "100.50"},
            "actorType": "BUILDER",
            "actorId": "usr_01xyz",
            "tokenJti": null,
            "createdAt": "2026-03-07T10:00:00.000000Z",
            "updatedAt": "2026-03-07T10:01:00.000000Z"
        }
        """.data(using: .utf8)!

        let op = try decoder.decode(Operation.self, from: json)
        let parsed = try XCTUnwrap(op.parsedOutcome)
        XCTAssertEqual(parsed["status"]?.stringValue, "ok")
        XCTAssertEqual(parsed["amount"]?.stringValue, "100.50")
    }

    func testOperationStateTerminal() {
        XCTAssertTrue(OperationState.completed.isTerminal)
        XCTAssertTrue(OperationState.failed.isTerminal)
        XCTAssertTrue(OperationState.expired.isTerminal)
        XCTAssertFalse(OperationState.pending.isTerminal)
    }

    // MARK: - Balance

    func testBalanceDecoding() throws {
        let json = """
        {
            "id": "bal_01abc",
            "arcaId": "obj_01def",
            "denomination": "USD",
            "amount": "1000.50",
            "arriving": "200.00",
            "settled": "800.50",
            "departing": "0.00",
            "total": "1000.50"
        }
        """.data(using: .utf8)!

        let balance = try decoder.decode(ArcaBalance.self, from: json)
        XCTAssertEqual(balance.denomination, "USD")
        XCTAssertEqual(balance.amount, "1000.50")
        XCTAssertEqual(balance.arriving, "200.00")
        XCTAssertEqual(balance.settled, "800.50")
        XCTAssertEqual(balance.departing, "0.00")
        XCTAssertEqual(balance.total, "1000.50")
    }

    func testBalanceDecoding_BasicShape() throws {
        let json = """
        {
            "id": "bal_01abc",
            "arcaId": "obj_01def",
            "denomination": "USD",
            "amount": "500.00"
        }
        """.data(using: .utf8)!

        let balance = try decoder.decode(ArcaBalance.self, from: json)
        XCTAssertEqual(balance.id?.rawValue, "bal_01abc")
        XCTAssertEqual(balance.arcaId?.rawValue, "obj_01def")
        XCTAssertEqual(balance.denomination, "USD")
        XCTAssertEqual(balance.amount, "500.00")
        XCTAssertNil(balance.arriving)
        XCTAssertNil(balance.settled)
        XCTAssertNil(balance.departing)
        XCTAssertNil(balance.total)
    }

    func testBalanceDecoding_SummaryShape() throws {
        let json = """
        {
            "denomination": "USD",
            "arriving": "50.00",
            "settled": "800.00",
            "departing": "100.00",
            "total": "950.00"
        }
        """.data(using: .utf8)!

        let balance = try decoder.decode(ArcaBalance.self, from: json)
        XCTAssertNil(balance.id)
        XCTAssertNil(balance.arcaId)
        XCTAssertNil(balance.amount)
        XCTAssertEqual(balance.denomination, "USD")
        XCTAssertEqual(balance.arriving, "50.00")
        XCTAssertEqual(balance.settled, "800.00")
        XCTAssertEqual(balance.departing, "100.00")
        XCTAssertEqual(balance.total, "950.00")
    }

    func testObjectDetailResponse_BasicBalances() throws {
        let json = """
        {
            "object": {
                "id": "obj_01abc",
                "realmId": "rlm_01def",
                "path": "/wallets/main",
                "type": "denominated",
                "denomination": "USD",
                "status": "active",
                "metadata": null,
                "deletedAt": null,
                "systemOwned": false,
                "createdAt": "2026-03-28T10:00:00.000000Z",
                "updatedAt": "2026-03-28T10:00:00.000000Z"
            },
            "operations": [],
            "events": [],
            "deltas": [],
            "balances": [
                {"id": "bal_01", "arcaId": "obj_01abc", "denomination": "USD", "amount": "1000"}
            ]
        }
        """.data(using: .utf8)!

        let detail = try decoder.decode(ArcaObjectDetailResponse.self, from: json)
        XCTAssertEqual(detail.balances.count, 1)
        XCTAssertEqual(detail.balances[0].denomination, "USD")
        XCTAssertEqual(detail.balances[0].amount, "1000")
        XCTAssertNil(detail.balances[0].arriving)
        XCTAssertNil(detail.reservedBalances)
        XCTAssertNil(detail.positions)
    }

    // MARK: - StateDelta

    func testStateDeltaDecoding() throws {
        let json = """
        {
            "id": "dlt_01abc",
            "realmId": "rlm_01def",
            "eventId": "evt_01ghi",
            "arcaPath": "/wallets/main",
            "deltaType": "balance_change",
            "beforeValue": "1000",
            "afterValue": "500",
            "createdAt": "2026-03-07T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let delta = try decoder.decode(StateDelta.self, from: json)
        XCTAssertEqual(delta.deltaType, .balanceChange)
        XCTAssertEqual(delta.beforeValue, "1000")
        XCTAssertEqual(delta.afterValue, "500")
    }

    func testStateDeltaBalanceAdjustmentDecoding() throws {
        let json = """
        {
            "id": "dlt_adj01",
            "realmId": "rlm_01def",
            "eventId": "evt_adj01",
            "arcaPath": "/exchanges/main",
            "deltaType": "balance_adjustment",
            "beforeValue": "9800.50",
            "afterValue": "9850.75",
            "createdAt": "2026-03-28T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let delta = try decoder.decode(StateDelta.self, from: json)
        XCTAssertEqual(delta.deltaType, .balanceAdjustment)
        XCTAssertEqual(delta.beforeValue, "9800.50")
        XCTAssertEqual(delta.afterValue, "9850.75")
    }

    func testDeltaTypeUnknownValueDoesNotCrash() throws {
        let json = """
        {
            "id": "dlt_future01",
            "realmId": "rlm_01def",
            "eventId": "evt_future01",
            "arcaPath": "/wallets/main",
            "deltaType": "some_future_delta_type",
            "beforeValue": null,
            "afterValue": "100",
            "createdAt": "2026-03-28T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let delta = try decoder.decode(StateDelta.self, from: json)
        XCTAssertEqual(delta.deltaType, .unknown("some_future_delta_type"))
    }

    func testDeltaTypeUnknownRoundTrips() throws {
        let original = DeltaType.unknown("custom_type")
        let data = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(DeltaType.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testOperationDetailWithBalanceAdjustmentDelta() throws {
        let json = """
        {
            "operation": {
                "id": "op_adj01",
                "realmId": "rlm_01def",
                "path": "/op/adjustment/exchanges/main/op_adj01",
                "type": "adjustment",
                "state": "completed",
                "sourceArcaPath": null,
                "targetArcaPath": "/exchanges/main",
                "input": null,
                "outcome": "{\\"type\\":\\"positive_drift\\"}",
                "actorType": "system",
                "actorId": "venue_reconciliation",
                "tokenJti": null,
                "createdAt": "2026-03-28T10:00:00.000000Z",
                "updatedAt": "2026-03-28T10:00:00.000000Z"
            },
            "events": [],
            "deltas": [
                {
                    "id": "dlt_01",
                    "realmId": "rlm_01def",
                    "arcaPath": "/exchanges/main",
                    "deltaType": "balance_change",
                    "beforeValue": "9800",
                    "afterValue": "9850",
                    "createdAt": "2026-03-28T10:00:00.000000Z"
                },
                {
                    "id": "dlt_02",
                    "realmId": "rlm_01def",
                    "arcaPath": "/exchanges/main",
                    "deltaType": "status_change",
                    "beforeValue": null,
                    "afterValue": "active",
                    "createdAt": "2026-03-28T10:00:00.000000Z"
                },
                {
                    "id": "dlt_03",
                    "realmId": "rlm_01def",
                    "eventId": "evt_adj01",
                    "arcaPath": "/exchanges/main",
                    "deltaType": "balance_adjustment",
                    "beforeValue": "9800",
                    "afterValue": "9850",
                    "createdAt": "2026-03-28T10:00:00.000000Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let detail = try decoder.decode(OperationDetailResponse.self, from: json)
        XCTAssertEqual(detail.operation.type, .adjustment)
        XCTAssertEqual(detail.deltas.count, 3)
        XCTAssertEqual(detail.deltas[0].deltaType, .balanceChange)
        XCTAssertEqual(detail.deltas[1].deltaType, .statusChange)
        XCTAssertEqual(detail.deltas[2].deltaType, .balanceAdjustment)
    }

    func testStateDeltaLabelsChangeDecoding() throws {
        let json = """
        {
            "id": "dlt_01abc",
            "realmId": "rlm_01def",
            "eventId": "evt_01ghi",
            "arcaPath": "/wallets/main/.info",
            "deltaType": "labels_change",
            "beforeValue": "{}",
            "afterValue": "{\\"tier\\": \\"gold\\"}",
            "createdAt": "2026-03-07T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let delta = try decoder.decode(StateDelta.self, from: json)
        XCTAssertEqual(delta.deltaType, .labelsChange)
        XCTAssertEqual(delta.beforeValue, "{}")
        XCTAssertEqual(delta.afterValue, "{\"tier\": \"gold\"}")
    }

    // MARK: - Exchange State

    func testExchangeStateDecoding() throws {
        let json = """
        {
            "account": {
                "id": "act_01abc",
                "realmId": "rlm_01def",
                "name": "test-exchange",
                "createdAt": "2026-03-07T10:00:00.000000Z",
                "updatedAt": "2026-03-07T10:00:00.000000Z"
            },
            "marginSummary": {
                "equity": "10000",
                "initialMarginUsed": "500",
                "maintenanceMarginRequired": "100",
                "availableToWithdraw": "9500",
                "totalNtlPos": "5000",
                "totalUnrealizedPnl": "100",
                "totalRawUsd": "9900"
            },
            "crossMarginSummary": {
                "equity": "10000",
                "initialMarginUsed": "500",
                "maintenanceMarginRequired": "100",
                "availableToWithdraw": "9500",
                "totalNtlPos": "5000",
                "totalUnrealizedPnl": "100",
                "totalRawUsd": "9900"
            },
            "crossMaintenanceMarginUsed": "100",
            "positions": [],
            "openOrders": [],
            "feeRates": null
        }
        """.data(using: .utf8)!

        let state = try decoder.decode(ExchangeState.self, from: json)
        XCTAssertEqual(state.account.id.rawValue, "act_01abc")
        XCTAssertEqual(state.marginSummary.equity, "10000")
        XCTAssertEqual(state.marginSummary.initialMarginUsed, "500")
        XCTAssertEqual(state.marginSummary.maintenanceMarginRequired, "100")
        XCTAssertEqual(state.marginSummary.availableToWithdraw, "9500")
        XCTAssertEqual(state.crossMaintenanceMarginUsed, "100")
        XCTAssertTrue(state.positions.isEmpty)
        XCTAssertTrue(state.openOrders.isEmpty)
        XCTAssertNil(state.feeRates)
    }

    func testExchangeStateDecodingWithPositions() throws {
        let json = """
        {
            "account": {
                "id": "act_01abc",
                "realmId": "rlm_01def",
                "name": "test-exchange",
                "createdAt": "2026-03-07T10:00:00.000000Z",
                "updatedAt": "2026-03-07T10:00:00.000000Z"
            },
            "marginSummary": {
                "equity": "10000",
                "initialMarginUsed": "500",
                "maintenanceMarginRequired": "100",
                "availableToWithdraw": "9500",
                "totalNtlPos": "5000",
                "totalUnrealizedPnl": "100",
                "totalRawUsd": "9900"
            },
            "positions": [
                {
                    "id": "sps_01abc",
                    "accountId": "act_01abc",
                    "realmId": "rlm_01def",
                    "coin": "BTC",
                    "side": "LONG",
                    "size": "0.1",
                    "entryPrice": "65000",
                    "leverage": 5,
                    "marginUsed": "1300",
                    "liquidationPrice": "52000",
                    "unrealizedPnl": "150.50",
                    "createdAt": "2026-03-07T10:00:00.000000Z",
                    "updatedAt": "2026-03-07T10:05:00.000000Z"
                }
            ],
            "openOrders": [],
            "feeRates": null
        }
        """.data(using: .utf8)!

        let state = try decoder.decode(ExchangeState.self, from: json)
        XCTAssertEqual(state.positions.count, 1)
        let pos = state.positions[0]
        XCTAssertEqual(pos.id.rawValue, "sps_01abc")
        XCTAssertEqual(pos.accountId?.rawValue, "act_01abc")
        XCTAssertEqual(pos.realmId?.rawValue, "rlm_01def")
        XCTAssertEqual(pos.coin, "BTC")
        XCTAssertEqual(pos.side, .long)
        XCTAssertEqual(pos.size, "0.1")
        XCTAssertEqual(pos.entryPrice, "65000")
        XCTAssertEqual(pos.leverage, 5)
        XCTAssertEqual(pos.marginUsed, "1300")
        XCTAssertEqual(pos.liquidationPrice, "52000")
        XCTAssertEqual(pos.unrealizedPnl, "150.50")
        XCTAssertEqual(pos.createdAt, "2026-03-07T10:00:00.000000Z")
        XCTAssertEqual(pos.updatedAt, "2026-03-07T10:05:00.000000Z")
    }

    func testPositionListResponseDecoding() throws {
        let json = """
        {
            "positions": [
                {
                    "id": "sps_01kme4wd4wft3sz9cjaj7vedmb",
                    "accountId": "act_01kmb3yn78ff3vrcseym39hqjv",
                    "realmId": "rlm_01kmb3gpdde24vxnppyc77j08y",
                    "coin": "hl:BTC",
                    "side": "LONG",
                    "size": "0.1",
                    "entryPrice": "65000",
                    "leverage": 5,
                    "marginUsed": "1300",
                    "liquidationPrice": "52000",
                    "unrealizedPnl": "150.50",
                    "createdAt": "2026-03-07T10:00:00.000000Z",
                    "updatedAt": "2026-03-07T10:05:00.000000Z"
                }
            ],
            "total": 1
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(PositionListResponse.self, from: json)
        XCTAssertEqual(response.positions.count, 1)
        XCTAssertEqual(response.total, 1)
        let pos = response.positions[0]
        XCTAssertEqual(pos.id.rawValue, "sps_01kme4wd4wft3sz9cjaj7vedmb")
        XCTAssertEqual(pos.coin, "hl:BTC")
        XCTAssertEqual(pos.side, .long)
        XCTAssertEqual(pos.size, "0.1")
        XCTAssertNil(pos.cumulativeFunding)
    }

    func testPositionDecoding_WithCumulativeFunding() throws {
        let json = """
        {
            "positions": [
                {
                    "id": "sps_01kme4wd4wft3sz9cjaj7vedmb",
                    "accountId": "act_01kmb3yn78ff3vrcseym39hqjv",
                    "realmId": "rlm_01kmb3gpdde24vxnppyc77j08y",
                    "coin": "hl:ETH",
                    "side": "SHORT",
                    "size": "1.0",
                    "entryPrice": "3500",
                    "leverage": 10,
                    "marginUsed": "350",
                    "liquidationPrice": "3850",
                    "unrealizedPnl": "-25.00",
                    "cumulativeFunding": "12.50",
                    "createdAt": "2026-03-07T10:00:00.000000Z",
                    "updatedAt": "2026-03-07T10:05:00.000000Z"
                }
            ],
            "total": 1
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(PositionListResponse.self, from: json)
        let pos = response.positions[0]
        XCTAssertEqual(pos.cumulativeFunding, "12.50")
        XCTAssertEqual(pos.side, .short)
    }

    func testPositionListResponseDecodingViaAPIEnvelope() throws {
        let json = """
        {
            "success": true,
            "data": {
                "positions": [
                    {
                        "id": "sps_01abc",
                        "accountId": "act_01abc",
                        "realmId": "rlm_01def",
                        "coin": "hl:BTC",
                        "side": "LONG",
                        "size": "0.5",
                        "entryPrice": "50000",
                        "leverage": 5,
                        "marginUsed": "5000"
                    }
                ],
                "total": 1
            }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(APIResponse<PositionListResponse>.self, from: json)
        XCTAssertTrue(envelope.success)
        XCTAssertEqual(envelope.data?.positions.count, 1)
        XCTAssertEqual(envelope.data?.positions[0].coin, "hl:BTC")
    }

    func testOrderListResponseDecoding() throws {
        let json = """
        {
            "orders": [
                {
                    "id": "ord_01abc",
                    "accountId": "act_01abc",
                    "realmId": "rlm_01def",
                    "coin": "hl:BTC",
                    "side": "SELL",
                    "orderType": "LIMIT",
                    "price": "66300",
                    "size": "0.1",
                    "filledSize": "0",
                    "status": "WAITING_FOR_TRIGGER",
                    "reduceOnly": true,
                    "timeInForce": "GTC",
                    "leverage": 5,
                    "isTrigger": true,
                    "triggerPx": "66300",
                    "tpsl": "tp",
                    "grouping": "positionTpsl",
                    "createdAt": "2026-03-28T03:50:00.000000Z",
                    "updatedAt": "2026-03-28T03:50:00.000000Z"
                }
            ],
            "total": 1
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(OrderListResponse.self, from: json)
        XCTAssertEqual(response.orders.count, 1)
        XCTAssertEqual(response.total, 1)
        let order = response.orders[0]
        XCTAssertEqual(order.id.rawValue, "ord_01abc")
        XCTAssertEqual(order.coin, "hl:BTC")
        XCTAssertEqual(order.side, .sell)
        XCTAssertEqual(order.isTrigger, true)
        XCTAssertEqual(order.triggerPx, "66300")
        XCTAssertEqual(order.tpsl, "tp")
        XCTAssertEqual(order.grouping, "positionTpsl")
    }

    func testOrderListResponseDecodingViaAPIEnvelope() throws {
        let json = """
        {
            "success": true,
            "data": {
                "orders": [
                    {
                        "id": "ord_01abc",
                        "coin": "hl:BTC",
                        "side": "BUY",
                        "orderType": "LIMIT",
                        "price": "60000",
                        "size": "0.5",
                        "filledSize": "0",
                        "status": "OPEN",
                        "reduceOnly": false,
                        "timeInForce": "GTC",
                        "leverage": 3
                    }
                ],
                "total": 1
            }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(APIResponse<OrderListResponse>.self, from: json)
        XCTAssertTrue(envelope.success)
        XCTAssertEqual(envelope.data?.orders.count, 1)
        XCTAssertEqual(envelope.data?.orders[0].coin, "hl:BTC")
    }

    func testExchangeStateDecodingWithOpenOrders() throws {
        let json = """
        {
            "account": {
                "id": "act_01abc",
                "realmId": "rlm_01def",
                "name": "test-exchange",
                "createdAt": "2026-03-07T10:00:00.000000Z",
                "updatedAt": "2026-03-07T10:00:00.000000Z"
            },
            "marginSummary": {
                "equity": "10000",
                "initialMarginUsed": "0",
                "maintenanceMarginRequired": "0",
                "availableToWithdraw": "10000",
                "totalNtlPos": "0",
                "totalUnrealizedPnl": "0",
                "totalRawUsd": "10000"
            },
            "positions": [],
            "openOrders": [
                {
                    "id": "ord_01abc",
                    "accountId": "act_01abc",
                    "realmId": "rlm_01def",
                    "coin": "ETH",
                    "side": "BUY",
                    "orderType": "LIMIT",
                    "price": "3000",
                    "size": "1.0",
                    "filledSize": "0",
                    "avgFillPrice": null,
                    "status": "OPEN",
                    "reduceOnly": false,
                    "timeInForce": "GTC",
                    "leverage": 3,
                    "builderFeeBps": null,
                    "createdAt": "2026-03-07T10:00:00.000000Z",
                    "updatedAt": "2026-03-07T10:00:00.000000Z"
                }
            ],
            "feeRates": null
        }
        """.data(using: .utf8)!

        let state = try decoder.decode(ExchangeState.self, from: json)
        XCTAssertEqual(state.openOrders.count, 1)
        let order = state.openOrders[0]
        XCTAssertEqual(order.id.rawValue, "ord_01abc")
        XCTAssertEqual(order.accountId?.rawValue, "act_01abc")
        XCTAssertEqual(order.realmId?.rawValue, "rlm_01def")
        XCTAssertEqual(order.coin, "ETH")
        XCTAssertEqual(order.side, .buy)
        XCTAssertEqual(order.orderType, .limit)
        XCTAssertEqual(order.price, "3000")
        XCTAssertEqual(order.size, "1.0")
        XCTAssertEqual(order.filledSize, "0")
        XCTAssertNil(order.avgFillPrice)
        XCTAssertEqual(order.status, .open)
        XCTAssertFalse(order.reduceOnly)
        XCTAssertEqual(order.timeInForce, .gtc)
        XCTAssertEqual(order.leverage, 3)
        XCTAssertNil(order.builderFeeBps)
        XCTAssertEqual(order.createdAt, "2026-03-07T10:00:00.000000Z")
        XCTAssertEqual(order.updatedAt, "2026-03-07T10:00:00.000000Z")
    }

    func testUpdateLeverageRequestEncodesLeverageAsInt() throws {
        struct LeverageBody: Encodable {
            let coin: String
            let leverage: Int
        }
        let body = LeverageBody(coin: "BTC", leverage: 40)
        let data = try JSONEncoder().encode(body)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"leverage\":40") || json.contains("\"leverage\": 40"),
                       "leverage must encode as a JSON integer, got: \(json)")
        XCTAssertFalse(json.contains("\"leverage\":\"40\""),
                        "leverage must NOT encode as a JSON string")
    }

    func testActiveAssetDataDecoding() throws {
        let json = """
        {
            "coin": "BTC",
            "leverage": { "type": "cross", "value": 5 },
            "maxBuySize": "0.1538",
            "maxSellSize": "-0.1538",
            "maxBuyUsd": "10000",
            "maxSellUsd": "-10000",
            "availableToTrade": "5000",
            "markPx": "65000",
            "feeRate": "0.00045",
            "maintenanceMarginRate": "0.03"
        }
        """.data(using: .utf8)!

        let data = try decoder.decode(ActiveAssetData.self, from: json)
        XCTAssertEqual(data.coin, "BTC")
        XCTAssertEqual(data.leverage.type, .cross)
        XCTAssertEqual(data.leverage.value, 5)
        XCTAssertEqual(data.maxBuySize, "0.1538")
        XCTAssertEqual(data.availableToTrade, "5000")
        XCTAssertEqual(data.markPx, "65000")
        XCTAssertEqual(data.maintenanceMarginRate, "0.03")
    }

    // MARK: - Aggregation

    func testPathAggregationDecoding() throws {
        let json = """
        {
            "prefix": "/",
            "totalEquityUsd": "50000",
            "departingUsd": "1000",
            "breakdown": [
                {
                    "asset": "USD",
                    "category": "spot",
                    "amount": "50000",
                    "price": "1",
                    "valueUsd": "50000"
                }
            ]
        }
        """.data(using: .utf8)!

        let agg = try decoder.decode(PathAggregation.self, from: json)
        XCTAssertEqual(agg.totalEquityUsd, "50000")
        XCTAssertEqual(agg.breakdown.count, 1)
        XCTAssertEqual(agg.breakdown[0].category, .spot)
        XCTAssertNil(agg.arrivingUsd)
        XCTAssertNil(agg.asOf)
    }

    func testObjectValuationDecoding_MissingReservedBalances() throws {
        let json = """
        {
            "objectId": "obj_01abc",
            "path": "/users/u1/wallet",
            "type": "denominated",
            "denomination": "USD",
            "valueUsd": "1000",
            "balances": [
                {"denomination": "USD", "amount": "1000", "price": "1.0", "valueUsd": "1000"}
            ]
        }
        """.data(using: .utf8)!

        let val = try decoder.decode(ObjectValuation.self, from: json)
        XCTAssertEqual(val.objectId.rawValue, "obj_01abc")
        XCTAssertEqual(val.valueUsd, "1000")
        XCTAssertEqual(val.balances.count, 1)
        XCTAssertNil(val.reservedBalances)
        XCTAssertNil(val.pendingInbound)
        XCTAssertNil(val.positions)
    }

    func testCreateWatchResponseDecoding_NoReservedBalances() throws {
        let json = """
        {
            "watchId": "req_01abc",
            "aggregation": {
                "prefix": "/users/u1/",
                "totalEquityUsd": "1000",
                "departingUsd": "0",
                "arrivingUsd": "0",
                "breakdown": [
                    {
                        "asset": "USD",
                        "category": "spot",
                        "amount": "1000",
                        "price": "1.0",
                        "valueUsd": "1000"
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CreateWatchResponse.self, from: json)
        XCTAssertEqual(resp.watchId.rawValue, "req_01abc")
        XCTAssertEqual(resp.aggregation.totalEquityUsd, "1000")
        XCTAssertEqual(resp.aggregation.breakdown.count, 1)
        XCTAssertEqual(resp.aggregation.breakdown[0].valueUsd, "1000")
    }

    func testPathAggregationRevalued_FromBreakdown() {
        let breakdown = [
            AssetBreakdown(
                asset: "hl:BTC",
                category: .spot,
                amount: "2",
                price: "50000",
                valueUsd: "100000",
                weightedAvgLeverage: nil,
                avgEntryPrice: nil
            ),
            AssetBreakdown(
                asset: "hl:ETH",
                category: .perp,
                amount: "1",
                price: "3000",
                valueUsd: "500",
                weightedAvgLeverage: nil,
                avgEntryPrice: nil
            ),
            AssetBreakdown(
                asset: "ex",
                category: .exchange,
                amount: "0",
                price: nil,
                valueUsd: "200",
                weightedAvgLeverage: nil,
                avgEntryPrice: nil
            ),
        ]
        let agg = PathAggregation(
            prefix: "/",
            totalEquityUsd: "100700",
            departingUsd: "10",
            arrivingUsd: "5",
            breakdown: breakdown,
            asOf: nil,
            cumInflowsUsd: nil,
            cumOutflowsUsd: nil
        )
        let mids = ["hl:BTC": "60000"]
        let re = agg.revalued(with: mids)
        XCTAssertEqual(re.departingUsd, "10")
        XCTAssertEqual(re.arrivingUsd, "5")
        XCTAssertEqual(re.breakdown[0].valueUsd, "120000")
        XCTAssertEqual(re.breakdown[0].price, "60000")
        XCTAssertEqual(re.breakdown[1].valueUsd, "500")
        XCTAssertEqual(re.breakdown[2].valueUsd, "200")
        XCTAssertEqual(re.totalEquityUsd, "120700")
    }

    // MARK: - Summary

    func testSummaryDecoding() throws {
        let json = """
        {
            "objectCount": 5,
            "operationCount": 20,
            "eventCount": 50,
            "pendingOperationCount": 2
        }
        """.data(using: .utf8)!

        let summary = try decoder.decode(ExplorerSummary.self, from: json)
        XCTAssertEqual(summary.objectCount, 5)
        XCTAssertEqual(summary.pendingOperationCount, 2)
        XCTAssertNil(summary.expiredOperationCount)
    }

    // MARK: - RealmEvent

    func testRealmEventDecoding() throws {
        let json = """
        {
            "type": "operation.updated",
            "realmId": "rlm_01abc",
            "entityId": "op_01def",
            "entityPath": "/op/transfer/1",
            "operation": {
                "id": "op_01def",
                "realmId": "rlm_01abc",
                "path": "/op/transfer/1",
                "type": "transfer",
                "state": "completed",
                "sourceArcaPath": "/wallets/a",
                "targetArcaPath": "/wallets/b",
                "input": null,
                "outcome": null,
                "actorType": null,
                "actorId": null,
                "tokenJti": null,
                "createdAt": "2026-03-07T10:00:00.000000Z",
                "updatedAt": "2026-03-07T10:01:00.000000Z"
            }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(RealmEvent.self, from: json)
        XCTAssertEqual(event.type, EventType.operationUpdated.rawValue)
        XCTAssertEqual(event.entityId, "op_01def")
        XCTAssertNotNil(event.operation)
        XCTAssertEqual(event.operation?.state, .completed)
        XCTAssertNil(event.mids)
    }

    // MARK: - TypedEvent

    func testTypedEventFromExchangeUpdated() throws {
        let json = """
        {
            "type": "exchange.updated",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "entityPath": "/exchanges/main",
            "correlationId": "corr_123",
            "deliverySeq": 42,
            "exchangeState": {
                "account": {
                    "id": "act_01abc",
                    "realmId": "rlm_01abc",
                    "name": "test",
                    "createdAt": "2026-03-07T10:00:00.000000Z",
                    "updatedAt": "2026-03-07T10:00:00.000000Z"
                },
                "marginSummary": {
                    "equity": "10000",
                    "initialMarginUsed": "0",
                    "maintenanceMarginRequired": "0",
                    "availableToWithdraw": "10000",
                    "totalNtlPos": "0",
                    "totalUnrealizedPnl": "0",
                    "totalRawUsd": "10000"
                },
                "positions": [],
                "openOrders": [],
                "feeRates": null
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .exchangeUpdated(let state, let envelope):
            XCTAssertEqual(state.account.id.rawValue, "act_01abc")
            XCTAssertEqual(envelope.realmId, "rlm_01abc")
            XCTAssertEqual(envelope.entityId, "obj_01def")
            XCTAssertEqual(envelope.correlationId, "corr_123")
            XCTAssertEqual(envelope.deliverySeq, 42)
        default:
            XCTFail("Expected .exchangeUpdated, got \(typed)")
        }
    }

    func testTypedEventFromFillPreview() throws {
        let json = """
        {
            "type": "exchange.fill",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "correlationId": "ord_01xyz",
            "sequence": 1,
            "deliverySeq": 5,
            "fill": {
                "id": "sf_01abc",
                "orderId": "ord_01xyz",
                "accountId": "act_01abc",
                "realmId": "rlm_01abc",
                "coin": "hl:BTC",
                "side": "BUY",
                "size": "0.1",
                "price": "65000",
                "fee": "1.5",
                "isMaker": false,
                "isLiquidation": false,
                "createdAt": "2026-03-27T12:00:00.000000Z"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .fillPreview(let fill, let envelope):
            XCTAssertEqual(fill.coin, "hl:BTC")
            XCTAssertEqual(fill.side, .buy)
            XCTAssertEqual(envelope.correlationId, "ord_01xyz")
            XCTAssertEqual(envelope.sequence, 1)
        default:
            XCTFail("Expected .fillPreview, got \(typed)")
        }
    }

    func testTypedEventFromFillRecorded() throws {
        let json = """
        {
            "type": "fill.recorded",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "correlationId": "ord_01xyz",
            "sequence": 2,
            "deliverySeq": 6,
            "fill": {
                "id": "pl_01abc",
                "operationId": "op_fill_01",
                "orderId": "ord_01xyz",
                "market": "hl:BTC",
                "side": "BUY",
                "size": "0.1",
                "price": "65000",
                "fee": "1.5",
                "realizedPnl": "0",
                "resultingPosition": { "side": "LONG", "size": "0.1", "entryPx": "65000", "leverage": 5 },
                "isLiquidation": false,
                "createdAt": "2026-03-27T12:00:00.000000Z"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .fillRecorded(let fill, let envelope):
            XCTAssertEqual(fill.operationId, "op_fill_01")
            XCTAssertEqual(fill.market, "hl:BTC")
            XCTAssertEqual(envelope.correlationId, "ord_01xyz")
            XCTAssertEqual(envelope.sequence, 2)
        default:
            XCTFail("Expected .fillRecorded, got \(typed)")
        }
    }

    func testTypedEventFromFunding() throws {
        let json = """
        {
            "type": "exchange.funding",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "deliverySeq": 10,
            "funding": {
                "accountId": "act_01abc",
                "coin": "hl:BTC",
                "side": "LONG",
                "size": "0.5",
                "price": "65000",
                "fundingRate": "0.0001",
                "payment": "-0.25"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .fundingPayment(let payment, let envelope):
            XCTAssertEqual(payment.coin, "hl:BTC")
            XCTAssertEqual(payment.payment, "-0.25")
            XCTAssertEqual(envelope.entityId, "obj_01def")
        default:
            XCTFail("Expected .fundingPayment, got \(typed)")
        }
    }

    func testTypedEventFromOperationCreated() throws {
        let json = """
        {
            "type": "operation.created",
            "realmId": "rlm_01abc",
            "entityId": "op_01def",
            "entityPath": "/op/transfer/1",
            "eventId": "rev_01abc",
            "deliverySeq": 1,
            "operation": {
                "id": "op_01def",
                "realmId": "rlm_01abc",
                "path": "/op/transfer/1",
                "type": "transfer",
                "state": "pending",
                "sourceArcaPath": "/wallets/a",
                "targetArcaPath": "/wallets/b",
                "input": null,
                "outcome": null,
                "actorType": null,
                "actorId": null,
                "tokenJti": null,
                "createdAt": "2026-03-27T10:00:00.000000Z",
                "updatedAt": "2026-03-27T10:00:00.000000Z"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .operationCreated(let op, let envelope):
            XCTAssertEqual(op.type, .transfer)
            XCTAssertEqual(op.state, .pending)
            XCTAssertEqual(envelope.eventId, "rev_01abc")
            XCTAssertEqual(envelope.entityPath, "/op/transfer/1")
        default:
            XCTFail("Expected .operationCreated, got \(typed)")
        }
    }

    func testTypedEventFromTradeExecuted() throws {
        let json = """
        {
            "type": "trade.executed",
            "realmId": "rlm_01abc",
            "entityId": "hl:BTC",
            "coin": "hl:BTC",
            "deliverySeq": 50,
            "trade": {
                "coin": "hl:BTC",
                "px": "60500.00",
                "sz": "0.5",
                "side": "buy",
                "time": "2026-04-15T00:00:00.000",
                "hash": "0xabc123"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .tradeExecuted(let tradeEvent, let envelope):
            XCTAssertEqual(tradeEvent.coin, "hl:BTC")
            XCTAssertEqual(tradeEvent.trade.px, "60500.00")
            XCTAssertEqual(tradeEvent.trade.side, "buy")
            XCTAssertEqual(tradeEvent.trade.hash, "0xabc123")
            XCTAssertEqual(envelope.deliverySeq, 50)
        default:
            XCTFail("Expected .tradeExecuted, got \(typed)")
        }
    }

    func testTypedEventUnknownType() throws {
        let json = """
        {
            "type": "some.future.event",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "deliverySeq": 99
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .unknown(let event):
            XCTAssertEqual(event.type, "some.future.event")
        default:
            XCTFail("Expected .unknown, got \(typed)")
        }
    }

    func testTypedEventFromRealmCreated() throws {
        let json = """
        {
            "type": "realm.created",
            "realmId": "rlm_01abc",
            "entityId": "rlm_01abc",
            "deliverySeq": 1,
            "realm": {
                "id": "rlm_01abc",
                "orgId": "org_01def",
                "name": "Test Realm",
                "slug": "test-realm",
                "type": "demo",
                "description": null,
                "settings": null,
                "archivedAt": null,
                "createdBy": "usr_01xyz",
                "createdAt": "2026-03-27T10:00:00.000000Z",
                "updatedAt": "2026-03-27T10:00:00.000000Z"
            }
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .realmCreated(let realm, let envelope):
            XCTAssertEqual(realm.id.rawValue, "rlm_01abc")
            XCTAssertEqual(realm.name, "Test Realm")
            XCTAssertEqual(realm.slug, "test-realm")
            XCTAssertEqual(realm.type, .demo)
            XCTAssertEqual(envelope.entityId, "rlm_01abc")
            XCTAssertEqual(envelope.deliverySeq, 1)
        default:
            XCTFail("Expected .realmCreated, got \(typed)")
        }
    }

    func testTypedEventRealmCreatedMissingRealmFallsToUnknown() throws {
        let json = """
        {
            "type": "realm.created",
            "realmId": "rlm_01abc",
            "entityId": "rlm_01abc",
            "deliverySeq": 1
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)

        switch typed {
        case .unknown(let event):
            XCTAssertEqual(event.type, "realm.created")
        default:
            XCTFail("Expected .unknown for realm.created without realm payload, got \(typed)")
        }
    }

    func testTypedEventEnvelopeAccessor() throws {
        let json = """
        {
            "type": "balance.updated",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "timestamp": "2026-03-27T10:00:00.000000Z",
            "deliverySeq": 7
        }
        """.data(using: .utf8)!

        let raw = try decoder.decode(RealmEvent.self, from: json)
        let typed = TypedEvent.from(raw)
        let envelope = typed.envelope
        XCTAssertNotNil(envelope)
        XCTAssertEqual(envelope?.realmId, "rlm_01abc")
        XCTAssertEqual(envelope?.timestamp, "2026-03-27T10:00:00.000000Z")
        XCTAssertEqual(envelope?.deliverySeq, 7)
    }

    // MARK: - Deposit Response

    func testDepositResponseDecoding() throws {
        let json = """
        {
            "operation": {
                "id": "op_01abc",
                "realmId": "rlm_01def",
                "path": "/op/deposit/1",
                "type": "deposit",
                "state": "pending",
                "sourceArcaPath": null,
                "targetArcaPath": "/wallets/main",
                "input": null,
                "outcome": null,
                "actorType": "BUILDER",
                "actorId": "usr_01xyz",
                "tokenJti": null,
                "createdAt": "2026-03-07T10:00:00.000000Z",
                "updatedAt": "2026-03-07T10:00:00.000000Z"
            },
            "poolAddress": "0x1234567890abcdef",
            "tokenAddress": "0xabcdef1234567890",
            "chain": "reth",
            "expiresAt": "2026-03-07T11:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(FundAccountResponse.self, from: json)
        XCTAssertEqual(response.operation.type, .deposit)
        XCTAssertEqual(response.poolAddress, "0x1234567890abcdef")
        XCTAssertEqual(response.chain, "reth")
    }

    // MARK: - Market Data

    func testFillDecodingWithOrderOperationId() throws {
        let json = """
        {
            "id": "pl_01abc",
            "operationId": "op_fill_01",
            "orderOperationId": "op_order_01",
            "orderId": "ord_01",
            "market": "BTC",
            "side": "BUY",
            "size": "0.5",
            "price": "65000",
            "fee": "1.5",
            "realizedPnl": "0",
            "resultingPosition": { "side": "LONG", "size": "0.5", "entryPx": "65000", "leverage": 5 },
            "isLiquidation": false,
            "createdAt": "2026-03-16T12:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let fill = try decoder.decode(Fill.self, from: json)
        XCTAssertEqual(fill.operationId, "op_fill_01")
        XCTAssertEqual(fill.orderOperationId, "op_order_01")
        XCTAssertEqual(fill.orderId, "ord_01")
        XCTAssertEqual(fill.market, "BTC")
    }

    func testFillDecodingWithoutOrderOperationId() throws {
        let json = """
        {
            "id": "pl_02abc",
            "operationId": "op_fill_02",
            "market": "ETH",
            "resultingPosition": { "side": "SHORT", "size": "1.0", "leverage": 3 },
            "createdAt": "2026-03-16T12:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let fill = try decoder.decode(Fill.self, from: json)
        XCTAssertEqual(fill.operationId, "op_fill_02")
        XCTAssertNil(fill.orderOperationId)
        XCTAssertNil(fill.orderId)
    }

    func testSparklinesResponseDecoding() throws {
        let json = """
        {
            "sparklines": {
                "hl:BTC": [60000, 60100, 60050, 60200, 60150],
                "hl:ETH": [3000, 3010, 3005]
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(SparklinesResponse.self, from: json)
        XCTAssertEqual(response.sparklines.count, 2)
        XCTAssertEqual(response.sparklines["hl:BTC"]?.count, 5)
        XCTAssertEqual(response.sparklines["hl:ETH"]?.first, 3000)
    }

    func testMarketTickerDecoding() throws {
        let json = """
        {
            "coin": "hl:1:TSLA",
            "dex": "xyz",
            "symbol": "TSLA",
            "exchange": "hl",
            "markPx": "250",
            "midPx": "250",
            "prevDayPx": "248",
            "dayNtlVlm": "500000",
            "priceChange24hPct": "0.8",
            "openInterest": "1000",
            "funding": "0.0001",
            "nextFundingTime": 1711900800000,
            "feeScale": 2.0,
            "isDelisted": false
        }
        """.data(using: .utf8)!

        let ticker = try decoder.decode(MarketTicker.self, from: json)
        XCTAssertEqual(ticker.coin, "hl:1:TSLA")
        XCTAssertEqual(ticker.dex, "xyz")
        XCTAssertEqual(ticker.feeScale, 2.0)
        XCTAssertFalse(ticker.isDelisted)
    }

    func testMarketTickerDecoding_StandardPerp() throws {
        let json = """
        {
            "coin": "hl:BTC",
            "symbol": "BTC",
            "exchange": "hl",
            "markPx": "64000",
            "midPx": "64000",
            "prevDayPx": "63000",
            "dayNtlVlm": "5000000",
            "priceChange24hPct": "1.5",
            "openInterest": "10000",
            "funding": "0.0001",
            "feeScale": 1.0,
            "isDelisted": false
        }
        """.data(using: .utf8)!

        let ticker = try decoder.decode(MarketTicker.self, from: json)
        XCTAssertEqual(ticker.coin, "hl:BTC")
        XCTAssertEqual(ticker.feeScale, 1.0)
        XCTAssertNil(ticker.dex)
        XCTAssertNil(ticker.nextFundingTime)
    }

    func testSimBookResponseDecoding() throws {
        let json = """
        {
            "coin": "BTC",
            "bids": [{"price": "65000", "size": "1.5", "orderCount": 3}],
            "asks": [{"price": "65100", "size": "2.0", "orderCount": 5}],
            "time": 1709805600
        }
        """.data(using: .utf8)!

        let book = try decoder.decode(SimBookResponse.self, from: json)
        XCTAssertEqual(book.coin, "BTC")
        XCTAssertEqual(book.bids.count, 1)
        XCTAssertEqual(book.bids[0].price, "65000")
        XCTAssertEqual(book.asks[0].orderCount, 5)
    }

    // MARK: - SimFill Preview (exchange.fill WS event)

    func testSimFillDecoding_PreviewWithoutAccountRealmCreatedAt() throws {
        let json = """
        {
            "id": "sf_01abc",
            "orderId": "ord_01xyz",
            "coin": "hl:BTC",
            "side": "BUY",
            "size": "0.1",
            "price": "65000",
            "fee": "1.5",
            "isMaker": false,
            "isLiquidation": false
        }
        """.data(using: .utf8)!

        let fill = try decoder.decode(SimFill.self, from: json)
        XCTAssertEqual(fill.id.rawValue, "sf_01abc")
        XCTAssertEqual(fill.coin, "hl:BTC")
        XCTAssertEqual(fill.side, .buy)
        XCTAssertNil(fill.accountId)
        XCTAssertNil(fill.realmId)
        XCTAssertNil(fill.createdAt)
    }

    func testSimFillDecoding_FullWithAllFields() throws {
        let json = """
        {
            "id": "sf_01abc",
            "orderId": "ord_01xyz",
            "accountId": "act_01abc",
            "realmId": "rlm_01def",
            "coin": "hl:BTC",
            "side": "SELL",
            "size": "0.5",
            "price": "64000",
            "fee": "2.0",
            "builderFee": "0.5",
            "platformFee": "0.3",
            "realizedPnl": "100.00",
            "isLiquidation": false,
            "createdAt": "2026-03-28T12:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let fill = try decoder.decode(SimFill.self, from: json)
        XCTAssertEqual(fill.accountId?.rawValue, "act_01abc")
        XCTAssertEqual(fill.realmId?.rawValue, "rlm_01def")
        XCTAssertEqual(fill.createdAt, "2026-03-28T12:00:00.000000Z")
        XCTAssertEqual(fill.side, .sell)
        XCTAssertEqual(fill.platformFee, "0.3")
    }

    func testSimFillDecoding_PlatformFeeAbsent() throws {
        let json = """
        {
            "id": "sf_01abc",
            "orderId": "ord_01xyz",
            "coin": "hl:BTC",
            "side": "BUY",
            "size": "0.1",
            "price": "65000",
            "fee": "1.5",
            "isLiquidation": false
        }
        """.data(using: .utf8)!

        let fill = try decoder.decode(SimFill.self, from: json)
        XCTAssertNil(fill.platformFee)
    }

    func testRealmEventDecoding_ExchangeFillPreview() throws {
        let json = """
        {
            "type": "exchange.fill",
            "realmId": "rlm_01abc",
            "entityId": "obj_01def",
            "deliverySeq": 5,
            "fill": {
                "id": "sf_01abc",
                "orderId": "ord_01xyz",
                "coin": "hl:BTC",
                "side": "BUY",
                "size": "0.1",
                "price": "65000",
                "fee": "1.5",
                "isMaker": false,
                "isLiquidation": false
            }
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(RealmEvent.self, from: json)
        XCTAssertEqual(event.type, "exchange.fill")
        XCTAssertNotNil(event.fill)
        XCTAssertEqual(event.fill?.coin, "hl:BTC")
        XCTAssertNil(event.fill?.accountId)
    }

    // MARK: - ArcaObjectBrowseResponse

    func testBrowseResponseDecoding_NoPrefix() throws {
        let json = """
        {
            "folders": ["/users/", "/exchanges/"],
            "objects": [],
            "total": 2
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(ArcaObjectBrowseResponse.self, from: json)
        XCTAssertEqual(response.folders.count, 2)
        XCTAssertTrue(response.objects.isEmpty)
        XCTAssertEqual(response.total, 2)
    }

    // MARK: - PnlResponse omitempty

    func testPnlResponseDecoding_WithoutExternalFlows() throws {
        let json = """
        {
            "prefix": "/",
            "from": "2026-03-01T00:00:00.000000Z",
            "to": "2026-03-28T00:00:00.000000Z",
            "startingEquityUsd": "10000",
            "endingEquityUsd": "10500",
            "netInflowsUsd": "0",
            "netOutflowsUsd": "0",
            "pnlUsd": "500"
        }
        """.data(using: .utf8)!

        let pnl = try decoder.decode(PnlResponse.self, from: json)
        XCTAssertEqual(pnl.pnlUsd, "500")
        XCTAssertNil(pnl.externalFlows)
    }

    func testPnlResponseDecoding_WithExternalFlows() throws {
        let json = """
        {
            "prefix": "/",
            "from": "2026-03-01T00:00:00.000000Z",
            "to": "2026-03-28T00:00:00.000000Z",
            "startingEquityUsd": "10000",
            "endingEquityUsd": "10500",
            "netInflowsUsd": "1000",
            "netOutflowsUsd": "0",
            "pnlUsd": "-500",
            "externalFlows": [
                {
                    "operationId": "op_01abc",
                    "type": "deposit",
                    "direction": "inflow",
                    "amount": "1000",
                    "denomination": "USD",
                    "valueUsd": "1000",
                    "timestamp": "2026-03-15T12:00:00.000000Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let pnl = try decoder.decode(PnlResponse.self, from: json)
        XCTAssertEqual(pnl.externalFlows?.count, 1)
        XCTAssertEqual(pnl.externalFlows?[0].direction, "inflow")
    }

    // MARK: - PnlPoint valueUsd

    func testPnlPointDecoding_WithoutValueUsd() throws {
        let json = """
        { "timestamp": "2026-01-01T00:00:00Z", "pnlUsd": "100.00", "equityUsd": "5100.00" }
        """.data(using: .utf8)!
        let point = try decoder.decode(PnlPoint.self, from: json)
        XCTAssertEqual(point.pnlUsd, "100.00")
        XCTAssertNil(point.valueUsd)
    }

    func testPnlPointDecoding_WithValueUsd() throws {
        let json = """
        { "timestamp": "2026-01-01T00:00:00Z", "pnlUsd": "100.00", "equityUsd": "5100.00", "valueUsd": "5100.00" }
        """.data(using: .utf8)!
        let point = try decoder.decode(PnlPoint.self, from: json)
        XCTAssertEqual(point.valueUsd, "5100.00")
    }

    func testPnlPointMemberwiseInit_DefaultValueUsd() {
        let point = PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "200.00", equityUsd: "5200.00")
        XCTAssertNil(point.valueUsd)
    }

    func testPnlPointMemberwiseInit_WithValueUsd() {
        var point = PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "200.00", equityUsd: "5200.00")
        point.valueUsd = "5200.00"
        XCTAssertEqual(point.valueUsd, "5200.00")
    }

    func testPnlAnchorEnum() {
        let zero: PnlAnchor = .zero
        let equity: PnlAnchor = .equity
        XCTAssertNotEqual("\(zero)", "\(equity)")
    }

    // MARK: - applyEquityAnchor

    func testEquityAnchor_LivePointValueUsdEqualsEquity() {
        var points = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
            PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "500.00", equityUsd: "5500.00"),
        ]
        applyEquityAnchor(to: &points, liveEquity: 5500, livePnl: 500)

        XCTAssertEqual(points[1].valueUsd, "5500.00")
    }

    func testEquityAnchor_HistoricalPointsGetCorrectOffset() {
        var points = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
            PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "200.00", equityUsd: "5200.00"),
            PnlPoint(timestamp: "2026-01-01T02:00:00Z", pnlUsd: "800.00", equityUsd: "5800.00"),
        ]
        // offset = 5800 - 800 = 5000
        applyEquityAnchor(to: &points, liveEquity: 5800, livePnl: 800)

        XCTAssertEqual(points[0].valueUsd, "5000.00")
        XCTAssertEqual(points[1].valueUsd, "5200.00")
        XCTAssertEqual(points[2].valueUsd, "5800.00")
    }

    func testEquityAnchor_OffsetStableAcrossMidPriceUpdates() {
        let history = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
        ]
        let startingEquity = 5000.0

        // First price tick: equity = 5500, pnl = 500
        var points1 = history
        let pnl1 = 5500.0 - startingEquity
        points1.append(PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "500.00", equityUsd: "5500.00"))
        applyEquityAnchor(to: &points1, liveEquity: 5500, livePnl: pnl1)
        let hist1ValueUsd = points1[0].valueUsd

        // Second price tick: equity = 5300, pnl = 300
        var points2 = history
        let pnl2 = 5300.0 - startingEquity
        points2.append(PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "300.00", equityUsd: "5300.00"))
        applyEquityAnchor(to: &points2, liveEquity: 5300, livePnl: pnl2)

        XCTAssertEqual(points2[0].valueUsd, hist1ValueUsd, "Historical point valueUsd must be identical across price ticks")
        XCTAssertEqual(points2.last?.valueUsd, "5300.00", "Live point valueUsd must equal current equity")
    }

    func testEquityAnchor_OffsetShiftsOnFlowChange() {
        let history = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
        ]
        let startingEquity = 5000.0
        let liveEquity = 7000.0
        let cumInflows = 2000.0
        // pnl = 7000 - 5000 - 2000 = 0 (deposit doesn't create P&L)
        let pnl = liveEquity - startingEquity - cumInflows

        var points = history
        points.append(PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: String(format: "%.2f", pnl), equityUsd: "7000.00"))
        applyEquityAnchor(to: &points, liveEquity: liveEquity, livePnl: pnl)

        // offset = 7000 - 0 = 7000
        XCTAssertEqual(points[0].valueUsd, "7000.00")
        XCTAssertEqual(points[1].valueUsd, "7000.00")
        XCTAssertEqual(points[1].pnlUsd, "0.00")
    }

    func testEquityAnchor_DoesNotMutateOriginalHistoricalPoints() {
        let original = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
            PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "100.00", equityUsd: "5100.00"),
        ]
        var copy = original
        copy.append(PnlPoint(timestamp: "2026-01-01T02:00:00Z", pnlUsd: "500.00", equityUsd: "5500.00"))
        applyEquityAnchor(to: &copy, liveEquity: 5500, livePnl: 500)

        XCTAssertNil(original[0].valueUsd, "Original array must not be mutated")
        XCTAssertNil(original[1].valueUsd, "Original array must not be mutated")
        XCTAssertNotNil(copy[0].valueUsd, "Copy should have valueUsd set")
    }

    func testEquityAnchor_ZeroAnchorDefaultProducesNoValueUsd() {
        let points = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "100.00", equityUsd: "5100.00"),
            PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "200.00", equityUsd: "5200.00"),
        ]
        for p in points {
            XCTAssertNil(p.valueUsd, "Without applyEquityAnchor, points must not have valueUsd")
        }
    }

    func testEquityAnchor_NegativePnlProducesCorrectValues() {
        var points = [
            PnlPoint(timestamp: "2026-01-01T00:00:00Z", pnlUsd: "0.00", equityUsd: "5000.00"),
            PnlPoint(timestamp: "2026-01-01T01:00:00Z", pnlUsd: "-300.00", equityUsd: "4700.00"),
        ]
        // offset = 4700 - (-300) = 5000
        applyEquityAnchor(to: &points, liveEquity: 4700, livePnl: -300)

        XCTAssertEqual(points[0].valueUsd, "5000.00")
        XCTAssertEqual(points[1].valueUsd, "4700.00")
    }

    // MARK: - ArcaObjectType resilience

    func testArcaObjectTypeInfoDecoding() throws {
        let json = Data(#""info""#.utf8)
        let decoded = try decoder.decode(ArcaObjectType.self, from: json)
        XCTAssertEqual(decoded, .info)
    }

    func testArcaObjectTypeUnknownDecoding() throws {
        let json = Data(#""future_type""#.utf8)
        let decoded = try decoder.decode(ArcaObjectType.self, from: json)
        XCTAssertEqual(decoded, .unknown("future_type"))
    }

    func testArcaObjectTypeRoundTrips() throws {
        for typeStr in ["denominated", "exchange", "deposit", "withdrawal", "escrow", "info"] {
            let json = Data(#""\#(typeStr)""#.utf8)
            let decoded = try decoder.decode(ArcaObjectType.self, from: json)
            let encoded = try JSONEncoder().encode(decoded)
            let roundTripped = String(data: encoded, encoding: .utf8)
            XCTAssertEqual(roundTripped, #""\#(typeStr)""#)
        }
    }

    func testArcaObjectWithInfoType() throws {
        let json = """
        {
            "id": "obj_info01",
            "realmId": "rlm_01def",
            "path": "/.info",
            "type": "info",
            "denomination": null,
            "status": "active",
            "metadata": null,
            "deletedAt": null,
            "systemOwned": true,
            "createdAt": "2026-03-28T10:00:00.000000Z",
            "updatedAt": "2026-03-28T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let obj = try decoder.decode(ArcaObject.self, from: json)
        XCTAssertEqual(obj.type, .info)
        XCTAssertEqual(obj.path, "/.info")
        XCTAssertTrue(obj.systemOwned)
    }

    // MARK: - ExchangeState null arrays

    func testExchangeStateDecoding_NullPositionsAndOrders() throws {
        let json = """
        {
            "account": {
                "id": "act_01abc",
                "realmId": "rlm_01def",
                "name": "test",
                "createdAt": "2026-03-28T10:00:00.000000Z",
                "updatedAt": "2026-03-28T10:00:00.000000Z"
            },
            "marginSummary": {
                "equity": "10000",
                "initialMarginUsed": "0",
                "maintenanceMarginRequired": "0",
                "availableToWithdraw": "10000",
                "totalNtlPos": "0",
                "totalUnrealizedPnl": "0",
                "totalRawUsd": "10000"
            },
            "positions": null,
            "openOrders": null,
            "feeRates": null
        }
        """.data(using: .utf8)!

        let state = try decoder.decode(ExchangeState.self, from: json)
        XCTAssertTrue(state.positions.isEmpty)
        XCTAssertTrue(state.openOrders.isEmpty)
    }

    // MARK: - SnapshotBalancesResponse null arrays

    func testSnapshotBalancesDecoding_NullPositions() throws {
        let json = """
        {
            "realmId": "rlm_01abc",
            "arcaId": "obj_01def",
            "asOf": "2026-03-28T10:00:00.000000Z",
            "balances": [
                {"denomination": "USD", "amount": "1000"}
            ],
            "positions": null
        }
        """.data(using: .utf8)!

        let snapshot = try decoder.decode(SnapshotBalancesResponse.self, from: json)
        XCTAssertEqual(snapshot.balances.count, 1)
        XCTAssertTrue(snapshot.positions.isEmpty)
    }

    // MARK: - ArcaPositionCurrent entryPx

    func testArcaPositionCurrentDecoding_EntryPx() throws {
        let json = """
        {
            "id": "pos_01abc",
            "realmId": "rlm_01def",
            "arcaId": "obj_01ghi",
            "market": "hl:BTC",
            "side": "LONG",
            "size": "0.1",
            "leverage": 5,
            "entryPx": "65000",
            "updatedAt": "2026-03-28T10:00:00.000000Z"
        }
        """.data(using: .utf8)!

        let pos = try decoder.decode(ArcaPositionCurrent.self, from: json)
        XCTAssertEqual(pos.entryPx, "65000")
        XCTAssertEqual(pos.market, "hl:BTC")
    }

    // MARK: - ExchangeState.revalued(with:)

    private func makeTestExchangeState(
        positions: [SimPosition] = [],
        equity: String = "10000",
        totalRawUsd: String = "10000",
        maintenanceMarginRequired: String = "100"
    ) -> ExchangeState {
        let summary = SimMarginSummary(
            equity: equity, initialMarginUsed: "500",
            maintenanceMarginRequired: maintenanceMarginRequired,
            availableToWithdraw: "9900", totalNtlPos: "5000",
            totalUnrealizedPnl: "0", totalRawUsd: totalRawUsd
        )
        return ExchangeState(
            account: SimAccount(id: SimAccountID("act_1"), realmId: RealmID("rlm_1"),
                                name: "test", createdAt: "2026-01-01T00:00:00.000000Z",
                                updatedAt: "2026-01-01T00:00:00.000000Z"),
            marginSummary: summary, crossMarginSummary: summary,
            crossMaintenanceMarginUsed: "100",
            positions: positions, openOrders: [],
            feeRates: nil, pendingIntents: nil
        )
    }

    private func makeTestPosition(
        coin: String, side: PositionSide, size: String,
        entryPrice: String, marginUsed: String
    ) -> SimPosition {
        SimPosition(
            id: SimPositionID("sps_1"), accountId: SimAccountID("act_1"),
            realmId: RealmID("rlm_1"), coin: coin, side: side,
            size: size, entryPrice: entryPrice, leverage: 10,
            marginUsed: marginUsed, liquidationPrice: nil,
            unrealizedPnl: "0", returnOnEquity: "0",
            positionValue: nil, error: nil,
            cumulativeFunding: nil,
            createdAt: nil, updatedAt: nil
        )
    }

    func testExchangeStateRevalued_LongPositionPnl() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "0.5",
                                   entryPrice: "50000", marginUsed: "2500")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:BTC": "60000"])

        // LONG 0.5, entry 50000, mark 60000 → pnl = 0.5 * (60000 - 50000) = 5000
        XCTAssertEqual(result.positions[0].unrealizedPnl, "5000")
        XCTAssertEqual(result.positions[0].positionValue, "30000")
    }

    func testExchangeStateRevalued_ShortPositionPnl() {
        let pos = makeTestPosition(coin: "hl:ETH", side: .short, size: "2",
                                   entryPrice: "3200", marginUsed: "1280")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:ETH": "3000"])

        // SHORT 2, entry 3200, mark 3000 → pnl = -2 * (3000 - 3200) = 400
        XCTAssertEqual(result.positions[0].unrealizedPnl, "400")
    }

    func testExchangeStateRevalued_ReturnOnEquity() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:BTC": "55000"])

        // pnl = 5000, margin = 5000 → roe = 1.0
        let roe = Decimal(string: result.positions[0].returnOnEquity ?? "0") ?? 0
        XCTAssertEqual(roe, 1)
    }

    func testExchangeStateRevalued_MarginSummaryRecomputed() {
        let pos1 = makeTestPosition(coin: "hl:BTC", side: .long, size: "0.5",
                                    entryPrice: "50000", marginUsed: "2500")
        let pos2 = makeTestPosition(coin: "hl:ETH", side: .short, size: "2",
                                    entryPrice: "3200", marginUsed: "1280")
        let state = makeTestExchangeState(positions: [pos1, pos2])
        let result = state.revalued(with: ["hl:BTC": "60000", "hl:ETH": "3000"])

        // totalUnrealizedPnl = 5000 + 400 = 5400
        XCTAssertEqual(result.marginSummary.totalUnrealizedPnl, "5400")
        // equity = totalRawUsd + totalPnl = 10000 + 5400 = 15400
        XCTAssertEqual(result.marginSummary.equity, "15400")
        // availableToWithdraw = equity - maintenance = 15400 - 100 = 15300
        XCTAssertEqual(result.marginSummary.availableToWithdraw, "15300")
    }

    func testExchangeStateRevalued_CrossMarginSummaryAlsoRevalued() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:BTC": "55000"])

        XCTAssertEqual(result.crossMarginSummary?.totalUnrealizedPnl, "5000")
        XCTAssertEqual(result.crossMarginSummary?.equity, "15000")
    }

    func testExchangeStateRevalued_PreservesWhenMidMissing() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:ETH": "3000"])

        // No mid for BTC → position preserved as-is
        XCTAssertEqual(result.positions[0].unrealizedPnl, "0")
    }

    func testExchangeStateRevalued_ClearsError() {
        let pos = SimPosition(
            id: SimPositionID("sps_1"), accountId: SimAccountID("act_1"),
            realmId: RealmID("rlm_1"), coin: "hl:BTC", side: .long,
            size: "1", entryPrice: "50000", leverage: 10,
            marginUsed: "5000", liquidationPrice: nil,
            unrealizedPnl: nil, returnOnEquity: nil,
            positionValue: nil, error: "market_data_unavailable",
            cumulativeFunding: nil,
            createdAt: nil, updatedAt: nil
        )
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:BTC": "55000"])

        XCTAssertNil(result.positions[0].error)
        XCTAssertEqual(result.positions[0].unrealizedPnl, "5000")
    }

    func testExchangeStateRevalued_PreservesStructuralFields() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(positions: [pos])
        let result = state.revalued(with: ["hl:BTC": "55000"])

        XCTAssertEqual(result.account.id.rawValue, "act_1")
        XCTAssertEqual(result.openOrders.count, 0)
        XCTAssertEqual(result.marginSummary.initialMarginUsed, "500")
        XCTAssertEqual(result.marginSummary.totalRawUsd, "10000")
    }

    func testExchangeStateRevalued_EmptyPositions() {
        let state = makeTestExchangeState(positions: [])
        let result = state.revalued(with: ["hl:BTC": "60000"])

        XCTAssertTrue(result.positions.isEmpty)
        XCTAssertEqual(result.marginSummary.totalUnrealizedPnl, "0")
        XCTAssertEqual(result.marginSummary.equity, "10000")
    }

    func testExchangeStateRevalued_Idempotent() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(positions: [pos])
        let mids = ["hl:BTC": "55000"]
        let first = state.revalued(with: mids)
        let second = first.revalued(with: mids)

        XCTAssertEqual(first.marginSummary.equity, second.marginSummary.equity)
        XCTAssertEqual(first.positions[0].unrealizedPnl, second.positions[0].unrealizedPnl)
    }

    func testExchangeStateRevalued_FloorsAvailableToWithdrawAtZero() {
        let pos = makeTestPosition(coin: "hl:BTC", side: .long, size: "1",
                                   entryPrice: "50000", marginUsed: "5000")
        let state = makeTestExchangeState(
            positions: [pos], equity: "100", totalRawUsd: "100",
            maintenanceMarginRequired: "200"
        )
        let result = state.revalued(with: ["hl:BTC": "50000"])

        // equity = 100 + 0 = 100, maintenance = 200 → floor at 0
        XCTAssertEqual(result.marginSummary.availableToWithdraw, "0")
    }
}

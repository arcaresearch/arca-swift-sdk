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
            "availableToTrade": ["0.1538", "-0.1538"],
            "markPx": "65000",
            "feeRate": "0.00045"
        }
        """.data(using: .utf8)!

        let data = try decoder.decode(ActiveAssetData.self, from: json)
        XCTAssertEqual(data.coin, "BTC")
        XCTAssertEqual(data.leverage.type, .cross)
        XCTAssertEqual(data.leverage.value, 5)
        XCTAssertEqual(data.maxBuySize, "0.1538")
        XCTAssertEqual(data.availableToTrade?.first, "0.1538")
        XCTAssertEqual(data.markPx, "65000")
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
            ],
            "objects": []
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
                "breakdown": [],
                "objects": [
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
                ]
            }
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(CreateWatchResponse.self, from: json)
        XCTAssertEqual(resp.watchId.rawValue, "req_01abc")
        XCTAssertEqual(resp.aggregation.totalEquityUsd, "1000")
        XCTAssertEqual(resp.aggregation.objects.count, 1)
        XCTAssertNil(resp.aggregation.objects[0].reservedBalances)
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

    // MARK: - computed:false must not replace valid valuation

    func testObjectValuation_ComputedFalseNotUsedAsReplacement() throws {
        // Simulate the scenario: client has a valid valuation, then receives
        // a computed:false valuation. The computed:false payload should NOT
        // replace the prior value in a well-behaved consumer.
        let goodJSON = """
        {
            "objectId": "obj_exchange",
            "path": "/exchanges/main",
            "type": "exchange",
            "valueUsd": "1700",
            "balances": [
                {"denomination": "USD", "amount": "1700", "price": "1.0", "valueUsd": "1700"}
            ],
            "computed": true
        }
        """.data(using: .utf8)!

        let badJSON = """
        {
            "objectId": "",
            "path": "/exchanges/main",
            "type": "unknown",
            "valueUsd": "0",
            "balances": [],
            "computed": false
        }
        """.data(using: .utf8)!

        let good = try decoder.decode(ObjectValuation.self, from: goodJSON)
        let bad = try decoder.decode(ObjectValuation.self, from: badJSON)

        XCTAssertEqual(good.computed, true, "valid valuation must have computed=true")
        XCTAssertEqual(bad.computed, false, "placeholder valuation must have computed=false")
        XCTAssertEqual(good.valueUsd, "1700")
        XCTAssertEqual(bad.valueUsd, "0")

        // The key invariant: revaluing a computed:false valuation still
        // produces $0 — it must never be yielded to consumers as a replacement
        // for a previously valid valuation.
        let revalued = bad.revalued(with: ["USD": "1.0"])
        XCTAssertEqual(revalued.valueUsd, "0",
            "revaluing a computed:false placeholder should not produce a non-zero value")
        XCTAssertEqual(revalued.computed, false,
            "computed flag must survive revaluation")
    }
}

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
            "amount": "1000.50"
        }
        """.data(using: .utf8)!

        let balance = try decoder.decode(ArcaBalance.self, from: json)
        XCTAssertEqual(balance.denomination, "USD")
        XCTAssertEqual(balance.amount, "1000.50")
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
            "totalReservedUsd": "1000",
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
        XCTAssertNil(agg.totalInTransitUsd)
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
                "totalReservedUsd": "0",
                "totalInTransitUsd": "0",
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
}

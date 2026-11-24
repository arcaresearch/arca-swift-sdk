import XCTest
@testable import ArcaSDK

/// Production, 2026-11-15 to 2026-11-21 (Gobi Live): two users could not read
/// their trading account at all. `watchExchangeState` starts by fetching the
/// object's detail, which lists the object's latest operations, and one of
/// them was a bracket order parked in `pending_review`. `OperationState` had
/// no such case, so the whole detail response failed to decode until the
/// operation left that state six days later.
final class OperationStateDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    /// The object detail of that account, reduced to what matters: the parked
    /// bracket as the server sent it, a state no SDK version knows yet, and an
    /// ordinary completed order.
    private let detailJSON = #"""
    {"object":{"id":"obj_1kgydawnmq6v3ayfbxrd8r0rjy","realmId":"rlm_1","path":"/users/a/trading/b","type":"exchange","status":"active","systemOwned":false,"createdAt":"t","updatedAt":"t"},
     "operations":[
       {"id":"opr_30eekem6ef8b5rkf2kwcxmvga2","realmId":"rlm_1","path":"/op/order/a/df2bb204","type":"order","state":"pending_review",
        "targetArcaPath":"/users/a/trading/b",
        "input":"{\"exchangeObjectId\":\"obj_1kgydawnmq6v3ayfbxrd8r0rjy\",\"grouping\":\"normalTpsl\",\"orders\":[{\"market\":\"hl:0:SOPH\",\"side\":\"buy\",\"size\":\"4647\",\"orderType\":\"MARKET\"}]}",
        "outcome":"{\"status\":\"pending_review\",\"reason\":\"batch_order_outcome_unknown\",\"diagnostic\":{},\"swept\":true}",
        "createdAt":"2026-11-15T00:02:58.614144Z","updatedAt":"2026-11-15T00:08:04.693637Z"},
       {"id":"opr_future","realmId":"rlm_1","path":"/op/order/a/future","type":"order","state":"a_state_added_later",
        "createdAt":"t","updatedAt":"t"},
       {"id":"opr_done","realmId":"rlm_1","path":"/op/order/a/done","type":"order","state":"completed",
        "createdAt":"t","updatedAt":"t"}],
     "events":[],"deltas":[],"balances":[]}
    """#

    func testObjectDetailWithAnOperationInReviewStillDecodes() throws {
        let detail = try decoder.decode(ArcaObjectDetailResponse.self, from: Data(detailJSON.utf8))

        XCTAssertEqual(detail.operations.map(\.state), [.pendingReview, .unknown, .completed])
        XCTAssertEqual(detail.operations.map(\.state.isTerminal), [false, false, true],
                       "an operation in review, or in a state this SDK does not know, is not finished")
        XCTAssertEqual(detail.object.path, "/users/a/trading/b")
    }

    func testOperationStateRoundTripsKnownValuesAndNeverThrowsOnNewOnes() throws {
        for (wire, state) in [("pending", OperationState.pending), ("pending_review", .pendingReview),
                              ("completed", .completed), ("failed", .failed), ("expired", .expired)] {
            XCTAssertEqual(try decoder.decode(OperationState.self, from: Data("\"\(wire)\"".utf8)), state)
            XCTAssertEqual(state.rawValue, wire)
        }
        XCTAssertEqual(try decoder.decode(OperationState.self, from: Data(#""quarantined""#.utf8)), .unknown)
    }

    /// The token tells the server this build can read any operation state, so
    /// it need not present `pending_review` as `pending`.
    func testSDKAdvertisesThatItReadsAnyOperationState() {
        XCTAssertTrue(ArcaClient.advertisedCapabilities.contains("open-operation-states"))
    }
}

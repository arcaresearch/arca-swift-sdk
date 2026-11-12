import XCTest
@testable import ArcaSDK

final class ObservationOrderTests: XCTestCase {
    private func state(observedAt: String? = nil, asOf: String? = nil) throws -> ExchangeState {
        var allocation = ""
        if let asOf { allocation = #","tradingAllocation":{"asOf":"\#(asOf)","revision":"rev_1","preferences":{},"projectionUnavailable":true}"# }
        let observed = observedAt.map { #","observedAt":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(ExchangeState.self, from: Data(#"""
        {"account":{"id":"a","realmId":"r","name":"n","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
         "marginSummary":{"equity":"1","initialMarginUsed":"0","maintenanceMarginRequired":"0","availableToWithdraw":"1","totalNtlPos":"0","totalUnrealizedPnl":"0"},
         "positions":[],"openOrders":[]\#(observed)\#(allocation)}
        """#.utf8))
    }

    /// Go's RFC3339Nano trims trailing zeros, so fractions vary in length and
    /// the strings do not sort lexically; the parser keeps every digit.
    func testRFC3339KeepsSubMillisecondPrecisionAndVariableFractions() {
        let base = RFC3339.parse("2026-09-13T06:37:39Z")!.timeIntervalSince1970
        XCTAssertEqual(RFC3339.parse("2026-09-13T06:37:39.7Z")!.timeIntervalSince1970, base + 0.7, accuracy: 1e-7)
        XCTAssertEqual(RFC3339.parse("2026-09-13T06:37:39.706482Z")!.timeIntervalSince1970, base + 0.706482, accuracy: 1e-7)
        XCTAssertEqual(RFC3339.parse("2026-09-13T06:37:39.706482123Z")!.timeIntervalSince1970, base + 0.706482123, accuracy: 1e-6)
        XCTAssertLessThan(RFC3339.parse("2026-09-13T06:37:39.706482Z")!, RFC3339.parse("2026-09-13T06:37:39.7065Z")!)
        XCTAssertNil(RFC3339.parse("2026-09-13T06:37:39.Z"))
        XCTAssertNil(RFC3339.parse("not a time"))
    }

    func testObservedBeforeOrdersByReadTimeAndNeverByArrival() throws {
        let earlier = try state(observedAt: "2026-09-13T06:37:39.706482Z")
        let later = try state(observedAt: "2026-09-13T06:37:40.699918Z")
        XCTAssertTrue(earlier.observedBefore(later))
        XCTAssertFalse(later.observedBefore(earlier))
        XCTAssertFalse(later.observedBefore(later), "equal read times are the same observation, not an older one")

        // Platforms that stamp only the allocation's asOf order the same way.
        let viaAsOf = try state(asOf: "2026-09-13T06:37:39.000Z")
        XCTAssertTrue(viaAsOf.observedBefore(later))
        XCTAssertEqual(try state(observedAt: "2026-09-13T06:37:41Z", asOf: "2026-09-13T06:37:39Z").observationTime,
                       RFC3339.parse("2026-09-13T06:37:41Z"), "the explicit stamp wins over the allocation's")

        // An unstamped observation is never "before" anything: it applies as it always did.
        let unstamped = try state()
        XCTAssertFalse(unstamped.observedBefore(later))
        XCTAssertFalse(later.observedBefore(unstamped))
    }

    /// A watch re-marks its last structural state on every price tick. When
    /// revaluation dropped `observedAt`, those frames came out unstamped, so a
    /// consumer could not tell a pre-fill frame from the post-fill read it had
    /// already applied: on staging a filled TWAP slice appeared after the
    /// app's re-read and vanished on the next tick (2026-11-12, BRENTOIL).
    func testRevaluedFrameKeepsItsReadTimeSoAPreFillTickCannotReplaceAPostFillRead() throws {
        let preFill = try JSONDecoder().decode(ExchangeState.self, from: Data(#"""
        {"account":{"id":"a","realmId":"r","name":"n","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
         "marginSummary":{"equity":"10000","initialMarginUsed":"500","maintenanceMarginRequired":"50","availableToWithdraw":"9500","totalNtlPos":"5000","totalUnrealizedPnl":"0","totalRawUsd":"10000"},
         "positions":[{"id":"pos_btc","market":"hl:0:BTC","side":"long","size":"0.05","entryPrice":"100000","leverage":10,"marginUsed":"500"}],
         "openOrders":[],"observedAt":"2026-11-12T20:52:45.1Z","stateSource":"fold"}
        """#.utf8))
        let postFill = try state(observedAt: "2026-11-12T20:52:56.8Z")

        let tick = preFill.revalued(with: ["hl:0:BTC": "101000"])
        XCTAssertNotEqual(tick.marginSummary.totalUnrealizedPnl, preFill.marginSummary.totalUnrealizedPnl, "the tick must actually re-mark")
        XCTAssertEqual(tick.observedAt, preFill.observedAt, "revaluation changes prices, not when the state was read")
        XCTAssertEqual(tick.stateSource, preFill.stateSource)
        XCTAssertTrue(tick.observedBefore(postFill), "a re-marked pre-fill frame is still older than the post-fill read")
    }
}

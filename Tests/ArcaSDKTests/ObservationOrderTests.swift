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
}

import XCTest
@testable import ArcaSDK

/// Gobi letter 2026-10-30 ("P&L chart baseline"): once a live
/// `watchPnlChart` window slid, refreshed history counted P&L from the new
/// window start while the live point kept the opening start, so one update
/// carried two baselines.
final class PnlBaselineTests: XCTestCase {

    private func point(_ ts: String, pnl: String, equity: String, cumIn: String? = nil, cumOut: String? = nil, unfloored: String? = nil) -> PnlPoint {
        PnlPoint(timestamp: ts, pnlUsd: pnl, equityUsd: equity, unflooredEquityUsd: unfloored, cumInflowsUsd: cumIn, cumOutflowsUsd: cumOut)
    }

    private let baseline = PnlChartBaseline(
        timestamp: "2026-01-01T00:00:00Z", startingEquityUsd: "5000.00", cumInflowsUsd: "1000.00", cumOutflowsUsd: "0.00"
    )

    func testSlidWindowIsRebasedOntoOpeningBaseline() {
        // The window slid to 00:01 and the server counted from there.
        let slid = [
            point("2026-01-01T00:01:00Z", pnl: "0.00", equity: "5100.00", cumIn: "1000.00", cumOut: "0.00"),
            point("2026-01-01T00:02:00Z", pnl: "50.00", equity: "6150.00", cumIn: "2000.00", cumOut: "0.00"),
            point("2026-01-01T00:03:00Z", pnl: "-60.00", equity: "4040.00", cumIn: "2000.00", cumOut: "2000.00"),
        ]
        XCTAssertEqual(rebasePnlPoints(slid, baseline: baseline).map(\.pnlUsd), ["100.00", "150.00", "40.00"])
    }

    func testRebaseUsesUnflooredEquity() {
        let clamped = [point("2026-01-01T00:01:00Z", pnl: "0.00", equity: "0.00", cumIn: "1000.00", cumOut: "0.00", unfloored: "-50.00")]
        XCTAssertEqual(rebasePnlPoints(clamped, baseline: baseline).first?.pnlUsd, "-5050.00")
    }

    func testRebaseLeavesPointsWithoutFlowTotalsUntouched() {
        let withFlows = [point("2026-01-01T00:01:00Z", pnl: "0.00", equity: "5100.00", cumIn: "1000.00", cumOut: "0.00")]
        let mixed = withFlows + [point("2026-01-01T00:02:00Z", pnl: "10.00", equity: "5110.00")]
        let noFlowBaseline = PnlChartBaseline(timestamp: baseline.timestamp, startingEquityUsd: "5000.00")
        XCTAssertEqual(rebasePnlPoints(withFlows, baseline: noFlowBaseline).map(\.pnlUsd), ["0.00"])
        XCTAssertEqual(rebasePnlPoints(mixed, baseline: baseline).map(\.pnlUsd), ["0.00", "10.00"])
        XCTAssertEqual(rebasePnlPoints(withFlows, baseline: nil).map(\.pnlUsd), ["0.00"])
    }

    func testBaselineIsTheFirstPoint() {
        let pts = [point("2026-01-01T00:00:00Z", pnl: "0.00", equity: "5000.00", cumIn: "1000.00", cumOut: "0.00")]
        XCTAssertEqual(pnlBaseline(from: pts, startingEquityUsd: "5000.00"), baseline)
        XCTAssertNil(pnlBaseline(from: [], startingEquityUsd: "0"))
    }

    func testLivePnlKeepsInputPrecision() {
        // Formatting to cents made equityUsd − pnlUsd wobble by up to half a cent.
        XCTAssertEqual(formatPnlUsd(0.1234, inputs: ["5000.1234", "5000.00"]), "0.1234")
        XCTAssertEqual(formatPnlUsd(500, inputs: ["5500", "5000"]), "500.00")
        XCTAssertEqual(formatPnlUsd(1.0 / 3.0, inputs: ["0.333333333333333"]), "0.333333333")
        XCTAssertEqual(formatPnlUsd(-0.000001, inputs: ["1.00"]), "0.00")
    }

    func testSameCents() {
        XCTAssertTrue(sameCents("0.1201", "0.1249"))
        XCTAssertFalse(sameCents("0.12", "0.13"))
        XCTAssertTrue(sameCents(nil, nil))
        XCTAssertFalse(sameCents("0.12", nil))
    }

    private func history(points: [PnlPoint], bucketSeconds: Int?, serverNow: String?) -> PnlHistoryResponse {
        PnlHistoryResponse(
            prefix: "/w/", from: "2026-01-01T10:07:00Z", to: "2026-01-01T12:00:00Z", points: points.count,
            bucketSeconds: bucketSeconds, serverNow: serverNow, startingEquityUsd: "0", pnlPoints: points
        )
    }

    func testFlowsSinceIsTheFirstBucketClose() {
        let h = history(points: [point("2026-01-01T10:00:00Z", pnl: "0", equity: "0")], bucketSeconds: 3600, serverNow: "2026-01-01T12:00:00Z")
        XCTAssertEqual(RFC3339.parse(alignedFlowsSince(h, fallback: "x")), RFC3339.parse("2026-01-01T11:00:00Z"))
    }

    func testFlowsSinceStopsAtServerClockForOpenBucket() {
        let h = history(points: [point("2026-01-01T10:00:00Z", pnl: "0", equity: "0")], bucketSeconds: 3600, serverNow: "2026-01-01T10:30:00Z")
        XCTAssertEqual(RFC3339.parse(alignedFlowsSince(h, fallback: "x")), RFC3339.parse("2026-01-01T10:30:00Z"))
    }

    func testFlowsSinceFallsBackWithoutPointsOrBucketSize() {
        XCTAssertEqual(alignedFlowsSince(history(points: [], bucketSeconds: 60, serverNow: nil), fallback: "from"), "from")
        let noBucket = history(points: [point("2026-01-01T10:00:00Z", pnl: "0", equity: "0")], bucketSeconds: nil, serverNow: nil)
        XCTAssertEqual(alignedFlowsSince(noBucket, fallback: "from"), "from")
    }

    /// `watchPnlChart` has no HTTP + WebSocket fixture (see
    /// WatchPnlChartSelfHealingTests), so pin the wiring: every refetch path
    /// goes through the rebasing installer, and live P&L is never rounded to
    /// cents.
    func testWatchPnlChartRebasesEveryRefetchAndKeepsLivePrecision() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ArcaSDK/Arca+Aggregation.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "public func watchPnlChart("),
              let end = source.range(of: "public static func computeChartRange") else {
            XCTFail("watchPnlChart not found"); return
        }
        let body = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(body.contains("alignedFlowsSince(history"), "flowsSince must be the first bucket's close")
        XCTAssertTrue(body.contains("rebasePnlPoints(history.pnlPoints"), "opening history must be on the stream baseline")
        XCTAssertEqual(body.components(separatedBy: "absorbHistory(fresh)").count - 1, 2,
                       "both the gap handler and refreshHistory must install history through absorbHistory")
        XCTAssertFalse(body.contains("fresh.pnlPoints.filter"), "a refetch must not install server points without rebasing")
        XCTAssertFalse(body.contains("%.2f"), "live P&L must keep the precision of its inputs")
        XCTAssertTrue(body.contains("baseline: baselineBox.value"), "updates must carry the baseline")
    }
}

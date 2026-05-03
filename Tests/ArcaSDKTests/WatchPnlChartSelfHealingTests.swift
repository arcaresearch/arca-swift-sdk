import XCTest
@testable import ArcaSDK

/// Bug regression: prior to this fix, `Arca.watchPnlChart` was missing the
/// self-healing wiring (`resumeStream`, `authenticatedStream`, boundary timer,
/// multi-bucket gap detection, live-tail sliding window) that `watchEquityChart`
/// and `watchCandleChart` had already received. End-to-end behaviour testing
/// for the full chart factory wiring requires a mocked HTTP + WebSocket fixture
/// pair that this package does not yet have (Tests/AggregationHistoryTests
/// covers the HTTP layer alone).
///
/// This file pins the **structural parity** between the equity and P&L chart
/// factories by asserting both function bodies contain the same set of
/// self-healing markers. If you remove a marker from one factory, you must
/// remove it from the other — or both.
final class WatchPnlChartSelfHealingTests: XCTestCase {

    private func loadAggregationSource() throws -> String {
        // #filePath resolves to .../sdk/swift/Tests/ArcaSDKTests/<this file>.
        // Navigate up three levels to the package root, then down into the
        // SDK source.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ArcaSDKTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // sdk/swift/
            .appendingPathComponent("Sources/ArcaSDK/Arca+Aggregation.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the substring containing the body of the named function,
    /// from its `public func` declaration up to the next top-level marker.
    private func functionBody(in source: String, named: String, until nextMarker: String) -> Substring? {
        guard let start = source.range(of: "public func \(named)(") else { return nil }
        let after = source[start.lowerBound...]
        let endIndex = after.range(of: nextMarker)?.lowerBound ?? after.endIndex
        return after[..<endIndex]
    }

    func testEquityAndPnlChartFactoriesShareSelfHealingMarkers() throws {
        let source = try loadAggregationSource()

        guard let equityBody = functionBody(in: source, named: "watchEquityChart", until: "public func watchPnlChart(") else {
            XCTFail("watchEquityChart not found in source"); return
        }
        guard let pnlBody = functionBody(in: source, named: "watchPnlChart", until: "public static func computeChartRange") else {
            XCTFail("watchPnlChart not found in source"); return
        }

        let markers: [(label: String, marker: String)] = [
            ("resume task subscribes to ws.resumeStream",            "ws.resumeStream"),
            ("auth task subscribes to ws.authenticatedStream",       "ws.authenticatedStream"),
            ("boundary timer guards on agg-silence factor",          "BOUNDARY_AGG_SILENCE_FACTOR"),
            ("multi-bucket gap detection refetches dense window",    "Multi-bucket gap"),
            ("live-tail sliding window helper",                      "slideIfLive"),
            ("window box for sliding cache key + window state",      "windowBox"),
            ("live-tail threshold check vs LIVE_TAIL_THRESHOLD_S",   "LIVE_TAIL_THRESHOLD_S"),
            ("resume task cancellation in onTermination",            "resumeTask.cancel()"),
            ("auth task cancellation in onTermination",              "authTask.cancel()"),
            ("boundary task cancellation in onTermination",          "boundaryTask.cancel()"),
        ]

        for (label, marker) in markers {
            XCTAssertTrue(
                equityBody.contains(marker),
                "watchEquityChart missing marker '\(marker)' (\(label))"
            )
            XCTAssertTrue(
                pnlBody.contains(marker),
                "watchPnlChart missing marker '\(marker)' (\(label)) — Bug regression: the P&L chart must mirror the equity chart's self-healing wiring."
            )
        }
    }

    /// The previous-bucket boundary point in the agg-tick path used to copy
    /// the LAST HISTORICAL point's pnl/equity, which is the *previously
    /// closed* bucket — wrong by one bucket. The fix captures the live
    /// values that were current right before the boundary (mirroring TS
    /// `PnlChartStream`'s `prevPnlUsd`/`prevEquityUsd` capture). This test
    /// ensures we don't silently regress to the old pattern.
    func testWatchPnlChartCapturesPreviousLiveValuesForBoundaryPoint() throws {
        let source = try loadAggregationSource()
        guard let pnlBody = functionBody(in: source, named: "watchPnlChart", until: "public static func computeChartRange") else {
            XCTFail("watchPnlChart not found in source"); return
        }

        XCTAssertTrue(
            pnlBody.contains("previousLiveEquity") && pnlBody.contains("previousLivePnl"),
            "watchPnlChart must capture previousLiveEquity / previousLivePnl BEFORE absorbing the new agg, so a boundary cross emits the values that were current at the boundary."
        )

        // The single-bucket fallback must use the captured `previousLivePnl`,
        // not the last historical point's `pnlUsd`. Catch the old-style
        // copy by asserting the historical-tail copy pattern is gone.
        XCTAssertFalse(
            pnlBody.contains("pts[pts.count - 1]\n") && pnlBody.contains("pnlUsd: last.pnlUsd"),
            "watchPnlChart must NOT copy the last historical point's pnl/equity onto the boundary point — that is the *previously closed* bucket and produces an off-by-one boundary value."
        )
    }
}

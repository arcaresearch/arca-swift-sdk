import Foundation

private let minPnlDecimals = 2
private let maxPnlDecimals = 9

private func decimalPlaces(_ s: String?) -> Int {
    guard let s = s, let dot = s.firstIndex(of: ".") else { return 0 }
    let end = s.firstIndex(where: { $0 == "e" || $0 == "E" }) ?? s.endIndex
    guard end > dot else { return 0 }
    return s.distance(from: s.index(after: dot), to: end)
}

private func num(_ s: String?) -> Double {
    Double(s ?? "0") ?? 0
}

/// Formats a P&L value with as many decimals as the most precise input it
/// was derived from (at least 2, at most 9), so `equityUsd − pnlUsd` comes
/// out exactly at the inputs' precision instead of wobbling by up to half a
/// cent when P&L alone is rounded.
func formatPnlUsd(_ value: Double, inputs: [String?]) -> String {
    let places = min(inputs.reduce(minPnlDecimals) { max($0, decimalPlaces($1)) }, maxPnlDecimals)
    let fixed = String(format: "%.\(places)f", value)
    if fixed.hasPrefix("-"), fixed.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) {
        return String(fixed.dropFirst())
    }
    return fixed
}

/// Whether two dollar strings round to the same cent. Nil only matches nil.
func sameCents(_ a: String?, _ b: String?) -> Bool {
    guard let a = a, let b = b else { return a == nil && b == nil }
    return ((Double(a) ?? 0) * 100).rounded() == ((Double(b) ?? 0) * 100).rounded()
}

/// The baseline a history response counts P&L from: its first point. Nil
/// when the response has no points to count from.
func pnlBaseline(from points: [PnlPoint], startingEquityUsd: String) -> PnlChartBaseline? {
    guard let first = points.first else { return nil }
    return PnlChartBaseline(
        timestamp: first.timestamp,
        startingEquityUsd: startingEquityUsd,
        cumInflowsUsd: first.cumInflowsUsd,
        cumOutflowsUsd: first.cumOutflowsUsd
    )
}

/// Re-derives each point's `pnlUsd` against `baseline` from the point's
/// equity and lifetime cumulative flows. A response for a slid window
/// counts from its own first point; this puts it back on the baseline the
/// chart opened with. Returns `points` untouched when the baseline or any
/// point lacks cumulative flows (older servers).
func rebasePnlPoints(_ points: [PnlPoint], baseline: PnlChartBaseline?) -> [PnlPoint] {
    guard let baseline = baseline,
          let baseIn = baseline.cumInflowsUsd,
          let baseOut = baseline.cumOutflowsUsd,
          points.allSatisfy({ $0.cumInflowsUsd != nil && $0.cumOutflowsUsd != nil }) else {
        return points
    }
    let base = num(baseline.startingEquityUsd) - num(baseIn) + num(baseOut)
    return points.map { p in
        let equity = p.unflooredEquityUsd ?? p.equityUsd
        let adjusted = num(equity) - num(p.cumInflowsUsd) + num(p.cumOutflowsUsd)
        return PnlPoint(
            timestamp: p.timestamp,
            pnlUsd: formatPnlUsd(adjusted - base, inputs: [
                equity, p.cumInflowsUsd, p.cumOutflowsUsd, baseline.startingEquityUsd, baseIn, baseOut,
            ]),
            equityUsd: p.equityUsd,
            unflooredEquityUsd: p.unflooredEquityUsd,
            status: p.status,
            cumInflowsUsd: p.cumInflowsUsd,
            cumOutflowsUsd: p.cumOutflowsUsd,
            valueUsd: p.valueUsd
        )
    }
}

/// The instant a history response's first point describes. A bucket point
/// stamped `t` holds the state through the bucket's close, `t +
/// bucketSeconds` (or the server's clock, for the bucket still open), so a
/// flow committed between the requested `from` and that close is already
/// inside `startingEquityUsd`. Counting live flows from here, rather than
/// from `from`, keeps such a flow from being subtracted twice.
func alignedFlowsSince(_ history: PnlHistoryResponse, fallback: String) -> String {
    guard let first = history.pnlPoints.first,
          let bucketSeconds = history.bucketSeconds, bucketSeconds > 0,
          let start = RFC3339.parse(first.timestamp) else {
        return fallback
    }
    let cap = history.serverNow.flatMap(RFC3339.parse) ?? Date()
    return iso8601String(from: min(start.addingTimeInterval(TimeInterval(bucketSeconds)), cap))
}

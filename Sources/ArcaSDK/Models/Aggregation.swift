import Foundation

// MARK: - Aggregation

public enum AssetCategory: String, Codable, Sendable {
    case spot
    case perp
    case exchange
}

/// Indicates which side owns an object's price-derived valuation.
///
/// - `client`: the SDK recomputes price-derived fields (equity, uPnL, mark,
///   max-order-size) locally from raw mid prices. This is the default for all
///   traffic today.
/// - `server`: those fields are authoritative as delivered by the server; the
///   SDK must not recompute them from raw mids. Used by the (sim-only)
///   price-overlay feature so a large order's market impact stays consistent
///   across every surface.
///
/// Absent on the wire ⇒ treat as `.client` (byte-identical to today).
public enum PricingMode: String, Codable, Sendable {
    case client
    case server
}

public struct AssetBreakdown: Codable, Sendable {
    public let asset: String
    public let category: AssetCategory
    public let amount: String
    public let price: String?
    public let valueUsd: String
    public let weightedAvgLeverage: String?
    public let avgEntryPrice: String?
}

public struct BalanceValue: Codable, Sendable {
    public let denomination: String
    public let amount: String
    public let price: String?
    public let valueUsd: String
}

public struct PositionValue: Codable, Sendable {
    public let market: String
    public let side: String
    public let size: String
    public let entryPrice: String
    public let markPrice: String?
    public let unrealizedPnl: String?
    public let valueUsd: String?
}

public struct ReservedValue: Codable, Sendable {
    public let denomination: String
    public let amount: String
    public let price: String?
    public let valueUsd: String
    public let operationId: OperationID
    public let sourceArcaPath: String?
    public let destinationArcaPath: String?
    public let startedAt: String?
    public let inTransit: Bool?
}

public struct ObjectValuation: Codable, Sendable {
    public let objectId: ObjectID
    public let path: String
    public let type: String
    public let denomination: String?
    public let valueUsd: String
    public let balances: [BalanceValue]
    public let reservedBalances: [ReservedValue]?
    public let pendingInbound: [ReservedValue]?
    public let positions: [PositionValue]?
    /// When `.server`, price-derived fields are server-authoritative and the
    /// SDK does not recompute them from mids. Absent ⇒ `.client`.
    public let pricingMode: PricingMode?

    public init(
        objectId: ObjectID,
        path: String,
        type: String,
        denomination: String?,
        valueUsd: String,
        balances: [BalanceValue],
        reservedBalances: [ReservedValue]?,
        pendingInbound: [ReservedValue]?,
        positions: [PositionValue]?,
        pricingMode: PricingMode? = nil
    ) {
        self.objectId = objectId
        self.path = path
        self.type = type
        self.denomination = denomination
        self.valueUsd = valueUsd
        self.balances = balances
        self.reservedBalances = reservedBalances
        self.pendingInbound = pendingInbound
        self.positions = positions
        self.pricingMode = pricingMode
    }
}

public struct PathAggregation: Codable, Sendable {
    public let prefix: String
    public let totalEquityUsd: String
    public let departingUsd: String
    public let arrivingUsd: String?
    public let breakdown: [AssetBreakdown]
    public let asOf: String?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?
    /// When `.server`, totals are server-authoritative and the SDK does not
    /// recompute them from mids. Absent ⇒ `.client`.
    public let pricingMode: PricingMode?

    public init(
        prefix: String,
        totalEquityUsd: String,
        departingUsd: String,
        arrivingUsd: String?,
        breakdown: [AssetBreakdown],
        asOf: String?,
        cumInflowsUsd: String?,
        cumOutflowsUsd: String?,
        pricingMode: PricingMode? = nil
    ) {
        self.prefix = prefix
        self.totalEquityUsd = totalEquityUsd
        self.departingUsd = departingUsd
        self.arrivingUsd = arrivingUsd
        self.breakdown = breakdown
        self.asOf = asOf
        self.cumInflowsUsd = cumInflowsUsd
        self.cumOutflowsUsd = cumOutflowsUsd
        self.pricingMode = pricingMode
    }
}

// MARK: - Client-Side Revaluation

extension BalanceValue {
    /// Returns a copy with `valueUsd` and `price` recomputed from current mid prices.
    public func revalued(with mids: [String: String]) -> BalanceValue {
        let mid = mids[denomination] ?? "1"
        let amountDec = Decimal(string: amount) ?? 0
        let priceDec = Decimal(string: mid) ?? 1
        let value = amountDec * priceDec
        return BalanceValue(denomination: denomination, amount: amount,
                            price: mid, valueUsd: "\(value)")
    }
}

extension PositionValue {
    /// Returns a copy with `markPrice`, `unrealizedPnl`, and `valueUsd` recomputed.
    public func revalued(with mids: [String: String]) -> PositionValue {
        guard let mid = mids[market], let markDec = Decimal(string: mid) else { return self }
        let sizeDec = Decimal(string: size) ?? 0
        let entryDec = Decimal(string: entryPrice) ?? 0
        let signedSize: Decimal = (side == "short") ? -sizeDec : sizeDec
        let pnl = signedSize * (markDec - entryDec)
        return PositionValue(market: market, side: side, size: size, entryPrice: entryPrice,
                             markPrice: mid, unrealizedPnl: "\(pnl)", valueUsd: "\(pnl)")
    }
}

extension ReservedValue {
    /// Returns a copy with `valueUsd` and `price` recomputed from current mid prices.
    public func revalued(with mids: [String: String]) -> ReservedValue {
        let mid = mids[denomination] ?? "1"
        let amountDec = Decimal(string: amount) ?? 0
        let priceDec = Decimal(string: mid) ?? 1
        let value = amountDec * priceDec
        return ReservedValue(denomination: denomination, amount: amount, price: mid,
                             valueUsd: "\(value)", operationId: operationId,
                             sourceArcaPath: sourceArcaPath, destinationArcaPath: destinationArcaPath,
                             startedAt: startedAt, inTransit: inTransit)
    }
}

extension ObjectValuation {
    /// Returns a copy with all price-derived fields recomputed from mid prices.
    /// Static data (amounts, sizes, entry prices, paths) is preserved.
    public func revalued(with mids: [String: String]) -> ObjectValuation {
        // Server-authoritative pricing: trust the server's values verbatim and
        // never recompute from raw mids. Absent/`.client` ⇒ recompute as before.
        if pricingMode == .server { return self }
        if type == "exchange" {
            let newPositions = positions?.map { $0.revalued(with: mids) }
            let cashStr = balances.first?.amount ?? "0"
            let cashDec = Decimal(string: cashStr) ?? 0
            let totalPnl = newPositions?.reduce(Decimal(0)) { sum, pos in
                sum + (Decimal(string: pos.unrealizedPnl ?? "0") ?? 0)
            } ?? 0
            let equity = cashDec + totalPnl
            let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
            let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
            return ObjectValuation(objectId: objectId, path: path, type: type,
                                   denomination: denomination, valueUsd: "\(equity)",
                                   balances: balances, reservedBalances: newReserved,
                                   pendingInbound: newInbound, positions: newPositions,
                                   pricingMode: pricingMode)
        }

        let newBalances = balances.map { $0.revalued(with: mids) }
        let newReserved = reservedBalances?.map { $0.revalued(with: mids) }
        let newInbound = pendingInbound?.map { $0.revalued(with: mids) }
        let objValue = newBalances.reduce(Decimal(0)) { sum, b in
            sum + (Decimal(string: b.valueUsd) ?? 0)
        }
        return ObjectValuation(objectId: objectId, path: path, type: type,
                               denomination: denomination, valueUsd: "\(objValue)",
                               balances: newBalances, reservedBalances: newReserved,
                               pendingInbound: newInbound, positions: positions,
                               pricingMode: pricingMode)
    }
}

extension PathAggregation {
    /// Returns a copy with totals recomputed from ``breakdown`` using mid prices.
    /// Spot rows use `amount × mid`; perp rows recompute mark-to-market P&L.
    /// Exchange rows keep server ``AssetBreakdown/valueUsd``.
    /// ``departingUsd`` and ``arrivingUsd`` are USD-denominated and pass through unchanged.
    public func revalued(with mids: [String: String]) -> PathAggregation {
        // Server-authoritative pricing: totals are trusted as delivered.
        if pricingMode == .server { return self }
        let newBreakdown = breakdown.map { entry -> AssetBreakdown in
            switch entry.category {
            case .spot:
                guard let mid = mids[entry.asset] else { return entry }
                let amountDec = Decimal(string: entry.amount) ?? 0
                let priceDec = Decimal(string: mid) ?? 1
                let value = amountDec * priceDec
                return AssetBreakdown(
                    asset: entry.asset,
                    category: entry.category,
                    amount: entry.amount,
                    price: mid,
                    valueUsd: "\(value)",
                    weightedAvgLeverage: entry.weightedAvgLeverage,
                    avgEntryPrice: entry.avgEntryPrice
                )
            case .perp:
                guard let mid = mids[entry.asset],
                      let newMid = Decimal(string: mid),
                      let oldPrice = entry.price,
                      let oldMid = Decimal(string: oldPrice),
                      oldMid != 0,
                      let avgEntryPrice = entry.avgEntryPrice,
                      let entryPrice = Decimal(string: avgEntryPrice) else {
                    return entry
                }
                let amountDec = Decimal(string: entry.amount) ?? 0
                let currentValue = Decimal(string: entry.valueUsd) ?? 0
                let entryNotional = entryPrice * amountDec
                let netSignedSize = (currentValue + entryNotional) / oldMid
                let newValue = newMid * netSignedSize - entryNotional
                return AssetBreakdown(
                    asset: entry.asset,
                    category: entry.category,
                    amount: entry.amount,
                    price: mid,
                    valueUsd: "\(newValue)",
                    weightedAvgLeverage: entry.weightedAvgLeverage,
                    avgEntryPrice: entry.avgEntryPrice
                )
            case .exchange:
                return entry
            }
        }
        let totalEquity = newBreakdown.reduce(Decimal(0)) { sum, entry in
            sum + (Decimal(string: entry.valueUsd) ?? 0)
        }
        return PathAggregation(
            prefix: prefix,
            totalEquityUsd: "\(totalEquity)",
            departingUsd: departingUsd,
            arrivingUsd: arrivingUsd,
            breakdown: newBreakdown,
            asOf: asOf,
            cumInflowsUsd: cumInflowsUsd,
            cumOutflowsUsd: cumOutflowsUsd,
            pricingMode: pricingMode
        )
    }
}

// MARK: - Aggregation Source

public enum AggregationSourceType: String, Codable, Sendable {
    case prefix
    case pattern
    case paths
    case watch
}

public struct AggregationSource: Codable, Sendable {
    public let type: AggregationSourceType
    public let value: String

    public init(type: AggregationSourceType, value: String) {
        self.type = type
        self.value = value
    }
}

public struct CreateWatchResponse: Codable, Sendable {
    public let watchId: WatchID
    public let aggregation: PathAggregation
}

// MARK: - P&L

public struct ExternalFlowEntry: Codable, Sendable {
    public let operationId: OperationID
    public let type: String
    public let direction: String
    public let amount: String
    public let denomination: String
    public let valueUsd: String
    public let sourceArcaPath: String?
    public let targetArcaPath: String?
    public let timestamp: String
}

public struct PnlResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let startingEquityUsd: String
    public let endingEquityUsd: String
    public let netInflowsUsd: String
    public let netOutflowsUsd: String
    public let pnlUsd: String
    public let externalFlows: [ExternalFlowEntry]?
}

// MARK: - P&L History

public struct PnlPoint: Codable, Sendable {
    public let timestamp: String
    /// Flow-adjusted P&L: external inflows/outflows removed, anchored at
    /// the first point. A deposit does not move this.
    public let pnlUsd: String
    /// Marked account value for this bucket, floored at zero — the same
    /// number `getEquityHistory` returns for the same bucket. Chart this,
    /// not `pnlUsd`, when you want "what is the account worth".
    public let equityUsd: String
    /// True signed value, present only when the zero floor clamped this
    /// point. `pnlUsd` is already derived from it.
    public let unflooredEquityUsd: String?
    public let status: ChartPointStatus?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?
    /// Present when the chart is created with `anchor: .equity`.
    /// Equal to pnlUsd shifted so the live (rightmost) point equals current equity.
    public var valueUsd: String?

    public init(
        timestamp: String,
        pnlUsd: String,
        equityUsd: String,
        unflooredEquityUsd: String? = nil,
        status: ChartPointStatus? = nil,
        cumInflowsUsd: String? = nil,
        cumOutflowsUsd: String? = nil,
        valueUsd: String? = nil
    ) {
        self.timestamp = timestamp
        self.pnlUsd = pnlUsd
        self.equityUsd = equityUsd
        self.unflooredEquityUsd = unflooredEquityUsd
        self.status = status
        self.cumInflowsUsd = cumInflowsUsd
        self.cumOutflowsUsd = cumOutflowsUsd
        self.valueUsd = valueUsd
    }
}

/// Controls the y-axis baseline for P&L charts.
public enum PnlAnchor: Sendable {
    /// Standard P&L chart starting at 0.
    case zero
    /// P&L shifted so the live (rightmost) value equals the current account equity.
    case equity
}

/// Populates `valueUsd` with `equityUsd` for equity-anchored P&L charts.
/// This provides a true historical portfolio value view, rather than a translated P&L curve.
func applyEquityAnchor(to points: inout [PnlPoint]) {
    for i in points.indices {
        points[i].valueUsd = points[i].equityUsd
    }
}

public struct PnlHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    public let resolution: String?
    public let resolutionRequested: String?
    /// Bucket width of `resolution`, in seconds.
    public let bucketSeconds: Int?
    public let serverNow: String?
    public let startingEquityUsd: String
    public let pnlPoints: [PnlPoint]
    public let externalFlows: [ExternalFlowEntry]?
    public let midPrices: [String: String]?

    public init(
        prefix: String,
        from: String,
        to: String,
        points: Int,
        resolution: String? = nil,
        resolutionRequested: String? = nil,
        bucketSeconds: Int? = nil,
        serverNow: String? = nil,
        startingEquityUsd: String,
        pnlPoints: [PnlPoint],
        externalFlows: [ExternalFlowEntry]? = nil,
        midPrices: [String: String]? = nil
    ) {
        self.prefix = prefix
        self.from = from
        self.to = to
        self.points = points
        self.resolution = resolution
        self.resolutionRequested = resolutionRequested
        self.bucketSeconds = bucketSeconds
        self.serverNow = serverNow
        self.startingEquityUsd = startingEquityUsd
        self.pnlPoints = pnlPoints
        self.externalFlows = externalFlows
        self.midPrices = midPrices
    }
}

// MARK: - Equity History

/// Provenance of a bucket's CASH side. Not a marked/unmarked flag:
/// every bucket is marked to that bucket's own mids, so a `.carried`
/// point still changes value as the market moves. `.incomplete` means an
/// input was missing (no mid for a market, or the position overlay could
/// not run).
public enum ChartPointStatus: String, Codable, Sendable {
    case open
    case sealed
    case carried
    case incomplete
}

public struct EquityPoint: Codable, Sendable {
    public let timestamp: String
    /// Marked account value for this bucket: cash valued at the bucket's
    /// own mids, plus unrealized P&L on every position open at that
    /// bucket, valued at the same mids. Floored at zero — an exchange
    /// account is the one class permitted to hold a negative balance,
    /// and a balance that renders negative is worse than one that
    /// renders as zero.
    public let equityUsd: String
    /// True signed value, present ONLY when the zero floor clamped this
    /// point — so its presence is also how you tell a floored point from
    /// a genuinely-zero one. The floor never destroys the number; use
    /// this to reconstruct the real change.
    public let unflooredEquityUsd: String?
    public let status: ChartPointStatus?
    public let cumInflowsUsd: String?
    public let cumOutflowsUsd: String?

    public init(
        timestamp: String,
        equityUsd: String,
        unflooredEquityUsd: String? = nil,
        status: ChartPointStatus? = nil,
        cumInflowsUsd: String? = nil,
        cumOutflowsUsd: String? = nil
    ) {
        self.timestamp = timestamp
        self.equityUsd = equityUsd
        self.unflooredEquityUsd = unflooredEquityUsd
        self.status = status
        self.cumInflowsUsd = cumInflowsUsd
        self.cumOutflowsUsd = cumOutflowsUsd
    }
}

public struct EquityHistoryResponse: Codable, Sendable {
    public let prefix: String
    public let from: String
    public let to: String
    public let points: Int
    /// Ladder rung actually served. The ladder picks the finest rung
    /// whose bucket count fits the requested `points`, so a 24h window at
    /// `points: 180` is served at `15m` (~96 points). Compare two series
    /// by window and `resolution`, never by array length.
    public let resolution: String?
    /// Set only when the requested rung lacked coverage and the server
    /// promoted to a coarser one.
    public let resolutionRequested: String?
    /// Bucket width of `resolution`, in seconds.
    public let bucketSeconds: Int?
    public let serverNow: String?
    public let equityPoints: [EquityPoint]

    public init(
        prefix: String,
        from: String,
        to: String,
        points: Int,
        resolution: String? = nil,
        resolutionRequested: String? = nil,
        bucketSeconds: Int? = nil,
        serverNow: String? = nil,
        equityPoints: [EquityPoint]
    ) {
        self.prefix = prefix
        self.from = from
        self.to = to
        self.points = points
        self.resolution = resolution
        self.resolutionRequested = resolutionRequested
        self.bucketSeconds = bucketSeconds
        self.serverNow = serverNow
        self.equityPoints = equityPoints
    }
}

/// Emitted by `EquityChartStream` on each update.
/// Contains the full point array (historical + live tail).
public struct EquityChartUpdate: Sendable {
    public let points: [EquityPoint]
}

/// Emitted by `PnlChartStream` on each update.
/// Contains the full P&L point array (historical + live tail) and all flows.
public struct PnlChartUpdate: Sendable {
    public let points: [PnlPoint]
    public let externalFlows: [ExternalFlowEntry]
}

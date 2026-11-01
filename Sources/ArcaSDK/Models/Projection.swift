import Foundation

// MARK: - Projections

/// A registered per-realm projection: a named field-filter over the
/// canonical ``ObjectValuation`` shape plus the path patterns defining
/// which objects it covers. Managed via `arca:ManageProjection`; read via
/// `arca:ReadProjection` grants on the projection NAME.
public struct RealmProjection: Codable, Sendable {
    public let realmId: String
    public let name: String
    /// Projectable fields: `equity`, `realizedValue`, `unrealizedValue`,
    /// `positions`, and the windowed figures `pnl` and `volume` (served only
    /// to a read or watch that asks for a window).
    public let fields: [String]
    /// Path patterns (exact path, `"*"`, or trailing `"/prefix/*"`).
    public let resources: [String]
    public let createdAt: String
    public let updatedAt: String

    public init(
        realmId: String,
        name: String,
        fields: [String],
        resources: [String],
        createdAt: String,
        updatedAt: String
    ) {
        self.realmId = realmId
        self.name = name
        self.fields = fields
        self.resources = resources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A rolling window a projection read or watch can ask for.
public enum ProjectionWindow: String, Sendable {
    case thirtyDays = "30d"
}

/// Readiness of one windowed figure.
public enum WindowedStatus: String, Sendable {
    /// The value covers the whole window.
    case complete
    /// P&L only: a mark was missing at `from` or now, so the value is off
    /// by that position's move.
    case incomplete
    /// Not computed yet. The value is absent, so it never reads as zero.
    case pending
}

/// An account's P&L over `(from, asOf]`: `A(asOf) - A(from)`, where
/// `A(t) = equity(t) - cumInflows(t) + cumOutflows(t)`. Deposits,
/// withdrawals and transfers are flows and never count; realized and
/// unrealized gains, fees, funding and liquidations do. Equals
/// `getPnlHistory`'s P&L for the same `from`. Rank or sum rows only when
/// their `from` matches.
public struct ProjectedPnl: Codable, Sendable, Equatable {
    public let window: String
    /// Window start (an hour boundary), RFC 3339.
    public let from: String
    /// When the value was computed. Absent while pending.
    public let asOf: String?
    /// `"full"`, or `"since_creation"` for an account younger than the window.
    public let coverage: String?
    /// The account's first point, set with `coverage == "since_creation"`.
    public let coveredFrom: String?
    /// `"complete"`, `"incomplete"` or `"pending"`; see ``windowedStatus``.
    public let status: String
    /// Exact decimal USD. Absent while pending.
    public let pnlUsd: String?

    /// ``status`` as a known value; nil for one a newer server added.
    public var windowedStatus: WindowedStatus? { WindowedStatus(rawValue: status) }

    public init(window: String, from: String, asOf: String? = nil, coverage: String? = nil,
                coveredFrom: String? = nil, status: String, pnlUsd: String? = nil) {
        self.window = window
        self.from = from
        self.asOf = asOf
        self.coverage = coverage
        self.coveredFrom = coveredFrom
        self.status = status
        self.pnlUsd = pnlUsd
    }

    func shifted(by shift: Decimal) -> ProjectedPnl {
        guard windowedStatus != .pending, let pnlUsd, let value = Decimal(string: pnlUsd) else { return self }
        return ProjectedPnl(window: window, from: from, asOf: asOf, coverage: coverage,
                            coveredFrom: coveredFrom, status: status, pnlUsd: "\(value + shift)")
    }
}

/// An account's traded volume over `(from, asOf]`: the exact sum of
/// `|fill size × fill price|` over its fill records booked in the window,
/// liquidations and partial fills included, each fill counted once.
/// Deposits, transfers, fees, funding and unfilled orders never count, and
/// a price move never changes it.
public struct ProjectedVolume: Codable, Sendable, Equatable {
    public let window: String
    /// Window start (an hour boundary), RFC 3339.
    public let from: String
    /// The ledger read the sum is true at. Absent while pending.
    public let asOf: String?
    public let coverage: String?
    public let coveredFrom: String?
    /// `"complete"` or `"pending"`; see ``windowedStatus``.
    public let status: String
    /// Exact decimal USD. Absent while pending.
    public let volumeUsd: String?

    /// ``status`` as a known value; nil for one a newer server added.
    public var windowedStatus: WindowedStatus? { WindowedStatus(rawValue: status) }

    public init(window: String, from: String, asOf: String? = nil, coverage: String? = nil,
                coveredFrom: String? = nil, status: String, volumeUsd: String? = nil) {
        self.window = window
        self.from = from
        self.asOf = asOf
        self.coverage = coverage
        self.coveredFrom = coveredFrom
        self.status = status
        self.volumeUsd = volumeUsd
    }
}

/// The projection-filtered view of an ``ObjectValuation`` delivered to
/// `arca:ReadProjection` readers. Identity fields are always present;
/// everything else appears only when the projection's registered field set
/// includes it. Balances, reserved balances, and pending inbound are never
/// projectable.
///
/// Decoding is lenient past the identity fields: a field this SDK cannot
/// read is left nil rather than failing the row.
public struct ProjectedValuation: Codable, Sendable {
    public let objectId: ObjectID
    public let path: String
    public let type: String
    /// Mirrors ``ObjectValuation``'s mids completeness: present (as `false`)
    /// only when a position's mid price was missing, so the price-derived
    /// fields understate reality.
    public let midsComplete: Bool?
    /// Pricing mode hint for client-side re-marking against the mids feed.
    public let pricingMode: PricingMode?
    /// Total equity in USD (projection field `equity`).
    public let equity: String?
    /// Realized/cash component (projection field `realizedValue`).
    public let realizedValue: String?
    /// Unrealized P&L (projection field `unrealizedValue`).
    public let unrealizedValue: String?
    /// Open positions (projection field `positions`).
    public let positions: [PositionValue]?
    /// P&L over the rolling window (projection field `pnl`), present when
    /// the read or watch asked for a window. Re-marked with `equity`.
    public let pnl: ProjectedPnl?
    /// Traded volume over the rolling window (projection field `volume`),
    /// present when the read or watch asked for a window. Never re-marked.
    public let volume: ProjectedVolume?

    public init(
        objectId: ObjectID,
        path: String,
        type: String,
        midsComplete: Bool? = nil,
        pricingMode: PricingMode? = nil,
        equity: String? = nil,
        realizedValue: String? = nil,
        unrealizedValue: String? = nil,
        positions: [PositionValue]? = nil,
        pnl: ProjectedPnl? = nil,
        volume: ProjectedVolume? = nil
    ) {
        self.objectId = objectId
        self.path = path
        self.type = type
        self.midsComplete = midsComplete
        self.pricingMode = pricingMode
        self.equity = equity
        self.realizedValue = realizedValue
        self.unrealizedValue = unrealizedValue
        self.positions = positions
        self.pnl = pnl
        self.volume = volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectId = try c.decode(ObjectID.self, forKey: .objectId)
        path = try c.decode(String.self, forKey: .path)
        type = try c.decode(String.self, forKey: .type)
        midsComplete = try? c.decodeIfPresent(Bool.self, forKey: .midsComplete)
        pricingMode = try? c.decodeIfPresent(PricingMode.self, forKey: .pricingMode)
        equity = try? c.decodeIfPresent(String.self, forKey: .equity)
        realizedValue = try? c.decodeIfPresent(String.self, forKey: .realizedValue)
        unrealizedValue = try? c.decodeIfPresent(String.self, forKey: .unrealizedValue)
        positions = try? c.decodeIfPresent([PositionValue].self, forKey: .positions)
        pnl = try? c.decodeIfPresent(ProjectedPnl.self, forKey: .pnl)
        volume = try? c.decodeIfPresent(ProjectedVolume.self, forKey: .volume)
    }
}

/// Decodes a value without failing its container: a value that does not
/// decode is nil. Projection rows decode one by one through this, so one
/// row this SDK cannot read never empties a snapshot or a frame.
struct LenientDecoded<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension ProjectedValuation {
    /// Decodes a JSON array of rows, skipping rows that do not decode.
    static func decodeRows(_ data: Data) -> [ProjectedValuation] {
        ((try? JSONDecoder().decode([LenientDecoded<ProjectedValuation>].self, from: data)) ?? []).compactMap(\.value)
    }
}

/// One page of the batched projection read, keyset-paginated by path.
public struct ProjectionValuationsPage: Codable, Sendable {
    public let projection: String
    public let fields: [String]
    /// The window the rows' `pnl` / `volume` figures cover, when one was asked for.
    public let window: String?
    public let valuations: [ProjectedValuation]
    /// Set when more pages remain; pass it back verbatim as `cursor`.
    public let cursor: String?

    public init(projection: String, fields: [String], valuations: [ProjectedValuation], cursor: String? = nil, window: String? = nil) {
        self.projection = projection
        self.fields = fields
        self.window = window
        self.valuations = valuations
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projection = try c.decode(String.self, forKey: .projection)
        fields = try c.decode([String].self, forKey: .fields)
        window = try? c.decodeIfPresent(String.self, forKey: .window)
        valuations = (try c.decodeIfPresent([LenientDecoded<ProjectedValuation>].self, forKey: .valuations) ?? []).compactMap(\.value)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

// MARK: - Client-Side Revaluation

extension ProjectedValuation {
    /// Returns a copy re-marked at the given mids, in exact decimals.
    ///
    /// One rule covers every price-derived figure: `equity`,
    /// `unrealizedValue` and the windowed `pnl` each shift by the change in
    /// position P&L from the delivered row to the new mids. Everything else
    /// the server put in them (cash, unsettled funding, the P&L baseline)
    /// is kept as delivered. `volume` is never re-marked.
    ///
    /// Rows the server prices (`pricingMode == .server`), rows without
    /// positions, and positions without a mid pass through unchanged.
    /// Always re-mark the row as delivered, never an already re-marked one.
    public func revalued(with mids: [String: String]) -> ProjectedValuation {
        if pricingMode == .server { return self }
        guard let positions, !positions.isEmpty else { return self }

        var shift = Decimal(0)
        var moved = false
        var allMarked = true
        let newPositions = positions.map { p -> PositionValue in
            guard let (position, delta) = p.remarked(with: mids) else {
                if p.markPrice == nil { allMarked = false }
                return p
            }
            moved = true
            shift += delta
            return position
        }
        guard moved else { return self }

        func shifted(_ raw: String?) -> String? {
            guard let raw, let value = Decimal(string: raw) else { return raw }
            return "\(value + shift)"
        }
        return ProjectedValuation(
            objectId: objectId,
            path: path,
            type: type,
            midsComplete: midsComplete == false && allMarked ? nil : midsComplete,
            pricingMode: pricingMode,
            equity: shifted(equity),
            realizedValue: realizedValue,
            unrealizedValue: shifted(unrealizedValue),
            positions: newPositions,
            pnl: pnl?.shifted(by: shift),
            volume: volume
        )
    }
}

extension PositionValue {
    /// Re-marks a projected position at a new mid: the position and the
    /// change in its P&L from the delivered row, or nil when the mid or
    /// the position's numbers are unusable. The change is measured from
    /// the delivered mark; a position the server could not mark was left
    /// out of its row's figures, so its whole P&L is the change.
    func remarked(with mids: [String: String]) -> (PositionValue, Decimal)? {
        guard let mid = mids[market], let midDec = Decimal(string: mid),
              let sizeDec = Decimal(string: size) else { return nil }
        let magnitude = sizeDec < 0 ? -sizeDec : sizeDec
        let signedSize: Decimal = side == "short" ? -magnitude : (side == "long" ? magnitude : sizeDec)
        let delivered = unrealizedPnl.flatMap { Decimal(string: $0) }
        let pnl: Decimal
        let shift: Decimal
        if let markPrice, let markDec = Decimal(string: markPrice), let delivered {
            shift = signedSize * (midDec - markDec)
            pnl = delivered + shift
        } else {
            guard let entryDec = Decimal(string: entryPrice) else { return nil }
            pnl = signedSize * (midDec - entryDec)
            shift = pnl - (delivered ?? 0)
        }
        return (PositionValue(market: market, side: side, size: size, entryPrice: entryPrice,
                              markPrice: mid, unrealizedPnl: "\(pnl)", valueUsd: "\(pnl)"), shift)
    }
}

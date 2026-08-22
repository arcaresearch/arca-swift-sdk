import Foundation

// MARK: - Projections

/// A registered per-realm projection: a named field-filter over the
/// canonical ``ObjectValuation`` shape plus the path patterns defining
/// which objects it covers. Managed via `arca:ManageProjection`; read via
/// `arca:ReadProjection` grants on the projection NAME.
public struct RealmProjection: Codable, Sendable {
    public let realmId: String
    public let name: String
    /// Projectable fields: `equity`, `realizedValue`, `unrealizedValue`, `positions`.
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

/// The projection-filtered view of an ``ObjectValuation`` delivered to
/// `arca:ReadProjection` readers. Identity fields are always present;
/// everything else appears only when the projection's registered field set
/// includes it. Balances, reserved balances, and pending inbound are never
/// projectable.
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

    public init(
        objectId: ObjectID,
        path: String,
        type: String,
        midsComplete: Bool? = nil,
        pricingMode: PricingMode? = nil,
        equity: String? = nil,
        realizedValue: String? = nil,
        unrealizedValue: String? = nil,
        positions: [PositionValue]? = nil
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
    }
}

/// One page of the batched projection read, keyset-paginated by path.
public struct ProjectionValuationsPage: Codable, Sendable {
    public let projection: String
    public let fields: [String]
    public let valuations: [ProjectedValuation]
    /// Set when more pages remain; pass it back verbatim as `cursor`.
    public let cursor: String?

    public init(projection: String, fields: [String], valuations: [ProjectedValuation], cursor: String? = nil) {
        self.projection = projection
        self.fields = fields
        self.valuations = valuations
        self.cursor = cursor
    }
}

// MARK: - Client-Side Revaluation

extension ProjectedValuation {
    /// Returns a copy with price-derived fields recomputed from current mid
    /// prices: each position is re-marked, `unrealizedValue` (when projected)
    /// is replaced by the fresh P&L sum, and `equity` (when projected) is
    /// rebuilt as `realizedValue + newPnl` when the realized component is
    /// available, else shifted by the P&L delta. Rows without positions pass
    /// through unchanged.
    public func revalued(with mids: [String: String]) -> ProjectedValuation {
        // Server-authoritative pricing: trust the delivered values verbatim.
        if pricingMode == .server { return self }
        guard let positions, !positions.isEmpty else { return self }

        let newPositions = positions.map { $0.revalued(with: mids) }
        let oldPnl = positions.reduce(Decimal(0)) { sum, p in
            sum + (Decimal(string: p.unrealizedPnl ?? "0") ?? 0)
        }
        let newPnl = newPositions.reduce(Decimal(0)) { sum, p in
            sum + (Decimal(string: p.unrealizedPnl ?? "0") ?? 0)
        }

        var newUnrealized = unrealizedValue
        if unrealizedValue != nil {
            newUnrealized = "\(newPnl)"
        }
        var newEquity = equity
        if let equity {
            if let realizedValue, let realizedDec = Decimal(string: realizedValue) {
                newEquity = "\(realizedDec + newPnl)"
            } else {
                let equityDec = Decimal(string: equity) ?? 0
                newEquity = "\(equityDec + (newPnl - oldPnl))"
            }
        }

        return ProjectedValuation(
            objectId: objectId,
            path: path,
            type: type,
            midsComplete: midsComplete,
            pricingMode: pricingMode,
            equity: newEquity,
            realizedValue: realizedValue,
            unrealizedValue: newUnrealized,
            positions: newPositions
        )
    }
}

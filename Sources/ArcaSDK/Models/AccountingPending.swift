import Foundation

/// One venue-confirmed execution that the ledger has not fully recorded into
/// the ``ExchangeState`` that carries it.
///
/// The platform confirms an order's execution (the receipt) before its ledger
/// folds the fills into the account, and it folds them one fill at a time.
/// Every observation in between is a real but intermediate account: the old
/// position, a partly projected one, cash debited before margin is released.
/// Rather than make each reader guess whether an observation is "after" an
/// execution it knows about, the observation says so itself: this entry names
/// the execution and exactly how much of it — `unaccountedSize`, executed
/// minus accounted — is still missing from `positions`. Adding that signed
/// quantity to the market's position yields the same book on the frame emitted
/// at execution time, on every per-fill frame, and on the settled frame.
///
/// Positions, side and quantity are exact from the venue and may be composed
/// immediately. Realized P&L, fees and therefore equity are ledger facts; keep
/// the previous money until ``ExchangeState/isAccountingSettled`` is true.
public struct AccountingPendingExecution: Codable, Sendable, Equatable {
    public let operationId: String
    /// The venue order id, `nil` before acknowledgement is recorded.
    public let orderId: String?
    public let market: String
    /// `"buy"` or `"sell"`: a buy adds `unaccountedSize` to the market's signed
    /// position, a sell subtracts it.
    public let side: String
    public let executedSize: String
    public let accountedSize: String
    public let unaccountedSize: String
    /// True once the venue has finished with the order; false for a working
    /// order whose fills so far are reported here.
    public let executionFinal: Bool
    /// The venue's provisional aggregate price when known, so a position this
    /// execution opens can show the price it executed at.
    public let averagePrice: String?

    public init(operationId: String, orderId: String? = nil, market: String, side: String,
                executedSize: String, accountedSize: String, unaccountedSize: String,
                executionFinal: Bool, averagePrice: String? = nil) {
        self.operationId = operationId; self.orderId = orderId; self.market = market; self.side = side
        self.executedSize = executedSize; self.accountedSize = accountedSize; self.unaccountedSize = unaccountedSize
        self.executionFinal = executionFinal; self.averagePrice = averagePrice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decode(String.self, forKey: .operationId)
        orderId = try c.decodeIfPresent(String.self, forKey: .orderId)
        market = try c.decode(String.self, forKey: .market)
        side = try c.decode(String.self, forKey: .side)
        executedSize = try c.decodeIfPresent(String.self, forKey: .executedSize) ?? "0"
        accountedSize = try c.decodeIfPresent(String.self, forKey: .accountedSize) ?? "0"
        unaccountedSize = try c.decode(String.self, forKey: .unaccountedSize)
        executionFinal = try c.decodeIfPresent(Bool.self, forKey: .executionFinal) ?? false
        averagePrice = try c.decodeIfPresent(String.self, forKey: .averagePrice)
    }

    /// The quantity this entry adds to its market's signed position (long
    /// positive, short negative), or `nil` for an entry that cannot be
    /// composed — which a reader treats as "leave this market's ledger row".
    public var signedUnaccounted: Decimal? {
        guard let size = Self.decimal(unaccountedSize), size >= 0 else { return nil }
        switch side.lowercased() {
        case "buy", "long": return size
        case "sell", "short": return -size
        default: return nil
        }
    }

    static func decimal(_ raw: String?) -> Decimal? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              raw.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
}

/// Where a ``ProjectedPosition``'s quantity came from.
public enum ProjectedPositionSource: String, Sendable {
    /// No pending execution touches this market; the row is the ledger
    /// position verbatim.
    case ledger
    /// At least one pending execution was composed onto the ledger position
    /// (or onto a flat market). Quantity and side are exact; money on
    /// ``ProjectedPosition/ledger``, if any, describes the pre-execution row.
    case execution
}

/// One market of the composed book: the ledger position with every pending
/// execution for that market applied.
public struct ProjectedPosition: Sendable, Equatable {
    public let market: String
    public let side: PositionSide
    /// The unsigned composed quantity.
    public let size: Decimal
    /// The ledger entry for an unchanged or reduced position, the
    /// quantity-weighted blend for an increase whose executions carried an
    /// average price, the execution's average price for a position the pending
    /// executions opened or reversed, and `nil` when it cannot be known.
    public let entryPrice: Decimal?
    public let source: ProjectedPositionSource
    /// The observation's own row for this market, `nil` when the market was
    /// flat on the ledger.
    public let ledger: SimPosition?
    /// The executions composed onto this market.
    public let pending: [AccountingPendingExecution]

    public static func == (lhs: ProjectedPosition, rhs: ProjectedPosition) -> Bool {
        lhs.market == rhs.market && lhs.side == rhs.side && lhs.size == rhs.size && lhs.entryPrice == rhs.entryPrice &&
            lhs.source == rhs.source && lhs.ledger?.id == rhs.ledger?.id && lhs.ledger?.size == rhs.ledger?.size && lhs.pending == rhs.pending
    }
}

extension ExchangeState {
    /// Whether this observation's positions and money include every execution
    /// the platform knows about. While false, show ``projectedPositions()``
    /// and keep the previously settled balances.
    public var isAccountingSettled: Bool { accountingPending?.isEmpty ?? true }

    /// `positions` composed with `accountingPending`: the book as it will read
    /// once the ledger has recorded everything the venue has already executed.
    /// Markets that compose to zero are omitted. Ledger positions keep their
    /// order, followed by positions the pending executions opened, in market
    /// order. A market whose pending entries cannot be parsed is returned as
    /// its ledger row with source `.ledger`, so a malformed entry can never
    /// invent or erase a position.
    public func projectedPositions() -> [ProjectedPosition] {
        var pendingByMarket: [String: [AccountingPendingExecution]] = [:]
        for entry in accountingPending ?? [] { pendingByMarket[entry.market, default: []].append(entry) }
        var out: [ProjectedPosition] = []
        var seen = Set<String>()
        for position in positions {
            seen.insert(position.market)
            let ledgerRow = ProjectedPosition(market: position.market, side: position.side,
                size: AccountingPendingExecution.decimal(position.size).map { abs($0) } ?? 0,
                entryPrice: AccountingPendingExecution.decimal(position.entryPrice), source: .ledger, ledger: position, pending: [])
            guard let pending = pendingByMarket[position.market] else { out.append(ledgerRow); continue }
            switch Self.compose(ledger: position, pending: pending) {
            case .failure: out.append(ledgerRow)
            case .flat: break
            case .position(let row): out.append(row)
            }
        }
        for market in pendingByMarket.keys.sorted() where !seen.contains(market) {
            if case .position(let row) = Self.compose(ledger: nil, pending: pendingByMarket[market]!) { out.append(row) }
        }
        return out
    }

    private enum Composition { case failure, flat, position(ProjectedPosition) }

    private static func compose(ledger: SimPosition?, pending: [AccountingPendingExecution]) -> Composition {
        var signed: Decimal = 0
        var entry: Decimal?
        var market = ledger?.market ?? ""
        if let ledger {
            guard let size = AccountingPendingExecution.decimal(ledger.size) else { return .failure }
            signed = ledger.side == .short ? -size : size
            if let px = AccountingPendingExecution.decimal(ledger.entryPrice), px > 0 { entry = px }
        }
        for execution in pending {
            guard let delta = execution.signedUnaccounted else { return .failure }
            if market.isEmpty { market = execution.market }
            entry = blendedEntry(held: signed, entry: entry, delta: delta, averagePrice: execution.averagePrice)
            signed += delta
        }
        if signed == 0 { return .flat }
        return .position(ProjectedPosition(market: market, side: signed > 0 ? .long : .short, size: abs(signed),
            entryPrice: entry, source: .execution, ledger: ledger, pending: pending))
    }

    /// The entry price after applying `delta` to `held` at `entry`: unchanged
    /// for a same-side reduction, quantity-weighted for an increase with a
    /// known execution price, the execution price for an open or the far side
    /// of a reversal, and `nil` when it cannot be derived.
    private static func blendedEntry(held: Decimal, entry: Decimal?, delta: Decimal, averagePrice: String?) -> Decimal? {
        let price = AccountingPendingExecution.decimal(averagePrice).flatMap { $0 > 0 ? $0 : nil }
        let next = held + delta
        if held == 0 || next == 0 || (held > 0) != (next > 0) { return price }
        if (delta > 0) != (held > 0) { return entry }
        guard let entry, let price else { return nil }
        let heldAbs = abs(held), deltaAbs = abs(delta)
        return (heldAbs * entry + deltaAbs * price) / (heldAbs + deltaAbs)
    }
}

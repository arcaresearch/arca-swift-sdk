import Foundation

/// Display facts only. A projected row deliberately has no authoritative position,
/// entry price, fees, P&L, margin, collateral or trading-eligibility fields.
public struct VisiblePosition: Sendable {
    public let market: String
    public let signedSize: String
    public let source: String // authoritative | baseline | execution
    public let authoritativePosition: SimPosition?
}

/// Cumulative execution coverage, including operations that removed the row.
public struct PositionExecutionCoverage: Sendable {
    public let operationId: String
    public let orderId: String
    public let market: String
    public let filledSize: String
    public let status: String // execution | accounted | unavailable
}

public struct PositionViewSnapshot: Sendable {
    public let positions: [VisiblePosition]
    public let coverage: [PositionExecutionCoverage]
    /// Includes confirmed full closes, which have no visible row.
    public let pendingMarkets: [String]
    /// Evidence was insufficient; absence of a row here does NOT mean flat.
    public let unavailableMarkets: [String]
}

/// A pre-submission baseline reservation. Retain it across transport retries;
/// bind it to exactly one logical operation. Never create one after submitting.
public final class PositionUpdate: @unchecked Sendable {
    let id = UUID()
    let view: PositionView
    public let market: String
    public let side: OrderSide
    init(view: PositionView, market: String, side: OrderSide) {
        self.view = view; self.market = market; self.side = side
    }
    /// Only when no order was dispatched (or the backend proves it never was).
    public func cancelBeforeSubmission() { view.cancel(self) }
    /// Display attachment failed after dispatch: preserve the order outcome, mark its display unknown.
    public func invalidate() { view.invalidate(market: market) }
}

/// One shared, account-scoped display view per Arca instance. All access and
/// notifications are serialized. `ExchangeState` remains financial authority.
public final class PositionView: @unchecked Sendable {
    public let objectId: String
    public let current = SendableBox(PositionViewSnapshot(positions: [], coverage: [], pendingMarkets: [], unavailableMarkets: []))
    private let lock = NSRecursiveLock()
    private var state: ExchangeState?
    private var asOf: String?
    private var revision: UInt64 = 0
    private var closed = false
    private struct Entry {
        let id: UUID
        let market: String
        let side: OrderSide
        let baselineAsOf: String
        var operationId: String?
        var orderId: String?
        var quantity = Decimal.zero
        var received = false
        var accounted = false
    }
    private var entries: [UUID: Entry] = [:]
    private var baselines: [String: Decimal] = [:]
    private var unavailable = Set<String>()
    private var completed: [PositionExecutionCoverage] = []
    private var reconciliationInFlight = false
    private var observedFills: [(String, String?, String?)] = []
    private let read: @Sendable () async throws -> ExchangeState

    init(objectId: String, read: @escaping @Sendable () async throws -> ExchangeState) {
        self.objectId = objectId; self.read = read
    }

    /// Capture BEFORE calling a backend mutation. Requires a coherent, dated
    /// account observation; an old/unsupported snapshot is not a safe baseline.
    public func begin(market: String, side: OrderSide) throws -> PositionUpdate {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !market.isEmpty, let state, asOf != nil,
              state.tradingAllocation?.remainingValidity().map({ $0 > 0 }) != false,
              entries.count < 128, !ambiguousMarkets().contains(market) else { throw Self.error("POSITION_BASELINE_UNAVAILABLE") }
        if baselines[market] == nil {
            guard let size = Self.size(state, market) else { throw Self.error("POSITION_BASELINE_UNAVAILABLE") }
            baselines[market] = size
        }
        let token = PositionUpdate(view: self, market: market, side: side)
        entries[token.id] = Entry(id: token.id, market: market, side: side, baselineAsOf: asOf!)
        revision &+= 1; publish()
        return token
    }

    func bind(_ token: PositionUpdate, operation: Operation, objectId: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard objectId == self.objectId, var entry = entries[token.id],
              operation.type == .order,
              let created = Self.timestamp(operation.createdAt), created >= entry.baselineAsOf,
              let data = operation.input?.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["exchangeObjectId"] as? String == objectId,
              input["market"] as? String == token.market,
              input["side"] as? String == token.side.rawValue,
              entry.operationId == nil || entry.operationId == operation.id.rawValue,
              !completed.contains(where: { $0.operationId == operation.id.rawValue }),
              !entries.values.contains(where: { $0.id != token.id && $0.operationId == operation.id.rawValue })
        else { throw Self.error("POSITION_UPDATE_IDENTITY_MISMATCH") }
        entry.operationId = operation.id.rawValue
        entries[token.id] = entry
        revision &+= 1; publish()
    }

    func receive(_ token: PositionUpdate, receipt: OrderExecutionReceipt) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, var entry = entries[token.id], receipt.objectId == objectId,
              entry.operationId == receipt.operationId,
              entry.orderId == nil || entry.orderId == receipt.orderId,
              !receipt.orderId.isEmpty,
              ["FILLED", "CANCELLED", "CANCELED", "EXPIRED", "FAILED", "REJECTED"].contains(receipt.status.uppercased()),
              let quantity = Self.decimal(receipt.filledSize), quantity >= entry.quantity else { return }
        if entry.received && quantity == entry.quantity { return }
        entry.orderId = receipt.orderId; entry.quantity = quantity; entry.received = true; entry.accounted = false
        entries[token.id] = entry
        revision &+= 1; publish()
    }

    func accounted(_ token: PositionUpdate, detail: SimOrderWithFills? = nil) async {
        let ticket = markAccounted(token, detail: detail)
        guard let ticket else { return }
        // One read after ALL overlapping operations are accounted. Existing
        // accounted() owns push/reconnect/backoff; no new polling loop here.
        await recover(ticket: ticket)
    }

    private func markAccounted(_ token: PositionUpdate, detail: SimOrderWithFills?) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, var entry = entries[token.id], entry.received else { return nil }
        if let detail, detail.order.id.rawValue != entry.orderId || Self.decimal(detail.order.filledSize) != entry.quantity { return nil }
        if !entry.accounted { entry.accounted = true; entries[token.id] = entry; revision &+= 1 }
        guard entries.values.allSatisfy(\.accounted), !reconciliationInFlight else { return nil }
        reconciliationInFlight = true
        return revision
    }

    func reconcile(_ fresh: ExchangeState, ticket: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, revision == ticket, entries.values.allSatisfy(\.accounted),
              let stamp = Self.timestamp(fresh), asOf.map({ stamp >= $0 }) ?? true else { return }
        completed += coverage(status: "accounted")
        completed = Array(completed.suffix(128))
        entries.removeAll(); baselines.removeAll(); unavailable.removeAll(); observedFills.removeAll()
        state = fresh; asOf = stamp; revision &+= 1; publish()
    }

    func observe(_ fresh: ExchangeState) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let stamp = Self.timestamp(fresh)
        // Once a dated state is known, undated/older pushes cannot resurrect a
        // position. Mid-price revaluations retain the same observation stamp.
        if let previous = asOf, stamp.map({ $0 >= previous }) != true { return }
        let changed = stamp != asOf
        state = fresh; asOf = stamp; publish()
        if changed && !entries.isEmpty && entries.values.allSatisfy(\.accounted) && !reconciliationInFlight {
            reconciliationInFlight = true
            let ticket = revision
            Task { [weak self] in
                guard let self else { return }
                await self.recover(ticket: ticket)
            }
        }
    }

    func invalidate(market: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let market { if baselines[market] != nil { unavailable.insert(market) } }
        else { unavailable.formUnion(baselines.keys) }
        publish()
    }

    func observeFill(market: String, operationId: String?, orderId: String?, recordedAt: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard baselines[market] != nil else { return }
        if let committed = Self.timestamp(recordedAt), let baseline = entries.values.filter({ $0.market == market }).map(\.baselineAsOf).min(), committed <= baseline { return }
        if observedFills.contains(where: { $0.0 == market && $0.1 == operationId && $0.2 == orderId }) { return }
        if observedFills.count >= 256 { unavailable.formUnion(baselines.keys) }
        else { observedFills.append((market, operationId, orderId)) }
        publish()
    }

    private func recover(ticket: UInt64) async {
        var next: UInt64? = ticket
        while let current = next {
            if Task.isCancelled { cancelReconciliation(); return }
            if let fresh = try? await read() { reconcile(fresh, ticket: current) }
            next = finishReconciliation(ticket: current)
        }
    }

    private func cancelReconciliation() {
        lock.lock(); defer { lock.unlock() }; reconciliationInFlight = false
    }

    private func finishReconciliation(ticket: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        reconciliationInFlight = false
        guard !closed, !entries.isEmpty, revision != ticket, entries.values.allSatisfy(\.accounted) else { return nil }
        reconciliationInFlight = true
        return revision
    }

    private func ambiguousMarkets() -> Set<String> {
        var result = unavailable
        for (market, operation, order) in observedFills {
            let local = entries.values.filter { $0.market == market }
            let matched = local.contains { (operation != nil && $0.operationId == operation) || (order != nil && $0.orderId == order) }
            // Unknown identity is unavailable until a delayed attachment resolves it.
            if !matched { result.insert(market) }
        }
        // A snapshot outside the range of any partial accounting of known
        // local executions proves the baseline is incomplete (for example an
        // external fill whose push was missed). Never add local fills to it.
        for (market, baseline) in baselines {
            let local = entries.values.filter { $0.market == market }
            guard local.allSatisfy(\.received), let state else { continue }
            var low = baseline, high = baseline
            var valid = true
            for entry in local {
                if entry.side == .buy { if let n = Self.add(high, entry.quantity) { high = n } else { valid = false } }
                else { if let n = Self.add(low, -entry.quantity) { low = n } else { valid = false } }
            }
            if !valid || Self.size(state, market).map({ $0 >= low && $0 <= high }) != true { result.insert(market) }
        }
        return result
    }

    private func coverage(status: String? = nil) -> [PositionExecutionCoverage] {
        let ambiguous = ambiguousMarkets()
        return entries.values.compactMap { entry in
            guard entry.received, let op = entry.operationId, let order = entry.orderId else { return nil }
            return PositionExecutionCoverage(operationId: op, orderId: order, market: entry.market,
                filledSize: Self.text(entry.quantity), status: status ?? (ambiguous.contains(entry.market) ? "unavailable" : "execution"))
        }.sorted { $0.operationId < $1.operationId }
    }

    func cancel(_ token: PositionUpdate) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[token.id], entry.operationId == nil, !entry.received else { return }
        entries.removeValue(forKey: token.id)
        if !entries.values.contains(where: { $0.market == token.market }) { baselines.removeValue(forKey: token.market); unavailable.remove(token.market) }
        revision &+= 1; publish()
    }

    /// Call on account reset/logout. Old handles and delayed reads become inert.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        closed = true; state = nil; asOf = nil; entries.removeAll(); baselines.removeAll(); observedFills.removeAll(); unavailable.removeAll(); completed.removeAll()
        revision &+= 1; publish()
    }

    private func publish() {
        var ambiguous = ambiguousMarkets()
        var rows: [String: VisiblePosition] = [:]
        for position in state?.positions ?? [] {
            if let size = Self.signed(position.size, side: position.side), size != 0 {
                rows[position.market] = VisiblePosition(market: position.market, signedSize: Self.text(size), source: "authoritative", authoritativePosition: position)
            }
        }
        for (market, baseline) in baselines {
            rows.removeValue(forKey: market)
            guard !ambiguous.contains(market) else { continue }
            var total = baseline
            var valid = true
            for entry in entries.values where entry.market == market {
                var left = total, delta = entry.side == .buy ? entry.quantity : -entry.quantity
                var next = Decimal.zero
                if NSDecimalAdd(&next, &left, &delta, .plain) != .noError { valid = false; break }
                total = next
            }
            if !valid { unavailable.insert(market); ambiguous.insert(market); continue }
            if total != 0 { rows[market] = VisiblePosition(market: market, signedSize: Self.text(total), source: entries.values.contains(where: { $0.market == market && $0.received }) ? "execution" : "baseline", authoritativePosition: nil) }
        }
        current.update { $0 = PositionViewSnapshot(positions: rows.values.sorted { $0.market < $1.market }, coverage: completed + coverage(), pendingMarkets: baselines.keys.sorted(), unavailableMarkets: ambiguous.sorted()) }
    }

    static func timestamp(_ state: ExchangeState) -> String? {
        timestamp(state.tradingAllocation?.asOf)
    }
    private static func timestamp(_ value: String?) -> String? {
        guard let raw = value,
              raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.dropLast().split(separator: ".")
        return String(parts[0]) + "." + ((parts.count == 2 ? String(parts[1]) : "") + String(repeating: "0", count: 9)).prefix(9) + "Z"
    }
    private static func decimal(_ raw: String) -> Decimal? {
        guard (raw.split(separator: ".").dropFirst().first?.count ?? 0) <= 38 else { return nil }
        return OrderExecutionReceipt.decimal(raw)
    }
    private static func add(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var left = a, right = b, result = Decimal.zero
        return NSDecimalAdd(&result, &left, &right, .plain) == .noError ? result : nil
    }
    private static func signed(_ size: String, side: PositionSide) -> Decimal? {
        decimal(size).map { side == .long ? $0 : -$0 }
    }
    private static func size(_ state: ExchangeState, _ market: String) -> Decimal? {
        let positions = state.positions.filter { $0.market == market }
        guard positions.count <= 1 else { return nil }
        return positions.first.map { signed($0.size, side: $0.side) } ?? .some(.zero)
    }
    private static func text(_ number: Decimal) -> String { NSDecimalNumber(decimal: number).stringValue }
    static func error(_ code: String) -> ArcaError { .unknown(code: code, message: code, errorId: nil) }
}

extension Arca {
    /// Shared display view; feed it by keeping `watchExchangeState` alive.
    public func positionView(objectId: String) -> PositionView {
        var result: PositionView!
        positionViews.update { views in
            if let existing = views[objectId] { result = existing }
            else {
                result = PositionView(objectId: objectId) { [weak self] in
                    guard let self else { throw PositionView.error("CLIENT_CLOSED") }
                    return try await self.getExchangeState(objectId: objectId)
                }
                views[objectId] = result
            }
        }
        return result
    }
    /// Retire the old view on account reset; delayed old handles cannot mutate its replacement.
    public func resetPositionView(objectId: String) {
        var old: PositionView?
        positionViews.update { old = $0.removeValue(forKey: objectId) }
        old?.reset()
    }
}

import Foundation

// Money figures (documents/contracts/sdk-money-figure.md): one shape for
// every balance a product shows, projected from one wallet snapshot. A
// figure is Arca's figure verbatim plus the legs of the operations moving
// money into or out of it; nothing here is summed into a figure on the
// client. Conservation (every dollar in exactly one place, counted once) is
// Arca's guarantee at the snapshot's journal position; this file renders it
// and never re-derives it.

/// Which end of a leg this figure is, from the figure's point of view.
public enum MoneyDirection: String, Codable, Sendable {
    /// Money on its way into this figure.
    case incoming
    /// Money committed to leave, or already gone from, this figure.
    case outgoing
}

/// Where a leg is: `reserved` is still inside its source's figure,
/// `inTransit` has left its source and not reached its destination, and
/// `expected` is a provider-confirmed deposit not on chain yet (listed,
/// never counted).
public enum MoneyLegStage: String, Codable, Sendable {
    case reserved
    case inTransit = "in_transit"
    case expected
}

/// The other end of a leg, described from the frame alone. `unknown` is a
/// counterparty the frame does not list (an account past the catalog page or
/// scan, an archived one, another owner's wallet); the leg still renders on
/// the end that is visible.
public enum MoneyCounterparty: Equatable, Sendable {
    case cash
    case account(arcaId: String, name: String?)
    case external(address: String?)
    case unknown(arcaId: String?)

    /// Whether the money crosses the wallet boundary (a deposit or a send).
    public var crossesWallet: Bool {
        if case .external = self { return true }
        return false
    }
}

/// One operation's money moving into or out of a figure: a `moving[]` entry
/// of the snapshot projected onto one end, or a `predicted` leg from an
/// accepted operation the stream has not framed yet.
public struct MoneyLeg: Equatable, Sendable, Identifiable {
    public var id: String { "\(operationId):\(direction.rawValue)" }

    public let operationId: String
    /// The snapshot operation's `requestId` (a move's create key) when known.
    public let requestId: String?
    /// The operation kind: `cash_to_trading`, `trading_to_cash`,
    /// `trading_to_trading`, `trading_to_external`, `deposit`, `move`, ...
    public let kind: String
    public let direction: MoneyDirection
    public let stage: MoneyLegStage
    /// What arrives, as a micro-USDC integer string.
    public let amountMicro: String
    public let counterparty: MoneyCounterparty
    /// True for a leg added by ``WalletMoneyWatchStream/predict(_:)`` before
    /// the stream carried the operation.
    public let predicted: Bool
    /// The operation's `createdAt` when the snapshot lists it.
    public let startedAt: String?

    public init(operationId: String, requestId: String? = nil, kind: String, direction: MoneyDirection, stage: MoneyLegStage,
                amountMicro: String, counterparty: MoneyCounterparty, predicted: Bool = false, startedAt: String? = nil) {
        self.operationId = operationId
        self.requestId = requestId
        self.kind = kind
        self.direction = direction
        self.stage = stage
        self.amountMicro = amountMicro
        self.counterparty = counterparty
        self.predicted = predicted
        self.startedAt = startedAt
    }
}

/// Why a figure last moved, named only when the frame makes it attributable.
public struct MoneyChange: Equatable, Sendable {
    public enum Cause: Equatable, Sendable {
        /// An operation touching the figure changed stage, leg or status.
        case operation(operationId: String, kind: String)
        /// The venue moved the figure (a fill's realized P&L, a funding
        /// payment, a liquidation or its mark) with no operation touching it.
        case venue
    }

    public let cause: Cause
    /// The signed difference of Arca's figure from the previous frame, a
    /// micro-USDC integer string ("-500000"). A caption, never a figure.
    public let deltaMicro: String
    /// The journal position of the frame that carried the change.
    public let sequence: UInt64

    public init(cause: Cause, deltaMicro: String, sequence: UInt64) {
        self.cause = cause
        self.deltaMicro = deltaMicro
        self.sequence = sequence
    }
}

/// Which snapshot figure a ``MoneyFigure`` renders.
public enum MoneyFigureKind: Equatable, Sendable {
    /// `totals`: the whole wallet.
    case total
    /// `cash.balances`.
    case cash
    /// One `accounts[]` entry.
    case account(arcaId: String)
}

/// A balance as a product shows it: Arca's figure, what of it is spendable,
/// and the operations moving money into or out of it. `settledMicro` is nil
/// only when the frame has no figure (an account never observed).
public struct MoneyFigure: Equatable, Sendable {
    public let kind: MoneyFigureKind
    /// Arca's figure verbatim: Cash `confirmedMicro`, an account's
    /// `balances.totalMicro`, the wallet's `totals.totalMicro`.
    public let settledMicro: String?
    /// What the figure can pay out now: Cash `availableMicro` (confirmed less
    /// reservations), an account's `withdrawableMicro`; nil for the total.
    public let availableMicro: String?
    /// Money on its way in, one leg per operation.
    public let arriving: [MoneyLeg]
    /// Money committed to leave or already gone, one leg per operation.
    public let departing: [MoneyLeg]
    /// The venue time (accounts) or block time (Cash) the figure describes.
    public let asOf: String?
    /// False once Arca stopped receiving the figure's source (a quiet venue
    /// subscription, Cash `unavailable`).
    public let current: Bool
    /// Where the figure came from: `cash`, an account's `balances.source`,
    /// or `totals`.
    public let source: String
    /// The venue frame's equity for an account, used as is when it is newer
    /// than `asOf` and the frame lists no settlement toward the account; nil
    /// otherwise. Never adds to `settledMicro`.
    public let revaluedMicro: String?
    /// Why the figure last moved, when the frame can say.
    public let change: MoneyChange?

    public init(kind: MoneyFigureKind, settledMicro: String?, availableMicro: String?, arriving: [MoneyLeg], departing: [MoneyLeg],
                asOf: String?, current: Bool, source: String, revaluedMicro: String? = nil, change: MoneyChange? = nil) {
        self.kind = kind
        self.settledMicro = settledMicro
        self.availableMicro = availableMicro
        self.arriving = arriving
        self.departing = departing
        self.asOf = asOf
        self.current = current
        self.source = source
        self.revaluedMicro = revaluedMicro
        self.change = change
    }

    /// Whether any leg is in motion (`reserved` or `in_transit`); `expected`
    /// legs are listed but do not count as motion.
    public var inMotion: Bool {
        (arriving + departing).contains { $0.stage != .expected }
    }

    /// The caption total of the arriving legs in motion, micro-USDC; a sum of
    /// annotations for one line of text, never a figure.
    public var arrivingMicro: String { Micro.sum(arriving.filter { $0.stage != .expected }.map(\.amountMicro)) }

    /// The caption total of the departing legs, micro-USDC.
    public var departingMicro: String { Micro.sum(departing.map(\.amountMicro)) }

    /// The caption total of `expected` deposits, micro-USDC.
    public var expectedMicro: String { Micro.sum(arriving.filter { $0.stage == .expected }.map(\.amountMicro)) }

    func with(revaluedMicro: String?) -> MoneyFigure {
        MoneyFigure(kind: kind, settledMicro: settledMicro, availableMicro: availableMicro, arriving: arriving, departing: departing,
                    asOf: asOf, current: current, source: source, revaluedMicro: revaluedMicro, change: change)
    }

    func with(change: MoneyChange?) -> MoneyFigure {
        MoneyFigure(kind: kind, settledMicro: settledMicro, availableMicro: availableMicro, arriving: arriving, departing: departing,
                    asOf: asOf, current: current, source: source, revaluedMicro: revaluedMicro, change: change)
    }

    func adding(arriving extraArriving: [MoneyLeg], departing extraDeparting: [MoneyLeg]) -> MoneyFigure {
        MoneyFigure(kind: kind, settledMicro: settledMicro, availableMicro: availableMicro,
                    arriving: arriving + extraArriving, departing: departing + extraDeparting,
                    asOf: asOf, current: current, source: source, revaluedMicro: revaluedMicro, change: change)
    }
}

/// An engineering-only observation about a frame. Never a gate and never a
/// product signal: the frame is published as Arca composed it.
public enum MoneyDiagnostic: Equatable, Sendable {
    /// `totals.totalMicro` did not equal the figures it was given; the
    /// difference as a signed micro string.
    case totalsMismatch(expectedMicro: String, composedMicro: String)
    /// A predicted leg reached its bound without the stream framing it.
    case predictionExpired(requestId: String)
    /// A venue frame older than the account's figure, or racing a pending
    /// settlement, was not used for revaluation.
    case venueFrameIgnored(arcaId: String, reason: String)
}

/// The accepted operation a product tells the watch about before the first
/// frame that carries it, so its legs can show at once. Only what the server
/// returned: its identity, amount and ends. It never changes a figure.
public struct MoneyPrediction: Equatable, Sendable {
    public let requestId: String
    public let operationId: String?
    public let kind: String
    public let amountMicro: String
    public let from: WalletEndpoint
    public let to: WalletEndpoint

    public init(requestId: String, operationId: String? = nil, kind: String, amountMicro: String, from: WalletEndpoint, to: WalletEndpoint) {
        self.requestId = requestId
        self.operationId = operationId
        self.kind = kind
        self.amountMicro = amountMicro
        self.from = from
        self.to = to
    }
}

/// A venue frame for one account: its equity and the time the venue
/// described, from an exchange-state watch.
public struct MoneyRevaluation: Equatable, Sendable {
    public let arcaId: String
    public let equityMicro: String
    public let observedAt: Date

    public init(arcaId: String, equityMicro: String, observedAt: Date) {
        self.arcaId = arcaId
        self.equityMicro = equityMicro
        self.observedAt = observedAt
    }

    /// From an exchange-state frame's `marginSummary.equity` (a decimal USD
    /// string) and its observation time; nil when either is missing.
    public init?(arcaId: String, exchangeState: ExchangeState) {
        guard let observed = exchangeState.observationTime, let micro = Micro.fromDecimal(exchangeState.marginSummary.equity) else { return nil }
        self.init(arcaId: arcaId, equityMicro: micro, observedAt: observed)
    }
}

/// Every money figure of one wallet at one journal position, from one
/// snapshot: the total, Cash, each trading account, and the operations behind
/// the legs. One frame, one value: a product renders all of it or none.
public struct WalletMoney: Equatable, Sendable {
    public let total: MoneyFigure
    public let cash: MoneyFigure
    /// Trading accounts keyed by `arcaId`.
    public let accounts: [String: MoneyFigure]
    /// The `arcaId`s in the snapshot's order (`labels.ordinal`, then path).
    public let accountOrder: [String]
    public let operations: [WalletFundingOperation]
    public let watermark: WalletSnapshotWatermark
    /// `totals.complete`: every component has a figure.
    public let complete: Bool
    /// `totals.current`: every figure is current.
    public let current: Bool
    public let diagnostics: [MoneyDiagnostic]
    /// The frame this was projected from, for anything a figure does not carry.
    public let snapshot: WalletSnapshot

    /// The figure of one account, nil when the snapshot does not list it.
    public func account(_ arcaId: String) -> MoneyFigure? { accounts[arcaId] }

    /// The figures in catalog order.
    public var orderedAccounts: [MoneyFigure] { accountOrder.compactMap { accounts[$0] } }

    /// Every leg of the wallet, deduplicated by operation (a leg shown at
    /// both ends is one operation).
    public var operationsInMotion: [WalletFundingOperation] {
        operations.filter { op in !op.isTerminal && snapshot.moving.contains { $0.operationId == op.operationId } }
    }

    // MARK: - Composition

    /// Projects a snapshot onto money figures. `previous` names the last
    /// frame of the same wallet so `change` can be attributed; `predictions`
    /// are accepted operations the stream has not framed yet (those it has
    /// are dropped here, so a leg is never shown twice); `revaluations` are
    /// venue frames per account.
    public static func compose(_ snapshot: WalletSnapshot, previous: WalletMoney? = nil,
                               predictions: [MoneyPrediction] = [], revaluations: [String: MoneyRevaluation] = [:]) -> WalletMoney {
        var diagnostics: [MoneyDiagnostic] = []
        let legs = legsByEnd(snapshot)
        let sequence = snapshot.watermark.sequence

        // Cash: Arca's figures verbatim. Its legs are the funding moves that
        // name Cash plus the Cash read model's own in-flight money: sends in
        // `cash.operations` and `pendingInMicro` (receivers and the linked
        // source), which `moving[]` does not list.
        let cashLegs = cashOwnLegs(snapshot)
        var cash = MoneyFigure(kind: .cash, settledMicro: snapshot.cash.balances.confirmedMicro,
                               availableMicro: snapshot.cash.balances.availableMicro,
                               arriving: legs.cash.arriving + cashLegs.arriving, departing: legs.cash.departing + cashLegs.departing,
                               asOf: snapshot.cash.balances.asOf.time, current: snapshot.cash.walletState != WalletState.unavailable.rawValue,
                               source: "cash")

        // Accounts in the snapshot's order.
        var accounts: [String: MoneyFigure] = [:]
        var order: [String] = []
        for account in snapshot.accounts {
            let ends = legs.accounts[account.arcaId] ?? LegEnds()
            var figure = MoneyFigure(kind: .account(arcaId: account.arcaId), settledMicro: account.balances?.totalMicro,
                                     availableMicro: account.balances?.withdrawableMicro, arriving: ends.arriving, departing: ends.departing,
                                     asOf: account.asOf, current: account.current, source: account.balances?.source ?? "unavailable")
            if let revaluation = revaluations[account.arcaId] {
                switch Self.revaluation(revaluation, for: account, figure: figure) {
                case .success(let micro): figure = figure.with(revaluedMicro: micro)
                case .failure(let reason): diagnostics.append(.venueFrameIgnored(arcaId: account.arcaId, reason: reason))
                }
            }
            accounts[account.arcaId] = figure
            order.append(account.arcaId)
        }

        // The total: `totals` verbatim, annotated only with legs that cross
        // the wallet boundary (Axiom 9.9); Cash's own sends and pending
        // receipts cross it too.
        var total = MoneyFigure(kind: .total, settledMicro: snapshot.totals.totalMicro, availableMicro: nil,
                                arriving: legs.total.arriving + cashLegs.arriving, departing: legs.total.departing + cashLegs.departing,
                                asOf: snapshot.composedAt.isEmpty ? nil : snapshot.composedAt, current: snapshot.totals.current, source: "totals")

        // Predicted legs: only operations the frame does not carry yet.
        let framed = Set(snapshot.operations.compactMap(\.requestId)) .union(snapshot.operations.map(\.operationId))
        for prediction in predictions where !framed.contains(prediction.requestId) && !(prediction.operationId.map { framed.contains($0) } ?? false) {
            let predicted = predictedLegs(prediction, snapshot: snapshot)
            if let leg = predicted.cash.departing.first { cash = cash.adding(arriving: [], departing: [leg]) }
            if let leg = predicted.cash.arriving.first { cash = cash.adding(arriving: [leg], departing: []) }
            for (arcaId, ends) in predicted.accounts {
                guard let figure = accounts[arcaId] else { continue }
                accounts[arcaId] = figure.adding(arriving: ends.arriving, departing: ends.departing)
            }
            total = total.adding(arriving: predicted.total.arriving, departing: predicted.total.departing)
        }

        // Diagnostics only: does the composed sum agree with `totals`?
        if snapshot.totals.complete, let composed = composedTotal(snapshot), composed != snapshot.totals.totalMicro {
            diagnostics.append(.totalsMismatch(expectedMicro: snapshot.totals.totalMicro, composedMicro: composed))
        }

        // Changes, attributed from frame facts.
        if let previous, previous.snapshot.watermark.sequence < sequence {
            cash = cash.with(change: change(from: previous.cash, to: cash, snapshot: snapshot, previous: previous, sequence: sequence, account: nil))
            for (arcaId, figure) in accounts {
                let before = previous.accounts[arcaId]
                accounts[arcaId] = figure.with(change: change(from: before, to: figure, snapshot: snapshot, previous: previous, sequence: sequence, account: snapshot.account(arcaId: arcaId)))
            }
            total = total.with(change: change(from: previous.total, to: total, snapshot: snapshot, previous: previous, sequence: sequence, account: nil))
        }

        return WalletMoney(total: total, cash: cash, accounts: accounts, accountOrder: order, operations: snapshot.operations,
                           watermark: snapshot.watermark, complete: snapshot.totals.complete, current: snapshot.totals.current,
                           diagnostics: diagnostics, snapshot: snapshot)
    }

    // MARK: - Legs

    struct LegEnds {
        var arriving: [MoneyLeg] = []
        var departing: [MoneyLeg] = []
    }

    struct LegsByEnd {
        var cash = LegEnds()
        var accounts: [String: LegEnds] = [:]
        var total = LegEnds()
    }

    static func counterparty(_ endpoint: WalletEndpoint, snapshot: WalletSnapshot) -> MoneyCounterparty {
        if endpoint.isCash || (endpoint.boundaryId != nil && endpoint.boundaryId == snapshot.boundaryId && !snapshot.boundaryId.isEmpty) {
            return .cash
        }
        if let arcaId = endpoint.arcaId {
            if let account = snapshot.account(arcaId: arcaId) { return .account(arcaId: arcaId, name: account.name) }
            return .unknown(arcaId: arcaId)
        }
        if endpoint.kind == "external" || endpoint.address != nil || (!endpoint.kind.isEmpty && endpoint.kind != "cash") {
            return .external(address: endpoint.address)
        }
        return .unknown(arcaId: nil)
    }

    /// Projects every `moving[]` entry onto the ends the snapshot lists. A
    /// `reserved` leg shows at both ends (the money is still inside its
    /// source); an `in_transit` leg shows at its destination when the frame
    /// lists it, else at its source (a send on its way out of the wallet);
    /// an `expected` leg shows only at its destination.
    static func legsByEnd(_ snapshot: WalletSnapshot) -> LegsByEnd {
        var out = LegsByEnd()
        let operations = Dictionary(snapshot.operations.map { ($0.operationId, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in snapshot.moving {
            guard let stage = entry.typedLeg.map(stage(of:)) else { continue }
            let op = operations[entry.operationId]
            let fromParty = counterparty(entry.from, snapshot: snapshot)
            let toParty = counterparty(entry.to, snapshot: snapshot)
            let departing = MoneyLeg(operationId: entry.operationId, requestId: op?.requestId, kind: entry.kind, direction: .outgoing,
                                     stage: stage, amountMicro: entry.amountMicro, counterparty: toParty, startedAt: op?.createdAt)
            let arriving = MoneyLeg(operationId: entry.operationId, requestId: op?.requestId, kind: entry.kind, direction: .incoming,
                                    stage: stage, amountMicro: entry.amountMicro, counterparty: fromParty, startedAt: op?.createdAt)
            switch stage {
            case .reserved:
                place(departing, at: fromParty, in: &out)
                place(arriving, at: toParty, in: &out)
            case .inTransit:
                if isListed(toParty) { place(arriving, at: toParty, in: &out) } else { place(departing, at: fromParty, in: &out) }
            case .expected:
                place(arriving, at: toParty, in: &out)
            }
            // The total shows only what crosses the wallet boundary.
            if toParty.crossesWallet && !fromParty.crossesWallet { out.total.departing.append(departing) }
            if fromParty.crossesWallet && !toParty.crossesWallet { out.total.arriving.append(arriving) }
        }
        return out
    }

    static func isListed(_ party: MoneyCounterparty) -> Bool {
        switch party {
        case .cash, .account: return true
        case .external, .unknown: return false
        }
    }

    /// The Cash read model's own in-flight money: a send in `cash.operations`
    /// is `reserved` while `sending` (the ledger holds it; `availableMicro`
    /// already excludes it) and `in_transit` while `confirming`;
    /// `pendingInMicro` is one arriving leg from outside the wallet.
    static func cashOwnLegs(_ snapshot: WalletSnapshot) -> LegEnds {
        var ends = LegEnds()
        for op in snapshot.cash.operations where op.kind == "send" {
            let stage: MoneyLegStage
            switch op.typedState {
            case .sending?: stage = .reserved
            case .confirming?: stage = .inTransit
            default: continue
            }
            ends.departing.append(MoneyLeg(operationId: op.id, requestId: op.requestId, kind: "send", direction: .outgoing, stage: stage,
                                           amountMicro: op.amountMicro, counterparty: .external(address: op.destination), startedAt: op.startedAt))
        }
        if let pending = Micro.parse(snapshot.cash.balances.pendingInMicro), pending > 0 {
            ends.arriving.append(MoneyLeg(operationId: "cash:pending-in", kind: "deposit", direction: .incoming, stage: .inTransit,
                                          amountMicro: snapshot.cash.balances.pendingInMicro, counterparty: .external(address: nil)))
        }
        return ends
    }

    static func place(_ leg: MoneyLeg, at party: MoneyCounterparty, in legs: inout LegsByEnd) {
        switch party {
        case .cash:
            if leg.direction == .outgoing { legs.cash.departing.append(leg) } else { legs.cash.arriving.append(leg) }
        case .account(let arcaId, _):
            var ends = legs.accounts[arcaId] ?? LegEnds()
            if leg.direction == .outgoing { ends.departing.append(leg) } else { ends.arriving.append(leg) }
            legs.accounts[arcaId] = ends
        case .external, .unknown:
            break // not an end this frame can show
        }
    }

    static func stage(of leg: WalletMovingLeg) -> MoneyLegStage {
        switch leg {
        case .reserved: return .reserved
        case .inTransit: return .inTransit
        case .expected: return .expected
        }
    }

    static func predictedLegs(_ prediction: MoneyPrediction, snapshot: WalletSnapshot) -> LegsByEnd {
        var out = LegsByEnd()
        let fromParty = counterparty(prediction.from, snapshot: snapshot)
        let toParty = counterparty(prediction.to, snapshot: snapshot)
        let id = prediction.operationId ?? prediction.requestId
        let departing = MoneyLeg(operationId: id, requestId: prediction.requestId, kind: prediction.kind, direction: .outgoing, stage: .reserved,
                                 amountMicro: prediction.amountMicro, counterparty: toParty, predicted: true)
        let arriving = MoneyLeg(operationId: id, requestId: prediction.requestId, kind: prediction.kind, direction: .incoming, stage: .reserved,
                                amountMicro: prediction.amountMicro, counterparty: fromParty, predicted: true)
        place(departing, at: fromParty, in: &out)
        place(arriving, at: toParty, in: &out)
        if toParty.crossesWallet && !fromParty.crossesWallet { out.total.departing.append(departing) }
        if fromParty.crossesWallet && !toParty.crossesWallet { out.total.arriving.append(arriving) }
        return out
    }

    // MARK: - Revaluation

    enum Revaluation {
        case success(String)
        case failure(String)
    }

    /// A venue frame is used as is only when it is newer than the account's
    /// figure and the frame lists no settlement toward the account: Arca
    /// holds the figure while a funding operation holds the account, so a
    /// venue frame that already shows the money would count it twice with
    /// the leg still listed.
    static func revaluation(_ revaluation: MoneyRevaluation, for account: WalletTradingAccount, figure: MoneyFigure) -> Revaluation {
        if account.heldBy != nil { return .failure("account held by \(account.heldBy ?? "")") }
        if figure.arriving.contains(where: { $0.stage != .expected }) { return .failure("settlement pending toward the account") }
        guard let asOf = account.asOf, let figureTime = RFC3339.parse(asOf) else {
            return account.balances == nil ? .failure("no figure to revalue") : .success(revaluation.equityMicro)
        }
        if revaluation.observedAt < figureTime { return .failure("venue frame older than the figure") }
        return .success(revaluation.equityMicro)
    }

    // MARK: - Diagnostics

    /// `cash.confirmed + moving(in transit) + Σ accounts` from the pieces the
    /// frame lists, for the diagnostic only.
    static func composedTotal(_ snapshot: WalletSnapshot) -> String? {
        var terms = [snapshot.cash.balances.confirmedMicro]
        for account in snapshot.accounts where account.lifecycle != WalletTradingAccountState.archived.rawValue {
            guard let balances = account.balances else { return nil }
            terms.append(balances.totalMicro)
        }
        terms.append(contentsOf: snapshot.moving.filter { $0.typedLeg == .inTransit }.map(\.amountMicro))
        return Micro.sum(terms)
    }

    // MARK: - Change attribution

    static func change(from previous: MoneyFigure?, to figure: MoneyFigure, snapshot: WalletSnapshot, previous previousMoney: WalletMoney,
                       sequence: UInt64, account: WalletTradingAccount?) -> MoneyChange? {
        guard let before = previous?.settledMicro, let after = figure.settledMicro, let delta = Micro.difference(after, before) else {
            // No figure to compare: an operation whose legs changed still names itself.
            if let cause = operationThatMoved(figure, previous: previous, snapshot: snapshot, previousMoney: previousMoney) {
                return MoneyChange(cause: cause, deltaMicro: "0", sequence: sequence)
            }
            return nil
        }
        if let cause = operationThatMoved(figure, previous: previous, snapshot: snapshot, previousMoney: previousMoney) {
            return MoneyChange(cause: cause, deltaMicro: delta, sequence: sequence)
        }
        if delta == "0" { return nil }
        if let account, account.balances?.typedSource == .hyperliquidWs {
            return MoneyChange(cause: .venue, deltaMicro: delta, sequence: sequence)
        }
        return nil
    }

    /// An operation that touches the figure and changed between the frames:
    /// a new or retired leg, or a stage or status transition.
    static func operationThatMoved(_ figure: MoneyFigure, previous: MoneyFigure?, snapshot: WalletSnapshot, previousMoney: WalletMoney) -> MoneyChange.Cause? {
        let nowLegs = Dictionary((figure.arriving + figure.departing).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let beforeLegs = Dictionary(((previous?.arriving ?? []) + (previous?.departing ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var touched: [(String, String)] = []
        for (id, leg) in nowLegs where beforeLegs[id]?.stage != leg.stage { touched.append((leg.operationId, leg.kind)) }
        for (id, leg) in beforeLegs where nowLegs[id] == nil { touched.append((leg.operationId, leg.kind)) }
        let before = Dictionary(previousMoney.operations.map { ($0.operationId, $0) }, uniquingKeysWith: { first, _ in first })
        for op in snapshot.operations where touches(op, figure: figure, snapshot: snapshot) {
            let old = before[op.operationId]
            if old == nil || old?.stage != op.stage || old?.status != op.status || old?.creditBooked != op.creditBooked || old?.debitBooked != op.debitBooked {
                touched.append((op.operationId, op.kind))
            }
        }
        if figure.kind == .cash || figure.kind == .total {
            let beforeCash = Dictionary(previousMoney.snapshot.cash.operations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for op in snapshot.cash.operations where beforeCash[op.id]?.state != op.state && (op.kind == "send" || figure.kind == .cash) {
                touched.append((op.id, op.kind))
            }
        }
        guard let (id, kind) = touched.first else { return nil }
        return .operation(operationId: id, kind: kind)
    }

    static func touches(_ op: WalletFundingOperation, figure: MoneyFigure, snapshot: WalletSnapshot) -> Bool {
        let ends = [counterparty(op.from, snapshot: snapshot), counterparty(op.to, snapshot: snapshot)]
        switch figure.kind {
        case .cash: return ends.contains(.cash)
        case .account(let arcaId): return ends.contains { if case .account(let id, _) = $0 { return id == arcaId } else { return false } }
        case .total: return ends.contains { $0.crossesWallet }
        }
    }
}

/// Integer arithmetic on micro-USDC strings for captions and diagnostics.
/// A figure is never produced here; only differences and caption totals.
enum Micro {
    static func parse(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Int64(trimmed)
    }

    static func sum(_ values: [String]) -> String {
        var total: Int64 = 0
        for value in values { total &+= parse(value) ?? 0 }
        return String(total)
    }

    /// `a - b` as a signed integer string, nil when either is not an integer.
    static func difference(_ a: String, _ b: String) -> String? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        return String(x - y)
    }

    /// A decimal USD string ("6.49", "-0.5") as micro-USDC, truncated toward
    /// zero past six decimals; nil when not a decimal.
    static func fromDecimal(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, whole.allSatisfy(\.isNumber) || whole.isEmpty else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.allSatisfy(\.isNumber) else { return nil }
        let padded = String((fraction + "000000").prefix(6))
        guard let wholeValue = Int64(whole.isEmpty ? "0" : String(whole)), let fractionValue = Int64(padded) else { return nil }
        let micro = wholeValue * 1_000_000 + fractionValue
        return negative ? String(-micro) : String(micro)
    }
}

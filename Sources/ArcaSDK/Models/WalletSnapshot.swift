import Foundation

// The combined Cash and trading wallet snapshot, schema 2
// (documents/contracts/v9-wallet-snapshot.md): Cash, every trading account
// under the owner's root, the money between them and the funding operations
// that move it, composed by Arca from stored records in one read-only
// transaction at one journal position. Every money figure is a micro-USDC
// integer string. In-flight money is listed in `moving`, never hidden, and
// `totals.totalMicro = cashMicro + movingMicro + tradingMicro` at every
// position. Vocabulary values are kept as strings on the wire types so a value
// this SDK predates still decodes; the typed accessors return nil for one it
// does not know.

/// The wallet snapshot schema this SDK reads.
public let walletSnapshotSchema = 2

/// What the snapshot's figures describe. `sequence` is the realm journal
/// position the snapshot was read at (a stream resumes after it);
/// `revision` changes only when one of the wallet's own boundaries changed.
public struct WalletSnapshotWatermark: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let revision: UInt64
    public let cashBlock: UInt64
    public let cashBlockHash: String?
    public let nativeObservedAt: Int64
    public let settlementSequence: UInt64
    public let lastSettlementBlock: UInt64

    public init(sequence: UInt64, revision: UInt64, cashBlock: UInt64 = 0, cashBlockHash: String? = nil,
                nativeObservedAt: Int64 = 0, settlementSequence: UInt64 = 0, lastSettlementBlock: UInt64 = 0) {
        self.sequence = sequence
        self.revision = revision
        self.cashBlock = cashBlock
        self.cashBlockHash = cashBlockHash
        self.nativeObservedAt = nativeObservedAt
        self.settlementSequence = settlementSequence
        self.lastSettlementBlock = lastSettlementBlock
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, revision, cashBlock, cashBlockHash, nativeObservedAt, settlementSequence, lastSettlementBlock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        cashBlock = try c.decodeIfPresent(UInt64.self, forKey: .cashBlock) ?? 0
        cashBlockHash = try c.decodeIfPresent(String.self, forKey: .cashBlockHash)
        nativeObservedAt = try c.decodeIfPresent(Int64.self, forKey: .nativeObservedAt) ?? 0
        settlementSequence = try c.decodeIfPresent(UInt64.self, forKey: .settlementSequence) ?? 0
        lastSettlementBlock = try c.decodeIfPresent(UInt64.self, forKey: .lastSettlementBlock) ?? 0
    }
}

/// A trading account's observed figures: `totalMicro` is the perp account
/// value plus USDC spot, `withdrawableMicro` what the venue would release.
/// `source` says where they came from: `hyperliquid_ws` (a venue push),
/// `arca_settlement` (what Arca booked, until the next push confirms it),
/// `arca_setup` (an account created by an unfinished move), `declared` or
/// `not_deployed` (zero by construction).
public struct WalletNativeBalances: Codable, Equatable, Sendable {
    public let totalMicro: String
    public let perpMicro: String
    public let withdrawableMicro: String
    public let spotMicro: String
    public let source: String

    public init(totalMicro: String, perpMicro: String, withdrawableMicro: String, spotMicro: String, source: String) {
        self.totalMicro = totalMicro
        self.perpMicro = perpMicro
        self.withdrawableMicro = withdrawableMicro
        self.spotMicro = spotMicro
        self.source = source
    }

    public var typedSource: WalletNativeBalanceSource? { WalletNativeBalanceSource(rawValue: source) }
}

/// `balances.source` values of a trading account.
public enum WalletNativeBalanceSource: String, Codable, CaseIterable, Sendable {
    case hyperliquidWs = "hyperliquid_ws"
    case arcaSettlement = "arca_settlement"
    case arcaSetup = "arca_setup"
    case declared
    case notDeployed = "not_deployed"
}

/// One end of a movement: Cash (`kind` `cash`), a trading account (its
/// `arcaId`, `arcaPath` and `boundaryId`), or an outside address (`kind`
/// `external`, or a provider name for an announced deposit, with the payer's
/// `address` once observed).
public struct WalletEndpoint: Codable, Equatable, Sendable {
    public let kind: String
    public let arcaId: String?
    public let arcaPath: String?
    public let boundaryId: String?
    public let address: String?

    public init(kind: String, arcaId: String? = nil, arcaPath: String? = nil, boundaryId: String? = nil, address: String? = nil) {
        self.kind = kind
        self.arcaId = arcaId
        self.arcaPath = arcaPath
        self.boundaryId = boundaryId
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case kind, arcaId, arcaPath, boundaryId, address }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        arcaId = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .arcaId))
        arcaPath = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .arcaPath))
        boundaryId = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .boundaryId))
        address = Self.nonEmpty(try c.decodeIfPresent(String.self, forKey: .address))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Whether this end is the wallet's Cash account.
    public var isCash: Bool { kind == "cash" }
}

/// Money in flight for one unfinished operation. `leg` is `reserved` (still
/// inside its source's figure), `in_transit` (left its source, not yet at its
/// destination; counted in `totals.movingMicro`) or `expected` (a deposit a
/// provider confirmed that is not on chain yet; listed, never summed).
/// `amountMicro` is what arrives.
public struct WalletMoving: Codable, Equatable, Sendable {
    public let operationId: String
    public let kind: String
    public let leg: String
    public let amountMicro: String
    public let from: WalletEndpoint
    public let to: WalletEndpoint

    public init(operationId: String, kind: String, leg: String, amountMicro: String, from: WalletEndpoint, to: WalletEndpoint) {
        self.operationId = operationId
        self.kind = kind
        self.leg = leg
        self.amountMicro = amountMicro
        self.from = from
        self.to = to
    }

    public var typedLeg: WalletMovingLeg? { WalletMovingLeg(rawValue: leg) }
}

/// `moving[].leg` values.
public enum WalletMovingLeg: String, Codable, CaseIterable, Sendable {
    case reserved
    case inTransit = "in_transit"
    case expected
}

/// An account's own key-free receiving address; `pendingMicro` is what
/// arrived there and is not swept yet.
public struct WalletDepositAddress: Codable, Equatable, Sendable {
    public let address: String
    public let lifecycle: String
    public let pendingMicro: String

    public init(address: String, lifecycle: String, pendingMicro: String) {
        self.address = address
        self.lifecycle = lifecycle
        self.pendingMicro = pendingMicro
    }
}

/// How far a trading account is from placing orders, from stored records.
public struct WalletTradingReadiness: Codable, Equatable, Sendable {
    public let state: String
    public let bindingOperationId: String?

    public init(state: String, bindingOperationId: String? = nil) {
        self.state = state
        self.bindingOperationId = bindingOperationId
    }

    public var typedState: WalletTradingReadinessState? { WalletTradingReadinessState(rawValue: state) }
}

/// `trading.state` values of a trading account.
public enum WalletTradingReadinessState: String, Codable, CaseIterable, Sendable {
    case setupRequired = "setup_required"
    case tradingDisabled = "trading_disabled"
    case awaitingFirstCredit = "awaiting_first_credit"
    case consentRequired = "consent_required"
    case consented
    case unavailable
}

/// The standing shape of one route on a trading account at this snapshot.
/// Advisory: a quote is the priced, expiring review; a preview never admits,
/// reserves or prices a specific amount.
public struct WalletRoutePreview: Codable, Equatable, Sendable {
    public let route: String
    public let allowed: Bool
    public let reason: String?
    public let minimumRaw: String?
    public let maxRaw: String?
    public let activationFeeRaw: String?
    public let networkFeeRaw: String?
    public let requiresSetup: Bool

    private enum CodingKeys: String, CodingKey {
        case route, allowed, reason, minimumRaw, maxRaw, activationFeeRaw, networkFeeRaw, requiresSetup
    }

    public init(route: String, allowed: Bool, reason: String? = nil, minimumRaw: String? = nil, maxRaw: String? = nil,
                activationFeeRaw: String? = nil, networkFeeRaw: String? = nil, requiresSetup: Bool = false) {
        self.route = route
        self.allowed = allowed
        self.reason = reason
        self.minimumRaw = minimumRaw
        self.maxRaw = maxRaw
        self.activationFeeRaw = activationFeeRaw
        self.networkFeeRaw = networkFeeRaw
        self.requiresSetup = requiresSetup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? ""
        allowed = try c.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        minimumRaw = try c.decodeIfPresent(String.self, forKey: .minimumRaw)
        maxRaw = try c.decodeIfPresent(String.self, forKey: .maxRaw)
        activationFeeRaw = try c.decodeIfPresent(String.self, forKey: .activationFeeRaw)
        networkFeeRaw = try c.decodeIfPresent(String.self, forKey: .networkFeeRaw)
        requiresSetup = try c.decodeIfPresent(Bool.self, forKey: .requiresSetup) ?? false
    }
}

/// Whether an account may take part in one action, with the reason when not.
public struct WalletAccountCapability: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let reason: String?

    public init(allowed: Bool, reason: String? = nil) {
        self.allowed = allowed
        self.reason = reason
    }
}

/// One declared or deployed trading account under the owner's root.
/// `balances` is nil only for a deployed account never observed; `asOf` is
/// the venue time the figures describe and `current` is false once they went
/// quiet. `heldBy` names the funding operation holding the account: while it
/// is set the figure keeps its pre-operation value and the money is listed in
/// `moving` instead, so a move is counted once.
public struct WalletTradingAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: String { arcaId }

    public let arcaId: String
    public let arcaPath: String
    public let boundaryId: String
    public let kind: String
    public let accountAddress: String
    public let localId: String?
    public let labels: [String: String]
    public let state: String
    public let setupStatus: String
    public let lifecycle: String
    public let declaredAt: String?
    public let revision: UInt64
    public let balances: WalletNativeBalances?
    public let asOf: String?
    public let current: Bool
    public let heldBy: String?
    public let routes: [WalletRoutePreview]
    public let trading: WalletTradingReadiness
    public let depositAddress: WalletDepositAddress?
    // Lifecycle and fee facts (documents/contracts/v9-logical-account-lifecycle.md).
    public let factsSequence: UInt64
    public let setupRetryable: Bool
    public let activation: String?
    public let fundingState: String?
    public let capabilities: [String: WalletAccountCapability]
    public let deferredActivationFeeRaw: String?
    public let deferredActivationFeeState: String?
    public let deferredActivationFeeTrigger: String?

    public init(arcaId: String, arcaPath: String, boundaryId: String, kind: String, accountAddress: String = "",
                localId: String? = nil, labels: [String: String] = [:], state: String, setupStatus: String = "",
                lifecycle: String = "active", declaredAt: String? = nil, revision: UInt64 = 0,
                balances: WalletNativeBalances?, asOf: String? = nil, current: Bool, heldBy: String? = nil,
                routes: [WalletRoutePreview] = [], trading: WalletTradingReadiness = .init(state: "unavailable"),
                depositAddress: WalletDepositAddress? = nil, factsSequence: UInt64 = 0, setupRetryable: Bool = false,
                activation: String? = nil, fundingState: String? = nil, capabilities: [String: WalletAccountCapability] = [:],
                deferredActivationFeeRaw: String? = nil, deferredActivationFeeState: String? = nil,
                deferredActivationFeeTrigger: String? = nil) {
        self.arcaId = arcaId
        self.arcaPath = arcaPath
        self.boundaryId = boundaryId
        self.kind = kind
        self.accountAddress = accountAddress
        self.localId = localId
        self.labels = labels
        self.state = state
        self.setupStatus = setupStatus
        self.lifecycle = lifecycle
        self.declaredAt = declaredAt
        self.revision = revision
        self.balances = balances
        self.asOf = asOf
        self.current = current
        self.heldBy = heldBy
        self.routes = routes
        self.trading = trading
        self.depositAddress = depositAddress
        self.factsSequence = factsSequence
        self.setupRetryable = setupRetryable
        self.activation = activation
        self.fundingState = fundingState
        self.capabilities = capabilities
        self.deferredActivationFeeRaw = deferredActivationFeeRaw
        self.deferredActivationFeeState = deferredActivationFeeState
        self.deferredActivationFeeTrigger = deferredActivationFeeTrigger
    }

    private enum CodingKeys: String, CodingKey {
        case arcaId, arcaPath, boundaryId, kind, accountAddress, localId, labels, state, setupStatus, lifecycle, declaredAt
        case revision, balances, asOf, current, heldBy, routes, trading, depositAddress
        case factsSequence, setupRetryable, activation, fundingState, capabilities
        case deferredActivationFeeRaw, deferredActivationFeeState, deferredActivationFeeTrigger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arcaId = try c.decodeIfPresent(String.self, forKey: .arcaId) ?? ""
        arcaPath = try c.decodeIfPresent(String.self, forKey: .arcaPath) ?? ""
        boundaryId = try c.decodeIfPresent(String.self, forKey: .boundaryId) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        accountAddress = try c.decodeIfPresent(String.self, forKey: .accountAddress) ?? ""
        localId = try c.decodeIfPresent(String.self, forKey: .localId)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        setupStatus = try c.decodeIfPresent(String.self, forKey: .setupStatus) ?? ""
        lifecycle = try c.decodeIfPresent(String.self, forKey: .lifecycle) ?? ""
        declaredAt = try c.decodeIfPresent(String.self, forKey: .declaredAt)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        balances = try c.decodeIfPresent(WalletNativeBalances.self, forKey: .balances)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
        current = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        heldBy = try c.decodeIfPresent(String.self, forKey: .heldBy).flatMap { $0.isEmpty ? nil : $0 }
        routes = try c.decodeIfPresent([WalletRoutePreview].self, forKey: .routes) ?? []
        trading = try c.decodeIfPresent(WalletTradingReadiness.self, forKey: .trading) ?? WalletTradingReadiness(state: "unavailable")
        depositAddress = try c.decodeIfPresent(WalletDepositAddress.self, forKey: .depositAddress)
        factsSequence = try c.decodeIfPresent(UInt64.self, forKey: .factsSequence) ?? 0
        setupRetryable = try c.decodeIfPresent(Bool.self, forKey: .setupRetryable) ?? false
        activation = try c.decodeIfPresent(String.self, forKey: .activation)
        fundingState = try c.decodeIfPresent(String.self, forKey: .fundingState)
        capabilities = try c.decodeIfPresent([String: WalletAccountCapability].self, forKey: .capabilities) ?? [:]
        deferredActivationFeeRaw = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeRaw)
        deferredActivationFeeState = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeState)
        deferredActivationFeeTrigger = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeTrigger)
    }

    public var typedState: WalletTradingAccountState? { WalletTradingAccountState(rawValue: state) }

    /// The owner-facing name from `labels.name`, nil when unnamed.
    public var name: String? { labels["name"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The catalog position from `labels.ordinal`, nil when unordered.
    public var ordinal: Int? { labels["ordinal"].flatMap { Int($0) } }
}

/// `accounts[].state` values.
public enum WalletTradingAccountState: String, Codable, CaseIterable, Sendable {
    case declared
    case settingUp = "setting_up"
    case setupRetryable = "setup_retryable"
    case ready
    case archived
    case unavailable
}

/// The Cash policy-move leg of a Cash <-> trading move: `debit` or `credit`,
/// `reserved`, `pinned`, `booked` or `released`.
public struct WalletCashLeg: Codable, Equatable, Sendable {
    public let leg: String
    public let state: String
    public let amountMicro: String
    public let txHash: String?

    public init(leg: String, state: String, amountMicro: String, txHash: String? = nil) {
        self.leg = leg
        self.state = state
        self.amountMicro = amountMicro
        self.txHash = txHash
    }
}

/// One operator transaction of a funding operation and its state
/// (`planned`, `signed`, `confirmed` or `reverted`).
public struct WalletMoveStep: Codable, Equatable, Sendable {
    public let name: String
    public let state: String
    public let txHash: String?
    public let blockNumber: UInt64?
    public let blockHash: String?

    public init(name: String, state: String, txHash: String? = nil, blockNumber: UInt64? = nil, blockHash: String? = nil) {
        self.name = name
        self.state = state
        self.txHash = txHash
        self.blockNumber = blockNumber
        self.blockHash = blockHash
    }
}

/// A send's current owner-signed consent.
public struct WalletMoveConsent: Codable, Equatable, Sendable {
    public let proposalId: String
    public let attempt: Int
    public let expiresAt: Int64
    public let signed: Bool

    public init(proposalId: String, attempt: Int, expiresAt: Int64, signed: Bool) {
        self.proposalId = proposalId
        self.attempt = attempt
        self.expiresAt = expiresAt
        self.signed = signed
    }
}

/// An owner answer an operation waits for (`setup_signature`,
/// `send_signature`). The proposal payload is read from the proposal itself.
public struct WalletFundingRequirement: Codable, Equatable, Sendable {
    public let kind: String
    public let operationId: String
    public let proposalId: String
    public let actionIds: [String]
    public let expiresAt: Int64

    private enum CodingKeys: String, CodingKey { case kind, operationId, proposalId, actionIds, expiresAt }

    public init(kind: String, operationId: String, proposalId: String, actionIds: [String] = [], expiresAt: Int64 = 0) {
        self.kind = kind
        self.operationId = operationId
        self.proposalId = proposalId
        self.actionIds = actionIds
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        operationId = try c.decodeIfPresent(String.self, forKey: .operationId) ?? ""
        proposalId = try c.decodeIfPresent(String.self, forKey: .proposalId) ?? ""
        actionIds = try c.decodeIfPresent([String].self, forKey: .actionIds) ?? []
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
    }
}

/// The settlement that proved a funding operation's charge and credit.
public struct WalletSettlement: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let nativeTxHash: String?
    public let coreBlock: UInt64
    public let coreBlockHash: String?
    public let amountMicro: String
    public let feeMicro: String
    public let creditMicro: String
    public let final: Bool

    private enum CodingKeys: String, CodingKey {
        case sequence, nativeTxHash, coreBlock, coreBlockHash, amountMicro, feeMicro, creditMicro, final
    }

    public init(sequence: UInt64, nativeTxHash: String? = nil, coreBlock: UInt64 = 0, coreBlockHash: String? = nil,
                amountMicro: String, feeMicro: String = "0", creditMicro: String, final: Bool) {
        self.sequence = sequence
        self.nativeTxHash = nativeTxHash
        self.coreBlock = coreBlock
        self.coreBlockHash = coreBlockHash
        self.amountMicro = amountMicro
        self.feeMicro = feeMicro
        self.creditMicro = creditMicro
        self.final = final
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        nativeTxHash = try c.decodeIfPresent(String.self, forKey: .nativeTxHash)
        coreBlock = try c.decodeIfPresent(UInt64.self, forKey: .coreBlock) ?? 0
        coreBlockHash = try c.decodeIfPresent(String.self, forKey: .coreBlockHash)
        amountMicro = try c.decodeIfPresent(String.self, forKey: .amountMicro) ?? "0"
        feeMicro = try c.decodeIfPresent(String.self, forKey: .feeMicro) ?? "0"
        creditMicro = try c.decodeIfPresent(String.self, forKey: .creditMicro) ?? "0"
        final = try c.decodeIfPresent(Bool.self, forKey: .final) ?? false
    }
}

/// Who sent a deposit, as the product announced it.
public struct WalletDepositSource: Codable, Equatable, Sendable {
    public let kind: String
    public let reference: String?

    public init(kind: String, reference: String? = nil) {
        self.kind = kind
        self.reference = reference
    }
}

/// The canonical transfer into an account's deposit address.
public struct WalletDepositArrival: Codable, Equatable, Sendable {
    public let txHash: String
    public let logIndex: UInt
    public let blockNumber: UInt64
    public let blockHash: String
    public let from: String
    public let amountMicro: String

    public init(txHash: String, logIndex: UInt, blockNumber: UInt64, blockHash: String, from: String, amountMicro: String) {
        self.txHash = txHash
        self.logIndex = logIndex
        self.blockNumber = blockNumber
        self.blockHash = blockHash
        self.from = from
        self.amountMicro = amountMicro
    }
}

/// One funding operation of the wallet with everything needed to render its
/// progress. `kind` is `setup`, `deposit`, `cash_to_trading`,
/// `trading_to_cash`, `trading_to_trading` or `trading_to_external`;
/// `debitBooked` and `creditBooked` say which side Arca has booked; once the
/// settlement proved the charge, `actualDebitMicro` and
/// `actualNetworkFeeMicro` are set together.
public struct WalletFundingOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: String { operationId }

    public let operationId: String
    public let requestId: String?
    public let kind: String
    public let stage: String
    public let status: String
    public let attention: String?
    public let error: String?
    public let safeToReviewAgain: Bool
    public let amountMicro: String
    public let arrivesMicro: String
    public let debitMicro: String
    public let activationFeeMicro: String
    public let networkFeeMicro: String
    public let actualDebitMicro: String?
    public let actualNetworkFeeMicro: String?
    public let from: WalletEndpoint
    public let to: WalletEndpoint
    public let steps: [WalletMoveStep]
    public let debitBooked: Bool
    public let creditBooked: Bool
    public let cashLeg: WalletCashLeg?
    public let setupOperationId: String?
    public let setupDeadline: Int64?
    public let setupState: String?
    public let consent: WalletMoveConsent?
    public let requirements: [WalletFundingRequirement]
    public let settlement: WalletSettlement?
    public let txHash: String?
    public let createdAt: String
    public let origin: String?
    public let source: WalletDepositSource?
    public let arrival: WalletDepositArrival?
    public let expiresAt: Int64?
    public let sweepOperationId: String?
    public let deferredActivationFeeRaw: String?
    public let deferredActivationFeeState: String?
    public let deferredActivationFeeTrigger: String?

    public init(operationId: String, requestId: String? = nil, kind: String, stage: String, status: String,
                attention: String? = nil, error: String? = nil, safeToReviewAgain: Bool = false,
                amountMicro: String, arrivesMicro: String, debitMicro: String, activationFeeMicro: String = "0",
                networkFeeMicro: String = "0", actualDebitMicro: String? = nil, actualNetworkFeeMicro: String? = nil,
                from: WalletEndpoint, to: WalletEndpoint, steps: [WalletMoveStep] = [], debitBooked: Bool = false,
                creditBooked: Bool = false, cashLeg: WalletCashLeg? = nil, setupOperationId: String? = nil,
                setupDeadline: Int64? = nil, setupState: String? = nil, consent: WalletMoveConsent? = nil,
                requirements: [WalletFundingRequirement] = [], settlement: WalletSettlement? = nil, txHash: String? = nil,
                createdAt: String = "", origin: String? = nil, source: WalletDepositSource? = nil,
                arrival: WalletDepositArrival? = nil, expiresAt: Int64? = nil, sweepOperationId: String? = nil,
                deferredActivationFeeRaw: String? = nil, deferredActivationFeeState: String? = nil,
                deferredActivationFeeTrigger: String? = nil) {
        self.operationId = operationId
        self.requestId = requestId
        self.kind = kind
        self.stage = stage
        self.status = status
        self.attention = attention
        self.error = error
        self.safeToReviewAgain = safeToReviewAgain
        self.amountMicro = amountMicro
        self.arrivesMicro = arrivesMicro
        self.debitMicro = debitMicro
        self.activationFeeMicro = activationFeeMicro
        self.networkFeeMicro = networkFeeMicro
        self.actualDebitMicro = actualDebitMicro
        self.actualNetworkFeeMicro = actualNetworkFeeMicro
        self.from = from
        self.to = to
        self.steps = steps
        self.debitBooked = debitBooked
        self.creditBooked = creditBooked
        self.cashLeg = cashLeg
        self.setupOperationId = setupOperationId
        self.setupDeadline = setupDeadline
        self.setupState = setupState
        self.consent = consent
        self.requirements = requirements
        self.settlement = settlement
        self.txHash = txHash
        self.createdAt = createdAt
        self.origin = origin
        self.source = source
        self.arrival = arrival
        self.expiresAt = expiresAt
        self.sweepOperationId = sweepOperationId
        self.deferredActivationFeeRaw = deferredActivationFeeRaw
        self.deferredActivationFeeState = deferredActivationFeeState
        self.deferredActivationFeeTrigger = deferredActivationFeeTrigger
    }

    private enum CodingKeys: String, CodingKey {
        case operationId, requestId, kind, stage, status, attention, error, safeToReviewAgain
        case amountMicro, arrivesMicro, debitMicro, activationFeeMicro, networkFeeMicro, actualDebitMicro, actualNetworkFeeMicro
        case from, to, steps, debitBooked, creditBooked, cashLeg, setupOperationId, setupDeadline, setupState, consent
        case requirements, settlement, txHash, createdAt, origin, source, arrival, expiresAt, sweepOperationId
        case deferredActivationFeeRaw, deferredActivationFeeState, deferredActivationFeeTrigger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decodeIfPresent(String.self, forKey: .operationId) ?? ""
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId).flatMap { $0.isEmpty ? nil : $0 }
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        attention = try c.decodeIfPresent(String.self, forKey: .attention).flatMap { $0.isEmpty ? nil : $0 }
        error = try c.decodeIfPresent(String.self, forKey: .error).flatMap { $0.isEmpty ? nil : $0 }
        safeToReviewAgain = try c.decodeIfPresent(Bool.self, forKey: .safeToReviewAgain) ?? false
        amountMicro = try c.decodeIfPresent(String.self, forKey: .amountMicro) ?? "0"
        arrivesMicro = try c.decodeIfPresent(String.self, forKey: .arrivesMicro) ?? "0"
        debitMicro = try c.decodeIfPresent(String.self, forKey: .debitMicro) ?? "0"
        activationFeeMicro = try c.decodeIfPresent(String.self, forKey: .activationFeeMicro) ?? "0"
        networkFeeMicro = try c.decodeIfPresent(String.self, forKey: .networkFeeMicro) ?? "0"
        actualDebitMicro = try c.decodeIfPresent(String.self, forKey: .actualDebitMicro)
        actualNetworkFeeMicro = try c.decodeIfPresent(String.self, forKey: .actualNetworkFeeMicro)
        from = try c.decodeIfPresent(WalletEndpoint.self, forKey: .from) ?? WalletEndpoint(kind: "")
        to = try c.decodeIfPresent(WalletEndpoint.self, forKey: .to) ?? WalletEndpoint(kind: "")
        steps = try c.decodeIfPresent([WalletMoveStep].self, forKey: .steps) ?? []
        debitBooked = try c.decodeIfPresent(Bool.self, forKey: .debitBooked) ?? false
        creditBooked = try c.decodeIfPresent(Bool.self, forKey: .creditBooked) ?? false
        cashLeg = try c.decodeIfPresent(WalletCashLeg.self, forKey: .cashLeg)
        setupOperationId = try c.decodeIfPresent(String.self, forKey: .setupOperationId)
        setupDeadline = try c.decodeIfPresent(Int64.self, forKey: .setupDeadline)
        setupState = try c.decodeIfPresent(String.self, forKey: .setupState)
        consent = try c.decodeIfPresent(WalletMoveConsent.self, forKey: .consent)
        requirements = try c.decodeIfPresent([WalletFundingRequirement].self, forKey: .requirements) ?? []
        settlement = try c.decodeIfPresent(WalletSettlement.self, forKey: .settlement)
        txHash = try c.decodeIfPresent(String.self, forKey: .txHash)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        source = try c.decodeIfPresent(WalletDepositSource.self, forKey: .source)
        arrival = try c.decodeIfPresent(WalletDepositArrival.self, forKey: .arrival)
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        sweepOperationId = try c.decodeIfPresent(String.self, forKey: .sweepOperationId)
        deferredActivationFeeRaw = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeRaw)
        deferredActivationFeeState = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeState)
        deferredActivationFeeTrigger = try c.decodeIfPresent(String.self, forKey: .deferredActivationFeeTrigger)
    }

    /// Whether the operation has reached a terminal status.
    public var isTerminal: Bool { status == "succeeded" || status == "failed" || status == "completed" }

    /// Whether the operation is a receiver deposit (money into an account's
    /// own deposit address) or a standing-route or discovered deposit.
    public var isExternalDeposit: Bool { kind == "deposit" }
}

/// `totals.totalMicro = cashMicro + movingMicro + tradingMicro` at every
/// position. `complete` is false when a component has no figure; `current`
/// is false when any figure is not current.
public struct WalletTotals: Codable, Equatable, Sendable {
    public let cashMicro: String
    public let movingMicro: String
    public let tradingMicro: String
    public let totalMicro: String
    public let complete: Bool
    public let current: Bool

    public init(cashMicro: String, movingMicro: String, tradingMicro: String, totalMicro: String, complete: Bool, current: Bool) {
        self.cashMicro = cashMicro
        self.movingMicro = movingMicro
        self.tradingMicro = tradingMicro
        self.totalMicro = totalMicro
        self.complete = complete
        self.current = current
    }
}

/// The whole-wallet accounting envelope, emitted once a verified deposit link
/// registered the source in Cash's accounting fold. Nil amounts are unknown.
public struct WalletAccounting: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let sourceMicro: String?
    public let cashMicro: String
    public let availableCashMicro: String
    public let tradingMicro: String
    public let movingMicro: String
    public let totalMicro: String?
    public let complete: Bool
    public let current: Bool
    public let cashBlock: UInt64
    public let cashBlockHash: String?
}

/// The Cash allocation record moves debit and credit, present once Cash is
/// set up.
public struct WalletCashAccount: Codable, Equatable, Sendable {
    public let arcaId: String
    public let defaultArcaId: String
    public let arcaPath: String
    public let localId: String
    public let accountStatus: String

    private enum CodingKeys: String, CodingKey { case arcaId, defaultArcaId, arcaPath, localId, accountStatus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arcaId = try c.decodeIfPresent(String.self, forKey: .arcaId) ?? ""
        defaultArcaId = try c.decodeIfPresent(String.self, forKey: .defaultArcaId) ?? ""
        arcaPath = try c.decodeIfPresent(String.self, forKey: .arcaPath) ?? ""
        localId = try c.decodeIfPresent(String.self, forKey: .localId) ?? ""
        accountStatus = try c.decodeIfPresent(String.self, forKey: .accountStatus) ?? ""
    }
}

/// The complete wallet at one journal position: Cash, every trading account,
/// money in flight and funding operations. Replace it as a whole; it is never
/// refused for movement in progress. A wallet exists from its funding source,
/// before Cash setup: such a pre-Cash wallet has an empty `boundaryId`, Cash
/// in `setup_required` with zero balances, no accounts and nothing moving.
public struct WalletSnapshot: Codable, Equatable, Sendable {
    public let schema: Int
    public let realmId: String
    public let ownerAddress: String
    public let arcaPath: String
    public let boundaryId: String
    public let cash: WalletAccount
    public let cashTarget: WalletEndpoint
    public let cashAccount: WalletCashAccount?
    public let accounts: [WalletTradingAccount]
    public let moving: [WalletMoving]
    public let operations: [WalletFundingOperation]
    public let totals: WalletTotals
    public let accounting: WalletAccounting?
    public let attention: [String]
    public let watermark: WalletSnapshotWatermark
    public let composedAt: String

    private enum CodingKeys: String, CodingKey {
        case schema, realmId, ownerAddress, arcaPath, boundaryId, cash, cashTarget, cashAccount, accounts, moving
        case operations, totals, accounting, attention, watermark, composedAt
    }

    public init(schema: Int = walletSnapshotSchema, realmId: String, ownerAddress: String, arcaPath: String, boundaryId: String,
                cash: WalletAccount, cashTarget: WalletEndpoint = WalletEndpoint(kind: "cash"), cashAccount: WalletCashAccount? = nil,
                accounts: [WalletTradingAccount], moving: [WalletMoving], operations: [WalletFundingOperation],
                totals: WalletTotals, accounting: WalletAccounting? = nil, attention: [String] = [],
                watermark: WalletSnapshotWatermark, composedAt: String = "") {
        self.schema = schema
        self.realmId = realmId
        self.ownerAddress = ownerAddress
        self.arcaPath = arcaPath
        self.boundaryId = boundaryId
        self.cash = cash
        self.cashTarget = cashTarget
        self.cashAccount = cashAccount
        self.accounts = accounts
        self.moving = moving
        self.operations = operations
        self.totals = totals
        self.accounting = accounting
        self.attention = attention
        self.watermark = watermark
        self.composedAt = composedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        realmId = try c.decodeIfPresent(String.self, forKey: .realmId) ?? ""
        ownerAddress = try c.decodeIfPresent(String.self, forKey: .ownerAddress) ?? ""
        arcaPath = try c.decodeIfPresent(String.self, forKey: .arcaPath) ?? ""
        boundaryId = try c.decodeIfPresent(String.self, forKey: .boundaryId) ?? ""
        cash = try c.decode(WalletAccount.self, forKey: .cash)
        cashTarget = try c.decodeIfPresent(WalletEndpoint.self, forKey: .cashTarget) ?? WalletEndpoint(kind: "cash")
        cashAccount = try c.decodeIfPresent(WalletCashAccount.self, forKey: .cashAccount)
        accounts = try c.decodeIfPresent([WalletTradingAccount].self, forKey: .accounts) ?? []
        moving = try c.decodeIfPresent([WalletMoving].self, forKey: .moving) ?? []
        operations = try c.decodeIfPresent([WalletFundingOperation].self, forKey: .operations) ?? []
        totals = try c.decode(WalletTotals.self, forKey: .totals)
        accounting = try c.decodeIfPresent(WalletAccounting.self, forKey: .accounting)
        attention = try c.decodeIfPresent([String].self, forKey: .attention) ?? []
        watermark = try c.decodeIfPresent(WalletSnapshotWatermark.self, forKey: .watermark) ?? WalletSnapshotWatermark(sequence: 0, revision: 0)
        composedAt = try c.decodeIfPresent(String.self, forKey: .composedAt) ?? ""
    }

    /// The trading account with this `arcaId`, if the snapshot lists it.
    public func account(arcaId: String) -> WalletTradingAccount? {
        accounts.first { $0.arcaId == arcaId }
    }

    /// Whether the snapshot's figures still describe the wallet this one does
    /// (same owner and root) and are at least as new. Older or foreign frames
    /// are ignored by the money watch.
    public func supersedes(_ previous: WalletSnapshot?) -> Bool {
        guard let previous else { return true }
        guard previous.ownerAddress.lowercased() == ownerAddress.lowercased(), previous.arcaPath == arcaPath,
              previous.realmId == realmId else { return false }
        return watermark.sequence >= previous.watermark.sequence
    }
}

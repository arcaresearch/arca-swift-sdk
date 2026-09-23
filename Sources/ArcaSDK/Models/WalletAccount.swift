import Foundation

// The Wallet Account read model (documents/contracts/v9-cash-wallet-integration.md,
// "Wallet Account read model"): one owner-facing wallet — a V9 cash boundary
// plus the external address linked to it — composed by Arca from durable
// records with no chain call. Every money figure is a micro-USDC integer
// string; every figure carries the as-of it was recorded under. Enum values
// are the closed vocabulary shipped as
// backend/libs/arca-go/cashv9/testdata/wallet-account/vocabulary.json and are
// kept as strings here so a value this SDK predates still decodes; the typed
// accessors return nil for one it does not know.

/// The block a figure is valid through, with its hash and time when recorded.
public struct WalletAsOf: Codable, Equatable, Sendable {
    public let block: UInt64
    public let hash: String?
    public let time: String?

    public init(block: UInt64, hash: String? = nil, time: String? = nil) {
        self.block = block
        self.hash = hash
        self.time = time
    }
}

/// Six-decimal integer strings (micro-USDC). `reservedMicro` and
/// `pendingOutMicro` are the same figure seen from two sides (the ledger
/// hold and the owner's "money leaving").
public struct WalletBalances: Codable, Equatable, Sendable {
    public let confirmedMicro: String
    public let availableMicro: String
    public let reservedMicro: String
    public let pendingInMicro: String
    public let pendingOutMicro: String
    public let asOf: WalletAsOf
}

/// The external address linked to the wallet, as the address observer
/// projects it. `balanceMicro` is nil when the projection has no baseline —
/// never "0" as a stand-in for unknown.
public struct WalletSource: Codable, Equatable, Sendable {
    public let address: String
    public let balanceMicro: String?
    public let health: String
    public let completeThroughBlock: UInt64
    public let asOf: WalletAsOf
}

/// The automatic-deposit route and USDC allowance of the linked source on
/// the adapter, as observed on chain. `routeId` is absent when `state` is
/// `off`; `allowanceMicro` is absent only when no baseline has been read.
public struct WalletAutoDeposit: Codable, Equatable, Sendable {
    public let state: String
    public let routeId: String?
    public let allowanceMicro: String?
    public let asOf: WalletAsOf

    /// The typed state, or nil for a value this SDK does not know.
    public var typedState: AutoDepositState? { AutoDepositState(rawValue: state) }
}

/// One owner-started operation in the closed vocabulary.
public struct WalletOperation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let state: String
    public let reason: String?
    public let amountMicro: String
    public let destination: String?
    public let txHash: String?
    public let startedAt: String
    public let updatedAt: String
    public let canRetry: Bool

    public var typedState: WalletOperationState? { WalletOperationState(rawValue: state) }
    public var typedReason: WalletFailureReason? { reason.flatMap(WalletFailureReason.init(rawValue:)) }
}

/// The composed read model. `revision` is the realm's change-journal
/// sequence at composition; the stream resumes from it.
public struct WalletAccount: Codable, Equatable, Sendable {
    public let schema: Int
    public let revision: UInt64
    public let realmId: String
    public let boundaryId: String
    public let ownerAddress: String
    public let depositAddress: String?
    public let source: WalletSource?
    public let walletState: String
    public let attention: [String]
    public let balances: WalletBalances
    public let autoDeposit: WalletAutoDeposit?
    public let operations: [WalletOperation]
    /// Action-proposal attempts awaiting the owner's answer, soonest deadline
    /// first. Nil from servers that predate them.
    public let requirements: [WalletRequirement]?
    /// Explicit deposit links into this boundary; with an active one,
    /// `source` and `autoDeposit` describe its source wallet. Nil when none.
    public var depositLinks: [WalletDepositLink]? = nil

    public var typedWalletState: WalletState? { WalletState(rawValue: walletState) }
}

/// One open action-proposal attempt on the account. `expiresAt` is the signed
/// deadline in unix seconds; past it the attempt cannot be accepted. Read the
/// proposal for its payload.
public struct WalletRequirement: Codable, Equatable, Sendable {
    public let proposalId: String
    public let requirementId: String
    public let attemptId: String
    public let actionKind: String
    public let schemaId: String
    public let variant: String
    public let state: String
    public let expiresAt: Int64
}

/// `walletState` values.
public enum WalletState: String, Codable, CaseIterable, Sendable {
    case setupRequired = "setup_required"
    case settingUp = "setting_up"
    case ready
    case needsAttention = "needs_attention"
    case unavailable
}

/// `operations[].state` values. `awaitingApproval` and `uncertain` are
/// product-layer states Arca never produces itself; they are in the
/// vocabulary so every renderer shares one closed set.
public enum WalletOperationState: String, Codable, CaseIterable, Sendable {
    case awaitingApproval = "awaiting_approval"
    case sending
    case confirming
    case completed
    case failed
    case uncertain
}

/// `operations[].reason` values, present only when `state` is `failed`.
public enum WalletFailureReason: String, Codable, CaseIterable, Sendable {
    case consentExpired = "consent_expired"
    case reverted
    case rejected
    case destinationRefused = "destination_refused"
    case recoveryStarted = "recovery_started"
    case cancelled
    case unknown
}

/// `autoDeposit.state` values.
public enum AutoDepositState: String, Codable, CaseIterable, Sendable {
    case off
    case active
    case needsApproval = "needs_approval"
    case needsAttention = "needs_attention"
}

import Foundation

// MARK: - Provider objects and deposit links
//
// A provider object is an ordinary Arca object (type `provider`) naming one
// account at an external wallet provider — Privy today — at whatever path the
// product chooses. It holds no balance and grants no spending authority. A
// deposit link is a durable relationship from one of its wallets to one Cash
// account through the realm's automatic-deposit adapter.

public struct ProviderEvidenceFacts: Codable, Equatable, Sendable {
    public let kind: String
    public let issuedAt: String
    public let expiresAt: String
    public let keyId: String?
}

public struct ProviderConnection: Codable, Equatable, Sendable {
    /// `unverified` or `verified`.
    public let status: String
    public let checkedAt: String?
    public let evidence: ProviderEvidenceFacts?
}

public struct ProviderState: Codable, Equatable, Sendable {
    public let schema: Int
    public let provider: String
    public let subject: String?
    public let connection: ProviderConnection
}

/// The realm's observation of one address. `balanceMicro` nil means unknown,
/// never zero; a `health` other than `live` means it may be stale.
public struct AddressObservationView: Codable, Equatable, Sendable {
    public let watchId: String
    public let chainId: String
    public let tokenAddress: String
    public let balanceMicro: String?
    public let health: String
    public let completeThroughBlock: UInt64
    public let asOfBlockHash: String?
    public let asOfTime: String?
}

public struct ProviderWalletControl: Codable, Equatable, Sendable {
    public let target: String
    public let relation: String
}

public struct ProviderWalletVerification: Codable, Equatable, Sendable {
    /// `verified`, or `unlinked` when the latest verification no longer lists it.
    public let status: String
    public let verifiedAt: String?
    public let evidenceKind: String?
    public let evidenceIssuedAt: String?
}

public struct ProviderWallet: Codable, Equatable, Sendable, Identifiable {
    public var id: String { walletId }
    public let walletId: String
    public let chainType: String
    public let address: String
    public let walletClientType: String?
    public let providerWalletId: String?
    public let role: String?
    public let verification: ProviderWalletVerification
    public let controls: [ProviderWalletControl]
    public let observation: AddressObservationView?
}

public struct ProviderDetail: Codable, Equatable, Sendable {
    public let objectId: String
    public let path: String
    public let state: ProviderState
    public let wallets: [ProviderWallet]
}

public struct DepositLinkAccountRef: Codable, Equatable, Sendable {
    public let kernel: String
    public let venue: String
    public let localId: String
}

public struct DepositLinkSource: Codable, Equatable, Sendable {
    public let objectId: String
    public let path: String
    public let walletId: String
    public let address: String
}

public struct DepositLinkDestination: Codable, Equatable, Sendable {
    public let objectId: String
    public let path: String
    public let boundaryId: String
    public let account: DepositLinkAccountRef
}

public struct DepositLinkAdapter: Codable, Equatable, Sendable {
    public let address: String
    public let kind: String
    public let runtimeCodeHash: String?
}

public struct DepositLinkRequested: Codable, Equatable, Sendable {
    /// `active` or `revoked` — the application's request, not the chain's state.
    public let state: String
    public let at: String
    public let by: String?
    public let revokeRequestedAt: String?
    public let revokeRequestedBy: String?
}

public struct DepositLinkConsent: Codable, Equatable, Sendable {
    public let permissionVersion: String
    public let nonce: String
    public let allowanceRaw: String
    public let deadline: Int64
}

public struct DepositLinkLimits: Codable, Equatable, Sendable {
    public let allowanceMicro: String?
}

public struct DepositRouteAsOf: Codable, Equatable, Sendable {
    public let block: UInt64
    public let hash: String?
    public let time: String?
}

/// `status`: unwatched, unknown (nothing known), off (known absent), mismatched
/// (forwards elsewhere), active, needs_approval, needs_attention.
public struct DepositRouteObservation: Codable, Equatable, Sendable {
    public let status: String
    public let routeId: String?
    public let account: String?
    public let localId: String?
    public let permissionVersion: UInt64?
    public let allowanceMicro: String?
    public let matchesDestination: Bool
    public let health: String?
    public let asOf: DepositRouteAsOf?
}

public struct DepositLinkOperations: Codable, Equatable, Sendable {
    public let setupOperationId: String?
    public let revokeOperationId: String?
}

/// One link: requested, observed and accepted-operation state side by side.
/// `progress`: in_sync, setup_pending, setup_accepted, revoke_pending,
/// revoke_in_flight or unknown.
public struct DepositLink: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let realmId: String
    public let source: DepositLinkSource
    public let destination: DepositLinkDestination
    public let chainId: String
    public let token: String
    public let adapter: DepositLinkAdapter
    public let requested: DepositLinkRequested
    public let lifetime: String
    public let consent: DepositLinkConsent?
    public let limits: DepositLinkLimits?
    public let observed: DepositRouteObservation
    public let operations: DepositLinkOperations
    public let progress: String
    public let createdAt: String
    public let updatedAt: String
}

/// One explicit deposit link into a Wallet Account's boundary.
public struct WalletDepositLink: Codable, Equatable, Sendable {
    public let linkId: String
    public let sourceObjectId: String
    public let sourceWalletId: String
    public let sourceAddress: String
    public let adapter: String
    /// `active` or `revoked`.
    public let requestedState: String
    /// A ``DepositRouteObservation`` status.
    public let observedStatus: String
}

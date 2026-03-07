import Foundation

// MARK: - Transfer

public struct TransferResponse: Codable, Sendable {
    public let operation: Operation
}

// MARK: - Deposit

public struct InitiateDepositResponse: Codable, Sendable {
    public let operation: Operation
    public let poolAddress: String?
    public let tokenAddress: String?
    public let chain: String?
    public let expiresAt: String?
}

// MARK: - Withdrawal

public struct InitiateWithdrawalResponse: Codable, Sendable {
    public let operation: Operation
    public let txHash: String?
}

// MARK: - Nonce

public struct NonceResponse: Codable, Sendable {
    public let nonce: Int
    public let path: String
}

// MARK: - Snapshot

public struct CanonicalPosition: Codable, Sendable {
    public let id: PositionID
    public let realmId: RealmID
    public let arcaId: ObjectID
    public let market: String
    public let side: String
    public let size: String
    public let leverage: Int
    public let updatedAt: String
}

public struct SnapshotBalancesResponse: Codable, Sendable {
    public let realmId: String
    public let arcaId: String
    public let asOf: String
    public let balances: [ArcaBalance]
    public let positions: [CanonicalPosition]
}

import Foundation

// MARK: - Transfer

public struct TransferFee: Codable, Sendable {
    public let amount: String
    public let denomination: String
}

public struct TransferResponse: Codable, Sendable, OperationResponse {
    public let operation: Operation
    public let fee: TransferFee?

    public func withOperation(_ op: Operation) -> Self {
        .init(operation: op, fee: fee)
    }
}

// MARK: - Fund Account

public struct FundAccountResponse: Codable, Sendable, OperationResponse {
    public let operation: Operation
    public let poolAddress: String?
    public let tokenAddress: String?
    public let chain: String?
    public let expiresAt: String?

    public func withOperation(_ op: Operation) -> Self {
        .init(
            operation: op,
            poolAddress: poolAddress,
            tokenAddress: tokenAddress,
            chain: chain,
            expiresAt: expiresAt
        )
    }
}

// MARK: - Defund Account

public struct DefundAccountResponse: Codable, Sendable, OperationResponse {
    public let operation: Operation
    public let txHash: String?

    public func withOperation(_ op: Operation) -> Self {
        .init(operation: op, txHash: txHash)
    }
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

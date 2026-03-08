import Foundation

// MARK: - Transfers, Deposits, Withdrawals

extension Arca {

    /// Execute a transfer between two Arca objects.
    ///
    /// Settlement is immediate for denominated targets, or async for
    /// targets that require a receiver workflow (e.g. exchange objects).
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - from: Source Arca path
    ///   - to: Target Arca path
    ///   - amount: Amount as decimal string
    public func transfer(
        path: String,
        from: String,
        to: String,
        amount: String
    ) async throws -> TransferResponse {
        let response: TransferResponse = try await client.post("/transfer", body: TransferRequest(
            realmId: realm,
            path: path,
            sourceArcaPath: from,
            targetArcaPath: to,
            amount: amount
        ))
        try throwIfOperationFailed(response.operation)
        return response
    }

    /// Initiate a deposit to a denominated Arca object.
    /// In demo realms, deposits are simulated.
    ///
    /// - Parameters:
    ///   - arcaRef: Target Arca path
    ///   - amount: Amount as decimal string
    ///   - path: Optional operation path for idempotency
    ///   - senderAddress: Optional sender wallet address (for on-chain matching)
    public func deposit(
        arcaRef: String,
        amount: String,
        path: String? = nil,
        senderAddress: String? = nil
    ) async throws -> InitiateDepositResponse {
        let response: InitiateDepositResponse = try await client.post("/deposit", body: DepositRequest(
            realmId: realm,
            arcaPath: arcaRef,
            amount: amount,
            path: path,
            senderAddress: senderAddress
        ))
        try throwIfOperationFailed(response.operation)
        return response
    }

    /// Initiate a withdrawal from a denominated Arca object.
    ///
    /// - Parameters:
    ///   - arcaPath: Source Arca path
    ///   - amount: Amount as decimal string
    ///   - destinationAddress: On-chain destination address (omit to burn in demo mode)
    ///   - path: Optional operation path for idempotency
    public func withdrawal(
        arcaPath: String,
        amount: String,
        destinationAddress: String? = nil,
        path: String? = nil
    ) async throws -> InitiateWithdrawalResponse {
        let response: InitiateWithdrawalResponse = try await client.post("/withdrawal", body: WithdrawalRequest(
            realmId: realm,
            arcaPath: arcaPath,
            amount: amount,
            destinationAddress: destinationAddress ?? "",
            path: path
        ))
        try throwIfOperationFailed(response.operation)
        return response
    }
}

// MARK: - Request Bodies

private struct TransferRequest: Encodable {
    let realmId: String
    let path: String
    let sourceArcaPath: String
    let targetArcaPath: String
    let amount: String
}

private struct DepositRequest: Encodable {
    let realmId: String
    let arcaPath: String
    let amount: String
    let path: String?
    let senderAddress: String?
}

private struct WithdrawalRequest: Encodable {
    let realmId: String
    let arcaPath: String
    let amount: String
    let destinationAddress: String
    let path: String?
}

import Foundation

// MARK: - Transfers, Fund/Defund Account

extension Arca {

    /// Execute a transfer between two Arca objects.
    ///
    /// Settlement is immediate for denominated targets, or async for
    /// targets that require a receiver workflow (e.g. exchange objects).
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
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
    ) -> OperationHandle<TransferResponse> {
        operationHandle { [self] in
            try await client.post("/transfer", body: TransferRequest(
                realmId: realm,
                path: path,
                sourceArcaPath: from,
                targetArcaPath: to,
                amount: amount
            ))
        }
    }

    /// Programmatically fund an Arca object. This is a developer/test tool for
    /// non-production use (testing, competitions, programmatic account seeding).
    /// For production deposit flows, use ``createPaymentLink(type:arcaRef:amount:)``.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - arcaRef: Target Arca path
    ///   - amount: Amount as decimal string
    ///   - path: Optional operation path for idempotency
    ///   - senderAddress: Optional sender wallet address (for on-chain matching)
    public func fundAccount(
        arcaRef: String,
        amount: String,
        path: String? = nil,
        senderAddress: String? = nil
    ) -> OperationHandle<FundAccountResponse> {
        operationHandle { [self] in
            try await client.post("/fund-account", body: FundAccountRequest(
                realmId: realm,
                arcaPath: arcaRef,
                amount: amount,
                path: path,
                senderAddress: senderAddress
            ))
        }
    }

    /// Programmatically withdraw from an Arca object. This is a developer/test tool
    /// for non-production use. For production withdrawal flows, use
    /// ``createPaymentLink(type:arcaRef:amount:)``.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - arcaPath: Source Arca path
    ///   - amount: Amount as decimal string
    ///   - destinationAddress: On-chain destination address (omit to burn in demo mode)
    ///   - path: Optional operation path for idempotency
    public func defundAccount(
        arcaPath: String,
        amount: String,
        destinationAddress: String? = nil,
        path: String? = nil
    ) -> OperationHandle<DefundAccountResponse> {
        operationHandle { [self] in
            try await client.post("/defund-account", body: DefundAccountRequest(
                realmId: realm,
                arcaPath: arcaPath,
                amount: amount,
                destinationAddress: destinationAddress ?? "",
                path: path
            ))
        }
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

private struct FundAccountRequest: Encodable {
    let realmId: String
    let arcaPath: String
    let amount: String
    let path: String?
    let senderAddress: String?
}

private struct DefundAccountRequest: Encodable {
    let realmId: String
    let arcaPath: String
    let amount: String
    let destinationAddress: String
    let path: String?
}

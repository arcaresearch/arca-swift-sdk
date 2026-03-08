import Foundation

// MARK: - Payment Links

extension Arca {

    /// Create a payment link for deposit or withdrawal.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - type: Whether this is a deposit or withdrawal link
    ///   - arcaRef: Target Arca path
    ///   - amount: Amount as decimal string
    ///   - returnUrl: Optional URL to redirect after payment
    ///   - expiresInMinutes: Optional expiration window
    ///   - metadata: Optional key-value metadata
    public func createPaymentLink(
        type: PaymentLinkType,
        arcaRef: String,
        amount: String,
        returnUrl: String? = nil,
        expiresInMinutes: Int? = nil,
        metadata: [String: Any]? = nil
    ) -> OperationHandle<CreatePaymentLinkResponse> {
        let metadataStr: String? = {
            guard let metadata = metadata,
                  let data = try? JSONSerialization.data(withJSONObject: metadata) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }()
        return operationHandle { [self] in
            try await client.post("/payment-links", body: CreatePaymentLinkRequest(
                realmId: realm,
                type: type.rawValue,
                arcaPath: arcaRef,
                amount: amount,
                returnUrl: returnUrl,
                expiresInMinutes: expiresInMinutes,
                metadata: metadataStr
            ))
        }
    }

    /// List payment links, optionally filtered by type and/or status.
    ///
    /// - Parameters:
    ///   - type: Filter by deposit or withdrawal
    ///   - status: Filter by status string
    public func listPaymentLinks(
        type: PaymentLinkType? = nil,
        status: String? = nil
    ) async throws -> PaymentLinkListResponse {
        var query: [String: String] = ["realmId": realm]
        if let type = type { query["type"] = type.rawValue }
        if let status = status { query["status"] = status }
        return try await client.get("/payment-links", query: query)
    }
}

// MARK: - Request Bodies

private struct CreatePaymentLinkRequest: Encodable {
    let realmId: String
    let type: String
    let arcaPath: String
    let amount: String
    let returnUrl: String?
    let expiresInMinutes: Int?
    let metadata: String?
}

import Foundation

public enum PaymentLinkType: String, Codable, Sendable {
    case deposit
    case withdrawal
}

public struct PaymentLinkResponse: Codable, Sendable {
    public let id: String
    public let url: String
    public let token: String?
    public let type: PaymentLinkType
    public let status: String
    public let amount: String
    public let denomination: String
    public let operationId: String
    public let expiresAt: String
    public let returnUrl: String?
    public let createdAt: String
}

public struct CreatePaymentLinkResponse: Codable, Sendable {
    public let paymentLink: PaymentLinkResponse
    public let operation: Operation
}

public struct PaymentLinkListResponse: Codable, Sendable {
    public let paymentLinks: [PaymentLinkResponse]
    public let total: Int
}

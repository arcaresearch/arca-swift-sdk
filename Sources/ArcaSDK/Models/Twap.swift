import Foundation

// MARK: - TWAP Types

public enum TwapStatus: String, Codable, Sendable {
    case active
    case completed
    case cancelled
    case failed
}

public enum TwapType: String, Codable, Sendable {
    case twap
    case dca
}

public struct Twap: Codable, Sendable {
    public let twapId: String
    public let realmId: String
    public let operationId: String
    public let exchangeObjectId: String
    public let exchangeObjectPath: String
    public let simAccountId: String
    public let type: TwapType
    public let coin: String
    public let side: String
    public let totalSize: String?
    public let executedSize: String
    public let executedNotional: String
    public let sliceCount: Int
    public let filledSlices: Int
    public let failedSlices: Int
    public let intervalSeconds: Int
    public let startTime: String
    public let endTime: String?
    public let status: TwapStatus
    public let cancelReason: String?
    public let reduceOnly: Bool
    public let leverage: Int?
    public let slippageBps: Int
    public let randomize: Bool
    public let consecutiveFailures: Int
    public let createdAt: String
    public let updatedAt: String
}

public struct TwapOperationResponse: Codable, Sendable, OperationResponse {
    public let twap: Twap
    public let operation: Operation

    public func withOperation(_ op: Operation) -> Self {
        .init(twap: twap, operation: op)
    }
}

public struct TwapLimits: Sendable {
    public let minSliceNotionalUsd: Double
    public let minIntervalSeconds: Int
    public let maxIntervalSeconds: Int
    public let minDurationMinutes: Int
    public let maxDurationMinutes: Int
    public let minSlippageBps: Int
    public let maxSlippageBps: Int
    public let defaultSlippageBps: Int
    public let defaultIntervalSeconds: Int
    public let maxConcurrentPerObject: Int
}

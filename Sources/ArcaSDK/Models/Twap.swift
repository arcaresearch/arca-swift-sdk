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
    /// Running counter of slices the scanner has dispatched so far. Starts
    /// at 0 and increments once per dispatch. To render `"X of N"` before
    /// the first slice resolves, use ``expectedSliceCount``.
    public let sliceCount: Int
    /// Planned total slice count, computed at create time as
    /// `max(1, durationSeconds / intervalSeconds)`. Stable for the
    /// TWAP's lifetime; use this when displaying progress as `"X / N"`
    /// since ``sliceCount`` is 0 until the first slice dispatches.
    public let expectedSliceCount: Int
    public let filledSlices: Int
    public let failedSlices: Int
    public let intervalSeconds: Int
    /// Echo of the request's `durationMinutes`.
    public let durationMinutes: Int
    public let startTime: String
    public let endTime: String?
    public let status: TwapStatus
    /// High-level discriminator for terminal state:
    /// `"user"`, `"liquidated"`, `"consecutive_failures"`. Set on both
    /// `cancelled` and `failed` TWAPs. Use this for programmatic branching.
    public let cancelReason: String?
    /// Descriptive failure detail captured from the last slice when the
    /// TWAP terminates as `failed` (e.g. `"Slippage cap hit at 1.5%"`,
    /// `"MARKET_DATA_UNAVAILABLE"`). Pair with ``cancelReason`` for UI
    /// surfaces — `cancelReason` is the enum, `failureReason` is the
    /// message.
    public let failureReason: String?
    /// Mid-price snapshot at creation, captured server-side so clients
    /// can render a stable "vs target" delta from slice 1. `nil` when
    /// mid was unavailable at create time (cold cache); fall back to
    /// live mark in that case.
    public let targetPrice: String?
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

/// Universal TWAP constraints + a duration-keyed recommendation curve,
/// returned by ``Arca/getTwapLimits()``. The server is the source of
/// truth; SDKs cache the response for the process lifetime so a single
/// GET on first use covers every subsequent validation.
public struct TwapLimits: Codable, Sendable {
    public let limits: TwapLimitsConfig
    public let recommendation: TwapRecommendationCurve
}

public struct TwapLimitsConfig: Codable, Sendable {
    /// Coarse minimum total size accepted by the create-time validator.
    /// The authoritative per-coin precision lives in the meta cache and
    /// is surfaced through the markets API; this is a lower bound.
    public let minTotalSize: String
    public let maxDurationMinutes: Int
    public let minIntervalSeconds: Int
    public let maxIntervalSeconds: Int
    public let minSlippageBps: Int
    public let maxSlippageBps: Int
    public let defaultIntervalSeconds: Int
    public let defaultSlippageBps: Int
    public let maxConcurrentPerObject: Int
}

public struct TwapRecommendationCurve: Codable, Sendable {
    /// Sorted by `maxDurationMinutes` ascending. Pick the first bucket
    /// whose `maxDurationMinutes` is `>= durationMinutes`; the
    /// corresponding `recommendedIntervalSeconds` produces ~12–30
    /// slices in the common case.
    public let buckets: [TwapRecommendationBucket]
}

public struct TwapRecommendationBucket: Codable, Sendable {
    public let maxDurationMinutes: Int
    public let recommendedIntervalSeconds: Int
}

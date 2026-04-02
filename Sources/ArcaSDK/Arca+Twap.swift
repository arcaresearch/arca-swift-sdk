import Foundation

// MARK: - TWAP Methods

extension Arca {

    /// Start a TWAP (Time-Weighted Average Price) order that executes a total size
    /// over a duration by placing market orders at regular intervals.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key).
    ///   - exchangeId: Exchange Arca object ID.
    ///   - coin: Canonical coin identifier (e.g. `"hl:BTC"`).
    ///   - side: `"BUY"` or `"SELL"`.
    ///   - totalSize: Total size to execute over the duration.
    ///   - durationMinutes: Duration in minutes (1 to 43200).
    ///   - intervalSeconds: Interval between slices in seconds (10 to 3600, default 30).
    ///   - randomize: Add timing jitter to slice placement.
    ///   - reduceOnly: Reduce-only mode.
    ///   - leverage: Leverage multiplier.
    ///   - slippageBps: Max slippage in basis points (10 to 1000, default 300).
    public func placeTwap(
        path: String,
        exchangeId: String,
        coin: String,
        side: OrderSide,
        totalSize: String,
        durationMinutes: Int,
        intervalSeconds: Int? = nil,
        randomize: Bool = false,
        reduceOnly: Bool = false,
        leverage: Int? = nil,
        slippageBps: Int? = nil
    ) -> OperationHandle<TwapOperationResponse> {
        operationHandle { [self] in
            try await client.post("/objects/\(exchangeId)/exchange/twap", body: PlaceTwapRequest(
                realmId: realm,
                path: path,
                coin: coin,
                side: side.rawValue,
                totalSize: totalSize,
                durationMinutes: durationMinutes,
                intervalSeconds: intervalSeconds,
                randomize: randomize,
                reduceOnly: reduceOnly,
                leverage: leverage,
                slippageBps: slippageBps
            ))
        }
    }

    /// Cancel an active TWAP.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - operationId: The parent operation ID of the TWAP.
    public func cancelTwap(
        exchangeId: String,
        operationId: String
    ) -> OperationHandle<TwapOperationResponse> {
        operationHandle { [self] in
            try await client.delete(
                "/objects/\(exchangeId)/exchange/twap/\(operationId)",
                query: ["realmId": realm]
            )
        }
    }

    /// Get TWAP status and progress by its parent operation ID.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - operationId: The parent operation ID of the TWAP.
    public func getTwap(exchangeId: String, operationId: String) async throws -> TwapOperationResponse {
        try await client.get(
            "/objects/\(exchangeId)/exchange/twap/\(operationId)",
            query: ["realmId": realm]
        )
    }

    /// List TWAPs for an exchange object.
    ///
    /// - Parameters:
    ///   - exchangeId: Exchange Arca object ID.
    ///   - activeOnly: If true, only returns active TWAPs.
    public func listTwaps(exchangeId: String, activeOnly: Bool = false) async throws -> [Twap] {
        var query = ["realmId": realm]
        if activeOnly { query["active"] = "true" }
        return try await client.get(
            "/objects/\(exchangeId)/exchange/twaps",
            query: query
        )
    }

    /// Get TWAP limits and constraints for validation before placing a TWAP.
    public var twapLimits: TwapLimits {
        TwapLimits(
            minSliceNotionalUsd: 10,
            minIntervalSeconds: 10,
            maxIntervalSeconds: 3600,
            minDurationMinutes: 1,
            maxDurationMinutes: 43200,
            minSlippageBps: 10,
            maxSlippageBps: 1000,
            defaultSlippageBps: 300,
            defaultIntervalSeconds: 30,
            maxConcurrentPerObject: 5
        )
    }
}

// MARK: - Private Request Types

private struct PlaceTwapRequest: Encodable {
    let realmId: String
    let path: String
    let coin: String
    let side: String
    let totalSize: String
    let durationMinutes: Int
    let intervalSeconds: Int?
    let randomize: Bool
    let reduceOnly: Bool
    let leverage: Int?
    let slippageBps: Int?
}

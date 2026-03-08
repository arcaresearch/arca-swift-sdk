import Foundation

// MARK: - Exchange (Perps) Operations

extension Arca {

    /// Create a Perps Exchange Arca object.
    /// Automatically sets type=exchange and denomination=USD.
    ///
    /// - Parameters:
    ///   - ref: Full Arca path (e.g. `/exchanges/hl1`)
    ///   - exchangeType: Exchange provider (defaults to `hyperliquid`)
    ///   - operationPath: Optional idempotency key
    public func createPerpsExchange(
        ref: String,
        exchangeType: String = "hyperliquid",
        operationPath: String? = nil
    ) async throws -> CreateArcaObjectResponse {
        let metadata = try JSONEncoder().encode(["exchangeType": exchangeType])
        let metadataString = String(data: metadata, encoding: .utf8)

        return try await client.post("/objects", body: CreateExchangeRequest(
            realmId: realm,
            path: ref,
            type: "exchange",
            denomination: "USD",
            metadata: metadataString,
            operationPath: operationPath
        ))
    }

    /// Get exchange account state (equity, margin, positions, orders).
    public func getExchangeState(objectId: String) async throws -> ExchangeState {
        try await client.get("/objects/\(objectId)/exchange/state")
    }

    /// Get active asset trading data: max trade sizes, margin, mark price, fee rate.
    ///
    /// - Parameters:
    ///   - objectId: Exchange Arca object ID
    ///   - coin: Coin/asset (e.g. `BTC`, `ETH`)
    ///   - builderFeeBps: Optional builder fee in tenths of a basis point
    public func getActiveAssetData(
        objectId: String,
        coin: String,
        builderFeeBps: Int? = nil
    ) async throws -> ActiveAssetData {
        var query: [String: String] = ["coin": coin]
        if let bps = builderFeeBps, bps > 0 {
            query["builderFeeBps"] = String(bps)
        }
        return try await client.get("/objects/\(objectId)/exchange/active-asset-data", query: query)
    }

    /// Update leverage for a coin on an exchange object.
    public func updateLeverage(
        objectId: String,
        coin: String,
        leverage: Int
    ) async throws -> UpdateLeverageResponse {
        try await client.post("/objects/\(objectId)/exchange/leverage", body: [
            "coin": coin,
            "leverage": String(leverage),
        ])
    }

    /// Get leverage settings for a coin (or all coins) on an exchange object.
    public func getLeverage(objectId: String, coin: String? = nil) async throws -> [LeverageSetting] {
        var query: [String: String] = [:]
        if let coin = coin { query["coin"] = coin }

        if coin != nil {
            let single: LeverageSetting = try await client.get(
                "/objects/\(objectId)/exchange/leverage", query: query
            )
            return [single]
        }
        return try await client.get("/objects/\(objectId)/exchange/leverage", query: query)
    }

    /// Place an order on an exchange Arca object.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - objectId: Exchange Arca object ID
    ///   - coin: Coin/asset to trade
    ///   - side: Order side (`.buy` or `.sell`)
    ///   - orderType: Order type (`.market` or `.limit`)
    ///   - size: Order size as decimal string
    ///   - szDenom: Size denomination (`.token` or `.usd`, defaults to `.token`)
    ///   - price: Limit price (required for limit orders)
    ///   - leverage: Leverage multiplier (default: 1)
    ///   - reduceOnly: If true, only reduces an existing position
    ///   - timeInForce: Time in force (default: `.gtc`)
    ///   - builderFeeBps: Builder fee in tenths of a basis point
    ///   - feeTargets: Fee routing targets
    public func placeOrder(
        path: String,
        objectId: String,
        coin: String,
        side: OrderSide,
        orderType: OrderType,
        size: String,
        szDenom: SizeDenomination = .token,
        price: String? = nil,
        leverage: Int = 1,
        reduceOnly: Bool = false,
        timeInForce: TimeInForce = .gtc,
        builderFeeBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil
    ) async throws -> OrderOperationResponse {
        let response: OrderOperationResponse = try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
            realmId: realm,
            path: path,
            coin: coin,
            side: side.rawValue,
            orderType: orderType.rawValue,
            size: size,
            szDenom: szDenom.rawValue,
            price: price,
            leverage: leverage,
            reduceOnly: reduceOnly,
            timeInForce: timeInForce.rawValue,
            builderFeeBps: builderFeeBps,
            feeTargets: feeTargets
        ))
        try throwIfOperationFailed(response.operation)
        return response
    }

    /// List orders for an exchange Arca object.
    public func listOrders(objectId: String, status: String? = nil) async throws -> [SimOrder] {
        var query: [String: String] = [:]
        if let status = status { query["status"] = status }
        return try await client.get("/objects/\(objectId)/exchange/orders", query: query)
    }

    /// Get a specific order with its fills.
    public func getOrder(objectId: String, orderId: String) async throws -> SimOrderWithFills {
        try await client.get("/objects/\(objectId)/exchange/orders/\(orderId)")
    }

    /// Cancel an order on an exchange Arca object.
    public func cancelOrder(
        path: String,
        objectId: String,
        orderId: String
    ) async throws -> OrderOperationResponse {
        let response: OrderOperationResponse = try await client.delete(
            "/objects/\(objectId)/exchange/orders/\(orderId)",
            query: ["realmId": realm, "path": path]
        )
        try throwIfOperationFailed(response.operation)
        return response
    }

    /// List positions for an exchange Arca object.
    public func listPositions(objectId: String) async throws -> [SimPosition] {
        try await client.get("/objects/\(objectId)/exchange/positions")
    }

    /// Get market metadata (supported assets).
    public func getMarketMeta() async throws -> SimMetaResponse {
        try await client.get("/exchange/market/meta")
    }

    /// Get current mid prices for all assets.
    public func getMarketMids() async throws -> SimMidsResponse {
        try await client.get("/exchange/market/mids")
    }

    /// Get L2 order book for a specific coin.
    public func getOrderBook(coin: String) async throws -> SimBookResponse {
        try await client.get("/exchange/market/book/\(coin)")
    }

    /// Get OHLCV candle data for a specific coin.
    ///
    /// - Parameters:
    ///   - coin: Asset name (e.g. `BTC`, `ETH`)
    ///   - interval: Candle interval (e.g. `.oneMinute`, `.oneHour`)
    ///   - startTime: Optional start time in epoch milliseconds
    ///   - endTime: Optional end time in epoch milliseconds
    public func getCandles(
        coin: String,
        interval: CandleInterval,
        startTime: Int? = nil,
        endTime: Int? = nil
    ) async throws -> CandlesResponse {
        var query: [String: String] = ["interval": interval.rawValue]
        if let startTime = startTime { query["startTime"] = String(startTime) }
        if let endTime = endTime { query["endTime"] = String(endTime) }
        return try await client.get("/exchange/market/candles/\(coin)", query: query)
    }
}

// MARK: - Exchange Enums

public enum OrderSide: String, Codable, Sendable {
    case buy = "BUY"
    case sell = "SELL"
}

public enum PositionSide: String, Codable, Sendable {
    case long = "LONG"
    case short = "SHORT"
}

public enum OrderType: String, Codable, Sendable {
    case market = "MARKET"
    case limit = "LIMIT"
}

public enum OrderStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case open = "OPEN"
    case partiallyFilled = "PARTIALLY_FILLED"
    case filled = "FILLED"
    case cancelled = "CANCELLED"
    case failed = "FAILED"
}

public enum LeverageType: String, Codable, Sendable {
    case cross
    case isolated
}

public enum SizeDenomination: String, Sendable {
    case token
    case usd
}

public enum TimeInForce: String, Codable, Sendable {
    case gtc = "GTC"
    case ioc = "IOC"
    case alo = "ALO"
}

// MARK: - Request Bodies

private struct CreateExchangeRequest: Encodable {
    let realmId: String
    let path: String
    let type: String
    let denomination: String
    let metadata: String?
    let operationPath: String?
}

private struct PlaceOrderRequest: Encodable {
    let realmId: String
    let path: String
    let coin: String
    let side: String
    let orderType: String
    let size: String
    let szDenom: String
    let price: String?
    let leverage: Int
    let reduceOnly: Bool
    let timeInForce: String
    let builderFeeBps: Int?
    let feeTargets: [FeeTarget]?
}

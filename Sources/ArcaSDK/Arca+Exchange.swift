import Foundation

// MARK: - Exchange (Perps) Operations

extension Arca {

    /// Ensure a Perps Exchange Arca object exists.
    /// Automatically sets type=exchange and denomination=USD.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settle()` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - ref: Full Arca path (e.g. `/exchanges/hl1`)
    ///   - exchangeType: Exchange provider (defaults to `hyperliquid`)
    ///   - operationPath: Optional idempotency key
    public func ensurePerpsExchange(
        ref: String,
        exchangeType: String = "hyperliquid",
        operationPath: String? = nil
    ) -> OperationHandle<CreateArcaObjectResponse> {
        operationHandle { [self] in
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
        try await client.post("/objects/\(objectId)/exchange/leverage", body: UpdateLeverageRequest(
            coin: coin,
            leverage: leverage
        ))
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
    /// Returns an ``OrderHandle`` with order lifecycle methods:
    /// - `try await order.settle()` — wait for placement
    /// - `try await order.filled()` — wait for fill
    /// - `for try await fill in order.fills()` — stream fills
    /// - `order.onFill { fill in ... }` — callback per fill
    /// - `try await order.cancel().settle()` — cancel the order
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - objectId: Exchange Arca object ID
    ///   - coin: Coin/asset to trade
    ///   - side: Order side (`.buy` or `.sell`)
    ///   - orderType: Order type (`.market` or `.limit`)
    ///   - size: Order size as decimal string
    ///   - price: Limit price (required for limit orders)
    ///   - leverage: Optional leverage override. If omitted, uses the account's current per-coin leverage setting.
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
        price: String? = nil,
        leverage: Int? = nil,
        reduceOnly: Bool = false,
        timeInForce: TimeInForce = .gtc,
        builderFeeBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil
    ) -> OrderHandle {
        let inner: OperationHandle<OrderOperationResponse> = operationHandle { [self] in
            try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
                realmId: realm,
                path: path,
                coin: coin,
                side: side.rawValue,
                orderType: orderType.rawValue,
                size: size,
                price: price,
                leverage: leverage,
                reduceOnly: reduceOnly,
                timeInForce: timeInForce.rawValue,
                builderFeeBps: builderFeeBps,
                feeTargets: feeTargets
            ))
        }

        let deps = OrderHandleDeps(
            getOrder: { [self] objId, orderId in
                try await self.getOrder(objectId: objId, orderId: orderId)
            },
            fillEvents: { [self] in
                await self.ws.fillEvents()
            },
            cancelOrder: { [self] cancelPath, objId, orderId in
                self.cancelOrder(path: cancelPath, objectId: objId, orderId: orderId)
            },
            waitForSettlement: { [self] operationId in
                try await self.waitForSettlement(operationId)
            },
            listFills: { [self] objId in
                try await self.listFills(objectId: objId)
            }
        )

        return OrderHandle(
            inner: inner,
            objectId: objectId,
            placementPath: path,
            deps: deps
        )
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
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settle()` to wait
    /// for full settlement.
    public func cancelOrder(
        path: String,
        objectId: String,
        orderId: String
    ) -> OperationHandle<OrderOperationResponse> {
        operationHandle { [self] in
            try await client.delete(
                "/objects/\(objectId)/exchange/orders/\(orderId)",
                query: ["realmId": realm, "path": path]
            )
        }
    }

    /// List positions for an exchange Arca object.
    public func listPositions(objectId: String) async throws -> [SimPosition] {
        try await client.get("/objects/\(objectId)/exchange/positions")
    }

    /// Close an open position (fully or partially) with `reduceOnly` enforced.
    ///
    /// Looks up the current position for the given coin, infers the closing side,
    /// and places a market order sized to close the full position (or the specified
    /// `size` for a partial close). Always sets `reduceOnly: true` so the order
    /// can never accidentally open or increase a position.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - objectId: Exchange Arca object ID
    ///   - coin: Coin in canonical format (e.g. "hl:BTC")
    ///   - size: Partial close size. If nil, closes the full position.
    ///   - timeInForce: Time in force (default: .ioc)
    ///   - builderFeeBps: Builder fee in tenths of a basis point
    ///   - feeTargets: Fee routing targets
    public func closePosition(
        path: String,
        objectId: String,
        coin: String,
        size: String? = nil,
        timeInForce: TimeInForce = .ioc,
        builderFeeBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil
    ) -> OrderHandle {
        let positionFetch = Task { [self] in
            let positions = try await listPositions(objectId: objectId)
            guard let position = positions.first(where: { $0.coin == coin }) else {
                throw ArcaError.notFound(code: "POSITION_NOT_FOUND", message: "No open position for \(coin)", errorId: nil)
            }
            return position
        }

        let inner: OperationHandle<OrderOperationResponse> = operationHandle { [self] in
            let position = try await positionFetch.value
            let closingSide: OrderSide = position.side == .long ? .sell : .buy
            let closeSize: String
            if let requested = size {
                let requestedVal = Double(requested) ?? 0
                let availableVal = Double(position.size) ?? 0
                closeSize = requestedVal > availableVal ? position.size : requested
            } else {
                closeSize = position.size
            }
            return try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
                realmId: realm,
                path: path,
                coin: coin,
                side: closingSide.rawValue,
                orderType: OrderType.market.rawValue,
                size: closeSize,
                price: nil,
                leverage: nil,
                reduceOnly: true,
                timeInForce: timeInForce.rawValue,
                builderFeeBps: builderFeeBps,
                feeTargets: feeTargets
            ))
        }

        let deps = OrderHandleDeps(
            getOrder: { [self] objId, orderId in
                try await self.getOrder(objectId: objId, orderId: orderId)
            },
            fillEvents: { [self] in
                await self.ws.fillEvents()
            },
            cancelOrder: { [self] cancelPath, objId, orderId in
                self.cancelOrder(path: cancelPath, objectId: objId, orderId: orderId)
            },
            waitForSettlement: { [self] operationId in
                try await self.waitForSettlement(operationId)
            },
            listFills: { [self] objId in
                try await self.listFills(objectId: objId)
            }
        )

        return OrderHandle(
            inner: inner,
            objectId: objectId,
            placementPath: path,
            deps: deps
        )
    }

    /// List historical fills (trades) for an exchange Arca object.
    /// Returns paginated fill data with P&L, fees, and resulting position state.
    ///
    /// - Parameters:
    ///   - objectId: Exchange Arca object ID
    ///   - market: Filter by market coin (e.g. `"hl:BTC"`)
    ///   - startTime: Filter fills on or after this timestamp (RFC 3339)
    ///   - endTime: Filter fills on or before this timestamp (RFC 3339)
    ///   - limit: Max fills to return (default 100, max 500)
    ///   - cursor: Cursor for pagination (createdAt of last fill)
    public func listFills(
        objectId: String,
        market: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> FillListResponse {
        var query: [String: String] = [:]
        if let market = market { query["market"] = market }
        if let startTime = startTime { query["startTime"] = startTime }
        if let endTime = endTime { query["endTime"] = endTime }
        if let limit = limit { query["limit"] = String(limit) }
        if let cursor = cursor { query["cursor"] = cursor }
        return try await client.get("/objects/\(objectId)/exchange/fills", query: query)
    }

    /// Get per-market P&L aggregation for an exchange Arca object.
    /// Summarizes realized P&L, total fees, trade count, and volume by market.
    ///
    /// - Parameters:
    ///   - objectId: Exchange Arca object ID
    ///   - startTime: Filter fills on or after this timestamp (RFC 3339)
    ///   - endTime: Filter fills on or before this timestamp (RFC 3339)
    public func tradeSummary(
        objectId: String,
        startTime: String? = nil,
        endTime: String? = nil
    ) async throws -> TradeSummaryResponse {
        var query: [String: String] = [:]
        if let startTime = startTime { query["startTime"] = startTime }
        if let endTime = endTime { query["endTime"] = endTime }
        return try await client.get("/objects/\(objectId)/exchange/trade-summary", query: query)
    }

    /// Get market metadata (supported assets).
    public func getMarketMeta() async throws -> SimMetaResponse {
        try await client.get("/exchange/market/meta")
    }

    /// Get current mid prices for all assets.
    public func getMarketMids() async throws -> SimMidsResponse {
        try await client.get("/exchange/market/mids")
    }

    /// Get 24h ticker data for all assets (volume, price change, funding, delisted status).
    public func getMarketTickers() async throws -> MarketTickersResponse {
        try await client.get("/exchange/market/tickers")
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

    /// Subscribe to real-time mid prices for all assets.
    /// Resolves once the server sends the initial snapshot, so `prices`
    /// is populated on return. Reconnections are handled automatically.
    /// Call `stop()` when done.
    ///
    /// - Parameter exchange: Exchange identifier (default: `"sim"`)
    public func watchPrices(exchange: String = "sim") async throws -> MarketPriceStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let prices = SendableBox<[String: String]>([:])

        let snapshotId = await ws.onSnapshot(channel: "mids") { data in
            let mids = data as? [String: String] ?? [:]
            prices.update { $0 = mids }
            state.update { $0 = .connected }
        }

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                }
            }
        }

        await ws.acquireMids(exchange: exchange)

        let midsStream = await ws.midsEvents()
        let updates = AsyncStream<[String: String]> { continuation in
            let task = Task {
                for await mids in midsStream {
                    prices.update { current in
                        for (key, value) in mids {
                            current[key] = value
                        }
                    }
                    continuation.yield(prices.value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let stream = MarketPriceStream(
            state: state,
            prices: prices,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "mids", id: snapshotId)
                await ws.releaseMids()
            }
        )
        await stream.ready()
        return stream
    }

    /// Subscribe to a live, SDK-derived max order size stream for a coin/side.
    /// Uses ``getExchangeState(_:)`` + ``watchPrices()`` and recomputes on
    /// price or exchange state changes.
    /// Call `stop()` when done.
    ///
    /// - Parameter options: Trading parameters (object, coin, side, leverage, fees).
    public func watchMaxOrderSize(options opts: MaxOrderSizeWatchOptions) async throws -> MaxOrderSizeWatchStream {
        await ws.ensureConnected()

        let streamState = SendableBox<WatchStreamState>(.loading)
        let activeAssetBox = SendableBox<ActiveAssetData?>(nil)

        let priceStream = try await watchPrices()

        let initialExchangeState: ExchangeState
        do {
            initialExchangeState = try await getExchangeState(objectId: opts.objectId)
        } catch {
            await priceStream.stop()
            throw error
        }

        let exchangeStateBox = SendableBox<ExchangeState?>(initialExchangeState)

        func recompute() -> ActiveAssetData? {
            guard let exState = exchangeStateBox.value else { return nil }
            let markStr = priceStream.prices.value[opts.coin]
            let markPx = markStr.flatMap(Double.init) ?? 0
            return deriveActiveAssetData(
                from: exState,
                coin: opts.coin,
                markPx: markPx,
                leverage: opts.leverage,
                side: opts.side,
                builderFeeBps: opts.builderFeeBps,
                szDecimals: opts.szDecimals
            )
        }

        if let initial = recompute() {
            activeAssetBox.update { $0 = initial }
        }

        await ws.acquireChannel(.exchange)

        let exchangeStream = await ws.exchangeEvents()
        let midsUpdates = priceStream.updates

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && streamState.value != .loading {
                    streamState.update { $0 = .reconnecting }
                }
            }
        }

        let updates = AsyncStream<ActiveAssetData> { continuation in
            let exchangeTask = Task {
                for await (state, event) in exchangeStream {
                    guard event.entityId == opts.objectId else { continue }
                    exchangeStateBox.update { $0 = state }
                    if let data = recompute() {
                        activeAssetBox.update { $0 = data }
                        streamState.update { $0 = .connected }
                        continuation.yield(data)
                    }
                }
            }
            let midsTask = Task {
                for await _ in midsUpdates {
                    if let data = recompute() {
                        activeAssetBox.update { $0 = data }
                        streamState.update { $0 = .connected }
                        continuation.yield(data)
                    }
                }
            }
            continuation.onTermination = { _ in
                exchangeTask.cancel()
                midsTask.cancel()
            }
        }

        streamState.update { $0 = .connected }

        let stream = MaxOrderSizeWatchStream(
            state: streamState,
            activeAssetData: activeAssetBox,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await priceStream.stop()
                await ws.releaseChannel(.exchange)
            }
        )
        return stream
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

private struct UpdateLeverageRequest: Encodable {
    let coin: String
    let leverage: Int
}

private struct PlaceOrderRequest: Encodable {
    let realmId: String
    let path: String
    let coin: String
    let side: String
    let orderType: String
    let size: String
    let price: String?
    let leverage: Int?
    let reduceOnly: Bool
    let timeInForce: String
    let builderFeeBps: Int?
    let feeTargets: [FeeTarget]?
}

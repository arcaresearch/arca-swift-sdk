import Foundation

// MARK: - Exchange (Perps) Operations

extension Arca {

    /// Ensure a Perps Exchange Arca object exists. Automatically sets type=exchange.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settle()` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - ref: Full Arca path (e.g. `/exchanges/hl1`)
    ///   - venue: Venue the exchange object trades against — `"hl-sim"`
    ///     (default) provisions a simulated Hyperliquid account; `"hl"`
    ///     provisions a live one.
    ///   - operationPath: Optional idempotency key
    public func ensurePerpsExchange(
        ref: String,
        venue: String = "hl-sim",
        operationPath: String? = nil
    ) -> OperationHandle<CreateArcaObjectResponse> {
        operationHandle { [self] in
            let metadata = try JSONEncoder().encode(["venue": venue])
            let metadataString = String(data: metadata, encoding: .utf8)

            return try await client.post("/objects", body: CreateExchangeRequest(
                realmId: realm,
                path: ref,
                type: "exchange",
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
    ///   - market: Coin/asset in canonical format (e.g. `"hl:0:BTC"`, `"hl:1:SILVER"`)
    ///   - applicationFeeTenthsBps: Optional application fee in tenths of a basis point
    ///   - leverage: Optional leverage override. When provided, the server uses
    ///     this value instead of the stored leverage setting. When `nil`, the
    ///     server reads the leverage from the account's per-coin setting
    ///     (defaulting to 1x if none has been set via ``updateLeverage``).
    public func getActiveAssetData(
        objectId: String,
        market: String,
        applicationFeeTenthsBps: Int? = nil,
        leverage: Int? = nil
    ) async throws -> ActiveAssetData {
        var query: [String: String] = ["market": market]
        if let bps = applicationFeeTenthsBps, bps > 0 {
            query["applicationFeeTenthsBps"] = String(bps)
        }
        if let lev = leverage, lev > 0 {
            query["leverage"] = String(lev)
        }
        return try await client.get("/objects/\(objectId)/exchange/active-asset-data", query: query)
    }

    /// Get per-asset fee rates for an exchange object.
    /// Returns fully-composed taker/maker rates accounting for volume tier, HIP-3 fee scale,
    /// platform fee, and application fee.
    public func getAssetFees(objectId: String, applicationFeeTenthsBps: Int? = nil) async throws -> [AssetFeeEntry] {
        var query: [String: String] = [:]
        if let bps = applicationFeeTenthsBps, bps > 0 {
            query["applicationFeeTenthsBps"] = String(bps)
        }
        return try await client.get("/objects/\(objectId)/exchange/asset-fees", query: query)
    }

    /// Update leverage for a coin on an exchange object.
    public func updateLeverage(
        objectId: String,
        market: String,
        leverage: Int
    ) async throws -> UpdateLeverageResponse {
        try await client.post("/objects/\(objectId)/exchange/leverage", body: UpdateLeverageRequest(
            market: market,
            leverage: leverage
        ))
    }

    /// Add or remove collateral from an isolated-margin position.
    ///
    /// Isolated positions carry their own dedicated collateral and are
    /// liquidated independently of the cross pool. A positive `amount` (decimal
    /// USD string) moves balance into the position, lowering its liquidation
    /// price; a negative `amount` removes collateral, raising it. Removal is
    /// rejected if it would drop the position below its maintenance margin.
    /// Only valid on isolated positions.
    public func updateIsolatedMargin(
        objectId: String,
        market: String,
        amount: String
    ) async throws -> UpdateIsolatedMarginResponse {
        try await client.post("/objects/\(objectId)/exchange/isolated-margin", body: UpdateIsolatedMarginRequest(
            market: market,
            amount: amount
        ))
    }

    /// Switch an asset between cross and isolated margin for an exchange object.
    ///
    /// Rejected on isolated-only (HIP-3) markets and while an open position
    /// exists for the asset — close the position first. Leverage is remembered
    /// per mode, so switching restores the leverage last set for that mode.
    public func setMarginMode(
        objectId: String,
        market: String,
        marginMode: MarginMode
    ) async throws -> SetMarginModeResponse {
        try await client.post("/objects/\(objectId)/exchange/margin-mode", body: SetMarginModeRequest(
            market: market,
            marginMode: marginMode
        ))
    }

    /// Get leverage settings for a coin (or all coins) on an exchange object.
    public func getLeverage(objectId: String, market: String? = nil) async throws -> [LeverageSetting] {
        var query: [String: String] = [:]
        if let market = market { query["market"] = market }

        if market != nil {
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
    ///   - market: Coin/asset to trade
    ///   - side: Order side (`.buy` or `.sell`)
    ///   - orderType: Order type (`.market` or `.limit`)
    ///   - size: Order size as decimal string
    ///   - price: Limit price (required for limit orders)
    ///   - leverage: Optional leverage override. If omitted, uses the account's current per-coin leverage setting.
    ///   - reduceOnly: If true, only reduces an existing position
    ///   - timeInForce: Time in force (default: `.gtc`)
    ///   - applicationFeeTenthsBps: Application fee in tenths of a basis point
    ///   - feeTargets: Fee routing targets
    ///   - isTrigger: If true, this is a trigger (TP/SL) order
    ///   - triggerPx: Trigger price — mark price threshold to activate the order
    ///   - isMarket: If true, execute as market order when triggered; if false, use price as limit
    ///   - tpsl: Take profit (`.takeProfit`) or stop loss (`.stopLoss`)
    ///   - sizeToMax: Marks an *unsized* ("size to max") TP/SL — it carries no fixed quantity and closes the **entire** position when triggered. Leave nil/false for a *sized* TP/SL that closes its fixed `size`. Either way, no TP/SL outlives the position.
    ///   - useMax: When true, the server resolves max order size at execution time. `size` serves as the reference.
    ///   - sizeTolerance: Max allowed downward size adjustment as a fraction (0.01 = 1%). Server may reduce `size` by up to this percentage to fit available margin. Never increases size. Recommended: 0.01 for interactive, 0.02 for retail. Server max: 0.25.
    ///   - maxSizeTolerance: Deprecated — use `sizeTolerance` instead.
    ///   - ocoGroupId: Links this order to the other legs of a TP/SL bracket so a fill on one leg cancels its siblings (one-cancels-the-other). Advisory/unsigned. Usually left nil; `setPositionTpsl` sets it automatically.
    public func placeOrder(
        path: String,
        objectId: String,
        market: String,
        side: OrderSide,
        orderType: OrderType,
        size: String,
        price: String? = nil,
        leverage: Int? = nil,
        reduceOnly: Bool = false,
        timeInForce: TimeInForce = .gtc,
        applicationFeeTenthsBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil,
        isTrigger: Bool? = nil,
        triggerPx: String? = nil,
        isMarket: Bool? = nil,
        tpsl: TpslType? = nil,
        sizeToMax: Bool? = nil,
        useMax: Bool? = nil,
        sizeTolerance: Double? = nil,
        maxSizeTolerance: Double? = nil,
        isolated: Bool? = nil,
        ocoGroupId: String? = nil
    ) -> OrderHandle {
        let effectiveTolerance = sizeTolerance ?? maxSizeTolerance
        let inner: OperationHandle<OrderOperationResponse> = operationHandle { [self] in
            try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
                realmId: realm,
                path: path,
                market: market,
                side: side.rawValue,
                orderType: orderType.rawValue,
                size: size,
                price: price,
                leverage: leverage,
                reduceOnly: reduceOnly,
                timeInForce: timeInForce.rawValue,
                applicationFeeTenthsBps: applicationFeeTenthsBps,
                feeTargets: feeTargets,
                isTrigger: isTrigger,
                triggerPx: triggerPx,
                isMarket: isMarket,
                tpsl: tpsl?.rawValue,
                sizeToMax: sizeToMax,
                useMax: useMax,
                sizeTolerance: effectiveTolerance,
                isolated: isolated == true ? true : nil,
                ocoGroupId: ocoGroupId
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
            modifyOrder: { [self] modifyPath, objId, orderId, newSize in
                self.modifyOrder(path: modifyPath, objectId: objId, orderId: orderId, newSize: newSize)
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
        let response: OrderListResponse = try await client.get("/objects/\(objectId)/exchange/orders", query: query)
        return response.orders
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

    /// Resize a resting order to a new total size.
    ///
    /// Only **sized** orders can be resized: resting limit orders and sized
    /// TP/SL triggers. Unsized ("size to max") TP/SL triggers are rejected by
    /// the venue — they have no size to amend and always close the whole
    /// position. `newSize` is the new total size and must exceed the order's
    /// already-filled quantity. `path` is the per-resize idempotency key.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settle()` to wait
    /// for full settlement.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key); distinct resizes need distinct paths
    ///   - objectId: Exchange Arca object ID
    ///   - orderId: ID of the order to resize
    ///   - newSize: New total order size
    public func modifyOrder(
        path: String,
        objectId: String,
        orderId: String,
        newSize: String
    ) -> OperationHandle<OrderOperationResponse> {
        operationHandle { [self] in
            try await client.patch(
                "/objects/\(objectId)/exchange/orders/\(orderId)",
                body: ModifyOrderBody(realmId: realm, path: path, newSize: newSize)
            )
        }
    }

    /// List positions for an exchange Arca object.
    public func listPositions(objectId: String) async throws -> [SimPosition] {
        let response: PositionListResponse = try await client.get("/objects/\(objectId)/exchange/positions")
        return response.positions
    }

    /// Close an open position (fully or partially) with `reduceOnly` enforced.
    ///
    /// Looks up the current position for the given coin, infers the closing side,
    /// and places a market order sized to close the full position (or the specified
    /// `size` for a partial close). Always sets `reduceOnly: true` so the order
    /// can never accidentally open or increase a position.
    ///
    /// Automatically threads the position's `leverage` into the order body and
    /// sets `isolated: true` for HIP-3 (`onlyIsolated`) markets such as
    /// `hl:1:CL`. Hyperliquid buckets isolated positions by leverage — a close
    /// that doesn't carry `leverage` is rejected by the matching engine.
    /// Pass `isolated` or `leverage` to override the auto-fill.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - objectId: Exchange Arca object ID
    ///   - market: Coin in canonical format (e.g. "hl:0:BTC")
    ///   - size: Partial close size. If nil, closes the full position.
    ///   - timeInForce: Time in force (default: .ioc)
    ///   - applicationFeeTenthsBps: Application fee in tenths of a basis point
    ///   - feeTargets: Fee routing targets
    ///   - isolated: Override `isolated` inference. Defaults to `onlyIsolated`
    ///     from market meta.
    ///   - leverage: Override leverage. Defaults to the position's leverage.
    public func closePosition(
        path: String,
        objectId: String,
        market: String,
        size: String? = nil,
        timeInForce: TimeInForce = .ioc,
        applicationFeeTenthsBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil,
        isolated: Bool? = nil,
        leverage: Int? = nil
    ) -> OrderHandle {
        let positionFetch = Task { [self] in
            let positions = try await listPositions(objectId: objectId)
            guard let position = positions.first(where: { $0.market == market }) else {
                throw ArcaError.notFound(code: "POSITION_NOT_FOUND", message: "No open position for \(market)", errorId: nil)
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

            let effectiveLeverage: Int? = leverage ?? position.leverage
            let effectiveIsolated: Bool
            if let override = isolated {
                effectiveIsolated = override
            } else {
                let meta = try? await self.market(market)
                effectiveIsolated = meta?.onlyIsolated == true
            }

            return try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
                realmId: realm,
                path: path,
                market: market,
                side: closingSide.rawValue,
                orderType: OrderType.market.rawValue,
                size: closeSize,
                price: nil,
                leverage: effectiveLeverage,
                reduceOnly: true,
                timeInForce: timeInForce.rawValue,
                applicationFeeTenthsBps: applicationFeeTenthsBps,
                feeTargets: feeTargets,
                isTrigger: nil,
                triggerPx: nil,
                isMarket: nil,
                tpsl: nil,
                sizeToMax: nil,
                useMax: nil,
                sizeTolerance: nil,
                isolated: effectiveIsolated ? true : nil
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
            modifyOrder: { [self] modifyPath, objId, orderId, newSize in
                self.modifyOrder(path: modifyPath, objectId: objId, orderId: orderId, newSize: newSize)
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

    // MARK: - Position TP/SL (existing positions)

    /// Attach a stop-loss to the open position for `market`.
    ///
    /// By default the trigger is placed *unsized* (`sizeToMax: true`,
    /// `reduceOnly: true`) — when it fires it closes the **entire** live position
    /// regardless of size, and it is cancelled when the position closes. Pass a
    /// positive base-unit `size` for a **sized** partial close (e.g. stop out
    /// half); reduce-only caps it at the live position. The closing side is
    /// inferred from the position (long → sell, short → buy), and `leverage` /
    /// `isolated` are auto-filled
    /// from the position and market meta exactly like ``closePosition(path:objectId:market:size:timeInForce:applicationFeeTenthsBps:feeTargets:isolated:leverage:)``.
    ///
    /// By default any existing stop-loss for the position is replaced; pass
    /// `replace: false` to stack multiple triggers.
    ///
    /// - Parameters:
    ///   - path: Operation path (idempotency key)
    ///   - objectId: Exchange Arca object ID
    ///   - market: Coin in canonical format (e.g. `"hl:0:BTC"`)
    ///   - triggerPx: Mark-price threshold that activates the order
    ///   - size: Sized partial close (base units). Omit for a whole-position (sizeToMax) close.
    ///   - isMarket: Execute as market (default) or limit when triggered
    ///   - limitPrice: Resting limit price when `isMarket == false` (required then)
    ///   - replace: Cancel any existing same-type trigger first (default true)
    ///   - leverage: Override the position's leverage
    ///   - isolated: Override the isolated-margin inference
    ///   - timeInForce: Time in force (default `.gtc`)
    ///   - applicationFeeTenthsBps: Application fee in tenths of a basis point
    ///   - feeTargets: Fee routing targets
    public func setStopLoss(
        path: String,
        objectId: String,
        market: String,
        triggerPx: String,
        size: String? = nil,
        isMarket: Bool? = nil,
        limitPrice: String? = nil,
        replace: Bool = true,
        leverage: Int? = nil,
        isolated: Bool? = nil,
        timeInForce: TimeInForce = .gtc,
        applicationFeeTenthsBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil,
        ocoGroupId: String? = nil
    ) -> OrderHandle {
        setPositionTrigger(
            tpsl: .stopLoss, path: path, objectId: objectId, market: market, triggerPx: triggerPx,
            size: size, isMarket: isMarket, limitPrice: limitPrice, replace: replace, leverage: leverage,
            isolated: isolated, timeInForce: timeInForce,
            applicationFeeTenthsBps: applicationFeeTenthsBps, feeTargets: feeTargets,
            ocoGroupId: ocoGroupId
        )
    }

    /// Attach a take-profit to the open position for `market`. The
    /// position-attached counterpart of ``setStopLoss(path:objectId:market:triggerPx:size:isMarket:limitPrice:replace:leverage:isolated:timeInForce:applicationFeeTenthsBps:feeTargets:ocoGroupId:)``.
    public func setTakeProfit(
        path: String,
        objectId: String,
        market: String,
        triggerPx: String,
        size: String? = nil,
        isMarket: Bool? = nil,
        limitPrice: String? = nil,
        replace: Bool = true,
        leverage: Int? = nil,
        isolated: Bool? = nil,
        timeInForce: TimeInForce = .gtc,
        applicationFeeTenthsBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil,
        ocoGroupId: String? = nil
    ) -> OrderHandle {
        setPositionTrigger(
            tpsl: .takeProfit, path: path, objectId: objectId, market: market, triggerPx: triggerPx,
            size: size, isMarket: isMarket, limitPrice: limitPrice, replace: replace, leverage: leverage,
            isolated: isolated, timeInForce: timeInForce,
            applicationFeeTenthsBps: applicationFeeTenthsBps, feeTargets: feeTargets,
            ocoGroupId: ocoGroupId
        )
    }

    private func setPositionTrigger(
        tpsl: TpslType,
        path: String,
        objectId: String,
        market: String,
        triggerPx: String,
        size: String?,
        isMarket: Bool?,
        limitPrice: String?,
        replace: Bool,
        leverage: Int?,
        isolated: Bool?,
        timeInForce: TimeInForce,
        applicationFeeTenthsBps: Int?,
        feeTargets: [FeeTarget]?,
        ocoGroupId: String?
    ) -> OrderHandle {
        let inner: OperationHandle<OrderOperationResponse> = operationHandle { [self] in
            let isMarketOrder = isMarket ?? true
            if !isMarketOrder, (limitPrice ?? "").isEmpty {
                throw ArcaError.validation(
                    message: "trigger-limit orders require a limitPrice (omit isMarket for a market trigger)",
                    errorId: nil
                )
            }
            let (side, effLeverage, effIsolated) = try await inferPositionCloseParams(
                objectId: objectId, market: market, leverageOverride: leverage, isolatedOverride: isolated
            )
            if replace {
                let existing = try await findPositionTpslOrders(objectId: objectId, market: market, tpsl: tpsl.rawValue)
                for order in existing {
                    _ = try await cancelOrder(
                        path: path + "/replace-" + order.id.rawValue, objectId: objectId, orderId: order.id.rawValue
                    ).submitted
                }
            }
            // A non-empty `size` makes this a sized partial reduce-only trigger
            // (closes that quantity, reduce-only caps it at the live position);
            // an empty size keeps the unsized sizeToMax close of the whole
            // position. `sizeToMax` is omitted (nil) for the sized leg.
            let sized = !(size ?? "").isEmpty
            return try await client.post("/objects/\(objectId)/exchange/orders", body: PlaceOrderRequest(
                realmId: realm,
                path: path,
                market: market,
                side: side.rawValue,
                orderType: isMarketOrder ? OrderType.market.rawValue : OrderType.limit.rawValue,
                size: sized ? size! : "0",
                price: isMarketOrder ? nil : limitPrice,
                leverage: effLeverage,
                reduceOnly: true,
                timeInForce: timeInForce.rawValue,
                applicationFeeTenthsBps: applicationFeeTenthsBps,
                feeTargets: feeTargets,
                isTrigger: true,
                triggerPx: triggerPx,
                isMarket: isMarketOrder,
                tpsl: tpsl.rawValue,
                sizeToMax: sized ? nil : true,
                useMax: nil,
                sizeTolerance: nil,
                isolated: effIsolated ? true : nil,
                ocoGroupId: ocoGroupId
            ))
        }

        return OrderHandle(
            inner: inner,
            objectId: objectId,
            placementPath: path,
            deps: makeOrderHandleDeps()
        )
    }

    /// Attach a stop-loss and/or take-profit to an open position in one call.
    /// At least one of `stopLossPx` / `takeProfitPx` must be provided. Legs are
    /// placed sequentially (SL then TP); a placement failure surfaces
    /// immediately. Returns the handles for the placed legs.
    @discardableResult
    public func setPositionTpsl(
        path: String,
        objectId: String,
        market: String,
        stopLossPx: String? = nil,
        takeProfitPx: String? = nil,
        stopLossSz: String? = nil,
        takeProfitSz: String? = nil,
        isMarket: Bool? = nil,
        replace: Bool = true,
        applicationFeeTenthsBps: Int? = nil,
        feeTargets: [FeeTarget]? = nil,
        ocoGroupId: String? = nil
    ) async throws -> SetPositionTpslResult {
        if (stopLossPx ?? "").isEmpty, (takeProfitPx ?? "").isEmpty {
            throw ArcaError.validation(
                message: "setPositionTpsl requires at least one of stopLossPx or takeProfitPx",
                errorId: nil
            )
        }
        let effectiveFeeBps = applicationFeeTenthsBps
        // One opaque group id links both legs as a true one-cancels-the-other
        // bracket: when either leg fills (even partially) the venue cancels the
        // sibling with cancelReason=sibling_filled. That is the right default
        // for two unsized whole-position legs. But when EITHER leg is sized,
        // auto-OCO is a footgun — a partial fill of the sized leg (e.g. scaling
        // out half via the TP) would cancel the sibling stop protecting the
        // remainder. So we only auto-link when both legs are unsized; a caller
        // who wants sized legs linked passes an explicit ocoGroupId.
        let anySized = !(stopLossSz ?? "").isEmpty || !(takeProfitSz ?? "").isEmpty
        let groupId = ocoGroupId ?? (anySized ? nil : Self.generateOcoGroupId())
        var slHandle: OrderHandle?
        var tpHandle: OrderHandle?
        if let sl = stopLossPx, !sl.isEmpty {
            let handle = setStopLoss(
                path: path + "/sl", objectId: objectId, market: market, triggerPx: sl,
                size: stopLossSz,
                isMarket: isMarket, replace: replace, applicationFeeTenthsBps: effectiveFeeBps, feeTargets: feeTargets,
                ocoGroupId: groupId
            )
            _ = try await handle.submitted
            slHandle = handle
        }
        if let tp = takeProfitPx, !tp.isEmpty {
            let handle = setTakeProfit(
                path: path + "/tp", objectId: objectId, market: market, triggerPx: tp,
                size: takeProfitSz,
                isMarket: isMarket, replace: replace, applicationFeeTenthsBps: effectiveFeeBps, feeTargets: feeTargets,
                ocoGroupId: groupId
            )
            _ = try await handle.submitted
            tpHandle = handle
        }
        return SetPositionTpslResult(stopLoss: slHandle, takeProfit: tpHandle)
    }

    /// Open a position and attach reduce-only TP/SL triggers as a linked
    /// `normalTpsl` bracket — Hyperliquid parity. The entry and its triggers
    /// are submitted as a single signed batch to one operation; one signature
    /// links the legs. The trigger legs **arm only when the entry fills**, and
    /// the venue links them with a shared one-cancels-the-other group so a fill
    /// on one cancels its sibling.
    ///
    /// `normalTpsl` is a **fixed-size parent-order bracket**: each TP/SL child
    /// defaults to the entry's `size` (a `normalTpsl` child is a fixed-size leg
    /// of the parent order, not a whole-position trigger). Pass `takeProfitSz`
    /// / `stopLossSz` (positive base units) for a smaller partial-close child.
    /// For a **whole-position** TP/SL that sizes to the entire live position
    /// (Hyperliquid `positionTpsl`), use ``setStopLoss`` / ``setTakeProfit`` /
    /// ``setPositionTpsl`` instead — a separate trigger-only model with no entry
    /// leg that is not accepted here.
    ///
    /// Returns one ``OrderHandle`` per leg (`entry`, `takeProfit?`,
    /// `stopLoss?`), all backed by the single bracket operation. At least one
    /// of `takeProfitPx` / `stopLossPx` is required. Until the entry fills, a
    /// TP/SL child is not yet a live venue order (no venue order id —
    /// addressable only by its cloid); cancelling it before activation cancels
    /// the parent bracket.
    ///
    /// A single signature links the legs, but this is **not** a globally
    /// all-or-none batch: Hyperliquid only guarantees whole-payload rejection
    /// for pre-validation failures.
    ///
    /// - Note: the venue links a bracket's TP and SL legs as
    ///   one-cancels-the-other, and a fill on either — including a **partial**
    ///   fill of a sized leg — cancels the sibling. So a partial TP combined
    ///   with an SL in the same bracket will cancel that SL when the TP fills.
    ///   To scale out and keep a stop on the remainder, place the partial TP
    ///   separately (``setTakeProfit`` with a `size`) and keep the stop unlinked.
    ///
    /// ```swift
    /// let bracket = try arca.openWithBracket(
    ///     path: "/wallets/main/bracket/btc-1", objectId: id, market: "hl:0:BTC",
    ///     side: .buy, size: "0.01", takeProfitPx: "72000", stopLossPx: "58000"
    /// )
    /// try await bracket.entry.settle()     // bracket placed
    /// _ = try await bracket.entry.filled() // wait for the entry to fill
    /// ```
    public func openWithBracket(
        path: String,
        objectId: String,
        market: String,
        side: OrderSide,
        size: String,
        orderType: OrderType = .market,
        price: String? = nil,
        leverage: Int? = nil,
        isolated: Bool = false,
        timeInForce: TimeInForce = .gtc,
        applicationFeeTenthsBps: Int? = nil,
        takeProfitPx: String? = nil,
        stopLossPx: String? = nil,
        takeProfitSz: String? = nil,
        stopLossSz: String? = nil,
        triggersAreMarket: Bool = true,
        grouping: String = "normalTpsl"
    ) throws -> OpenBracketResult {
        if (takeProfitPx ?? "").isEmpty, (stopLossPx ?? "").isEmpty {
            throw ArcaError.validation(
                message: "openWithBracket requires at least one of takeProfitPx or stopLossPx",
                errorId: nil
            )
        }
        if orderType == .limit, (price ?? "").isEmpty {
            throw ArcaError.validation(message: "a LIMIT entry requires a price", errorId: nil)
        }

        let tif = timeInForce.rawValue
        // The TP/SL legs close the position the entry opens — opposite side.
        let closingSide: OrderSide = side == .buy ? .sell : .buy
        let feeBps = applicationFeeTenthsBps
        let isolatedFlag: Bool? = isolated ? true : nil

        // Build orders[] in request order: entry first, then the trigger legs.
        var orders: [BatchLegBody] = [
            BatchLegBody(
                market: market, side: side.rawValue, orderType: orderType.rawValue, size: size,
                price: (price ?? "").isEmpty ? nil : price, leverage: leverage,
                timeInForce: tif, applicationFeeTenthsBps: feeBps, isolated: isolatedFlag
            )
        ]
        func trigger(_ tpsl: String, _ triggerPx: String, _ sz: String?) -> BatchLegBody {
            // A normalTpsl child is FIXED-SIZE: it defaults to the entry's
            // `size`. An explicit `sz` is a smaller partial-close child. We
            // never send `sizeToMax` here — that is the whole-position
            // `positionTpsl` model, which this endpoint rejects (use
            // setStopLoss / setTakeProfit).
            let childSize = (sz ?? "").isEmpty ? size : sz!
            return BatchLegBody(
                market: market, side: closingSide.rawValue,
                orderType: triggersAreMarket ? OrderType.market.rawValue : OrderType.limit.rawValue,
                size: childSize, reduceOnly: true, timeInForce: tif, applicationFeeTenthsBps: feeBps,
                isTrigger: true, triggerPx: triggerPx, isMarket: triggersAreMarket,
                tpsl: tpsl, sizeToMax: nil, isolated: isolatedFlag
            )
        }
        if let tp = takeProfitPx, !tp.isEmpty { orders.append(trigger("tp", tp, takeProfitSz)) }
        if let sl = stopLossPx, !sl.isEmpty { orders.append(trigger("sl", sl, stopLossSz)) }

        let body = PlaceOrderBatchBody(realmId: realm, path: path, grouping: grouping, orders: orders)

        // One shared batch call: all three handles derive from this single Task,
        // so the HTTP request fires exactly once.
        let batchCall = Task<OrderOperationResponse, Error> { [self] in
            let resp: OrderOperationResponse = try await client.post(
                "/objects/\(objectId)/exchange/orders/batch", body: body
            )
            try throwIfOperationFailed(resp.operation)
            return resp
        }

        let deps = makeOrderHandleDeps()
        // Each leg gets its own OrderHandle backed by the SAME batch operation.
        // We rewrite the operation's outcome to the leg's own order summary
        // (which carries `orderId`) so the handle's orderId resolves to that leg
        // — letting `.filled()` / `.cancel()` target the right order even though
        // all legs share one operation. `tpsl == nil` selects the entry (orders[0]).
        func legHandle(_ tpsl: String?) -> OrderHandle {
            let inner = OperationHandle<OrderOperationResponse>(
                submit: {
                    let resp = try await batchCall.value
                    let outcome = Self.selectLegOutcome(resp.operation.outcome, tpsl: tpsl)
                    return resp.withOperation(resp.operation.withOutcome(outcome))
                },
                waitForSettlement: { [self] operationId in
                    try await self.waitForSettlement(operationId)
                }
            )
            return OrderHandle(inner: inner, objectId: objectId, placementPath: path, deps: deps)
        }

        return OpenBracketResult(
            entry: legHandle(nil),
            takeProfit: (takeProfitPx ?? "").isEmpty ? nil : legHandle("tp"),
            stopLoss: (stopLossPx ?? "").isEmpty ? nil : legHandle("sl")
        )
    }

    /// Pick one leg's order summary out of a bracket operation's outcome and
    /// return it as a JSON string (carrying that leg's `orderId`). `tpsl == nil`
    /// selects the entry (`orders[0]`). Falls back to the whole outcome when the
    /// shape is unexpected so handle resolution still has something to read.
    private static func selectLegOutcome(_ outcome: String?, tpsl: String?) -> String? {
        guard let raw = outcome, let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legs = dict["orders"] as? [[String: Any]], !legs.isEmpty
        else { return outcome }
        let leg: [String: Any]?
        if let tpsl = tpsl {
            leg = legs.first { ($0["tpsl"] as? String) == tpsl }
        } else {
            leg = legs.first
        }
        guard let chosen = leg,
              let legData = JSONSafe.data(from: chosen),
              let legStr = String(data: legData, encoding: .utf8)
        else { return outcome }
        return legStr
    }

    /// Mint a fresh opaque id that links the legs of a TP/SL bracket as
    /// one-cancels-the-other. The id is advisory and only needs to be unique
    /// within a single account's live order set, so a random UUID is
    /// sufficient.
    static func generateOcoGroupId() -> String {
        "oco_\(UUID().uuidString)"
    }

    /// Cancel resting unsized (sizeToMax) trigger orders for `market`. `tpsl`
    /// narrows the clear to a single leg; `nil` clears both. Returns the orders
    /// that were targeted for cancellation.
    @discardableResult
    public func clearPositionTpsl(
        path: String,
        objectId: String,
        market: String,
        tpsl: TpslType? = nil
    ) async throws -> [SimOrder] {
        let existing = try await findPositionTpslOrders(objectId: objectId, market: market, tpsl: tpsl?.rawValue)
        for order in existing {
            _ = try await cancelOrder(
                path: path + "/" + order.id.rawValue, objectId: objectId, orderId: order.id.rawValue
            ).submitted
        }
        return existing
    }

    /// Look up the open position for `market` and derive the closing side,
    /// leverage, and isolated flag needed by a reduce-only close/trigger order.
    /// Optional overrides win over the inferred values.
    private func inferPositionCloseParams(
        objectId: String,
        market: String,
        leverageOverride: Int?,
        isolatedOverride: Bool?
    ) async throws -> (OrderSide, Int, Bool) {
        let positions = try await listPositions(objectId: objectId)
        guard let position = positions.first(where: { $0.market == market }) else {
            throw ArcaError.notFound(code: "POSITION_NOT_FOUND", message: "No open position for \(market)", errorId: nil)
        }
        let side: OrderSide = position.side == .long ? .sell : .buy
        let leverage = leverageOverride ?? position.leverage
        let isolated: Bool
        if let override = isolatedOverride {
            isolated = override
        } else if let meta = try? await self.market(market) {
            if let modes = meta.marginModes, !modes.isEmpty {
                isolated = modes.count == 1 && modes.first == "isolated"
            } else {
                isolated = meta.onlyIsolated
            }
        } else {
            isolated = false
        }
        return (side, leverage, isolated)
    }

    /// Return resting unsized (sizeToMax) trigger orders for `market`, optionally
    /// narrowed to a single tp/sl leg.
    private func findPositionTpslOrders(
        objectId: String,
        market: String,
        tpsl: String?
    ) async throws -> [SimOrder] {
        let orders = try await listOrders(objectId: objectId, status: OrderStatus.waitingForTrigger.rawValue)
        return orders.filter {
            $0.market == market
                && $0.sizeToMax == true
                && (tpsl == nil || $0.tpsl == tpsl)
        }
    }

    private func makeOrderHandleDeps() -> OrderHandleDeps {
        OrderHandleDeps(
            getOrder: { [self] objId, orderId in
                try await self.getOrder(objectId: objId, orderId: orderId)
            },
            fillEvents: { [self] in
                await self.ws.fillEvents()
            },
            cancelOrder: { [self] cancelPath, objId, orderId in
                self.cancelOrder(path: cancelPath, objectId: objId, orderId: orderId)
            },
            modifyOrder: { [self] modifyPath, objId, orderId, newSize in
                self.modifyOrder(path: modifyPath, objectId: objId, orderId: orderId, newSize: newSize)
            },
            waitForSettlement: { [self] operationId in
                try await self.waitForSettlement(operationId)
            },
            listFills: { [self] objId in
                try await self.listFills(objectId: objId)
            }
        )
    }

    /// List historical fills (trades) for an exchange Arca object.
    /// Returns paginated fill data with P&L, fees, and resulting position state.
    ///
    /// - Parameters:
    ///   - objectId: Exchange Arca object ID
    ///   - market: Filter by market coin (e.g. `"hl:0:BTC"`)
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

    /// Look up a single market by its **exact canonical market ID**
    /// (e.g. `"hl:0:BTC"`, `"hl:1:TSLA"`).
    ///
    /// This is an exact-id lookup — pass the `name` field of a ``Market``, not a
    /// bare symbol like `"BTC"`. To go from a human symbol to its market(s), use
    /// ``resolveMarkets(_:exchange:dex:)`` / ``resolveMarketOrThrow(_:exchange:dex:)``.
    /// The market id is the readable `{exchange}:{dexIndex}:{symbol}` form
    /// (for example `"hl:0:BTC"`).
    ///
    /// Lazily fetches and caches market metadata on first call. Subsequent
    /// calls return from cache without a network request.
    ///
    /// ```swift
    /// let btc = try await arca.market("hl:0:BTC")
    /// print(btc?.symbol)       // "BTC"
    /// print(btc?.displayName)  // nil or "Bitcoin"
    /// print(btc?.logoUrl)      // "https://...-128.webp" (default 128px)
    /// print(btc?.logoSources?.first?.width) // 256
    /// ```
    ///
    /// - Parameter id: Canonical market ID (the `name` field on ``Market``).
    /// - Returns: The matching ``Market``, or `nil` if not found.
    public func market(_ id: String) async throws -> Market? {
        let map = try await ensureMetaLoaded()
        return map[id]
    }

    /// Resolve a human **symbol** (e.g. `"BTC"`, `"TSLA"`) to the market(s) that
    /// carry it, returning an **array** because one symbol can legitimately map
    /// to many markets across exchanges and HIP-3 dexes (e.g. a native `BTC` and
    /// a builder-deployed `BTC` on a different dex).
    ///
    /// This never fails silently: an empty array is an explicit "no market has
    /// this symbol", not a guess. Match is **exact and case-sensitive** on the
    /// ``Market/symbol`` field (`"kSHIB"` ≠ `"KSHIB"`). Narrow ambiguous symbols
    /// with the optional `exchange` / `dex` filters.
    ///
    /// For the "I expect exactly one" case, use ``resolveMarketOrThrow(_:exchange:dex:)``.
    /// If you already hold a canonical id, use ``market(_:)`` instead. The market
    /// id is the readable `{exchange}:{dexIndex}:{symbol}` form (e.g. `"hl:0:BTC"`).
    ///
    /// ```swift
    /// let all = try await arca.resolveMarkets("BTC")                 // every BTC market
    /// let hlOnly = try await arca.resolveMarkets("BTC", exchange: "hl")
    /// let tsla = try await arca.resolveMarkets("TSLA", dex: "xyz")
    /// ```
    ///
    /// - Parameters:
    ///   - symbol: Display symbol to resolve (the `symbol` field on ``Market``).
    ///   - exchange: When non-nil, only markets whose `exchange` equals this value match.
    ///   - dex: When non-nil, only markets whose `dex` equals this value match.
    /// - Returns: All matching markets; an empty array when none match.
    public func resolveMarkets(
        _ symbol: String,
        exchange: String? = nil,
        dex: String? = nil
    ) async throws -> [Market] {
        let map = try await ensureMetaLoaded()
        var out: [Market] = []
        for m in map.values {
            if m.symbol != symbol { continue }
            if let exchange = exchange, m.exchange != exchange { continue }
            if let dex = dex, m.dex != dex { continue }
            out.append(m)
        }
        return out
    }

    /// Resolve a human **symbol** to the single market that carries it, throwing
    /// when the result is not exactly one.
    ///
    /// Use this when your code assumes a symbol is unambiguous (often after
    /// narrowing with `exchange` / `dex`). Throws an ``ArcaError/validation(message:errorId:)``
    /// when zero markets match (so a typo never silently no-ops) and when more
    /// than one matches (so an ambiguous symbol never silently picks the wrong
    /// one). The market id is the readable `{exchange}:{dexIndex}:{symbol}` form
    /// (e.g. `"hl:0:BTC"`).
    ///
    /// ```swift
    /// let btc = try await arca.resolveMarketOrThrow("BTC", exchange: "hl")
    /// _ = arca.placeOrder(path: path, objectId: objectId, market: btc.name, ...)
    /// ```
    ///
    /// - Parameters:
    ///   - symbol: Display symbol to resolve (the `symbol` field on ``Market``).
    ///   - exchange: Optional exchange filter, forwarded to ``resolveMarkets(_:exchange:dex:)``.
    ///   - dex: Optional dex filter, forwarded to ``resolveMarkets(_:exchange:dex:)``.
    /// - Returns: The single matching ``Market``.
    /// - Throws: ``ArcaError/validation(message:errorId:)`` when zero or more than one market matches.
    public func resolveMarketOrThrow(
        _ symbol: String,
        exchange: String? = nil,
        dex: String? = nil
    ) async throws -> Market {
        let matches = try await resolveMarkets(symbol, exchange: exchange, dex: dex)
        let filters: String
        if exchange != nil || dex != nil {
            var parts: [String] = []
            if let exchange = exchange { parts.append("exchange: \(exchange)") }
            if let dex = dex { parts.append("dex: \(dex)") }
            filters = " (filters: \(parts.joined(separator: ", ")))"
        } else {
            filters = ""
        }
        if matches.isEmpty {
            throw ArcaError.validation(
                message: "No market found for symbol \"\(symbol)\"\(filters). Pass a canonical id "
                    + "to market(_:), or list candidates with resolveMarkets(\"\(symbol)\").",
                errorId: nil
            )
        }
        if matches.count > 1 {
            let names = matches.map { $0.name }.joined(separator: ", ")
            throw ArcaError.validation(
                message: "Symbol \"\(symbol)\"\(filters) is ambiguous — \(matches.count) markets "
                    + "match: \(names). Narrow with exchange / dex, or call market(_:) with the "
                    + "exact canonical id.",
                errorId: nil
            )
        }
        return matches[0]
    }

    /// Eagerly fetch and cache market metadata.
    ///
    /// Call at app startup to avoid latency on the first ``market(_:)`` call.
    /// Safe to call multiple times — skips the fetch if already cached.
    public func preloadMarketMeta() async throws {
        _ = try await ensureMetaLoaded()
    }

    /// Force re-fetch market metadata, replacing the cache.
    ///
    /// Use after a new asset is listed or when metadata may have changed.
    public func refreshMarketMeta() async throws {
        _ = try await ensureMetaLoaded(forceRefresh: true)
    }

    /// Venue-wide order limits (e.g. the $10 minimum notional). Static; no
    /// network call. Reduce-only orders and unsized (`sizeToMax`) triggers are
    /// exempt so dust positions can always be closed.
    public func getOrderLimits() -> OrderLimits {
        OrderLimits(minOrderNotionalUsd: 10)
    }

    /// Compute the minimum valid order size for a market at a given price.
    ///
    /// The venue enforces a minimum order **notional** (`size * price`), but a
    /// UI that takes a size in base-asset units needs that expressed as a
    /// minimum **size**. This converts the market's `minOrderNotionalUsd` into a
    /// size, rounded **up** to the market's `szDecimals` precision so the result
    /// always clears the floor. Reduce-only orders and unsized (`sizeToMax`)
    /// triggers are exempt (any positive size down to one tick).
    ///
    /// - Parameters:
    ///   - market: The resolved ``Market``.
    ///   - price: Reference price (mark price for market orders, limit price for limit orders).
    public func getMinOrderSize(
        market: Market,
        price: Double,
        reduceOnly: Bool = false,
        isTrigger: Bool = false,
        sizeToMax: Bool = false
    ) -> MinOrderSize {
        computeMinOrderSize(
            szDecimals: market.szDecimals,
            minNotionalUsd: market.minOrderNotionalUsd ?? getOrderLimits().minOrderNotionalUsd,
            price: price,
            reduceOnly: reduceOnly,
            isTrigger: isTrigger,
            sizeToMax: sizeToMax
        )
    }

    /// Compute the minimum valid order size for a market id at a given price.
    /// Fetches (and caches) market metadata via ``market(_:)``; falls back to
    /// the venue-wide ``getOrderLimits()`` default when the market is unknown or
    /// carries no `minOrderNotionalUsd`.
    public func getMinOrderSize(
        marketId: String,
        price: Double,
        reduceOnly: Bool = false,
        isTrigger: Bool = false,
        sizeToMax: Bool = false
    ) async throws -> MinOrderSize {
        let m = try await market(marketId)
        return computeMinOrderSize(
            szDecimals: m?.szDecimals ?? 5,
            minNotionalUsd: m?.minOrderNotionalUsd ?? getOrderLimits().minOrderNotionalUsd,
            price: price,
            reduceOnly: reduceOnly,
            isTrigger: isTrigger,
            sizeToMax: sizeToMax
        )
    }

    /// Validate an order size against the market's minimum before placing an
    /// order. Advisory only — the server (sim-exchange and Hyperliquid) remains
    /// the authoritative enforcement point; use this to gate a UI.
    public func validateOrderSize(
        market: Market,
        price: Double,
        size: Double,
        reduceOnly: Bool = false,
        isTrigger: Bool = false,
        sizeToMax: Bool = false
    ) -> OrderSizeValidation {
        let min = getMinOrderSize(
            market: market, price: price,
            reduceOnly: reduceOnly, isTrigger: isTrigger, sizeToMax: sizeToMax
        )
        return checkOrderSize(min: min, price: price, size: size, reduceOnly: reduceOnly, isTrigger: isTrigger, sizeToMax: sizeToMax)
    }

    /// Validate an order size for a market id. Fetches market metadata as needed.
    public func validateOrderSize(
        marketId: String,
        price: Double,
        size: Double,
        reduceOnly: Bool = false,
        isTrigger: Bool = false,
        sizeToMax: Bool = false
    ) async throws -> OrderSizeValidation {
        let min = try await getMinOrderSize(
            marketId: marketId, price: price,
            reduceOnly: reduceOnly, isTrigger: isTrigger, sizeToMax: sizeToMax
        )
        return checkOrderSize(min: min, price: price, size: size, reduceOnly: reduceOnly, isTrigger: isTrigger, sizeToMax: sizeToMax)
    }

    private func computeMinOrderSize(
        szDecimals: Int,
        minNotionalUsd: Double,
        price: Double,
        reduceOnly: Bool,
        isTrigger: Bool,
        sizeToMax: Bool
    ) -> MinOrderSize {
        let factor = pow(10.0, Double(szDecimals))
        let tick = 1 / factor

        // Reduce-only and unsized trigger orders are exempt from the notional
        // minimum — any positive size down to one tick is allowed.
        if reduceOnly || (isTrigger && sizeToMax) {
            return MinOrderSize(minSize: formatSizeToDecimals(tick, szDecimals), minNotionalUsd: 0)
        }

        guard price.isFinite, price > 0 else {
            return MinOrderSize(minSize: formatSizeToDecimals(tick, szDecimals), minNotionalUsd: minNotionalUsd)
        }

        // Round up to szDecimals precision. Subtract a tiny epsilon on the
        // scaled value so floating-point noise on an exact boundary (e.g.
        // 10 / 100000) doesn't overshoot by a full tick.
        var minSizeNum = (minNotionalUsd / price * factor - 1e-6).rounded(.up) / factor
        if minSizeNum < tick { minSizeNum = tick }
        return MinOrderSize(minSize: formatSizeToDecimals(minSizeNum, szDecimals), minNotionalUsd: minNotionalUsd)
    }

    private func checkOrderSize(
        min: MinOrderSize,
        price: Double,
        size: Double,
        reduceOnly: Bool,
        isTrigger: Bool,
        sizeToMax: Bool
    ) -> OrderSizeValidation {
        guard size.isFinite, size > 0 else {
            return OrderSizeValidation(ok: false, reason: "Order size must be a positive number.", minSize: min.minSize, minNotionalUsd: min.minNotionalUsd)
        }

        // Exempt orders (reduce-only / unsized trigger) only need a positive size.
        if reduceOnly || (isTrigger && sizeToMax) {
            return OrderSizeValidation(ok: true, reason: nil, minSize: min.minSize, minNotionalUsd: min.minNotionalUsd)
        }

        let minSizeNum = Double(min.minSize) ?? 0
        if size < minSizeNum {
            let notional = price.isFinite ? size * price : 0
            let notionalStr = String(format: "%.2f", notional)
            let minNotionalStr = formatNotionalUsd(min.minNotionalUsd)
            return OrderSizeValidation(
                ok: false,
                reason: "Order notional $\(notionalStr) is below venue minimum of $\(minNotionalStr). Minimum size is \(min.minSize).",
                minSize: min.minSize,
                minNotionalUsd: min.minNotionalUsd
            )
        }

        return OrderSizeValidation(ok: true, reason: nil, minSize: min.minSize, minNotionalUsd: min.minNotionalUsd)
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
    public func getOrderBook(market: String) async throws -> SimBookResponse {
        try await client.get("/exchange/market/book/\(market)")
    }

    /// Get OHLCV candle data for a specific coin.
    ///
    /// When `candleCdnBaseUrl` is configured and the interval is not `15s`,
    /// fetches from CDN chunks for historical data with REST API fallback.
    ///
    /// - Parameters:
    ///   - market: Canonical coin ID (e.g. `hl:0:BTC`, `hl:0:ETH`)
    ///   - interval: Candle interval (e.g. `.oneMinute`, `.oneHour`)
    ///   - startTime: Optional start time in epoch milliseconds
    ///   - endTime: Optional end time in epoch milliseconds
    ///   - skipBackfill: When true, the server returns only cached data without
    ///     waiting for synchronous Hyperliquid backfill. Use for fast initial renders.
    public func getCandles(
        market: String,
        interval: CandleInterval,
        startTime: Int? = nil,
        endTime: Int? = nil,
        skipBackfill: Bool = false
    ) async throws -> CandlesResponse {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let dur = interval.milliseconds
        let effectiveEnd = endTime ?? (nowMs / dur * dur)
        let key = buildCacheKey("candles", [
            "market": market,
            "interval": interval.rawValue,
            "startTime": startTime.map(String.init),
            "endTime": String(effectiveEnd),
        ])
        if let cached: CandlesResponse = historyCache.get(key) {
            return cached
        }

        try Task.checkCancellation()

        if let cdnBase = candleCdnBaseUrl, interval != .fifteenSeconds,
           let start = startTime {
            let end = effectiveEnd
            let candles = try await CandleCDN.fetchCandlesFromCDN(
                baseUrl: cdnBase,
                market: market,
                interval: interval,
                startMs: start,
                endMs: end,
                logger: log,
                apiFallback: { [client] s, e in
                    var q: [String: String] = ["interval": interval.rawValue]
                    q["startTime"] = String(s)
                    q["endTime"] = String(e)
                    if skipBackfill { q["skipBackfill"] = "true" }
                    let resp: CandlesResponse = try await client.get("/exchange/market/candles/\(market)", query: q)
                    return resp.candles
                }
            )
            let result = CandlesResponse(market: market, interval: interval.rawValue, candles: candles)
            if !candles.isEmpty {
                historyCache.set(key, value: result)
            }
            return result
        }

        var query: [String: String] = ["interval": interval.rawValue]
        if let startTime = startTime { query["startTime"] = String(startTime) }
        if let endTime = endTime { query["endTime"] = String(endTime) }
        if skipBackfill { query["skipBackfill"] = "true" }
        let result: CandlesResponse = try await client.get("/exchange/market/candles/\(market)", query: query)
        historyCache.set(key, value: result)
        return result
    }

    /// Get open-interest + 24h-notional-volume history for a market.
    ///
    /// Each bar tracks open interest (OHLC over the bucket, base-asset units)
    /// plus the rolling 24h notional volume (`ntlVlm`, USD) and last mark price
    /// (`mark`) at the bucket close; USD OI ≈ `oiClose * mark`. `market` must be
    /// a canonical coin id (e.g. `hl:0:BTC`). Deep history (~1 year) is seeded
    /// from a one-time 0xArchive backfill (`s == "0xa"`).
    ///
    /// - Parameters:
    ///   - market: Canonical coin ID (e.g. `hl:0:BTC`)
    ///   - interval: OI interval (e.g. `.oneMinute`, `.oneHour`)
    ///   - startTime: Optional start time in epoch milliseconds
    ///   - endTime: Optional end time in epoch milliseconds
    public func getOIHistory(
        market: String,
        interval: CandleInterval,
        startTime: Int? = nil,
        endTime: Int? = nil
    ) async throws -> OIHistoryResponse {
        let key = buildCacheKey("oiHistory", [
            "market": market,
            "interval": interval.rawValue,
            "startTime": startTime.map(String.init),
            "endTime": endTime.map(String.init),
        ])
        if let cached: OIHistoryResponse = historyCache.get(key) {
            return cached
        }
        try Task.checkCancellation()
        var query: [String: String] = ["interval": interval.rawValue]
        if let startTime = startTime { query["startTime"] = String(startTime) }
        if let endTime = endTime { query["endTime"] = String(endTime) }
        let result: OIHistoryResponse = try await client.get("/exchange/market/oi/\(market)", query: query)
        if !result.bars.isEmpty {
            historyCache.set(key, value: result)
        }
        return result
    }

    /// Get market-wide SETTLED funding-rate history for a market.
    ///
    /// Returns the venue's real settlement series — each observation carries the
    /// settlement time (`t`, Unix ms), the settled `fundingRate`, and the
    /// `premium` — in chronological order. This is distinct from the
    /// account-scoped funding *payments* streamed by ``watchFunding(objectId:)``;
    /// these are the market-wide rates that drive those payments. `market` must
    /// be a canonical market id (e.g. `hl:0:BTC`, `hl:1:TSLA`); HIP-3 markets are
    /// supported where history exists. Funding is an event series, so there is
    /// no interval. The default window is the trailing 7 days; the documented
    /// maximum window is 30 days. Values are settled rates, never predicted —
    /// read the ticker's `funding` + `nextFundingTime` for the current/predicted
    /// rate.
    ///
    /// - Parameters:
    ///   - market: Canonical market ID (e.g. `hl:0:BTC`)
    ///   - startTime: Optional start time in epoch milliseconds
    ///   - endTime: Optional end time in epoch milliseconds
    public func getFundingHistory(
        market: String,
        startTime: Int? = nil,
        endTime: Int? = nil
    ) async throws -> FundingHistoryResponse {
        let key = buildCacheKey("fundingHistory", [
            "market": market,
            "startTime": startTime.map(String.init),
            "endTime": endTime.map(String.init),
        ])
        if let cached: FundingHistoryResponse = historyCache.get(key) {
            return cached
        }
        try Task.checkCancellation()
        var query: [String: String] = [:]
        if let startTime = startTime { query["startTime"] = String(startTime) }
        if let endTime = endTime { query["endTime"] = String(endTime) }
        let result: FundingHistoryResponse = try await client.get("/exchange/market/funding/\(market)", query: query)
        if !result.funding.isEmpty {
            historyCache.set(key, value: result)
        }
        return result
    }

    /// Get sparkline close-price arrays for all tracked coins in a single request.
    /// Returns a map of coin name to an array of recent close prices at the
    /// 24 hourly close prices. Sparkline data is pre-computed every ~5 minutes;
    /// for real-time prices use ``watchPrices(exchange:)``.
    ///
    /// The `interval` and `points` parameters are accepted for backward
    /// compatibility but ignored — sparklines always return 24 hourly close prices.
    public func getSparklines(
        interval: CandleInterval = .oneHour,
        points: Int = 24
    ) async throws -> SparklinesResponse {
        return try await client.get("/exchange/market/sparklines")
    }

    /// Subscribe to real-time mid prices for all assets.
    /// Resolves once the server sends the initial snapshot, so `prices`
    /// is populated on return. Reconnections are handled automatically.
    /// Call `stop()` when done.
    ///
    /// The `updates` stream is buffered to the latest snapshot only:
    /// slow consumers (e.g., publishing into SwiftUI `@Published` from a
    /// background thread) will drop intermediate ticks rather than
    /// accumulating them in memory. Updates are also skipped when the
    /// incoming mids contain no actual change.
    ///
    /// - Parameter exchange: Exchange identifier (default: `"sim"`)
    public func watchPrices(exchange: String = "sim") async throws -> MarketPriceStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let prices = SendableBox<[String: String]>([:])

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
        let updates = AsyncStream([String: String].self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await mids in midsStream {
                    var changed = false
                    prices.update { current in
                        for (key, value) in mids {
                            if current[key] != value {
                                current[key] = value
                                changed = true
                            }
                        }
                    }
                    state.update { $0 = .connected }
                    if changed {
                        continuation.yield(prices.value)
                    }
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
    /// The `updates` stream is buffered to the latest snapshot only: slow
    /// consumers will drop intermediate recomputations rather than
    /// accumulating them in memory.
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

        var resolvedFeeScale = opts.feeScale ?? 1.0
        if opts.feeScale == nil {
            if let meta = try? await self.market(opts.market),
               let scale = meta.feeScale, scale > 0 {
                resolvedFeeScale = scale
            }
        }

        // Resolve the per-asset MMR, margin tiers, and top-of-book spread once
        // via getActiveAssetData and feed them into every recompute. None of
        // these are derivable from market meta alone (the margin table and the
        // order book aren't exposed there), so one fetch resolves all three:
        //  - maintenanceMarginRate: without it every recompute hardcodes "0.03",
        //    producing wrong liquidation estimates in `Arca.orderBreakdown` for
        //    any tiered asset (e.g. BTC at 1%).
        //  - marginTiers: tiered assets ladder their initial-margin rate by
        //    notional; without the server tiers the derivation assumes a flat
        //    1/leverage rate and over-states the max, which is then rejected at
        //    placement with "insufficient balance".
        //  - bid/ask: market buys are margin-checked at the ask and sells at the
        //    bid, so we size against that directional price (carried as a spread
        //    ratio applied to the live mid) rather than the mid alone.
        let mmrBox = SendableBox<String?>(opts.maintenanceMarginRate)
        let tiersBox = SendableBox<[MarginTier]?>(nil)
        let askRatioBox = SendableBox<Double>(1)
        let bidRatioBox = SendableBox<Double>(1)
        if let data = try? await getActiveAssetData(
            objectId: opts.objectId,
            market: opts.market,
            applicationFeeTenthsBps: opts.builderFeeBps,
            leverage: opts.leverage
        ) {
            if opts.maintenanceMarginRate == nil {
                mmrBox.update { $0 = data.maintenanceMarginRate }
            }
            if let tiers = data.marginTiers, !tiers.isEmpty {
                tiersBox.update { $0 = tiers }
            }
            // Spread ratio = directional price / snapshot mid, applied to the
            // live mid on each recompute so it stays stable as price moves. The
            // server returns bid == ask == mark when there's no book (ratio 1).
            if let mid = Double(data.markPx), mid > 0 {
                if let bid = data.bidPx.flatMap(Double.init), bid > 0 {
                    bidRatioBox.update { $0 = bid / mid }
                }
                if let ask = data.askPx.flatMap(Double.init), ask > 0 {
                    askRatioBox.update { $0 = ask / mid }
                }
            }
        }

        let exchangeStateBox = SendableBox<ExchangeState?>(initialExchangeState)

        func recompute() -> ActiveAssetData? {
            guard let exState = exchangeStateBox.value else { return nil }
            let markStr = priceStream.prices.value[opts.market]
            let markPx = markStr.flatMap(Double.init) ?? 0
            return deriveActiveAssetData(
                from: exState,
                market: opts.market,
                markPx: markPx,
                leverage: opts.leverage,
                side: opts.side,
                builderFeeBps: opts.builderFeeBps,
                szDecimals: opts.szDecimals,
                feeScale: resolvedFeeScale,
                maintenanceMarginRate: mmrBox.value,
                marginTiers: tiersBox.value,
                askRatio: askRatioBox.value,
                bidRatio: bidRatioBox.value
            )
        }

        // Server-authoritative pricing: when the object is priced by the server
        // (sim-only price overlay), max-order-size must come from the server's
        // active-asset-data endpoint, not from local raw-mid derivation. The
        // server value is refreshed on exchange-state events (below), not per
        // mid tick. Absent/`.client` ⇒ local derivation, exactly as before.
        let fetchServerActiveAssetData: @Sendable () async -> ActiveAssetData? = { [weak self] in
            guard let self else { return nil }
            return try? await self.getActiveAssetData(
                objectId: opts.objectId,
                market: opts.market,
                applicationFeeTenthsBps: opts.builderFeeBps,
                leverage: opts.leverage
            )
        }

        if initialExchangeState.pricingMode == .server {
            if let initial = await fetchServerActiveAssetData() {
                activeAssetBox.update { $0 = initial }
            }
        } else if let initial = recompute() {
            activeAssetBox.update { $0 = initial }
        }

        let detail = try await getObjectDetail(objectId: opts.objectId)
        let objectPath = detail.object.path
        await ws.watchPath(objectPath)

        let exchangeStream = await ws.exchangeNotifications()
        let midsUpdates = priceStream.updates

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && streamState.value != .loading {
                    streamState.update { $0 = .reconnecting }
                }
            }
        }

        let updates = AsyncStream(ActiveAssetData.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let exchangeTask = Task { [weak self] in
                for await event in exchangeStream {
                    guard event.entityId == opts.objectId || event.entityPath == objectPath else { continue }
                    let nextState: ExchangeState
                    if let state = event.exchangeState {
                        nextState = state
                    } else {
                        guard let self = self,
                              let fetched = try? await self.getExchangeState(objectId: opts.objectId) else { continue }
                        nextState = fetched
                    }
                    exchangeStateBox.update { $0 = nextState }
                    let data: ActiveAssetData?
                    if nextState.pricingMode == .server {
                        data = await fetchServerActiveAssetData()
                    } else {
                        data = recompute()
                    }
                    if let data {
                        activeAssetBox.update { $0 = data }
                        streamState.update { $0 = .connected }
                        continuation.yield(data)
                    }
                }
            }
            let midsTask = Task {
                for await _ in midsUpdates {
                    // Server-authoritative pricing: ignore raw mid ticks; the
                    // server drives max-order-size via exchange-state events.
                    if exchangeStateBox.value?.pricingMode == .server { continue }
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

        if activeAssetBox.value != nil {
            streamState.update { $0 = .connected }
        }

        let stream = MaxOrderSizeWatchStream(
            state: streamState,
            activeAssetData: activeAssetBox,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await priceStream.stop()
                await ws.unwatchPath(objectPath)
            }
        )
        return stream
    }
}

// MARK: - Position TP/SL Result

/// Handles for the legs placed by ``Arca/setPositionTpsl(path:objectId:market:stopLossPx:takeProfitPx:isMarket:replace:applicationFeeTenthsBps:feeTargets:)``.
/// A leg is `nil` when its trigger price was not provided.
public struct SetPositionTpslResult: Sendable {
    public let stopLoss: OrderHandle?
    public let takeProfit: OrderHandle?
}

/// Handles for the legs placed by ``Arca/openWithBracket(path:objectId:market:side:size:orderType:price:leverage:isolated:timeInForce:applicationFeeTenthsBps:takeProfitPx:stopLossPx:triggersAreMarket:grouping:)``.
/// All three handles are backed by the **single** bracket operation; `takeProfit`
/// / `stopLoss` are `nil` when their trigger price was not provided.
public struct OpenBracketResult: Sendable {
    public let entry: OrderHandle
    public let takeProfit: OrderHandle?
    public let stopLoss: OrderHandle?
}

// MARK: - Exchange Enums

public enum OrderSide: String, Codable, Sendable {
    case buy = "buy"
    case sell = "sell"
}

public enum PositionSide: String, Codable, Sendable {
    case long = "long"
    case short = "short"
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
    case waitingForTrigger = "WAITING_FOR_TRIGGER"
    case triggered = "TRIGGERED"
}

public enum TpslType: String, Codable, Sendable {
    case takeProfit = "tp"
    case stopLoss = "sl"
}

public enum LeverageType: String, Codable, Sendable {
    case cross
    case isolated
}

public enum MarginMode: String, Codable, Sendable {
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
    let metadata: String?
    let operationPath: String?
}

private struct UpdateLeverageRequest: Encodable {
    let market: String
    let leverage: Int
}

private struct UpdateIsolatedMarginRequest: Encodable {
    let market: String
    let amount: String
}

private struct SetMarginModeRequest: Encodable {
    let market: String
    let marginMode: MarginMode
}

private struct PlaceOrderRequest: Encodable {
    let realmId: String
    let path: String
    let market: String
    let side: String
    let orderType: String
    let size: String
    let price: String?
    let leverage: Int?
    let reduceOnly: Bool
    let timeInForce: String
    let applicationFeeTenthsBps: Int?
    let feeTargets: [FeeTarget]?
    let isTrigger: Bool?
    let triggerPx: String?
    let isMarket: Bool?
    let tpsl: String?
    let sizeToMax: Bool?
    let useMax: Bool?
    let sizeTolerance: Double?
    /// Whether the order targets the asset's isolated-margin bucket.
    /// Required (with positive `leverage`) on `onlyIsolated=true`
    /// markets such as HIP-3 (`hl:1:*`). Encoded as `nil` (omitted)
    /// by default so existing call sites don't change shape.
    let isolated: Bool?
    /// Links this order to the other legs of a TP/SL bracket so a fill on one
    /// leg cancels its siblings (one-cancels-the-other). Advisory and unsigned:
    /// forwarded to the venue but never part of the EIP-712 order digest.
    /// Defaulted (and `var`) so the synthesized memberwise initializer keeps it
    /// optional — call sites that don't bracket (e.g. closePosition) omit the
    /// key, while placeOrder/setPositionTrigger set it.
    var ocoGroupId: String? = nil
}

private struct ModifyOrderBody: Encodable {
    let realmId: String
    let path: String
    let newSize: String
}

/// One leg of a ``PlaceOrderBatchBody``. Optional fields are omitted from the
/// JSON when `nil` (Swift's default `Encodable` behavior), so the entry leg and
/// the unsized trigger legs share one shape. Mirrors the platform's
/// `dto.PlaceOrderBatchLeg`. `oco_group_id` is deliberately absent — the venue
/// server-stamps the shared group id on the trigger legs.
private struct BatchLegBody: Encodable {
    let market: String
    let side: String
    var orderType: String? = nil
    let size: String
    var price: String? = nil
    var leverage: Int? = nil
    var reduceOnly: Bool? = nil
    var timeInForce: String? = nil
    var applicationFeeTenthsBps: Int? = nil
    var isTrigger: Bool? = nil
    var triggerPx: String? = nil
    var isMarket: Bool? = nil
    var tpsl: String? = nil
    var sizeToMax: Bool? = nil
    var isolated: Bool? = nil
}

/// Request body for the atomic batch endpoint. One signed
/// `eip712.OrderBatchAction` is built server-side over `orders[] + grouping`.
private struct PlaceOrderBatchBody: Encodable {
    let realmId: String
    let path: String
    let grouping: String
    let orders: [BatchLegBody]
}

/// Format a size to at most `decimals` fractional digits, stripping trailing
/// zeros, for use as a canonical decimal string (e.g. "0.0001", "3.34", "10").
private func formatSizeToDecimals(_ value: Double, _ decimals: Int) -> String {
    if decimals <= 0 { return String(Int(value.rounded())) }
    var s = String(format: "%.\(decimals)f", value)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s.isEmpty ? "0" : s
}

/// Format a USD notional dropping a trailing `.0` (e.g. 10.0 -> "10", 10.5 -> "10.5").
private func formatNotionalUsd(_ value: Double) -> String {
    if value == value.rounded() { return String(Int(value)) }
    return String(value)
}

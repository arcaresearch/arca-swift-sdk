import Foundation

extension Arca {

    /// Subscribe to real-time operation events.
    /// Resolves once the server sends the initial snapshot, so `operations`
    /// is populated on return. Reconnections are handled automatically.
    /// Call `stop()` when done.
    public func watchOperations() async throws -> OperationWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let box = SendableBox<[Operation]>([])
        let decoder = JSONDecoder()

        let snapshotId = await ws.onSnapshot(channel: "operations") { data in
            let snapshot = data as? [[String: Any]] ?? []
            let ops: [Operation] = snapshot.compactMap { dict in
                guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? decoder.decode(Operation.self, from: d)
            }
            box.update { $0 = ops }
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

        await ws.acquireChannel(.operations)

        let operationUpdates = await ws.operationEvents()
        let updates = AsyncStream<(Operation, RealmEvent)> { continuation in
            let task = Task {
                for await (op, event) in operationUpdates {
                    box.update { ops in
                        if let idx = ops.firstIndex(where: { $0.id == op.id }) {
                            ops[idx] = op
                        } else {
                            ops.insert(op, at: 0)
                        }
                    }
                    continuation.yield((op, event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let stream = OperationWatchStream(
            state: state,
            operations: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "operations", id: snapshotId)
                await ws.releaseChannel(.operations)
            }
        )
        await stream.ready()
        return stream
    }

    /// Subscribe to real-time balance updates.
    /// Resolves once the server sends the initial snapshot, so `balances`
    /// is populated on return. Reconnections are handled automatically.
    /// Optionally filter by an Arca path prefix.
    /// Call `stop()` when done.
    public func watchBalances(arcaRef: String? = nil) async throws -> BalanceWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let box = SendableBox<[String: BalanceSnapshot]>([:])

        let snapshotId = await ws.onSnapshot(channel: "balances") { data in
            let entries = data as? [[String: Any]] ?? []
            var map: [String: BalanceSnapshot] = [:]
            let decoder = JSONDecoder()
            for entry in entries {
                guard let d = try? JSONSerialization.data(withJSONObject: entry),
                      let snap = try? decoder.decode(BalanceSnapshot.self, from: d) else { continue }
                map[snap.entityId] = snap
            }
            box.update { $0 = map }
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

        await ws.acquireChannel(.balances)

        let balanceUpdates = await ws.balanceEvents()

        let updates = AsyncStream<(String, RealmEvent)> { continuation in
            let task = Task {
                for await (entityId, event) in balanceUpdates {
                    if let filter = arcaRef, let path = event.entityPath, !path.hasPrefix(filter) {
                        continue
                    }
                    continuation.yield((entityId, event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let stream = BalanceWatchStream(
            state: state,
            balances: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "balances", id: snapshotId)
                await ws.releaseChannel(.balances)
            }
        )
        await stream.ready()
        return stream
    }

    /// Subscribe to real-time valuation updates for a single Arca object.
    /// The server pushes structural changes (fills, balance updates, object CRUD).
    /// Mid-price revaluation is performed client-side so valuations update in
    /// real time without consuming server bandwidth on every tick.
    /// Call `stop()` when done.
    ///
    /// - Parameter path: Path of the Arca object to watch
    /// - Parameter exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchObject(path: String, exchange: String = "sim") async throws -> ObjectWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let valBox = SendableBox<ObjectValuation?>(nil)
        let watchIdBox = SendableBox<String?>(nil)
        let midsBox = SendableBox<[String: String]>([:])
        let retryAttemptBox = SendableBox<Int>(0)
        let retryTaskBox = SendableBox<Task<Void, Never>?>(nil)

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                    retryTaskBox.value?.cancel()
                    retryTaskBox.update { $0 = nil }
                    retryAttemptBox.update { $0 = 0 }
                } else if s == .connected && watchIdBox.value != nil {
                    state.update { $0 = .connected }
                }
            }
        }

        let midsSnapshotId = await ws.onSnapshot(channel: "mids") { data in
            let mids = data as? [String: String] ?? [:]
            midsBox.update { $0 = mids }
        }

        await ws.acquireMids(exchange: exchange)

        let valEvents = await ws.objectValuationEvents()
        let midsStream = await ws.midsEvents()

        let updates = AsyncStream<ObjectValuation> { continuation in
            let valTask = Task { [ws] in
                for await (valuation, eventPath, wid) in valEvents {
                    guard eventPath == path else { continue }
                    watchIdBox.update { $0 = wid }
                    await ws.trackObjectWatch(watchId: wid, path: path)
                    let currentMids = midsBox.value
                    let revalued = currentMids.isEmpty ? valuation : valuation.revalued(with: currentMids)
                    valBox.update { $0 = revalued }
                    state.update { $0 = .connected }
                    continuation.yield(revalued)

                    if valuation.computed == false {
                        let attempt = retryAttemptBox.value
                        let delay = min(1.0 * pow(2.0, Double(attempt)), 30.0)
                        retryTaskBox.value?.cancel()
                        retryTaskBox.update { $0 = Task { [ws] in
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            retryAttemptBox.update { $0 += 1 }
                            await ws.sendWatchObject(path: path)
                        }}
                    } else {
                        retryTaskBox.value?.cancel()
                        retryTaskBox.update { $0 = nil }
                        retryAttemptBox.update { $0 = 0 }
                    }
                }
                continuation.finish()
            }

            let midsTask = Task {
                for await mids in midsStream {
                    midsBox.update { current in
                        for (key, value) in mids { current[key] = value }
                    }
                    guard let base = valBox.value else { continue }
                    let revalued = base.revalued(with: midsBox.value)
                    valBox.update { $0 = revalued }
                    continuation.yield(revalued)
                }
            }

            continuation.onTermination = { _ in
                valTask.cancel()
                midsTask.cancel()
                retryTaskBox.value?.cancel()
            }
        }

        await ws.sendWatchObject(path: path)

        return ObjectWatchStream(
            state: state,
            path: path,
            watchId: watchIdBox,
            valuation: valBox,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                retryTaskBox.value?.cancel()
                await ws.removeSnapshotHandler(channel: "mids", id: midsSnapshotId)
                await ws.releaseMids()
                if let wid = watchIdBox.value {
                    await ws.sendUnwatchObject(watchId: wid)
                }
            }
        )
    }

    /// Subscribe to real-time aggregation updates for a set of sources.
    /// Automatically handles server-side watch creation, structural change events,
    /// and client-side revaluation from mid prices. Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - sources: Aggregation sources to track
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchAggregation(sources: [AggregationSource], exchange: String = "sim") async throws -> AggregationWatchStream {
        await ws.ensureConnected()

        let watchResponse = try await createAggregationWatch(sources: sources)
        let initialAgg = watchResponse.aggregation

        let state = SendableBox<WatchStreamState>(.loading)
        let aggBox = SendableBox<PathAggregation?>(initialAgg)
        let structuralBox = SendableBox<PathAggregation?>(initialAgg)
        let midsBox = SendableBox<[String: String]>([:])
        let widBox = SendableBox<String>(watchResponse.watchId.rawValue)
        let continuationBox = SendableBox<AsyncStream<PathAggregation>.Continuation?>(nil)
        let refreshingBox = SendableBox<Bool>(false)

        let statusStream = await ws.statusStream
        let statusTask = Task { [weak self] in
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                } else if s == .connected && state.value == .reconnecting {
                    guard let self = self else { continue }
                    guard !refreshingBox.value else { continue }
                    refreshingBox.update { $0 = true }
                    do {
                        let oldWatchId = widBox.value
                        let newWatch = try await self.createAggregationWatch(sources: sources)
                        widBox.update { $0 = newWatch.watchId.rawValue }
                        try? await self.destroyAggregationWatch(watchId: oldWatchId)
                        structuralBox.update { $0 = newWatch.aggregation }
                        let currentMids = midsBox.value
                        let revalued = currentMids.isEmpty ? newWatch.aggregation : newWatch.aggregation.revalued(with: currentMids)
                        aggBox.update { $0 = revalued }
                        continuationBox.value?.yield(revalued)
                    } catch {
                        // Best effort — keep existing data
                    }
                    refreshingBox.update { $0 = false }
                    state.update { $0 = .connected }
                }
            }
        }

        let midsSnapshotId = await ws.onSnapshot(channel: "mids") { data in
            let mids = data as? [String: String] ?? [:]
            midsBox.update { $0 = mids }
        }

        await ws.acquireMids(exchange: exchange)
        await ws.acquireChannel(.aggregation)

        let aggEvents = await ws.aggregationEvents()
        let midsStream = await ws.midsEvents()

        let updates = AsyncStream<PathAggregation> { continuation in
            continuationBox.update { $0 = continuation }

            let aggTask = Task {
                for await (eventWatchId, agg, _) in aggEvents {
                    guard eventWatchId == widBox.value, let agg = agg else { continue }
                    structuralBox.update { $0 = agg }
                    let currentMids = midsBox.value
                    let revalued = currentMids.isEmpty ? agg : agg.revalued(with: currentMids)
                    aggBox.update { $0 = revalued }
                    state.update { $0 = .connected }
                    continuation.yield(revalued)
                }
                continuation.finish()
            }

            let midsTask = Task {
                for await mids in midsStream {
                    midsBox.update { current in
                        for (key, value) in mids { current[key] = value }
                    }
                    guard let base = structuralBox.value else { continue }
                    let revalued = base.revalued(with: midsBox.value)
                    aggBox.update { $0 = revalued }
                    continuation.yield(revalued)
                }
            }

            continuation.onTermination = { _ in
                aggTask.cancel()
                midsTask.cancel()
            }
        }

        state.update { $0 = .connected }

        let stream = AggregationWatchStream(
            state: state,
            watchId: widBox.value,
            aggregation: aggBox,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "mids", id: midsSnapshotId)
                await ws.releaseMids()
                await ws.releaseChannel(.aggregation)
                try? await self.destroyAggregationWatch(watchId: widBox.value)
            }
        )

        return stream
    }

    /// Watch fills (trade history) for an exchange Arca object.
    ///
    /// Two-phase fill delivery:
    /// 1. `exchange.fill` — instant preview with venue data (market, side, size, price, total fee)
    /// 2. `fill.recorded` — authoritative fill with platform-computed data (dir, position, fee breakdown)
    ///
    /// Phase 2 replaces the preview. On reconnect, re-fetches from REST to reconcile gaps.
    ///
    /// - Parameters:
    ///   - objectId: Exchange Arca object ID
    ///   - market: Optional market filter (canonical coin ID)
    ///   - limit: Max fills for initial fetch (default 100)
    public func watchFills(
        objectId: String,
        market: String? = nil,
        limit: Int? = nil
    ) async throws -> FillWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let box = SendableBox<[Fill]>([])
        let fillIdSet = SendableBox<Set<String>>(Set())
        let previewOrderIds = SendableBox<Set<String>>([])
        let recordedOrderIds = SendableBox<Set<String>>([])
        let fetchInFlight = SendableBox<Bool>(false)

        let objectPath: String?
        if let detail = try? await getObjectDetail(objectId: objectId) {
            objectPath = detail.object.path
        } else {
            objectPath = nil
        }

        let capturedPath = objectPath
        let matchesObject: @Sendable (RealmEvent) -> Bool = { event in
            event.entityId == objectId
                || (capturedPath != nil && event.entityPath == capturedPath)
        }

        let fetchFills: @Sendable () async -> Void = { [self] in
            guard !fetchInFlight.value else { return }
            fetchInFlight.update { $0 = true }
            defer { fetchInFlight.update { $0 = false } }
            guard let resp = try? await self.listFills(objectId: objectId, market: market, limit: limit) else { return }
            box.update { $0 = resp.fills }
            fillIdSet.update { ids in
                ids.removeAll()
                for f in resp.fills { ids.insert(f.id) }
            }
            previewOrderIds.update { $0.removeAll() }
            recordedOrderIds.update { $0.removeAll() }
            state.update { $0 = .connected }
        }

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                } else if s == .connected && !box.value.isEmpty {
                    await fetchFills()
                }
            }
        }

        await ws.acquireChannel(.exchange)

        let previewStream = await ws.fillEvents()
        let recordedStream = await ws.fillRecordedEvents()

        let updates = AsyncStream<(Fill, RealmEvent)> { continuation in
            let previewTask = Task {
                for await (simFill, event) in previewStream {
                    guard matchesObject(event) else { continue }
                    let orderId = simFill.orderId.rawValue
                    guard !previewOrderIds.value.contains(orderId) && !recordedOrderIds.value.contains(orderId) else { continue }
                    let preview = Fill(
                        id: simFill.id.rawValue,
                        operationId: nil,
                        fillId: nil,
                        orderOperationId: nil,
                        orderId: orderId,
                        market: simFill.coin,
                        side: simFill.side,
                        size: simFill.size,
                        price: simFill.price,
                        dir: nil,
                        startPosition: nil,
                        fee: simFill.fee,
                        exchangeFee: nil,
                        platformFee: nil,
                        builderFee: simFill.builderFee,
                        realizedPnl: simFill.realizedPnl,
                        resultingPosition: nil,
                        isLiquidation: simFill.isLiquidation,
                        createdAt: simFill.createdAt
                    )
                    previewOrderIds.update { $0.insert(orderId) }
                    box.update { $0.insert(preview, at: 0) }
                    continuation.yield((preview, event))
                }
            }
            let recordedTask = Task {
                for await (fill, event) in recordedStream {
                    guard matchesObject(event) else { continue }
                    if let orderId = fill.orderId, previewOrderIds.value.contains(orderId) {
                        box.update { fills in
                            if let idx = fills.firstIndex(where: { $0.orderId == orderId && $0.operationId == nil }) {
                                fills[idx] = fill
                            } else {
                                fills.insert(fill, at: 0)
                            }
                        }
                        previewOrderIds.update { $0.remove(orderId) }
                    } else {
                        guard !fillIdSet.value.contains(fill.id) else { continue }
                        box.update { $0.insert(fill, at: 0) }
                    }
                    if let orderId = fill.orderId {
                        recordedOrderIds.update { $0.insert(orderId) }
                    }
                    fillIdSet.update { $0.insert(fill.id) }
                    continuation.yield((fill, event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                previewTask.cancel()
                recordedTask.cancel()
            }
        }

        await fetchFills()

        let stream = FillWatchStream(
            state: state,
            fills: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.releaseChannel(.exchange)
            }
        )
        return stream
    }

    /// Subscribe to raw real-time candle events (no history blending).
    ///
    /// **For candlestick charts, use ``watchCandleChart(coin:interval:count:)``
    /// instead** — it loads historical candles, merges live events, and handles
    /// reconnection gaps automatically.
    ///
    /// This method returns a raw event stream. Each `CandleEvent` contains a
    /// single candle; your app is responsible for maintaining the chart array.
    /// Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - coins: Canonical coin IDs to watch (e.g. `["hl:BTC", "hl:ETH"]`)
    ///   - intervals: Candle intervals (e.g. `[.oneMinute, .fiveMinutes]`)
    public func watchCandles(coins: [String], intervals: [CandleInterval]) async throws -> CandleWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.connected)

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected {
                    state.update { $0 = .reconnecting }
                } else if s == .connected {
                    state.update { $0 = .connected }
                }
            }
        }

        await ws.acquireCandles(coins: coins, intervals: intervals)

        let candleStream = await ws.candleEvents()
        let coinSet = Set(coins)

        let updates = AsyncStream<CandleEvent> { continuation in
            let task = Task {
                for await event in candleStream {
                    if coinSet.isEmpty || coinSet.contains(event.coin) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return CandleWatchStream(
            state: state,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.releaseCandles(coins: coins, intervals: intervals)
            }
        )
    }
}

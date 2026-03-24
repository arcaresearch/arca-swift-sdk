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

    /// Subscribe to real-time candle updates.
    /// Returns immediately in `.connected` state (candles have no snapshot).
    /// Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - coins: Coins to watch (e.g. `["BTC", "ETH"]`)
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

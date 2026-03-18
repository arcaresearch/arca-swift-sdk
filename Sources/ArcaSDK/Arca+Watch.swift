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
    /// Uses the same computation path as aggregation (Axiom 10: Observational Consistency).
    /// Call `stop()` when done.
    ///
    /// - Parameter path: Path of the Arca object to watch
    public func watchObject(path: String) async throws -> ObjectWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let valBox = SendableBox<ObjectValuation?>(nil)
        let watchIdBox = SendableBox<String?>(nil)

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                } else if s == .connected && watchIdBox.value != nil {
                    state.update { $0 = .connected }
                }
            }
        }

        let valEvents = await ws.objectValuationEvents()

        let updates = AsyncStream<ObjectValuation> { continuation in
            let task = Task {
                for await (valuation, eventPath, wid) in valEvents {
                    guard eventPath == path else { continue }
                    watchIdBox.update { $0 = wid }
                    valBox.update { $0 = valuation }
                    state.update { $0 = .connected }
                    continuation.yield(valuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
                if let wid = watchIdBox.value {
                    await ws.sendUnwatchObject(watchId: wid)
                }
            }
        )
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

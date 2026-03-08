import Foundation

extension Arca {

    /// Subscribe to real-time operation events.
    /// Returns immediately; the stream starts in `.loading` and transitions
    /// to `.connected` when the first snapshot arrives.
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

        return OperationWatchStream(
            state: state,
            operations: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "operations", id: snapshotId)
                await ws.releaseChannel(.operations)
            }
        )
    }

    /// Subscribe to real-time balance updates.
    /// Returns immediately; the stream starts in `.loading` and transitions
    /// to `.connected` when the first snapshot arrives.
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

        return BalanceWatchStream(
            state: state,
            balances: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.removeSnapshotHandler(channel: "balances", id: snapshotId)
                await ws.releaseChannel(.balances)
            }
        )
    }

    /// Subscribe to real-time exchange state and fill events.
    /// Returns immediately in `.connected` state (exchange has no snapshot).
    /// Call `stop()` when done.
    public func watchExchange() async throws -> ExchangeWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.connected)
        let box = SendableBox<ExchangeState?>(nil)

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

        await ws.acquireChannel(.exchange)

        let stateEvents = await ws.exchangeEvents()
        let fillEvents = await ws.fillEvents()

        let updates = AsyncStream<ExchangeUpdate> { continuation in
            let stateTask = Task {
                for await (exchangeState, event) in stateEvents {
                    box.update { $0 = exchangeState }
                    continuation.yield(.stateUpdate(exchangeState, event))
                }
            }
            let fillTask = Task {
                for await (fill, event) in fillEvents {
                    continuation.yield(.fill(fill, event))
                }
            }
            continuation.onTermination = { _ in
                stateTask.cancel()
                fillTask.cancel()
            }
        }

        return ExchangeWatchStream(
            state: state,
            exchangeState: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.releaseChannel(.exchange)
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

import Foundation

extension Arca {

    /// Subscribe to real-time operation events.
    /// The server sends an initial snapshot, then streams creates and updates.
    /// Call `stop()` when done.
    public func watchOperations() async throws -> OperationWatchStream {
        await ws.ensureConnected()
        let snapshot: [[String: Any]] = await ws.waitForSnapshot(channel: "operations")
        await ws.acquireChannel(.operations)

        let decoder = JSONDecoder()
        let initial: [Operation] = snapshot.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(Operation.self, from: data)
        }
        let box = SendableBox(initial)

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
            operations: box,
            updates: updates,
            stop: { [ws] in await ws.releaseChannel(.operations) }
        )
    }

    /// Subscribe to real-time balance updates.
    /// Optionally filter by an Arca path prefix.
    /// Call `stop()` when done.
    public func watchBalances(arcaRef: String? = nil) async throws -> BalanceWatchStream {
        await ws.ensureConnected()
        await ws.acquireChannel(.balances)

        let balanceUpdates = await ws.balanceEvents()
        let box = SendableBox<[String: BalanceSnapshot]>([:])

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
            balances: box,
            updates: updates,
            stop: { [ws] in await ws.releaseChannel(.balances) }
        )
    }

    /// Subscribe to real-time exchange state and fill events.
    /// Call `stop()` when done.
    public func watchExchange() async throws -> ExchangeWatchStream {
        await ws.ensureConnected()
        await ws.acquireChannel(.exchange)

        let stateEvents = await ws.exchangeEvents()
        let fillEvents = await ws.fillEvents()
        let box = SendableBox<ExchangeState?>(nil)

        let updates = AsyncStream<ExchangeUpdate> { continuation in
            let stateTask = Task {
                for await (state, event) in stateEvents {
                    box.update { $0 = state }
                    continuation.yield(.stateUpdate(state, event))
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
            exchangeState: box,
            updates: updates,
            stop: { [ws] in await ws.releaseChannel(.exchange) }
        )
    }

    /// Subscribe to real-time candle updates.
    /// Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - coins: Coins to watch (e.g. `["BTC", "ETH"]`)
    ///   - intervals: Candle intervals (e.g. `[.oneMinute, .fiveMinutes]`)
    public func watchCandles(coins: [String], intervals: [CandleInterval]) async throws -> CandleWatchStream {
        await ws.ensureConnected()
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
            updates: updates,
            stop: { [ws] in await ws.releaseCandles(coins: coins, intervals: intervals) }
        )
    }
}

import Foundation

private func hasInlineStructuralExchangeState(_ state: ExchangeState?) -> Bool {
    state?.pendingIntents != nil
}

extension Arca {

    /// Watch real-time operation events under a path prefix.
    /// Creates a path-scoped watch; the server sends initial operations in the
    /// snapshot, then streams `operation.created` / `operation.updated`.
    /// Reconnections are handled automatically. Call `stop()` when done.
    ///
    /// - Parameter path: Arca path prefix to watch (default: "/" for all operations)
    public func watchOperations(path: String = "/") async throws -> OperationWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let box = SendableBox<[Operation]>([])

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                }
            }
        }

        let gapId = await ws.onGap { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    let resp = path != "/"
                        ? try await self.listOperations(path: path)
                        : try await self.listOperations()
                    box.update { $0 = resp.operations }
                } catch {
                    self.log.warning("watch",
                                     "operations gap recovery refetch failed",
                                     error: error,
                                     metadata: ["path": path])
                }
            }
        }

        await ws.watchPath(path)

        do {
            let resp = path != "/"
                ? try await self.listOperations(path: path)
                : try await self.listOperations()
            box.update { $0 = resp.operations }
        } catch {
            self.log.warning("watch",
                             "operations initial snapshot failed",
                             error: error,
                             metadata: ["path": path])
        }
        state.update { $0 = .connected }

        let opCallbacks = SendableBox<[UUID: @Sendable (Operation, RealmEvent) -> Void]>([:])

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
                    let cbs = opCallbacks.value
                    for cb in cbs.values { cb(op, event) }
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
                await ws.removeGapHandler(gapId)
                await ws.unwatchPath(path)
            },
            updateCallbacks: opCallbacks
        )
        await stream.ready()
        return stream
    }

    /// Watch real-time balance updates under a path prefix.
    /// Creates a path-scoped watch; the server sends initial balances
    /// (four-bucket summary) in the snapshot, then streams `balance.updated`.
    /// Reconnections are handled automatically. Call `stop()` when done.
    ///
    /// - Parameter path: Arca path prefix to watch (default: "/" for all balances)
    public func watchBalances(path: String = "/") async throws -> BalanceWatchStream {
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let box = SendableBox<[String: BalanceSnapshot]>([:])

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                }
            }
        }

        let gapId = await ws.onGap { [weak self] _ in
            Task { [weak self] in
                guard let self = self else { return }
                let entities = box.value
                for (entityId, snap) in entities {
                    do {
                        let bals = try await self.getBalances(objectId: entityId)
                        box.update { $0[entityId] = BalanceSnapshot(entityId: entityId, entityPath: snap.entityPath, balances: bals) }
                    } catch {
                        self.log.warning("watch",
                                         "balances gap recovery refetch failed",
                                         error: error,
                                         metadata: ["entityId": entityId])
                    }
                }
            }
        }

        await ws.watchPath(path)

        do {
            let objects = try await self.listObjects(path: path == "/" ? nil : path)
            for obj in objects.objects {
                do {
                    let bals = try await self.getBalances(objectId: obj.id.rawValue)
                    if !bals.isEmpty {
                        box.update { $0[obj.id.rawValue] = BalanceSnapshot(entityId: obj.id.rawValue, entityPath: obj.path, balances: bals) }
                    }
                } catch {
                    self.log.warning("watch",
                                     "balances initial snapshot failed for object",
                                     error: error,
                                     metadata: ["entityId": obj.id.rawValue, "path": obj.path])
                }
            }
        } catch {
            self.log.warning("watch",
                             "balances initial listObjects failed",
                             error: error,
                             metadata: ["path": path])
        }
        state.update { $0 = .connected }

        let balCallbacks = SendableBox<[UUID: @Sendable (String, RealmEvent) -> Void]>([:])

        let balanceUpdates = await ws.balanceEvents()

        let updates = AsyncStream<(String, RealmEvent)> { continuation in
            let task = Task {
                for await (entityId, event) in balanceUpdates {
                    if path != "/", let eventPath = event.entityPath, !eventPath.hasPrefix(path) {
                        continue
                    }
                    continuation.yield((entityId, event))
                    let cbs = balCallbacks.value
                    for cb in cbs.values { cb(entityId, event) }
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
                await ws.removeGapHandler(gapId)
                await ws.unwatchPath(path)
            },
            updateCallbacks: balCallbacks
        )
        await stream.ready()
        return stream
    }

    /// Watch real-time valuation updates for a single Arca object.
    /// Creates a path-scoped watch with an aggregation watch for valuation;
    /// the server sends initial valuation in the snapshot, then streams
    /// `object.valuation` events on structural changes (fills, balance updates).
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
        let continuationBox = SendableBox<AsyncStream<ObjectValuation>.Continuation?>(nil)
        let stoppedBox = SendableBox<Bool>(false)

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

        let gapId = await ws.onGap { [weak self] _ in
            Task { [weak self] in
                guard let self = self, !stoppedBox.value else { return }
                let val: ObjectValuation
                do {
                    val = try await self.getObjectValuation(path: path)
                } catch {
                    self.log.warning("watch",
                                     "object valuation gap recovery refetch failed",
                                     error: error,
                                     metadata: ["path": path])
                    return
                }
                guard !stoppedBox.value else { return }
                let currentMids = midsBox.value
                let revalued = currentMids.isEmpty ? val : val.revalued(with: currentMids)
                valBox.update { $0 = revalued }
                continuationBox.value?.yield(revalued)
            }
        }

        await ws.acquireMids(exchange: exchange)

        let objCallbacks = SendableBox<[UUID: @Sendable (ObjectValuation) -> Void]>([:])

        let yieldValuation: @Sendable (AsyncStream<ObjectValuation>.Continuation, ObjectValuation) -> Void = { cont, val in
            cont.yield(val)
            let cbs = objCallbacks.value
            for cb in cbs.values { cb(val) }
        }

        let valEvents = await ws.objectValuationEvents()
        let midsStream = await ws.midsEvents()

        let updates = AsyncStream<ObjectValuation> { continuation in
            continuationBox.update { $0 = continuation }

            let valTask = Task {
                for await (valuation, eventPath, wid, rawEvent) in valEvents {
                    guard eventPath == path else { continue }
                    watchIdBox.update { $0 = wid }

                    if rawEvent.driftCorrected == true {
                        self.log.warning("watch",
                                         "valuation drift corrected; previous value was stale",
                                         metadata: ["path": eventPath, "watchId": wid])
                    }

                    let currentMids = midsBox.value
                    let revalued = currentMids.isEmpty ? valuation : valuation.revalued(with: currentMids)
                    valBox.update { $0 = revalued }
                    state.update { $0 = .connected }
                    yieldValuation(continuation, revalued)
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
                    yieldValuation(continuation, revalued)
                }
            }

            continuation.onTermination = { _ in
                valTask.cancel()
                midsTask.cancel()
            }
        }

        await ws.watchPath(path)

        return ObjectWatchStream(
            state: state,
            path: path,
            watchId: watchIdBox,
            valuation: valBox,
            updates: updates,
            stop: { [ws] in
                stoppedBox.update { $0 = true }
                continuationBox.update { $0 = nil }
                statusTask.cancel()
                await ws.removeGapHandler(gapId)
                await ws.releaseMids()
                await ws.unwatchPath(path)
            },
            updateCallbacks: objCallbacks
        )
    }

    /// Watch real-time valuations for multiple Arca objects.
    /// Creates one ``ObjectWatchStream`` per path and merges updates into a
    /// dictionary keyed by object path. Duplicate paths are ignored (first wins).
    /// Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - paths: Arca object paths to watch
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchObjects(paths: [String], exchange: String = "sim") async throws -> ObjectsWatchStream {
        var seen = Set<String>()
        let uniquePaths = paths.filter { seen.insert($0).inserted }

        if uniquePaths.isEmpty {
            let streamState = SendableBox<WatchStreamState>(.connected)
            let valuations = SendableBox<[String: ObjectValuation]>([:])
            let mergedCallbacks = SendableBox<[UUID: @Sendable ([String: ObjectValuation]) -> Void]>([:])
            let updates = AsyncStream<[String: ObjectValuation]> { continuation in
                continuation.yield([:])
                continuation.finish()
            }
            return ObjectsWatchStream(
                state: streamState,
                valuations: valuations,
                childStreams: [],
                updates: updates,
                stop: {},
                updateCallbacks: mergedCallbacks
            )
        }

        var builtStreams: [ObjectWatchStream] = []
        builtStreams.reserveCapacity(uniquePaths.count)
        for path in uniquePaths {
            builtStreams.append(try await watchObject(path: path, exchange: exchange))
        }
        let childStreams = builtStreams

        let streamState = SendableBox<WatchStreamState>(.loading)
        let valuations = SendableBox<[String: ObjectValuation]>([:])
        let continuationBox = SendableBox<AsyncStream<[String: ObjectValuation]>.Continuation?>(nil)
        let mergedCallbacks = SendableBox<[UUID: @Sendable ([String: ObjectValuation]) -> Void]>([:])
        let stoppedBox = SendableBox<Bool>(false)

        let refreshMergedState: @Sendable () -> Void = {
            let states = childStreams.map { $0.state.value }
            if states.contains(.reconnecting) {
                streamState.update { $0 = .reconnecting }
            } else if states.contains(.loading) {
                streamState.update { $0 = .loading }
            } else {
                streamState.update { $0 = .connected }
            }
        }

        let emit: @Sendable () -> Void = {
            refreshMergedState()
            let snap = valuations.value
            continuationBox.value?.yield(snap)
            let cbs = mergedCallbacks.value
            for cb in cbs.values { cb(snap) }
        }

        let unsubsBox = SendableBox<[@Sendable () -> Void]>([])

        let updates = AsyncStream<[String: ObjectValuation]> { continuation in
            continuationBox.update { $0 = continuation }

            var tempUnsubs: [@Sendable () -> Void] = []
            for stream in childStreams {
                let path = stream.path
                if let v = stream.valuation.value {
                    valuations.update { $0[path] = v }
                }
                let u1 = stream.onUpdate { val in
                    valuations.update { $0[path] = val }
                    emit()
                }
                let stateBox = stream.state
                let u2 = stateBox.onChange { _ in
                    refreshMergedState()
                }
                tempUnsubs.append(u1)
                tempUnsubs.append { stateBox.removeObserver(u2) }
            }
            unsubsBox.update { $0 = tempUnsubs }
            emit()

            continuation.onTermination = { _ in
                var shouldStop = false
                stoppedBox.update {
                    if !$0 {
                        $0 = true
                        shouldStop = true
                    }
                }
                guard shouldStop else { return }
                continuationBox.update { $0 = nil }
                let unsubs = unsubsBox.value
                for u in unsubs { u() }
                unsubsBox.update { $0.removeAll() }
                for s in childStreams {
                    Task { await s.stop() }
                }
            }
        }

        let stopMerged: @Sendable () async -> Void = {
            var shouldStop = false
            stoppedBox.update {
                if !$0 {
                    $0 = true
                    shouldStop = true
                }
            }
            guard shouldStop else { return }
            continuationBox.update { $0 = nil }
            let unsubs = unsubsBox.value
            for u in unsubs { u() }
            unsubsBox.update { $0.removeAll() }
            for s in childStreams {
                await s.stop()
            }
        }

        return ObjectsWatchStream(
            state: streamState,
            valuations: valuations,
            childStreams: childStreams,
            updates: updates,
            stop: stopMerged,
            updateCallbacks: mergedCallbacks
        )
    }

    /// Watch real-time aggregation updates for a set of sources.
    /// Creates a standalone aggregation watch (not path-scoped); handles
    /// structural change events and client-side revaluation from mid prices.
    /// Call `stop()` when done.
    ///
    /// - Parameters:
    ///   - sources: Aggregation sources to track
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`)
    public func watchAggregation(sources: [AggregationSource], exchange: String = "sim", flowsSince: String? = nil) async throws -> AggregationWatchStream {
        await ws.ensureConnected()

        let watchResponse = try await createAggregationWatch(sources: sources, flowsSince: flowsSince)
        let initialAgg = watchResponse.aggregation

        let state = SendableBox<WatchStreamState>(.loading)
        let aggBox = SendableBox<PathAggregation?>(initialAgg)
        let structuralBox = SendableBox<PathAggregation?>(initialAgg)
        let midsBox = SendableBox<[String: String]>([:])
        let widBox = SendableBox<String>(watchResponse.watchId.rawValue)
        let continuationBox = SendableBox<AsyncStream<PathAggregation>.Continuation?>(nil)
        let refreshingBox = SendableBox<Bool>(false)
        let stoppedBox = SendableBox<Bool>(false)

        let statusStream = await ws.statusStream
        let statusTask = Task { [weak self] in
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                } else if s == .connected && state.value == .reconnecting {
                    guard let self = self, !stoppedBox.value else { continue }
                    guard !refreshingBox.value else { continue }
                    refreshingBox.update { $0 = true }
                    do {
                        let oldWatchId = widBox.value
                        let newWatch = try await self.createAggregationWatch(sources: sources, flowsSince: flowsSince)
                        guard !stoppedBox.value else {
                            refreshingBox.update { $0 = false }
                            continue
                        }
                        widBox.update { $0 = newWatch.watchId.rawValue }
                        do {
                            try await self.destroyAggregationWatch(watchId: oldWatchId)
                        } catch {
                            self.log.debug("watch",
                                           "destroyAggregationWatch cleanup failed (best-effort)",
                                           error: error,
                                           metadata: ["watchId": oldWatchId])
                        }
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

        await ws.acquireMids(exchange: exchange)

        let aggCallbacks = SendableBox<[UUID: @Sendable (PathAggregation) -> Void]>([:])

        let yieldAgg: @Sendable (AsyncStream<PathAggregation>.Continuation, PathAggregation) -> Void = { cont, agg in
            cont.yield(agg)
            let cbs = aggCallbacks.value
            for cb in cbs.values { cb(agg) }
        }

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
                    yieldAgg(continuation, revalued)
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
                    yieldAgg(continuation, revalued)
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
                stoppedBox.update { $0 = true }
                continuationBox.update { $0 = nil }
                statusTask.cancel()
                await ws.releaseMids()
                do {
                    try await self.destroyAggregationWatch(watchId: widBox.value)
                } catch {
                    self.log.debug("watch",
                                   "destroyAggregationWatch cleanup failed (best-effort)",
                                   error: error,
                                   metadata: ["watchId": widBox.value])
                }
            },
            updateCallbacks: aggCallbacks
        )

        return stream
    }

    /// Watch real-time exchange state for an Arca exchange object.
    /// Resolves the object path from `objectId`, creates a path-scoped watch,
    /// then fetches initial state via REST and re-fetches on each `exchange.updated`
    /// event matching the object. Reconnections are handled automatically.
    /// Call `stop()` when done.
    ///
    /// - Parameter objectId: Exchange Arca object ID
    public func watchExchangeState(objectId: String, exchange: String = "sim") async throws -> ExchangeStateWatchStream {
        await ws.ensureConnected()

        let detail = try await getObjectDetail(objectId: objectId)
        let objectPath = detail.object.path

        let streamState = SendableBox<WatchStreamState>(.loading)
        let stateBox = SendableBox<ExchangeState?>(nil)
        let structuralBox = SendableBox<ExchangeState?>(nil)
        let midsBox = SendableBox<[String: String]>([:])

        let initialState = try await getExchangeState(objectId: objectId)
        structuralBox.update { $0 = initialState }
        stateBox.update { $0 = initialState }
        streamState.update { $0 = .connected }

        let statusStream = await ws.statusStream
        let statusTask = Task { [weak self] in
            for await s in statusStream {
                if s == .disconnected && streamState.value != .loading {
                    streamState.update { $0 = .reconnecting }
                } else if s == .connected && streamState.value == .reconnecting {
                    guard let self = self else { continue }
                    do {
                        let refreshed = try await self.getExchangeState(objectId: objectId)
                        structuralBox.update { $0 = refreshed }
                        let currentMids = midsBox.value
                        let revalued = currentMids.isEmpty ? refreshed : refreshed.revalued(with: currentMids)
                        stateBox.update { $0 = revalued }
                    } catch {
                        self.log.warning("watch",
                                         "exchange state refresh on reconnect failed",
                                         error: error,
                                         metadata: ["objectId": objectId])
                    }
                    streamState.update { $0 = .connected }
                }
            }
        }

        await ws.acquireMids(exchange: exchange)
        await ws.watchPath(objectPath)

        let exchangeStream = await ws.exchangeNotifications()
        let midsStream = await ws.midsEvents()

        let updates = AsyncStream<ExchangeState> { [weak self] continuation in
            let exchangeTask = Task { [weak self] in
                for await event in exchangeStream {
                    guard event.entityId == objectId || event.entityPath == objectPath else { continue }
                    let structural: ExchangeState
                    if let state = event.exchangeState,
                       hasInlineStructuralExchangeState(state) {
                        structural = state
                    } else {
                        guard let self = self else { continue }
                        do {
                            structural = try await self.getExchangeState(objectId: objectId)
                        } catch {
                            self.log.warning("watch",
                                             "exchange state refetch failed",
                                             error: error,
                                             metadata: ["objectId": objectId])
                            continue
                        }
                    }
                    structuralBox.update { $0 = structural }
                    let currentMids = midsBox.value
                    let revalued = currentMids.isEmpty ? structural : structural.revalued(with: currentMids)
                    stateBox.update { $0 = revalued }
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
                    stateBox.update { $0 = revalued }
                    continuation.yield(revalued)
                }
            }

            continuation.onTermination = { _ in
                exchangeTask.cancel()
                midsTask.cancel()
            }
        }

        return ExchangeStateWatchStream(
            state: streamState,
            exchangeState: stateBox,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.unwatchPath(objectPath)
                await ws.releaseMids()
            }
        )
    }

    /// Watch real-time funding payment events for an exchange Arca object.
    /// Resolves the object path from `objectId`, creates a path-scoped watch,
    /// then yields each funding payment with its ``EventEnvelope`` for correlation.
    /// Call `stop()` when done.
    ///
    /// - Parameter objectId: Exchange Arca object ID
    public func watchFunding(objectId: String) async throws -> FundingWatchStream {
        await ws.ensureConnected()

        let detail = try await getObjectDetail(objectId: objectId)
        let objectPath = detail.object.path

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

        await ws.watchPath(objectPath)

        let fundingStream = await ws.fundingEvents()
        let updates = AsyncStream<(FundingPayment, EventEnvelope)> { continuation in
            let task = Task {
                for await (payment, event) in fundingStream {
                    guard event.entityId == objectId else { continue }
                    let envelope = EventEnvelope(from: event)
                    continuation.yield((payment, envelope))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return FundingWatchStream(
            state: state,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                await ws.unwatchPath(objectPath)
            }
        )
    }

    /// Watch fills (trade history) for an exchange Arca object.
    ///
    /// Two-phase fill delivery with envelope-based correlation:
    /// 1. `exchange.fill` — instant preview with venue data (matched by `correlationId`)
    /// 2. `fill.recorded` — authoritative fill replaces preview (matched by `correlationId`)
    ///
    /// A convergence timeout fires if a preview doesn't receive its authoritative
    /// update within the timeout window. On reconnect, re-fetches from REST to reconcile gaps.
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
        let previewCorrelations = SendableBox<[String: Task<Void, Never>]>([:])
        let resolvedCorrelations = SendableBox<Set<String>>([])
        let convergenceCallbacks = SendableBox<[UUID: @Sendable (String) -> Void]>([:])
        let fetchInFlight = SendableBox<Bool>(false)

        let detail = try await getObjectDetail(objectId: objectId)
        let objectPath = detail.object.path

        let matchesObject: @Sendable (RealmEvent) -> Bool = { event in
            event.entityId == objectId
                || event.entityPath == objectPath
        }

        let clearAllTimers: @Sendable () -> Void = {
            previewCorrelations.update { map in
                for (_, task) in map { task.cancel() }
                map.removeAll()
            }
        }

        let fetchFills: @Sendable () async -> Void = { [weak self] in
            guard let self else { return }
            guard !fetchInFlight.value else { return }
            fetchInFlight.update { $0 = true }
            defer { fetchInFlight.update { $0 = false } }
            let resp: FillListResponse
            do {
                resp = try await self.listFills(objectId: objectId, market: market, limit: limit)
            } catch {
                self.log.warning("watch",
                                 "fills snapshot refetch failed",
                                 error: error,
                                 metadata: [
                                     "objectId": objectId,
                                     "market": market ?? "",
                                 ])
                return
            }
            box.update { $0 = resp.fills }
            fillIdSet.update { ids in
                ids.removeAll()
                for f in resp.fills { ids.insert(f.id) }
            }
            clearAllTimers()
            resolvedCorrelations.update { $0.removeAll() }
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

        let gapId = await ws.onGap { _ in
            Task { await fetchFills() }
        }

        await ws.watchPath(objectPath)

        let previewStream = await ws.fillEvents()
        let recordedStream = await ws.fillRecordedEvents()

        let updates = AsyncStream<(Fill, RealmEvent)> { continuation in
            let previewTask = Task {
                for await (simFill, event) in previewStream {
                    guard matchesObject(event) else { continue }
                    let orderId = simFill.orderId.rawValue
                    let correlationKey = event.correlationId ?? orderId

                    if previewCorrelations.value[correlationKey] != nil || resolvedCorrelations.value.contains(correlationKey) {
                        continue
                    }

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

                    let timerTask = Task {
                        try? await Task.sleep(nanoseconds: FillWatchStream.convergenceTimeoutNs)
                        guard !Task.isCancelled else { return }
                        let stillPending = previewCorrelations.value[correlationKey] != nil
                        guard stillPending else { return }
                        let cbs = convergenceCallbacks.value
                        for (_, cb) in cbs { cb(correlationKey) }
                    }

                    previewCorrelations.update { $0[correlationKey] = timerTask }
                    box.update { $0.insert(preview, at: 0) }
                    continuation.yield((preview, event))
                }
            }
            let recordedTask = Task {
                for await (fill, event) in recordedStream {
                    guard matchesObject(event) else { continue }
                    let correlationKey = event.correlationId ?? fill.orderId

                    var replaced = false
                    if let key = correlationKey {
                        let hadPreview = previewCorrelations.value[key] != nil
                        if hadPreview {
                            box.update { fills in
                                if let idx = fills.firstIndex(where: { ($0.orderId == key || $0.orderId == fill.orderId) && $0.operationId == nil }) {
                                    fills[idx] = fill
                                    replaced = true
                                }
                            }
                        } else {
                            box.update { fills in
                                if let idx = fills.firstIndex(where: { $0.orderId == key && $0.operationId == nil }) {
                                    fills[idx] = fill
                                    replaced = true
                                }
                            }
                        }

                        previewCorrelations.update { map in
                            map[key]?.cancel()
                            map.removeValue(forKey: key)
                        }
                        resolvedCorrelations.update { $0.insert(key) }
                    }

                    if !replaced {
                        guard !fillIdSet.value.contains(fill.id) else { continue }
                        box.update { $0.insert(fill, at: 0) }
                    }

                    fillIdSet.update { $0.insert(fill.id) }
                    continuation.yield((fill, event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                previewTask.cancel()
                recordedTask.cancel()
                clearAllTimers()
            }
        }

        await fetchFills()

        let stream = FillWatchStream(
            state: state,
            fills: box,
            updates: updates,
            stop: { [ws] in
                statusTask.cancel()
                clearAllTimers()
                await ws.removeGapHandler(gapId)
                await ws.unwatchPath(objectPath)
            },
            convergenceCallbacks: convergenceCallbacks
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

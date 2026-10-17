import Foundation

// MARK: - Projections
//
// Batched reduced-trust reads: a registered projection is a named
// field-filter over the canonical ObjectValuation shape plus the path
// patterns defining which objects it covers. Managing the registry requires
// arca:ManageProjection; reading valuations through it requires
// arca:ReadProjection on the projection NAME. Readers never receive
// balances, reserved balances, or any field outside the registered set.

private struct UpsertProjectionRequest: Encodable {
    let fields: [String]
    let resources: [String]
}

private struct ProjectionListResponse: Decodable {
    let projections: [RealmProjection]
}

private struct ProjectionDeleteResponse: Decodable {
    let deleted: Bool
}

extension Arca {

    /// Register or update a named projection for the realm.
    /// Requires `arca:ManageProjection`.
    ///
    /// - Parameters:
    ///   - name: Projection name (1–64 chars: alphanumerics, `.`, `_`, `-`).
    ///   - fields: Projectable fields: `equity`, `realizedValue`,
    ///     `unrealizedValue`, `positions`.
    ///   - resources: Path patterns (exact path, `"*"`, or trailing `"/prefix/*"`).
    public func upsertProjection(name: String, fields: [String], resources: [String]) async throws -> RealmProjection {
        try await client.put(
            "/realms/\(realm)/projections/\(name)",
            body: UpsertProjectionRequest(fields: fields, resources: resources)
        )
    }

    /// Fetch a registered projection by name. Requires `arca:ManageProjection`.
    public func getProjection(name: String) async throws -> RealmProjection {
        try await client.get("/realms/\(realm)/projections/\(name)")
    }

    /// List the realm's registered projections. Requires `arca:ManageProjection`.
    public func listProjections() async throws -> [RealmProjection] {
        let resp: ProjectionListResponse = try await client.get("/realms/\(realm)/projections")
        return resp.projections
    }

    /// Delete a registered projection. Requires `arca:ManageProjection`.
    public func deleteProjection(name: String) async throws {
        let _: ProjectionDeleteResponse = try await client.delete("/realms/\(realm)/projections/\(name)")
    }

    /// Read one page of redacted valuations for every object a projection
    /// covers, keyset-paginated by path. Requires `arca:ReadProjection` on
    /// the projection name.
    ///
    /// - Parameters:
    ///   - name: Projection name.
    ///   - prefix: Narrow the page to paths under this prefix (never widens
    ///     the projection).
    ///   - path: Exact object path — the single-object variant.
    ///   - paths: Read a known set of paths in one call (max 500). Use this
    ///     when you already know which accounts you want — a leaderboard
    ///     roster, a set of followed traders — instead of paging the whole
    ///     projection to find them. Like every other filter it only narrows.
    ///   - cursor: Keyset cursor from the prior page.
    ///   - limit: Page size (default 100, max 500).
    public func getProjectionValuations(
        name: String,
        prefix: String? = nil,
        path: String? = nil,
        paths: [String]? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> ProjectionValuationsPage {
        var query: [String: String] = ["realmId": realm]
        if let prefix { query["prefix"] = prefix }
        if let path { query["path"] = path }
        if let paths, !paths.isEmpty { query["paths"] = paths.joined(separator: ",") }
        if let cursor { query["cursor"] = cursor }
        if let limit { query["limit"] = String(limit) }
        return try await client.get("/projections/\(name)/valuations", query: query)
    }

    /// Subscribe to a registered projection for a chosen set of accounts:
    /// one batched watch delivering per-object REDACTED valuation deltas
    /// keyed by path, for the `paths` (max 500) and/or `prefix` you name.
    /// Between server deltas, rows re-mark client-side against the mids
    /// feed — and the stream subscribes to mids only for the markets its
    /// rows hold positions in — so a leaderboard ticks with the market at
    /// the cost of its own rows, not the realm's.
    ///
    /// The scope only narrows the projection's registered resources: a
    /// path outside them is dropped, a prefix is intersected with them. No
    /// scope at all is an EMPTY watch that delivers nothing until
    /// ``ProjectionWatchStream/setPaths(_:)`` names one; it never means
    /// every covered account. Change the roster with `setPaths` /
    /// `setPrefix` without re-subscribing.
    ///
    /// A path set comes back whole in the watch reply. A prefix scope is
    /// paginated: the reply carries the first page and this method fetches
    /// the rest over REST before returning, so
    /// ``ProjectionWatchStream/valuations`` starts complete. The server-side
    /// watch is connection-scoped; reconnects and rotations re-create it
    /// with the current scope automatically.
    ///
    /// Requires `arca:ReadProjection` on the projection name. The stream
    /// never receives balances, reserved balances, fills, orders, or any
    /// field outside the projection's registered set.
    ///
    /// - Parameters:
    ///   - name: Projection name.
    ///   - paths: Exact object paths to watch (max 500).
    ///   - prefix: A sub-tree of the projection to watch.
    ///   - exchange: Exchange identifier for mid prices (default: `"sim"`).
    public func watchProjection(name: String, paths: [String] = [], prefix: String? = nil, exchange: String = "sim") async throws -> ProjectionWatchStream {
        await ws.ensureConnected()
        let initialScope = ProjectionWatchScope(paths: paths, prefix: prefix)

        let fetchRemaining: @Sendable (ProjectionWatchCreated, ProjectionWatchScope) async throws -> [ProjectedValuation] = { [weak self] reply, scope in
            var all = reply.valuations
            var next = reply.cursor
            while let cursor = next, let self {
                let page = try await self.getProjectionValuations(name: name, prefix: scope.wirePrefix, cursor: cursor)
                all.append(contentsOf: page.valuations)
                next = page.cursor
            }
            return all
        }

        let created = try await ws.createProjectionWatch(projection: name, scope: initialScope)
        let initial = try await fetchRemaining(created, initialScope)
        var initialMap: [String: ProjectedValuation] = [:]
        for v in initial { initialMap[v.path] = v }

        let state = SendableBox<WatchStreamState>(.loading)
        // structuralBox holds server truth; valBox holds the re-marked view.
        let structuralBox = SendableBox<[String: ProjectedValuation]>(initialMap)
        let valBox = SendableBox<[String: ProjectedValuation]>(initialMap)
        let midsBox = SendableBox<[String: String]>([:])
        let widBox = SendableBox<String>(created.watchId)
        let scopeBox = SendableBox<ProjectionWatchScope>(initialScope)
        let continuationBox = SendableBox<AsyncStream<[String: ProjectedValuation]>.Continuation?>(nil)
        let refreshingBox = SendableBox<Bool>(false)
        let stoppedBox = SendableBox<Bool>(false)
        let projCallbacks = SendableBox<[UUID: @Sendable ([String: ProjectedValuation]) -> Void]>([:])

        // The stream's mids interest is the union of its rows' position
        // markets: the manager subscribes the Arca socket to that union
        // (and the direct provider, when preferred), never to every market.
        let priceInterest = await ws.registerPriceMarkets()
        let interestRevision = SendableBox<UInt64>(0)
        let syncInterest: @Sendable () -> Void = { [ws] in
            let markets = Set(structuralBox.value.values.flatMap { ($0.positions ?? []).map(\.market) })
            let revision = interestRevision.updateAndGet { $0 += 1 }
            Task { await ws.updatePriceMarkets(priceInterest, markets: markets, revision: revision) }
        }
        await ws.updatePriceMarkets(priceInterest, markets: Set(initialMap.values.flatMap { ($0.positions ?? []).map(\.market) }))

        let emit: @Sendable () -> Void = {
            let mids = midsBox.value
            let structural = structuralBox.value
            let out = mids.isEmpty ? structural : structural.mapValues { $0.revalued(with: mids) }
            valBox.update { $0 = out }
            continuationBox.value?.yield(out)
            for cb in projCallbacks.value.values { cb(out) }
        }

        // The server-side watch lives on the connection that created it, so
        // every reconnect and every rotation must re-create it with the
        // CURRENT scope (and refetch the snapshot — deltas that fired
        // during the gap are gone).
        let recreateWatch: @Sendable () async -> Void = { [weak self] in
            guard let self = self, !stoppedBox.value else { return }
            guard !refreshingBox.value else { return }
            refreshingBox.update { $0 = true }
            do {
                let oldWatchId = widBox.value
                let scope = scopeBox.value
                let newWatch = try await self.ws.createProjectionWatch(projection: name, scope: scope)
                let vals = try await fetchRemaining(newWatch, scope)
                guard !stoppedBox.value else {
                    await self.ws.destroyProjectionWatch(watchId: newWatch.watchId)
                    refreshingBox.update { $0 = false }
                    return
                }
                widBox.update { $0 = newWatch.watchId }
                // Best-effort: the server ignores unknown watch IDs, so this
                // is safe even when the old watch died with the old socket.
                await self.ws.destroyProjectionWatch(watchId: oldWatchId)
                var map: [String: ProjectedValuation] = [:]
                for v in vals { map[v.path] = v }
                structuralBox.update { $0 = map }
                syncInterest()
                emit()
            } catch {
                // Best effort — keep existing data.
                self.log.warning("watch", "projection watch re-create failed",
                                 error: error, metadata: ["projection": name])
            }
            refreshingBox.update { $0 = false }
        }

        // Scope changes are serialized so a later setPaths always wins; the
        // reply is the full snapshot of the new scope and replaces the rows.
        let scopeQueue = SerialAsyncQueue()
        let applyScope: @Sendable (ProjectionWatchScope) async throws -> Void = { [weak self] scope in
            guard let self else { return }
            try await scopeQueue.run { [self] in
                guard !stoppedBox.value else { return }
                scopeBox.update { $0 = scope }
                let reply = try await self.ws.updateProjectionWatch(watchId: widBox.value, scope: scope)
                let vals = try await fetchRemaining(reply, scope)
                guard !stoppedBox.value, scopeBox.value == scope else { return } // superseded
                var map: [String: ProjectedValuation] = [:]
                for v in vals { map[v.path] = v }
                structuralBox.update { $0 = map }
                syncInterest()
                emit()
            }
        }

        let statusStream = await ws.statusStream
        let statusTask = Task {
            for await s in statusStream {
                if s == .disconnected && state.value != .loading {
                    state.update { $0 = .reconnecting }
                } else if s == .connected && state.value == .reconnecting {
                    await recreateWatch()
                    state.update { $0 = .connected }
                }
            }
        }

        // A rotation swaps the socket without an outage — no status change
        // fires — but the replacement connection has no projection watch, so
        // re-create it there too.
        let rotatedStream = await ws.rotatedStream
        let rotatedTask = Task {
            for await _ in rotatedStream {
                await recreateWatch()
            }
        }

        await ws.acquireMids(exchange: exchange, allMarkets: false)

        let projEvents = await ws.projectionValuationEvents()
        let midsStream = await ws.midsEvents()

        let updates = AsyncStream([String: ProjectedValuation].self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuationBox.update { $0 = continuation }

            let deltaTask = Task {
                for await (eventWatchId, deltas, removed, _) in projEvents {
                    guard eventWatchId == widBox.value else { continue }
                    structuralBox.update { current in
                        for (path, valuation) in deltas {
                            current[path] = valuation
                        }
                        if let removed {
                            for path in removed {
                                current.removeValue(forKey: path)
                            }
                        }
                    }
                    state.update { $0 = .connected }
                    syncInterest()
                    emit()
                }
                continuation.finish()
            }

            let midsTask = Task {
                for await mids in midsStream {
                    midsBox.update { current in
                        for (key, value) in mids { current[key] = value }
                    }
                    emit()
                }
            }

            continuation.onTermination = { _ in
                deltaTask.cancel()
                midsTask.cancel()
            }
        }

        state.update { $0 = .connected }

        var stream = ProjectionWatchStream(
            state: state,
            projection: name,
            fields: created.fields,
            watchId: widBox,
            scope: scopeBox,
            valuations: valBox,
            updates: updates,
            stop: { [ws] in
                stoppedBox.update { $0 = true }
                continuationBox.update { $0 = nil }
                statusTask.cancel()
                rotatedTask.cancel()
                await ws.releasePriceMarkets(priceInterest)
                await ws.releaseMids(allMarkets: false)
                await ws.destroyProjectionWatch(watchId: widBox.value)
            },
            updateCallbacks: projCallbacks
        )
        stream.updateScope = applyScope
        return stream
    }
}

/// Runs async work one item at a time, in call order. Used to serialize a
/// stream's scope changes so a later `setPaths` always wins.
actor SerialAsyncQueue {
    private var tail: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Void, Error> {
            await previous?.value
            try await work()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}

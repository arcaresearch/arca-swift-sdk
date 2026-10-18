import Foundation

// MARK: - V9 funding: the wallet snapshot, its stream and money figures
//
// One read and one stream per owner-facing wallet, composed by Arca from
// stored records at one journal position (documents/contracts/v9-wallet-snapshot.md,
// documents/contracts/v9-wallet-streams.md), and the money figures a product
// renders from them (documents/contracts/sdk-money-figure.md). The realm is
// the one this client was initialised for.

public extension Arca {
    /// The complete wallet at one journal position: Cash, every trading
    /// account under `arcaPath`, money in flight and funding operations.
    /// Requires `arca:ReadObject` on the root and the Cash path — a
    /// realm-scoped device token is enough. Pass an empty `boundaryId` for a
    /// wallet that has registered its funding source but not set up Cash.
    func walletSnapshot(ownerAddress: String, arcaPath: String, boundaryId: String) async throws -> WalletSnapshot {
        let snapshot: WalletSnapshot = try await client.get("/custody/v9/funding/wallet-snapshot",
                                                            query: Self.walletQuery(realm: realm, ownerAddress: ownerAddress, arcaPath: arcaPath, boundaryId: boundaryId))
        guard snapshot.schema == walletSnapshotSchema else {
            throw ArcaError.unknown(code: "SCHEMA_UNSUPPORTED", message: "wallet snapshot schema \(snapshot.schema) is not supported by this SDK", errorId: nil)
        }
        return snapshot
    }

    /// The money figures of one wallet from a one-shot read:
    /// ``WalletMoney/compose(_:previous:predictions:revaluations:)`` of
    /// ``walletSnapshot(ownerAddress:arcaPath:boundaryId:)``. To follow the
    /// wallet, use ``watchWalletMoney(ownerAddress:arcaPath:boundaryId:)``.
    func walletMoney(ownerAddress: String, arcaPath: String, boundaryId: String) async throws -> WalletMoney {
        WalletMoney.compose(try await walletSnapshot(ownerAddress: ownerAddress, arcaPath: arcaPath, boundaryId: boundaryId))
    }

    /// Stream one wallet's snapshots: a complete snapshot on connect and
    /// after every change to Cash, a trading account, an operation or a
    /// deposit address, coalesced to at most one per 250 ms. Every element is
    /// the whole wallet at one journal position — replace what you show.
    ///
    /// Resume is automatic: after a disconnect the stream reconnects with
    /// `Last-Event-ID` set to the last snapshot's `watermark.sequence`,
    /// backing off 1 s → 30 s and resetting once a snapshot is delivered,
    /// and the server answers with exactly one fresh snapshot. A 401/403 is
    /// retried once with a refreshed credential when a token provider is
    /// configured. The stream ends by throwing only when the server refuses
    /// the connection (not found, forbidden, the per-key stream cap);
    /// cancelling the consuming task ends it silently.
    func walletSnapshotEvents(ownerAddress: String, arcaPath: String, boundaryId: String) -> AsyncThrowingStream<WalletSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [client, realm, log] in
                let runner = WalletSnapshotStreamRunner(client: client, realm: realm, ownerAddress: ownerAddress, arcaPath: arcaPath, boundaryId: boundaryId, log: log)
                await runner.run(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Watch one wallet's money figures: ``WalletMoneyWatchStream/money`` is
    /// the latest ``WalletMoney`` and ``WalletMoneyWatchStream/updates``
    /// yields each new one. Every figure a product shows — the total, Cash,
    /// each account, every leg in motion — comes from the same frame, so
    /// figures that changed together in Arca change together on screen.
    ///
    /// Tell the watch about an accepted operation with
    /// ``WalletMoneyWatchStream/predict(_:)`` so its legs show before the
    /// first frame carries it, and give it venue frames with
    /// ``WalletMoneyWatchStream/revalue(_:)`` so an account's figure can tick
    /// between snapshots without ever being added to.
    ///
    /// ```swift
    /// let watch = arca.watchWalletMoney(ownerAddress: owner, arcaPath: root, boundaryId: cash)
    /// for await money in watch.updates {
    ///     render(money.total, money.cash, money.orderedAccounts)
    /// }
    /// ```
    func watchWalletMoney(ownerAddress: String, arcaPath: String, boundaryId: String) -> WalletMoneyWatchStream {
        let stream = WalletMoneyWatchStream(log: log)
        let events = walletSnapshotEvents(ownerAddress: ownerAddress, arcaPath: arcaPath, boundaryId: boundaryId)
        stream.start(events: events)
        return stream
    }

    internal static func walletQuery(realm: String, ownerAddress: String, arcaPath: String, boundaryId: String) -> [String: String] {
        var query = ["realmId": realm, "ownerAddress": ownerAddress, "arcaPath": arcaPath]
        if !boundaryId.isEmpty { query["boundaryId"] = boundaryId }
        return query
    }
}

// MARK: - WalletMoneyWatchStream

/// A live view of one wallet's money figures. One instance per wallet; share
/// it across screens so every surface renders the same frame.
public final class WalletMoneyWatchStream: @unchecked Sendable {
    /// `loading` until the first snapshot, then `connected`; `reconnecting`
    /// is not surfaced because resume is silent and complete.
    public let state: SendableBox<WatchStreamState>
    /// The latest frame, nil before the first snapshot.
    public let money: SendableBox<WalletMoney?>
    /// Set when the server refused the stream (not found, forbidden, the
    /// per-key cap): the watch is dead and must be recreated.
    public let failure: SendableBox<Error?>
    /// Each new frame, buffered to the latest.
    public let updates: AsyncStream<WalletMoney>

    /// How long a predicted leg is kept when the stream never frames its
    /// operation (an operation Arca accepted is framed within a second).
    public var predictionBound: TimeInterval = 300

    private let continuation: AsyncStream<WalletMoney>.Continuation
    private let updateCallbacks = SendableBox<[UUID: @Sendable (WalletMoney) -> Void]>([:])
    private let log: ArcaLogger
    private let lock = NSLock()
    private var snapshot: WalletSnapshot?
    private var predictions: [String: MoneyPrediction] = [:]
    private var predictionTimers: [String: Task<Void, Never>] = [:]
    private var revaluations: [String: MoneyRevaluation] = [:]
    private var task: Task<Void, Never>?
    private var stopped = false

    init(log: ArcaLogger) {
        self.log = log
        state = SendableBox(.loading)
        money = SendableBox(nil)
        failure = SendableBox(nil)
        let (stream, continuation) = AsyncStream<WalletMoney>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream
        self.continuation = continuation
    }

    func start(events: AsyncThrowingStream<WalletSnapshot, Error>) {
        task = Task { [weak self] in
            do {
                for try await snapshot in events {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(snapshot: snapshot)
                }
            } catch {
                guard let self else { return }
                self.failure.update { $0 = error }
                self.log.error("stream", "wallet money stream refused", error: error)
            }
            self?.continuation.finish()
        }
    }

    /// Register a callback invoked on each frame. Returns an unsubscribe function.
    @discardableResult
    public func onUpdate(_ handler: @escaping @Sendable (WalletMoney) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        updateCallbacks.update { $0[id] = handler }
        return { [updateCallbacks] in
            updateCallbacks.update { $0.removeValue(forKey: id) }
        }
    }

    /// Returns when the first frame has been received. Never throws.
    public func ready() async {
        await state.wait(until: { $0 != .loading })
    }

    /// An accepted operation the server returned, so its legs show at once:
    /// "leaving" under its source and "arriving" under its destination. It
    /// never changes a figure. Retired in the frame that first carries the
    /// operation, or at ``predictionBound``.
    public func predict(_ prediction: MoneyPrediction) {
        lock.lock()
        predictions[prediction.requestId] = prediction
        predictionTimers[prediction.requestId]?.cancel()
        let bound = predictionBound
        predictionTimers[prediction.requestId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(bound * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retirePrediction(prediction.requestId, expired: true)
        }
        lock.unlock()
        recompose()
    }

    /// A venue frame for one account from an exchange-state watch. It is used
    /// as the account's `revaluedMicro` only when newer than the account's
    /// figure and no settlement toward the account is pending; it is never
    /// added to a figure.
    public func revalue(_ revaluation: MoneyRevaluation) {
        lock.lock()
        revaluations[revaluation.arcaId] = revaluation
        lock.unlock()
        recompose()
    }

    /// Drop a venue frame (the exchange-state watch for the account ended).
    public func clearRevaluation(arcaId: String) {
        lock.lock()
        revaluations.removeValue(forKey: arcaId)
        lock.unlock()
        recompose()
    }

    /// Stop listening. The watch cannot be restarted.
    public func stop() async {
        lock.lock()
        stopped = true
        let task = self.task
        self.task = nil
        let timers = predictionTimers.values
        predictionTimers = [:]
        lock.unlock()
        task?.cancel()
        for timer in timers { timer.cancel() }
        continuation.finish()
    }

    // MARK: - Internals

    private func apply(snapshot: WalletSnapshot) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard snapshot.supersedes(self.snapshot) else {
            lock.unlock()
            log.notice("stream", "ignored a wallet frame that is older or for another wallet",
                       metadata: ["sequence": String(snapshot.watermark.sequence), "owner": snapshot.ownerAddress])
            return
        }
        self.snapshot = snapshot
        // Predictions the frame now carries are retired here, in the same
        // application step, so no frame shows a predicted and a framed leg.
        let framed = Set(snapshot.operations.compactMap(\.requestId)).union(snapshot.operations.map(\.operationId))
        for (key, prediction) in predictions where framed.contains(key) || (prediction.operationId.map { framed.contains($0) } ?? false) {
            predictions.removeValue(forKey: key)
            predictionTimers.removeValue(forKey: key)?.cancel()
        }
        lock.unlock()
        recompose()
    }

    private func retirePrediction(_ requestId: String, expired: Bool) {
        lock.lock()
        guard predictions.removeValue(forKey: requestId) != nil else { lock.unlock(); return }
        predictionTimers.removeValue(forKey: requestId)
        lock.unlock()
        if expired {
            log.notice("stream", "a predicted leg reached its bound without a frame", metadata: ["requestId": requestId])
        }
        recompose(extraDiagnostics: expired ? [.predictionExpired(requestId: requestId)] : [])
    }

    private func recompose(extraDiagnostics: [MoneyDiagnostic] = []) {
        lock.lock()
        guard !stopped, let snapshot else { lock.unlock(); return }
        let previous = money.value
        let composed = WalletMoney.compose(snapshot, previous: previous, predictions: Array(predictions.values), revaluations: revaluations)
        lock.unlock()
        let published = extraDiagnostics.isEmpty ? composed : composed.withDiagnostics(composed.diagnostics + extraDiagnostics)
        for diagnostic in published.diagnostics where !(previous?.diagnostics.contains(diagnostic) ?? false) {
            log.notice("stream", "wallet money diagnostic", metadata: ["detail": String(describing: diagnostic), "sequence": String(published.watermark.sequence)])
        }
        money.update { $0 = published }
        state.update { if $0 == .loading { $0 = .connected } }
        continuation.yield(published)
        for callback in updateCallbacks.value.values { callback(published) }
    }
}

extension WalletMoney {
    func withDiagnostics(_ diagnostics: [MoneyDiagnostic]) -> WalletMoney {
        WalletMoney(total: total, cash: cash, accounts: accounts, accountOrder: accountOrder, operations: operations,
                    watermark: watermark, complete: complete, current: current, diagnostics: diagnostics, snapshot: snapshot)
    }
}

// MARK: - WalletSnapshotStreamRunner

/// The reconnect loop behind ``Arca/walletSnapshotEvents(ownerAddress:arcaPath:boundaryId:)``.
/// One instance per stream; not shared.
final class WalletSnapshotStreamRunner: @unchecked Sendable {
    private let client: ArcaClient
    private let realm: String
    private let ownerAddress: String
    private let arcaPath: String
    private let boundaryId: String
    private let log: ArcaLogger
    private let decoder = JSONDecoder()

    /// Journal position of the last delivered snapshot, sent as `Last-Event-ID`.
    private(set) var lastSequence: UInt64?

    init(client: ArcaClient, realm: String, ownerAddress: String, arcaPath: String, boundaryId: String, log: ArcaLogger) {
        self.client = client
        self.realm = realm
        self.ownerAddress = ownerAddress
        self.arcaPath = arcaPath
        self.boundaryId = boundaryId
        self.log = log
    }

    private enum Connection {
        case disconnected(Error?)
        case refreshAndRetry(AuthRefreshTrigger)
        case refused(ArcaError)
    }

    private var deliveredSinceLastBackoffReset = false

    func run(continuation: AsyncThrowingStream<WalletSnapshot, Error>.Continuation) async {
        var attempt = 0
        var refreshedThisAttempt = false
        while !Task.isCancelled {
            let outcome = await connect(continuation: continuation)
            if Task.isCancelled {
                continuation.finish()
                return
            }
            switch outcome {
            case .refused(let error):
                continuation.finish(throwing: error)
                return
            case .refreshAndRetry(let trigger):
                if refreshedThisAttempt || !client.canRefreshToken {
                    continuation.finish(throwing: trigger == .forbidden
                        ? ArcaError.forbidden(message: "wallet stream refused", errorId: nil)
                        : ArcaError.unauthorized(message: "wallet stream refused", errorId: nil))
                    return
                }
                do {
                    try await client.refreshToken(trigger)
                    refreshedThisAttempt = true
                    continue
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            case .disconnected(let error):
                if deliveredSinceLastBackoffReset {
                    attempt = 0
                    deliveredSinceLastBackoffReset = false
                }
                let delay = SSEBackoff.delay(attempt: attempt)
                log.notice("stream", "wallet stream disconnected; reconnecting", error: error,
                           metadata: ["arcaPath": arcaPath, "lastSequence": lastSequence.map(String.init) ?? "", "delaySeconds": String(delay)])
                attempt += 1
                refreshedThisAttempt = false
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    continuation.finish()
                    return
                }
            }
        }
        continuation.finish()
    }

    private func connect(continuation: AsyncThrowingStream<WalletSnapshot, Error>.Continuation) async -> Connection {
        let request = client.streamRequest(
            path: "/custody/v9/funding/wallet-stream",
            query: Arca.walletQuery(realm: realm, ownerAddress: ownerAddress, arcaPath: arcaPath, boundaryId: boundaryId),
            lastEventID: lastSequence.map(String.init)
        )
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await client.streamSession.bytes(for: request)
        } catch {
            if Task.isCancelled { return .disconnected(nil) }
            return .disconnected(ArcaError.networkError(underlying: error))
        }
        guard let http = response as? HTTPURLResponse else {
            return .disconnected(ArcaError.networkError(underlying: URLError(.badServerResponse)))
        }
        if http.statusCode != 200 {
            var body = Data()
            do {
                for try await byte in bytes { body.append(byte); if body.count > 64 * 1024 { break } }
            } catch {}
            let refusal = client.streamRefusal(data: body, statusCode: http.statusCode)
            switch refusal {
            case .unauthorized: return .refreshAndRetry(.unauthorized)
            case .forbidden: return .refreshAndRetry(.forbidden)
            default:
                if (502...504).contains(http.statusCode) {
                    return .disconnected(refusal)
                }
                return .refused(refusal)
            }
        }
        var parser = SSEParser()
        do {
            for try await byte in bytes {
                guard let frame = parser.consume(byte: byte) else { continue }
                if let event = frame.event, event != "snapshot" { continue } // position, heartbeat, control: never applied
                guard let data = frame.data.data(using: .utf8) else { continue }
                let snapshot: WalletSnapshot
                do {
                    snapshot = try decoder.decode(WalletSnapshot.self, from: data)
                } catch {
                    return .refused(ArcaError.decodingError(underlying: error))
                }
                if snapshot.schema != walletSnapshotSchema {
                    return .refused(ArcaError.unknown(code: "SCHEMA_UNSUPPORTED", message: "wallet snapshot schema \(snapshot.schema) is not supported by this SDK", errorId: nil))
                }
                lastSequence = frame.id.flatMap(UInt64.init) ?? snapshot.watermark.sequence
                deliveredSinceLastBackoffReset = true
                continuation.yield(snapshot)
            }
        } catch {
            if Task.isCancelled { return .disconnected(nil) }
            return .disconnected(ArcaError.networkError(underlying: error))
        }
        return .disconnected(nil)
    }
}

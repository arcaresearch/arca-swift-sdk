import Foundation

// MARK: - V9 cash: Wallet Account
//
// One read and one stream per owner-facing wallet, composed by Arca from
// durable records with no chain call (documents/contracts/v9-cash-wallet-integration.md,
// "Wallet Account read model" and "Streams"). The realm is the one this
// client was initialised for.

public extension Arca {
    /// The Wallet Account for one boundary: confirmed, available, pending in,
    /// pending out, `walletState`, the linked source, the automatic-deposit
    /// state and every operation the owner started. Requires
    /// `arca:ReadObject` on the boundary — a realm-scoped device token is
    /// enough. Throws ``ArcaError/notFound(code:message:errorId:)`` for an
    /// unknown boundary.
    func walletAccount(boundaryId: String) async throws -> WalletAccount {
        try await client.get("/custody/v9/cash/wallet-account", query: ["realmId": realm, "boundaryId": boundaryId])
    }

    /// The Wallet Account of the boundary an owner address controls (the
    /// active one when the owner has several). Not found when it has none.
    func walletAccount(ownerAddress: String) async throws -> WalletAccount {
        try await client.get("/custody/v9/cash/wallet-account", query: ["realmId": realm, "ownerAddress": ownerAddress])
    }

    /// Stream the Wallet Account of one boundary: a complete snapshot on
    /// connect and after every change to the boundary or to its linked
    /// address, coalesced to at most one per 250 ms. Every element is the
    /// whole state — replace what you show; a missed frame costs latency,
    /// never correctness.
    ///
    /// Resume is automatic: after a disconnect (the ingress resets
    /// connections about hourly) the stream reconnects with `Last-Event-ID`
    /// set to the last snapshot's `revision`, backing off 1 s → 30 s and
    /// resetting the backoff once a snapshot is delivered, and the server
    /// answers with exactly one fresh snapshot. A 401/403 is retried once
    /// with a refreshed credential when a token provider is configured.
    /// The stream ends by throwing only when the server refuses the
    /// connection (not found, forbidden, the per-key stream cap); cancelling
    /// the consuming task ends it silently.
    ///
    /// ```swift
    /// for try await wallet in arca.walletAccountEvents(boundaryId: boundaryId) {
    ///     render(wallet) // wallet.walletState, wallet.balances, wallet.operations
    /// }
    /// ```
    func walletAccountEvents(boundaryId: String) -> AsyncThrowingStream<WalletAccount, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [client, realm, log] in
                let runner = WalletAccountStreamRunner(client: client, realm: realm, boundaryId: boundaryId, log: log)
                await runner.run(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The reconnect loop behind ``Arca/walletAccountEvents(boundaryId:)``.
/// One instance per stream; not shared.
final class WalletAccountStreamRunner: @unchecked Sendable {
    private let client: ArcaClient
    private let realm: String
    private let boundaryId: String
    private let log: ArcaLogger
    private let decoder = JSONDecoder()

    /// Revision of the last delivered snapshot, sent as `Last-Event-ID`.
    private(set) var lastRevision: UInt64?

    init(client: ArcaClient, realm: String, boundaryId: String, log: ArcaLogger) {
        self.client = client
        self.realm = realm
        self.boundaryId = boundaryId
        self.log = log
    }

    private enum Connection {
        /// The connection ended (EOF, network error); reconnect.
        case disconnected(Error?)
        /// The server refused; retry once after a credential refresh.
        case refreshAndRetry(AuthRefreshTrigger)
        /// The server refused for good.
        case refused(ArcaError)
    }

    func run(continuation: AsyncThrowingStream<WalletAccount, Error>.Continuation) async {
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
                        ? ArcaError.forbidden(message: "Wallet Account stream refused", errorId: nil)
                        : ArcaError.unauthorized(message: "Wallet Account stream refused", errorId: nil))
                    return
                }
                do {
                    try await client.refreshToken(trigger)
                    refreshedThisAttempt = true
                    continue // reconnect immediately with the new credential
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            case .disconnected(let error):
                // A connection that delivered a snapshot starts the
                // schedule over; only consecutive failures climb it.
                if deliveredSinceLastBackoffReset {
                    attempt = 0
                    deliveredSinceLastBackoffReset = false
                }
                let delay = SSEBackoff.delay(attempt: attempt)
                log.notice("stream", "wallet account stream disconnected; reconnecting",
                           error: error,
                           metadata: ["boundaryId": boundaryId, "lastRevision": lastRevision.map(String.init) ?? "", "delaySeconds": String(delay)])
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

    /// Set when a connection delivered at least one snapshot, so the next
    /// disconnect starts the backoff over.
    private var deliveredSinceLastBackoffReset = false

    private func connect(continuation: AsyncThrowingStream<WalletAccount, Error>.Continuation) async -> Connection {
        let request = client.streamRequest(
            path: "/custody/v9/cash/wallet-account/events",
            query: ["realmId": realm, "boundaryId": boundaryId],
            lastEventID: lastRevision.map(String.init)
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
                    return .disconnected(refusal) // the ingress; not the API's answer
                }
                return .refused(refusal)
            }
        }
        var parser = SSEParser()
        do {
            for try await byte in bytes {
                guard let frame = parser.consume(byte: byte) else { continue }
                if let event = frame.event, event != "snapshot" { continue } // unknown frames are never applied
                guard let data = frame.data.data(using: .utf8) else { continue }
                let snapshot: WalletAccount
                do {
                    snapshot = try decoder.decode(WalletAccount.self, from: data)
                } catch {
                    return .refused(ArcaError.decodingError(underlying: error))
                }
                if snapshot.schema != 1 {
                    return .refused(ArcaError.unknown(code: "SCHEMA_UNSUPPORTED", message: "Wallet Account schema \(snapshot.schema) is not supported by this SDK", errorId: nil))
                }
                lastRevision = snapshot.revision
                deliveredSinceLastBackoffReset = true
                continuation.yield(snapshot)
            }
        } catch {
            if Task.isCancelled { return .disconnected(nil) }
            return .disconnected(ArcaError.networkError(underlying: error))
        }
        // A clean end of body is the ingress's periodic reset, never completion.
        return .disconnected(nil)
    }
}

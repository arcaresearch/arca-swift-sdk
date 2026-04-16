import Foundation

/// Async function that returns a fresh scoped JWT token.
public typealias TokenProvider = @Sendable () async throws -> String

/// Actor managing token lifecycle: proactive refresh, deduplication, and auth error events.
public actor TokenManager {
    private let provider: TokenProvider?
    private var pendingRefresh: Task<String, Error>?
    private var proactiveRefreshTask: Task<Void, Never>?
    private var authErrorHandlers: [UUID: @Sendable (Error) -> Void] = [:]
    private var log: ArcaLogger = .disabled

    private static let refreshBufferSeconds: TimeInterval = 30

    public init(provider: TokenProvider?) {
        self.provider = provider
    }

    /// Attach the SDK's logger. Called by ``Arca`` during initialization so
    /// the token manager can emit records under the `auth` category.
    public func attachLogger(_ logger: ArcaLogger) {
        self.log = logger
    }

    /// Whether a token provider is configured.
    public var hasProvider: Bool { provider != nil }

    /// Call the token provider, deduplicating concurrent calls.
    /// Throws if no provider is configured or the provider fails.
    public func refreshToken() async throws -> String {
        if let pendingRefresh {
            return try await pendingRefresh.value
        }
        guard let provider else {
            throw ArcaError.unauthorized(message: "No token provider configured", errorId: nil)
        }
        log.debug("auth", "refreshing token via provider")
        let task = Task { try await provider() }
        self.pendingRefresh = task
        do {
            let token = try await task.value
            self.pendingRefresh = nil
            return token
        } catch {
            self.pendingRefresh = nil
            log.warning("auth", "token provider failed", error: error)
            throw error
        }
    }

    /// Schedule a proactive refresh ~30s before the token's `exp` claim.
    /// When the refresh succeeds, `onRefresh` is called with the new token.
    public func scheduleProactiveRefresh(
        token: String,
        onRefresh: @escaping @Sendable (String) async -> Void
    ) {
        proactiveRefreshTask?.cancel()
        guard provider != nil else { return }
        guard let exp = Self.extractExpiry(from: token) else { return }

        let delay = max(0, exp - Date().timeIntervalSince1970 - Self.refreshBufferSeconds)

        proactiveRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                guard let token = try await self?.refreshToken() else { return }
                await onRefresh(token)
            } catch {
                await self?.logProactiveRefreshFailed(error)
                await self?.emitAuthError(error)
            }
        }
    }

    private func logProactiveRefreshFailed(_ error: Error) {
        log.error("auth", "proactive token refresh failed; emitting auth error",
                  error: error)
    }

    /// Register a handler for unrecoverable authentication errors.
    /// Returns an ID to pass to ``removeAuthErrorHandler(_:)``.
    @discardableResult
    public func onAuthError(_ handler: @escaping @Sendable (Error) -> Void) -> UUID {
        let id = UUID()
        authErrorHandlers[id] = handler
        return id
    }

    /// Remove a previously registered auth error handler.
    public func removeAuthErrorHandler(_ id: UUID) {
        authErrorHandlers[id] = nil
    }

    /// Emit an auth error to all registered handlers.
    public func emitAuthError(_ error: Error) {
        for handler in authErrorHandlers.values {
            handler(error)
        }
    }

    // MARK: - JWT Expiry Extraction

    private static func extractExpiry(from token: String) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return exp
    }
}

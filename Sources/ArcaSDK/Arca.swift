import Foundation

/// The Arca SDK client for iOS apps.
///
/// Authenticates with a scoped JWT token (minted by the app's backend).
/// All methods are `async throws` and use Swift structured concurrency.
///
/// **Static token (manual refresh):**
/// ```swift
/// let arca = try Arca(token: scopedJwt)
/// ```
///
/// **With token provider (automatic refresh):**
/// ```swift
/// let arca = try Arca(token: scopedJwt, tokenProvider: {
///     let (data, _) = try await URLSession.shared.data(from: myRefreshURL)
///     return try JSONDecoder().decode(TokenResponse.self, from: data).token
/// })
/// ```
///
/// **Provider-only (no initial token):**
/// ```swift
/// let arca = try await Arca.withTokenProvider {
///     let (data, _) = try await URLSession.shared.data(from: myRefreshURL)
///     return try JSONDecoder().decode(TokenResponse.self, from: data).token
/// }
/// ```
public final class Arca: Sendable {
    public let client: ArcaClient
    public let ws: WebSocketManager
    public let tokenManager: TokenManager
    public let historyCache: HistoryCache

    /// Base URL for the candle CDN (e.g. `https://cdn.arcaos.io`).
    /// When set, `getCandles` fetches from CDN chunks for historical data.
    public let candleCdnBaseUrl: String?

    private let realmId: String

    /// Initialize the SDK from a scoped JWT token, with optional automatic refresh.
    ///
    /// - Parameters:
    ///   - token: Scoped JWT issued by your backend
    ///   - baseURL: Base URL of the Arca API (defaults to `https://api.arcaos.io`)
    ///   - realmId: Explicit realm ID override (decoded from token if omitted)
    ///   - tokenProvider: Optional async function that returns a fresh JWT.
    ///     When set, the SDK calls it proactively before expiry, on HTTP 401,
    ///     and on WebSocket reconnect.
    public init(
        token: String,
        baseURL: URL = URL(string: "https://api.arcaos.io")!,
        realmId: String? = nil,
        tokenProvider: TokenProvider? = nil,
        cache: CacheConfig = CacheConfig(),
        urlSessionConfiguration: URLSessionConfiguration = .default,
        candleCdnBaseUrl: String? = nil
    ) throws {
        let resolved = try realmId ?? Self.extractRealmId(from: token)

        self.realmId = resolved
        self.candleCdnBaseUrl = candleCdnBaseUrl
        self.tokenManager = TokenManager(provider: tokenProvider)
        self.historyCache = HistoryCache(config: cache)

        let mgr = self.tokenManager
        var onUnauthorized: (@Sendable () async throws -> String)?
        var wsGetToken: (@Sendable () async throws -> String)?
        if tokenProvider != nil {
            onUnauthorized = { try await mgr.refreshToken() }
            wsGetToken = { try await mgr.refreshToken() }
        }

        let onAuthError: @Sendable (Error) -> Void = { error in
            Task { await mgr.emitAuthError(error) }
        }

        self.client = ArcaClient(
            token: token,
            baseURL: baseURL,
            urlSessionConfiguration: urlSessionConfiguration,
            onUnauthorized: onUnauthorized,
            onAuthError: onAuthError
        )

        let wsURL = Self.httpToWebSocket(baseURL)
        self.ws = WebSocketManager(
            baseURL: wsURL,
            token: token,
            realmId: resolved,
            getToken: wsGetToken
        )

        if tokenProvider != nil {
            let weakClient = self.client
            let weakWS = self.ws
            Task {
                await self.tokenManager.scheduleProactiveRefresh(token: token) { newToken in
                    await weakClient.updateToken(newToken)
                    await weakWS.updateToken(newToken)
                }
            }
        }
    }

    /// Private init for provider-only factory method (realm already resolved).
    private init(
        realmId: String,
        token: String,
        baseURL: URL,
        tokenManager: TokenManager,
        client: ArcaClient,
        ws: WebSocketManager,
        historyCache: HistoryCache,
        candleCdnBaseUrl: String? = nil
    ) {
        self.realmId = realmId
        self.candleCdnBaseUrl = candleCdnBaseUrl
        self.tokenManager = tokenManager
        self.client = client
        self.ws = ws
        self.historyCache = historyCache
    }

    /// Create an Arca instance using only a token provider (no initial token).
    /// The provider is called immediately to obtain the first token.
    ///
    /// - Parameters:
    ///   - tokenProvider: Async function returning a fresh scoped JWT
    ///   - baseURL: Base URL of the Arca API
    ///   - realmId: Explicit realm ID (if not embedded in the token)
    public static func withTokenProvider(
        _ tokenProvider: @escaping TokenProvider,
        baseURL: URL = URL(string: "https://api.arcaos.io")!,
        realmId: String? = nil,
        cache: CacheConfig = CacheConfig(),
        candleCdnBaseUrl: String? = nil
    ) async throws -> Arca {
        let token = try await tokenProvider()
        return try Arca(
            token: token,
            baseURL: baseURL,
            realmId: realmId,
            tokenProvider: tokenProvider,
            cache: cache,
            candleCdnBaseUrl: candleCdnBaseUrl
        )
    }

    /// Update the bearer token after a refresh.
    /// Updates both the HTTP client and WebSocket manager.
    /// The WebSocket reconnects immediately if currently disconnected.
    public func updateToken(_ newToken: String) async {
        await client.updateToken(newToken)
        await ws.updateToken(newToken)

        let weakClient = self.client
        let weakWS = self.ws
        await tokenManager.scheduleProactiveRefresh(token: newToken) { token in
            await weakClient.updateToken(token)
            await weakWS.updateToken(token)
        }
    }

    /// Register a listener for unrecoverable authentication errors.
    /// Returns an ID to pass to ``removeAuthErrorHandler(_:)`` to unsubscribe.
    @discardableResult
    public func onAuthError(_ handler: @escaping @Sendable (Error) -> Void) async -> UUID {
        await tokenManager.onAuthError(handler)
    }

    /// Remove a previously registered auth error handler.
    public func removeAuthErrorHandler(_ id: UUID) async {
        await tokenManager.removeAuthErrorHandler(id)
    }

    /// Clear the in-memory cache of historical data responses
    /// (equity history, PnL history, candles).
    public func clearHistoryCache() async {
        await historyCache.clear()
    }

    /// The resolved realm ID for this SDK instance.
    public var realm: String { realmId }

    // MARK: - Operation Handle Factory

    /// Create an ``OperationHandle`` that starts the HTTP call eagerly
    /// and wires up WebSocket-based settlement waiting.
    func operationHandle<T: OperationResponse>(
        _ submit: @escaping @Sendable () async throws -> T
    ) -> OperationHandle<T> {
        OperationHandle(
            submit: submit,
            waitForSettlement: { [self] operationId in
                try await self.waitForSettlement(operationId)
            }
        )
    }

    // MARK: - JWT Payload Decoding

    private static func extractRealmId(from token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw ArcaError.validation(message: "Invalid JWT format — expected 3 parts", errorId: nil)
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let realmId = json["realmId"] as? String else {
            throw ArcaError.validation(
                message: "Token does not contain a realmId claim. Pass realmId explicitly.",
                errorId: nil
            )
        }

        return realmId
    }

    private static func httpToWebSocket(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url!
    }

    // MARK: - Order Breakdown

    /// Pure calculator that converts between spend (gross), notional (net), and
    /// token representations of an order. No network call.
    ///
    /// `tokens` in the result is the committed quantity submitted to the exchange.
    /// Dollar values are estimates at the provided `price`. For limit orders the
    /// breakdown is exact contingent on fill; for market orders, actual fill
    /// price may differ.
    public static func orderBreakdown(options opts: OrderBreakdownOptions) -> OrderBreakdown {
        let price = Double(opts.price) ?? 0
        let feeRate = Double(opts.feeRate) ?? 0
        let leverage = Double(opts.leverage)
        let amount = Double(opts.amount) ?? 0
        let szDecimals = opts.szDecimals

        let zero = OrderBreakdown(tokens: "0", notionalUsd: "0", marginRequired: "0",
                                  estimatedFee: "0", totalSpend: "0", price: opts.price, feeRate: opts.feeRate)
        guard price > 0, leverage > 0, feeRate >= 0, amount > 0 else { return zero }

        let notional: Double
        switch opts.amountType {
        case .spend:
            notional = amount / (1 / leverage + feeRate)
        case .notional:
            notional = amount
        case .tokens:
            notional = amount * price
        }

        let factor = pow(10.0, Double(szDecimals))
        let tokens = floor(notional / price * factor) / factor
        let actualNotional = tokens * price
        let marginRequired = actualNotional / leverage
        let estimatedFee = actualNotional * feeRate
        let totalSpend = marginRequired + estimatedFee

        func fmt(_ v: Double, _ d: Int = 8) -> String {
            guard v.isFinite else { return "0" }
            var s = String(format: "%.\(d)f", v)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }

        return OrderBreakdown(
            tokens: fmt(tokens, szDecimals),
            notionalUsd: fmt(actualNotional),
            marginRequired: fmt(marginRequired),
            estimatedFee: fmt(estimatedFee),
            totalSpend: fmt(totalSpend),
            price: opts.price,
            feeRate: opts.feeRate
        )
    }
}

/// Validate that a path argument starts with "/".
/// Paths without a trailing slash target a single object.
/// Paths with a trailing slash aggregate all objects under that prefix.
func validatePath(_ path: String) throws {
    guard path.hasPrefix("/") else {
        throw ArcaError.validation(
            message: "Path must start with '/'. Got: \"\(path)\". " +
            "Use a trailing slash for aggregation (e.g., '/users/alice/') " +
            "or an exact path for a single object (e.g., '/users/alice/main').",
            errorId: nil
        )
    }
}

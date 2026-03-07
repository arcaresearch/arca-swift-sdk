import Foundation

/// The Arca SDK client for iOS apps.
///
/// Authenticates with a scoped JWT token (minted by the app's backend).
/// All methods are `async throws` and use Swift structured concurrency.
///
/// ```swift
/// let arca = try Arca(token: scopedJwt, baseURL: URL(string: "https://api.arca.dev")!)
/// let objects = try await arca.listObjects()
/// ```
public final class Arca: Sendable {
    public let client: ArcaClient
    public let ws: WebSocketManager

    private let realmId: String

    /// Initialize the SDK from a scoped JWT token.
    ///
    /// The `realmId` is decoded from the token's JWT payload. If the token
    /// doesn't contain a `realmId` claim, pass it explicitly.
    ///
    /// - Parameters:
    ///   - token: Scoped JWT issued by your backend
    ///   - baseURL: Base URL of the Arca API (defaults to `https://api.arca.dev`)
    ///   - realmId: Explicit realm ID override (decoded from token if omitted)
    public init(token: String, baseURL: URL = URL(string: "https://api.arca.dev")!, realmId: String? = nil) throws {
        let resolved = try realmId ?? Self.extractRealmId(from: token)

        self.realmId = resolved
        self.client = ArcaClient(token: token, baseURL: baseURL)

        let wsURL = Self.httpToWebSocket(baseURL)
        self.ws = WebSocketManager(
            baseURL: wsURL,
            token: token,
            realmId: resolved
        )
    }

    /// Update the bearer token after a refresh.
    /// Updates both the HTTP client and WebSocket manager.
    public func updateToken(_ newToken: String) async {
        await client.updateToken(newToken)
        await ws.updateToken(newToken)
    }

    /// The resolved realm ID for this SDK instance.
    public var realm: String { realmId }

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
}

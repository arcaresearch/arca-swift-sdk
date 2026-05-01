import Foundation

// MARK: - Token Minting

/// Permission preset for ``Arca/mintDeviceToken(realmId:sub:forUserPath:permissions:expirationMinutes:)``.
public enum DeviceTokenPermissions: String, Sendable {
    /// `arca:Read` (the default — view-only).
    case read
    /// `arca:Read` + `arca:Exchange` (place/cancel orders + TWAPs +
    /// read exchange state). The "trading" preset for retail-style
    /// device tokens.
    case trade
    /// `arca:Read` + `arca:Write` (place orders, transfer, lifecycle).
    /// The widest preset; use only when the end-user needs full
    /// control over their resources.
    case full
}

/// Response from a token-minting call.
public struct MintTokenResponse: Codable, Sendable {
    public let token: String
    public let expiresAt: String
    public let jti: String?

    public init(token: String, expiresAt: String, jti: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.jti = jti
    }
}

extension Arca {

    /// Mint a scoped JWT for a single end-user device with one of three
    /// preset permission levels, instead of constructing IAM
    /// ``PolicyStatement``s by hand.
    ///
    /// This call requires the **caller's** current token to have
    /// sufficient permission to mint scoped tokens (typically a
    /// builder-issued JWT, not a device token). It is intended for
    /// builder-side code that issues device tokens for end users —
    /// e.g. an iOS server-side helper that mints a per-user token
    /// after authenticating the user with the builder's own auth.
    ///
    /// The presets are:
    ///
    /// | preset    | actions                                                      |
    /// |-----------|--------------------------------------------------------------|
    /// | `.read`   | `arca:Read` (view-only — the default device token shape)     |
    /// | `.trade`  | `arca:Read` + `arca:Exchange` (place/cancel orders + TWAPs)  |
    /// | `.full`   | `arca:Read` + `arca:Write` (place orders, transfer, etc.)    |
    ///
    /// `forUserPath` is the resource scope: pass the path subtree the
    /// end-user owns (e.g. `"/users/alice"`) and the token will only
    /// be usable on resources at or below that path. Defaults to `"*"`
    /// (no resource restriction).
    ///
    /// ```swift
    /// // Issue a "trading" token for an iOS device — can place orders
    /// // and TWAPs on alice's resources only.
    /// let response = try await arca.mintDeviceToken(
    ///     realmId: "rlm_...",
    ///     sub: "alice",
    ///     forUserPath: "/users/alice",
    ///     permissions: .trade,
    ///     expirationMinutes: 60
    /// )
    /// ```
    public func mintDeviceToken(
        realmId: String,
        sub: String,
        forUserPath: String? = nil,
        permissions: DeviceTokenPermissions = .read,
        expirationMinutes: Int? = nil
    ) async throws -> MintTokenResponse {
        let resource = forUserPath ?? "*"
        let actions: [String]
        switch permissions {
        case .read:
            actions = ["arca:Read"]
        case .trade:
            actions = ["arca:Read", "arca:Exchange"]
        case .full:
            actions = ["arca:Read", "arca:Write"]
        }
        let body = MintTokenRequest(
            realmId: realmId,
            sub: sub,
            scope: TokenScope(statements: [
                PolicyStatement(effect: "Allow", actions: actions, resources: [resource])
            ]),
            expirationMinutes: expirationMinutes
        )
        return try await client.post("/auth/token", body: body)
    }
}

// MARK: - Internal Request Types

struct MintTokenRequest: Encodable {
    let realmId: String
    let sub: String
    let scope: TokenScope
    let expirationMinutes: Int?
}

public struct TokenScope: Codable, Sendable {
    public let statements: [PolicyStatement]

    public init(statements: [PolicyStatement]) {
        self.statements = statements
    }
}

public struct PolicyStatement: Codable, Sendable {
    public let effect: String
    public let actions: [String]
    public let resources: [String]

    public init(effect: String, actions: [String], resources: [String]) {
        self.effect = effect
        self.actions = actions
        self.resources = resources
    }
}

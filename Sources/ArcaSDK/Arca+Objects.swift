import Foundation

// MARK: - Arca Object Operations

extension Arca {

    /// Create a denominated Arca object at the given path (idempotent).
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - ref: Full Arca path (e.g. `/users/u123/usd/main`)
    ///   - denomination: Currency denomination (e.g. `USD`, `BTC`)
    ///   - metadata: Optional metadata string
    ///   - operationPath: Optional idempotency key (use nonce API with separator `:`)
    public func createDenominatedArca(
        ref: String,
        denomination: String,
        metadata: String? = nil,
        operationPath: String? = nil
    ) -> OperationHandle<CreateArcaObjectResponse> {
        operationHandle { [self] in
            try await client.post("/objects", body: CreateObjectRequest(
                realmId: realm,
                path: ref,
                type: "denominated",
                denomination: denomination,
                metadata: metadata,
                operationPath: operationPath
            ))
        }
    }

    /// Create an Arca object of any type at the given path (idempotent).
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - ref: Full Arca path
    ///   - type: Object type
    ///   - denomination: Denomination (required for `denominated` type)
    ///   - metadata: Optional metadata string
    ///   - operationPath: Optional idempotency key
    public func createArca(
        ref: String,
        type: ArcaObjectType,
        denomination: String? = nil,
        metadata: String? = nil,
        operationPath: String? = nil
    ) -> OperationHandle<CreateArcaObjectResponse> {
        operationHandle { [self] in
            try await client.post("/objects", body: CreateObjectRequest(
                realmId: realm,
                path: ref,
                type: type.rawValue,
                denomination: denomination,
                metadata: metadata,
                operationPath: operationPath
            ))
        }
    }

    /// Delete an Arca object by path.
    ///
    /// Returns an ``OperationHandle`` — use `try await handle.settled` to wait
    /// for full settlement, or `try await handle.submitted` for the HTTP response.
    ///
    /// - Parameters:
    ///   - ref: Arca path to delete
    ///   - sweepTo: Optional path to sweep remaining funds into before deletion
    ///   - liquidatePositions: If true, liquidate all exchange positions first
    ///   - operationPath: Optional idempotency key
    public func ensureDeleted(
        ref: String,
        sweepTo: String? = nil,
        liquidatePositions: Bool = false,
        operationPath: String? = nil
    ) -> OperationHandle<DeleteArcaObjectResponse> {
        operationHandle { [self] in
            try await client.post("/objects/delete", body: DeleteObjectRequest(
                realmId: realm,
                path: ref,
                sweepToPath: sweepTo,
                liquidatePositions: liquidatePositions,
                operationPath: operationPath
            ))
        }
    }

    /// Get an Arca object by path.
    public func getObject(path: String) async throws -> ArcaObject {
        try await client.get("/objects/by-path", query: [
            "realmId": realm,
            "path": path,
        ])
    }

    /// Get full detail for an Arca object by ID (operations, events, deltas, balances, positions).
    public func getObjectDetail(objectId: String) async throws -> ArcaObjectDetailResponse {
        try await client.get("/objects/\(objectId)")
    }

    /// List Arca objects, optionally filtered by path prefix.
    public func listObjects(prefix: String? = nil, includeDeleted: Bool = false) async throws -> ArcaObjectListResponse {
        var query: [String: String] = ["realmId": realm]
        if let prefix = prefix { query["prefix"] = prefix }
        if includeDeleted { query["includeDeleted"] = "true" }
        return try await client.get("/objects", query: query)
    }

    /// Get balances for an Arca object by ID.
    public func getBalances(objectId: String) async throws -> [ArcaBalance] {
        let response: ArcaBalanceListResponse = try await client.get("/objects/\(objectId)/balances")
        return response.balances
    }

    /// Get balances for an Arca object by path.
    public func getBalancesByPath(path: String) async throws -> [ArcaBalance] {
        let obj = try await getObject(path: path)
        return try await getBalances(objectId: obj.id.rawValue)
    }

    /// Browse objects in a folder-like structure at the given prefix.
    public func browseObjects(prefix: String = "/", includeDeleted: Bool = false) async throws -> ArcaObjectBrowseResponse {
        var query: [String: String] = ["realmId": realm, "prefix": prefix]
        if includeDeleted { query["includeDeleted"] = "true" }
        return try await client.get("/objects/browse", query: query)
    }

    /// Get version history for an Arca object.
    public func getObjectVersions(objectId: String) async throws -> ArcaObjectVersionsResponse {
        try await client.get("/objects/\(objectId)/versions")
    }

    /// Get snapshot balances at a specific point in time.
    public func getSnapshotBalances(objectId: String, asOf: String) async throws -> SnapshotBalancesResponse {
        try await client.get("/objects/\(objectId)/snapshot", query: [
            "realmId": realm,
            "asOf": asOf,
        ])
    }
}

// MARK: - Request Bodies

private struct CreateObjectRequest: Encodable {
    let realmId: String
    let path: String
    let type: String
    let denomination: String?
    let metadata: String?
    let operationPath: String?
}

private struct DeleteObjectRequest: Encodable {
    let realmId: String
    let path: String
    let sweepToPath: String?
    let liquidatePositions: Bool
    let operationPath: String?
}

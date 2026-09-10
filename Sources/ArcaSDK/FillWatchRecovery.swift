import Foundation

private enum FillWatchRecoveryError: Error { case repeatedCursor, pageLimit, acknowledgementTimeout }

/// Preserve live rows that arrive while the paginated snapshot is in flight.
/// Stable venue IDs join previews to ledger rows; order IDs do not identify a fill.
func mergeWatchedFills(_ existing: [Fill], _ incoming: [Fill]) -> [Fill] {
    let all = existing + incoming
    let recorded = Set(all.filter { $0.operationId?.isEmpty == false }.map { $0.fillId ?? $0.id })
    var seen = Set<[String?]>()
    let result = all.filter { fill in
        let key = fill.fillId.flatMap { $0.isEmpty ? nil : $0 } ?? fill.id
        let isRecorded = fill.operationId?.isEmpty == false
        if !isRecorded && recorded.contains(key) { return false }
        // Keep conflicting accounting rows so receipt refinement can reject them.
        return seen.insert([key, isRecorded ? "recorded" : "preview", fill.orderId, fill.orderOperationId,
                            fill.size, fill.price, fill.market, fill.side?.rawValue]).inserted
    }
    return result.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }

}

extension Arca {
    /// A finite traversal; repeated cursors are a failed snapshot, never a loop.
    func fillWatchSnapshot(objectId: String, market: String?, limit: Int?) async throws -> [Fill] {
        var cursor: String?, seen = Set<String>(), fills: [Fill] = []
        for _ in 0..<1000 {
            try Task.checkCancellation()
            let page = try await listFills(objectId: objectId, market: market, limit: limit, cursor: cursor)
            fills.append(contentsOf: page.fills)
            guard let next = page.cursor, !next.isEmpty else { return mergeWatchedFills([], fills) }
            guard seen.insert(next).inserted else { throw FillWatchRecoveryError.repeatedCursor }
            cursor = next
        }
        throw FillWatchRecoveryError.pageLimit
    }
}

func fillWatchReady(_ ws: WebSocketManager, path: String) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await ws.recoverPathReady(path) }
        group.addTask {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw FillWatchRecoveryError.acknowledgementTimeout
        }
        try await group.next()
    }
}

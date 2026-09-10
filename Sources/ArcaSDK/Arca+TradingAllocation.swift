import Foundation

extension Arca {
    /// Read capability, intent and allocation at one mirror observation.
    public func getTradingAllocation(objectId: String, market: String? = nil) async throws -> TradingAllocationRead {
        var query: [String: String] = [:]
        if let market { query["market"] = market }
        return try await client.get("/objects/\(objectId)/exchange/allocation", query: query)
    }

    /// Estimate only. Reserves nothing and never submits or resizes an order.
    public func quoteTradingAllocation(objectId: String, request: TradingAllocationQuoteRequest) async throws -> TradingAllocationQuote {
        try await client.post("/objects/\(objectId)/exchange/allocation/quote", body: request)
    }
}

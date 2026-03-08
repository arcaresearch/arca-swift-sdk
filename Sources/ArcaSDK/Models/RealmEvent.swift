import Foundation

/// An event received from the Arca WebSocket stream.
/// All fields except `type` are optional — their presence depends on the event type.
public struct RealmEvent: Codable, Sendable {
    public let realmId: String?
    public let type: String
    public let entityId: String?
    public let entityPath: String?
    public let summary: ExplorerSummary?
    public let operation: Operation?
    public let event: ArcaEvent?
    public let object: ArcaObject?
    public let mids: [String: String]?
    public let exchangeState: ExchangeState?
    public let aggregation: PathAggregation?
    public let coin: String?
    public let interval: String?
    public let candle: Candle?
}

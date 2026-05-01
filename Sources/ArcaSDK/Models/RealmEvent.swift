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
    public let valuation: ObjectValuation?
    public let path: String?
    public let watchId: String?
    public let aggregation: PathAggregation?
    public let coin: String?
    public let interval: String?
    public let candle: Candle?
    public let fill: SimFill?
    /// Platform-level fill data, present on `fill.recorded` events.
    /// Decoded from the same `fill` JSON key as `SimFill`, but with the
    /// platform `Fill` schema (includes `operationId`, `resultingPosition`, etc.).
    public let recordedFill: Fill?
    public let funding: FundingPayment?
    public let trade: MarketTrade?
    public let realm: Realm?
    /// The full server-side ``Twap`` snapshot, attached to every TWAP
    /// event (`twap.started`, `twap.progress`, `twap.completed`,
    /// `twap.cancelled`, `twap.failed`). Use this in preference to
    /// individual progress fields to render UI state consistently.
    public let twap: Twap?

    /// Present and true when the server detected and corrected a cache drift.
    public let driftCorrected: Bool?

    // Envelope fields (Convergent Event Spine)
    public let eventId: String?
    public let correlationId: String?
    public let sequence: Int?
    public let timestamp: String?
    public let deliverySeq: Int?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        realmId = try container.decodeIfPresent(String.self, forKey: .realmId)
        type = try container.decode(String.self, forKey: .type)
        entityId = try container.decodeIfPresent(String.self, forKey: .entityId)
        entityPath = try container.decodeIfPresent(String.self, forKey: .entityPath)
        summary = try container.decodeIfPresent(ExplorerSummary.self, forKey: .summary)
        operation = try container.decodeIfPresent(Operation.self, forKey: .operation)
        event = try container.decodeIfPresent(ArcaEvent.self, forKey: .event)
        object = try container.decodeIfPresent(ArcaObject.self, forKey: .object)
        mids = try container.decodeIfPresent([String: String].self, forKey: .mids)
        exchangeState = try container.decodeIfPresent(ExchangeState.self, forKey: .exchangeState)
        valuation = try container.decodeIfPresent(ObjectValuation.self, forKey: .valuation)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        watchId = try container.decodeIfPresent(String.self, forKey: .watchId)
        aggregation = try container.decodeIfPresent(PathAggregation.self, forKey: .aggregation)
        coin = try container.decodeIfPresent(String.self, forKey: .coin)
        interval = try container.decodeIfPresent(String.self, forKey: .interval)
        candle = try container.decodeIfPresent(Candle.self, forKey: .candle)
        funding = try container.decodeIfPresent(FundingPayment.self, forKey: .funding)
        trade = try container.decodeIfPresent(MarketTrade.self, forKey: .trade)
        realm = try container.decodeIfPresent(Realm.self, forKey: .realm)
        twap = try container.decodeIfPresent(Twap.self, forKey: .twap)
        driftCorrected = try container.decodeIfPresent(Bool.self, forKey: .driftCorrected)
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        correlationId = try container.decodeIfPresent(String.self, forKey: .correlationId)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        deliverySeq = try container.decodeIfPresent(Int.self, forKey: .deliverySeq)

        if type == EventType.fillRecorded.rawValue {
            fill = nil
            recordedFill = try container.decodeIfPresent(Fill.self, forKey: .fill)
        } else {
            fill = try container.decodeIfPresent(SimFill.self, forKey: .fill)
            recordedFill = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case realmId, type, entityId, entityPath, summary, operation, event, object
        case mids, exchangeState, valuation, path, watchId, aggregation
        case coin, interval, candle, fill, funding, trade, realm, twap, driftCorrected
        case eventId, correlationId, sequence, timestamp, deliverySeq
    }

    public init(
        realmId: String? = nil, type: String, entityId: String? = nil, entityPath: String? = nil,
        summary: ExplorerSummary? = nil, operation: Operation? = nil, event: ArcaEvent? = nil,
        object: ArcaObject? = nil, mids: [String: String]? = nil, exchangeState: ExchangeState? = nil,
        valuation: ObjectValuation? = nil, path: String? = nil, watchId: String? = nil,
        aggregation: PathAggregation? = nil, coin: String? = nil, interval: String? = nil,
        candle: Candle? = nil, fill: SimFill? = nil, recordedFill: Fill? = nil,
        funding: FundingPayment? = nil, trade: MarketTrade? = nil,
        realm: Realm? = nil, twap: Twap? = nil, driftCorrected: Bool? = nil,
        eventId: String? = nil, correlationId: String? = nil, sequence: Int? = nil,
        timestamp: String? = nil, deliverySeq: Int? = nil
    ) {
        self.realmId = realmId; self.type = type; self.entityId = entityId; self.entityPath = entityPath
        self.summary = summary; self.operation = operation; self.event = event; self.object = object
        self.mids = mids; self.exchangeState = exchangeState; self.valuation = valuation
        self.path = path; self.watchId = watchId; self.aggregation = aggregation
        self.coin = coin; self.interval = interval; self.candle = candle
        self.fill = fill; self.recordedFill = recordedFill; self.funding = funding
        self.trade = trade; self.realm = realm; self.twap = twap; self.driftCorrected = driftCorrected
        self.eventId = eventId; self.correlationId = correlationId; self.sequence = sequence
        self.timestamp = timestamp; self.deliverySeq = deliverySeq
    }
}

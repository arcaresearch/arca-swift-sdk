import Foundation

/// Routing and correlation metadata common to all WebSocket events.
///
/// Separates the "spine" (who, what, when, correlation chain) from the
/// domain payload so builders don't sift through a bag of optionals.
public struct EventEnvelope: Sendable {
    public let realmId: String
    public let entityId: String
    public let entityPath: String?
    public let eventId: String?
    public let correlationId: String?
    public let sequence: Int?
    public let timestamp: String?
    public let deliverySeq: Int?

    public init(
        realmId: String,
        entityId: String,
        entityPath: String? = nil,
        eventId: String? = nil,
        correlationId: String? = nil,
        sequence: Int? = nil,
        timestamp: String? = nil,
        deliverySeq: Int? = nil
    ) {
        self.realmId = realmId
        self.entityId = entityId
        self.entityPath = entityPath
        self.eventId = eventId
        self.correlationId = correlationId
        self.sequence = sequence
        self.timestamp = timestamp
        self.deliverySeq = deliverySeq
    }

    /// Extract the envelope from a raw ``RealmEvent``.
    public init(from event: RealmEvent) {
        self.realmId = event.realmId ?? ""
        self.entityId = event.entityId ?? ""
        self.entityPath = event.entityPath
        self.eventId = event.eventId
        self.correlationId = event.correlationId
        self.sequence = event.sequence
        self.timestamp = event.timestamp
        self.deliverySeq = event.deliverySeq
    }
}

/// A discriminated event type that pairs a strongly-typed domain payload
/// with its ``EventEnvelope``.
///
/// Use `TypedEvent.from(_:)` to convert a raw ``RealmEvent``, then
/// `switch` exhaustively:
///
/// ```swift
/// for await event in await arca.ws.typedEvents {
///     switch event {
///     case .exchangeUpdated(let state, let envelope):
///         updateUI(state)
///     case .fillPreview(let fill, let envelope):
///         showPreview(fill)
///     case .fillRecorded(let fill, let envelope):
///         confirmFill(fill)
///     case .fundingPayment(let payment, let envelope):
///         logFunding(payment)
///     default:
///         break
///     }
/// }
/// ```
public enum TypedEvent: Sendable {

    // MARK: - Core Domain

    case operationCreated(Operation, envelope: EventEnvelope)
    case operationUpdated(Operation, envelope: EventEnvelope)
    case eventCreated(ArcaEvent, envelope: EventEnvelope)
    case objectCreated(ArcaObject?, envelope: EventEnvelope)
    case objectUpdated(ArcaObject?, envelope: EventEnvelope)
    case objectDeleted(envelope: EventEnvelope)
    case balanceUpdated(envelope: EventEnvelope)

    // MARK: - Exchange / Trading

    case exchangeUpdated(ExchangeState, envelope: EventEnvelope)
    case fillPreview(SimFill, envelope: EventEnvelope)
    case fillRecorded(Fill, envelope: EventEnvelope)
    case fundingPayment(FundingPayment, envelope: EventEnvelope)

    // MARK: - Market Data

    case candleClosed(CandleEvent, envelope: EventEnvelope)
    case candleUpdated(CandleEvent, envelope: EventEnvelope)
    case tradeExecuted(TradeEvent, envelope: EventEnvelope)
    case midsUpdated([String: String], envelope: EventEnvelope)

    // MARK: - Aggregation

    case aggregationUpdated(PathAggregation?, envelope: EventEnvelope)
    case objectValuation(ObjectValuation, path: String, watchId: String, envelope: EventEnvelope)

    // MARK: - Realm

    case realmCreated(Realm, envelope: EventEnvelope)

    // MARK: - Fallback

    /// Received an event whose `type` doesn't match any known case.
    /// The original ``RealmEvent`` is preserved for forward compatibility.
    case unknown(RealmEvent)

    // MARK: - Accessors

    /// The envelope for this event, or `nil` for `.unknown`.
    public var envelope: EventEnvelope? {
        switch self {
        case .operationCreated(_, let e),
             .operationUpdated(_, let e),
             .eventCreated(_, let e),
             .objectCreated(_, let e),
             .objectUpdated(_, let e),
             .objectDeleted(let e),
             .balanceUpdated(let e),
             .exchangeUpdated(_, let e),
             .fillPreview(_, let e),
             .fillRecorded(_, let e),
             .fundingPayment(_, let e),
             .candleClosed(_, let e),
             .candleUpdated(_, let e),
             .tradeExecuted(_, let e),
             .midsUpdated(_, let e),
             .aggregationUpdated(_, let e),
             .objectValuation(_, _, _, let e),
             .realmCreated(_, let e):
            return e
        case .unknown:
            return nil
        }
    }

    // MARK: - Factory

    /// Convert a raw ``RealmEvent`` into a discriminated ``TypedEvent``.
    public static func from(_ event: RealmEvent) -> TypedEvent {
        let envelope = EventEnvelope(from: event)

        switch event.type {
        case EventType.operationCreated.rawValue:
            guard let op = event.operation else { return .unknown(event) }
            return .operationCreated(op, envelope: envelope)

        case EventType.operationUpdated.rawValue:
            guard let op = event.operation else { return .unknown(event) }
            return .operationUpdated(op, envelope: envelope)

        case EventType.eventCreated.rawValue:
            guard let evt = event.event else { return .unknown(event) }
            return .eventCreated(evt, envelope: envelope)

        case EventType.objectCreated.rawValue:
            return .objectCreated(event.object, envelope: envelope)

        case EventType.objectUpdated.rawValue:
            return .objectUpdated(event.object, envelope: envelope)

        case EventType.objectDeleted.rawValue:
            return .objectDeleted(envelope: envelope)

        case EventType.balanceUpdated.rawValue:
            return .balanceUpdated(envelope: envelope)

        case EventType.exchangeUpdated.rawValue:
            guard let state = event.exchangeState else { return .unknown(event) }
            return .exchangeUpdated(state, envelope: envelope)

        case EventType.exchangeFill.rawValue:
            guard let fill = event.fill else { return .unknown(event) }
            return .fillPreview(fill, envelope: envelope)

        case EventType.fillRecorded.rawValue:
            guard let fill = event.recordedFill else { return .unknown(event) }
            return .fillRecorded(fill, envelope: envelope)

        case EventType.exchangeFunding.rawValue:
            guard let funding = event.funding else { return .unknown(event) }
            return .fundingPayment(funding, envelope: envelope)

        case EventType.candleClosed.rawValue:
            guard let coin = event.coin,
                  let ivStr = event.interval,
                  let interval = CandleInterval(rawValue: ivStr),
                  let candle = event.candle else { return .unknown(event) }
            return .candleClosed(CandleEvent(coin: coin, interval: interval, candle: candle), envelope: envelope)

        case EventType.candleUpdated.rawValue:
            guard let coin = event.coin,
                  let ivStr = event.interval,
                  let interval = CandleInterval(rawValue: ivStr),
                  let candle = event.candle else { return .unknown(event) }
            return .candleUpdated(CandleEvent(coin: coin, interval: interval, candle: candle), envelope: envelope)

        case EventType.tradeExecuted.rawValue:
            guard let coin = event.coin,
                  let trade = event.trade else { return .unknown(event) }
            return .tradeExecuted(TradeEvent(coin: coin, trade: trade), envelope: envelope)

        case EventType.midsUpdated.rawValue:
            guard let mids = event.mids else { return .unknown(event) }
            return .midsUpdated(mids, envelope: envelope)

        case EventType.aggregationUpdated.rawValue:
            return .aggregationUpdated(event.aggregation, envelope: envelope)

        case EventType.objectValuation.rawValue:
            guard let val = event.valuation,
                  let path = event.path,
                  let watchId = event.watchId else { return .unknown(event) }
            return .objectValuation(val, path: path, watchId: watchId, envelope: envelope)

        case EventType.realmCreated.rawValue:
            guard let realm = event.realm else { return .unknown(event) }
            return .realmCreated(realm, envelope: envelope)

        default:
            return .unknown(event)
        }
    }
}

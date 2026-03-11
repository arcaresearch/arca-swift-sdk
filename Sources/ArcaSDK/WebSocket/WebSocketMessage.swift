import Foundation

/// Messages sent from client to server over the WebSocket.
enum OutboundMessage: Encodable {
    case auth(token: String, realmId: String)
    case subscribe(channels: [String])
    case unsubscribe(channels: [String])
    case subscribeMids(exchange: String, coins: [String])
    case unsubscribeMids
    case subscribeCandles(coins: [String], intervals: [String])
    case unsubscribeCandles
    case ping

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auth(let token, let realmId):
            try container.encode("auth", forKey: .action)
            try container.encode(token, forKey: .token)
            try container.encode(realmId, forKey: .realmId)
        case .subscribe(let channels):
            try container.encode("subscribe", forKey: .action)
            try container.encode(channels, forKey: .channels)
        case .unsubscribe(let channels):
            try container.encode("unsubscribe", forKey: .action)
            try container.encode(channels, forKey: .channels)
        case .subscribeMids(let exchange, let coins):
            try container.encode("subscribe_mids", forKey: .action)
            try container.encode(exchange, forKey: .exchange)
            try container.encode(coins, forKey: .coins)
        case .unsubscribeMids:
            try container.encode("unsubscribe_mids", forKey: .action)
        case .subscribeCandles(let coins, let intervals):
            try container.encode("subscribe_candles", forKey: .action)
            try container.encode(coins, forKey: .coins)
            try container.encode(intervals, forKey: .intervals)
        case .unsubscribeCandles:
            try container.encode("unsubscribe_candles", forKey: .action)
        case .ping:
            try container.encode("ping", forKey: .action)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case action, token, realmId, channels, exchange, coins, intervals
    }
}

/// Inbound server control message (e.g. `authenticated`, `error`).
struct InboundControlMessage: Decodable {
    let type: String
    let message: String?
}

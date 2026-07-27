import Foundation

/// Timeout bounds applied to Arca's REST and CDN sessions.
///
/// `URLSessionConfiguration.default` leaves `timeoutIntervalForResource` at
/// seven days, so a stalled fetch can hold its connection far longer than any
/// caller is prepared to wait — long enough that a chart or balance load looks
/// permanently hung rather than failed. Bounding both intervals keeps a stall
/// recoverable: the request throws, callers run their error paths, and the
/// connection returns to the pool.
///
/// These apply only to request/response traffic. WebSocket sessions
/// deliberately keep the system defaults, since a long-lived socket must not
/// be torn down by a resource timeout.
public enum ArcaNetworkTimeouts {
    /// Maximum time to wait for further data on an in-flight request.
    public static let request: TimeInterval = 30

    /// Maximum total lifetime of a single resource fetch.
    public static let resource: TimeInterval = 60
}

public extension URLSessionConfiguration {
    /// `URLSessionConfiguration.default` with Arca's timeout bounds applied.
    ///
    /// Pass an explicit configuration to `Arca` or `ArcaClient` to opt out.
    static var arcaDefault: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = ArcaNetworkTimeouts.request
        config.timeoutIntervalForResource = ArcaNetworkTimeouts.resource
        return config
    }
}

public extension URLSession {
    /// Shared session for Arca fetches that aren't issued through `ArcaClient`,
    /// notably candle CDN reads. Prefer this over `URLSession.shared`, which
    /// carries the unbounded system resource timeout.
    static let arcaDefault = URLSession(configuration: .arcaDefault)
}

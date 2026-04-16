import Foundation
import os

// MARK: - Public types

/// Severity levels for ``ArcaLogRecord``.
///
/// Ordering matches Apple's unified logging semantics:
/// `debug < info < notice < warning < error`.
/// Set ``ArcaLogLevel`` on ``Arca`` (via `logLevel:` on ``Arca/init(token:baseURL:realmId:tokenProvider:cache:urlSessionConfiguration:candleCdnBaseUrl:logLevel:logHandler:)``)
/// to control which records are emitted.
public enum ArcaLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    public static func < (lhs: ArcaLogLevel, rhs: ArcaLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A single diagnostic record emitted by the SDK.
///
/// Records are delivered to a host-provided ``ArcaLogHandler`` (if configured) in
/// addition to being written to Apple's unified logging system
/// (subsystem `io.arcaos.sdk`, category from ``ArcaLogRecord/category``).
///
/// `metadata` contains structured context such as `errorId`, `path`, `coin`,
/// `operationId`, `statusCode`, `httpMethod`, or `url`. Fields are always
/// `String` values so they can be forwarded to arbitrary backends without
/// further encoding.
public struct ArcaLogRecord: Sendable {
    public let level: ArcaLogLevel
    public let category: String
    public let message: String
    public let error: Error?
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        level: ArcaLogLevel,
        category: String,
        message: String,
        error: Error? = nil,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.level = level
        self.category = category
        self.message = message
        self.error = error
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

/// A handler that receives diagnostic records from the SDK.
///
/// Implement this to forward records to Datadog, Sentry, Crashlytics, or a
/// custom backend. Handlers are invoked on a serial dispatch queue, so
/// implementations do not need to be internally thread-safe.
///
/// ```swift
/// struct StderrArcaLogger: ArcaLogHandler {
///     func handle(_ record: ArcaLogRecord) {
///         FileHandle.standardError.write(Data("[\(record.category)] \(record.message)\n".utf8))
///     }
/// }
/// ```
public protocol ArcaLogHandler: Sendable {
    func handle(_ record: ArcaLogRecord)
}

// MARK: - Internal logger

/// Internal logger used by every SDK subsystem.
///
/// Writes to `os.Logger` (subsystem `io.arcaos.sdk`, one category per area)
/// and, if configured, forwards a structured ``ArcaLogRecord`` to a
/// host-provided ``ArcaLogHandler``.
///
/// Message strings are captured as `@autoclosure` so formatting work is
/// skipped when the record is below ``ArcaLogger/minLevel``.
public final class ArcaLogger: @unchecked Sendable {
    public static let subsystem = "io.arcaos.sdk"

    private let lock = NSLock()
    private var _minLevel: ArcaLogLevel
    private let handler: ArcaLogHandler?
    private let handlerQueue: DispatchQueue?
    private let loggersLock = NSLock()
    private var loggers: [String: os.Logger] = [:]

    public init(minLevel: ArcaLogLevel = .warning, handler: ArcaLogHandler? = nil) {
        self._minLevel = minLevel
        self.handler = handler
        self.handlerQueue = handler != nil
            ? DispatchQueue(label: "io.arcaos.sdk.logger", qos: .utility)
            : nil
    }

    /// Minimum level at which records are emitted. Records below this level
    /// are dropped without evaluating their message closure.
    public var minLevel: ArcaLogLevel {
        get {
            lock.lock(); defer { lock.unlock() }
            return _minLevel
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _minLevel = newValue
        }
    }

    /// A singleton no-op logger. Used as the default when no SDK instance is
    /// configured (e.g. internal call sites that run before ``Arca`` is
    /// constructed).
    public static let disabled = ArcaLogger(minLevel: .error, handler: nil)

    // MARK: - Emit

    public func log(
        _ level: ArcaLogLevel,
        _ category: String,
        _ message: @autoclosure () -> String,
        error: Error? = nil,
        metadata: [String: String] = [:]
    ) {
        guard level >= minLevel else { return }

        let rendered = message()
        let osLogger = logger(for: category)
        let metaSuffix = Self.renderMetadata(metadata)
        let errSuffix = error.map { " error=\(String(describing: $0))" } ?? ""
        let line = "\(rendered)\(metaSuffix)\(errSuffix)"

        switch level {
        case .debug:   osLogger.debug("\(line, privacy: .public)")
        case .info:    osLogger.info("\(line, privacy: .public)")
        case .notice:  osLogger.notice("\(line, privacy: .public)")
        case .warning: osLogger.warning("\(line, privacy: .public)")
        case .error:   osLogger.error("\(line, privacy: .public)")
        }

        guard let handler = self.handler, let queue = self.handlerQueue else { return }
        let record = ArcaLogRecord(
            level: level,
            category: category,
            message: rendered,
            error: error,
            metadata: metadata
        )
        queue.async { handler.handle(record) }
    }

    // Convenience shortcuts.
    public func debug(_ category: String, _ message: @autoclosure () -> String,
                      error: Error? = nil, metadata: [String: String] = [:]) {
        log(.debug, category, message(), error: error, metadata: metadata)
    }

    public func info(_ category: String, _ message: @autoclosure () -> String,
                     error: Error? = nil, metadata: [String: String] = [:]) {
        log(.info, category, message(), error: error, metadata: metadata)
    }

    public func notice(_ category: String, _ message: @autoclosure () -> String,
                       error: Error? = nil, metadata: [String: String] = [:]) {
        log(.notice, category, message(), error: error, metadata: metadata)
    }

    public func warning(_ category: String, _ message: @autoclosure () -> String,
                        error: Error? = nil, metadata: [String: String] = [:]) {
        log(.warning, category, message(), error: error, metadata: metadata)
    }

    public func error(_ category: String, _ message: @autoclosure () -> String,
                      error: Error? = nil, metadata: [String: String] = [:]) {
        log(.error, category, message(), error: error, metadata: metadata)
    }

    // MARK: - Helpers

    private func logger(for category: String) -> os.Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let existing = loggers[category] { return existing }
        let created = os.Logger(subsystem: Self.subsystem, category: category)
        loggers[category] = created
        return created
    }

    private static func renderMetadata(_ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return "" }
        let parts = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        return " " + parts.joined(separator: " ")
    }
}

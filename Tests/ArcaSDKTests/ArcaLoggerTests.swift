import XCTest
@testable import ArcaSDK

/// Captures records emitted by ``ArcaLogger`` for test assertions.
final class CapturingLogHandler: ArcaLogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [ArcaLogRecord] = []

    var records: [ArcaLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    func handle(_ record: ArcaLogRecord) {
        lock.lock()
        _records.append(record)
        lock.unlock()
    }
}

/// Await the handler queue so records emitted synchronously by ``ArcaLogger``
/// are visible before the test asserts on them.
private func drainLogHandler(_ handler: CapturingLogHandler, expected: Int,
                             timeout: TimeInterval = 1.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while handler.records.count < expected, Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
    }
}

final class ArcaLoggerTests: XCTestCase {

    // MARK: - Level comparison

    func testLevelComparisonOrdering() {
        XCTAssertLessThan(ArcaLogLevel.debug, ArcaLogLevel.info)
        XCTAssertLessThan(ArcaLogLevel.info, ArcaLogLevel.notice)
        XCTAssertLessThan(ArcaLogLevel.notice, ArcaLogLevel.warning)
        XCTAssertLessThan(ArcaLogLevel.warning, ArcaLogLevel.error)
    }

    // MARK: - Level filtering

    func testWarningLevelDropsDebugAndInfo() async {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .warning, handler: handler)

        log.debug("network", "d")
        log.info("network", "i")
        log.notice("network", "n")
        log.warning("network", "w")
        log.error("network", "e")

        await drainLogHandler(handler, expected: 2)
        let levels = handler.records.map(\.level)
        XCTAssertEqual(levels, [.warning, .error])
    }

    func testDebugLevelReceivesAll() async {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .debug, handler: handler)

        log.debug("c", "d")
        log.info("c", "i")
        log.notice("c", "n")
        log.warning("c", "w")
        log.error("c", "e")

        await drainLogHandler(handler, expected: 5)
        XCTAssertEqual(handler.records.map(\.level),
                       [.debug, .info, .notice, .warning, .error])
    }

    // MARK: - @autoclosure skip evaluation

    func testMessageClosureNotEvaluatedWhenBelowLevel() {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .warning, handler: handler)

        let evaluationCount = SendableBox(0)
        for _ in 0..<3 {
            log.debug("c", {
                evaluationCount.update { $0 += 1 }
                return "should not be built"
            }())
        }
        XCTAssertEqual(evaluationCount.value, 0,
                       "Debug-level message closures must not be evaluated when minLevel is .warning")

        log.warning("c", {
            evaluationCount.update { $0 += 1 }
            return "should be built"
        }())
        XCTAssertEqual(evaluationCount.value, 1,
                       "Warning-level message closure must be evaluated when minLevel is .warning")
    }

    // MARK: - Metadata passthrough

    func testMetadataAndErrorPreserved() async {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .debug, handler: handler)
        struct SampleError: Error, Equatable {
            let id: String
        }
        let err = SampleError(id: "sample")

        log.error("network", "request failed",
                  error: err,
                  metadata: ["path": "/objects", "httpMethod": "GET"])

        await drainLogHandler(handler, expected: 1)
        XCTAssertEqual(handler.records.count, 1)
        let record = handler.records[0]
        XCTAssertEqual(record.level, .error)
        XCTAssertEqual(record.category, "network")
        XCTAssertEqual(record.message, "request failed")
        XCTAssertEqual(record.metadata["path"], "/objects")
        XCTAssertEqual(record.metadata["httpMethod"], "GET")
        XCTAssertEqual((record.error as? SampleError), err)
    }

    // MARK: - Concurrent emission

    func testConcurrentEmissionDeliversAllRecords() async {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .debug, handler: handler)

        let emitCount = 200
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<emitCount {
                group.addTask {
                    log.warning("stress", "msg", metadata: ["i": String(i)])
                }
            }
        }

        await drainLogHandler(handler, expected: emitCount)
        XCTAssertEqual(handler.records.count, emitCount,
                       "All concurrent records must be delivered without loss")
        let seen = Set(handler.records.compactMap { $0.metadata["i"] })
        XCTAssertEqual(seen.count, emitCount,
                       "Every concurrent index must appear exactly once")
    }

    // MARK: - Disabled logger

    func testDisabledLoggerDoesNotCrashWithoutHandler() {
        let log = ArcaLogger.disabled
        log.debug("c", "ignored")
        log.warning("c", "still ignored at min=.error")
        log.error("c", "goes to os.Logger but no handler to deliver to")
    }

    // MARK: - minLevel mutation

    func testMinLevelCanBeLowered() async {
        let handler = CapturingLogHandler()
        let log = ArcaLogger(minLevel: .error, handler: handler)

        log.warning("c", "dropped")
        await drainLogHandler(handler, expected: 0, timeout: 0.05)
        XCTAssertEqual(handler.records.count, 0)

        log.minLevel = .debug
        log.warning("c", "kept")
        await drainLogHandler(handler, expected: 1)
        XCTAssertEqual(handler.records.count, 1)
    }
}

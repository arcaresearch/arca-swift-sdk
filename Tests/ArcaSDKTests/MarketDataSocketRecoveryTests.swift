import Network
import XCTest
@testable import ArcaSDK

/// Real URLSession WebSockets and default retry timers against a loopback fixture.
/// The hint is explicitly injected: this is neither an NWPath transition test nor
/// a venue/physical-device latency benchmark. No account or public venue is used.
final class MarketDataSocketRecoveryTests: XCTestCase {
    func testExplicitHintRecoversSameOwnerBeforeOrdinarySocketRetry() async throws {
        let ordinary = try await recover(hint: false)
        let hinted = try await recover(hint: true)
        XCTAssertGreaterThan(ordinary.restoreToAttemptMs, 1_500)
        XCTAssertLessThan(hinted.restoreToAttemptMs, 1_500)
        XCTAssertLessThan(hinted.restoreToAttemptMs + 750, ordinary.restoreToAttemptMs)
    }

    private func recover(hint: Bool) async throws -> RecoveryResult {
        let ready = expectation(description: "loopback listener ready")
        let server = try LoopbackMarketSocket(ready: ready)
        addTeardownBlock { server.stop() }
        server.start()
        await fulfillment(of: [ready], timeout: 3)
        let url = try XCTUnwrap(server.url.value, server.errors.value.joined(separator: "; "))
        let manager = WebSocketManager(baseURL: URL(string: "http://127.0.0.1:1")!, token: "fixture", realmId: "fixture")
        let sources = SendableBox<[HyperliquidMarketSource]>([])
        addTeardownBlock {
            await manager.disconnect()
            for source in sources.value { await source.close() }
        }
        let initial = expectation(description: "initial routed quote")
        let pending = expectation(description: "observed ordinary retry")
        let recovered = expectation(description: "routed quote after reconnect")
        let probe = SocketRecoveryProbe(initial: initial, pending: pending, recovered: recovered)
        await manager.setPublicSourceFactory { _, receive in
            let source = HyperliquidMarketSource(url: url) { epoch, update in
                // Observe after the real manager has routed the frame, so a raw
                // decoded quote cannot masquerade as an accepted interested quote.
                await receive(epoch, update)
                await probe.record(update, diagnostics: await manager.marketDataDiagnostics)
            }
            sources.update { $0.append(source) }
            return source
        }
        let market = try JSONDecoder().decode(Market.self, from: Data(#"{"name":"hl:0:BTC","venueSymbol":"BTC","symbol":"BTC","exchange":"hl","index":0,"szDecimals":5,"maxLeverage":50,"onlyIsolated":false}"#.utf8))
        let configuration = await manager.beginMarketDataConfiguration()
        await manager.configureMarketData(epoch: configuration, preference: .hyperliquid, network: .mainnet, markets: [market])
        let owner = await manager.registerPriceMarkets()
        await manager.updatePriceMarkets(owner, markets: [market.name])
        await fulfillment(of: [initial], timeout: 3)
        let observedInitial = await probe.initialTiming
        let initialTiming = try XCTUnwrap(observedInitial)
        XCTAssertNotNil(initialTiming.firstPriceAtNanos)

        server.interrupt()
        await fulfillment(of: [pending], timeout: 3)
        let observedRetries = await probe.retries
        let firstRetry = try XCTUnwrap(observedRetries.first)
        let scheduled = try XCTUnwrap(firstRetry.lastRetryScheduledAtNanos)
        let delay = try XCTUnwrap(firstRetry.lastRetryDelayMs)
        XCTAssertTrue((2_000...2_499).contains(delay))
        let restored = server.restore()
        XCTAssertGreaterThan(Double(scheduled + UInt64(delay) * 1_000_000) - Double(restored), 1_500_000_000,
                             "The fixture must restore while a meaningful retry wait remains")
        if hint { await manager.notifyMarketDataNetworkAvailable() }
        await fulfillment(of: [recovered], timeout: 6)
        let observedRecovery = await probe.recoveredTiming
        let final = try XCTUnwrap(observedRecovery)
        let attempt = try XCTUnwrap(final.attemptAtNanos)
        let opened = try XCTUnwrap(final.openedAtNanos)
        let quote = try XCTUnwrap(final.firstPriceAtNanos)
        XCTAssertGreaterThan(attempt, restored)
        XCTAssertGreaterThanOrEqual(opened, attempt)
        XCTAssertGreaterThanOrEqual(quote, opened)
        XCTAssertNotEqual(attempt, initialTiming.attemptAtNanos)
        let retries = await probe.retries
        XCTAssertEqual(retries.count, hint ? 2 : 1)
        if hint { XCTAssertTrue((250...499).contains(try XCTUnwrap(retries.last?.lastRetryDelayMs))) }
        // The same owner and source survive the socket replacement; no lifecycle
        // restart, source reconfiguration or second market watch manufactures recovery.
        XCTAssertEqual(sources.value.count, 1)
        let status = await manager.marketDataSourceStatus
        XCTAssertEqual(status.directPriceMarkets, [market.name])
        let diagnostics = await manager.marketDataDiagnostics
        XCTAssertEqual(diagnostics.requestedPriceMarkets, 1)
        XCTAssertEqual(diagnostics.hyperliquidFailures, 1)
        XCTAssertEqual(diagnostics.hyperliquidRecoveries, 1)
        XCTAssertEqual(server.subscriptions.value, 2)
        XCTAssertTrue(server.errors.value.isEmpty, server.errors.value.joined(separator: "; "))
        await manager.releasePriceMarkets(owner)
        let released = await manager.marketDataDiagnostics
        XCTAssertEqual(released.requestedPriceMarkets, 0, "Releasing the original owner must remove the recovered demand")
        for source in sources.value { await source.close() }
        await manager.disconnect()
        server.stop()
        let result = RecoveryResult(restoreToAttemptMs: (Double(attempt) - Double(restored)) / 1_000_000)
        print("SocketRecovery fixture=loopback hint=\(hint) restoreToAttemptMs=\(result.restoreToAttemptMs) attemptToOpenMs=\((Double(opened) - Double(attempt)) / 1_000_000) openToAcceptedQuoteMs=\((Double(quote) - Double(opened)) / 1_000_000)")
        return result
    }
}

private struct RecoveryResult { let restoreToAttemptMs: Double }

private actor SocketRecoveryProbe {
    let initial: XCTestExpectation, pending: XCTestExpectation, recovered: XCTestExpectation
    private(set) var initialTiming: MarketConnectionTiming?
    private(set) var recoveredTiming: MarketConnectionTiming?
    private(set) var retries: [MarketConnectionTiming] = []
    init(initial: XCTestExpectation, pending: XCTestExpectation, recovered: XCTestExpectation) {
        self.initial = initial; self.pending = pending; self.recovered = recovered
    }
    func record(_ update: PublicMarketUpdate, diagnostics: MarketDataDiagnostics) {
        if case let .connection(_, _, at?, delay?) = update {
            var timing = MarketConnectionTiming()
            timing.lastRetryScheduledAtNanos = at; timing.lastRetryDelayMs = delay
            retries.append(timing)
            if retries.count == 1 { pending.fulfill() }
        }
        guard case let .received(.quote(_, _, _), received, _, _) = update,
              diagnostics.requestedPriceMarkets == 1,
              diagnostics.hyperliquidConnection.firstPriceAtNanos == received else { return }
        if initialTiming == nil {
            initialTiming = diagnostics.hyperliquidConnection; initial.fulfill()
        } else if recoveredTiming == nil, diagnostics.hyperliquidConnection.attemptAtNanos != initialTiming?.attemptAtNanos {
            recoveredTiming = diagnostics.hyperliquidConnection; recovered.fulfill()
        }
    }
}

/// Only the test-owned loopback socket is interrupted. All mutable Network state
/// is confined to queue; the bounded observations use the existing SDK test box.
private final class LoopbackMarketSocket: @unchecked Sendable {
    let url = SendableBox<URL?>(nil)
    let errors = SendableBox<[String]>([])
    let subscriptions = SendableBox(0)
    private let queue = DispatchQueue(label: "arca.tests.socket-recovery")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var available = true
    private var reportedReady = false

    init(ready: XCTestExpectation) throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 4_096
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !reportedReady else { return }
            switch state {
            case .ready:
                reportedReady = true
                if let port = listener.port { url.update { $0 = URL(string: "ws://127.0.0.1:\(port.rawValue)") } }
                ready.fulfill()
            case .failed(let error):
                reportedReady = true; errors.update { $0.append("listener: \(error)") }; ready.fulfill()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, available else { connection.cancel(); return }
            connections.append(connection)
            connection.start(queue: queue)
            receiveSubscription(connection)
        }
    }
    func start() { listener.start(queue: queue) }
    func interrupt() { queue.sync { available = false; connections.forEach { $0.cancel() }; connections.removeAll() } }
    func restore() -> UInt64 { queue.sync { available = true; return DispatchTime.now().uptimeNanoseconds } }
    func stop() { queue.sync { available = false; listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }

    private func receiveSubscription(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, available else { return }
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["method"] as? String == "subscribe",
                  let subscription = json["subscription"] as? [String: String],
                  subscription == ["type": "bbo", "coin": "BTC"] else {
                errors.update { $0.append("Unexpected loopback subscription or transport error") }; return
            }
            subscriptions.update { $0 += 1 }
            let time = Int(Date().timeIntervalSince1970 * 1_000)
            let frame = Data("{\"channel\":\"bbo\",\"data\":{\"coin\":\"BTC\",\"time\":\(time),\"bbo\":[{\"px\":\"100\"},{\"px\":\"102\"}]}}".utf8)
            let context = NWConnection.ContentContext(identifier: "quote", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                if let error { self?.errors.update { $0.append("quote send: \(error)") } }
            })
        }
    }
}

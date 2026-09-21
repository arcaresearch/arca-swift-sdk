import XCTest
@testable import ArcaSDK

/// The Wallet Account read model and its stream (wallet-money-movement
/// step 08): every fixture the platform generates from its composition
/// function decodes and round-trips, the enums are byte-for-byte the shipped
/// vocabulary, and the SSE client parses frames, resumes with
/// `Last-Event-ID` on the 1 s → 30 s schedule, refreshes once on 401 and
/// surfaces a refusal as the typed error.
final class WalletAccountTests: XCTestCase {

    // MARK: - Fixtures

    /// backend/libs/arca-go/cashv9/testdata/wallet-account, reached from this
    /// file inside the monorepo; skipped when the SDK is built standalone.
    private static var fixturesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // Tests/ArcaSDKTests/x.swift → sdk/swift → sdk → everything
        return url.appendingPathComponent("backend/libs/arca-go/cashv9/testdata/wallet-account")
    }

    private struct Vocabulary: Decodable {
        let schema: Int
        let walletStates: [String]
        let operationStates: [String]
        let operationKinds: [String]
        let reasons: [String]
        let attention: [String]
        let autoDepositStates: [String]
    }

    /// JSON as a comparable tree with `null`s removed, so Go's `omitempty`
    /// absences and Swift's nil optionals compare equal.
    private func normalized(_ data: Data) throws -> NSObject {
        func strip(_ value: Any) -> Any? {
            switch value {
            case is NSNull: return nil
            case let dict as [String: Any]:
                var out: [String: Any] = [:]
                for (k, v) in dict { if let s = strip(v) { out[k] = s } }
                return out
            case let array as [Any]:
                return array.compactMap(strip)
            default: return value
            }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return (strip(object) ?? [:]) as! NSObject
    }

    func testEveryFixtureDecodesAndRoundTripsAndEnumsMatchTheVocabulary() throws {
        let dir = Self.fixturesDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("fixtures not present at \(dir.path)")
        }
        let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: Data(contentsOf: dir.appendingPathComponent("vocabulary.json")))
        XCTAssertEqual(vocabulary.schema, 1)
        // The enums ARE the vocabulary, in order.
        XCTAssertEqual(WalletState.allCases.map(\.rawValue), vocabulary.walletStates)
        XCTAssertEqual(WalletOperationState.allCases.map(\.rawValue), vocabulary.operationStates)
        XCTAssertEqual(WalletFailureReason.allCases.map(\.rawValue), vocabulary.reasons)
        XCTAssertEqual(AutoDepositState.allCases.map(\.rawValue), vocabulary.autoDepositStates)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") && $0 != "vocabulary.json" }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 19, "fixture set shrank")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var statesSeen: Set<String> = []
        var autoDepositSeen: Set<String> = []
        for file in files {
            let raw = try Data(contentsOf: dir.appendingPathComponent(file))
            let account: WalletAccount
            do {
                account = try decoder.decode(WalletAccount.self, from: raw)
            } catch {
                XCTFail("\(file): \(error)")
                continue
            }
            XCTAssertEqual(account.schema, 1, file)
            XCTAssertNotNil(account.typedWalletState, "\(file): walletState \(account.walletState) unknown to the SDK")
            XCTAssertTrue(vocabulary.walletStates.contains(account.walletState), file)
            statesSeen.insert(account.walletState)
            for reason in account.attention {
                XCTAssertTrue(vocabulary.attention.contains(reason), "\(file): attention \(reason)")
            }
            for op in account.operations {
                XCTAssertNotNil(op.typedState, "\(file): operation state \(op.state)")
                XCTAssertTrue(vocabulary.operationKinds.contains(op.kind), "\(file): kind \(op.kind)")
                if let reason = op.reason {
                    XCTAssertNotNil(WalletFailureReason(rawValue: reason), "\(file): reason \(reason)")
                    XCTAssertEqual(op.state, WalletOperationState.failed.rawValue, "\(file): reason only when failed")
                }
                XCTAssertNotNil(UInt64(op.amountMicro), "\(file): amountMicro \(op.amountMicro) is not an integer string")
            }
            if let auto = account.autoDeposit {
                XCTAssertNotNil(auto.typedState, "\(file): autoDeposit state \(auto.state)")
                autoDepositSeen.insert(auto.state)
                if auto.state == AutoDepositState.off.rawValue { XCTAssertNil(auto.routeId, file) } else { XCTAssertNotNil(auto.routeId, file) }
            }
            for figure in [account.balances.confirmedMicro, account.balances.availableMicro, account.balances.reservedMicro, account.balances.pendingInMicro, account.balances.pendingOutMicro] {
                XCTAssertNotNil(UInt64(figure), "\(file): balance \(figure) is not an integer string")
            }
            // Round trip: nothing lost or renamed.
            let again = try encoder.encode(account)
            XCTAssertEqual(try normalized(again), try normalized(raw), "\(file): SDK type does not round-trip the fixture")
        }
        XCTAssertEqual(statesSeen, Set(vocabulary.walletStates), "fixtures cover every walletState")
        XCTAssertEqual(autoDepositSeen, Set(vocabulary.autoDepositStates), "fixtures cover every autoDeposit state")
    }

    // MARK: - SSE parsing and backoff

    func testSSEParserJoinsDataIgnoresCommentsAndDropsEmptyBlocks() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": connected"))
        XCTAssertNil(parser.consume(line: ""), "a comment-only block is not a frame")
        XCTAssertNil(parser.consume(line: "id: 42"))
        XCTAssertNil(parser.consume(line: "event: snapshot"))
        XCTAssertNil(parser.consume(line: "data: {\"a\":"))
        XCTAssertNil(parser.consume(line: "data:1}"))
        let frame = parser.consume(line: "")
        XCTAssertEqual(frame, SSEFrame(id: "42", event: "snapshot", data: "{\"a\":\n1}"))
        XCTAssertNil(parser.consume(line: "id: 43"))
        XCTAssertNil(parser.consume(line: ""), "id without data is not a frame")
        XCTAssertNil(parser.consume(line: "data: x"))
        XCTAssertEqual(parser.consume(line: ""), SSEFrame(id: nil, event: nil, data: "x"), "state resets between blocks")
    }

    func testSSEParserSplitsBytesOnNewlinesIncludingCRLF() {
        var parser = SSEParser()
        var frames: [SSEFrame] = []
        for byte in Array("id: 1\r\nevent: snapshot\r\ndata: a\r\n\r\n: heartbeat\n\ndata: b\n\n".utf8) {
            if let frame = parser.consume(byte: byte) { frames.append(frame) }
        }
        XCTAssertEqual(frames, [SSEFrame(id: "1", event: "snapshot", data: "a"), SSEFrame(id: nil, event: nil, data: "b")])
    }

    func testBackoffIsOneToThirtySecondsDoubling() {
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 9].map(SSEBackoff.delay(attempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    // MARK: - Stream behaviour

    private static func snapshot(revision: UInt64, state: String) -> String {
        "id: \(revision)\nevent: snapshot\ndata: {\"schema\":1,\"revision\":\(revision),\"realmId\":\"rlm_1\",\"boundaryId\":\"bnd_1\",\"ownerAddress\":\"0x4ae85840bdb73e220d646eb0c564eee18a790197\",\"source\":null,\"walletState\":\"\(state)\",\"attention\":[],\"balances\":{\"confirmedMicro\":\"3600000\",\"availableMicro\":\"3100000\",\"reservedMicro\":\"500000\",\"pendingInMicro\":\"0\",\"pendingOutMicro\":\"500000\",\"asOf\":{\"block\":46252318}},\"autoDeposit\":null,\"operations\":[]}\n\n"
    }

    private func makeClient(onUnauthorized: (@Sendable (AuthRefreshTrigger) async throws -> String)? = nil) -> ArcaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamScriptProtocol.self] + (config.protocolClasses ?? [])
        return ArcaClient(token: "fixture-token", baseURL: URL(string: "http://localhost:19998")!, urlSessionConfiguration: config, onUnauthorized: onUnauthorized)
    }

    func testStreamParsesSnapshotsAndResumesWithLastEventIDAfterBackoff() async throws {
        StreamScriptProtocol.reset()
        StreamScriptProtocol.enqueue([
            .init(status: 200, chunks: [": connected\n\n", Self.snapshot(revision: 41, state: "ready"), ": heartbeat\n\n", "event: control\ndata: {\"ignored\":true}\n\n", Self.snapshot(revision: 42, state: "needs_attention")], finish: true),
            .init(status: 200, chunks: [Self.snapshot(revision: 42, state: "needs_attention")], finish: true),
            .init(status: 200, chunks: [Self.snapshot(revision: 43, state: "ready")], finish: false),
        ])
        let runner = WalletAccountStreamRunner(client: makeClient(), realm: "rlm_1", boundaryId: "bnd_1", log: .disabled)
        let stream = AsyncThrowingStream<WalletAccount, Error> { continuation in
            let task = Task { await runner.run(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        let started = Date()
        var revisions: [UInt64] = []
        for try await wallet in stream {
            XCTAssertEqual(wallet.boundaryId, "bnd_1")
            revisions.append(wallet.revision)
            if revisions.count == 4 { break }
        }
        XCTAssertEqual(revisions, [41, 42, 42, 43], "one snapshot per connect after resume")
        let requests = StreamScriptProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.lastEventID), [nil, "42", "42"], "Last-Event-ID carries the last delivered revision")
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer fixture-token" && $0.accept == "text/event-stream" })
        XCTAssertTrue(requests.allSatisfy { $0.url.contains("realmId=rlm_1") && $0.url.contains("boundaryId=bnd_1") && $0.url.contains("/custody/v9/cash/wallet-account/events") })
        // Two reconnects, each after the 1 s first step (a delivering
        // connection resets the schedule), so at least ~2 s elapsed.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.9)
    }

    func testRefusedConnectionThrowsTheTypedError() async throws {
        StreamScriptProtocol.reset()
        StreamScriptProtocol.enqueue([
            .init(status: 404, chunks: [#"{"success":false,"error":{"code":"NOT_FOUND","message":"V9 cash resource not found"}}"#], finish: true),
        ])
        let runner = WalletAccountStreamRunner(client: makeClient(), realm: "rlm_1", boundaryId: "bnd_missing", log: .disabled)
        let stream = AsyncThrowingStream<WalletAccount, Error> { continuation in
            let task = Task { await runner.run(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        do {
            for try await _ in stream { XCTFail("no snapshot expected") }
            XCTFail("stream ended without throwing")
        } catch let error as ArcaError {
            guard case .notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        XCTAssertEqual(StreamScriptProtocol.requests.count, 1, "a refusal is not retried")
    }

    func testUnauthorizedRefreshesOnceAndReconnects() async throws {
        StreamScriptProtocol.reset()
        StreamScriptProtocol.enqueue([
            .init(status: 401, chunks: [#"{"success":false,"error":{"code":"UNAUTHORIZED","message":"expired"}}"#], finish: true),
            .init(status: 200, chunks: [Self.snapshot(revision: 7, state: "ready")], finish: false),
        ])
        let refreshes = SendableBox(0)
        let client = makeClient(onUnauthorized: { _ in
            refreshes.update { $0 += 1 }
            return "fresh-token"
        })
        let runner = WalletAccountStreamRunner(client: client, realm: "rlm_1", boundaryId: "bnd_1", log: .disabled)
        let stream = AsyncThrowingStream<WalletAccount, Error> { continuation in
            let task = Task { await runner.run(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        for try await wallet in stream {
            XCTAssertEqual(wallet.revision, 7)
            break
        }
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(StreamScriptProtocol.requests.map(\.authorization), ["Bearer fixture-token", "Bearer fresh-token"])
    }
}

/// URLProtocol that serves scripted `text/event-stream` connections in FIFO
/// order, delivering each chunk as a separate load and optionally leaving
/// the connection open, and records every request's resume headers.
private final class StreamScriptProtocol: URLProtocol {
    struct Script {
        let status: Int
        let chunks: [String]
        let finish: Bool
    }
    struct Seen {
        let url: String
        let authorization: String?
        let accept: String?
        let lastEventID: String?
    }

    private static let lock = NSLock()
    private static var queue: [Script] = []
    private static var _requests: [Seen] = []

    static var requests: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func enqueue(_ scripts: [Script]) {
        lock.lock(); queue.append(contentsOf: scripts); lock.unlock()
    }

    static func reset() {
        lock.lock(); queue = []; _requests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "localhost" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(Seen(
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            lastEventID: request.value(forHTTPHeaderField: "Last-Event-ID")
        ))
        let script = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()
        guard let script else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"success":false,"error":{"code":"INTERNAL_ERROR","message":"no scripted connection"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let contentType = script.status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        // Deliver the way a network connection does: headers, then each
        // chunk as its own load a moment later, then (maybe) the end. A
        // synchronous burst inside startLoading is coalesced by the loader
        // and never reaches an open AsyncBytes reader before completion.
        let queue = DispatchQueue(label: "stream-script")
        queue.async { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        for (i, chunk) in script.chunks.enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(20 * (i + 1))) {
                self.client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            }
        }
        if script.finish {
            queue.asyncAfter(deadline: .now() + .milliseconds(20 * (script.chunks.count + 2))) {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

import XCTest
@testable import ArcaSDK

/// Money figures (documents/contracts/sdk-money-figure.md): the schema-2
/// wallet snapshot decodes, every figure is Arca's figure verbatim, legs
/// render on the ends the frame lists, a prediction only adds legs, a venue
/// frame never outranks a booked settlement, and the per-wallet stream
/// resumes with `Last-Event-ID`. The fixture sequence is shared with the
/// Go, Kotlin and TypeScript SDKs.
final class WalletMoneyTests: XCTestCase {

    // MARK: - Fixtures

    /// backend/libs/arca-go/fundingv9/testdata/wallet-money, reached from this
    /// file inside the monorepo; skipped when the SDK is built standalone.
    private static var fixturesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("backend/libs/arca-go/fundingv9/testdata/wallet-money")
    }

    private static func fixture(_ name: String) throws -> WalletSnapshot {
        let url = fixturesDirectory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixtures not present at \(url.path)") }
        return try JSONDecoder().decode(WalletSnapshot.self, from: Data(contentsOf: url))
    }

    private static let hl1 = "obj_hl1"
    private static let hl2 = "obj_hl2"

    // MARK: - Decoding

    func testEveryFrameDecodesAsSchemaTwoWithItsFigures() throws {
        let dir = Self.fixturesDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("fixtures not present at \(dir.path)") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThanOrEqual(files.count, 17, "fixture set shrank")
        for file in files {
            let snapshot = try JSONDecoder().decode(WalletSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
            XCTAssertEqual(snapshot.schema, walletSnapshotSchema, file)
            XCTAssertNotNil(Int64(snapshot.totals.totalMicro), "\(file): totalMicro is an integer string")
            for entry in snapshot.moving {
                XCTAssertNotNil(entry.typedLeg, "\(file): leg \(entry.leg) unknown to the SDK")
                XCTAssertNotNil(Int64(entry.amountMicro), file)
            }
            for account in snapshot.accounts {
                XCTAssertNotNil(account.typedState, "\(file): account state \(account.state)")
                if let balances = account.balances { XCTAssertNotNil(balances.typedSource, "\(file): source \(balances.source)") }
            }
            let money = WalletMoney.compose(snapshot)
            XCTAssertEqual(money.watermark, snapshot.watermark, file)
            XCTAssertEqual(money.accountOrder, snapshot.accounts.map(\.arcaId), "\(file): accounts keep the snapshot's order")
        }
    }

    // MARK: - Figures are Arca's figures

    func testFiguresAreArcasFiguresVerbatim() throws {
        let dir = Self.fixturesDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("fixtures not present") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let snapshot = try JSONDecoder().decode(WalletSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
            let money = WalletMoney.compose(snapshot)
            XCTAssertEqual(money.total.settledMicro, snapshot.totals.totalMicro, "\(file): the total is totals.totalMicro")
            XCTAssertNil(money.total.availableMicro, file)
            XCTAssertEqual(money.cash.settledMicro, snapshot.cash.balances.confirmedMicro, "\(file): Cash is confirmedMicro")
            XCTAssertEqual(money.cash.availableMicro, snapshot.cash.balances.availableMicro, "\(file): Cash available is availableMicro")
            for account in snapshot.accounts {
                let figure = try XCTUnwrap(money.account(account.arcaId), "\(file): \(account.arcaId)")
                XCTAssertEqual(figure.settledMicro, account.balances?.totalMicro, "\(file): \(account.arcaId) is balances.totalMicro")
                XCTAssertEqual(figure.availableMicro, account.balances?.withdrawableMicro, file)
                XCTAssertEqual(figure.current, account.current, file)
                XCTAssertEqual(figure.asOf, account.asOf, file)
            }
            XCTAssertEqual(money.complete, snapshot.totals.complete, file)
            XCTAssertEqual(money.current, snapshot.totals.current, file)
            XCTAssertTrue(money.diagnostics.isEmpty, "\(file): \(money.diagnostics)")
        }
    }

    // MARK: - The move, stage by stage

    func testEveryDollarVisibleOnceAtEveryStage() throws {
        let rest = WalletMoney.compose(try Self.fixture("00-rest"))
        XCTAssertFalse(rest.cash.inMotion)
        XCTAssertFalse(rest.total.inMotion)
        XCTAssertEqual(rest.total.settledMicro, "31010000")

        // Reserved: the leg shows at both ends, the figures are unchanged, the total is unchanged.
        let reserved = WalletMoney.compose(try Self.fixture("01-move-reserved"), previous: rest)
        XCTAssertEqual(reserved.cash.settledMicro, "28510000")
        XCTAssertEqual(reserved.cash.availableMicro, "23500000", "Arca's spendable figure already excludes the reservation")
        XCTAssertEqual(reserved.cash.departing.map { ($0.amountMicro, $0.stage, $0.counterparty) }.count, 1)
        let leaving = try XCTUnwrap(reserved.cash.departing.first)
        XCTAssertEqual(leaving.amountMicro, "5000000")
        XCTAssertEqual(leaving.stage, .reserved)
        XCTAssertEqual(leaving.counterparty, .account(arcaId: Self.hl1, name: "Hyperliquid 1"))
        XCTAssertEqual(leaving.requestId, "req-move1")
        let arriving = try XCTUnwrap(reserved.account(Self.hl1)?.arriving.first)
        XCTAssertEqual(arriving.operationId, leaving.operationId, "one operation shown at both ends")
        XCTAssertEqual(arriving.counterparty, .cash)
        XCTAssertEqual(reserved.account(Self.hl1)?.settledMicro, "1500000")
        XCTAssertTrue(reserved.total.arriving.isEmpty && reserved.total.departing.isEmpty, "an internal move never reaches the total")
        XCTAssertEqual(reserved.total.settledMicro, "31010000")
        XCTAssertTrue(reserved.cash.inMotion && reserved.account(Self.hl1)!.inMotion)
        XCTAssertEqual(reserved.cash.change?.cause, .operation(operationId: "opr_move1", kind: "cash_to_trading"))

        // In transit: the money left Cash (and the fee left the wallet); only the destination keeps its line.
        let inTransit = WalletMoney.compose(try Self.fixture("02-move-in-transit"), previous: reserved)
        XCTAssertEqual(inTransit.cash.settledMicro, "23500000")
        XCTAssertTrue(inTransit.cash.departing.isEmpty, "a leg in transit is no longer the source's")
        XCTAssertEqual(inTransit.account(Self.hl1)?.arriving.first?.stage, .inTransit)
        XCTAssertEqual(inTransit.account(Self.hl1)?.arrivingMicro, "5000000")
        XCTAssertEqual(inTransit.account(Self.hl1)?.settledMicro, "1500000")
        XCTAssertEqual(inTransit.total.settledMicro, "31000000", "the network fee is the only change to the total")
        XCTAssertEqual(inTransit.cash.change?.deltaMicro, "-5010000")
        XCTAssertEqual(inTransit.cash.change?.cause, .operation(operationId: "opr_move1", kind: "cash_to_trading"))

        // Completed: the destination carries it, no legs anywhere.
        let completed = WalletMoney.compose(try Self.fixture("03-move-completed"), previous: inTransit)
        XCTAssertEqual(completed.account(Self.hl1)?.settledMicro, "6500000")
        XCTAssertEqual(completed.account(Self.hl1)?.source, "arca_settlement")
        XCTAssertTrue(completed.account(Self.hl1)!.arriving.isEmpty)
        XCTAssertFalse(completed.cash.inMotion || completed.account(Self.hl1)!.inMotion || completed.total.inMotion)
        XCTAssertEqual(completed.account(Self.hl1)?.change?.cause, .operation(operationId: "opr_move1", kind: "cash_to_trading"))
        XCTAssertEqual(completed.account(Self.hl1)?.change?.deltaMicro, "5000000")
        XCTAssertEqual(completed.total.settledMicro, "31000000")

        // A venue result: no operation touched the account; the change is the venue's.
        let fill = WalletMoney.compose(try Self.fixture("04-venue-fill"), previous: completed)
        XCTAssertEqual(fill.account(Self.hl1)?.settledMicro, "6420000")
        XCTAssertEqual(fill.account(Self.hl1)?.change?.cause, .venue)
        XCTAssertEqual(fill.account(Self.hl1)?.change?.deltaMicro, "-80000")
        XCTAssertNil(fill.cash.change, "Cash did not move")
        XCTAssertEqual(fill.total.settledMicro, "30920000")

        // Failure before the point of no return: the reservation returns, nothing else changed.
        let failed = WalletMoney.compose(try Self.fixture("05-move-failed-before-pnr"), previous: reserved)
        XCTAssertEqual(failed.cash.availableMicro, "28510000")
        XCTAssertTrue(failed.cash.departing.isEmpty && failed.account(Self.hl1)!.arriving.isEmpty)
        XCTAssertEqual(failed.cash.change?.cause, .operation(operationId: "opr_move1", kind: "cash_to_trading"))
        XCTAssertEqual(failed.cash.change?.operationStatus, "failed", "a released reservation is not money sent")
        XCTAssertEqual(failed.cash.change?.retired?.direction, .outgoing)

        // Compensation after it: Cash is credited back in the same frame the leg disappears.
        let compensated = WalletMoney.compose(try Self.fixture("06-move-compensated"), previous: inTransit)
        XCTAssertEqual(compensated.cash.settledMicro, "28500000")
        XCTAssertTrue(compensated.account(Self.hl1)!.arriving.isEmpty)
        XCTAssertEqual(compensated.cash.change?.deltaMicro, "5000000")
    }

    func testOnlyBoundaryCrossingLegsReachTheTotal() throws {
        let deposit = WalletMoney.compose(try Self.fixture("08-deposit-in-transit"))
        XCTAssertEqual(deposit.total.arriving.map(\.amountMicro), ["2000000"])
        XCTAssertEqual(deposit.total.arriving.first?.counterparty, .external(address: "0x3333333333333333333333333333333333333333"))
        XCTAssertEqual(deposit.account(Self.hl2)?.arriving.first?.stage, .inTransit)
        let send = WalletMoney.compose(try Self.fixture("11-send-in-transit"))
        XCTAssertEqual(send.total.departing.map(\.amountMicro), ["1000000"])
        XCTAssertEqual(send.account(Self.hl1)?.departing.first?.counterparty, .external(address: "0xabcabcabcabcabcabcabcabcabcabcabcabcabca"))
        let cash = WalletMoney.compose(try Self.fixture("14-cash-send-and-pending-in"))
        XCTAssertEqual(cash.cash.departing.map { ($0.amountMicro, $0.stage) }.map { "\($0.0):\($0.1.rawValue)" }, ["2000000:reserved"])
        XCTAssertEqual(cash.cash.arriving.map(\.amountMicro), ["750000"])
        XCTAssertEqual(cash.total.departing.map(\.amountMicro), ["2000000"])
        XCTAssertEqual(cash.total.arriving.map(\.amountMicro), ["750000"])
    }

    func testExpectedIsListedNotSummed() throws {
        let money = WalletMoney.compose(try Self.fixture("07-deposit-expected"))
        let figure = try XCTUnwrap(money.account(Self.hl2))
        XCTAssertEqual(figure.arriving.first?.stage, .expected)
        XCTAssertEqual(figure.expectedMicro, "2000000")
        XCTAssertEqual(figure.arrivingMicro, "0", "expected money is listed, never counted")
        XCTAssertFalse(figure.inMotion)
        XCTAssertEqual(money.total.expectedMicro, "2000000")
        XCTAssertEqual(money.total.settledMicro, "30920000")
    }

    func testExternalDepositJoinsTheTotalWhenObservedAndLandsOnce() throws {
        let expected = WalletMoney.compose(try Self.fixture("07-deposit-expected"))
        let observed = WalletMoney.compose(try Self.fixture("08-deposit-in-transit"), previous: expected)
        let landed = WalletMoney.compose(try Self.fixture("09-deposit-landed"), previous: observed)
        XCTAssertEqual(expected.total.settledMicro, "30920000")
        XCTAssertEqual(observed.total.settledMicro, "32920000", "observed on chain: it joins the total as moving")
        XCTAssertEqual(observed.account(Self.hl2)?.settledMicro, "1000000", "not yet in the account")
        XCTAssertEqual(landed.total.settledMicro, "32920000", "landing moves it from moving to the account, the total is unchanged")
        XCTAssertEqual(landed.account(Self.hl2)?.settledMicro, "3000000")
        XCTAssertTrue(landed.account(Self.hl2)!.arriving.isEmpty)
        XCTAssertEqual(landed.account(Self.hl2)?.change?.cause, .operation(operationId: "opr_dep1", kind: "deposit"))
        XCTAssertEqual(landed.total.change?.cause, .operation(operationId: "opr_dep1", kind: "deposit"))
        // The total did not move when the money landed (it was counted as moving already); the retired leg names the amount.
        XCTAssertEqual(landed.total.change?.deltaMicro, "0")
        XCTAssertEqual(landed.total.change?.retired?.amountMicro, "2000000")
        XCTAssertEqual(landed.total.change?.retired?.direction, .incoming)
        XCTAssertEqual(landed.total.change?.operationStatus, "succeeded")
        XCTAssertEqual(landed.account(Self.hl2)?.change?.operationStatus, "succeeded")
    }

    func testSendLeavesTheTotalOnlyWhenPaid() throws {
        let reserved = WalletMoney.compose(try Self.fixture("10-send-reserved"))
        let inTransit = WalletMoney.compose(try Self.fixture("11-send-in-transit"), previous: reserved)
        let paid = WalletMoney.compose(try Self.fixture("12-send-paid"), previous: inTransit)
        XCTAssertEqual(reserved.total.settledMicro, "32920000")
        XCTAssertEqual(reserved.account(Self.hl1)?.departing.first?.stage, .reserved)
        XCTAssertEqual(reserved.account(Self.hl1)?.availableMicro, "5420000", "withdrawable already excludes the send")
        XCTAssertEqual(inTransit.total.settledMicro, "32920000", "in transit, the money still belongs to the wallet")
        XCTAssertEqual(inTransit.account(Self.hl1)?.departing.first?.stage, .inTransit, "a send keeps its source line until paid")
        XCTAssertEqual(paid.total.settledMicro, "31920000")
        XCTAssertTrue(paid.account(Self.hl1)!.departing.isEmpty && paid.total.departing.isEmpty)
        XCTAssertEqual(paid.total.change?.cause, .operation(operationId: "opr_send1", kind: "trading_to_external"))
    }

    // MARK: - Counterparties the frame does not list

    func testLegRendersOnTheVisibleEndAlone() throws {
        let money = WalletMoney.compose(try Self.fixture("13-off-page-counterparty"))
        let figure = try XCTUnwrap(money.account(Self.hl1))
        XCTAssertEqual(figure.departing.count, 1)
        XCTAssertEqual(figure.departing.first?.counterparty, .unknown(arcaId: "obj_hl9"))
        XCTAssertNil(money.account("obj_hl9"), "the other end is not in this frame")
        XCTAssertTrue(money.total.arriving.isEmpty && money.total.departing.isEmpty, "a move inside the wallet never reaches the total")
        XCTAssertTrue(money.diagnostics.isEmpty)
    }

    func testPartialCatalogNeverChangesTheTotal() throws {
        let snapshot = try Self.fixture("13-off-page-counterparty")
        XCTAssertEqual(WalletMoney.compose(snapshot).total.settledMicro, snapshot.totals.totalMicro)
        let unobserved = try Self.fixture("16-account-unobserved")
        let money = WalletMoney.compose(unobserved)
        XCTAssertNil(money.account(Self.hl2)?.settledMicro, "an account never observed has no figure, not zero")
        XCTAssertFalse(money.complete)
        XCTAssertEqual(money.total.settledMicro, unobserved.totals.totalMicro)
    }

    func testPreCashWalletIsZeroCashAndNothingElse() throws {
        let money = WalletMoney.compose(try Self.fixture("15-pre-cash-wallet"))
        XCTAssertEqual(money.cash.settledMicro, "0")
        XCTAssertEqual(money.snapshot.cash.typedWalletState, .setupRequired)
        XCTAssertTrue(money.accounts.isEmpty)
        XCTAssertEqual(money.total.settledMicro, "0")
    }

    // MARK: - Prediction

    func testPredictionAddsLegsOnlyAndNeverTouchesSettled() throws {
        let rest = try Self.fixture("00-rest")
        let prediction = MoneyPrediction(requestId: "req-move1", kind: "cash_to_trading", amountMicro: "5000000",
                                         from: WalletEndpoint(kind: "cash", boundaryId: rest.boundaryId),
                                         to: WalletEndpoint(kind: "hyperliquid", arcaId: Self.hl1))
        let money = WalletMoney.compose(rest, predictions: [prediction])
        XCTAssertEqual(money.cash.settledMicro, "28510000")
        XCTAssertEqual(money.cash.availableMicro, "28510000", "a prediction never changes a figure")
        XCTAssertEqual(money.total.settledMicro, "31010000")
        XCTAssertEqual(money.cash.departing.map(\.predicted), [true])
        XCTAssertEqual(money.cash.departing.first?.counterparty, .account(arcaId: Self.hl1, name: "Hyperliquid 1"))
        XCTAssertEqual(money.account(Self.hl1)?.arriving.map(\.predicted), [true])
        XCTAssertTrue(money.total.departing.isEmpty)
    }

    func testPredictionRetiresWhenTheStreamCarriesTheOperation() throws {
        let prediction = MoneyPrediction(requestId: "req-move1", kind: "cash_to_trading", amountMicro: "5000000",
                                         from: WalletEndpoint(kind: "cash"), to: WalletEndpoint(kind: "hyperliquid", arcaId: Self.hl1))
        let framed = WalletMoney.compose(try Self.fixture("01-move-reserved"), predictions: [prediction])
        XCTAssertEqual(framed.cash.departing.count, 1, "the framed leg replaces the predicted one")
        XCTAssertEqual(framed.cash.departing.first?.predicted, false)
        XCTAssertEqual(framed.account(Self.hl1)?.arriving.count, 1)
    }

    // MARK: - Revaluation

    func testBookedSettlementOutranksStaleVenueFrame() throws {
        let booked = try Self.fixture("03-move-completed") // Hyperliquid 1 is 6.50 as of 18:00:09
        let stale = MoneyRevaluation(arcaId: Self.hl1, equityMicro: "1500000", observedAt: RFC3339.parse("2026-10-17T18:00:05Z")!)
        let money = WalletMoney.compose(booked, revaluations: [Self.hl1: stale])
        XCTAssertEqual(money.account(Self.hl1)?.settledMicro, "6500000")
        XCTAssertNil(money.account(Self.hl1)?.revaluedMicro, "a venue frame older than the booked figure is not used")
        XCTAssertEqual(money.diagnostics, [.venueFrameIgnored(arcaId: Self.hl1, reason: "venue frame older than the figure")])
        let fresh = MoneyRevaluation(arcaId: Self.hl1, equityMicro: "6490000", observedAt: RFC3339.parse("2026-10-17T18:00:11Z")!)
        let revalued = WalletMoney.compose(booked, revaluations: [Self.hl1: fresh])
        XCTAssertEqual(revalued.account(Self.hl1)?.revaluedMicro, "6490000")
        XCTAssertEqual(revalued.account(Self.hl1)?.settledMicro, "6500000", "the figure itself never moves with a venue frame")
    }

    func testRevaluationWaitsForAPendingSettlement() throws {
        let held = try Self.fixture("02-move-in-transit")
        let fresh = MoneyRevaluation(arcaId: Self.hl1, equityMicro: "6500000", observedAt: RFC3339.parse("2026-10-17T18:00:30Z")!)
        let money = WalletMoney.compose(held, revaluations: [Self.hl1: fresh])
        XCTAssertNil(money.account(Self.hl1)?.revaluedMicro, "the venue may show the money before Arca books it; the leg still lists it")
        XCTAssertEqual(money.diagnostics.count, 1)
    }

    func testFillIsCountedOnceAcrossSnapshotAndVenueFrames() throws {
        let completed = WalletMoney.compose(try Self.fixture("03-move-completed"))
        let venue = MoneyRevaluation(arcaId: Self.hl1, equityMicro: "6420000", observedAt: RFC3339.parse("2026-10-17T18:00:11Z")!)
        let ticking = WalletMoney.compose(completed.snapshot, previous: completed, revaluations: [Self.hl1: venue])
        XCTAssertEqual(ticking.account(Self.hl1)?.revaluedMicro, "6420000")
        XCTAssertEqual(ticking.account(Self.hl1)?.settledMicro, "6500000")
        // The next snapshot folds the same fill; the older venue frame is no longer used.
        let folded = WalletMoney.compose(try Self.fixture("04-venue-fill"), previous: ticking, revaluations: [Self.hl1: venue])
        XCTAssertEqual(folded.account(Self.hl1)?.settledMicro, "6420000")
        XCTAssertNil(folded.account(Self.hl1)?.revaluedMicro)
        XCTAssertEqual(folded.account(Self.hl1)?.change?.cause, .venue)
        XCTAssertEqual(folded.account(Self.hl1)?.change?.deltaMicro, "-80000", "one fill, one change")
    }

    func testAmbiguousCauseRollsDigitsWithoutACaption() throws {
        let landed = WalletMoney.compose(try Self.fixture("09-deposit-landed"))
        // The same frame again with the account moved by an unnamed cause and a non-venue source: no caption.
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(landed.snapshot)) as! [String: Any]
        var accounts = raw["accounts"] as! [[String: Any]]
        var balances = accounts[1]["balances"] as! [String: Any]
        balances["totalMicro"] = "2900000"
        balances["source"] = "arca_settlement"
        accounts[1]["balances"] = balances
        raw["accounts"] = accounts
        var totals = raw["totals"] as! [String: Any]
        totals["tradingMicro"] = "9320000"
        totals["totalMicro"] = "32820000"
        raw["totals"] = totals
        var watermark = raw["watermark"] as! [String: Any]
        watermark["sequence"] = 110
        raw["watermark"] = watermark
        let next = try JSONDecoder().decode(WalletSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        let money = WalletMoney.compose(next, previous: landed)
        XCTAssertEqual(money.account(Self.hl2)?.settledMicro, "2900000")
        XCTAssertNil(money.account(Self.hl2)?.change, "no operation and not a venue push: nothing is claimed")
    }

    // MARK: - Diagnostics

    func testMismatchIsDiagnosedNeverGated() throws {
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("00-rest.json"))) as! [String: Any]
        var totals = raw["totals"] as! [String: Any]
        totals["totalMicro"] = "99000000"
        raw["totals"] = totals
        let snapshot = try JSONDecoder().decode(WalletSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        let money = WalletMoney.compose(snapshot)
        XCTAssertEqual(money.total.settledMicro, "99000000", "the frame is published as Arca composed it")
        XCTAssertEqual(money.diagnostics, [.totalsMismatch(expectedMicro: "99000000", composedMicro: "31010000")])
    }

    // MARK: - The watch

    private func makeWatch(_ frames: [WalletSnapshot]) -> (WalletMoneyWatchStream, AsyncThrowingStream<WalletSnapshot, Error>.Continuation) {
        let (events, continuation) = AsyncThrowingStream<WalletSnapshot, Error>.makeStream()
        let watch = WalletMoneyWatchStream(log: .disabled)
        watch.start(events: events)
        for frame in frames { continuation.yield(frame) }
        return (watch, continuation)
    }

    func testOneFrameOneValue() async throws {
        let (watch, continuation) = makeWatch([try Self.fixture("00-rest"), try Self.fixture("01-move-reserved")])
        var seen: [UInt64] = []
        for await money in watch.updates {
            seen.append(money.watermark.sequence)
            XCTAssertEqual(money.cash.departing.isEmpty, money.account(Self.hl1)!.arriving.isEmpty, "both ends of a leg change in the same frame")
            XCTAssertEqual(money.snapshot.watermark.sequence, money.watermark.sequence)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [100, 101])
        XCTAssertEqual(watch.state.value, .connected)
        continuation.finish()
        await watch.stop()
    }

    func testOlderWatermarkIsIgnored() async throws {
        let rest = try Self.fixture("00-rest")
        let (watch, continuation) = makeWatch([rest, try Self.fixture("01-move-reserved")])
        for await money in watch.updates where money.watermark.sequence == 101 { break }
        continuation.yield(rest) // sequence 100 again: older than what is shown
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(watch.money.value?.watermark.sequence, 101)
        XCTAssertEqual(watch.money.value?.cash.departing.count, 1)
        continuation.finish()
        await watch.stop()
    }

    func testWatchPredictionIsRetiredByTheFrameThatCarriesIt() async throws {
        let (watch, continuation) = makeWatch([try Self.fixture("00-rest")])
        for await _ in watch.updates { break }
        watch.predict(MoneyPrediction(requestId: "req-move1", kind: "cash_to_trading", amountMicro: "5000000",
                                      from: WalletEndpoint(kind: "cash"), to: WalletEndpoint(kind: "hyperliquid", arcaId: Self.hl1)))
        await watch.money.wait(until: { $0?.cash.departing.first?.predicted == true })
        XCTAssertEqual(watch.money.value?.cash.availableMicro, "28510000", "no figure moved")
        continuation.yield(try Self.fixture("01-move-reserved"))
        await watch.money.wait(until: { $0?.watermark.sequence == 101 })
        XCTAssertEqual(watch.money.value?.cash.departing.map(\.predicted), [false], "the framed leg replaced the prediction in the same step")
        continuation.finish()
        await watch.stop()
    }

    func testWatchRevaluationFollowsTheRule() async throws {
        let (watch, continuation) = makeWatch([try Self.fixture("03-move-completed")])
        for await _ in watch.updates { break }
        watch.revalue(MoneyRevaluation(arcaId: Self.hl1, equityMicro: "6490000", observedAt: RFC3339.parse("2026-10-17T18:00:11Z")!))
        await watch.money.wait(until: { $0?.account(Self.hl1)?.revaluedMicro == "6490000" })
        watch.clearRevaluation(arcaId: Self.hl1)
        await watch.money.wait(until: { $0?.account(Self.hl1)?.revaluedMicro == nil })
        continuation.finish()
        await watch.stop()
    }

    // MARK: - The stream

    private func makeClient() -> ArcaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MoneyStreamScriptProtocol.self] + (config.protocolClasses ?? [])
        return ArcaClient(token: "fixture-token", baseURL: URL(string: "http://localhost:19997")!, urlSessionConfiguration: config, onUnauthorized: nil)
    }

    private static func frame(_ name: String) throws -> String {
        let url = fixturesDirectory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixtures not present") }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(WalletSnapshot.self, from: data)
        let oneLine = String(decoding: try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data)), as: UTF8.self)
        return "id: \(snapshot.watermark.sequence)\nevent: snapshot\ndata: \(oneLine)\n\n"
    }

    func testStreamParsesSnapshotsAndResumesWithLastEventID() async throws {
        MoneyStreamScriptProtocol.reset()
        MoneyStreamScriptProtocol.enqueue([
            .init(status: 200, chunks: [": connected\n\n", try Self.frame("00-rest"), "event: position\ndata: {\"sequence\":100}\n\n", try Self.frame("01-move-reserved")], finish: true),
            .init(status: 200, chunks: [try Self.frame("02-move-in-transit")], finish: false),
        ])
        let runner = WalletSnapshotStreamRunner(client: makeClient(), realm: "rlm_1", ownerAddress: "0x4ae85840bdb73e220d646eb0c564eee18a790197",
                                                arcaPath: "/users/alice", boundaryId: "", log: .disabled)
        let stream = AsyncThrowingStream<WalletSnapshot, Error> { continuation in
            let task = Task { await runner.run(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        var sequences: [UInt64] = []
        for try await snapshot in stream {
            sequences.append(snapshot.watermark.sequence)
            if sequences.count == 3 { break }
        }
        XCTAssertEqual(sequences, [100, 101, 102])
        let requests = MoneyStreamScriptProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.lastEventID), [nil, "101"], "Last-Event-ID carries the last delivered journal position")
        XCTAssertTrue(requests.allSatisfy { $0.url.contains("/custody/v9/funding/wallet-stream") && $0.url.contains("ownerAddress=") && $0.url.contains("arcaPath=") && !$0.url.contains("boundaryId=") })
    }

    func testRefusedStreamSurfacesTheTypedError() async throws {
        MoneyStreamScriptProtocol.reset()
        MoneyStreamScriptProtocol.enqueue([
            .init(status: 404, chunks: [#"{"success":false,"error":{"code":"NOT_FOUND","message":"wallet not found"}}"#], finish: true),
        ])
        let runner = WalletSnapshotStreamRunner(client: makeClient(), realm: "rlm_1", ownerAddress: "0xnobody", arcaPath: "/users/nobody", boundaryId: "bnd", log: .disabled)
        let stream = AsyncThrowingStream<WalletSnapshot, Error> { continuation in
            let task = Task { await runner.run(continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
        do {
            for try await _ in stream { XCTFail("no snapshot expected") }
            XCTFail("stream ended without throwing")
        } catch let error as ArcaError {
            guard case .notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        let watch = WalletMoneyWatchStream(log: .disabled)
        let (events, continuation) = AsyncThrowingStream<WalletSnapshot, Error>.makeStream()
        watch.start(events: events)
        continuation.finish(throwing: ArcaError.forbidden(message: "cap", errorId: nil))
        await watch.failure.wait(until: { $0 != nil })
        XCTAssertEqual(watch.state.value, .loading)
    }

    // MARK: - Micro

    func testMicroHelpersAreExactIntegerArithmetic() {
        XCTAssertEqual(Micro.sum(["1", "2", "3"]), "6")
        XCTAssertEqual(Micro.difference("5000000", "5010000"), "-10000")
        XCTAssertNil(Micro.difference("x", "1"))
        XCTAssertEqual(Micro.fromDecimal("6.49"), "6490000")
        XCTAssertEqual(Micro.fromDecimal("-0.5"), "-500000")
        XCTAssertEqual(Micro.fromDecimal("1500"), "1500000000")
        XCTAssertEqual(Micro.fromDecimal("0.1234567"), "123456", "truncated toward zero past six decimals")
        XCTAssertNil(Micro.fromDecimal("abc"))
    }
}

/// Scripted `text/event-stream` connections in FIFO order, recording each
/// request's resume headers (the wallet-account tests keep their own copy).
private final class MoneyStreamScriptProtocol: URLProtocol {
    struct Script {
        let status: Int
        let chunks: [String]
        let finish: Bool
    }
    struct Seen {
        let url: String
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

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 19997 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requests.append(Seen(url: request.url?.absoluteString ?? "", lastEventID: request.value(forHTTPHeaderField: "Last-Event-ID")))
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
        let queue = DispatchQueue(label: "money-stream-script")
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

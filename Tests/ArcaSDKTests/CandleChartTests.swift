import XCTest
@testable import ArcaSDK

final class CandleChartTests: XCTestCase {

    // MARK: - CandleInterval.milliseconds

    func testIntervalMilliseconds() {
        XCTAssertEqual(CandleInterval.fifteenSeconds.milliseconds, 15_000)
        XCTAssertEqual(CandleInterval.oneMinute.milliseconds, 60_000)
        XCTAssertEqual(CandleInterval.fiveMinutes.milliseconds, 300_000)
        XCTAssertEqual(CandleInterval.fifteenMinutes.milliseconds, 900_000)
        XCTAssertEqual(CandleInterval.oneHour.milliseconds, 3_600_000)
        XCTAssertEqual(CandleInterval.fourHours.milliseconds, 14_400_000)
        XCTAssertEqual(CandleInterval.oneDay.milliseconds, 86_400_000)
    }

    func testAllIntervalsHavePositiveMilliseconds() {
        for interval in CandleInterval.allCases {
            XCTAssertGreaterThan(interval.milliseconds, 0, "\(interval) should have positive milliseconds")
        }
    }

    // MARK: - dedupCandles

    func testDedupPreservesOrderedUnique() {
        let candles = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        let result = dedupCandles(candles)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].t, 1000)
        XCTAssertEqual(result[1].t, 2000)
        XCTAssertEqual(result[2].t, 3000)
    }

    func testDedupKeepsLastForDuplicateTimestamp() {
        let candles = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 1000, c: "150"),
        ]
        let result = dedupCandles(candles)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].c, "150")
    }

    func testDedupSortsUnsortedInput() {
        let candles = [
            makeCandle(t: 3000, c: "300"),
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
        ]
        let result = dedupCandles(candles)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].t, 1000)
        XCTAssertEqual(result[1].t, 2000)
        XCTAssertEqual(result[2].t, 3000)
    }

    func testDedupHandlesEmpty() {
        XCTAssertEqual(dedupCandles([]).count, 0)
    }

    func testDedupHandlesSingleElement() {
        let result = dedupCandles([makeCandle(t: 5000, c: "500")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].t, 5000)
    }

    func testDedupMergesHistoryAndLive() {
        let history = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        let live = [
            makeCandle(t: 3000, c: "350"),
            makeCandle(t: 4000, c: "400"),
        ]
        let result = dedupCandles(history + live)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[2].c, "350") // live wins
        XCTAssertEqual(result[3].t, 4000)
    }

    // MARK: - applyCandle

    func testApplyUpdateInPlace() {
        var arr = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
        ]
        let update = makeCandle(t: 2000, c: "250")
        applyCandle(update, to: &arr)
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[1].c, "250")
    }

    func testApplyAppendNewCandle() {
        var arr = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
        ]
        let newCandle = makeCandle(t: 3000, c: "300")
        applyCandle(newCandle, to: &arr)
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[2].t, 3000)
        XCTAssertEqual(arr[2].c, "300")
    }

    func testApplyToEmpty() {
        var arr: [Candle] = []
        applyCandle(makeCandle(t: 1000, c: "100"), to: &arr)
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0].t, 1000)
    }

    func testApplySequentialUpdatesAndCloses() {
        var arr = [makeCandle(t: 1000, c: "100")]

        // In-progress update to current candle
        applyCandle(makeCandle(t: 1000, c: "110"), to: &arr)
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0].c, "110")

        // Another in-progress update
        applyCandle(makeCandle(t: 1000, c: "120"), to: &arr)
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0].c, "120")

        // New candle (previous one closed)
        applyCandle(makeCandle(t: 2000, c: "200"), to: &arr)
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[1].c, "200")

        // Update new candle in progress
        applyCandle(makeCandle(t: 2000, c: "210"), to: &arr)
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[1].c, "210")
    }

    // MARK: - loadMore merge pattern

    func testPrependOlderCandlesAndDedup() {
        var existing = [
            makeCandle(t: 4000, c: "400"),
            makeCandle(t: 5000, c: "500"),
            makeCandle(t: 6000, c: "600"),
        ]
        let older = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        existing.insert(contentsOf: older, at: 0)
        existing = dedupCandles(existing)

        XCTAssertEqual(existing.count, 6)
        XCTAssertEqual(existing[0].t, 1000)
        XCTAssertEqual(existing[5].t, 6000)
    }

    func testPrependOlderCandlesWithOverlap() {
        var existing = [
            makeCandle(t: 3000, c: "300"),
            makeCandle(t: 4000, c: "400"),
        ]
        let older = [
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "OLD_300"),
        ]
        existing.insert(contentsOf: older, at: 0)
        existing = dedupCandles(existing)

        XCTAssertEqual(existing.count, 3)
        XCTAssertEqual(existing[0].t, 2000)
        // dedupCandles keeps the last occurrence — existing data wins
        // because it comes after the prepended older data in the array
        XCTAssertEqual(existing[1].c, "300")
    }

    func testPrependEmptyOlderCandles() {
        var existing = [
            makeCandle(t: 3000, c: "300"),
            makeCandle(t: 4000, c: "400"),
        ]
        let older: [Candle] = []
        existing.insert(contentsOf: older, at: 0)
        existing = dedupCandles(existing)

        XCTAssertEqual(existing.count, 2)
        XCTAssertEqual(existing[0].t, 3000)
    }

    // MARK: - Helpers

    private func makeCandle(t: Int, c: String) -> Candle {
        Candle(t: t, o: "100", h: "200", l: "50", c: c, v: "1000", n: 10)
    }
}

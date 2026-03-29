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

    func testApplyOutOfOrderUpdateExisting() {
        var arr = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        // candle.closed for t=2000 arrives after t=3000 is already the tail
        applyCandle(makeCandle(t: 2000, c: "250"), to: &arr)
        XCTAssertEqual(arr.count, 3, "Out-of-order update must not create a duplicate")
        XCTAssertEqual(arr[1].c, "250")
        // Array order preserved
        XCTAssertEqual(arr[0].t, 1000)
        XCTAssertEqual(arr[2].t, 3000)
    }

    func testApplyOutOfOrderInsertNewTimestamp() {
        var arr = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 3000, c: "300"),
        ]
        // A candle at t=2000 that we missed (gap) arrives out of order
        applyCandle(makeCandle(t: 2000, c: "200"), to: &arr)
        XCTAssertEqual(arr.count, 3, "Missing timestamp should be inserted, not duplicated")
        XCTAssertEqual(arr[0].t, 1000)
        XCTAssertEqual(arr[1].t, 2000)
        XCTAssertEqual(arr[2].t, 3000)
    }

    func testApplyOutOfOrderInsertBeforeAll() {
        var arr = [
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        applyCandle(makeCandle(t: 1000, c: "100"), to: &arr)
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[0].t, 1000)
    }

    func testApplyReconnectScenarioNoDuplicates() {
        // Simulate: REST returns [t1..t3], then buffered WS events arrive
        // out of order: candle.closed for t2, candle.updated for t3
        var arr = [
            makeCandle(t: 1000, c: "100"),
            makeCandle(t: 2000, c: "200"),
            makeCandle(t: 3000, c: "300"),
        ]
        // Buffered candle.closed for t=2000 (already in array, not at tail)
        applyCandle(makeCandle(t: 2000, c: "200_closed"), to: &arr)
        XCTAssertEqual(arr.count, 3, "Must update in place, not append")
        XCTAssertEqual(arr[1].c, "200_closed")

        // Buffered candle.updated for t=3000 (already at tail)
        applyCandle(makeCandle(t: 3000, c: "300_live"), to: &arr)
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[2].c, "300_live")

        // Verify no duplicates survive a dedup pass
        let deduped = dedupCandles(arr)
        XCTAssertEqual(deduped.count, arr.count,
            "Array should already be free of duplicates")
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

    // MARK: - SendableBox.updateAndGet

    func testUpdateAndGetReturnsPostMutationSnapshot() {
        let box = SendableBox<[Int]>([1, 2, 3])
        let snapshot = box.updateAndGet { $0.append(4) }
        XCTAssertEqual(snapshot, [1, 2, 3, 4])
        XCTAssertEqual(box.value, [1, 2, 3, 4])
    }

    func testUpdateAndGetIsAtomic() {
        let box = SendableBox<[Int]>([])
        let iterations = 1000

        let expectation = XCTestExpectation(description: "concurrent updates")
        expectation.expectedFulfillmentCount = iterations

        for i in 0..<iterations {
            DispatchQueue.global().async {
                let snapshot = box.updateAndGet { $0.append(i) }
                XCTAssertTrue(snapshot.contains(i))
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(box.value.count, iterations)
    }

    // MARK: - Candle array monotonicity

    func testApplyCandleNeverShrinks() {
        var arr = (0..<300).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let initialCount = arr.count

        // In-progress updates to the last candle
        for i in 0..<50 {
            applyCandle(makeCandle(t: 299 * 60_000, c: "update_\(i)"), to: &arr)
            XCTAssertGreaterThanOrEqual(arr.count, initialCount,
                "In-progress update should not shrink: \(arr.count) < \(initialCount)")
        }

        // New candles appended
        for i in 300..<320 {
            applyCandle(makeCandle(t: i * 60_000, c: "\(i)"), to: &arr)
            XCTAssertGreaterThanOrEqual(arr.count, initialCount,
                "Append should not shrink: \(arr.count) < \(initialCount)")
        }
        XCTAssertEqual(arr.count, 320)
    }

    func testGapRecoveryMergeNeverShrinks() {
        var arr = (0..<300).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let initialCount = arr.count

        // Gap recovery: fetch last 50 candles (overlapping with tail of existing)
        let gapCandles = (280..<310).map { makeCandle(t: $0 * 60_000, c: "gap_\($0)") }
        arr.append(contentsOf: gapCandles)
        arr = dedupCandles(arr)

        XCTAssertGreaterThanOrEqual(arr.count, initialCount,
            "Gap recovery merge should not shrink: \(arr.count) < \(initialCount)")
        XCTAssertEqual(arr.count, 310)
    }

    func testLoadMoreMergeNeverShrinks() {
        var arr = (100..<400).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let initialCount = arr.count

        // Load older candles with partial overlap
        let older = (0..<120).map { makeCandle(t: $0 * 60_000, c: "old_\($0)") }
        arr.insert(contentsOf: older, at: 0)
        arr = dedupCandles(arr)

        XCTAssertGreaterThanOrEqual(arr.count, initialCount,
            "loadMore merge should not shrink: \(arr.count) < \(initialCount)")
        XCTAssertEqual(arr.count, 400)
    }

    func testReconnectCyclePreservesCandles() {
        // Simulate full lifecycle: initial load → WS events → disconnect → reconnect → gap recovery
        var arr = (0..<300).map { makeCandle(t: $0 * 60_000, c: "\($0)") }

        // Live WS events update and extend
        applyCandle(makeCandle(t: 299 * 60_000, c: "live_update"), to: &arr)
        applyCandle(makeCandle(t: 300 * 60_000, c: "300"), to: &arr)
        applyCandle(makeCandle(t: 301 * 60_000, c: "301"), to: &arr)
        XCTAssertEqual(arr.count, 302)

        // Disconnect happens — no changes to array
        // Reconnect — gap recovery fetches last 50 candles
        let gapCandles = (290..<305).map { makeCandle(t: $0 * 60_000, c: "gap_\($0)") }
        arr.append(contentsOf: gapCandles)
        arr = dedupCandles(arr)

        XCTAssertEqual(arr.count, 305)
        // Original candles preserved (not overwritten by gap for non-overlapping range)
        XCTAssertEqual(arr[0].t, 0)
        XCTAssertEqual(arr[0].c, "0")
    }

    // MARK: - CoverageTracker

    func testCoverageAddSingleRange() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        let gaps = tracker.gaps(from: 100, to: 200)
        XCTAssertTrue(gaps.isEmpty, "Covered range should have no gaps")
    }

    func testCoverageGapsEmpty() {
        let tracker = CoverageTracker()
        let gaps = tracker.gaps(from: 100, to: 200)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].from, 100)
        XCTAssertEqual(gaps[0].to, 200)
    }

    func testCoverageMergesOverlapping() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        tracker.add(from: 150, to: 300)
        let gaps = tracker.gaps(from: 100, to: 300)
        XCTAssertTrue(gaps.isEmpty, "Overlapping ranges should merge")
    }

    func testCoverageMergesAdjacent() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        tracker.add(from: 201, to: 300)
        let gaps = tracker.gaps(from: 100, to: 300)
        XCTAssertTrue(gaps.isEmpty, "Adjacent ranges should merge")
    }

    func testCoverageGapBetweenTwoRanges() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        tracker.add(from: 300, to: 400)
        let gaps = tracker.gaps(from: 100, to: 400)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].from, 201)
        XCTAssertEqual(gaps[0].to, 299)
    }

    func testCoverageGapsAtBothEdges() {
        let tracker = CoverageTracker()
        tracker.add(from: 200, to: 300)
        let gaps = tracker.gaps(from: 100, to: 400)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].from, 100)
        XCTAssertEqual(gaps[0].to, 199)
        XCTAssertEqual(gaps[1].from, 301)
        XCTAssertEqual(gaps[1].to, 400)
    }

    func testCoverageIdempotentAdd() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        tracker.add(from: 100, to: 200)
        let gaps = tracker.gaps(from: 100, to: 200)
        XCTAssertTrue(gaps.isEmpty, "Duplicate add should be idempotent")
    }

    func testCoverageMultipleGaps() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        tracker.add(from: 400, to: 500)
        tracker.add(from: 700, to: 800)
        let gaps = tracker.gaps(from: 0, to: 1000)
        XCTAssertEqual(gaps.count, 4)
        XCTAssertEqual(gaps[0].from, 0)
        XCTAssertEqual(gaps[0].to, 99)
        XCTAssertEqual(gaps[1].from, 201)
        XCTAssertEqual(gaps[1].to, 399)
        XCTAssertEqual(gaps[2].from, 501)
        XCTAssertEqual(gaps[2].to, 699)
        XCTAssertEqual(gaps[3].from, 801)
        XCTAssertEqual(gaps[3].to, 1000)
    }

    func testCoverageQuerySubsetOfCovered() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 500)
        let gaps = tracker.gaps(from: 200, to: 400)
        XCTAssertTrue(gaps.isEmpty, "Query within covered range should have no gaps")
    }

    func testCoverageOutOfOrderAdds() {
        let tracker = CoverageTracker()
        tracker.add(from: 500, to: 600)
        tracker.add(from: 100, to: 200)
        tracker.add(from: 300, to: 400)
        let gaps = tracker.gaps(from: 100, to: 600)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].from, 201)
        XCTAssertEqual(gaps[0].to, 299)
        XCTAssertEqual(gaps[1].from, 401)
        XCTAssertEqual(gaps[1].to, 499)
    }

    func testCoverageGapsReversedRange() {
        let tracker = CoverageTracker()
        tracker.add(from: 100, to: 200)
        let gaps = tracker.gaps(from: 200, to: 100)
        XCTAssertTrue(gaps.isEmpty, "Reversed range should return no gaps")
    }

    // MARK: - LoadRangeResult

    func testLoadRangeResultFields() {
        let result = LoadRangeResult(
            loadedCount: 42,
            totalCount: 300,
            rangeStart: 1000,
            rangeEnd: 5000,
            reachedStart: true
        )
        XCTAssertEqual(result.loadedCount, 42)
        XCTAssertEqual(result.totalCount, 300)
        XCTAssertEqual(result.rangeStart, 1000)
        XCTAssertEqual(result.rangeEnd, 5000)
        XCTAssertTrue(result.reachedStart)
    }

    // MARK: - Helpers

    private func makeCandle(t: Int, c: String) -> Candle {
        Candle(t: t, o: "100", h: "200", l: "50", c: c, v: "1000", n: 10, s: nil)
    }
}

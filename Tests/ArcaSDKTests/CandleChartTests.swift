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

    // MARK: - SendableBox.onChange

    func testOnChangeFiresOnUpdate() {
        let box = SendableBox<Int>(0)
        var received: [Int] = []
        box.onChange { received.append($0) }

        box.update { $0 = 1 }
        box.update { $0 = 2 }
        box.update { $0 = 3 }

        XCTAssertEqual(received, [1, 2, 3])
    }

    func testOnChangeFiresOnUpdateAndGet() {
        let box = SendableBox<Int>(0)
        var received: [Int] = []
        box.onChange { received.append($0) }

        let result = box.updateAndGet { $0 = 42 }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(received, [42])
    }

    func testOnChangeMultipleObservers() {
        let box = SendableBox<Int>(0)
        var first: [Int] = []
        var second: [Int] = []
        box.onChange { first.append($0) }
        box.onChange { second.append($0) }

        box.update { $0 = 10 }

        XCTAssertEqual(first, [10])
        XCTAssertEqual(second, [10])
    }

    func testRemoveObserver() {
        let box = SendableBox<Int>(0)
        var received: [Int] = []
        let id = box.onChange { received.append($0) }

        box.update { $0 = 1 }
        XCTAssertEqual(received, [1])

        box.removeObserver(id)
        box.update { $0 = 2 }
        XCTAssertEqual(received, [1], "Removed observer must not fire")
    }

    func testOnChangeConcurrentSafety() {
        let box = SendableBox<Int>(0)
        let count = SendableBox<Int>(0)
        box.onChange { _ in
            count.update { $0 += 1 }
        }

        let iterations = 500
        let expectation = XCTestExpectation(description: "concurrent onChange")
        expectation.expectedFulfillmentCount = iterations

        for i in 0..<iterations {
            DispatchQueue.global().async {
                box.update { $0 = i }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(count.value, iterations)
    }

    // MARK: - CandleChartStream.onUpdate

    func testCandleChartStreamOnUpdateCallback() {
        let callbacks = SendableBox<[UUID: @Sendable (CandleChartUpdate) -> Void]>([:])
        let candlesBox = SendableBox<[Candle]>([])

        let stream = CandleChartStream(
            state: SendableBox(.connected),
            candles: candlesBox,
            updates: AsyncStream { $0.finish() },
            updateCallbacks: callbacks,
            ensureRange: { _, _ in LoadRangeResult(loadedCount: 0, totalCount: 0, rangeStart: 0, rangeEnd: 0, reachedStart: false) },
            loadMore: { _ in LoadRangeResult(loadedCount: 0, totalCount: 0, rangeStart: 0, rangeEnd: 0, reachedStart: false) },
            stop: { }
        )

        var received: [CandleChartUpdate] = []
        let unsub = stream.onUpdate { received.append($0) }

        let candle = makeCandle(t: 1000, c: "100")
        let update = CandleChartUpdate(candles: [candle], latestCandle: candle)
        let cbs = callbacks.value
        for cb in cbs.values { cb(update) }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].candles.count, 1)
        XCTAssertEqual(received[0].latestCandle.t, 1000)

        unsub()

        let update2 = CandleChartUpdate(candles: [candle], latestCandle: candle)
        let cbs2 = callbacks.value
        for cb in cbs2.values { cb(update2) }
        XCTAssertEqual(received.count, 1, "Unsubscribed callback must not fire")
    }

    func testCandleChartStreamMultipleOnUpdateCallbacks() {
        let callbacks = SendableBox<[UUID: @Sendable (CandleChartUpdate) -> Void]>([:])

        let stream = CandleChartStream(
            state: SendableBox(.connected),
            candles: SendableBox([]),
            updates: AsyncStream { $0.finish() },
            updateCallbacks: callbacks,
            ensureRange: { _, _ in LoadRangeResult(loadedCount: 0, totalCount: 0, rangeStart: 0, rangeEnd: 0, reachedStart: false) },
            loadMore: { _ in LoadRangeResult(loadedCount: 0, totalCount: 0, rangeStart: 0, rangeEnd: 0, reachedStart: false) },
            stop: { }
        )

        var firstCount = 0
        var secondCount = 0
        stream.onUpdate { _ in firstCount += 1 }
        let unsub2 = stream.onUpdate { _ in secondCount += 1 }

        let candle = makeCandle(t: 1000, c: "100")
        let update = CandleChartUpdate(candles: [candle], latestCandle: candle)
        let cbs = callbacks.value
        for cb in cbs.values { cb(update) }

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)

        unsub2()

        let cbs2 = callbacks.value
        for cb in cbs2.values { cb(update) }
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, 1, "Second callback should not fire after unsub")
    }

    // MARK: - Sparse initial data (skipBackfill coverage)

    func testSparseInitialDataDoesNotMarkCoverage() {
        let coverage = CoverageTracker()
        let count = 300
        let startTime = 0
        let endTime = 300 * 60_000

        let sparseCandles = [makeCandle(t: 150 * 60_000, c: "150")]
        let needsRetry = sparseCandles.count < count / 2

        XCTAssertTrue(needsRetry, "1 candle out of 300 should trigger retry")

        if !needsRetry && !sparseCandles.isEmpty {
            coverage.add(from: startTime, to: endTime)
        }

        let gaps = coverage.gaps(from: startTime, to: endTime)
        XCTAssertEqual(gaps.count, 1, "Sparse data must not mark coverage — full range should be a gap")
        XCTAssertEqual(gaps[0].from, startTime)
        XCTAssertEqual(gaps[0].to, endTime)
    }

    func testSufficientInitialDataMarksCoverage() {
        let coverage = CoverageTracker()
        let count = 300
        let startTime = 0
        let endTime = 300 * 60_000

        let candles = (0..<200).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let needsRetry = candles.count < count / 2

        XCTAssertFalse(needsRetry, "200 candles out of 300 should not trigger retry")

        if !needsRetry && !candles.isEmpty {
            coverage.add(from: startTime, to: endTime)
        }

        let gaps = coverage.gaps(from: startTime, to: endTime)
        XCTAssertTrue(gaps.isEmpty, "Sufficient data should mark coverage with no gaps")
    }

    func testBoundaryExactlyHalfDoesNotTriggerRetry() {
        let count = 300
        let threshold = count / 2 // 150

        let candles = (0..<threshold).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let needsRetry = candles.count < count / 2

        XCTAssertFalse(needsRetry, "Exactly count/2 candles should not trigger retry")
    }

    func testBoundaryOneUnderHalfTriggersRetry() {
        let count = 300
        let threshold = count / 2 - 1 // 149

        let candles = (0..<threshold).map { makeCandle(t: $0 * 60_000, c: "\($0)") }
        let needsRetry = candles.count < count / 2

        XCTAssertTrue(needsRetry, "count/2 - 1 candles should trigger retry")
    }

    func testEmptyInitialDataTriggersRetry() {
        let count = 300
        let candles: [Candle] = []
        let needsRetry = candles.count < count / 2

        XCTAssertTrue(needsRetry, "Empty candles should trigger retry")
    }

    // MARK: - CandleCDN cancellation

    func testFetchCandlesFromCDN_cancellationBeforeFetchExitsImmediately() async {
        var fallbackCalls = 0
        let apiFallback: @Sendable (Int, Int) async throws -> [Candle] = { _, _ in
            fallbackCalls += 1
            return [self.makeCandle(t: 1000, c: "100")]
        }

        let task = Task {
            try await CandleCDN.fetchCandlesFromCDN(
                baseUrl: "https://cdn.example.com",
                coin: "hl:BTC",
                interval: .oneHour,
                startMs: 0,
                endMs: 30 * 24 * 3_600_000,
                apiFallback: apiFallback
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(fallbackCalls, 0, "API fallback must not be called when task is cancelled")
    }

    func testFetchCandlesFromCDN_cancellationDoesNotFallbackToAPI() async {
        var fallbackCalls = 0

        let slowSession = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 5
            return config
        }())

        let apiFallback: @Sendable (Int, Int) async throws -> [Candle] = { _, _ in
            fallbackCalls += 1
            return []
        }

        let task = Task {
            try await CandleCDN.fetchCandlesFromCDN(
                baseUrl: "http://10.255.255.1:1",
                coin: "hl:BTC",
                interval: .oneHour,
                startMs: 0,
                endMs: 14 * 24 * 3_600_000,
                session: slowSession,
                apiFallback: apiFallback
            )
        }

        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms — let child tasks spawn
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            // URLSession errors wrapped in task group are acceptable too
        }

        XCTAssertEqual(fallbackCalls, 0, "API fallback must not be called after cancellation")
    }

    // MARK: - CandleCDN chunk boundary tests (DST spring-forward)

    func testDailyChunkOnDSTDay() {
        let march8Ms = 1_772_928_000_000
        let march9Ms = 1_773_014_400_000
        let chunk = CandleCDN.chunkForTime(interval: .fiveMinutes, ms: march8Ms)
        XCTAssertEqual(chunk.key, "2026-03-08")
        XCTAssertEqual(chunk.startMs, march8Ms)
        XCTAssertEqual(chunk.endMs, march9Ms, "Daily chunk end must be March 9 00:00 UTC regardless of DST")
    }

    func testWeeklyChunkAcrossDST() {
        let march2Ms = 1_772_409_600_000
        let march9Ms = 1_773_014_400_000
        let chunk = CandleCDN.chunkForTime(interval: .oneHour, ms: march2Ms)
        XCTAssertEqual(chunk.key, "2026-W10")
        XCTAssertEqual(chunk.startMs, march2Ms)
        XCTAssertEqual(chunk.endMs, march9Ms, "Weekly chunk end must be March 9 00:00 UTC despite DST transition on March 8")
    }

    func testMonthlyChunkAcrossDST() {
        let march1Ms = 1_772_323_200_000
        let april1Ms = 1_775_001_600_000
        let chunk = CandleCDN.chunkForTime(interval: .oneDay, ms: march1Ms)
        XCTAssertEqual(chunk.key, "2026-03")
        XCTAssertEqual(chunk.startMs, march1Ms)
        XCTAssertEqual(chunk.endMs, april1Ms, "Monthly chunk end must be April 1 00:00 UTC despite DST transition in March")
    }

    // MARK: - CandleCDN chunk boundary tests (DST fall-back)

    func testDailyChunkOnFallBack() {
        let nov1Ms = 1_793_491_200_000
        let nov2Ms = 1_793_577_600_000
        let chunk = CandleCDN.chunkForTime(interval: .fiveMinutes, ms: nov1Ms)
        XCTAssertEqual(chunk.key, "2026-11-01")
        XCTAssertEqual(chunk.startMs, nov1Ms)
        XCTAssertEqual(chunk.endMs, nov2Ms, "Daily chunk end must be Nov 2 00:00 UTC regardless of fall-back DST")
    }

    func testWeeklyChunkAcrossFallBack() {
        let oct26Ms = 1_792_972_800_000
        let nov2Ms  = 1_793_577_600_000
        let chunk = CandleCDN.chunkForTime(interval: .oneHour, ms: oct26Ms)
        XCTAssertEqual(chunk.key, "2026-W44")
        XCTAssertEqual(chunk.startMs, oct26Ms)
        XCTAssertEqual(chunk.endMs, nov2Ms, "Weekly chunk end must be Nov 2 00:00 UTC despite fall-back DST on Nov 1")
    }

    func testMonthlyChunkAcrossFallBack() {
        let nov1Ms = 1_793_491_200_000
        let dec1Ms = 1_796_083_200_000
        let chunk = CandleCDN.chunkForTime(interval: .oneDay, ms: nov1Ms)
        XCTAssertEqual(chunk.key, "2026-11")
        XCTAssertEqual(chunk.startMs, nov1Ms)
        XCTAssertEqual(chunk.endMs, dec1Ms, "Monthly chunk end must be Dec 1 00:00 UTC despite fall-back DST in November")
    }

    // MARK: - chunksForRange termination tests

    func testChunksForRangeWeekly_NoInfiniteLoop() {
        let march1Ms = 1_772_323_200_000
        let april1Ms = 1_775_001_600_000
        let chunks = CandleCDN.chunksForRange(interval: .oneHour, startMs: march1Ms, endMs: april1Ms)
        XCTAssertGreaterThan(chunks.count, 0, "Should produce at least one chunk")
        XCTAssertLessThanOrEqual(chunks.count, 7, "One month should need at most 7 weekly chunks")

        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startMs, chunks[i-1].endMs,
                "Chunks must be contiguous: chunk \(i) start should equal chunk \(i-1) end")
        }
        XCTAssertLessThanOrEqual(chunks.first!.startMs, march1Ms)
        XCTAssertGreaterThanOrEqual(chunks.last!.endMs, april1Ms)
    }

    func testChunksForRangeMonthly_NoInfiniteLoop() {
        let jan1Ms  = 1_767_225_600_000
        let jan1_2027Ms = 1_798_761_600_000
        let chunks = CandleCDN.chunksForRange(interval: .oneDay, startMs: jan1Ms, endMs: jan1_2027Ms)
        XCTAssertEqual(chunks.count, 12, "Full year at 1d interval should produce 12 monthly chunks")

        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startMs, chunks[i-1].endMs,
                "Chunks must be contiguous: chunk \(i) start should equal chunk \(i-1) end")
        }
        XCTAssertEqual(chunks.first!.key, "2026-01")
        XCTAssertEqual(chunks.last!.key, "2026-12")
    }

    // MARK: - Cross-SDK chunk key verification

    func testChunkKeysMatchGoBackend() {
        let march15NoonMs = 1_773_576_000_000

        let daily = CandleCDN.chunkForTime(interval: .fiveMinutes, ms: march15NoonMs)
        XCTAssertEqual(daily.key, "2026-03-15")

        let weekly = CandleCDN.chunkForTime(interval: .oneHour, ms: march15NoonMs)
        XCTAssertEqual(weekly.key, "2026-W11")

        let monthly = CandleCDN.chunkForTime(interval: .oneDay, ms: march15NoonMs)
        XCTAssertEqual(monthly.key, "2026-03")

        let jan1Ms = 1_767_225_600_000
        let janDaily = CandleCDN.chunkForTime(interval: .oneMinute, ms: jan1Ms)
        XCTAssertEqual(janDaily.key, "2026-01-01")

        let janWeekly = CandleCDN.chunkForTime(interval: .fourHours, ms: jan1Ms)
        XCTAssertEqual(janWeekly.key, "2026-W01")

        let janMonthly = CandleCDN.chunkForTime(interval: .oneDay, ms: jan1Ms)
        XCTAssertEqual(janMonthly.key, "2026-01")
    }

    // MARK: - Helpers

    private func makeCandle(t: Int, c: String) -> Candle {
        Candle(t: t, o: "100", h: "200", l: "50", c: c, v: "1000", n: 10, s: nil)
    }
}

import Foundation

private let gapRecoveryCandles = 50
private let defaultLoadCount = 300

private struct PendingCandleRange: Sendable {
    let from: Int
    let to: Int
}

private struct RangeLoadState: Sendable {
    var loading = false
    var pendingRange: PendingCandleRange?
    var task: Task<Int, Never>?
}

private func mergePendingRange(
    _ current: PendingCandleRange?,
    with next: PendingCandleRange
) -> PendingCandleRange {
    guard let current else { return next }
    return PendingCandleRange(
        from: min(current.from, next.from),
        to: max(current.to, next.to)
    )
}

// MARK: - CoverageTracker

/// Tracks which time ranges have been loaded as a sorted, non-overlapping
/// interval list. Merge-on-insert keeps the list compact; gap queries against
/// a requested range run in O(n) where n is the number of coverage intervals.
final class CoverageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [(from: Int, to: Int)] = []

    func add(from: Int, to: Int) {
        lock.lock()
        defer { lock.unlock() }
        intervals.append((from, to))
        intervals.sort { $0.from < $1.from }
        var merged: [(from: Int, to: Int)] = []
        for iv in intervals {
            if let last = merged.last, iv.from <= last.to + 1 {
                merged[merged.count - 1] = (last.from, max(last.to, iv.to))
            } else {
                merged.append(iv)
            }
        }
        intervals = merged
    }

    func gaps(from: Int, to: Int) -> [(from: Int, to: Int)] {
        lock.lock()
        defer { lock.unlock() }
        guard from <= to else { return [] }
        var result: [(from: Int, to: Int)] = []
        var cursor = from
        for iv in intervals {
            if cursor > to { break }
            if iv.to < cursor { continue }
            if iv.from > cursor {
                result.append((cursor, min(iv.from - 1, to)))
            }
            cursor = max(cursor, iv.to + 1)
        }
        if cursor <= to {
            result.append((cursor, to))
        }
        return result
    }

    #if DEBUG
    var debugIntervals: [(from: Int, to: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return intervals
    }
    #endif
}

// MARK: - watchCandleChart

extension Arca {

    /// Create a live candle chart that merges historical candle data with
    /// real-time WebSocket updates. The candle array stays sorted and deduped;
    /// new bars appear automatically as candle events arrive.
    ///
    /// On WebSocket reconnection, recent candles are refetched to fill any gap.
    ///
    /// Use ``CandleChartStream/ensureRange`` when the visible viewport changes
    /// (zoom, resize, jump to date). Use ``CandleChartStream/loadMore`` for
    /// simple backward scrolling.
    ///
    /// The `updates` stream is buffered to the latest snapshot only: slow
    /// consumers will drop intermediate snapshots rather than accumulating
    /// them in memory. The full candle array is always available on
    /// ``CandleChartStream/candles`` so dropped intermediates are recoverable.
    ///
    /// - Parameters:
    ///   - coin: Canonical coin ID (e.g. `"hl:BTC"`, `"hl:1:BRENTOIL"`)
    ///   - interval: Candle interval (e.g. `.oneMinute`)
    ///   - count: Number of historical candles to load (default 300)
    public func watchCandleChart(
        coin: String,
        interval: CandleInterval,
        count: Int = 300
    ) async throws -> CandleChartStream {
        try Task.checkCancellation()
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let candlesBox = SendableBox<[Candle]>([])
        let continuationBox = SendableBox<AsyncStream<CandleChartUpdate>.Continuation?>(nil)
        let loadingMore = SendableBox<Bool>(false)
        let stoppedBox = SendableBox<Bool>(false)
        let reachedStartBox = SendableBox<Bool>(false)
        let coverage = CoverageTracker()
        let rangeLoadState = SendableBox(RangeLoadState())

        await ws.acquireCandles(coins: [coin], intervals: [interval])

        do {
            try Task.checkCancellation()
        } catch {
            await ws.releaseCandles(coins: [coin], intervals: [interval])
            throw error
        }

        let candleStream = await ws.candleEvents()
        let statusStream = await ws.statusStream

        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let startTime = nowMs - interval.milliseconds * count
        let history: CandlesResponse
        var initialHistoryError: Error?
        do {
            history = try await getCandles(
                coin: coin,
                interval: interval,
                startTime: startTime,
                skipBackfill: true
            )
        } catch is CancellationError {
            await ws.releaseCandles(coins: [coin], intervals: [interval])
            throw CancellationError()
        } catch {
            initialHistoryError = error
            log.error("candle",
                        "initial getCandles failed; showing empty history",
                        error: error,
                        metadata: [
                            "coin": coin,
                            "interval": interval.rawValue,
                            "fingerprint": "initial_getcandles_failed"
                        ])
            history = CandlesResponse(coin: coin, interval: interval.rawValue, candles: [])
        }

        let needsRetry = history.candles.count < count / 2
        let initialHistoryState: InitialHistoryState
        if let error = initialHistoryError {
            initialHistoryState = .failed(error: String(describing: error))
        } else if needsRetry && history.candles.isEmpty {
            initialHistoryState = .failed(error: "Empty history response")
        } else if needsRetry {
            initialHistoryState = .loaded(count: history.candles.count) // or failed?
        } else {
            initialHistoryState = .loaded(count: history.candles.count)
        }
        
        let historySnapshot = SendableBox<InitialHistoryState>(initialHistoryState)
        candlesBox.update { $0 = dedupCandles(history.candles) }
        state.update { $0 = .connected }

        if !needsRetry && !history.candles.isEmpty {
            coverage.add(from: startTime, to: nowMs)
        }

        let previousCount = SendableBox<Int>(0)
        let chartCallbacks = SendableBox<[UUID: @Sendable (CandleChartUpdate) -> Void]>([:])

        let yieldSnapshot: @Sendable (AsyncStream<CandleChartUpdate>.Continuation, [Candle], Candle) -> Void = { [log] cont, snapshot, trigger in
            let count = snapshot.count
            let prev = previousCount.value
            if count < prev {
                log.warning("candle",
                            "candle array shrunk; skipping emit to avoid flicker",
                            metadata: [
                                "previousCount": String(prev),
                                "count": String(count),
                            ])
                return
            }
            previousCount.update { $0 = max($0, count) }
            let update = CandleChartUpdate(
                candles: snapshot,
                latestCandle: trigger
            )
            cont.yield(update)
            let cbs = chartCallbacks.value
            for cb in cbs.values { cb(update) }
        }

        let updates = AsyncStream(CandleChartUpdate.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuationBox.update { $0 = continuation }

            let initial = candlesBox.value
            if let last = initial.last {
                yieldSnapshot(continuation, initial, last)
            }

            let candleTask = Task { [weak ws] in
                for await event in candleStream {
                    guard event.coin == coin,
                          event.interval == interval else { continue }

                    let latest = event.candle
                    let snapshot = candlesBox.updateAndGet { arr in
                        applyCandle(latest, to: &arr)
                    }
                    
                    // Gate WS-only snapshots until history succeeds
                    if case .loaded = historySnapshot.value {
                        yieldSnapshot(continuation, snapshot, latest)
                    }
                    _ = ws
                }
                continuation.finish()
            }

            let statusTask = Task { [weak self] in
                var wasConnected = false
                for await s in statusStream {
                    if s == .disconnected {
                        state.update { $0 = .reconnecting }
                    } else if s == .connected {
                        state.update { $0 = .connected }
                        if wasConnected, let self = self {
                            let gapStart = Int(Date().timeIntervalSince1970 * 1000)
                                - interval.milliseconds * gapRecoveryCandles
                            do {
                                let res = try await self.getCandles(
                                    coin: coin,
                                    interval: interval,
                                    startTime: gapStart
                                )
                                if !res.candles.isEmpty {
                                    let snapshot = candlesBox.updateAndGet { arr in
                                        arr.append(contentsOf: res.candles)
                                        arr = dedupCandles(arr)
                                    }
                                    let gapEnd = Int(Date().timeIntervalSince1970 * 1000)
                                    coverage.add(from: gapStart, to: gapEnd)
                                    if let last = snapshot.last {
                                        yieldSnapshot(continuation, snapshot, last)
                                    }
                                }
                            } catch {
                                self.log.warning("candle",
                                                 "gap recovery refetch failed",
                                                 error: error,
                                                 metadata: [
                                                     "coin": coin,
                                                     "interval": interval.rawValue,
                                                 ])
                            }
                        }
                    }
                    wasConnected = true
                }
            }

            let retryTask: Task<Void, Never>? = needsRetry ? Task { [weak self] in
                var delay: UInt64 = 1_000_000_000
                let maxDelay: UInt64 = 30_000_000_000
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, let self = self else { return }
                    do {
                        let retryStart = Int(Date().timeIntervalSince1970 * 1000)
                            - interval.milliseconds * count
                        let res = try await self.getCandles(
                            coin: coin,
                            interval: interval,
                            startTime: retryStart
                        )
                        if !res.candles.isEmpty {
                            let snapshot = candlesBox.updateAndGet { arr in
                                arr.append(contentsOf: res.candles)
                                arr = dedupCandles(arr)
                            }
                            let retryEnd = Int(Date().timeIntervalSince1970 * 1000)
                            coverage.add(from: retryStart, to: retryEnd)
                            if let last = snapshot.last {
                                yieldSnapshot(continuation, snapshot, last)
                            }
                            return
                        }
                    } catch {
                        self.log.warning("candle",
                                         "initial candle retry failed; backing off",
                                         error: error,
                                         metadata: [
                                             "coin": coin,
                                             "interval": interval.rawValue,
                                         ])
                    }
                    delay = min(delay * 2, maxDelay)
                }
            } : nil

            continuation.onTermination = { _ in
                candleTask.cancel()
                statusTask.cancel()
                retryTask?.cancel()
            }
        }

        let drainPendingRanges: @Sendable () async -> Int = { [weak self] in
            guard let self = self else { return 0 }

            var totalLoaded = 0
            while !stoppedBox.value {
                var requested: PendingCandleRange?
                rangeLoadState.update { state in
                    requested = state.pendingRange
                    state.pendingRange = nil
                }
                guard let requested else { break }

                let gaps = coverage.gaps(from: requested.from, to: requested.to)
                await withTaskGroup(of: (Int, Int, [Candle])?.self) { group in
                    for gap in gaps {
                        group.addTask { [self] in
                            do {
                                let res = try await self.getCandles(
                                    coin: coin,
                                    interval: interval,
                                    startTime: gap.from,
                                    endTime: gap.to
                                )
                                return (gap.from, gap.to, res.candles)
                            } catch {
                                self.log.warning("candle",
                                                 "range gap fetch failed",
                                                 error: error,
                                                 metadata: [
                                                     "coin": coin,
                                                     "interval": interval.rawValue,
                                                     "from": String(gap.from),
                                                     "to": String(gap.to),
                                                 ])
                                return nil
                            }
                        }
                    }
                    for await result in group {
                        guard !stoppedBox.value, !Task.isCancelled else { return }
                        guard let (from, to, candles) = result else { continue }

                        if !candles.isEmpty {
                            candlesBox.update { arr in
                                arr.append(contentsOf: candles)
                                arr = dedupCandles(arr)
                            }
                            totalLoaded += candles.count
                            coverage.add(from: from, to: to)
                        } else {
                            let earliest = candlesBox.value.first?.t ?? Int.max
                            if from <= earliest {
                                reachedStartBox.update { $0 = true }
                                coverage.add(from: from, to: to)
                            }
                        }

                        let snapshot = candlesBox.value
                        if let cont = continuationBox.value, let last = snapshot.last {
                            yieldSnapshot(cont, snapshot, last)
                        }
                    }
                }
                guard !Task.isCancelled else { break }
            }

            return totalLoaded
        }

        // MARK: ensureRange

        let ensureRange: @Sendable (_ start: Int, _ end: Int) async -> LoadRangeResult = { start, end in
            let makeResult: ([Candle], Int) -> LoadRangeResult = { candles, loaded in
                LoadRangeResult(
                    loadedCount: loaded,
                    totalCount: candles.count,
                    rangeStart: candles.first?.t ?? 0,
                    rangeEnd: candles.last?.t ?? 0,
                    reachedStart: reachedStartBox.value
                )
            }

            guard !stoppedBox.value else {
                return makeResult(candlesBox.value, 0)
            }
            guard start <= end else {
                return makeResult(candlesBox.value, 0)
            }
            if coverage.gaps(from: start, to: end).isEmpty {
                return makeResult(candlesBox.value, 0)
            }

            let requestedRange = PendingCandleRange(from: start, to: end)
            let enqueueRequestedRange = {
                rangeLoadState.update { state in
                    state.pendingRange = mergePendingRange(state.pendingRange, with: requestedRange)
                }
            }
            enqueueRequestedRange()

            while true {
                var existingTask: Task<Int, Never>?
                var shouldStartTask = false
                rangeLoadState.update { state in
                    if state.loading {
                        existingTask = state.task
                    } else {
                        state.loading = true
                        shouldStartTask = true
                    }
                }

                if shouldStartTask {
                    let task = Task {
                        await drainPendingRanges()
                    }
                    rangeLoadState.update { $0.task = task }
                    loadingMore.update { $0 = true }

                    let loaded = await task.value

                    rangeLoadState.update { state in
                        state.loading = false
                        state.task = nil
                    }
                    loadingMore.update { $0 = false }
                    return makeResult(candlesBox.value, loaded)
                }

                if let existingTask {
                    _ = await existingTask.value
                } else {
                    await Task.yield()
                }

                guard !stoppedBox.value else {
                    return makeResult(candlesBox.value, 0)
                }
                if coverage.gaps(from: start, to: end).isEmpty {
                    return makeResult(candlesBox.value, 0)
                }
                enqueueRequestedRange()
            }
        }

        // MARK: loadMore

        let loadMore: @Sendable (_ count: Int) async -> LoadRangeResult = { count in
            let earliest = candlesBox.value.first?.t ?? 0
            guard earliest > 0 else {
                return LoadRangeResult(
                    loadedCount: 0,
                    totalCount: candlesBox.value.count,
                    rangeStart: 0,
                    rangeEnd: candlesBox.value.last?.t ?? 0,
                    reachedStart: reachedStartBox.value
                )
            }
            let end = earliest - 1
            let start = max(0, end - interval.milliseconds * count)
            return await ensureRange(start, end)
        }

        return CandleChartStream(
            state: state,
            historySnapshot: historySnapshot,
            candles: candlesBox,
            updates: updates,
            updateCallbacks: chartCallbacks,
            ensureRange: ensureRange,
            loadMore: loadMore,
            stop: { [ws] in
                stoppedBox.update { $0 = true }
                continuationBox.update { $0 = nil }
                await ws.releaseCandles(coins: [coin], intervals: [interval])
            }
        )
    }
}

/// Apply a single candle to a sorted array. Updates in place if the
/// timestamp already exists; appends if newer; inserts at the correct
/// sorted position otherwise. Never creates duplicate timestamps.
func applyCandle(_ candle: Candle, to arr: inout [Candle]) {
    // Fast path: update the current (last) candle in place.
    if let last = arr.last, last.t == candle.t {
        arr[arr.count - 1] = candle
        return
    }
    // Fast path: new bar strictly after the latest — append.
    if arr.isEmpty || candle.t > arr[arr.count - 1].t {
        arr.append(candle)
        return
    }
    // Out-of-order candle (e.g., a candle.closed arriving after the next
    // bucket's candle.updated during WS reconnection). Search backwards
    // from the tail since out-of-order candles are typically recent.
    var i = arr.count - 2
    while i >= 0 {
        if arr[i].t == candle.t {
            arr[i] = candle
            return
        }
        if arr[i].t < candle.t {
            arr.insert(candle, at: i + 1)
            return
        }
        i -= 1
    }
    arr.insert(candle, at: 0)
}

/// Sort candles by timestamp and deduplicate, keeping the last entry for
/// each timestamp (live data wins over historical).
func dedupCandles(_ candles: [Candle]) -> [Candle] {
    let sorted = candles.sorted { $0.t < $1.t }
    guard !sorted.isEmpty else { return [] }
    var result: [Candle] = [sorted[0]]
    for i in 1..<sorted.count {
        if sorted[i].t == result[result.count - 1].t {
            result[result.count - 1] = sorted[i]
        } else {
            result.append(sorted[i])
        }
    }
    return result
}

import Foundation

private let gapRecoveryCandles = 50
private let loadMoreBatchSize = 300

extension Arca {

    /// Create a live candle chart that merges historical candle data with
    /// real-time WebSocket updates. The candle array stays sorted and deduped;
    /// new bars appear automatically as candle events arrive.
    ///
    /// On WebSocket reconnection, recent candles are refetched to fill any gap.
    ///
    /// Call ``CandleChartStream/loadMore`` when the user scrolls to the left
    /// edge of the chart — it fetches the next batch of older candles, merges
    /// them, and emits an update through the same `updates` stream.
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
        await ws.ensureConnected()

        let state = SendableBox<WatchStreamState>(.loading)
        let candlesBox = SendableBox<[Candle]>([])
        let continuationBox = SendableBox<AsyncStream<CandleChartUpdate>.Continuation?>(nil)
        let loadingMore = SendableBox<Bool>(false)
        let stoppedBox = SendableBox<Bool>(false)

        // Subscribe to WS candles BEFORE fetching history so we don't miss
        // events that arrive between the HTTP snapshot and subscription.
        await ws.acquireCandles(coins: [coin], intervals: [interval])

        let candleStream = await ws.candleEvents()
        let statusStream = await ws.statusStream

        // Fetch historical candles with explicit startTime so the cache key
        // is unique per invocation (avoids stale HistoryCache hits).
        let startTime = Int(Date().timeIntervalSince1970 * 1000) - interval.milliseconds * count
        let history: CandlesResponse
        do {
            history = try await getCandles(
                coin: coin,
                interval: interval,
                startTime: startTime,
                skipBackfill: true
            )
        } catch {
            #if DEBUG
            print("[ArcaSDK] initial getCandles failed: \(error)")
            #endif
            history = CandlesResponse(coin: coin, interval: interval.rawValue, candles: [])
        }

        candlesBox.update { $0 = dedupCandles(history.candles) }
        state.update { $0 = .connected }
        let needsRetry = history.candles.isEmpty

        let previousCount = SendableBox<Int>(0)

        let yieldSnapshot: @Sendable (AsyncStream<CandleChartUpdate>.Continuation, [Candle], Candle) -> Void = {
            cont, snapshot, trigger in
            let count = snapshot.count
            let prev = previousCount.value
            if count < prev {
                #if DEBUG
                print("[ArcaSDK] WARNING: candle array shrunk \(prev) → \(count)")
                #endif
                return
            }
            previousCount.update { $0 = max($0, count) }
            cont.yield(CandleChartUpdate(
                candles: snapshot,
                latestCandle: trigger
            ))
        }

        let updates = AsyncStream<CandleChartUpdate> { continuation in
            continuationBox.update { $0 = continuation }

            // Emit the historical snapshot immediately so `for await` renders
            // the chart on the very first iteration — no waiting for a WS event.
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
                    yieldSnapshot(continuation, snapshot, latest)
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
                            if let res = try? await self.getCandles(
                                coin: coin,
                                interval: interval,
                                startTime: gapStart
                            ), !res.candles.isEmpty {
                                let snapshot = candlesBox.updateAndGet { arr in
                                    arr.append(contentsOf: res.candles)
                                    arr = dedupCandles(arr)
                                }
                                if let last = snapshot.last {
                                    yieldSnapshot(continuation, snapshot, last)
                                }
                            }
                        }
                    }
                    wasConnected = true
                }
            }

            // If the initial fetch returned empty candles, retry indefinitely
            // with capped exponential backoff. Staying on a screen should never
            // produce worse data than closing and reopening the app.
            let retryTask: Task<Void, Never>? = needsRetry ? Task { [weak self] in
                var delay: UInt64 = 1_000_000_000 // 1s
                let maxDelay: UInt64 = 30_000_000_000 // 30s
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
                            if let last = snapshot.last {
                                yieldSnapshot(continuation, snapshot, last)
                            }
                            return
                        }
                    } catch {
                        #if DEBUG
                        print("[ArcaSDK] candle retry failed: \(error)")
                        #endif
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

        let loadMore: @Sendable () async -> Bool = { [weak self] in
            guard !stoppedBox.value else { return false }
            var alreadyLoading = false
            loadingMore.update { val in
                alreadyLoading = val
                val = true
            }
            if alreadyLoading { return false }
            defer { loadingMore.update { $0 = false } }

            guard let self = self else { return false }

            let earliest = candlesBox.value.first?.t
            guard let earliest = earliest, earliest > 0 else { return false }

            let endTime = earliest - 1
            let fetchStart = max(0, endTime - interval.milliseconds * loadMoreBatchSize)

            guard let res = try? await self.getCandles(
                coin: coin,
                interval: interval,
                startTime: fetchStart,
                endTime: endTime
            ), !res.candles.isEmpty else {
                return false
            }

            let snapshot = candlesBox.updateAndGet { arr in
                arr.insert(contentsOf: res.candles, at: 0)
                arr = dedupCandles(arr)
            }

            if let cont = continuationBox.value, let first = snapshot.first {
                yieldSnapshot(cont, snapshot, first)
            }

            return true
        }

        return CandleChartStream(
            state: state,
            candles: candlesBox,
            updates: updates,
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

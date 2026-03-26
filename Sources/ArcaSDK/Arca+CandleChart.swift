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
                startTime: startTime
            )
        } catch {
            history = CandlesResponse(coin: coin, interval: interval.rawValue, candles: [])
        }

        candlesBox.update { $0 = dedupCandles(history.candles) }
        state.update { $0 = .connected }

        let updates = AsyncStream<CandleChartUpdate> { continuation in
            continuationBox.update { $0 = continuation }

            // Emit the historical snapshot immediately so `for await` renders
            // the chart on the very first iteration — no waiting for a WS event.
            if let last = candlesBox.value.last {
                continuation.yield(CandleChartUpdate(
                    candles: candlesBox.value,
                    latestCandle: last
                ))
            }

            let candleTask = Task { [weak ws] in
                for await event in candleStream {
                    guard event.coin == coin,
                          event.interval == interval else { continue }

                    let latest = event.candle
                    candlesBox.update { arr in
                        applyCandle(latest, to: &arr)
                    }
                    continuation.yield(CandleChartUpdate(
                        candles: candlesBox.value,
                        latestCandle: latest
                    ))
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
                                candlesBox.update { arr in
                                    arr.append(contentsOf: res.candles)
                                    arr = dedupCandles(arr)
                                }
                                if let last = candlesBox.value.last {
                                    continuation.yield(CandleChartUpdate(
                                        candles: candlesBox.value,
                                        latestCandle: last
                                    ))
                                }
                            }
                        }
                    }
                    wasConnected = true
                }
            }

            continuation.onTermination = { _ in
                candleTask.cancel()
                statusTask.cancel()
            }
        }

        let loadMore: @Sendable () async -> Bool = { [weak self] in
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

            candlesBox.update { arr in
                arr.insert(contentsOf: res.candles, at: 0)
                arr = dedupCandles(arr)
            }

            if let cont = continuationBox.value {
                let snapshot = candlesBox.value
                if let first = snapshot.first {
                    cont.yield(CandleChartUpdate(
                        candles: snapshot,
                        latestCandle: first
                    ))
                }
            }

            return true
        }

        return CandleChartStream(
            state: state,
            candles: candlesBox,
            updates: updates,
            loadMore: loadMore,
            stop: { [ws] in
                await ws.releaseCandles(coins: [coin], intervals: [interval])
            }
        )
    }
}

/// Apply a single candle to a sorted array: update in place if timestamps
/// match the last entry, otherwise append.
func applyCandle(_ candle: Candle, to arr: inout [Candle]) {
    if let last = arr.last, last.t == candle.t {
        arr[arr.count - 1] = candle
    } else {
        arr.append(candle)
    }
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

import Foundation

/// CDN chunk fetching for historical candle data.
/// Mirrors the TypeScript SDK's `candle-cdn.ts` logic.
public enum CandleCDN {

    // MARK: - Chunk Period Computation

    struct ChunkPeriod {
        let key: String
        let startMs: Int
        let endMs: Int
    }

    private enum ChunkGranularity {
        case daily, weekly, monthly
    }

    private static func chunkGranularity(for interval: CandleInterval) -> ChunkGranularity {
        switch interval {
        case .fifteenSeconds, .oneMinute, .fiveMinutes, .fifteenMinutes:
            return .daily
        case .oneHour, .fourHours:
            return .weekly
        case .oneDay:
            return .monthly
        }
    }

    private static func dailyChunk(_ date: Date) -> ChunkPeriod {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        comps.hour = 0; comps.minute = 0; comps.second = 0; comps.nanosecond = 0
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let y = comps.year!, m = comps.month!, d = comps.day!
        let key = String(format: "%04d-%02d-%02d", y, m, d)
        return ChunkPeriod(key: key, startMs: Int(start.timeIntervalSince1970 * 1000), endMs: Int(end.timeIntervalSince1970 * 1000))
    }

    private static func weeklyChunk(_ date: Date) -> ChunkPeriod {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = comps.yearForWeekOfYear!
        let week = comps.weekOfYear!

        let monday = isoWeekStart(year: year, week: week)
        let end = cal.date(byAdding: .day, value: 7, to: monday)!
        let key = String(format: "%04d-W%02d", year, week)
        return ChunkPeriod(key: key, startMs: Int(monday.timeIntervalSince1970 * 1000), endMs: Int(end.timeIntervalSince1970 * 1000))
    }

    private static func monthlyChunk(_ date: Date) -> ChunkPeriod {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        comps.day = 1; comps.hour = 0; comps.minute = 0; comps.second = 0; comps.nanosecond = 0
        let start = cal.date(from: comps)!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let key = String(format: "%04d-%02d", comps.year!, comps.month!)
        return ChunkPeriod(key: key, startMs: Int(start.timeIntervalSince1970 * 1000), endMs: Int(end.timeIntervalSince1970 * 1000))
    }

    private static func isoWeekStart(year: Int, week: Int) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2 // Monday
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return cal.date(from: comps)!
    }

    static func chunkForTime(interval: CandleInterval, ms: Int) -> ChunkPeriod {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        switch chunkGranularity(for: interval) {
        case .daily: return dailyChunk(date)
        case .weekly: return weeklyChunk(date)
        case .monthly: return monthlyChunk(date)
        }
    }

    /// Returns all chunk periods that overlap [startMs, endMs).
    static func chunksForRange(interval: CandleInterval, startMs: Int, endMs: Int) -> [ChunkPeriod] {
        guard startMs < endMs else { return [] }
        var chunks: [ChunkPeriod] = []
        var cursor = startMs
        while cursor < endMs {
            let cp = chunkForTime(interval: interval, ms: cursor)
            chunks.append(cp)
            cursor = cp.endMs
        }
        return chunks
    }

    /// Constructs the CDN URL for a chunk file.
    static func chunkUrl(baseUrl: String, coin: String, interval: CandleInterval, chunkKey: String) -> String {
        "\(baseUrl)/candles/\(coin)/\(interval.rawValue)/\(chunkKey).json"
    }

    /// Fetches candles from CDN for a time range, falling back to the REST API
    /// for chunks that return 404 (not yet published) or for open (current) chunks.
    ///
    /// Each chunk is fetched independently via a non-throwing task group so a
    /// failure in one chunk does not cancel sibling fetches. CancellationError
    /// is still propagated to the caller.
    public static func fetchCandlesFromCDN(
        baseUrl: String,
        coin: String,
        interval: CandleInterval,
        startMs: Int,
        endMs: Int,
        session: URLSession = .shared,
        logger: ArcaLogger = .disabled,
        apiFallback: @escaping @Sendable (_ startMs: Int, _ endMs: Int) async throws -> [Candle]
    ) async throws -> [Candle] {
        try Task.checkCancellation()

        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let chunks = chunksForRange(interval: interval, startMs: startMs, endMs: endMs)

        let results: [[Candle]] = await withTaskGroup(of: (Int, [Candle])?.self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return nil }

                    let isClosed = nowMs >= chunk.endMs
                    let metaBase: [String: String] = [
                        "coin": coin,
                        "interval": interval.rawValue,
                        "chunkKey": chunk.key,
                    ]

                    if !isClosed {
                        guard !Task.isCancelled else { return nil }
                        let s = max(chunk.startMs, startMs)
                        let e = min(chunk.endMs - 1, endMs)
                        do {
                            let candles = try await apiFallback(s, e)
                            return (index, candles)
                        } catch {
                            logger.warning("cdn",
                                           "open-chunk API fallback failed",
                                           error: error,
                                           metadata: metaBase)
                            return nil
                        }
                    }

                    let url = URL(string: chunkUrl(baseUrl: baseUrl, coin: coin, interval: interval, chunkKey: chunk.key))!
                    do {
                        let (data, response) = try await session.data(from: url)
                        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                            guard !Task.isCancelled else { return nil }
                            let s = max(chunk.startMs, startMs)
                            let e = min(chunk.endMs - 1, endMs)
                            logger.debug("cdn",
                                         "chunk 404, using API fallback",
                                         metadata: metaBase.merging(["url": url.absoluteString]) { a, _ in a })
                            do {
                                let candles = try await apiFallback(s, e)
                                return (index, candles)
                            } catch {
                                logger.warning("cdn",
                                               "API fallback for 404 chunk failed",
                                               error: error,
                                               metadata: metaBase)
                                return nil
                            }
                        }
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            guard !Task.isCancelled else { return nil }
                            let s = max(chunk.startMs, startMs)
                            let e = min(chunk.endMs - 1, endMs)
                            logger.warning("cdn",
                                           "chunk non-OK status, using API fallback",
                                           metadata: metaBase.merging([
                                               "statusCode": String(http.statusCode),
                                               "url": url.absoluteString,
                                           ]) { a, _ in a })
                            do {
                                let candles = try await apiFallback(s, e)
                                return (index, candles)
                            } catch {
                                logger.warning("cdn",
                                               "API fallback for failing chunk failed",
                                               error: error,
                                               metadata: metaBase)
                                return nil
                            }
                        }
                        let candles = try JSONDecoder().decode([Candle].self, from: data)
                        let filtered = candles.filter { $0.t >= startMs && $0.t < endMs }
                        return (index, filtered)
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        let s = max(chunk.startMs, startMs)
                        let e = min(chunk.endMs - 1, endMs)
                        logger.warning("cdn",
                                       "chunk fetch failed, using API fallback",
                                       error: error,
                                       metadata: metaBase.merging(["url": url.absoluteString]) { a, _ in a })
                        do {
                            let candles = try await apiFallback(s, e)
                            return (index, candles)
                        } catch {
                            logger.warning("cdn",
                                           "API fallback after chunk fetch failure also failed",
                                           error: error,
                                           metadata: metaBase)
                            return nil
                        }
                    }
                }
            }

            var ordered = [(Int, [Candle])]()
            for await result in group {
                guard let result else { continue }
                ordered.append(result)
            }
            ordered.sort { $0.0 < $1.0 }
            return ordered.map { $0.1 }
        }

        try Task.checkCancellation()

        var merged: [Candle] = []
        for batch in results {
            merged.append(contentsOf: batch)
        }
        merged.sort { $0.t < $1.t }

        var deduped: [Candle] = []
        for candle in merged {
            if let last = deduped.last, last.t == candle.t {
                deduped[deduped.count - 1] = candle
            } else {
                deduped.append(candle)
            }
        }
        return deduped
    }
}

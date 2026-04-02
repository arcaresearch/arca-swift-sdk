import XCTest
@testable import ArcaSDK

final class HistoryCacheTests: XCTestCase {

    func testCacheMissReturnsNil() {
        let cache = HistoryCache()
        let result: String? = cache.get("missing")
        XCTAssertNil(result)
    }

    func testStoreAndRetrieve() {
        let cache = HistoryCache()
        cache.set("key1", value: "hello")
        let result: String? = cache.get("key1")
        XCTAssertEqual(result, "hello")
    }

    func testEvictsLeastRecentlyUsed() {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 3))
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        cache.set("c", value: 3)
        XCTAssertEqual(cache.size, 3)

        cache.set("d", value: 4)
        XCTAssertEqual(cache.size, 3)

        let evicted: Int? = cache.get("a")
        XCTAssertNil(evicted)
        let b: Int? = cache.get("b")
        XCTAssertEqual(b, 2)
        let c: Int? = cache.get("c")
        XCTAssertEqual(c, 3)
        let d: Int? = cache.get("d")
        XCTAssertEqual(d, 4)
    }

    func testAccessPromotesEntry() {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 3))
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        cache.set("c", value: 3)

        let _: Int? = cache.get("a")

        cache.set("d", value: 4)
        let a: Int? = cache.get("a")
        XCTAssertEqual(a, 1, "Accessed entry should not be evicted")
        let b: Int? = cache.get("b")
        XCTAssertNil(b, "Oldest untouched entry should be evicted")
    }

    func testUpdateExistingKeyDoesNotGrow() {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 2))
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        cache.set("a", value: 10)

        XCTAssertEqual(cache.size, 2)
        let a: Int? = cache.get("a")
        XCTAssertEqual(a, 10)
    }

    func testClear() {
        let cache = HistoryCache()
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        XCTAssertEqual(cache.size, 2)

        cache.clear()
        XCTAssertEqual(cache.size, 0)
        let a: Int? = cache.get("a")
        XCTAssertNil(a)
    }

    func testDisabledCacheIsNoop() {
        let cache = HistoryCache(config: .disabled)
        cache.set("a", value: 1)
        XCTAssertEqual(cache.size, 0)
        let a: Int? = cache.get("a")
        XCTAssertNil(a)
    }

    func testZeroMaxEntriesIsNoop() {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 0))
        cache.set("a", value: 1)
        XCTAssertEqual(cache.size, 0)
    }

    func testDefaultMaxEntries() {
        let cache = HistoryCache()
        for i in 0..<55 {
            cache.set("key-\(i)", value: i)
        }
        XCTAssertEqual(cache.size, 50)

        let evicted: Int? = cache.get("key-0")
        XCTAssertNil(evicted)
        let kept: Int? = cache.get("key-54")
        XCTAssertEqual(kept, 54)
    }

    func testConcurrentAccess() async {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 100))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    cache.set("key-\(i)", value: i)
                    let _: Int? = cache.get("key-\(i)")
                }
            }
        }
        XCTAssertEqual(cache.size, 50)
    }
}

final class BuildCacheKeyTests: XCTestCase {

    func testDeterministicWithSortedParams() {
        let key = buildCacheKey("equityHistory", [
            "to": "2026-03-24",
            "from": "2026-01-01",
            "prefix": "/accounts",
            "points": "200",
        ])
        XCTAssertEqual(key, "equityHistory:from=2026-01-01&points=200&prefix=/accounts&to=2026-03-24")
    }

    func testOmitsNilValues() {
        let key = buildCacheKey("candles", [
            "coin": "BTC",
            "interval": "1h",
            "startTime": nil,
            "endTime": nil,
        ])
        XCTAssertEqual(key, "candles:coin=BTC&interval=1h")
    }

    func testDifferentParamsProduceDifferentKeys() {
        let k1 = buildCacheKey("candles", ["coin": "BTC", "interval": "1h"])
        let k2 = buildCacheKey("candles", ["coin": "BTC", "interval": "4h"])
        XCTAssertNotEqual(k1, k2)
    }
}

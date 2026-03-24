import XCTest
@testable import ArcaSDK

final class HistoryCacheTests: XCTestCase {

    func testCacheMissReturnsNil() async {
        let cache = HistoryCache()
        let result: String? = await cache.get("missing")
        XCTAssertNil(result)
    }

    func testStoreAndRetrieve() async {
        let cache = HistoryCache()
        await cache.set("key1", value: "hello")
        let result: String? = await cache.get("key1")
        XCTAssertEqual(result, "hello")
    }

    func testEvictsLeastRecentlyUsed() async {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 3))
        await cache.set("a", value: 1)
        await cache.set("b", value: 2)
        await cache.set("c", value: 3)
        let size = await cache.size
        XCTAssertEqual(size, 3)

        await cache.set("d", value: 4)
        let sizeAfter = await cache.size
        XCTAssertEqual(sizeAfter, 3)

        let evicted: Int? = await cache.get("a")
        XCTAssertNil(evicted)
        let b: Int? = await cache.get("b")
        XCTAssertEqual(b, 2)
        let c: Int? = await cache.get("c")
        XCTAssertEqual(c, 3)
        let d: Int? = await cache.get("d")
        XCTAssertEqual(d, 4)
    }

    func testAccessPromotesEntry() async {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 3))
        await cache.set("a", value: 1)
        await cache.set("b", value: 2)
        await cache.set("c", value: 3)

        let _: Int? = await cache.get("a")

        await cache.set("d", value: 4)
        let a: Int? = await cache.get("a")
        XCTAssertEqual(a, 1, "Accessed entry should not be evicted")
        let b: Int? = await cache.get("b")
        XCTAssertNil(b, "Oldest untouched entry should be evicted")
    }

    func testUpdateExistingKeyDoesNotGrow() async {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 2))
        await cache.set("a", value: 1)
        await cache.set("b", value: 2)
        await cache.set("a", value: 10)

        let size = await cache.size
        XCTAssertEqual(size, 2)
        let a: Int? = await cache.get("a")
        XCTAssertEqual(a, 10)
    }

    func testClear() async {
        let cache = HistoryCache()
        await cache.set("a", value: 1)
        await cache.set("b", value: 2)
        let sizeBefore = await cache.size
        XCTAssertEqual(sizeBefore, 2)

        await cache.clear()
        let sizeAfter = await cache.size
        XCTAssertEqual(sizeAfter, 0)
        let a: Int? = await cache.get("a")
        XCTAssertNil(a)
    }

    func testDisabledCacheIsNoop() async {
        let cache = HistoryCache(config: .disabled)
        await cache.set("a", value: 1)
        let size = await cache.size
        XCTAssertEqual(size, 0)
        let a: Int? = await cache.get("a")
        XCTAssertNil(a)
    }

    func testZeroMaxEntriesIsNoop() async {
        let cache = HistoryCache(config: CacheConfig(maxEntries: 0))
        await cache.set("a", value: 1)
        let size = await cache.size
        XCTAssertEqual(size, 0)
    }

    func testDefaultMaxEntries() async {
        let cache = HistoryCache()
        for i in 0..<55 {
            await cache.set("key-\(i)", value: i)
        }
        let size = await cache.size
        XCTAssertEqual(size, 50)

        let evicted: Int? = await cache.get("key-0")
        XCTAssertNil(evicted)
        let kept: Int? = await cache.get("key-54")
        XCTAssertEqual(kept, 54)
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

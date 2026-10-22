import Foundation
import Testing
@testable import Atgeo

/// A settable clock for the TTL caches. Lock-guarded because the clock closure is @Sendable.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 0)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(milliseconds: Double) { lock.withLock { current += milliseconds / 1000 } }
    var closure: @Sendable () -> Date { { [unowned self] in self.now } }
}

private func rec(_ origin: String) -> TileRecord { TileRecord(value: ["origin": .string(origin)]) }

/// Unit level; the cache.test.ts port, which drives the client, comes in step 8. The reference has no
/// eviction test at all (design review, note 13), so this is the only check of contract §10's LRU rules.
@Suite struct CacheTests {
    @Test func ttlIsFreshUntilJustBeforeAnHourAndAMissFromThatInstant() {
        let clock = TestClock()
        var cache = TtlCache<Int>(ttl: 3600, now: clock.closure)
        cache.set("k", 1)
        #expect(cache.get("k") == 1)
        clock.advance(milliseconds: 3_599_999)
        #expect(cache.get("k") == 1)
        clock.advance(milliseconds: 1)
        #expect(cache.get("k") == nil)
        cache.set("k", 2)
        #expect(cache.get("k") == 2)
    }

    @Test func ttlKeysAreOrdinal() {
        var cache = TtlCache<Int>(ttl: 3600, now: { Date(timeIntervalSinceReferenceDate: 0) })
        cache.set("d\u{E9}|p|0,0,1,1", 1)
        #expect(cache.get("de\u{301}|p|0,0,1,1") == nil)
    }

    @Test func evictsLeastRecentlyUsedFirstAfterReads() {
        var cache = TileCache(budget: 30)
        cache.set("a", records: [], size: 10)
        cache.set("b", records: [], size: 10)
        cache.set("c", records: [], size: 10)
        _ = cache.get("a")
        cache.set("d", records: [], size: 10)
        #expect(cache.urls == ["c", "a", "d"])
        #expect(cache.total == 30)
        #expect(cache.get("b") == nil)
    }

    @Test func replacingSubtractsTheOldSize() {
        var cache = TileCache(budget: 30)
        cache.set("a", records: [], size: 10)
        cache.set("b", records: [], size: 10)
        cache.set("a", records: [rec("x")], size: 15)
        #expect(cache.total == 25)
        #expect(cache.urls == ["b", "a"])
        #expect(cache.get("a") == [rec("x")])
    }

    @Test func aTileLargerThanTheBudgetEvictsEverythingAndItself() {
        var cache = TileCache(budget: 30)
        cache.set("a", records: [], size: 10)
        cache.set("big", records: [], size: 31)
        #expect(cache.urls.isEmpty)
        #expect(cache.total == 0)
    }

    @Test func aTileExactlyAtTheBudgetStays() {
        var cache = TileCache(budget: 30)
        cache.set("a", records: [], size: 10)
        cache.set("b", records: [], size: 30)
        #expect(cache.urls == ["b"])
    }

    @Test func findTakesTheLowestURLByCodeUnitsWithoutTouchingRecency() {
        // "\u{FF61}" sorts before "\u{10000}" by String's <, after it by UTF-16 code units.
        let low = "https://t/\u{10000}", high = "https://t/\u{FF61}"
        #expect(high < low && ordinalLess(low, high))
        var cache = TileCache(budget: 100)
        cache.set(high, records: [rec("o"), rec("p")], size: 1)
        cache.set(low, records: [TileRecord(value: ["n": .number(1)]), TileRecord(value: ["origin": .string("o"), "n": .number(2)])], size: 1)
        cache.set("https://t/z", records: [], size: 1)
        #expect(cache.find(key: "o")?.value["n"] == .number(2))
        #expect(cache.find(key: "p") == rec("p"))
        #expect(cache.find(key: "q") == nil)
        #expect(cache.urls == [high, low, "https://t/z"])
    }

    @Test func findComparesKeysByCodeUnitsAndFallsBackToUri() {
        var cache = TileCache(budget: 100)
        cache.set("u", records: [rec("urn:\u{E9}"), TileRecord(value: [:], uri: "urn:v")], size: 1)
        #expect(cache.find(key: "urn:e\u{301}") == nil)
        #expect(cache.find(key: "urn:\u{E9}") == rec("urn:\u{E9}"))
        #expect(cache.find(key: "urn:v")?.uri == "urn:v")
    }

    @Test func urlsAreKeyedAsServed() {
        var cache = TileCache(budget: 100)
        cache.set("https://t/\u{E9}", records: [], size: 1)
        #expect(cache.get("https://t/e\u{301}") == nil)
        #expect(cache.get("https://t/\u{E9}") == [])
    }
}

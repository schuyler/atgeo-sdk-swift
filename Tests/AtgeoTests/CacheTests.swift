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

// MARK: - Port of test/cache.test.ts, through the client

private let sfRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
private let otherOrigin = "urn:atgeo:example.org:thing:shared"
/// 2026-01-01T00:00:00Z, as the reference sets its fake timers.
private let start = Date(timeIntervalSince1970: 1_767_225_600)

private func cacheSetup() throws -> FakeServer {
    try FakeServer(tilesets: [
        overture([FakeTile(url: tileURL("a"), records: [
            record(place("a", "Alpha", [point(37.772, -122.412)]), importance: 3),
            record(place("shared", "Shared in A", [point(37.773, -122.413)]), importance: 2),
        ])]),
        FakeTileset(
            slug: "example-thing",
            collections: [["dataset": .string("example.org"), "collection": .string("thing")]],
            tiles: [FakeTile(url: tileURL("o"), records: [
                record(place("shared", "Shared in other", [point(10, 10)], ["origin": .string(otherOrigin)])),
            ])]),
    ])
}

@Suite("warm regions") struct WarmRegions {
    @Test("answers an identical second search offline")
    func offline() async throws {
        let server = try cacheSetup()
        let client = server.client()
        let first = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", text: "Alpha", collection: "place")
        server.goOffline()
        let second = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", text: "Alpha", collection: "place")
        #expect(second == first)
        #expect(first.places.count > 0)
    }

    @Test("reuses tiles for a different text over the same region")
    func differentText() async throws {
        let server = try cacheSetup()
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        let before = server.requests.count
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", text: "Alpha", collection: "place")
        #expect(server.requests.count == before)
    }

    @Test("makes no tile request for a repeated search")
    func repeated() async throws {
        let server = try cacheSetup()
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requestStrings.filter { $0 == tileURL("a") }.count == 1)
    }
}

@Suite("tile-list expiry") struct TileListExpiry {
    @Test("expires after 3600 s and then requires network")
    func expires() async throws {
        let clock = TestClock(start)
        let server = try cacheSetup()
        let client = server.client(now: clock.closure)
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        let base = server.requests.count
        clock.advance(milliseconds: 3_599_000)
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requests.count == base)
        clock.advance(milliseconds: 2_000)
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.getTilesRequests.count == 2)
        #expect(server.requestStrings.filter { $0 == tileURL("a") }.count == 1)
    }

    @Test("fails offline once the tile list has expired")
    func failsOffline() async throws {
        let clock = TestClock(start)
        let server = try cacheSetup()
        let client = server.client(now: clock.closure)
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        server.goOffline()
        clock.advance(milliseconds: 3_601_000)
        await #expect(throws: (any Error).self) { _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place") }
    }

    @Test("caches describeService for 3600 s")
    func describeService() async throws {
        let clock = TestClock(start)
        let server = try cacheSetup()
        let client = server.client(now: clock.closure)
        _ = try await client.describeService()
        clock.advance(milliseconds: 3_599_000)
        _ = try await client.describeService()
        #expect(server.requests.count == 1)
        clock.advance(milliseconds: 2_000)
        _ = try await client.describeService()
        #expect(server.requests.count == 2)
    }
}

@Suite("place(origin:) cache scan") struct PlaceCacheScan {
    @Test("answers from an already-fetched tile without a request")
    func fromTile() async throws {
        let server = try cacheSetup()
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        let before = server.requests.count
        let found = try await client.place(origin: placeOrigin("a"))
        #expect(server.requests.count == before)
        #expect(found == PlaceRecord(origin: placeOrigin("a"), place: place("a", "Alpha", [point(37.772, -122.412)]), importance: 3))
    }

    @Test("answers offline for a cached origin")
    func offline() async throws {
        let server = try cacheSetup()
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        server.goOffline()
        #expect(try await client.place(origin: placeOrigin("shared")).place["name"] == .string("Shared in A"))
    }

    @Test("matches the whole origin, not a shared id")
    func wholeOrigin() async throws {
        let server = try cacheSetup()
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        let before = server.requests.count
        let found = try await client.place(origin: otherOrigin)
        let getPlaces = server.requests.dropFirst(before).filter { $0.path == "/xrpc/org.atgeo.getPlace" }
        #expect(getPlaces.count == 1)
        #expect(param(try #require(getPlaces.first), "uri") == otherOrigin)
        #expect(found.place["name"] == .string("Shared in other"))
    }

    @Test("returns the copy from the lowest tile URL, although a higher one was cached first")
    func lowestURL() async throws {
        let copy = { (name: String) in record(place("x", name, [point(37.775, -122.415)])) }
        let server = try FakeServer(
            tilesets: [overture([FakeTile(url: tileURL("a"), records: [copy("Copy A")]), FakeTile(url: tileURL("b"), records: [copy("Copy B")])])],
            tilesFor: { bbox in .tiles([bbox.hasPrefix("-122") ? tileURL("a") : tileURL("b")]) })
        let client = server.client()
        _ = try await client.searchPlaces(region: .bbox(west: -100.5, south: 10.5, east: -100.4, north: 10.6), dataset: "overturemaps.org", collection: "place")
        #expect(try await client.place(origin: placeOrigin("x")).place["name"] == .string("Copy B"))
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        server.goOffline()
        #expect(try await client.place(origin: placeOrigin("x")).place["name"] == .string("Copy A"))
    }
}

@Suite("cache budget through the client") struct CacheBudget {
    // No reference counterpart (design review, note 13): the budget is measured in response bytes, and a search
    // over more tiles than fit evicts the least recently used.
    @Test func aSmallBudgetEvictsAndTheEvictedTileIsFetchedAgain() async throws {
        let server = try FakeServer(tilesets: [overture([
            FakeTile(url: tileURL("a"), records: [record(place("a", "A", [point(37.772, -122.412)]))]),
            FakeTile(url: tileURL("b"), records: [record(place("b", "B", [point(37.773, -122.413)]))]),
        ])])
        let tileA = try await server.get(URL(string: tileURL("a"))!).body.count
        let tileB = try await server.get(URL(string: tileURL("b"))!).body.count
        // Room for one tile, not two.
        let budget = max(tileA, tileB) + 10
        #expect(tileA + tileB > budget)
        let client = server.client(cacheBudgetBytes: budget)
        let tiles = { server.requestStrings.filter { $0.hasPrefix("https://tiles.example/") }.count }
        let before = tiles()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(tiles() - before == 2)
        // a and b arrive in either order, so which one survives varies; exactly one does. The second search finds
        // it and fetches the other: not zero (nothing evicted) and not two (everything evicted).
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(tiles() - before == 3)
    }
}

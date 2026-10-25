import Foundation
import Testing
@testable import Atgeo

// The tile cache holds bodies and memoizes the parsed records of the latest search's tiles (contract §10).
// The memo may save parsing and nothing else: what is fetched, and when, the recency order and every result
// must be exactly as without it.

private let center = (lat: 37.775, lon: -122.415)

/// Four tiles of three records, all near `center`, so that every region below holds every record. Tiles m1
/// and m2 share an origin, so dedupe and the getPlace scan have a winner to pick.
private func memoTiles() -> [FakeTile] {
    (0..<4).map { t in
        FakeTile(url: tileURL("m\(t)"), records: (0..<3).map { r in
            let id = t == 2 && r == 0 ? "p1-0" : "p\(t)-\(r)"
            let names = ["Alpha Cafe", "Alpine Deli", "Beta Books"]
            return record(
                place(id, "\(names[r]) \(t)", [point(center.lat + Double(t) * 0.0004, center.lon + Double(r) * 0.0004)]),
                importance: Int64(t * 3 + r))
        })
    }
}

/// Circles of different radii snap to different boxes, each with its own tile list. Each list adds at most one
/// tile to the one before, so the steps below can fetch one tile at a time: with several in flight, the order
/// they finish in, and so the recency order, would be the scheduler's choice, memo or not.
private let regions: [(region: Region, tiles: [Int])] = [
    (.circle(lat: center.lat, lon: center.lon, radius: 300), [0]),
    (.circle(lat: center.lat, lon: center.lon, radius: 3_000), [0, 1]),
    (.circle(lat: center.lat, lon: center.lon, radius: 30_000), [1, 2]),
    (.circle(lat: center.lat, lon: center.lon, radius: 300_000), [2, 3]),
]

private func memoServer() throws -> FakeServer {
    let lists = Dictionary(uniqueKeysWithValues: regions.map { r in
        (queryBboxes(r.region)[0], r.tiles.map { tileURL("m\($0)") })
    })
    #expect(lists.count == regions.count)
    return try FakeServer(tilesets: [overture(memoTiles())], tilesFor: { bbox in .tiles(lists[bbox] ?? []) })
}

private func client(_ server: FakeServer, budget: Int, memoize: Bool) -> AtgeoClient {
    AtgeoClient(server: URL(string: server.server)!, transport: server, cacheBudgetBytes: budget, now: { Date() },
                memoize: memoize)
}

/// Room for three of the four tiles, so the steps below evict.
private func threeTileBudget() async throws -> Int {
    let sizer = try memoServer()
    var sizes: [Int] = []
    for t in 0..<4 { sizes.append(try await sizer.get(URL(string: tileURL("m\(t)"))!).body.count) }
    #expect(sizes.min()! * 4 > sizes.max()! * 3)
    return sizes.max()! * 3
}

private enum Step {
    case search(Int, String?, SortMode)
    case place(String)
}

/// The cache, least recently used first, is noted after the steps that change it.
private let steps: [Step] = [
    .search(0, nil, .fused),                                              // m0
    .search(1, "a", .fused), .search(1, "al", .similarity),               // m0 m1
    .search(2, "alp", .distance),                                         // m0 m1 m2
    .place(placeOrigin("p0-1")), .place(placeOrigin("p1-0")),             // from m0, parsed; from m1, memoized
    .search(3, "alpha", .fused), .search(3, "alpine", .fused),            // m1 m2 m3
    // m1 is read before m0 arrives, so recency is out of URL order; reading both again from the memo must
    // reorder them, as reading them unmemoized does.
    .search(1, "alpha", .fused),                                          // m3 m1 m0
    .search(1, "alpine", .fused),                                         // m3 m0 m1
    .search(0, nil, .distance),                                           // m3 m1 m0
    .place(placeOrigin("p1-0")), .place(placeOrigin("p2-1")),             // from m1, parsed; getPlace, m2 is gone
    .search(1, "beta", .fused), .search(1, "cafe", .similarity),          // m3 m0 m1
    .place(placeOrigin("p3-2")),                                          // from m3, parsed
    .search(2, nil, .fused), .search(2, "alpha cafe 2", .similarity),     // m0 m1 m2
    .search(1, "alpha cafe", .fused),                                     // m2 m0 m1
]

@Suite("tile memo") struct TileMemo {
    @Test("changes no request, no result and no recency, step by step")
    func differential() async throws {
        let budget = try await threeTileBudget()
        let plainServer = try memoServer(), memoServer = try memoServer()
        let plain = client(plainServer, budget: budget, memoize: false)
        let memo = client(memoServer, budget: budget, memoize: true)
        var tileRequests = 0
        for (i, step) in steps.enumerated() {
            switch step {
            case let .search(r, text, sort):
                let a = try await plain.searchPlaces(region: regions[r].region, dataset: "overturemaps.org", text: text, collection: "place", sort: sort)
                let b = try await memo.searchPlaces(region: regions[r].region, dataset: "overturemaps.org", text: text, collection: "place", sort: sort)
                #expect(a == b, "step \(i)")
                // Every record is in every region; m1 and m2 share one origin. Text drops what scores below 0.6.
                let all = 3 * regions[r].tiles.count - (regions[r].tiles == [1, 2] ? 1 : 0)
                #expect(text == nil ? a.places.count == all : !a.places.isEmpty, "step \(i)")
            case let .place(origin):
                let a = try await plain.place(origin: origin)
                let b = try await memo.place(origin: origin)
                #expect(a == b, "step \(i)")
            }
            #expect(plainServer.requestStrings == memoServer.requestStrings, "step \(i)")
            #expect(await plain.cachedTileURLs == memo.cachedTileURLs, "step \(i)")
            // The precondition that makes request order and recency deterministic.
            let fetched = memoServer.requestStrings.filter { $0.hasPrefix("https://tiles.example/") }.count
            #expect(fetched - tileRequests <= 1, "step \(i) fetched more than one tile")
            tileRequests = fetched
        }
        // Not vacuous: tiles were evicted and fetched again, getPlace went to the server once, and the memo
        // saved parses.
        #expect(await memo.cachedTileURLs == ["m2", "m0", "m1"].map(tileURL))
        #expect(memoServer.requestStrings.filter { $0.hasPrefix("https://tiles.example/") }
            == ["m0", "m1", "m2", "m3", "m0", "m2"].map(tileURL))
        #expect(memoServer.requestStrings.filter { $0.contains("getPlace") }.count == 1)
        #expect(await memo.tileParses < plain.tileParses)
    }

    @Test("parses nothing when the same region is searched with new text")
    func typing() async throws {
        let server = try memoServer()
        let client = server.client()
        let first = try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", text: "a", collection: "place")
        let parses = await client.tileParses
        #expect(parses == 2)
        let requests = server.requests.count
        for text in ["al", "alp", "alph", "alpha"] {
            _ = try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", text: text, collection: "place")
        }
        #expect(await client.tileParses == parses)
        #expect(server.requests.count == requests)
        #expect(await Set(client.memoizedTileURLs) == Set(["m0", "m1"].map(tileURL)))
        #expect(try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", text: "a", collection: "place") == first)
    }

    @Test("parses an older search's tiles again from the cache, without a request")
    func olderSearch() async throws {
        let server = try memoServer()
        let client = server.client()
        let first = try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", text: "alpha", collection: "place")
        _ = try await client.searchPlaces(region: regions[2].region, dataset: "overturemaps.org", text: "alpha", collection: "place")
        // Tile m1 is in both regions, so it stayed memoized; m0 is parsed again.
        #expect(await Set(client.memoizedTileURLs) == Set(["m1", "m2"].map(tileURL)))
        let parses = await client.tileParses, requests = server.requests.count
        #expect(try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", text: "alpha", collection: "place") == first)
        #expect(await client.tileParses == parses + 1)
        #expect(server.requests.count == requests)
        #expect(await Set(client.memoizedTileURLs) == Set(["m0", "m1"].map(tileURL)))
    }

    @Test("place(origin:) leaves recency alone, memoized or parsed")
    func placeRecency() async throws {
        let server = try memoServer()
        let client = server.client()
        _ = try await client.searchPlaces(region: regions[1].region, dataset: "overturemaps.org", collection: "place")
        _ = try await client.searchPlaces(region: regions[3].region, dataset: "overturemaps.org", collection: "place")
        let order = await client.cachedTileURLs
        let parses = await client.tileParses
        // p0-0 is only in m0, which the second search left unmemoized; p1-0 is in m1 and m2, and m1 is lower.
        #expect(try await client.place(origin: placeOrigin("p0-0")).place["name"] == .string("Alpha Cafe 0"))
        #expect(try await client.place(origin: placeOrigin("p1-0")).place["name"] == .string("Alpha Cafe 1"))
        #expect(await client.tileParses == parses + 2)
        // From the memo, without parsing.
        #expect(try await client.place(origin: placeOrigin("p3-0")).place["name"] == .string("Alpha Cafe 3"))
        #expect(await client.tileParses == parses + 2)
        #expect(await client.cachedTileURLs == order)
        #expect(!server.requestStrings.contains { $0.contains("getPlace") })
    }
}

@Suite("tile cache memo") struct TileCacheMemo {
    private func body(_ origins: [String]) -> (body: Data, records: [PreparedRecord], keys: Set<Int>) {
        let data = try! JSONEncoder().encode(JSONValue.object([
            "records": .array(origins.map { wire(TileRecord(value: ["origin": .string($0)])) }),
        ]))
        let (records, keys) = try! parseTile(data)
        return (data, records, keys)
    }

    @Test("serves memoized records only for the entry they were parsed from")
    func generations() {
        var cache = TileCache(budget: 100)
        let a = body(["x"]), b = body(["y"])
        let first = cache.insert("a", body: a.body, keys: a.keys, size: 10)
        #expect(cache.read("a")?.records == nil)
        cache.keepParsed([("a", first, a.records)])
        #expect(cache.read("a")?.records == a.records)
        // Replacing the URL drops the memo, and records from the old entry are refused.
        let second = cache.insert("a", body: b.body, keys: b.keys, size: 10)
        #expect(cache.read("a")?.records == nil)
        cache.keepParsed([("a", first, a.records)])
        #expect(cache.read("a")?.records == nil)
        cache.keepParsed([("a", second, b.records)])
        #expect(cache.read("a")?.records == b.records)
    }

    @Test("drops a tile's memo when the tile is evicted, and keeps only the latest search's")
    func eviction() {
        var cache = TileCache(budget: 20)
        let a = body(["x"]), b = body(["y"]), c = body(["z"])
        let ga = cache.insert("a", body: a.body, keys: a.keys, size: 10)
        let gb = cache.insert("b", body: b.body, keys: b.keys, size: 10)
        cache.keepParsed([("a", ga, a.records), ("b", gb, b.records)])
        #expect(cache.memoized == ["a", "b"])
        let gc = cache.insert("c", body: c.body, keys: c.keys, size: 10)
        #expect(cache.memoized == ["b"])
        // An evicted tile is not memoized again.
        cache.keepParsed([("a", ga, a.records), ("c", gc, c.records)])
        #expect(cache.memoized == ["c"])
        #expect(cache.urls == ["b", "c"])
    }

    @Test("memoizes nothing when the memo is off")
    func off() {
        var cache = TileCache(budget: 20, memoize: false)
        let a = body(["x"])
        let g = cache.insert("a", body: a.body, keys: a.keys, size: 10)
        cache.keepParsed([("a", g, a.records)])
        #expect(cache.memoized.isEmpty)
        #expect(cache.read("a")?.records == nil)
    }

    @Test("lists every candidate tile for a key, lowest URL first, without touching recency")
    func lookup() {
        var cache = TileCache(budget: 100)
        for (url, origins) in [("c", ["k"]), ("a", ["j", "k"]), ("b", ["j"])] {
            let t = body(origins)
            cache.insert(url, body: t.body, keys: t.keys, size: 1)
        }
        #expect(cache.lookup(key: "k").map(\.body) == [body(["j", "k"]).body, body(["k"]).body])
        #expect(cache.lookup(key: "q").isEmpty)
        #expect(cache.urls == ["c", "a", "b"])
    }
}

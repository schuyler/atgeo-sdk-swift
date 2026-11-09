import Foundation
import Testing
@testable import Atgeo

// Port of test/keyword.test.ts, keywordRegions.test.ts, qualifying.test.ts, disclosed.test.ts and the
// already-aborted tests of transport.test.ts (contract §4.11, §11, §12 items 6 and 9, §16, §17).

private let dataset = "overturemaps.org"
private let division = "urn:atgeo:overturemaps.org:division:d1"

private let keywordTilesets: [FakeTileset] = [
    overture([
        FakeTile(url: tileURL("p"), records: [
            record(place("starbucks-3", "Starbucks", [point(37.7, -122.4)]), importance: 5),
            record(place("starbucks-1", "Starbucks", [point(37.775, -122.418)], ["futureKey": .object(["a": .number(1)])]), importance: 5),
            record(place("starbucks-2", "Starbucks Reserve", [point(37.8, -122.3)]), importance: 9),
            record(place("mcd", "McDonald's", [point(37.78, -122.41)]), importance: 7),
        ]),
    ]),
    FakeTileset(
        slug: "overture-division",
        collections: [["dataset": .string(dataset), "collection": .string("division")]],
        tiles: [FakeTile(url: tileURL("d"), records: [
            record(place("d1", "Starbucks District", [point(37.9, -122.5)], ["origin": .string(division)]), importance: 1),
        ])]),
]

/// The query parameters of a request, percent-decoded.
func paramsOf(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? [] {
        out[item.name] = (item.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    return out
}

extension FakeServer {
    /// The searchPlaces requests, in order.
    var searchPlacesRequests: [URL] { requests.filter { $0.absoluteString.contains("org.atgeo.searchPlaces") } }
}

/// A nearby region around the Zanzibar Cafe of `zanzibarTiles`.
let zanzibarRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
let zanzibarTiles = [
    FakeTile(url: tileURL("p"), records: [record(place("zc", "Zanzibar Cafe", [point(37.772, -122.412)]), importance: 5)]),
]

@Suite("searchByKeyword") struct SearchByKeyword {
    func setup() throws -> (FakeServer, AtgeoClient) {
        let server = try FakeServer(tilesets: keywordTilesets)
        return (server, server.client())
    }

    @Test("returns the server's matches in the server's order, as keyword hits")
    func order() async throws {
        let (_, client) = try setup()
        let result = try await client.searchByKeyword(keyword: "starb", dataset: dataset, collection: "place")
        #expect(result.places.map(\.origin) == ["starbucks-2", "starbucks-1", "starbucks-3"].map { placeOrigin($0) })
        let hit = result.places[1]
        #expect(hit.via == .keyword)
        #expect(hit.name == "Starbucks")
        #expect(hit.importance == 5)
        #expect(hit.collection == CollectionKey(dataset: dataset, collection: "place"))
        #expect(hit.location == PlaceLocation(point: .init(lat: 37.775, lon: -122.418), bbox: nil))
        #expect(hit.place["futureKey"] == .object(["a": .number(1)]))
    }

    @Test("credits each hit's own collection and the union of the places' attribution")
    func attribution() async throws {
        let (_, client) = try setup()
        let result = try await client.searchByKeyword(keyword: "starb", dataset: dataset)
        #expect(result.places.map { $0.collection?.collection } == ["place", "place", "place", "division"])
        #expect(result.attribution == [Attribution(dataset: dataset, collection: "division"), Attribution(dataset: dataset, collection: "place")])
    }

    @Test("sends exactly dataset and q when given no collection or region")
    func exactParams() async throws {
        let (server, client) = try setup()
        let result = try await client.searchByKeyword(keyword: "Starb", dataset: dataset)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].absoluteString.contains("/xrpc/org.atgeo.searchPlaces?"))
        #expect(paramsOf(server.requests[0]) == ["dataset": dataset, "q": "Starb"])
        #expect(result.disclosed == Disclosure(keyword: true, region: nil))
    }

    @Test("sends the keyword exactly as passed, with the characters that need encoding")
    func keywordIsNotTouched() async throws {
        let (server, client) = try setup()
        let keyword = "  A+B & C=D#%e\u{301} 100%  "
        _ = try await client.searchByKeyword(keyword: keyword, dataset: dataset)
        #expect(paramsOf(server.requests[0])["q"].map { Array($0.utf16) } == Array(keyword.utf16))
    }

    @Test("sends the collection and the snapped region when given")
    func collectionAndRegion() async throws {
        let (server, client) = try setup()
        let region = KeywordRegion(west: -122.43, south: 37.77, east: -122.41, north: 37.78)
        let result = try await client.searchByKeyword(keyword: "Starb", dataset: dataset, collection: "place", region: region)
        #expect(server.requests.count == 1)
        #expect(paramsOf(server.requests[0]) == ["dataset": dataset, "collection": "place", "q": "Starb", "bbox": "-123,37,-122,38"])
        #expect(result.disclosed == Disclosure(keyword: true, region: 1))
    }

    @Test("sends a keyword the server cannot use and throws the server's KeywordRequired")
    func keywordRequired() async throws {
        let (server, client) = try setup()
        await #expect(throws: AtgeoError.self) { _ = try await client.searchByKeyword(keyword: "a", dataset: dataset) }
        do {
            _ = try await client.searchByKeyword(keyword: "a", dataset: dataset)
            Issue.record("expected a throw")
        } catch let error as AtgeoError {
            #expect(error.code == "KeywordRequired")
        }
        #expect(server.requests.count == 2)
    }

    @Test("does not cache: each call is one request, and nothing enters the tile caches")
    func notCached() async throws {
        let (server, client) = try setup()
        _ = try await client.searchByKeyword(keyword: "starb", dataset: dataset)
        _ = try await client.searchByKeyword(keyword: "starb", dataset: dataset)
        #expect(server.searchPlacesRequests.count == 2)
        #expect(await client.cachedTileURLs.isEmpty)
    }

    @Test("refuses a region that fails the bbox validation, with no request")
    func invalidRegion() async throws {
        let (server, client) = try setup()
        for region in [
            KeywordRegion(west: 0, south: 10, east: 1, north: 5), KeywordRegion(west: 181, south: 0, east: 0, north: 1),
            KeywordRegion(west: 0, south: -91, east: 1, north: 1), KeywordRegion(west: .nan, south: 0, east: 1, north: 1),
        ] {
            await #expect(throws: AtgeoArgumentError.invalidRegion("invalid bbox")) {
                _ = try await client.searchByKeyword(keyword: "ab", dataset: dataset, region: region)
            }
        }
        #expect(server.requests.isEmpty)
    }

    @Test("a body with no places array is a DecodingError")
    func noPlaces() async throws {
        let server = try FakeServer(rawBodies: ["https://places.atgeo.org/xrpc/org.atgeo.searchPlaces": HTTPResponse(status: 200, body: Data("{}".utf8))])
        await #expect(throws: DecodingError.self) { _ = try await server.client().searchByKeyword(keyword: "ab", dataset: dataset) }
    }
}

// Contract §11 (#59): a request whose caller already cancelled never reaches the transport, which may ignore
// cancellation. FakeServer ignores it, so it stands in for such a transport.
@Suite("an already-cancelled request") struct AlreadyCancelled {
    /// Runs `body` in a task that has cancelled itself first.
    private func cancelled<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
        Task {
            _ = withUnsafeCurrentTask { $0?.cancel() }
            return try await body()
        }
    }

    @Test("is not handed to the transport by searchByKeyword")
    func keyword() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        let task = cancelled { try await client.searchByKeyword(keyword: "Quokka", dataset: dataset) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test("is not handed to the transport by a cold searchNearby")
    func nearby() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        let task = cancelled { try await client.searchNearby(region: zanzibarRegion, dataset: dataset) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test("keeps the fallback's keyword off the wire when the caller cancelled before the keyword half")
    func fallback() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        // Warm the cache, so the nearby half is answered without a request and completes though the task is
        // cancelled (contract §11); the keyword half is then the first request made after the cancellation.
        _ = try await client.searchNearby(region: zanzibarRegion, dataset: dataset)
        let before = server.requests.count
        let task = cancelled {
            try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "Quokka", keywordRegion: .none)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.requests.count == before)
        #expect(server.searchPlacesRequests.isEmpty)
    }

    @Test("a fully cached search completes though cancelled")
    func cachedCompletes() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        _ = try await client.searchNearby(region: zanzibarRegion, dataset: dataset)
        let task = cancelled { try await client.searchNearby(region: zanzibarRegion, dataset: dataset) }
        #expect(try await task.value.places.count == 1)
    }
}

// fixtures/keyword-regions.json: the whole-degree bbox a keyword search sends for each input box. The fake
// refuses a bbox with decimals and one the real server would call invalid, so a case passes only if the server
// accepts what was sent, whatever the fixture's arithmetic says.
struct KeywordRegionCase: Sendable, CustomTestStringConvertible {
    var name: String
    var bbox: [Double]
    var sent: String
    var testDescription: String { name }
}

private func regionCases() throws -> [KeywordRegionCase] {
    try #require(try fixture("keyword-regions.json").arrayValue).map { c in
        KeywordRegionCase(
            name: try #require(c["name"]?.stringValue),
            bbox: try #require(c["bbox"]?.arrayValue).compactMap(\.doubleValue),
            sent: try #require(c["sent"]?.stringValue))
    }
}

@Suite("keyword regions") struct KeywordRegions {
    private func run(_ b: [Double]) async throws -> [URL] {
        let server = try FakeServer(tilesets: [overture([])])
        let region = KeywordRegion(west: b[0], south: b[1], east: b[2], north: b[3])
        _ = try await server.client().searchByKeyword(keyword: "Zanzibar", dataset: dataset, collection: "place", region: region)
        return server.requests
    }

    @Test func hasTheVendoredCases() throws {
        #expect(try regionCases().count == 72)
        #expect(try regionCases().allSatisfy { $0.bbox.count == 4 })
    }

    @Test("sends the case's bbox", arguments: try regionCases())
    func sends(_ c: KeywordRegionCase) async throws {
        let requests = try await run(c.bbox)
        #expect(requests.count == 1)
        #expect(paramsOf(requests[0])["bbox"] == c.sent)
        #expect(c.sent.wholeMatch(of: /(0|-?[1-9]\d*)(,(0|-?[1-9]\d*)){3}/) != nil)
    }

    @Test("keeps every digit of a precise box off the wire")
    func preciseBox() async throws {
        let requests = try await run([-122.4194155, 37.7749295, -122.4094155, 37.7849295])
        #expect(paramsOf(requests[0])["bbox"] == "-123,37,-122,38")
        #expect(requests[0].absoluteString.wholeMatch(of: /.*bbox=-?\d+%2C-?\d+%2C-?\d+%2C-?\d+/) != nil)
        for r in requests {
            for needle in ["7749295", "4194155", "4094155", "7849295"] { #expect(!r.absoluteString.contains(needle)) }
        }
    }

    @Test("never prints a negative zero or a fraction")
    func integers() {
        for region in [
            KeywordRegion(west: -0.0, south: -0.5, east: 0.0, north: 0.5), KeywordRegion(west: -0.2, south: -0.0, east: -0.0, north: 0),
        ] {
            let bbox = keywordBbox(region)
            #expect(bbox.wholeMatch(of: /(0|-?[1-9]\d*)(,(0|-?[1-9]\d*)){3}/) != nil, "\(bbox)")
        }
    }
}

// fixtures/qualifying-keywords.json: the qualifying predicate of contract §17.
struct QualifyingCase: Sendable, CustomTestStringConvertible {
    var name: String
    var keyword: String
    var qualifies: Bool
    var testDescription: String { name }
}

private func qualifyingCases() throws -> [QualifyingCase] {
    try #require(try fixture("qualifying-keywords.json").arrayValue).map { c in
        QualifyingCase(
            name: try #require(c["name"]?.stringValue), keyword: try #require(c["keyword"]?.stringValue),
            qualifies: try #require(c["qualifies"]?.boolValue))
    }
}

@Suite("qualifying keywords") struct QualifyingKeywords {
    @Test func hasTheVendoredCases() throws {
        #expect(try qualifyingCases().count == 23)
    }

    @Test("the predicate", arguments: try qualifyingCases())
    func predicate(_ c: QualifyingCase) {
        #expect(qualifies(c.keyword) == c.qualifies)
    }

    // Contract §17 and the Swift spec: the length is in Unicode scalars, not grapheme clusters.
    @Test func countsScalarsNotGraphemes() {
        #expect("e\u{301}".count == 1)
        // Two scalars in one grapheme: NFKD splits and `normalize` strips the accent, so one letter remains.
        #expect(!qualifies("\u{E9}"))
        // An emoji sequence is one grapheme and several scalars; it qualifies by scalar count.
        #expect(qualifies("\u{1F468}\u{200D}\u{1F469}"))
    }
}

// fixtures/match-tiers-lone-surrogates.json is vendored and not run: a Swift String cannot hold a lone surrogate,
// and the JSON parser reads a lone surrogate escape as U+FFFD, so the case cannot reach the tier function.
@Suite("lone surrogates") struct LoneSurrogates {
    @Test func theFixtureIsVendoredAndNotRun() throws {
        #expect(try fixture("match-tiers-lone-surrogates.json").arrayValue?.count == 4)
    }
}

// What each result reports the server learned during that call (contract §4.11, §12 item 9).
@Suite("disclosed") struct Disclosed {
    func setup() throws -> (FakeServer, AtgeoClient) {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        return (server, server.client())
    }

    @Test("is the 0.01 degree grid, no keyword, on a cold nearby search, whose hits come from tiles")
    func cold() async throws {
        let result = try await setup().1.searchNearby(region: zanzibarRegion, dataset: dataset, text: "Zanzibar", collection: "place")
        #expect(result.disclosed == Disclosure(keyword: false, region: 0.01))
        #expect(!result.places.isEmpty)
        #expect(result.places.allSatisfy { $0.via == .tiles })
    }

    @Test("reports no region for a nearby search answered from cache")
    func warm() async throws {
        let client = try setup().1
        _ = try await client.searchNearby(region: zanzibarRegion, dataset: dataset, collection: "place")
        let again = try await client.searchNearby(region: zanzibarRegion, dataset: dataset, text: "Zanzibar", collection: "place")
        #expect(again.disclosed == Disclosure(keyword: false, region: nil))
    }

    @Test("reports the keyword and a 1 degree region for a keyword search with a region, and none without")
    func keyword() async throws {
        let client = try setup().1
        let box = KeywordRegion(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
        #expect(try await client.searchByKeyword(keyword: "Zanzibar", dataset: dataset, region: box).disclosed == Disclosure(keyword: true, region: 1))
        #expect(try await client.searchByKeyword(keyword: "Zanzibar", dataset: dataset).disclosed == Disclosure(keyword: true, region: nil))
    }

    @Test("counts a getTiles request as sent even when it lists no tiles")
    func emptyList() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)], tilesFor: { _ in .tiles([]) })
        let result = try await server.client().searchNearby(region: zanzibarRegion, dataset: dataset)
        #expect(server.requests.count == 1)
        #expect(result.disclosed == Disclosure(keyword: false, region: 0.01))
    }

    @Test("counts a tile fetch that failed")
    func failedFetch() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)], failTiles: [tileURL("p")])
        let result = try await server.client().searchNearby(region: zanzibarRegion, dataset: dataset)
        #expect(result.tileFailures.map(\.kind) == [.status])
        #expect(result.disclosed == Disclosure(keyword: false, region: 0.01))
    }

    @Test("does not count a tile the client refused to fetch")
    func refused() async throws {
        // The tile list is cached by the first search, so the second sends nothing: its only tile is refused.
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)], tilesFor: { _ in .tiles(["ftp://tiles.example/p.json"]) })
        let client = server.client()
        let first = try await client.searchNearby(region: zanzibarRegion, dataset: dataset)
        #expect(first.disclosed == Disclosure(keyword: false, region: 0.01))
        let before = server.requests.count
        let again = try await client.searchNearby(region: zanzibarRegion, dataset: dataset)
        #expect(server.requests.count == before)
        #expect(again.tileFailures.map(\.kind) == [.refused])
        #expect(again.disclosed == Disclosure(keyword: false, region: nil))
    }
}

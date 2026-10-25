import Foundation
import Testing
@testable import Atgeo

// Port of test/attribution.test.ts: fixtures/attribution-scenarios.json, which pins SearchResult.attribution and
// SearchHit.collection (contract §4.10 and §8), and the same scenarios with tiles arriving in reverse URL order
// (contract §13). The tile bodies need not validate against the lexicons, so the server here is raw, not the
// validating fake.

struct AttributionScenario: Sendable, CustomTestStringConvertible {
    struct Tile: Sendable {
        var url: String
        var body: JSONValue?
        var status: Int?
    }
    var name: String
    var dataset: String
    var collection: String?
    var region: Region
    var tiles: [Tile]
    var attribution: [JSONValue]
    /// `(origin, collection)` of each expected hit; the collection is `.null` for a hit with none.
    var hits: [(origin: String?, collection: JSONValue)]
    var testDescription: String { name }
}

private let serverBase = "https://places.atgeo.org"
private let getTilesURL = "\(serverBase)/xrpc/org.atgeo.getTiles"

private func scenarios() throws -> [AttributionScenario] {
    try #require(try fixture("attribution-scenarios.json").arrayValue).map { s in
        let r = try #require(s["region"])
        let b = r["bbox"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        #expect(b.count == 4)
        return AttributionScenario(
            name: try #require(s["name"]?.stringValue),
            dataset: try #require(s["dataset"]?.stringValue),
            collection: s["collection"]?.stringValue,
            region: .bbox(west: b[0], south: b[1], east: b[2], north: b[3]),
            tiles: try #require(s["tiles"]?.arrayValue).map { t in
                .init(url: t["url"]?.stringValue ?? "", body: t["body"], status: t["status"].flatMap { int64($0) }.map(Int.init))
            },
            attribution: try #require(s["expect"]?["attribution"]?.arrayValue),
            hits: try #require(s["expect"]?["hits"]?.arrayValue).map { ($0["origin"]?.stringValue, $0["collection"] ?? .null) })
    }
}

/// The scenario's server (contract §13): every getTiles call, whatever its query, lists the scenario's tile URLs in
/// their listed order, which is deliberately not sorted; each tile URL is served exactly, with its body verbatim
/// and its status (default 200). A tile with a status and no body gets the default error body.
struct ScenarioServer: HTTPTransport {
    var scenario: AttributionScenario

    func get(_ url: URL) async throws -> HTTPResponse {
        let href = url.absoluteString
        if href == getTilesURL || href.hasPrefix("\(getTilesURL)?") {
            return HTTPResponse(status: 200, body: try encode(.object(["tiles": .array(scenario.tiles.map { .string($0.url) })])))
        }
        guard let tile = scenario.tiles.first(where: { $0.url == href }) else {
            return HTTPResponse(status: 404, body: Data("Not found".utf8))
        }
        let body = tile.body ?? .object(["error": .string("InternalServerError"), "message": .string("upstream error")])
        return HTTPResponse(status: tile.status ?? 200, body: try encode(body))
    }

    private func encode(_ v: JSONValue) throws -> Data { try JSONEncoder().encode(v) }
}

/// A fresh client per scenario: scenarios reuse tile URLs with different bodies, and the tile-list cache is keyed
/// by dataset, collection and bbox, so a shared client would serve one scenario's lists and tiles to the next.
private func search(_ s: AttributionScenario, transport: any HTTPTransport) async throws -> SearchResult {
    let client = AtgeoClient(server: URL(string: serverBase)!, transport: transport)
    return try await client.searchPlaces(region: s.region, dataset: s.dataset, collection: s.collection)
}

/// The attribution as the fixture writes it, in JSON terms: a field the entry lacks is a missing key.
private func jsonTerms(_ a: Attribution) throws -> JSONValue {
    try decodeJSON(JSONEncoder().encode(a))
}

private func check(_ result: SearchResult, against s: AttributionScenario) throws {
    #expect(try result.attribution.map(jsonTerms) == s.attribution)

    // The hits are compared as a multiset of (origin, collection) pairs, order-insensitive. Every hit's collection
    // is compared with strict equality, so a port that handed back the whole entry would fail; in Swift a hit's
    // `collection` is a `CollectionKey?` with the two fields only, always a property, nil for a null.
    func lengthPrefixed(_ s: String?) -> String { s.map { "\($0.utf16.count):\($0)" } ?? "nil" }
    func key(_ origin: String?, _ dataset: String?, _ collection: String?) -> String {
        [origin, dataset, collection].map(lengthPrefixed).joined(separator: "|")
    }
    func key(_ origin: String?, _ collection: JSONValue) -> String {
        if case .object(let o) = collection {
            #expect(o.keys.sorted() == ["collection", "dataset"])
            return key(origin, o["dataset"]?.stringValue, o["collection"]?.stringValue)
        }
        #expect(collection == .null)
        return key(origin, nil, nil)
    }
    // The encoded collection has exactly the two keys, which a type carrying more of the entry would fail.
    for hit in result.places {
        if let collection = hit.collection {
            #expect(try decodeJSON(JSONEncoder().encode(collection)).objectValue?.keys.sorted() == ["collection", "dataset"])
        }
    }
    let got = result.places.map { key($0.origin, $0.collection?.dataset, $0.collection?.collection) }
    #expect(got.sorted() == s.hits.map { key($0.origin, $0.collection) }.sorted())
}

@Suite("attribution scenarios") struct AttributionScenarios {
    @Test func hasTheScenariosTheContractDescribes() throws {
        #expect(try scenarios().count == 12)
    }

    @Test("the scenario", arguments: try scenarios())
    func scenario(_ s: AttributionScenario) async throws {
        try check(try await search(s, transport: ScenarioServer(scenario: s)), against: s)
    }

    @Test func aTileWithAStatusAndNoBodyGetsTheDefaultErrorBody() async throws {
        let s = AttributionScenario(
            name: "x", dataset: "x.org", collection: nil, region: .bbox(west: 0, south: 0, east: 1, north: 1),
            tiles: [.init(url: "https://places.atgeo.org/tiles/a.json", body: nil, status: 500)], attribution: [], hits: [])
        let response = try await ScenarioServer(scenario: s).get(URL(string: "https://places.atgeo.org/tiles/a.json")!)
        #expect(response.status == 500)
        #expect(try decodeJSON(response.body) == .object(["error": .string("InternalServerError"), "message": .string("upstream error")]))
        let result = try await search(s, transport: ScenarioServer(scenario: s))
        #expect(result.tileFailures.map(\.kind) == [.status])
    }

    @Test func aTileWithAStatusAndNoBodyIsAFailedTileOfKindStatusAndTheDecodeScenarioIsKindDecode() async throws {
        let s = try #require(try scenarios().first { $0.name == "a failed tile contributes nothing" })
        let result = try await search(s, transport: ScenarioServer(scenario: s))
        #expect(result.tileFailures.map(\.kind) == [.decode, .status])
        #expect(result.tiles == .init(fetched: 1, failed: 2))
    }
}

// The result must not depend on which tile arrives first (contract §4.10 walks tiles in URL order, and §13 says each
// port needs a test of its own): the lowest URL's response is delayed, so the highest URL arrives first.
@Suite("attribution scenarios, tiles arriving in reverse URL order") struct AttributionScenariosReversed {
    private static func multi() throws -> [AttributionScenario] { try scenarios().filter { $0.tiles.count > 1 } }

    @Test func hasMultiTileScenarios() throws {
        #expect(try Self.multi().count >= 4)
    }

    @Test("the scenario", arguments: try multi())
    func scenario(_ s: AttributionScenario) async throws {
        let urls = s.tiles.map(\.url).sorted { ordinalLess($0, $1) }
        let delays = Dictionary(uniqueKeysWithValues: urls.enumerated().map { ($1, TimeInterval(urls.count - 1 - $0) * 0.05) })
        let transport = DelayingTransport(ScenarioServer(scenario: s)) { delays[$0.absoluteString] }
        let result = try await search(s, transport: transport)
        // The delays took effect: the tiles completed highest URL first.
        let completed = transport.completionOrder.map(\.absoluteString).filter { delays[$0] != nil }
        #expect(completed == urls.reversed())
        try check(result, against: s)
    }
}

// A hit's collection comes from its own tile's attribution, not from the first used tile's, and not from the tile
// that sat at the record's position before text, dedupe or a filter dropped records ahead of it (contract §8).
@Suite("a hit's collection is its own tile's") struct HitCollectionFromItsOwnTile {
    private func rec(_ origin: String, _ name: String) -> JSONValue {
        .object(["value": .object([
            "$type": .string("org.atgeo.place"), "origin": .string(origin), "name": .string(name),
            "locations": .array([.object([
                "$type": .string("community.lexicon.location.geo"),
                "latitude": .string("37.770000"), "longitude": .string("-122.415000"),
            ])]),
        ])])
    }

    private func tile(_ name: String, _ records: [JSONValue], _ collection: String) -> AttributionScenario.Tile {
        .init(url: "https://places.atgeo.org/tiles/\(name)", body: .object([
            "records": .array(records),
            "attribution": .array([.object(["dataset": .string("d"), "collection": .string(collection)])]),
        ]), status: nil)
    }

    private func search(_ tiles: [AttributionScenario.Tile], text: String? = nil) async throws -> SearchResult {
        let s = AttributionScenario(
            name: "own tile", dataset: "d", collection: nil, region: .bbox(west: -122.42, south: 37.76, east: -122.41, north: 37.78),
            tiles: tiles, attribution: [], hits: [])
        return try await AtgeoClient(server: URL(string: serverBase)!, transport: ScenarioServer(scenario: s))
            .searchPlaces(region: s.region, dataset: "d", text: text)
    }

    private func collections(_ r: SearchResult) -> [String: CollectionKey?] {
        Dictionary(uniqueKeysWithValues: r.places.map { ($0.origin ?? "", $0.collection) })
    }

    @Test func eachHitTakesItsOwnTilesCollection() async throws {
        let r = try await search([
            tile("a.json", [rec("urn:atgeo:d:c1:1", "One")], "c1"),
            tile("b.json", [rec("urn:atgeo:d:c2:2", "Two")], "c2"),
        ])
        #expect(collections(r) == [
            "urn:atgeo:d:c1:1": CollectionKey(dataset: "d", collection: "c1"),
            "urn:atgeo:d:c2:2": CollectionKey(dataset: "d", collection: "c2"),
        ])
    }

    @Test func aRecordDroppedByTheTextScoreDoesNotShiftTheCollections() async throws {
        let r = try await search([
            tile("a.json", [rec("urn:atgeo:d:c1:1", "Zzzzqqq")], "c1"),
            tile("b.json", [rec("urn:atgeo:d:c2:2", "Cafe")], "c2"),
        ], text: "Cafe")
        #expect(r.places.map(\.origin) == ["urn:atgeo:d:c2:2"])
        #expect(r.places.first?.collection == CollectionKey(dataset: "d", collection: "c2"))
    }

    @Test func aRecordDroppedByDedupeDoesNotShiftTheCollections() async throws {
        let r = try await search([
            tile("a.json", [rec("urn:atgeo:d:c1:1", "One"), rec("urn:atgeo:d:c1:1", "One")], "c1"),
            tile("b.json", [rec("urn:atgeo:d:c2:2", "Two")], "c2"),
        ])
        #expect(collections(r) == [
            "urn:atgeo:d:c1:1": CollectionKey(dataset: "d", collection: "c1"),
            "urn:atgeo:d:c2:2": CollectionKey(dataset: "d", collection: "c2"),
        ])
    }

    @Test func aRecordDroppedByTheRegionFilterDoesNotShiftTheCollections() async throws {
        var far = rec("urn:atgeo:d:c1:1", "One")
        if case .object(var o) = far, case .object(var v)? = o["value"] {
            v["locations"] = .array([.object([
                "$type": .string("community.lexicon.location.geo"), "latitude": .string("10"), "longitude": .string("10"),
            ])])
            o["value"] = .object(v)
            far = .object(o)
        }
        let r = try await search([
            tile("a.json", [far], "c1"),
            tile("b.json", [rec("urn:atgeo:d:c2:2", "Two")], "c2"),
        ])
        #expect(collections(r) == ["urn:atgeo:d:c2:2": CollectionKey(dataset: "d", collection: "c2")])
    }
}

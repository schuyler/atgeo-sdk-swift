import Foundation
import Testing
@testable import Atgeo

// Port of test/keywordFallback.test.ts and the fallback half of privacy.test.ts: fixtures/keyword-fallback.json
// (the solid-hit decision and the merge, contract §18) and the rules around it (§12 item 7).

private let base = "https://places.atgeo.org"
private let dataset = "overturemaps.org"

/// A raw, request-capturing server: getTiles (any query) lists the tile URLs in listed order, each tile is served
/// with its body, and searchPlaces (any query) is answered by `onSearch`. The bodies need not validate against the
/// lexicons, which is why this is not the validating fake.
final class KeywordScenarioServer: HTTPTransport, @unchecked Sendable {
    private let tiles: [(url: String, body: JSONValue)]
    private let onSearch: @Sendable () throws -> HTTPResponse
    private let lock = NSLock()
    private var captured: [URL] = []

    init(tiles: [(url: String, body: JSONValue)], keywordAnswer: JSONValue) {
        self.tiles = tiles
        onSearch = { HTTPResponse(status: 200, body: try JSONEncoder().encode(keywordAnswer)) }
    }

    init(tiles: [(url: String, body: JSONValue)], onSearch: @escaping @Sendable () throws -> HTTPResponse) {
        self.tiles = tiles
        self.onSearch = onSearch
    }

    var requests: [URL] { lock.withLock { captured } }
    var searchRequests: [URL] { requests.filter { $0.absoluteString.hasPrefix("\(base)/xrpc/org.atgeo.searchPlaces") } }

    func get(_ url: URL) async throws -> HTTPResponse {
        lock.withLock { captured.append(url) }
        let href = url.absoluteString
        if href.hasPrefix("\(base)/xrpc/org.atgeo.getTiles") {
            return HTTPResponse(status: 200, body: try JSONEncoder().encode(JSONValue.object(["tiles": .array(tiles.map { .string($0.url) })])))
        }
        if href.hasPrefix("\(base)/xrpc/org.atgeo.searchPlaces") { return try onSearch() }
        guard let tile = tiles.first(where: { $0.url == href }) else { return HTTPResponse(status: 404, body: Data("Not found".utf8)) }
        return HTTPResponse(status: 200, body: try JSONEncoder().encode(tile.body))
    }
}

struct FallbackScenario: Sendable, CustomTestStringConvertible {
    var name: String
    var dataset: String
    var collection: String?
    var region: Region
    var keyword: String
    var keywordRegion: KeywordRegionMode
    var sort: SortMode
    var tiles: [(url: String, body: JSONValue)]
    var keywordAnswer: JSONValue
    var keywordRequested: Bool
    var bbox: String?
    var origins: [String]
    var disclosed: Disclosure
    var testDescription: String { name }
}

private func scenarios() throws -> [FallbackScenario] {
    try #require(try fixture("keyword-fallback.json").arrayValue).map { s in
        let r = try #require(s["region"])
        let region: Region
        if let b = r["bbox"]?.arrayValue?.compactMap(\.doubleValue), b.count == 4 {
            region = .bbox(west: b[0], south: b[1], east: b[2], north: b[3])
        } else {
            region = .circle(
                lat: try #require(r["lat"]?.doubleValue), lon: try #require(r["lon"]?.doubleValue),
                radius: try #require(r["radius"]?.doubleValue))
        }
        let expect = try #require(s["expect"])
        let mode = try #require(s["keywordRegion"]?.stringValue)
        return FallbackScenario(
            name: try #require(s["name"]?.stringValue),
            dataset: try #require(s["dataset"]?.stringValue),
            collection: s["collection"]?.stringValue,
            region: region,
            keyword: try #require(s["keyword"]?.stringValue),
            keywordRegion: mode == "degree" ? .degree : .none,
            sort: s["sort"]?.stringValue.flatMap(SortMode.init(rawValue:)) ?? .fused,
            tiles: try #require(s["tiles"]?.arrayValue).map { (url: $0["url"]?.stringValue ?? "", body: $0["body"] ?? .null) },
            keywordAnswer: try #require(s["keywordAnswer"]),
            keywordRequested: try #require(expect["keywordRequested"]?.boolValue),
            bbox: expect["bbox"]?.stringValue,
            origins: try #require(expect["origins"]?.arrayValue).compactMap(\.stringValue),
            disclosed: Disclosure(
                keyword: try #require(expect["disclosed"]?["keyword"]?.boolValue),
                region: expect["disclosed"]?["region"]?.doubleValue))
    }
}

@Suite("keyword fallback scenarios") struct KeywordFallbackScenarios {
    @Test func hasTheScenarios() throws {
        #expect(try scenarios().count == 7)
    }

    // A fresh client per scenario: scenarios reuse tile URLs, and the caches are keyed by dataset, collection and bbox.
    @Test("the scenario", arguments: try scenarios())
    func scenario(_ s: FallbackScenario) async throws {
        let server = KeywordScenarioServer(tiles: s.tiles, keywordAnswer: s.keywordAnswer)
        let result = try await AtgeoClient(server: URL(string: base)!, transport: server).searchNearbyThenByKeyword(
            region: s.region, dataset: s.dataset, keyword: s.keyword, keywordRegion: s.keywordRegion,
            collection: s.collection, sort: s.sort)

        #expect(result.places.map(\.origin) == s.origins.map { Optional($0) })
        #expect(result.disclosed == s.disclosed)

        let searches = server.searchRequests
        #expect(searches.count == (s.keywordRequested ? 1 : 0))
        if s.keywordRequested {
            var expected = ["dataset": s.dataset, "q": s.keyword]
            if let collection = s.collection { expected["collection"] = collection }
            if let bbox = s.bbox { expected["bbox"] = bbox }
            #expect(paramsOf(searches[0]) == expected)
        }
    }
}

@Suite("searchNearbyThenByKeyword arguments") struct FallbackArguments {
    private let box = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
    private let bad = Region.bbox(west: 0, south: 10, east: 1, north: 5)

    // Each case is wrong in its own way and in every way after it, so the error names the first.
    @Test("refuses a bad region first, then similarity without a keyword, with no request")
    func order() async throws {
        let server = KeywordScenarioServer(tiles: [], keywordAnswer: .null)
        let client = AtgeoClient(server: URL(string: base)!, transport: server)
        await #expect(throws: AtgeoArgumentError.invalidRegion("invalid bbox")) {
            _ = try await client.searchNearbyThenByKeyword(region: bad, dataset: dataset, keyword: "  ", keywordRegion: .none, sort: .similarity)
        }
        await #expect(throws: AtgeoArgumentError.similarityRequiresText) {
            _ = try await client.searchNearbyThenByKeyword(region: box, dataset: dataset, keyword: "  ", keywordRegion: .none, sort: .similarity)
        }
        #expect(server.requests.isEmpty)
    }
}

// Contract §18 step 8 (#56): the qualifying predicate can judge a keyword sendable that the server refuses. NFKD
// turns "ﬁ" into "fi", two characters, but the server keeps the ligature whole, one character, and answers
// KeywordRequired. The fallback then keeps its nearby result instead of failing.
@Suite("searchNearbyThenByKeyword when the server refuses a keyword the SDK judged qualifying") struct FallbackKeywordRequired {
    @Test("returns the nearby result, disclosing the keyword it sent")
    func keepsNearby() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let nearby = try await FakeServer(tilesets: [overture(zanzibarTiles)]).client()
            .searchNearby(region: zanzibarRegion, dataset: dataset, text: "ﬁ")
        let result = try await server.client().searchNearbyThenByKeyword(
            region: zanzibarRegion, dataset: dataset, keyword: "ﬁ", keywordRegion: .degree)
        #expect(server.searchPlacesRequests.count == 1)
        // The keyword went out and was refused; everything else is the nearby search's.
        #expect(result == FallbackSearchResult(nearby, disclosed: Disclosure(keyword: true, region: 0.01)))
    }

    @Test("reports a one degree region when the nearby half was cached and the keyword carried one")
    func warmNearby() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        _ = try await client.searchNearby(region: zanzibarRegion, dataset: dataset)
        let degree = try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "ﬁ", keywordRegion: .degree)
        #expect(degree.disclosed == Disclosure(keyword: true, region: 1))
        let none = try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "ﬁ", keywordRegion: .none)
        #expect(none.disclosed == Disclosure(keyword: true, region: nil))
    }

    @Test("still throws any other refusal of the keyword request")
    func otherRefusal() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let transport = InterceptingTransport(server) { url in
            url.absoluteString.contains("org.atgeo.searchPlaces")
                ? HTTPResponse(status: 400, body: Data(#"{"error":"InvalidRequest","message":"q is too long"}"#.utf8)) : nil
        }
        let client = AtgeoClient(server: URL(string: server.server)!, transport: transport)
        do {
            _ = try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "Quokka", keywordRegion: .none)
            Issue.record("expected a throw")
        } catch let error as AtgeoError {
            #expect(error.code == "InvalidRequest")
        }
    }
}

/// Answers the URLs `answer` names itself, and passes the rest to `base`.
struct InterceptingTransport: HTTPTransport {
    let base: any HTTPTransport
    let answer: @Sendable (URL) -> HTTPResponse?
    init(_ base: any HTTPTransport, _ answer: @escaping @Sendable (URL) -> HTTPResponse?) {
        self.base = base
        self.answer = answer
    }

    func get(_ url: URL) async throws -> HTTPResponse {
        if let response = answer(url) { return response }
        return try await base.get(url)
    }
}

// #60: fallback rules no test killed before. A raw server, so bodies and attribution can be chosen freely.
@Suite("searchNearbyThenByKeyword pins") struct FallbackPins {
    private let region = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
    private let tile = "\(base)/tiles/t.json"
    private let loc: JSONValue = .array([.object([
        "$type": .string("community.lexicon.location.geo"), "latitude": .string("37.775000"), "longitude": .string("-122.415000"),
    ])])

    private func entry(_ attribution: String) -> JSONValue {
        .object(["dataset": .string(dataset), "collection": .string("place"), "attribution": .string(attribution)])
    }

    @Test("never leaves out a nearby hit with no origin, even when a keyword hit has none either")
    func nullOrigins() async throws {
        // Neither record has an origin or a uri, so both hits have origin nil.
        let tileBody: JSONValue = .object([
            "records": .array([.object(["value": .object(["name": .string("Quokka Lounge"), "locations": loc])])]), "attribution": .array([]),
        ])
        let answer: JSONValue = .object(["places": .array([
            .object(["value": .object(["name": .string("Qwokka Bar"), "locations": loc]), "attribution": .array([])]),
        ])])
        let server = KeywordScenarioServer(tiles: [(tile, tileBody)], keywordAnswer: answer)
        let result = try await AtgeoClient(server: URL(string: base)!, transport: server)
            .searchNearbyThenByKeyword(region: region, dataset: dataset, keyword: "Qwokka", keywordRegion: .none)
        #expect(result.places.map(\.via) == [.keyword, .tiles])
        #expect(result.places.map(\.name) == ["Qwokka Bar", "Quokka Lounge"])
    }

    @Test("keeps the nearby attribution entry when both halves carry the same collection")
    func nearbyAttributionWins() async throws {
        let tileBody: JSONValue = .object(["records": .array([]), "attribution": .array([entry("from the tiles")])])
        let answer: JSONValue = .object(["places": .array([.object([
            "value": .object(["origin": .string("urn:atgeo:overturemaps.org:place:k"), "name": .string("Kumquat"), "locations": loc]),
            "attribution": .array([entry("from the keyword answer")]),
        ])])])
        let server = KeywordScenarioServer(tiles: [(tile, tileBody)], keywordAnswer: answer)
        let result = try await AtgeoClient(server: URL(string: base)!, transport: server)
            .searchNearbyThenByKeyword(region: region, dataset: dataset, keyword: "Kumquat", keywordRegion: .none)
        #expect(result.attribution == [Attribution(dataset: dataset, collection: "place", attribution: "from the tiles")])
    }

    @Test("a hit's via and collection survive the merge")
    func viaSurvives() async throws {
        let origin = "urn:atgeo:overturemaps.org:place:k"
        let answer: JSONValue = .object(["places": .array([.object([
            "value": .object(["origin": .string(origin), "name": .string("Kumquat"), "locations": loc]),
            "attribution": .array([entry("x")]),
        ])])])
        let server = KeywordScenarioServer(tiles: [(tile, .object(["records": .array([]), "attribution": .array([])]))], keywordAnswer: answer)
        let result = try await AtgeoClient(server: URL(string: base)!, transport: server)
            .searchNearbyThenByKeyword(region: region, dataset: dataset, keyword: "Kumquat", keywordRegion: .none)
        guard case .keyword(let hit)? = result.places.first else { Issue.record("expected a keyword hit"); return }
        #expect(hit.collection == CollectionKey(dataset: dataset, collection: "place"))
        #expect(result.places.first?.via == .keyword)
    }
}

// Section 12, item 7 (#60): when the fallback does send its keyword, no nearby-half request carries it.
@Suite("the fallback's nearby half keeps the keyword local") struct FallbackPrivacy {
    @Test("puts the keyword in the searchPlaces request only")
    func keywordOnlyInSearch() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let keyword = "Kumquat Lagoon"
        _ = try await server.client().searchNearbyThenByKeyword(
            region: .circle(lat: 37.7749295, lon: -122.4194155, radius: 500), dataset: dataset, keyword: keyword, keywordRegion: .none)
        let search = server.searchPlacesRequests
        let nearby = server.requests.filter { !$0.absoluteString.contains("org.atgeo.searchPlaces") }
        #expect(search.count == 1)
        #expect(paramsOf(search[0]) == ["dataset": dataset, "q": keyword])
        #expect(!nearby.isEmpty)
        for url in nearby {
            let raw = url.absoluteString.lowercased()
            let decoded = (raw.removingPercentEncoding ?? raw).replacingOccurrences(of: "+", with: " ")
            for needle in ["kumquat lagoon", "kumquat", "lagoon", "kumqu"] {
                #expect(!raw.contains(needle))
                #expect(!decoded.contains(needle))
            }
        }
    }

    @Test("sends no keyword when a nearby hit is a word match, or the keyword cannot qualify")
    func nothingSent() async throws {
        let server = try FakeServer(tilesets: [overture(zanzibarTiles)])
        let client = server.client()
        let solid = try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "Zanz", keywordRegion: .degree)
        #expect(solid.disclosed == Disclosure(keyword: false, region: 0.01))
        let short = try await client.searchNearbyThenByKeyword(region: zanzibarRegion, dataset: dataset, keyword: "q", keywordRegion: .degree)
        #expect(short.disclosed == Disclosure(keyword: false, region: nil))
        #expect(server.searchPlacesRequests.isEmpty)
    }
}

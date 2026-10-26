import Foundation
import Testing
@testable import Atgeo

// Port of test/client.test.ts.

private let sfRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)

@Suite("getPlace(origin:)") struct GetPlace {
    let value = place("r1", "Ferry Building", [point(37.7955, -122.3937)], [
        "attributes": .object(["kind": .string("landmark")]),
        "futureKey": .object(["nested": .array([.number(1), .number(2)])]),
    ])
    let origin = placeOrigin("r1")
    let noImportance = place("r2", "No Importance", [point(37.7955, -122.3937)])

    func setup() throws -> FakeServer {
        try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [record(value, importance: 80), record(noImportance)])])])
    }

    @Test("sends one getPlace request with the origin as uri on a cold client, and no describeService")
    func oneRequest() async throws {
        let fake = try setup()
        _ = try await fake.client().getPlace(origin: origin)
        #expect(fake.requests.count == 1)
        let u = try #require(fake.requests.first)
        #expect(originAndPath(u) == "\(defaultServer)/xrpc/org.atgeo.getPlace")
        #expect(param(u, "uri") == origin)
        #expect(!fake.requests.contains { $0.lastPathComponent == "org.atgeo.describeService" })
    }

    @Test("returns the value unmodified with importance beside it")
    func unmodified() async throws {
        #expect(try await setup().client().getPlace(origin: origin)
                == PlaceRecord(origin: origin, place: value, importance: 80, attribution: [overturePlaceAttribution]))
    }

    @Test("returns a nil importance when the server gives none")
    func nilImportance() async throws {
        #expect(try await setup().client().getPlace(origin: placeOrigin("r2")).importance == nil)
    }

    @Test("returns the same answer from the cache and the network")
    func cacheEqualsNetwork() async throws {
        let fake = try setup()
        let network = try await fake.client().getPlace(origin: origin)
        let fresh = fake.client()
        _ = try await fresh.searchPlaces(region: .bbox(west: -122.40, south: 37.79, east: -122.39, north: 37.80), dataset: "overturemaps.org", collection: "place")
        let before = fake.requests.count
        #expect(try await fresh.getPlace(origin: origin) == network)
        #expect(fake.requests.count == before)
    }

    @Test("makes no request for the origin of a hit from an earlier search")
    func noRequestForAHit() async throws {
        let fake = try setup()
        let client = fake.client()
        let places = try await client.searchPlaces(region: .bbox(west: -122.40, south: 37.79, east: -122.39, north: 37.80), dataset: "overturemaps.org", collection: "place").places
        let before = fake.requests.count
        _ = try await client.getPlace(origin: try #require(places.first?.origin))
        #expect(fake.requests.count == before)
    }

    @Test("resolves a hit identified by a record uri from the cache")
    func uriFromCache() async throws {
        let uriOnly = withoutOrigin(place("u", "By uri", [point(37.775, -122.415)]))
        let fake = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [record(uriOnly, importance: 4, uri: "https://example.org/r/u")])])])
        let client = fake.client()
        let places = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org").places
        #expect(places.first?.origin == "https://example.org/r/u")
        fake.goOffline()
        #expect(try await client.getPlace(origin: "https://example.org/r/u")
                == PlaceRecord(origin: "https://example.org/r/u", place: uriOnly, importance: 4,
                               attribution: [overturePlaceAttribution]))
    }

    // getPlace(origin:) carries attribution as served (contract §9): from the cache, the attribution of the tile that
    // held the record; from the network, the response's. The fake's tileset credits its collection, then these
    // references, one of them twice.
    static let references: [JSONObject] = [
        ["dataset": .string("z.example"), "collection": .string("c")],
        ["dataset": .string("a.example"), "collection": .string("c"), "release": .string("1")],
        ["dataset": .string("a.example"), "collection": .string("c"), "release": .string("2")],
    ]
    static let served = [
        overturePlaceAttribution,
        Attribution(dataset: "z.example", collection: "c"),
        Attribution(dataset: "a.example", collection: "c", release: "1"),
        Attribution(dataset: "a.example", collection: "c", release: "2"),
    ]

    func withReferences() throws -> FakeServer {
        var tileset = overture([FakeTile(url: tileURL("a"), records: [record(value, importance: 80)])])
        tileset.references = Self.references
        return try FakeServer(tilesets: [tileset])
    }

    @Test("returns the tile's attribution from the cache in served order, duplicates included, unsorted")
    func attributionFromCache() async throws {
        let fake = try withReferences()
        let client = fake.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        fake.goOffline()
        #expect(try await client.getPlace(origin: origin).attribution == Self.served)
    }

    @Test("returns the response's attribution from the network in served order, duplicates included, unsorted")
    func attributionFromNetwork() async throws {
        let fake = try withReferences()
        let answer = try await fake.client().getPlace(origin: origin)
        #expect(fake.requests.contains { $0.path == "/xrpc/org.atgeo.getPlace" })
        #expect(answer.attribution == Self.served)
    }

    // Swift's structs are values: the answer is the app's own copy, so changing it, or an entry's `licenses`,
    // changes nothing the client caches. This is the contract's copy requirement (§9), met by the language.
    @Test("changing a getPlace(origin:) answer's attribution changes nothing cached", arguments: [true, false])
    func attributionIsTheAppsOwn(fromCache: Bool) async throws {
        var tileset = overture([FakeTile(url: tileURL("a"), records: [record(value, importance: 80)])])
        tileset.collections = [[
            "dataset": .string("overturemaps.org"), "collection": .string("place"),
            "licenses": .array([.string("https://l.example/1")]),
        ]]
        tileset.references = Self.references
        let fake = try FakeServer(tilesets: [tileset])
        let client = fake.client()
        if fromCache {
            _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
            fake.goOffline()
        }
        var first = try await client.getPlace(origin: origin)
        let original = first.attribution
        #expect(original.first?.licenses == ["https://l.example/1"])
        try #require(!first.attribution.isEmpty)
        first.attribution[0].licenses?.append("https://l.example/changed")
        first.attribution[0].release = "changed"
        first.attribution.reverse()
        first.place["name"] = .string("Changed")
        let again = try await client.getPlace(origin: origin)
        #expect(again.attribution == original)
        #expect(again.place == value)
        if !fromCache { #expect(fake.requests.filter { $0.path == "/xrpc/org.atgeo.getPlace" }.count == 2) }
    }

    @Test("rejects an unknown origin with PlaceNotFound", arguments: [placeOrigin("nope"), "https://example.org/not-an-origin"])
    func placeNotFound(unknown: String) async throws {
        let client = try setup().client()
        do {
            _ = try await client.getPlace(origin: unknown)
            Issue.record("expected PlaceNotFound")
        } catch let error as AtgeoError {
            #expect(error.code == "PlaceNotFound")
        }
    }
}

@Suite("describeService and describeTileset") struct Describe {
    static let osm = FakeTileset(
        slug: "osm",
        collections: [[
            "dataset": .string("openstreetmap.org"), "collection": .string("way"), "recordCount": .number(3),
            "categories": .array([.object(["value": .string("cafe"), "count": .number(2)])]),
        ]],
        references: [[
            "dataset": .string("openstreetmap.org"), "collection": .string("node"),
            "licenses": .array([.string("https://opendatacommons.org/licenses/odbl/")]),
        ]],
        tiles: [])

    func fake() throws -> FakeServer { try FakeServer(tilesets: [overture([]), Self.osm]) }

    @Test("describeService returns the did and the configured tilesets")
    func service() async throws {
        let service = try await fake().client().describeService()
        #expect(service == ServiceDescription(did: "did:web:places.atgeo.org", tilesets: [
            .init(slug: "overture-place", collections: [CollectionRef(dataset: "overturemaps.org", collection: "place")]),
            .init(slug: "osm", collections: [CollectionRef(dataset: "openstreetmap.org", collection: "way")]),
        ], maxTiles: 50))
        #expect(service.maxTiles == 50)
        #expect(service.tilesets.map(\.slug) == ["overture-place", "osm"])
    }

    @Test("describeTileset returns the descriptor")
    func tileset() async throws {
        let tileset = try await fake().client().describeTileset("osm")
        #expect(tileset == Tileset(
            slug: "osm", publishedAt: nil, extent: nil,
            collections: [CollectionInfo(
                dataset: "openstreetmap.org", collection: "way", release: nil, source: nil, licenses: nil, attribution: nil,
                recordCount: 3, locationFormats: nil, containmentTypes: nil,
                categories: [.init(value: "cafe", count: 2)], attributes: nil)],
            references: [CollectionAttribution(
                dataset: "openstreetmap.org", collection: "node", release: nil, source: nil,
                licenses: ["https://opendatacommons.org/licenses/odbl/"], attribution: nil)]))
        #expect(tileset.slug == "osm")
    }

    @Test("describeTileset passes the overview through")
    func overview() async throws {
        var withOverview = Self.osm
        withOverview.overview = ["records": .number(1234)]
        let tileset = try await FakeServer(tilesets: [withOverview]).client().describeTileset("osm")
        #expect(tileset.overview == Tileset.Overview(records: 1234))
        var expected = try await fake().client().describeTileset("osm")
        expected.overview = Tileset.Overview(records: 1234)
        #expect(tileset == expected)
        #expect(try await fake().client().describeTileset("osm").overview == nil)
    }

    @Test("describeTileset asks the server each time")
    func notCached() async throws {
        let server = try fake()
        let client = server.client()
        _ = try await client.describeTileset("osm")
        _ = try await client.describeTileset("osm")
        #expect(server.requests.count == 2)
    }

    @Test("describeTileset rejects an unknown slug with TilesetNotFound")
    func unknownSlug() async throws {
        do {
            _ = try await fake().client().describeTileset("nope")
            Issue.record("expected TilesetNotFound")
        } catch let error as AtgeoError {
            #expect(error.code == "TilesetNotFound")
        }
    }
}

@Suite("searchPlaces results") struct SearchPlacesResults {
    static let records = [
        record(place("cafe", "Zanzibar Cafe", [point(0.001, 0)], [
            "futureKey": .object(["a": .number(1)]), "variants": .array([.object(["name": .string("ZC")])]),
        ]), importance: 2),
        record(place("shop", "Corner Shop", [point(0.002, 0)]), importance: 9),
        record(place("division", "Some Division", [bboxLocation(north: 0.01, south: -0.01, east: 0.01, west: -0.01)]), importance: 1),
    ]
    static let circle = Region.circle(lat: 0, lon: 0, radius: 2000)

    func setup() throws -> AtgeoClient {
        try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: Self.records)])]).client()
    }

    @Test("returns origin, the wire place, importance, metres distance and nil score without text")
    func shape() async throws {
        let result = try await setup().searchPlaces(region: Self.circle, dataset: "overturemaps.org", collection: "place")
        let cafe = try #require(result.places.first { $0.origin == placeOrigin("cafe") })
        #expect(cafe.place == Self.records[0].value)
        #expect(cafe.place["importance"] == nil)
        #expect(cafe.importance == 2)
        #expect(abs(cafe.distance - 111.195) < 0.05)
        #expect(result.places.allSatisfy { $0.score == nil })
    }

    @Test("gives distance 0 to a bbox containing the center")
    func containingBox() async throws {
        #expect(try await setup().searchPlaces(region: Self.circle, dataset: "overturemaps.org", collection: "place").places.first { $0.origin == placeOrigin("division") }?.distance == 0)
    }

    @Test("returns a numeric score with text")
    func scoreWithText() async throws {
        let result = try await setup().searchPlaces(region: Self.circle, dataset: "overturemaps.org", text: "Zanzibar Cafe", collection: "place")
        let cafe = try #require(result.places.first { $0.origin == placeOrigin("cafe") })
        // vitest's toBeCloseTo(1, 2) is |diff| < 0.005.
        #expect(abs((cafe.score ?? 0) - 1) < 0.005)
        #expect(result.places.allSatisfy { $0.score != nil })
    }

    @Test("treats text that normalizes to empty as no text")
    func blankText() async throws {
        let client = try setup()
        let none = try await client.searchPlaces(region: Self.circle, dataset: "overturemaps.org", collection: "place")
        let blank = try await client.searchPlaces(region: Self.circle, dataset: "overturemaps.org", text: "   ", collection: "place")
        #expect(blank.places.count > 0)
        #expect(blank == none)
        #expect(blank.places.allSatisfy { $0.score == nil })
    }
}

@Suite("ordering among places containing the center") struct OrderingAmongContaining {
    private func ids(_ values: [(JSONObject, Int64?)], region: Region, text: String? = nil, sort: SortMode) async throws -> [String] {
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: values.map { record($0.0, importance: $0.1) })])])
        return try await server.client().searchPlaces(region: region, dataset: "overturemaps.org", text: text, collection: "place", sort: sort).places
            .map { String(($0.origin ?? "").dropFirst(placeOrigin("").count)) }
    }

    @Test("puts the smaller box first when the center sits on the antimeridian seam")
    func seam() async throws {
        // Center is exactly (45, 180). The small box reaches it as lon -180 / 180.
        let small = place("small", "Small", [bboxLocation(north: 50, south: 40, east: -170, west: -180)])
        let large = place("large", "Large", [bboxLocation(north: 55, south: 35, east: -160, west: 160)])
        #expect(try await ids([(small, 1), (large, 9)], region: .bbox(west: 170, south: 40, east: -170, north: 50), sort: .distance)
                == ["small", "large"])
    }

    @Test("leaves ties to the origin, whatever the sizes", arguments: [SortMode.fused, .similarity])
    func tiesToOrigin(sort: SortMode) async throws {
        let large = place("a-large", "Same", [bboxLocation(north: 50, south: 40, east: 15, west: 5)])
        let small = place("b-small", "Same", [bboxLocation(north: 46, south: 44, east: 11, west: 9)])
        #expect(try await ids([(small, 5), (large, 5)], region: .circle(lat: 45, lon: 10, radius: 1000), text: "Same", sort: sort)
                == ["a-large", "b-small"])
    }

    @Test("puts a point at the center before a more important containing box")
    func pointFirst() async throws {
        let box = place("box", "Box", [bboxLocation(north: 46, south: 44, east: 11, west: 9)])
        let pin = place("pin", "Pin", [point(45, 10)])
        #expect(try await ids([(box, 9), (pin, 1)], region: .circle(lat: 45, lon: 10, radius: 1000), sort: .distance) == ["pin", "box"])
    }
}

@Suite("datasets and collections") struct DatasetsAndCollections {
    static func osm(_ kind: String, _ id: String, _ lat: Double) -> JSONObject {
        place(id, "\(kind) \(id)", [point(lat, -122.415)], ["origin": .string("urn:atgeo:openstreetmap.org:\(kind):\(id)")])
    }

    static let osmTileset = FakeTileset(
        slug: "osm",
        collections: ["node", "way", "relation"].map { ["dataset": .string("openstreetmap.org"), "collection": .string($0)] },
        tiles: [FakeTile(url: tileURL("osm"), records: [
            record(osm("node", "1", 37.771)),
            record(osm("way", "2", 37.772)),
            record(osm("relation", "3", 37.773)),
            record(withoutOrigin(place("u", "By uri", [point(37.774, -122.415)])), uri: "https://example.org/r/u"),
        ])])

    func setup() throws -> FakeServer { try FakeServer(tilesets: [overture([]), Self.osmTileset]) }

    @Test("keys the tile list on dataset and collection")
    func keys() async throws {
        let fake = try setup()
        let client = fake.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "openstreetmap.org", collection: "way")
        _ = try await client.searchPlaces(region: sfRegion, dataset: "openstreetmap.org")
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        #expect(fake.getTilesRequests.map { "\(param($0, "dataset") ?? "null")|\(param($0, "collection") ?? "null")" }
                == ["openstreetmap.org|way", "openstreetmap.org|null", "overturemaps.org|null"])
    }

    @Test("matches the collection, not a collection sharing its prefix")
    func prefix() async throws {
        let fake = try FakeServer(tilesets: [FakeTileset(
            slug: "osm",
            collections: ["way", "wayside"].map { ["dataset": .string("openstreetmap.org"), "collection": .string($0)] },
            tiles: [FakeTile(url: tileURL("osm"), records: [record(Self.osm("way", "2", 37.772)), record(Self.osm("wayside", "9", 37.773))])])])
        let places = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org", collection: "way").places
        #expect(places.map(\.origin) == ["urn:atgeo:openstreetmap.org:way:2"])
    }

    // Contract §4.7: the filter is startsWith on `value.origin`, never contains.
    @Test("keeps an origin that starts with the collection's prefix and drops one that merely contains it")
    func filterIsStartsWith() async throws {
        var contains = Self.osm("way", "5", 37.775)
        contains["origin"] = .string("x:urn:atgeo:openstreetmap.org:way:5")
        let fake = try FakeServer(tilesets: [FakeTileset(
            slug: "osm", collections: [["dataset": .string("openstreetmap.org"), "collection": .string("way")]],
            tiles: [FakeTile(url: tileURL("osm"), records: [record(Self.osm("way", "2", 37.772)), record(contains)])])])
        let places = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org", collection: "way").places
        #expect(places.map(\.origin) == ["urn:atgeo:openstreetmap.org:way:2"])
        let whole = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org").places
        #expect(whole.compactMap(\.origin).sorted() == ["urn:atgeo:openstreetmap.org:way:2", "x:urn:atgeo:openstreetmap.org:way:5"])
        #expect(whole.first { $0.origin == "x:urn:atgeo:openstreetmap.org:way:5" }?.collection == nil)
    }

    @Test("searches a whole dataset when only the dataset is named")
    func wholeDataset() async throws {
        let fake = try setup()
        let places = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org").places
        #expect(places.compactMap(\.origin).sorted() == [
            "https://example.org/r/u", "urn:atgeo:openstreetmap.org:node:1",
            "urn:atgeo:openstreetmap.org:relation:3", "urn:atgeo:openstreetmap.org:way:2",
        ])
        let first = try #require(fake.requests.first)
        #expect(param(first, "dataset") == "openstreetmap.org")
        #expect(param(first, "collection") == nil)
    }

    @Test("filters to one collection, dropping records with no origin")
    func oneCollection() async throws {
        let fake = try setup()
        let places = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org", collection: "way").places
        #expect(places.map(\.origin) == ["urn:atgeo:openstreetmap.org:way:2"])
        #expect(param(try #require(fake.requests.first), "collection") == "way")
    }

    // The reference's "requires dataset in the type" and its TypeError cases (missing, null, a number, an array, a
    // collection named without a dataset, a missing dataset reported before an invalid region) have no runtime
    // test here: `dataset` is a non-optional String, so a call without one does not compile, and nothing the
    // compiler accepts can reach the client as "missing". What can be checked is the signature (SourceChecks, and
    // PublicAPITests, which calls it with the labels in the contract's order) and the one runtime case below.
    @Test("sends an empty dataset to the server, which answers for itself")
    func emptyDataset() async throws {
        let fake = try setup()
        await #expect(throws: AtgeoError.self) {
            _ = try await fake.client().searchPlaces(region: sfRegion, dataset: "")
        }
        let lists = fake.getTilesRequests
        #expect(lists.count == 1)
        #expect(param(try #require(lists.first), "dataset") == "")
        #expect(URLComponents(url: try #require(lists.first), resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?
            .contains { $0.name == "dataset" } == true)
    }

    @Test("sends the collection only when the search has one")
    func collectionOnlyWhenGiven() async throws {
        let fake = try setup()
        _ = try await fake.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        let first = try #require(fake.requests.first)
        #expect(param(first, "dataset") == "overturemaps.org")
        #expect(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).contains("collection") == false)
    }

    @Test("gives each hit the collection its origin names, by prefix, and nil to a hit keyed by uri")
    func hitCollections() async throws {
        let places = try await setup().client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org").places
        let byOrigin = Dictionary(uniqueKeysWithValues: places.map { ($0.origin ?? "nil", $0.collection) })
        #expect(byOrigin == [
            "urn:atgeo:openstreetmap.org:node:1": CollectionKey(dataset: "openstreetmap.org", collection: "node"),
            "urn:atgeo:openstreetmap.org:way:2": CollectionKey(dataset: "openstreetmap.org", collection: "way"),
            "urn:atgeo:openstreetmap.org:relation:3": CollectionKey(dataset: "openstreetmap.org", collection: "relation"),
            "https://example.org/r/u": nil,
        ])
    }

    @Test("gives way and wayside hits their own collections")
    func wayAndWayside() async throws {
        let fake = try FakeServer(tilesets: [FakeTileset(
            slug: "osm",
            collections: ["way", "wayside"].map { ["dataset": .string("openstreetmap.org"), "collection": .string($0)] },
            tiles: [FakeTile(url: tileURL("osm"), records: [record(Self.osm("way", "2", 37.772)), record(Self.osm("wayside", "9", 37.773))])])])
        let places = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org").places
        #expect(Dictionary(uniqueKeysWithValues: places.map { ($0.origin ?? "", $0.collection?.collection) })
                == ["urn:atgeo:openstreetmap.org:way:2": "way", "urn:atgeo:openstreetmap.org:wayside:9": "wayside"])
    }

    @Test("returns the union of the tile's attribution, references included, sorted")
    func attributionUnion() async throws {
        let fake = try FakeServer(tilesets: [FakeTileset(
            slug: "osm",
            collections: [
                ["dataset": .string("openstreetmap.org"), "collection": .string("way"), "release": .string("2026-01-01"),
                 "licenses": .array([.string("https://opendatacommons.org/licenses/odbl/")])],
                ["dataset": .string("openstreetmap.org"), "collection": .string("relation")],
            ],
            references: [["dataset": .string("openstreetmap.org"), "collection": .string("node"), "source": .string("https://www.openstreetmap.org")]],
            tiles: [FakeTile(url: tileURL("osm"), records: [record(Self.osm("way", "2", 37.772))])])])
        let result = try await fake.client().searchPlaces(region: sfRegion, dataset: "openstreetmap.org", collection: "way")
        #expect(result.attribution == [
            Attribution(dataset: "openstreetmap.org", collection: "node", source: "https://www.openstreetmap.org"),
            Attribution(dataset: "openstreetmap.org", collection: "relation"),
            Attribution(dataset: "openstreetmap.org", collection: "way", release: "2026-01-01",
                        licenses: ["https://opendatacommons.org/licenses/odbl/"]),
        ])
    }

    // Contract §13: the sort of 4.10 uses the comparator of 4.3, UTF-16 code units. U+10000 (a surrogate pair,
    // starting 0xD800) sorts before U+FF5E there, and after it by code point or String's <, which no fixture
    // distinguishes (all names are in the basic multilingual plane).
    @Test("sorts attribution by UTF-16 code units, not by code point")
    func attributionOrdinalAboveTheBMP() async throws {
        let astral = "\u{10000}", fullwidth = "\u{FF5E}"
        #expect(astral.utf16.lexicographicallyPrecedes(fullwidth.utf16))
        #expect(fullwidth.unicodeScalars.lexicographicallyPrecedes(astral.unicodeScalars))
        let tiles = [FakeTile(url: tileURL("a"), records: [record(place("p", "P", [point(37.775, -122.415)]))])]
        var tileset = overture(tiles)
        tileset.references = [
            ["dataset": .string(fullwidth), "collection": .string("c")],
            ["dataset": .string(astral), "collection": .string("c")],
        ]
        let result = try await FakeServer(tilesets: [tileset]).client().searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        #expect(result.attribution.map(\.dataset) == ["overturemaps.org", astral, fullwidth])
    }
}

// The reference's static source checks, over Sources/ read from disk. "References no DOM globals" has no
// Swift counterpart beyond the import check.
private let sourcesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources")

private func sourceFiles() throws -> [(String, String)] {
    let enumerator = try #require(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
    return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map {
        ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
    }.sorted { $0.0 < $1.0 }
}

@Suite("retired wire names and universal runtime") struct SourceChecks {
    // `dataset` is required with no default (contract §4.1), which in Swift is a non-optional parameter, between
    // `region` and `text`. The compiler enforces it for callers; this keeps a later edit from loosening it.
    @Test("searchPlaces takes a required, non-optional dataset after region")
    func datasetIsRequired() throws {
        let client = try #require(try sourceFiles().first { $0.0 == "AtgeoClient.swift" }).1
        #expect(client.firstMatch(of: /func searchPlaces\(\s*region: Region,\s*dataset: String,\s*text: String\? = nil,\s*collection: String\? = nil,\s*sort: SortMode = \.fused\s*\) async throws -> SearchResult/) != nil)
        #expect(!client.contains("overturemaps.org"), "the client names no default dataset")
    }

    @Test("reads the source files")
    func readsSources() throws {
        #expect(try sourceFiles().count >= 10)
    }

    @Test("mentions no retired collection, record or coverage names")
    func retiredNames() throws {
        for (file, text) in try sourceFiles() {
            #expect(text.firstMatch(of: /org\.atgeo\.collection|getRecord|getCoverage|rkey/) == nil, "\(file)")
        }
    }

    // os is for the debug log of failed tiles, behind canImport(os), on Apple platforms only (contract §14).
    @Test("the library imports only Foundation, FoundationNetworking and os")
    func imports() throws {
        for (file, text) in try sourceFiles() where file != "main.swift" {
            for line in text.split(separator: "\n") {
                guard let m = line.firstMatch(of: /^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:[a-z]+\s+)?(\w+)/) else { continue }
                #expect(["Foundation", "FoundationNetworking", "os"].contains(String(m.1)), "\(file): \(line)")
            }
        }
    }
}

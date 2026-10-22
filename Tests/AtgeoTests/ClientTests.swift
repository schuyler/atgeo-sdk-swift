import Foundation
import Testing
@testable import Atgeo

// Port of test/client.test.ts.

private let sfRegion = Region.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78)

@Suite("place(origin:)") struct GetPlace {
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
        _ = try await fake.client().place(origin: origin)
        #expect(fake.requests.count == 1)
        let u = try #require(fake.requests.first)
        #expect(originAndPath(u) == "\(defaultServer)/xrpc/org.atgeo.getPlace")
        #expect(param(u, "uri") == origin)
        #expect(!fake.requests.contains { $0.lastPathComponent == "org.atgeo.describeService" })
    }

    @Test("returns the value unmodified with importance beside it")
    func unmodified() async throws {
        #expect(try await setup().client().place(origin: origin) == PlaceRecord(origin: origin, place: value, importance: 80))
    }

    @Test("returns a nil importance when the server gives none")
    func nilImportance() async throws {
        #expect(try await setup().client().place(origin: placeOrigin("r2")).importance == nil)
    }

    @Test("returns the same answer from the cache and the network")
    func cacheEqualsNetwork() async throws {
        let fake = try setup()
        let network = try await fake.client().place(origin: origin)
        let fresh = fake.client()
        _ = try await fresh.searchPlaces(region: .bbox(minLon: -122.40, minLat: 37.79, maxLon: -122.39, maxLat: 37.80))
        let before = fake.requests.count
        #expect(try await fresh.place(origin: origin) == network)
        #expect(fake.requests.count == before)
    }

    @Test("makes no request for the origin of a hit from an earlier search")
    func noRequestForAHit() async throws {
        let fake = try setup()
        let client = fake.client()
        let places = try await client.searchPlaces(region: .bbox(minLon: -122.40, minLat: 37.79, maxLon: -122.39, maxLat: 37.80)).places
        let before = fake.requests.count
        _ = try await client.place(origin: try #require(places.first?.origin))
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
        #expect(try await client.place(origin: "https://example.org/r/u")
                == PlaceRecord(origin: "https://example.org/r/u", place: uriOnly, importance: 4))
    }

    @Test("rejects an unknown origin with PlaceNotFound", arguments: [placeOrigin("nope"), "https://example.org/not-an-origin"])
    func placeNotFound(unknown: String) async throws {
        let client = try setup().client()
        do {
            _ = try await client.place(origin: unknown)
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
        ]))
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
        let result = try await setup().searchPlaces(region: Self.circle)
        let cafe = try #require(result.places.first { $0.origin == placeOrigin("cafe") })
        #expect(cafe.place == Self.records[0].value)
        #expect(cafe.place["importance"] == nil)
        #expect(cafe.importance == 2)
        #expect(abs(cafe.distance - 111.195) < 0.05)
        #expect(result.places.allSatisfy { $0.score == nil })
    }

    @Test("gives distance 0 to a bbox containing the center")
    func containingBox() async throws {
        #expect(try await setup().searchPlaces(region: Self.circle).places.first { $0.origin == placeOrigin("division") }?.distance == 0)
    }

    @Test("returns a numeric score with text")
    func scoreWithText() async throws {
        let result = try await setup().searchPlaces(region: Self.circle, text: "Zanzibar Cafe")
        let cafe = try #require(result.places.first { $0.origin == placeOrigin("cafe") })
        // vitest's toBeCloseTo(1, 2) is |diff| < 0.005.
        #expect(abs((cafe.score ?? 0) - 1) < 0.005)
        #expect(result.places.allSatisfy { $0.score != nil })
    }

    @Test("treats text that normalizes to empty as no text")
    func blankText() async throws {
        let client = try setup()
        let none = try await client.searchPlaces(region: Self.circle)
        let blank = try await client.searchPlaces(region: Self.circle, text: "   ")
        #expect(blank.places.count > 0)
        #expect(blank == none)
        #expect(blank.places.allSatisfy { $0.score == nil })
    }
}

@Suite("ordering among places containing the center") struct OrderingAmongContaining {
    private func ids(_ values: [(JSONObject, Int64?)], region: Region, text: String? = nil, sort: SortMode) async throws -> [String] {
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: values.map { record($0.0, importance: $0.1) })])])
        return try await server.client().searchPlaces(region: region, text: text, sort: sort).places
            .map { String(($0.origin ?? "").dropFirst(placeOrigin("").count)) }
    }

    @Test("puts the smaller box first when the center sits on the antimeridian seam")
    func seam() async throws {
        // Center is exactly (45, 180). The small box reaches it as lon -180 / 180.
        let small = place("small", "Small", [bboxLocation(north: 50, south: 40, east: -170, west: -180)])
        let large = place("large", "Large", [bboxLocation(north: 55, south: 35, east: -160, west: 160)])
        #expect(try await ids([(small, 1), (large, 9)], region: .bbox(minLon: 170, minLat: 40, maxLon: -170, maxLat: 50), sort: .distance)
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

    @Test("defaults to overturemaps.org / place when nothing is named")
    func defaults() async throws {
        let fake = try setup()
        _ = try await fake.client().searchPlaces(region: sfRegion)
        let first = try #require(fake.requests.first)
        #expect(param(first, "dataset") == "overturemaps.org")
        #expect(param(first, "collection") == "place")
    }

    @Test("takes overturemaps.org for a collection named alone")
    func collectionAlone() async throws {
        let fake = try setup()
        _ = try? await fake.client().searchPlaces(region: sfRegion, collection: "division")
        let first = try #require(fake.requests.first)
        #expect(param(first, "dataset") == "overturemaps.org")
        #expect(param(first, "collection") == "division")
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

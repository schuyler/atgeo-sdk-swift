import Foundation
import Testing
import Atgeo  // not @testable: everything here must be reachable from an app

// What an app does with the SDK's types outside a search: builds them for its own tests and previews,
// persists them, and shows their errors.

@Suite struct PublicAPITests {
    private let hit = SearchHit(
        origin: "urn:atgeo:overturemaps.org:place:1",
        place: ["name": .string("Reading Terminal Market"), "importance": .number(7)],
        importance: 7, distance: 120.5, score: 0.91)

    @Test func everyResultTypeCanBeBuiltOutsideTheModule() {
        let result = SearchResult(places: [hit], complete: true, overview: false, tiles: .init(fetched: 1, failed: 0))
        #expect(result.places.first?.origin == hit.origin)
        #expect(result.tileFailures.isEmpty)
        let failure = TileFailure(url: "https://tiles.example/0.json", kind: .status, status: 503,
                                  error: AtgeoError(code: "HttpError", message: "HTTP 503", status: 503))
        let partial = SearchResult(places: [], complete: false, overview: false, tiles: .init(fetched: 0, failed: 1),
                                   tileFailures: [failure])
        #expect(partial.tileFailures == [TileFailure(url: "https://tiles.example/0.json", kind: .status, status: 503, error: nil)])
        #expect(TileFailure.Kind(rawValue: "refused") == .refused && TileFailure.Kind.transport.rawValue == "transport")
        #expect(PlaceRecord(origin: "o", place: [:], importance: nil).origin == "o")

        let service = ServiceDescription(
            did: "did:web:places.atgeo.org",
            tilesets: [.init(slug: "osm", collections: [CollectionRef(dataset: "openstreetmap.org", collection: "way")])])
        #expect(service.tilesets.first?.collections.first?.collection == "way")

        let tileset = Tileset(
            slug: "osm",
            extent: .init(north: "1", south: "0", east: "1", west: "0"),
            collections: [CollectionInfo(dataset: "openstreetmap.org", collection: "way",
                                         categories: [.init(value: "cafe", count: 3)])],
            references: [CollectionAttribution(dataset: "overturemaps.org", collection: "division")])
        #expect(tileset.collections.first?.categories?.first?.count == 3)
        #expect(tileset.publishedAt == nil)
    }

    @Test func resultsRoundTripThroughJSON() throws {
        let result = SearchResult(places: [hit], complete: false, overview: true, tiles: .init(fetched: 2, failed: 1),
                                  tileFailures: [TileFailure(url: "https://t/1.json", kind: .decode, error: CocoaError(.coderReadCorrupt))])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.tileFailures.first?.error == nil)

        let record = PlaceRecord(origin: "o", place: ["name": .string("x"), "n": .null], importance: nil)
        #expect(try JSONDecoder().decode(PlaceRecord.self, from: JSONEncoder().encode(record)) == record)

        let unscored = SearchHit(origin: nil, place: [:], importance: nil, distance: 0, score: nil)
        #expect(try JSONDecoder().decode(SearchHit.self, from: JSONEncoder().encode(unscored)) == unscored)
    }

    // The parser reads 1e400 as infinity, as JSON.parse does; JSONEncoder cannot write it (README, Caching).
    @Test func aNonFiniteNumberInAPlaceDoesNotEncodeByDefault() {
        let record = PlaceRecord(origin: "o", place: ["big": .number(.infinity)], importance: nil)
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(record) }
    }

    @Test func errorsDescribeThemselves() {
        let error: any Error = AtgeoError(code: "PlaceNotFound", message: "no place with that uri", status: 404)
        #expect(error.localizedDescription == "no place with that uri (PlaceNotFound)")
        #expect("\(error)" == "AtgeoError(PlaceNotFound, HTTP 404): no place with that uri")

        let argument: any Error = AtgeoArgumentError.invalidRegion("invalid circle")
        #expect(argument.localizedDescription == "invalid circle")
        #expect(AtgeoArgumentError.similarityRequiresText.localizedDescription == "sort .similarity requires search text")
    }

    @Test func aSearchThroughAnAppsOwnTransport() async throws {
        struct Canned: HTTPTransport {
            func get(_ url: URL) async throws -> HTTPResponse {
                if url.path.hasSuffix("/org.atgeo.getTiles") {
                    return HTTPResponse(status: 200, body: Data(#"{"tiles":["https://tiles.example/0.json"]}"#.utf8))
                }
                return HTTPResponse(status: 200, body: Data(#"""
                {"records":[{"uri":"u","value":{"origin":"urn:atgeo:overturemaps.org:place:1","name":"Here",
                "locations":[{"$type":"community.lexicon.location.geo","latitude":"1","longitude":"1"}]}}],
                "attribution":[{"dataset":"overturemaps.org","collection":"place","licenses":["CDLA-Permissive-2.0"]}]}
                """#.utf8))
            }
        }
        let client = AtgeoClient(transport: Canned())
        let result = try await client.searchPlaces(region: .circle(lat: 1, lon: 1, radius: 10), dataset: "overturemaps.org", text: "here", collection: "place")
        #expect(result.places.map(\.origin) == ["urn:atgeo:overturemaps.org:place:1"])
        #expect(result.complete && result.tileFailures.isEmpty)
        // Attribution and the hit's collection, through nothing but the public API (contract §4.10, §8).
        #expect(result.attribution == [Attribution(dataset: "overturemaps.org", collection: "place", licenses: ["CDLA-Permissive-2.0"])])
        #expect(result.places.first?.collection == CollectionKey(dataset: "overturemaps.org", collection: "place"))
    }

    // `dataset` is required, so a search without one does not compile (contract §4.1); the labels are in the order the
    // spec gives. The empty string is a dataset like any other, and goes to the server.
    @Test func searchPlacesTakesTheDatasetAfterTheRegion() async throws {
        struct Recording: HTTPTransport {
            func get(_ url: URL) async throws -> HTTPResponse { HTTPResponse(status: 400, body: Data(#"{"error":"DatasetNotFound"}"#.utf8)) }
        }
        let client = AtgeoClient(transport: Recording())
        await #expect(throws: AtgeoError.self) {
            _ = try await client.searchPlaces(region: .circle(lat: 1, lon: 1, radius: 10), dataset: "", text: nil, collection: nil, sort: .fused)
        }
    }

    @Test func theNewFieldsCanBeBuiltAndRoundTripThroughJSON() throws {
        let entry = Attribution(dataset: "d", collection: "c", release: "r", source: "s", licenses: ["l"], attribution: "a")
        let hit = SearchHit(origin: "o", place: [:], importance: nil, distance: 1, score: nil, collection: CollectionKey(dataset: "d", collection: "c"))
        let result = SearchResult(places: [hit], complete: true, overview: false, tiles: .init(fetched: 1, failed: 0), attribution: [entry])
        #expect(try JSONDecoder().decode(SearchResult.self, from: JSONEncoder().encode(result)) == result)
        let record = PlaceRecord(origin: "o", place: [:], importance: 1, attribution: [entry])
        #expect(try JSONDecoder().decode(PlaceRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(ServiceDescription(did: nil, tilesets: [], maxTiles: 50).maxTiles == 50)
        #expect(Tileset(slug: nil, collections: [], overview: .init(records: 7)).overview?.records == 7)
        #expect(Region.bbox(west: 170, south: 10, east: -170, north: 20) != Region.bbox(west: -170, south: 10, east: 170, north: 20))
    }

    // Results encoded before attribution existed still decode, with none, as for tileFailures.
    @Test func resultsEncodedBeforeAttributionExistedStillDecode() throws {
        let old = Data(#"""
        {"places":[{"origin":"o","place":{},"distance":1}],"complete":true,"overview":false,"tiles":{"fetched":1,"failed":0}}
        """#.utf8)
        let result = try JSONDecoder().decode(SearchResult.self, from: old)
        #expect(result.attribution == [] && result.places.first?.collection == nil)
        let record = try JSONDecoder().decode(PlaceRecord.self, from: Data(#"{"origin":"o","place":{}}"#.utf8))
        #expect(record.attribution == [])
    }

    @Test func aSearchReportsItsFailedTiles() async throws {
        struct Failing: HTTPTransport {
            func get(_ url: URL) async throws -> HTTPResponse {
                if url.path.hasSuffix("/org.atgeo.getTiles") {
                    return HTTPResponse(status: 200, body: Data(#"{"tiles":["https://tiles.example/1.json","https://tiles.example/0.json","file:///x"]}"#.utf8))
                }
                if url.path == "/0.json" { throw URLError(.timedOut) }
                return HTTPResponse(status: 404, body: Data())
            }
        }
        let result = try await AtgeoClient(transport: Failing()).searchPlaces(region: .circle(lat: 1, lon: 1, radius: 10), dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures.map(\.url) == ["file:///x", "https://tiles.example/0.json", "https://tiles.example/1.json"])
        #expect(result.tileFailures.map(\.kind) == [.refused, .transport, .status])
        #expect(result.tileFailures.map(\.status) == [nil, nil, 404])
        #expect((result.tileFailures[1].error as? URLError)?.code == .timedOut)
        #expect(result.tiles.failed == 3 && !result.complete)
    }
}

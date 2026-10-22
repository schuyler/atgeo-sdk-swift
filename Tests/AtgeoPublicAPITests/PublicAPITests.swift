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
        let result = SearchResult(places: [hit], complete: false, overview: true, tiles: .init(fetched: 2, failed: 1))
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(SearchResult.self, from: data) == result)

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
                "locations":[{"$type":"community.lexicon.location.geo","latitude":"1","longitude":"1"}]}}]}
                """#.utf8))
            }
        }
        let client = AtgeoClient(transport: Canned())
        let result = try await client.searchPlaces(region: .circle(lat: 1, lon: 1, radius: 10), text: "here")
        #expect(result.places.map(\.origin) == ["urn:atgeo:overturemaps.org:place:1"])
    }
}

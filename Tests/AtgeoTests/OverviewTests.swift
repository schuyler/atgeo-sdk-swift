import Foundation
import Testing
@testable import Atgeo

// Port of test/overview.test.ts.

private let east = tileURL("east"), west = tileURL("west")
private let sfRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
private let tiles = [
    FakeTile(url: east, records: [record(place("e", "East", [point(37.773, -122.413)]))]),
    FakeTile(url: west, records: [record(place("w", "West", [point(37.772, -122.412)]))]),
]

private func setup(_ tilesFor: (@Sendable (String) -> TilesForAnswer)? = nil, failTiles: [String] = []) throws -> FakeServer {
    try FakeServer(tilesets: [overture(tiles)], tilesFor: tilesFor, failTiles: failTiles)
}

private func body(_ tiles: [String], overview: Bool? = nil) -> TilesForAnswer {
    var b: JSONObject = ["tiles": .array(tiles.map(JSONValue.string))]
    if let overview { b["overview"] = .bool(overview) }
    return .body(b)
}

@Suite("overview answers") struct OverviewAnswers {
    @Test("flags an overview answer whose tiles all load as overview and complete")
    func overviewComplete() async throws {
        let result = try await setup { _ in body([east, west], overview: true) }.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.overview)
        #expect(result.complete)
    }

    @Test("does not flag a regular answer with a failed tile")
    func regularWithFailure() async throws {
        let result = try await setup(failTiles: [west]).client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(!result.overview)
        #expect(!result.complete)
    }

    @Test("reads an answer without the key as regular")
    func noKey() async throws {
        #expect(try await setup { _ in body([east, west]) }.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place").overview == false)
    }

    @Test("keeps the flag when the tile-list cache answers")
    func cached() async throws {
        let server = try setup { _ in body([east, west], overview: true) }
        let client = server.client()
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        let second = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.getTilesRequests.count == 1)
        #expect(second.overview)
    }

    @Test("flags a split antimeridian search when only one half is overview")
    func oneHalf() async throws {
        let server = try setup { bbox in bbox.hasPrefix("170") ? body([east], overview: true) : body([west]) }
        #expect(try await server.client().searchPlaces(region: .bbox(west: 170, south: 10, east: -170, north: 20), dataset: "overturemaps.org", collection: "place").overview)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

// Port of test/transport.test.ts.

private let sfRegion = Region.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78)

private func twoTiles(failTiles: [String] = []) throws -> FakeServer {
    try FakeServer(tilesets: [overture([
        FakeTile(url: tileURL("a"), records: [record(place("a", "A", [point(37.772, -122.412)]))]),
        FakeTile(url: tileURL("b"), records: [record(place("b", "B", [point(37.774, -122.414)]))]),
    ])], failTiles: failTiles)
}

/// Fails one URL as a network error and passes everything else through.
private struct FlakyTransport: HTTPTransport {
    let base: FakeServer
    let failing: String
    func get(_ url: URL) async throws -> HTTPResponse {
        if url.absoluteString == failing { throw URLError(.networkConnectionLost) }
        return try await base.get(url)
    }
}

private func code(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch let e as AtgeoError { return e.code } catch { return "not AtgeoError: \(error)" }
}

@Suite("failed tiles") struct FailedTiles {
    @Test("reports a complete search")
    func complete() async throws {
        let result = try await twoTiles().client().searchPlaces(region: sfRegion)
        #expect(result.complete)
        #expect(result.tiles == .init(fetched: 2, failed: 0))
    }

    @Test("returns surviving results, marked incomplete, when a tile answers non-200")
    func non200() async throws {
        let result = try await twoTiles(failTiles: [tileURL("b")]).client().searchPlaces(region: sfRegion)
        #expect(!result.complete)
        #expect(result.tiles == .init(fetched: 1, failed: 1))
        #expect(result.places.map(\.origin) == [placeOrigin("a")])
    }

    @Test("returns an incomplete result when a tile fetch throws")
    func fetchThrows() async throws {
        let server = try twoTiles()
        let client = AtgeoClient(server: AtgeoClient.defaultServer, transport: FlakyTransport(base: server, failing: tileURL("a")),
                                 cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() })
        let result = try await client.searchPlaces(region: sfRegion)
        #expect(!result.complete)
        #expect(result.tiles == .init(fetched: 1, failed: 1))
        #expect(result.places.map(\.origin) == [placeOrigin("b")])
    }

    @Test("does not retry a failed tile")
    func noRetry() async throws {
        let server = try twoTiles(failTiles: [tileURL("b")])
        _ = try await server.client().searchPlaces(region: sfRegion)
        #expect(server.requestStrings.filter { $0 == tileURL("b") }.count == 1)
    }

    @Test("reports every tile failed without throwing")
    func allFailed() async throws {
        let result = try await twoTiles(failTiles: [tileURL("a"), tileURL("b")]).client().searchPlaces(region: sfRegion)
        #expect(result.places.isEmpty && !result.complete && result.tiles == .init(fetched: 0, failed: 2))
    }
}

@Suite("typed server errors") struct TypedServerErrors {
    @Test("surfaces BboxTooLarge from getTiles")
    func bboxTooLarge() async throws {
        let server = try FakeServer(tilesFor: { _ in .error(code: "BboxTooLarge", message: "bbox too large") })
        #expect(await code { _ = try await server.client().searchPlaces(region: sfRegion) } == "BboxTooLarge")
    }

    @Test("surfaces CollectionNotFound from getTiles")
    func collectionNotFound() async throws {
        let server = try FakeServer()
        #expect(await code { _ = try await server.client().searchPlaces(region: sfRegion, collection: "nope") } == "CollectionNotFound")
    }

    @Test("surfaces DatasetNotFound from getTiles")
    func datasetNotFound() async throws {
        let server = try FakeServer()
        #expect(await code { _ = try await server.client().searchPlaces(region: sfRegion, dataset: "example.org") } == "DatasetNotFound")
    }

    @Test("throws when either antimeridian half is BboxTooLarge", arguments: [("first", "170"), ("second", "-180")])
    func eitherHalf(half: String, prefix: String) async throws {
        let a = tileURL("a")
        let server = try FakeServer(
            tilesets: [overture([FakeTile(url: a, records: [record(place("a", "A", [point(15, 175)]))])])],
            tilesFor: { bbox in bbox.hasPrefix(prefix) ? .error(code: "BboxTooLarge", message: "too large") : .tiles([a]) })
        #expect(await code { _ = try await server.client().searchPlaces(region: .bbox(minLon: 170, minLat: 10, maxLon: -170, maxLat: 20)) } == "BboxTooLarge", "\(half) half")
    }

    @Test("does not subdivide after BboxTooLarge")
    func noSubdivision() async throws {
        let server = try FakeServer(tilesFor: { _ in .error(code: "BboxTooLarge", message: "too large") })
        _ = try? await server.client().searchPlaces(region: sfRegion)
        #expect(server.requests.count == 1)
    }
}

@Suite("XRPC URLs") struct XRPCURLs {
    @Test("defaults to places.atgeo.org")
    func defaultServer() async throws {
        let server = try twoTiles()
        _ = try await server.client().searchPlaces(region: sfRegion)
        let u = try #require(server.requests.first)
        #expect(originAndPath(u) == "\(AtgeoTests.defaultServer)/xrpc/org.atgeo.getTiles")
        #expect(param(u, "dataset") == "overturemaps.org")
        #expect(param(u, "collection") == "place")
        #expect(param(u, "bbox") == "-122.42,37.77,-122.41,37.78")
    }

    @Test("targets a custom server for every XRPC call", arguments: ["http://localhost:8000", "http://localhost:8000/", "http://localhost:8000//"])
    func customServer(configured: String) async throws {
        let base = "http://localhost:8000"
        let server = try FakeServer(server: base, tilesets: [overture([
            FakeTile(url: "\(base)/tiles/a.json", records: [record(place("a", "A", [point(37.772, -122.412)]))]),
        ])])
        let client = AtgeoClient(server: URL(string: configured)!, transport: server)
        _ = try await client.searchPlaces(region: sfRegion)
        _ = try await client.describeService()
        _ = try await client.describeTileset("overture-place")
        _ = try? await client.place(origin: placeOrigin("zzz"))
        let xrpc = server.requests.filter { $0.absoluteString.contains("/xrpc/") }.map(originAndPath)
        #expect(xrpc == [
            "\(base)/xrpc/org.atgeo.getTiles", "\(base)/xrpc/org.atgeo.describeService",
            "\(base)/xrpc/org.atgeo.describeTileset", "\(base)/xrpc/org.atgeo.getPlace",
        ])
        #expect(server.requestStrings.contains("\(base)/tiles/a.json"))
    }
}

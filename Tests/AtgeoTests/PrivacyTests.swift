import Foundation
import Testing
@testable import Atgeo

// Port of test/privacy.test.ts (contract §12). The HTTPTransport seam carries a URL and nothing else, so the
// method (GET) and the body (none) are fixed by construction, and the default transport's only header is
// checked in URLSessionTransportTests. These tests assert on every request URL, raw and percent-decoded.

private let tile = "https://tiles.example/t1.json"

private func setup() throws -> FakeServer {
    try FakeServer(tilesets: [overture([FakeTile(url: tile, records: [record(place("r1", "Zanzibar Quokka Cafe", [point(37.775, -122.418)]))])])])
}

/// Every request, lowercased, raw and percent-decoded (with + read as a space).
private func wire(_ requests: [URL]) -> [String] {
    requests.flatMap { url -> [String] in
        let raw = url.absoluteString
        let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        return [raw.lowercased(), decoded.lowercased()]
    }
}

@Suite("search text stays local") struct SearchTextStaysLocal {
    @Test("does not put the text on the wire", arguments: ["Zanzibar Quokka", "  ZANZIBÁR   quokka ", "Zanzibar"])
    func notOnTheWire(text: String) async throws {
        let server = try setup()
        _ = try await server.client().searchPlaces(region: .circle(lat: 37.7749295, lon: -122.4194155, radius: 500), dataset: "overturemaps.org", text: text, collection: "place")
        #expect(server.requests.count > 0)
        let normalized = "zanzibar quokka"
        let needles = [text.lowercased(), text.trimmingCharacters(in: .whitespaces).lowercased(), normalized]
            + normalized.split(separator: " ").map(String.init)
            + ["zanzib", "quokka", percentEncode(text).lowercased(), "zanzibar+quokka", "zanzib%c3%a1r"]
        for haystack in wire(server.requests) {
            for needle in needles where !needle.isEmpty { #expect(!haystack.contains(needle), "\(needle) in \(haystack)") }
        }
    }

    @Test("issues only getTiles and tile requests")
    func onlyGetTilesAndTiles() async throws {
        let server = try setup()
        _ = try await server.client().searchPlaces(region: .circle(lat: 37.7749295, lon: -122.4194155, radius: 500), dataset: "overturemaps.org", text: "Zanzibar Quokka", collection: "place")
        let kinds = server.requestStrings.map { $0.contains("/xrpc/org.atgeo.getTiles?") ? "tiles" : $0 == tile ? "tile" : $0 }
        #expect(kinds == ["tiles", "tile"])
    }

    @Test("sends only dataset, collection and bbox to getTiles")
    func onlyThreeParameters() async throws {
        let server = try setup()
        _ = try await server.client().searchPlaces(region: .bbox(west: -122.43, south: 37.77, east: -122.41, north: 37.78), dataset: "overturemaps.org", text: "Zanzibar Quokka", collection: "place")
        for url in server.getTilesRequests {
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
            #expect(names == ["dataset", "collection", "bbox"])
        }
    }
}

@Suite("precise coordinates stay local") struct CoordinatesStayLocal {
    @Test("keeps the circle centre off the wire")
    func circleCentre() async throws {
        let server = try setup()
        _ = try await server.client().searchPlaces(region: .circle(lat: 37.7749295, lon: -122.4194155, radius: 123.456789), dataset: "overturemaps.org", text: "Zanzibar Quokka", collection: "place")
        #expect(server.requests.count > 0)
        for h in wire(server.requests) {
            for needle in ["37.7749295", "122.4194155", "7749295", "4194155", "123.456789"] { #expect(!h.contains(needle), "\(needle) in \(h)") }
        }
    }

    @Test("keeps full-precision bbox corners off the wire")
    func bboxCorners() async throws {
        let server = try setup()
        _ = try await server.client().searchPlaces(region: .bbox(west: -122.4194155, south: 37.7749295, east: -122.4094155, north: 37.7849295), dataset: "overturemaps.org", collection: "place")
        #expect(server.requests.count > 0)
        for h in wire(server.requests) {
            for needle in ["7749295", "4194155", "4094155", "7849295"] { #expect(!h.contains(needle), "\(needle) in \(h)") }
        }
    }
}

@Suite("getPlace(origin:) on a cache miss sends the origin and nothing else") struct PlaceSendsOnlyTheOrigin {
    @Test func onlyTheOrigin() async throws {
        let server = try setup()
        _ = try await server.client().getPlace(origin: placeOrigin("r1"))
        let url = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["uri"])
        #expect(param(url, "uri") == placeOrigin("r1"))
    }
}

// Port of "failed tiles carry no search text" (contract §12): a failed-tile entry is built from the tile URL and what
// fetching it produced, nothing from the search text.
@Suite("failed tiles carry no search text") struct FailedTilesCarryNoText {
    /// Tile b answers a page that is not a tile, c throws, d answers 500 with a `null` body; a fails in the fake.
    private struct Breaking: HTTPTransport {
        var base: FakeServer
        var tiles: [String]
        func get(_ url: URL) async throws -> HTTPResponse {
            switch url.absoluteString {
            case tiles[1]: return HTTPResponse(status: 200, body: Data("<html>not a tile</html>".utf8))
            case tiles[2]: throw URLError(.cannotConnectToHost)
            case tiles[3]: return HTTPResponse(status: 500, body: Data("null".utf8))
            default: return try await base.get(url)
            }
        }
    }

    @Test func leavesEveryFormOfTheTextOutOfTileFailures() async throws {
        let tiles = ["a", "b", "c", "d"].map { "https://tiles.example/\($0).json" }
        let records = tiles.map { FakeTile(url: $0, records: [record(place("r1", "Zanzibar Quokka Cafe", [point(37.775, -122.418)]))]) }
        let server = try FakeServer(tilesets: [overture(records)], failTiles: [tiles[0]])
        let text = "  ZANZIBÁR   quokka "
        let result = try await AtgeoClient(server: URL(string: defaultServer)!, transport: Breaking(base: server, tiles: tiles))
            .searchPlaces(region: .circle(lat: 37.7749295, lon: -122.4194155, radius: 500), dataset: "overturemaps.org", text: text, collection: "place")
        #expect(result.tileFailures.map(\.kind) == [.status, .decode, .transport, .status])
        let haystack = result.tileFailures.map { f in
            [f.url, "\(f.kind)", f.status.map(String.init) ?? "", String(describing: f.error), f.error?.localizedDescription ?? "", "\(f)"]
                .joined(separator: "\u{1}")
        }.joined(separator: "\u{2}").lowercased()
        for needle in [text.lowercased(), text.trimmingCharacters(in: .whitespaces).lowercased(), "zanzibar quokka", "zanzib", "quokka"] {
            #expect(!haystack.contains(needle), "\(needle) in the failures")
        }
    }
}

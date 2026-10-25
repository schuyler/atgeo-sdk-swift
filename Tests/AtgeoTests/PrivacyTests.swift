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

@Suite("place(origin:) on a cache miss sends the origin and nothing else") struct PlaceSendsOnlyTheOrigin {
    @Test func onlyTheOrigin() async throws {
        let server = try setup()
        _ = try await server.client().place(origin: placeOrigin("r1"))
        let url = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["uri"])
        #expect(param(url, "uri") == placeOrigin("r1"))
    }
}

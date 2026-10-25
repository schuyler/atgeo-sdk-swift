import Foundation
import Testing
@testable import Atgeo

// Port of test/fakeServer.test.ts. The reference's rejections come from @atproto/lexicon; here the fake's
// own validation reproduces them, matching on the same words.

private let tile = "https://tiles.example/a.json"
private let ok = place("a", "Alpha", [point(37.772, -122.412)])

private func build(_ records: [JSONValue], slug: String? = "overture-place") throws -> FakeServer {
    var tileset = overture([FakeTile(url: tile, raw: records)])
    tileset.slug = slug
    return try FakeServer(tilesets: [tileset])
}

private func configurationError(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return String(describing: error) }
}

private func object(_ data: Data) throws -> JSONValue { try decodeJSON(data) }

@Suite("fake server configuration") struct FakeServerConfiguration {
    @Test("accepts a valid configuration")
    func acceptsValid() throws {
        _ = try build([wire(record(ok, importance: 3))])
    }

    @Test("rejects a record value missing its name")
    func rejectsNameless() {
        var nameless = ok
        nameless["name"] = nil
        #expect(configurationError { _ = try build([wire(record(nameless))]) }?.contains("name") == true)
    }

    @Test("rejects a tile record missing its value")
    func rejectsValueless() {
        #expect(configurationError { _ = try build([.object(["importance": .number(3)])]) }?.contains(#""value""#) == true)
    }

    @Test("rejects a float importance")
    func rejectsFloatImportance() {
        #expect(configurationError { _ = try build([.object(["value": .object(ok), "importance": .number(0.5)])]) }?.contains("integer") == true)
    }

    @Test("rejects a descriptor missing its slug")
    func rejectsSluglessDescriptor() {
        #expect(configurationError { _ = try build([], slug: nil) }?.contains("slug") == true)
    }
}

@Suite("fake server requests") struct FakeServerRequests {
    private func get(_ server: FakeServer, _ path: String) async throws -> HTTPResponse {
        try await server.get(URL(string: "https://places.atgeo.org\(path)")!)
    }

    @Test("answers 400 InvalidRequest to getTiles without a dataset")
    func getTilesWithoutDataset() async throws {
        let response = try await get(try build([wire(record(ok))]), "/xrpc/org.atgeo.getTiles?bbox=-122.42,37.77,-122.41,37.78")
        #expect(response.status == 400)
        #expect(try object(response.body)["error"] == .string("InvalidRequest"))
    }

    @Test("answers 400 InvalidRequest to getPlace with a non-URI uri")
    func getPlaceWithNonURI() async throws {
        let response = try await get(try build([wire(record(ok))]), "/xrpc/org.atgeo.getPlace?uri=not%20a%20uri")
        #expect(response.status == 400)
    }

    @Test("serves tile bodies with publishedAt, attribution and records")
    func tileBodies() async throws {
        let body = try object(try await build([wire(record(ok, importance: 3))]).get(URL(string: tile)!).body)
        #expect(body.objectValue?.keys.sorted() == ["attribution", "publishedAt", "records"])
        #expect(body["records"] == .array([.object(["value": .object(ok), "importance": .number(3)])]))
    }

    @Test("answers getPlace with exactly uri, url, importance, value and attribution")
    func getPlaceShape() async throws {
        let origin = try #require(ok["origin"]?.stringValue)
        let path = "/xrpc/org.atgeo.getPlace?uri=\(origin)"
        let body = try object(try await get(try build([wire(record(ok, importance: 3))]), path).body)
        #expect(body.objectValue?.keys.sorted() == ["attribution", "importance", "uri", "url", "value"])
        #expect(body["uri"] == .string(origin))
        let bare = try object(try await get(try build([wire(record(ok))]), path).body)
        #expect(bare.objectValue?.keys.sorted() == ["attribution", "uri", "url", "value"])
    }

    @Test("emits a tileset's overview in its descriptor")
    func overviewInDescriptor() async throws {
        var tileset = overture([])
        tileset.overview = ["records": .number(7)]
        let body = try object(try await get(try FakeServer(tilesets: [tileset]), "/xrpc/org.atgeo.describeTileset?slug=overture-place").body)
        #expect(body["overview"] == .object(["records": .number(7)]))
    }

    @Test("answers describeService with a did and tilesets")
    func describeService() async throws {
        let body = try object(try await get(try build([]), "/xrpc/org.atgeo.describeService").body)
        #expect(body == .object([
            "did": .string("did:web:places.atgeo.org"),
            "maxTiles": .number(50),
            "tilesets": .array([.object([
                "slug": .string("overture-place"),
                "collections": .array([.object(["dataset": .string("overturemaps.org"), "collection": .string("place")])]),
            ])]),
        ]))
    }
}

/// Checks on the test doubles themselves, which have no reference counterpart.
@Suite struct TestDoubleTests {
    // Design review finding 2: a raw + would be read as a space by a form-decoding server, and the fake is one.
    @Test func theFakeFormDecodesAPlus() async throws {
        let server = try FakeServer()
        let raw = try await server.get(URL(string: "https://places.atgeo.org/xrpc/org.atgeo.describeTileset?slug=overture+place")!)
        #expect(try object(raw.body)["message"] == .string("Tileset overture place not found"))
        let encoded = try await server.get(URL(string: "https://places.atgeo.org/xrpc/org.atgeo.describeTileset?slug=overture%2Bplace")!)
        #expect(try object(encoded.body)["message"] == .string("Tileset overture+place not found"))
    }

    @Test func theFakeRejectsUnknownAndRepeatedParameters() async throws {
        let server = try FakeServer()
        for path in ["/xrpc/org.atgeo.describeService?q=coffee", "/xrpc/org.atgeo.getPlace?uri=a:b&uri=a:c",
                     "/xrpc/org.atgeo.getTiles?dataset=d&bbox=-122.4194155,37.77,-122.41,37.78"] {
            let response = try await server.get(URL(string: "https://places.atgeo.org\(path)")!)
            #expect(try object(response.body)["error"] == .string("InvalidRequest"), "\(path)")
        }
    }

    @Test func delayingTransportCountsRequestsInFlight() async throws {
        let server = try FakeServer()
        let delaying = DelayingTransport(server) { _ in 0.05 }
        let url = URL(string: "https://places.atgeo.org/xrpc/org.atgeo.describeService")!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try await delaying.get(url) } }
            try await group.waitForAll()
        }
        #expect(delaying.peakInFlight == 3)
        #expect(server.requests.count == 3)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

// Port of test/transport.test.ts.

private let sfRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)

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

private func status(_ body: () async throws -> Void) async -> Int? {
    do { try await body(); return nil } catch let e as AtgeoError { return e.status } catch { return nil }
}

@Suite("failed tiles") struct FailedTiles {
    @Test("reports a complete search")
    func complete() async throws {
        let result = try await twoTiles().client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.complete)
        #expect(result.tiles == .init(fetched: 2, failed: 0))
    }

    @Test("returns surviving results, marked incomplete, when a tile answers non-200")
    func non200() async throws {
        let result = try await twoTiles(failTiles: [tileURL("b")]).client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(!result.complete)
        #expect(result.tiles == .init(fetched: 1, failed: 1))
        #expect(result.places.map(\.origin) == [placeOrigin("a")])
    }

    @Test("returns an incomplete result when a tile fetch throws")
    func fetchThrows() async throws {
        let server = try twoTiles()
        let client = AtgeoClient(server: AtgeoClient.defaultServer, transport: FlakyTransport(base: server, failing: tileURL("a")),
                                 cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() })
        let result = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(!result.complete)
        #expect(result.tiles == .init(fetched: 1, failed: 1))
        #expect(result.places.map(\.origin) == [placeOrigin("b")])
    }

    @Test("does not retry a failed tile")
    func noRetry() async throws {
        let server = try twoTiles(failTiles: [tileURL("b")])
        _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requestStrings.filter { $0 == tileURL("b") }.count == 1)
    }

    @Test("reports every tile failed without throwing")
    func allFailed() async throws {
        let result = try await twoTiles(failTiles: [tileURL("a"), tileURL("b")]).client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.places.isEmpty && !result.complete && result.tiles == .init(fetched: 0, failed: 2))
    }
}

@Suite("typed server errors") struct TypedServerErrors {
    @Test("surfaces BboxTooLarge from getTiles")
    func bboxTooLarge() async throws {
        let server = try FakeServer(tilesFor: { _ in .error(code: "BboxTooLarge", message: "bbox too large") })
        #expect(await code { _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place") } == "BboxTooLarge")
        #expect(await status { _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place") } == 400)
    }

    @Test("carries the HTTP status, whatever the body says", arguments: [
        (404, #"{"error":"PlaceNotFound"}"#),
        (429, ""),
        (503, #"{"error":"InvalidRequest","message":"a 5xx with a 4xx-sounding code"}"#),
    ])
    func carriesStatus(status expected: Int, body: String) async throws {
        let server = try FakeServer(rawBodies: [
            "\(defaultServer)/xrpc/org.atgeo.getPlace": HTTPResponse(status: expected, body: Data(body.utf8)),
        ])
        #expect(await status { _ = try await server.client().place(origin: placeOrigin("x")) } == expected)
    }

    @Test("surfaces CollectionNotFound from getTiles")
    func collectionNotFound() async throws {
        let server = try FakeServer()
        #expect(await code { _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "nope") } == "CollectionNotFound")
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
        #expect(await code { _ = try await server.client().searchPlaces(region: .bbox(west: 170, south: 10, east: -170, north: 20), dataset: "overturemaps.org", collection: "place") } == "BboxTooLarge", "\(half) half")
    }

    @Test("does not subdivide after BboxTooLarge")
    func noSubdivision() async throws {
        let server = try FakeServer(tilesFor: { _ in .error(code: "BboxTooLarge", message: "too large") })
        _ = try? await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requests.count == 1)
    }
}

@Suite("XRPC URLs") struct XRPCURLs {
    @Test("defaults to places.atgeo.org")
    func defaultServer() async throws {
        let server = try twoTiles()
        _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
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
        _ = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
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

// Contract §4.4: a tile URL that is not an absolute http or https URL, or that carries credentials, is a failed
// tile with no request. Before the check, every one of these reached the transport (the fake records them);
// the default transport on Linux threw URLError(.unsupportedURL) for file: and ftp:, and sent the credentials
// as Authorization: Basic, an empty userinfo as `Basic Og==`.
@Suite("refused tile URLs") struct RefusedTileURLs {
    @Test("reads http and https URLs as the Rust and Python ports do")
    func classifies() {
        for ok in ["https://h", "HTTP://h/x", "hTtPs://h/x", "http://h:80/x@y", "http://[::1]:8000/x", "https://h?q",
                   "https://h#f", "http://h:65535/x", "http://h:/x", "http://h:00080/x", "http://[::ffff:1.2.3.4]/x",
                   "https://h\\x/y", "https://h/x\\y@z"] {
            #expect(isHTTPURL(ok), "\(ok)")
        }
        for bad in ["", "h/x", "/x", "x.json", "ftp://h/x", "file:///etc/passwd", "https:///x", "https://", "http://u@/x",
                    "https:h", "http://[]/x", "http://:80/x", "javascript://h/x", "httpx://h/x", " https://h/x",
                    "http://u:p@h:80/x", "https://u@h/x", "https://:p@h", "https://@h/x", "https://u:p@[::1]/x",
                    // Foundation does not end the authority at a backslash, so an @ after one is a userinfo there.
                    "https://h\\@x/y", "https://h\\%FF@x/y", "https://h\\x@y/z",
                    "https:/h/x", "https:\\\\h\\x", "http://h:65536/x", "http://h:99999/x", "http://h:8a/x", "http://h:-1/x",
                    "http://h%41/x", "http://h%00/x", "http://[zz]/x", "http://[::1/x", "http://[::1]x/y"] {
            #expect(!isHTTPURL(bad), "\(bad)")
        }
    }

    @Test("trims as WHATWG URL parsing does")
    func trims() {
        #expect(trimmedLikeWHATWG(" \u{0}\t https://h/x \n\u{1F}") == "https://h/x")
        #expect(trimmedLikeWHATWG("https://h/\ta\nb\rc") == "https://h/abc")
        #expect(trimmedLikeWHATWG("https://h/a b") == "https://h/a b")
        #expect(trimmedLikeWHATWG(" \u{1} ") == "")
    }

    @Test("fails the tile without a request", arguments: [
        "/tiles/a.json", "a.json", "file:///etc/hostname", "ftp://tiles.example/a.json",
        "https://user:pw@tiles.example/a.json", "https://user@tiles.example/a.json", "https://@tiles.example/a.json",
        "HTTPS://user:pw@tiles.example/a.json", "https://u:p@[::1]:8000/a.json",
        // Foundation reads this as user `tiles.example\` at host evil.example; WHATWG as host tiles.example.
        "https://tiles.example\\@evil.example/a.json",
        // Foundation reads user `tiles.example%5C%FF`, which URL.user cannot decode and so reports as nil.
        "https://tiles.example\\%FF@evil.example/a.json",
        "https:/tiles.example/a.json", "https:\\\\tiles.example\\a.json",
        "https://tiles.example:65536/a.json", "https://tiles%2Eexample/a.json", "http://[zz]/a.json",
        // Non-ASCII that IDNA's NFKC maps to a delimiter, which WHATWG then refuses in a host.
        "http://localhost\u{2100}x/y", "https://tiles.example\u{FF1A}8080/a.json", "https://tiles.example\u{FF1A}99999/a.json",
        "https://tiles\u{FF05}40example/a.json", "https://u\u{FF05}3Apw\u{FF05}40evil.example/a.json",
        "https://tiles.example\u{FF03}x/a.json", "https://u\u{FF20}tiles.example/a.json", "https://u\u{FE6B}tiles.example/a.json",
        "https:tiles.example/a.json", "https:///a.json",
    ])
    func refused(_ tile: String) async throws {
        let server = try FakeServer(tilesFor: { _ in .tiles([tile, tileURL("a")]) })
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 0, failed: 2))   // the fake has no tile a
        #expect(server.requestStrings.filter { !$0.contains("/xrpc/") } == [tileURL("a")])
    }

    @Test("fetches an uppercase scheme through the default transport, with the scheme lowercased")
    func uppercaseScheme() async throws {
        let ports = PortBox()
        let server = try Loopback { request in
            guard request.path.contains("getTiles") else {
                return .init(status: 200, body: Data(#"{"records":[{"value":{"origin":"urn:atgeo:overturemaps.org:place:a","name":"A","locations":[{"$type":"community.lexicon.location.geo","latitude":"37.772","longitude":"-122.412"}]}}]}"#.utf8))
            }
            return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["tiles": ["HTTP://127.0.0.1:\(ports.port)/a.json"]]))
        }
        ports.port = server.port
        let result = try await AtgeoClient(server: URL(string: "http://127.0.0.1:\(server.port)")!).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 1, failed: 0))
        #expect(result.tileFailures.isEmpty)
        #expect(result.places.map(\.origin) == [placeOrigin("a")])
        #expect(tileRequestURL("HTTPS://tiles.example/a.json")?.absoluteString == "https://tiles.example/a.json")
    }

    @Test("lowercases only the scheme, even before a combining mark")
    func lowercasesOnlyTheScheme() {
        #expect(withLowercaseScheme("HTTP://\u{34F}LOCALHOST:18090/A") == "http://\u{34F}LOCALHOST:18090/A")
        #expect(withLowercaseScheme("HTTP://\u{34F}LOCALHOST:18090/A/B?Q=http://Y") == "http://\u{34F}LOCALHOST:18090/A/B?Q=http://Y")
        #expect(withLowercaseScheme("HtTpS://H/X") == "https://H/X")
    }

    @Test("fetches an uppercase scheme before a combining mark, with only the scheme lowercased")
    func uppercaseSchemeBeforeACombiningMark() async throws {
        let ports = PortBox()
        let server = try Loopback { request in
            guard request.path.contains("getTiles") else { return .init(status: 200, body: Data(#"{"records":[]}"#.utf8)) }
            let tile = "HTTP://\u{34F}127.0.0.1:\(ports.port)/A/B?Q=http://Y"
            return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["tiles": [tile]]))
        }
        ports.port = server.port
        let result = try await AtgeoClient(server: URL(string: "http://127.0.0.1:\(server.port)")!).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 1, failed: 0), "\(result.tileFailures.map { "\($0.kind) \(String(describing: $0.error))" })")
        #expect(server.received.filter { !$0.path.contains("/xrpc/") }.map(\.path) == ["/A/B?Q=http://Y"])
    }

    @Test("fetches an IPv6 host", arguments: ["http://[::1]:8000/a.json"])
    func accepted(_ tile: String) async throws {
        let server = try FakeServer(tilesets: [overture([
            FakeTile(url: tile, records: [record(place("a", "A", [point(37.772, -122.412)]))]),
        ])])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 1, failed: 0))
        #expect(result.places.map(\.origin) == [placeOrigin("a")])
        #expect(server.requestStrings.filter { !$0.contains("/xrpc/") } == [tile])
    }

    @Test("refuses a host NFKC maps to a delimiter in the string check alone")
    func nfkc() {
        for bad in ["http://localhost\u{2100}x/y", "https://h\u{FF1A}8080/y", "https://h\u{FF05}40x/y", "https://h\u{FF03}x/y",
                    "https://u\u{FF20}h/x", "https://u\u{FE6B}h/x"] {
            #expect(!isHTTPURL(bad), "\(bad)")
        }
        #expect(isHTTPURL("https://b\u{FC}cher.example/x"))
    }

    @Test("reads a bracketed host as WHATWG's IPv6 parser does")
    func ipv6() {
        for ok in ["::", "::1", "1::", "1:2:3:4:5:6:7:8", "1::8", "::ffff:1.2.3.4", "1:2:3:4:5:6:1.2.3.4", "fe80::1:2", "1:2:3:4:5:6:7::", "::1:2:3:4:5:6:7"] {
            #expect(isIPv6Literal(ok), "\(ok)")
        }
        for bad in ["", "a", "127.0.0.1", ":::1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::", "::g",
                    "::1.2.3", "::1.2.3.256", "::01.2.3.4", "1:2:3:4:5:6:7:1.2.3.4", "1.2.3.4::", ":1::2", "1::2:"] {
            #expect(!isIPv6Literal(bad), "\(bad)")
        }
        #expect(!isHTTPURL("http://[127.0.0.1]/x") && !isHTTPURL("http://[a]/x") && !isHTTPURL("http://[:::1]/x"))
    }

    @Test("refuses a host holding a code point Foundation drops or maps where WHATWG refuses or maps otherwise",
          arguments: [0x1E9E, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x1D173, 0x1D17A, 0x2061, 0x2063, 0x2065, 0x206F,
                      0x3164, 0xFFA0, 0x200C, 0x200F] as [UInt32])
    func ignorables(_ cp: UInt32) {
        #expect(!isHTTPURL("https://a\(Character(Unicode.Scalar(cp)!))b.example/x"), "U+\(String(cp, radix: 16))")
    }

    @Test("keeps a host holding a code point both WHATWG and Foundation drop", arguments: [0x200B, 0x2060, 0x2064, 0xFEFF, 0xAD, 0x34F] as [UInt32])
    func droppedByBoth(_ cp: UInt32) {
        #expect(tileRequestURL("https://a\(Character(Unicode.Scalar(cp)!))b.example/x")?.host == "ab.example", "U+\(String(cp, radix: 16))")
    }

    @Test("Foundation's own reading refuses what the string check would have caught first")
    func defenceInDepth() throws {
        // URLs the string check refuses, given straight to the checks behind it.
        for s in ["https://u:p@h/x", "https://u@h/x", "https://h%5C%FF@x/y", "ftp://h/x", "http:///x"] {
            if let url = URL(string: s) { #expect(!passesFoundationChecks(url), "\(s)") }
        }
        #if canImport(FoundationNetworking)
        // Linux reads the host as `localhosta/cx`, which does not parse back to itself.
        let mapped = try #require(URL(string: "http://localhost\u{2100}x/y"))
        #expect(!passesFoundationChecks(mapped))
        #endif
        // Apple's Foundation returns nil for it (CI's macos-latest, macOS and iOS simulator), or reads host `localhosta`, path `/cx/y`,
        // consistently (macOS 14); there only the string check refuses it. Every platform refuses it in the end.
        #expect(tileRequestURL("http://localhost\u{2100}x/y") == nil)
        #expect(passesFoundationChecks(try #require(URL(string: "https://h:8080/x"))))
    }

    @Test("fetches an IDN host in punycode, as before")
    func idn() async throws {
        let server = try FakeServer(tilesFor: { _ in .tiles(["https://b\u{FC}cher.example/a.json"]) })
        _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requestStrings.filter { !$0.contains("/xrpc/") } == ["https://xn--bcher-kva.example/a.json"])
    }

    @Test("fetches a URL with surrounding spaces and controls trimmed, as fetch does")
    func trimmedFetch() async throws {
        let server = try FakeServer(tilesFor: { _ in .tiles([" \t\(tileURL("a"))\n"]) })
        _ = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(server.requestStrings.filter { !$0.contains("/xrpc/") } == [tileURL("a")])
    }

    @Test("sends no credentials through the default transport")
    func defaultTransport() async throws {
        let ports = PortBox()
        let server = try Loopback { request in
            guard request.path.contains("getTiles") else { return .init(status: 200, body: Data(#"{"records":[]}"#.utf8)) }
            let p = ports.port
            let tiles = ["http://user:pw@127.0.0.1:\(p)/cred.json", "http://@127.0.0.1:\(p)/empty.json",
                         "http://h\\%FF@127.0.0.1:\(p)/undecodable.json", "http://127.0.0.1:\(p)/ok.json"]
            return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["tiles": tiles]))
        }
        ports.port = server.port
        let result = try await AtgeoClient(server: URL(string: "http://127.0.0.1:\(server.port)")!).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 1, failed: 3))
        #expect(server.received.filter { !$0.path.contains("/xrpc/") }.map(\.path) == ["/ok.json"])
        #expect(server.received.allSatisfy { !$0.headers.contains { $0.name.lowercased() == "authorization" } })
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0
    var port: UInt16 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

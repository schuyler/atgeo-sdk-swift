import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

// Contract §4.4: each failed tile is reported in `tileFailures`, with its kind, in tile URL order.

private let sfRegion = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)

private func tile(_ name: String, at lat: Double = 37.772) -> FakeTile {
    FakeTile(url: tileURL(name), records: [record(place(name, name.uppercased(), [point(lat, -122.412)]))])
}

/// Throws `error` for the URLs in `failing` and passes everything else to the fake.
private struct ThrowingTransport: HTTPTransport {
    let base: FakeServer
    let failing: Set<String>
    let error: any Error
    func get(_ url: URL) async throws -> HTTPResponse {
        if failing.contains(url.absoluteString) { throw error }
        return try await base.get(url)
    }
}

/// Holds the tile URLs in `held` until the task is cancelled, then answers them 200 with a body that is not
/// JSON: a decode failure that arises after cancellation.
private struct HoldThenGarbage: HTTPTransport {
    let base: FakeServer
    let held: String
    func get(_ url: URL) async throws -> HTTPResponse {
        guard url.absoluteString == held else { return try await base.get(url) }
        _ = try await base.get(url)  // recorded, so the test can see it is in flight
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return HTTPResponse(status: 200, body: Data("not json".utf8))
    }
}

private func client(_ transport: any HTTPTransport) -> AtgeoClient {
    AtgeoClient(server: URL(string: defaultServer)!, transport: transport,
                cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() })
}

@Suite("tile failures") struct TileFailureTests {
    @Test("are empty for a search where every tile loads")
    func emptyOnSuccess() async throws {
        let result = try await FakeServer(tilesets: [overture([tile("a"), tile("b")])]).client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures.isEmpty && result.complete && result.tiles == .init(fetched: 2, failed: 0))
    }

    @Test("report a refused URL without a request")
    func refused() async throws {
        let server = try FakeServer(tilesFor: { _ in .tiles(["file:///etc/hostname"]) })
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures == [TileFailure(url: "file:///etc/hostname", kind: .refused, error: nil)])
        #expect((result.tileFailures.first?.error as? URLError)?.code == .unsupportedURL)
        #expect(server.requests.count == 1)
    }

    @Test("report a non-2xx answer with its status and AtgeoError")
    func status() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a"), tile("b")])], failTiles: [tileURL("b")])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures == [TileFailure(url: tileURL("b"), kind: .status, status: 500, error: nil)])
        let error = try #require(result.tileFailures.first?.error as? AtgeoError)
        #expect(error == AtgeoError(code: "HttpError", message: "HTTP 500", status: 500))
    }

    @Test("report a 2xx body that is not a tile payload as decode", arguments: [
        "not json", "[]", #"{"records":5}"#, "{}",
        String(repeating: "[", count: 600) + String(repeating: "]", count: 600),  // deeper than the parser's 512
    ])
    func decode(_ body: String) async throws {
        let server = try FakeServer(
            tilesFor: { _ in .tiles([tileURL("a")]) },
            rawBodies: [tileURL("a"): HTTPResponse(status: 200, body: Data(body.utf8))])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures == [TileFailure(url: tileURL("a"), kind: .decode, error: nil)])
        #expect(result.tileFailures.first?.error != nil)
    }

    @Test("report whatever the transport throws as transport, an AtgeoError included")
    func transport() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a"), tile("b")])])
        let lost = try await client(ThrowingTransport(base: server, failing: [tileURL("a")], error: URLError(.networkConnectionLost)))
            .searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(lost.tileFailures == [TileFailure(url: tileURL("a"), kind: .transport, error: nil)])
        #expect((lost.tileFailures.first?.error as? URLError)?.code == .networkConnectionLost)

        // An app's transport may throw an AtgeoError of its own; it is still where the failure arose that counts.
        let thrown = AtgeoError(code: "Proxy", message: "blocked", status: 403)
        let app = try await client(ThrowingTransport(base: server, failing: [tileURL("a")], error: thrown)).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(app.tileFailures == [TileFailure(url: tileURL("a"), kind: .transport, error: nil)])
        #expect(app.tileFailures.first?.status == nil)
        #expect(app.tileFailures.first?.error as? AtgeoError == thrown)
    }

    @Test("report a cached tile that fails to parse again as decode, without a request")
    func cachedReparse() async throws {
        let server = try FakeServer(tilesFor: { _ in .tiles([tileURL("a")]) })
        let client = server.client()
        await client.cacheUnparsedTile(tileURL("a"), body: Data("not json".utf8))
        let result = try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures == [TileFailure(url: tileURL("a"), kind: .decode, error: nil)])
        #expect(result.tileFailures.first?.error != nil)
        #expect(result.tiles == .init(fetched: 0, failed: 1))
        #expect(server.requestStrings.filter { !$0.contains("/xrpc/") }.isEmpty)
    }

    @Test("come in tile URL order, whatever order they completed in")
    func urlOrder() async throws {
        let refused = "ftp://tiles.example/0.json"
        let server = try FakeServer(
            tilesets: [overture([tile("a"), tile("b"), tile("c"), tile("d"), tile("e")])],
            tilesFor: { _ in .tiles([tileURL("e"), tileURL("d"), tileURL("c"), tileURL("b"), tileURL("a"), refused]) },
            failTiles: [tileURL("d")],
            rawBodies: [tileURL("b"): HTTPResponse(status: 200, body: Data("{".utf8))])
        // a is slowest and e fastest, so completion order is the reverse of URL order.
        let delays: [String: TimeInterval] = [tileURL("a"): 0.3, tileURL("b"): 0.2, tileURL("d"): 0.1]
        let flaky = ThrowingTransport(base: server, failing: [tileURL("a")], error: URLError(.timedOut))
        let transport = DelayingTransport(flaky, delay: { delays[$0.absoluteString] })
        let result = try await client(transport).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures == [
            TileFailure(url: refused, kind: .refused, error: nil),
            TileFailure(url: tileURL("a"), kind: .transport, error: nil),
            TileFailure(url: tileURL("b"), kind: .decode, error: nil),
            TileFailure(url: tileURL("d"), kind: .status, status: 500, error: nil),
        ])
        #expect(result.tiles == .init(fetched: 2, failed: result.tileFailures.count))
        #expect(!result.complete)
        #expect(result.places.compactMap(\.origin).sorted() == [placeOrigin("c"), placeOrigin("e")])
    }

    @Test("are not reported by a cancelled search, which throws instead")
    func cancelled() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a")])])
        let client = client(HoldThenGarbage(base: server, held: tileURL("a")))
        let task = Task { try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place") }
        let deadline = Date().addingTimeInterval(30)
        while !server.requestStrings.contains(tileURL("a")) && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        switch await task.result {
        case .success(let r): Issue.record("expected an error, got a result with failures \(r.tileFailures)")
        // The tile's own error, as in the reference: the body failed to parse after the search was cancelled.
        case .failure(let error): #expect(!(error is CancellationError) && !(error is URLError), "\(error)")
        }
    }
}

/// Records what the client logs.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TileFailure] = []
    var logged: [TileFailure] { lock.withLock { entries } }
    func record(_ failure: TileFailure) { lock.withLock { entries.append(failure) } }
}

private func client(_ transport: any HTTPTransport, log: LogSink) -> AtgeoClient {
    AtgeoClient(server: URL(string: defaultServer)!, transport: transport,
                cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() }, log: log.record)
}

@Suite("tile failure logging") struct TileFailureLogTests {
    @Test("logs each failure once, in URL order, when the search returns")
    func logsInURLOrder() async throws {
        let server = try FakeServer(
            tilesets: [overture([tile("a"), tile("b"), tile("c")])],
            tilesFor: { _ in .tiles([tileURL("c"), tileURL("b"), tileURL("a"), "ftp://tiles.example/0.json"]) },
            failTiles: [tileURL("c"), tileURL("a")])
        let delays: [String: TimeInterval] = [tileURL("a"): 0.2]
        let sink = LogSink()
        let result = try await client(DelayingTransport(server, delay: { delays[$0.absoluteString] }), log: sink)
            .searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(result.tileFailures.count == 3)
        #expect(sink.logged == result.tileFailures)
    }

    @Test("logs nothing for a search that succeeds")
    func nothingOnSuccess() async throws {
        let sink = LogSink()
        _ = try await client(try FakeServer(tilesets: [overture([tile("a")])]), log: sink).searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place")
        #expect(sink.logged.isEmpty)
    }

    @Test("logs nothing for a cancelled search, even for tiles that failed before the cancel")
    func nothingWhenCancelled() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a"), tile("b")])], failTiles: [tileURL("a")])
        let sink = LogSink()
        let client = client(HoldThenGarbage(base: server, held: tileURL("b")), log: sink)
        let task = Task { try await client.searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "place") }
        let deadline = Date().addingTimeInterval(30)
        while !(server.requestStrings.contains(tileURL("a")) && server.requestStrings.contains(tileURL("b"))) && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)  // tile a's failure has been collected
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(sink.logged.isEmpty)
    }
}

@Suite("TileFailure values") struct TileFailureValueTests {
    @Test("are equal whatever their errors")
    func equalityIgnoresError() {
        let a = TileFailure(url: "https://t/a", kind: .transport, error: URLError(.timedOut))
        #expect(a == TileFailure(url: "https://t/a", kind: .transport, error: nil))
        #expect(a != TileFailure(url: "https://t/b", kind: .transport, error: nil))
        #expect(a != TileFailure(url: "https://t/a", kind: .decode, error: nil))
        #expect(TileFailure(url: "u", kind: .status, status: 500, error: nil) != TileFailure(url: "u", kind: .status, status: 502, error: nil))
        // URLs compare by UTF-16 code units, not by canonical equivalence.
        #expect(TileFailure(url: "https://t/\u{E9}", kind: .decode, error: nil) != TileFailure(url: "https://t/e\u{301}", kind: .decode, error: nil))
    }

    @Test("round-trip through JSON without their errors")
    func codable() throws {
        let failures = [
            TileFailure(url: "https://t/a", kind: .status, status: 503, error: AtgeoError(code: "HttpError", message: "HTTP 503", status: 503)),
            TileFailure(url: "https://t/b", kind: .transport, error: URLError(.timedOut)),
        ]
        let result = SearchResult(places: [], complete: false, overview: false, tiles: .init(fetched: 0, failed: 2), tileFailures: failures)
        let data = try JSONEncoder().encode(result)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(json["tileFailures"] as? [[String: Any]])
        #expect(encoded.map { $0.keys.sorted() } == [["kind", "status", "url"], ["kind", "url"]])
        #expect(encoded.first?["kind"] as? String == "status")
        let decoded = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.tileFailures.allSatisfy { $0.error == nil })
    }

    @Test("a result encoded before tileFailures existed decodes with none")
    func decodesOlderResults() throws {
        let old = #"{"places":[],"complete":false,"overview":true,"tiles":{"fetched":1,"failed":1}}"#
        let decoded = try JSONDecoder().decode(SearchResult.self, from: Data(old.utf8))
        #expect(decoded == SearchResult(places: [], complete: false, overview: true, tiles: .init(fetched: 1, failed: 1)))
        #expect(decoded.tileFailures.isEmpty)
    }
}

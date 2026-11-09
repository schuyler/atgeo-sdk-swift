import Foundation
import Testing
@testable import Atgeo

// Port of test/autocomplete.test.ts: the autocompleter's skips, its supersession and its handling of the caller's
// own cancellation (contract §11, §17, §19), and section 12, item 8.

private let dataset = "overturemaps.org"
private let nothing = KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: false, region: nil))
private let tiles = [
    FakeTile(url: tileURL("p"), records: [record(place("zc", "Zanzibar Cafe", [point(37.775, -122.418)]), importance: 5)]),
]

private func setup() throws -> (FakeServer, AtgeoClient) {
    let server = try FakeServer(tilesets: [overture(tiles)])
    return (server, server.client())
}

/// Holds the first searchPlaces request until its task is cancelled, then fails as URLSession does; the rest go to
/// `base`. So a call stays in flight until something cancels it.
final class HangingFirstTransport: HTTPTransport, @unchecked Sendable {
    private let base: any HTTPTransport
    private let lock = NSLock()
    private var searches = 0

    init(_ base: any HTTPTransport) { self.base = base }

    /// How many searchPlaces requests have reached the transport.
    var started: Int { lock.withLock { searches } }

    func get(_ url: URL) async throws -> HTTPResponse {
        if url.absoluteString.contains("org.atgeo.searchPlaces") {
            let n = lock.withLock { () -> Int in searches += 1; return searches }
            if n == 1 {
                do { try await Task.sleep(nanoseconds: 60 * 1_000_000_000) } catch { throw URLError(.cancelled) }
            }
        }
        return try await base.get(url)
    }
}

/// Waits, up to five seconds, until `condition` holds.
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<5000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
}

@Suite("autocompleteByKeyword") struct Autocomplete {
    // A one-character prefix, a Hangul syllable (one character, though NFKD makes it two), and a consonant with a
    // spacing vowel sign (one character once the sign is stripped).
    @Test("makes no request for a prefix that cannot qualify, and resolves an empty result that disclosed nothing",
          arguments: ["a", "\u{D558}", "\u{915}\u{93E}"])
    func skipped(_ prefix: String) async throws {
        let (server, client) = try setup()
        let result = try await client.autocompleteByKeyword(dataset: dataset, collection: "place").searchByKeyword(prefix)
        #expect(result == nothing)
        #expect(server.requests.isEmpty)
    }

    @Test("sends a prefix that qualifies, as typed, and returns the keyword hits")
    func sends() async throws {
        let (server, client) = try setup()
        let result = try await client.autocompleteByKeyword(dataset: dataset, collection: "place").searchByKeyword("Zan")
        #expect(server.requests.count == 1)
        #expect(paramsOf(server.requests[0]) == ["dataset": dataset, "collection": "place", "q": "Zan"])
        #expect(result.places.map(\.origin) == [placeOrigin("zc")])
        #expect(result.disclosed == Disclosure(keyword: true, region: nil))
    }

    // Section 12, item 8: every string that qualifies goes out exactly as searchByKeyword sends it, prefixes included.
    @Test("sends every qualifying prefix of a keyword and none of the others")
    func everyPrefix() async throws {
        let (server, client) = try setup()
        let typing = try client.autocompleteByKeyword(dataset: dataset)
        let word = "Zanzibar"
        for n in 1...word.count { _ = try await typing.searchByKeyword(String(word.prefix(n))) }
        #expect(server.requests.count == word.count - 1)
        #expect(server.requests.map { paramsOf($0) } == (2...word.count).map { ["dataset": dataset, "q": String(word.prefix($0))] })
    }

    @Test("sends the region it was made with, snapped to whole degrees")
    func withRegion() async throws {
        let (server, client) = try setup()
        let region = KeywordRegion(west: -122.43, south: 37.77, east: -122.41, north: 37.78)
        let result = try await client.autocompleteByKeyword(dataset: dataset, region: region).searchByKeyword("Zan")
        #expect(paramsOf(server.requests[0])["bbox"] == "-123,37,-122,38")
        #expect(result.disclosed == Disclosure(keyword: true, region: 1))
    }

    @Test("supersedes the previous call on the same autocompleter, which throws CancellationError")
    func supersedes() async throws {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let hanging = HangingFirstTransport(server)
        let client = AtgeoClient(server: URL(string: server.server)!, transport: hanging)
        let typing = try client.autocompleteByKeyword(dataset: dataset, collection: "place")
        let first = Task { try await typing.searchByKeyword("Za") }
        await eventually { hanging.started == 1 }
        let second = try await typing.searchByKeyword("Zan")
        // Whatever the transport threw, here URLError(.cancelled), the superseded call's caller was not cancelled.
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(!first.isCancelled)
        #expect(second.places.count == 1)
    }

    @Test("an unqualifying keyword still supersedes the previous call")
    func skippedStillSupersedes() async throws {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let hanging = HangingFirstTransport(server)
        let typing = try AtgeoClient(server: URL(string: server.server)!, transport: hanging).autocompleteByKeyword(dataset: dataset)
        let first = Task { try await typing.searchByKeyword("Za") }
        await eventually { hanging.started == 1 }
        #expect(try await typing.searchByKeyword("z") == nothing)
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }

    @Test("does not supersede a call on another autocompleter of the same client")
    func otherAutocompleter() async throws {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let slow = DelayingTransport(server) { $0.absoluteString.contains("org.atgeo.searchPlaces") ? 0.05 : nil }
        let client = AtgeoClient(server: URL(string: server.server)!, transport: slow)
        let a = try client.autocompleteByKeyword(dataset: dataset)
        let b = try client.autocompleteByKeyword(dataset: dataset)
        let first = Task { try await a.searchByKeyword("Za") }
        await eventually { !server.searchPlacesRequests.isEmpty || slow.peakInFlight > 0 }
        _ = try await b.searchByKeyword("Zan")
        let result = try await first.value
        #expect(result.disclosed.keyword)
    }

    @Test("a call that is not superseded is not affected by an earlier call that finished")
    func sequentialCalls() async throws {
        let (_, client) = try setup()
        let typing = try client.autocompleteByKeyword(dataset: dataset)
        #expect(try await typing.searchByKeyword("Za").places.count == 1)
        #expect(try await typing.searchByKeyword("Zan").places.count == 1)
    }
}

@Suite("autocompleteByKeyword arguments") struct AutocompleteArguments {
    @Test("refuses a region that is not a valid bbox at construction")
    func badRegion() throws {
        let (_, client) = try setup()
        #expect(throws: AtgeoArgumentError.invalidRegion("invalid bbox")) {
            _ = try client.autocompleteByKeyword(dataset: dataset, region: KeywordRegion(west: 0, south: 5, east: 1, north: 1))
        }
    }
}

// Contract §19 (#56): a keyword the SDK judged qualifying but the server refuses with KeywordRequired resolves empty,
// as a keyword the SDK skips does, except that the keyword did go out.
@Suite("autocompleteByKeyword when the server refuses a keyword the SDK judged qualifying") struct AutocompleteKeywordRequired {
    @Test("resolves empty for the fi ligature, disclosing the keyword it sent")
    func ligature() async throws {
        let (server, client) = try setup()
        let result = try await client.autocompleteByKeyword(dataset: dataset).searchByKeyword("\u{FB01}")
        #expect(server.requests.count == 1)
        #expect(result == KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: true, region: nil)))
    }

    @Test("reports the region it sent with the refused keyword")
    func withRegion() async throws {
        let (_, client) = try setup()
        let region = KeywordRegion(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
        let result = try await client.autocompleteByKeyword(dataset: dataset, region: region).searchByKeyword("\u{FB01}")
        #expect(result.disclosed == Disclosure(keyword: true, region: 1))
    }

    @Test("still throws any other refusal")
    func otherRefusal() async throws {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let transport = InterceptingTransport(server) { _ in
            HTTPResponse(status: 400, body: Data(#"{"error":"InvalidRequest","message":"q is too long"}"#.utf8))
        }
        let client = AtgeoClient(server: URL(string: server.server)!, transport: transport)
        do {
            _ = try await client.autocompleteByKeyword(dataset: dataset).searchByKeyword("Zan")
            Issue.record("expected a throw")
        } catch let error as AtgeoError {
            #expect(error.code == "InvalidRequest")
        }
    }
}

// #60: rules of section 19 and section 11 that no test killed before.
@Suite("autocompleteByKeyword cancellation") struct AutocompleteCancellation {
    @Test("throws, without a request, when the caller's task is already cancelled")
    func alreadyCancelled() async throws {
        let (server, client) = try setup()
        let typing = try client.autocompleteByKeyword(dataset: dataset)
        let task = Task { () throws -> KeywordSearchResult in
            _ = withUnsafeCurrentTask { $0?.cancel() }
            return try await typing.searchByKeyword("Zan")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test("cancels its request when the caller cancels mid-flight")
    func midFlight() async throws {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let hanging = HangingFirstTransport(server)
        let typing = try AtgeoClient(server: URL(string: server.server)!, transport: hanging).autocompleteByKeyword(dataset: dataset)
        let call = Task { try await typing.searchByKeyword("Zan") }
        await eventually { hanging.started == 1 }
        call.cancel()
        // CancellationError, or URLError(.cancelled) from the transport, whichever reached the call first.
        await #expect(throws: (any Error).self) { _ = try await call.value }
        // The autocompleter is usable afterwards.
        #expect(try await typing.searchByKeyword("Zan").places.count == 1)
    }
}

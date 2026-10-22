import Foundation
import Testing
@testable import Atgeo

// No reference counterpart: the reference has no test of the in-flight cap, cancellation, or a retry after a
// failed getTiles (design review, step 8).

private let sf = Region.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78)

private func manyTiles(_ n: Int) throws -> FakeServer {
    try FakeServer(tilesets: [overture((0..<n).map { i in
        FakeTile(url: tileURL(String(format: "t%02d", i)), records: [record(place("p\(i)", "P\(i)", [point(37.775, -122.415)]))])
    })])
}

private func client(_ transport: any HTTPTransport) -> AtgeoClient {
    AtgeoClient(server: AtgeoClient.defaultServer, transport: transport, cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() })
}

/// Counts calls, for a tilesFor that fails the first time.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct ConcurrencyTests {
    @Test func atMostEightTilesAreInFlight() async throws {
        let server = try manyTiles(20)
        let delaying = DelayingTransport(server) { $0.absoluteString.hasPrefix("https://tiles.example/") ? 0.05 : nil }
        let result = try await client(delaying).searchPlaces(region: sf)
        #expect(result.tiles == .init(fetched: 20, failed: 0))
        #expect(result.places.count == 20)
        #expect(delaying.peakInFlight == 8)
    }

    @Test func cancellingASearchWithAHeldTileThrowsRatherThanCountingAFailure() async throws {
        let server = try manyTiles(3)
        let held = tileURL("t01")
        // Generous budgets: on the iOS simulator the whole suite starts at once and a test can wait tens of
        // seconds for its tiles. Cancellation must still beat the held tile's 300 s by a wide margin.
        let delaying = DelayingTransport(server) { $0.absoluteString == held ? 300 : nil }
        let c = client(delaying)
        let task = Task { try await c.searchPlaces(region: sf) }
        // Wait until the held tile is in flight, then cancel.
        let deadline = Date().addingTimeInterval(120)
        while delaying.completionOrder.count < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(delaying.completionOrder.count == 3)   // getTiles and the two other tiles
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 120)
        switch result {
        case .success(let r): Issue.record("expected cancellation, got a result with tiles \(r.tiles)")
        case .failure(let error): #expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "got \(error)")
        }
    }

    @Test func aCancelledTaskOnAWarmCacheStillReturns() async throws {
        let server = try manyTiles(3)
        let c = client(server)
        let warm = try await c.searchPlaces(region: sf)
        server.goOffline()
        let task = Task { () async throws -> SearchResult in
            while !Task.isCancelled { await Task.yield() }
            return try await c.searchPlaces(region: sf)
        }
        task.cancel()
        #expect(try await task.value == warm)
    }

    @Test func aFailedGetTilesCachesNothingAndARetryAsksAgain() async throws {
        let calls = Counter()
        let tile = tileURL("a")
        let server = try FakeServer(
            tilesets: [overture([FakeTile(url: tile, records: [record(place("a", "A", [point(37.775, -122.415)]))])])],
            tilesFor: { _ in calls.next() == 1 ? .error(code: "InternalServerError", message: "try again") : .tiles([tile]) })
        let c = server.client()
        await #expect(throws: AtgeoError(code: "InternalServerError", message: "try again", status: 400)) { _ = try await c.searchPlaces(region: sf) }
        let result = try await c.searchPlaces(region: sf)
        #expect(server.getTilesRequests.count == 2)
        #expect(result.places.count == 1)
    }

    @Test func concurrentSearchesOnOneClientAgree() async throws {
        let server = try manyTiles(12)
        let delaying = DelayingTransport(server) { $0.absoluteString.hasPrefix("https://tiles.example/") ? 0.01 : nil }
        let c = client(delaying)
        let results = try await withThrowingTaskGroup(of: SearchResult.self) { group in
            for _ in 0..<6 { group.addTask { try await c.searchPlaces(region: sf, text: "P1") } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0.places == results[0].places })
        #expect(results.allSatisfy { $0.complete })
    }
}

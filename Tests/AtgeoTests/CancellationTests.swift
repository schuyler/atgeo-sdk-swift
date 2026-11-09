import Foundation
import Testing
@testable import Atgeo

// Contract §11 and §19 against a transport that ignores cancellation: the caller learns of a cancel or a
// supersession without waiting for the transport (S2, S3, S4).

private let dataset = "overturemaps.org"
private let region = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)

private func tile(_ name: String) -> FakeTile {
    FakeTile(url: tileURL(name), records: [record(place(name, name.uppercased(), [point(37.772, -122.412)]))])
}

/// Holds the first `holding` requests whose URL contains `matching` until `open()` is called, whatever happens to
/// the task that made them, then answers them from `base`. A transport that ignores cancellation.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let base: any HTTPTransport
    private let matching: String
    private let holding: Int
    private let lock = NSLock()
    private var reached = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ base: any HTTPTransport, matching: String, holding: Int = 1) {
        self.base = base
        self.matching = matching
        self.holding = holding
    }

    /// How many matching requests have reached the transport.
    var started: Int { lock.withLock { reached } }
    var isOpen: Bool { lock.withLock { opened } }

    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func get(_ url: URL) async throws -> HTTPResponse {
        if url.absoluteString.contains(matching) {
            let n = lock.withLock { () -> Int in reached += 1; return reached }
            if n <= holding {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let now = lock.withLock { () -> Bool in
                        if !opened { waiters.append(c) }
                        return opened
                    }
                    if now { c.resume() }
                }
            }
        }
        return try await base.get(url)
    }
}

/// Opens `gate` after five seconds, so a regression fails the test instead of hanging it.
private func watchdog(_ gate: GatedTransport) -> Task<Void, Never> {
    Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        gate.open()
    }
}

private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<5000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
}

@Suite("cancellation through a transport that ignores it") struct IgnoringTransport {
    @Test("a superseded autocompleter call throws before the transport returns")
    func supersededBeforeTransportReturns() async throws {
        let server = try FakeServer(tilesets: [overture([tile("p")])])
        let gate = GatedTransport(server, matching: "org.atgeo.searchPlaces")
        let dog = watchdog(gate)
        defer { dog.cancel(); gate.open() }
        let typing = try AtgeoClient(server: URL(string: server.server)!, transport: gate).autocompleteByKeyword(dataset: dataset)
        let first = Task { try await typing.searchByKeyword("Za") }
        await eventually { gate.started == 1 }
        _ = try await typing.searchByKeyword("Zan")
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(!gate.isOpen, "the call waited for the transport")
    }

    @Test("a cancelled autocompleter call throws before the transport returns")
    func cancelledBeforeTransportReturns() async throws {
        let server = try FakeServer(tilesets: [overture([tile("p")])])
        let gate = GatedTransport(server, matching: "org.atgeo.searchPlaces")
        let dog = watchdog(gate)
        defer { dog.cancel(); gate.open() }
        let typing = try AtgeoClient(server: URL(string: server.server)!, transport: gate).autocompleteByKeyword(dataset: dataset)
        let call = Task { try await typing.searchByKeyword("Zan") }
        await eventually { gate.started == 1 }
        call.cancel()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(!gate.isOpen, "the call waited for the transport")
    }

    @Test("a searchByKeyword cancelled mid-flight throws CancellationError though the transport returns 200")
    func keywordCancelledMidFlight() async throws {
        let server = try FakeServer(tilesets: [overture([tile("p")])])
        let gate = GatedTransport(server, matching: "org.atgeo.searchPlaces")
        let dog = watchdog(gate)
        defer { dog.cancel(); gate.open() }
        let client = AtgeoClient(server: URL(string: server.server)!, transport: gate)
        let call = Task { try await client.searchByKeyword(keyword: "Zan", dataset: dataset) }
        await eventually { gate.started == 1 }
        call.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
    }

    @Test("a searchNearby cancelled while a tile is in flight throws CancellationError though the transport returns 200")
    func nearbyCancelledWithTileInFlight() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a")])])
        let gate = GatedTransport(server, matching: "https://tiles.example/")
        let dog = watchdog(gate)
        defer { dog.cancel(); gate.open() }
        let client = AtgeoClient(server: URL(string: server.server)!, transport: gate)
        let call = Task { try await client.searchNearby(region: region, dataset: dataset, collection: "place") }
        await eventually { gate.started == 1 }
        call.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
    }

    // S3 (contract §11): the tile list is cached, the tiles are not (a failed tile is not cached), and the
    // cancelled search makes no tile request.
    @Test("a cancelled searchNearby with a cached tile list and uncached tiles makes no tile request")
    func cachedListUncachedTiles() async throws {
        let server = try FakeServer(tilesets: [overture([tile("a")])], failTiles: [tileURL("a")])
        let client = server.client()
        let warm = try await client.searchNearby(region: region, dataset: dataset, collection: "place")
        #expect(warm.tileFailures.count == 1)
        let tileRequests = { server.requestStrings.filter { $0.hasPrefix("https://tiles.example/") }.count }
        let before = tileRequests()
        let getTiles = server.getTilesRequests.count
        let task = Task { () throws -> NearbySearchResult in
            _ = withUnsafeCurrentTask { $0?.cancel() }
            return try await client.searchNearby(region: region, dataset: dataset, collection: "place")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(tileRequests() == before)
        #expect(server.getTilesRequests.count == getTiles)
    }
}

@Suite("autocompleter, cancelled caller and a keyword that cannot qualify") struct CancelledNonQualifying {
    // D1 (contract §19 step 3): nothing is sent, so there is nothing to cancel; the call still supersedes.
    @Test("resolves empty without a request, and still supersedes the previous call")
    func resolvesEmpty() async throws {
        let server = try FakeServer(tilesets: [overture([tile("p")])])
        let hanging = HangingFirstTransport(server)
        let typing = try AtgeoClient(server: URL(string: server.server)!, transport: hanging).autocompleteByKeyword(dataset: dataset)
        let first = Task { try await typing.searchByKeyword("Za") }
        await eventually { hanging.started == 1 }
        let second = Task { () throws -> KeywordSearchResult in
            _ = withUnsafeCurrentTask { $0?.cancel() }
            return try await typing.searchByKeyword("z")
        }
        let result = try await second.value
        #expect(result == KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: false, region: nil)))
        #expect(server.searchPlacesRequests.isEmpty)
        await #expect(throws: CancellationError.self) { _ = try await first.value }
    }
}

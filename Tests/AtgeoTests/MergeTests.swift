import Foundation
import Testing
@testable import Atgeo

// Port of test/merge.test.ts.

private func idOf(_ origin: String?) -> String { String(String(describing: origin ?? "null").dropFirst(placeOrigin("").count)) }

private func search(_ records: [JSONObject], _ region: Region) async throws -> [String] {
    let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("t"), records: records.map { record($0) })])])
    return try await server.client().searchPlaces(region: region).places.map { idOf($0.origin) }.sorted()
}

private func divisions(_ tiles: [FakeTile]) -> FakeTileset {
    FakeTileset(slug: "overture-division", collections: [["dataset": .string("overturemaps.org"), "collection": .string("division")]], tiles: tiles)
}

private func division(_ id: String, _ name: String, lat: Double = 37.775) -> JSONObject {
    place(id, name, [point(lat, -122.415)], ["origin": .string("urn:atgeo:overturemaps.org:division:\(id)")])
}

private let sfRegion = Region.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78)

@Suite("deduplication") struct Deduplication {
    let first = place("dup", "First copy", [point(37.775, -122.415)])
    let second = place("dup", "Second copy", [point(37.775, -122.415)])

    @Test("collapses a duplicate origin across tiles to one result")
    func collapses() async throws {
        let server = try FakeServer(tilesets: [overture([
            FakeTile(url: tileURL("a"), records: [record(first), record(place("a-only", "A", [point(37.772, -122.412)]))]),
            FakeTile(url: tileURL("b"), records: [record(second), record(place("b-only", "B", [point(37.773, -122.413)]))]),
        ])])
        let result = try await server.client().searchPlaces(region: sfRegion)
        #expect(result.places.map { idOf($0.origin) }.sorted() == ["a-only", "b-only", "dup"])
    }

    @Test("keeps the first tile's copy in the default order too")
    func firstTileWins() async throws {
        let server = try FakeServer(tilesets: [overture([
            FakeTile(url: tileURL("a"), records: [record(first)]), FakeTile(url: tileURL("b"), records: [record(second)]),
        ])])
        #expect(try await server.client().searchPlaces(region: sfRegion).places.map { $0.place["name"] } == [.string("First copy")])
    }

    @Test("merges a division record held by two tiles into one hit")
    func divisionAcrossTiles() async throws {
        let server = try FakeServer(tilesets: [divisions([
            FakeTile(url: tileURL("a"), records: [record(division("d1", "Springfield"))]),
            FakeTile(url: tileURL("b"), records: [record(division("d1", "Springfield"))]),
        ])])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org", collection: "division")
        #expect(result.places.count == 1)
        #expect(result.places.first?.origin == "urn:atgeo:overturemaps.org:division:d1")
    }

    @Test("keeps the lowest-URL copy across an antimeridian split", arguments: [
        ("lower", "a", "z", "East copy"),
        ("higher", "z", "a", "West copy"),
    ])
    func lowestURLAcrossSplit(order: String, eastName: String, westName: String, winner: String) async throws {
        let server = try FakeServer(
            tilesets: [overture([
                FakeTile(url: tileURL(eastName), records: [record(place("x", "East copy", [point(15, 175)]))]),
                FakeTile(url: tileURL(westName), records: [record(place("x", "West copy", [point(15, -175)]))]),
            ])],
            tilesFor: { bbox in .tiles([bbox.hasPrefix("170") ? tileURL(eastName) : tileURL(westName)]) })
        let result = try await server.client().searchPlaces(region: .bbox(minLon: 170, minLat: 10, maxLon: -170, maxLat: 20))
        #expect(result.places.map { $0.place["name"] } == [.string(winner)], "east tile URL sorts \(order)")
    }

    @Test("keeps two records that have neither origin nor uri")
    func anonymous() async throws {
        let anon = { (name: String) in withoutOrigin(place("x", name, [point(37.775, -122.415)])) }
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [record(anon("One")), record(anon("Two"))])])])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        #expect(result.places.compactMap { $0.place["name"]?.stringValue }.sorted() == ["One", "Two"])
        #expect(result.places.allSatisfy { $0.origin == nil })
    }

    @Test("identifies an origin-less record by its uri")
    func byUri() async throws {
        let value = withoutOrigin(place("x", "By uri", [point(37.775, -122.415)]))
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [record(value, uri: "https://example.org/r/1")])])])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        #expect(result.places.map(\.origin) == ["https://example.org/r/1"])
    }
}

@Suite("ordering ties") struct OrderingTies {
    @Test("orders records equal on score, importance and distance by origin, nil last")
    func byOrigin() async throws {
        let same = { (id: String, anonymous: Bool) -> TileRecord in
            let p = place(id, "Same", [point(37.775, -122.415)])
            return record(anonymous ? withoutOrigin(p) : p, importance: 5)
        }
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [
            same("x", true), same("c", false), same("a", false), same("b", false),
        ])])])
        let result = try await server.client().searchPlaces(region: sfRegion, dataset: "overturemaps.org")
        #expect(result.places.map(\.origin) == [placeOrigin("a"), placeOrigin("b"), placeOrigin("c"), nil])
    }
}

@Suite("region filtering: bbox") struct RegionFilteringBbox {
    let region = Region.bbox(minLon: -122.4194, minLat: 37.7749, maxLon: -122.415, maxLat: 37.7799)

    @Test("drops a point inside the snapped box but outside the region")
    func dropsOutside() async throws {
        let kept = try await search([
            place("in", "In", [point(37.777, -122.417)]),
            place("south", "South", [point(37.771, -122.417)]),
            place("east", "East", [point(37.777, -122.411)]),
            place("far", "Far", [point(40, -100)]),
        ], region)
        #expect(kept == ["in"])
    }

    @Test("keeps a point on the region boundary")
    func boundary() async throws {
        #expect(try await search([place("edge", "Edge", [point(37.7749, -122.4194)])], region) == ["edge"])
    }

    @Test("passes bbox-only records by intersection")
    func bboxIntersection() async throws {
        let kept = try await search([
            place("overlap", "Overlap", [bboxLocation(north: 37.776, south: 37.7, east: -122.416, west: -122.5)]),
            place("encloses", "Encloses", [bboxLocation(north: 38, south: 37, east: -122, west: -123)]),
            place("inside", "Inside", [bboxLocation(north: 37.777, south: 37.776, east: -122.417, west: -122.418)]),
            place("north", "North", [bboxLocation(north: 38, south: 37.9, east: -122.416, west: -122.418)]),
            place("west", "West", [bboxLocation(north: 37.777, south: 37.776, east: -122.5, west: -122.6)]),
        ], region)
        #expect(kept == ["encloses", "inside", "overlap"])
    }

    @Test("tests a record with both point and bbox on the point")
    func pointWins() async throws {
        let kept = try await search([
            place("point-out", "Point out", [point(40, -100), bboxLocation(north: 38, south: 37, east: -122, west: -123)]),
            place("point-in", "Point in", [bboxLocation(north: 10, south: 9, east: 10, west: 9), point(37.777, -122.417)]),
        ], region)
        #expect(kept == ["point-in"])
    }

    @Test("drops records with no parseable location")
    func noLocation() async throws {
        var garbage = point(0, 0).objectValue!
        garbage["latitude"] = .string("north-ish")
        let kept = try await search([
            place("ok", "Ok", [point(37.777, -122.417)]),
            place("none", "None", []),
            place("address", "Address", [.object(["$type": .string("community.lexicon.location.address"), "country": .string("US"), "street": .string("1 Main St")])]),
            place("garbage", "Garbage", [.object(garbage)]),
            ["$type": .string("org.atgeo.place"), "origin": .string(placeOrigin("missing")), "name": .string("Missing")],
        ], region)
        #expect(kept == ["ok"])
    }

    @Test("handles a crossing region against points and crossing bboxes")
    func crossingRegion() async throws {
        let kept = try await search([
            place("east-side", "E", [point(0, 175)]),
            place("west-side", "W", [point(0, -175)]),
            place("prime", "P", [point(0, 0)]),
            place("crossing-box", "X", [bboxLocation(north: 1, south: -1, east: -175, west: 178)]),
            place("far-box", "F", [bboxLocation(north: 1, south: -1, east: 100, west: 90)]),
        ], .bbox(minLon: 170, minLat: -10, maxLon: -170, maxLat: 10))
        #expect(kept == ["crossing-box", "east-side", "west-side"])
    }
}

@Suite("region filtering: circle") struct RegionFilteringCircle {
    @Test("uses the true radius, not the enclosing square")
    func trueRadius() async throws {
        let (lat, lon) = (37.7749, -122.4194)
        let kept = try await search([
            place("near", "Near", [point(lat + 0.003, lon)]),
            place("corner", "Corner", [point(lat + 0.004, lon + 0.005)]),
            place("beyond", "Beyond", [point(lat + 0.005, lon)]),
        ], .circle(lat: lat, lon: lon, radius: 500))
        #expect(kept == ["near"])
    }

    @Test("passes bbox-only records by nearest-point distance")
    func bboxNearestPoint() async throws {
        let kept = try await search([
            place("close-box", "Close", [bboxLocation(north: 0.4, south: 0.3, east: 0.4, west: 0.3)]),
            place("corner-box", "Corner", [bboxLocation(north: 0.5, south: 0.4, east: 0.5, west: 0.4)]),
            place("surrounding", "Surrounding", [bboxLocation(north: 1, south: -1, east: 1, west: -1)]),
        ], .circle(lat: 0, lon: 0, radius: 55597))
        #expect(kept == ["close-box", "surrounding"])
    }

    @Test("keeps a high-latitude bbox-only record that clips the circle, with distance within the radius")
    func highLatitudeClip() async throws {
        let (lat, radius) = (85.0, 370000.0)
        // Measured to the box edge along the center's parallel: 379.9 km. The true nearest point is 357.1 km.
        let box = place("clipping", "Clipping", [bboxLocation(north: 89, south: 80, east: 50, west: 40)])
        #expect(haversine(lat, 0, lat, 40) > radius)
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("t"), records: [record(box)])])])
        let places = try await server.client().searchPlaces(region: .circle(lat: lat, lon: 0, radius: radius)).places
        #expect(places.map { idOf($0.origin) } == ["clipping"])
        #expect((places.first?.distance ?? .infinity) <= radius)
    }

    @Test("finds the nearest longitude around the antimeridian")
    func nearestLongitude() async throws {
        let kept = try await search([
            place("near-edge", "Near", [bboxLocation(north: 1, south: -1, east: 180, west: 170)]),
            place("far-edge", "Far", [bboxLocation(north: 1, south: -1, east: 170, west: 160)]),
            place("crossing", "Crossing", [bboxLocation(north: 1, south: -1, east: -170, west: 170)]),
        ], .circle(lat: 0, lon: -175, radius: 667170))
        #expect(kept == ["crossing", "near-edge"])
    }

    @Test("measures point distance across the antimeridian")
    func pointAcrossAntimeridian() async throws {
        let kept = try await search([
            place("p-wrap", "Wrap", [point(0, 179.5)]),
            place("p-far", "Far", [point(0, 178)]),
            place("p-same", "Same", [point(0, -176)]),
        ], .circle(lat: 0, lon: -175, radius: 667170))
        #expect(kept == ["p-same", "p-wrap"])
    }
}

@Suite("determinism") struct Determinism {
    private static func permutations(_ xs: [String]) -> [[String]] {
        xs.count <= 1 ? [xs] : xs.indices.flatMap { i in
            permutations(Array(xs[..<i] + xs[(i + 1)...])).map { [xs[i]] + $0 }
        }
    }

    private static let tiles = [
        FakeTile(url: tileURL("a"), records: [
            record(place("dup", "Copy A", [point(37.775, -122.415)]), importance: 5),
            record(place("a1", "Alpha", [point(37.772, -122.412)]), importance: 5),
            record(place("a2", "Alpha", [point(37.772, -122.412)]), importance: 5),
        ]),
        FakeTile(url: tileURL("b"), records: [
            record(place("dup", "Copy B", [point(37.775, -122.415)]), importance: 5),
            record(place("b1", "Alpha", [point(37.772, -122.412)]), importance: 5),
        ]),
        FakeTile(url: tileURL("c"), records: [
            record(place("dup", "Copy C", [point(37.775, -122.415)]), importance: 5),
            record(place("c1", "Alpha", [point(37.772, -122.412)]), importance: 5),
        ]),
    ]

    private static func run(_ arrival: [String], text: String?) async throws -> (SearchResult, [String]) {
        let server = try FakeServer(tilesets: [overture(tiles)])
        let ordered = OrderedTransport(server, order: arrival.map(tileURL))
        let client = AtgeoClient(server: URL(string: server.server)!, transport: ordered, cacheBudgetBytes: AtgeoClient.defaultCacheBudgetBytes, now: { Date() })
        let result = try await client.searchPlaces(region: sfRegion, text: text)
        return (result, await ordered.completed)
    }

    @Test("gives identical output for every tile arrival order", arguments: [String?.none, "Alpha"])
    func identicalOutput(text: String?) async throws {
        var outputs: [SearchResult] = []
        for order in Self.permutations(["a", "b", "c"]) {
            let (result, arrived) = try await Self.run(order, text: text)
            // The transport released the tiles in this order, so the test exercises what it says it does.
            #expect(arrived == order.map(tileURL))
            outputs.append(result)
        }
        #expect(outputs.allSatisfy { $0 == outputs[0] })
        #expect(outputs[0].places.map { idOf($0.origin) }.sorted() == ["a1", "a2", "b1", "c1", "dup"])
        #expect(outputs[0].places.first { idOf($0.origin) == "dup" }?.place["name"] == .string("Copy A"))
    }
}

/// Answers the named URLs one at a time, in `order`: each waits, suspended rather than blocking a thread, until
/// the one before it has answered. The reference uses timers for this (15 ms apart), which the macOS runner,
/// running tests in parallel on three cores, does not honour reliably even 100 ms apart.
private final class OrderedTransport: HTTPTransport, @unchecked Sendable {
    private actor Turnstile {
        private var next = 0
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private(set) var completed: [String] = []

        func wait(for turn: Int) async {
            if turn == next { return }
            await withCheckedContinuation { waiting[turn] = $0 }
        }

        func finish(_ url: String) {
            completed.append(url)
            next += 1
            waiting.removeValue(forKey: next)?.resume()
        }
    }

    private let base: any HTTPTransport
    private let order: [String]
    private let turnstile = Turnstile()

    init(_ base: any HTTPTransport, order: [String]) {
        self.base = base
        self.order = order
    }

    var completed: [String] { get async { await turnstile.completed } }

    func get(_ url: URL) async throws -> HTTPResponse {
        guard let turn = order.firstIndex(of: url.absoluteString) else { return try await base.get(url) }
        await turnstile.wait(for: turn)
        let response = try await base.get(url)
        await turnstile.finish(url.absoluteString)
        return response
    }
}

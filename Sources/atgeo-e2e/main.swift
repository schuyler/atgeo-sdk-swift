// End-to-end run against a live garganorn, a port of atgeo-sdk-js `scripts/e2e.ts` (design review note 16).
// Not part of `swift test`. Run with `swift run atgeo-e2e`, configured by the same environment variables.
// It also times the client's JSON parser on the largest tile the search fetched (design review note 12).
@_spi(Benchmark) import Atgeo
import Foundation

let env = ProcessInfo.processInfo.environment
let server = URL(string: env["ATGEO_SERVER"] ?? "http://localhost:8000")!
let dataset = env["ATGEO_DATASET"] ?? "openstreetmap.org"
let collection = env["ATGEO_COLLECTION"]
// "lat,lon,radius" in metres; the default is Manchester, NH, inside the local OSM New Hampshire tileset.
// Every part must parse, so "43,-71,3000,junk" is rejected rather than read as its first three numbers.
let parts = (env["ATGEO_REGION"] ?? "43.0,-71.45,3000").split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
guard parts.count == 3, let lat = parts[0], let lon = parts[1], let radius = parts[2] else {
    fail("ATGEO_REGION must be lat,lon,radius")
}
let region = Region.circle(lat: lat, lon: lon, radius: radius)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
    exit(1)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { fail(message()) }
}

func log(_ step: String, _ detail: String) {
    print("ok  \(step): \(detail)")
}

/// Keeps the body of every tile fetched, so the run can time decoding on real data.
actor TileBodies {
    var bodies: [Data] = []
    func add(_ body: Data) { bodies.append(body) }
}

struct RecordingTransport: HTTPTransport {
    let inner = URLSessionTransport()
    let tiles = TileBodies()

    func get(_ url: URL) async throws -> HTTPResponse {
        let response = try await inner.get(url)
        if !url.path.hasPrefix("/xrpc/") && (200..<300).contains(response.status) { await tiles.add(response.body) }
        return response
    }
}

// With a collection set, the tileset must serve that collection, not just the dataset.
func wanted(dataset d: String?, collection c: String?) -> Bool {
    d == dataset && (collection == nil || c == collection)
}
let wantedName = dataset + (collection.map { "/\($0)" } ?? "")

do {
    let transport = RecordingTransport()
    let client = AtgeoClient(server: server, transport: transport)

    let service = try await client.describeService()
    guard let served = service.tilesets.first(where: { $0.collections.contains { wanted(dataset: $0.dataset, collection: $0.collection) } }),
        let slug = served.slug
    else { fail("\(wantedName) not served") }
    // maxTiles and attribution arrive with the server that implements garganorn#27; this fails against an older one.
    check(service.maxTiles.map { $0 > 0 } ?? false, "describeService has no maxTiles")
    log("describeService", "\(service.did ?? "no did"), \(service.tilesets.count) tileset(s), maxTiles \(service.maxTiles ?? 0)")

    let tileset = try await client.describeTileset(slug)
    check(
        tileset.collections.contains { wanted(dataset: $0.dataset, collection: $0.collection) },
        "describeTileset does not list the dataset and collection")
    log("describeTileset", "\(tileset.slug ?? "no slug"), \(tileset.collections.count) collection(s)")

    let nearby = try await client.searchPlaces(region: region, dataset: dataset, collection: collection, sort: .distance)
    check(nearby.complete, "\(nearby.tiles.failed) tile(s) failed")
    check(!nearby.places.isEmpty, "no places in region")
    let distances = nearby.places.map(\.distance)
    check(
        distances.indices.allSatisfy { i in distances[i] <= radius && (i == 0 || distances[i] >= distances[i - 1]) },
        "not distance-ordered within radius")
    check(
        nearby.attribution.contains { wanted(dataset: $0.dataset, collection: $0.collection) },
        "the search's attribution does not credit \(wantedName)")
    check(nearby.places.contains { $0.collection != nil }, "no hit names its collection")
    log("searchPlaces (no text)", "\(nearby.places.count) places from \(nearby.tiles.fetched) tile(s)")

    guard let named = nearby.places.first(where: { $0.origin != nil && !($0.place["name"]?.stringValue ?? "").isEmpty }),
        let origin = named.origin, let name = named.place["name"]?.stringValue
    else { fail("no named place in region") }
    let matched = try await client.searchPlaces(region: region, dataset: dataset, text: name, collection: collection)
    check(
        matched.places.contains { $0.origin == origin && $0.score != nil },
        "named place missing from text search")
    check((matched.places.first?.score ?? 0) > 0, "top text hit has no score")
    let top = matched.places[0].place["name"]?.stringValue ?? "(no name)"
    log("searchPlaces (text)", "\"\(name)\" -> top hit \(top), \(matched.places.count) places")

    let fresh = AtgeoClient(server: server)
    let record = try await fresh.place(origin: origin)
    check(record.place["name"]?.stringValue == name, "getPlace name \(record.place["name"] ?? .null) is not \(name)")
    check(!record.attribution.isEmpty, "getPlace answered with no attribution")
    log("getPlace", "\(origin) -> \(name), \(record.attribution.count) attribution entr(ies)")

    // The parse the client runs on every tile, into JSONValue. Median of five.
    guard let largest = await transport.tiles.bodies.max(by: { $0.count < $1.count }) else { fail("no tile fetched") }
    var times: [Double] = []
    var records = 0
    for _ in 0..<5 {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try parseJSON(largest)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        records = value["records"]?.arrayValue?.count ?? 0
    }
    let median = times.sorted()[2]
    log("parseJSON", "largest tile \(largest.count / 1024) KiB, \(records) records, median \(String(format: "%.1f", median)) ms of 5")
} catch {
    fail("\(error)")
}

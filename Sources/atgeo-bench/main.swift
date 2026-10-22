// Times JSON parsing of a tile-sized body, the client's parser against Foundation's (design review note 12),
// and measures what a full tile cache costs in memory and what a search over a warm region costs.
// Not in `swift test`: run it as `swift run -c release atgeo-bench [tile.json ...]`. With no arguments it
// times a synthetic tile shaped like an OSM tile from places.atgeo.org; each argument adds a real body.
@_spi(Benchmark) import Atgeo
import Foundation

/// A deterministic tile: `count` records with the shape and size of the OSM tiles places.atgeo.org serves
/// (about 990 bytes each: a point with string coordinates, five attributes, four `within` relations, an
/// integer importance; one record in twenty has a variant). `accented` draws the names' letters from a-z and
/// ä é ö ü, so that most of them need Unicode normalization.
func syntheticTile(records count: Int, seed start: UInt64 = 0x9E37_79B9_7F4A_7C15, accented: Bool = false) -> Data {
    var seed = start
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed >> 33
    }
    func word() -> String {
        let letters = Array(accented ? "abcdefghijklmnopqrstuvwxyzäéöü" : "abcdefghijklmnopqrstuvwxyz")
        return String((0..<(4 + Int(next() % 8))).map { _ in letters[Int(next() % UInt64(letters.count))] })
    }
    func uuid() -> String {
        let hex = Array("0123456789abcdef")
        return [8, 4, 4, 4, 12].map { n in String((0..<n).map { _ in hex[Int(next() % 16)] }) }.joined(separator: "-")
    }
    func division(_ name: String, _ type: String) -> String {
        #"{"uri": "urn:atgeo:overturemaps.org:division:\#(uuid())", "name": "\#(name)", "type": "\#(type)"}"#
    }
    var records: [String] = []
    for i in 0..<count {
        let name = "\(word().capitalized) \(word().capitalized)"
        let lat = String(format: "%.6f", 42.97 + Double(next() % 60_000) / 1e6)
        let lon = String(format: "%.6f", -71.49 + Double(next() % 80_000) / 1e6)
        let variants = i % 20 == 0 ? #"[{"name": "\#(name) \#(word())", "type": "alternate", "language": "en"}]"# : "[]"
        let attributes = [
            #""cuisine": "\#(word())""#, #""opening_hours": "Mo-Fr 0\#(next() % 10):00-2\#(next() % 4):00; Sa 10:00-22:00; Su 09:00-13:00""#,
            #""wheelchair": "yes""#, #""amenity": "\#(word())""#, #""addr:street": "\#(word().capitalized) Street""#,
        ].joined(separator: ", ")
        let within = [
            division("United States", "country"), division("New Hampshire", "region"),
            division("Hillsborough County", "county"), division("Manchester", "locality"),
        ].joined(separator: ", ")
        records.append(#"""
        {"value": {"$type": "org.atgeo.place", "origin": "urn:atgeo:openstreetmap.org:node:\#(10_000_000_000 + next() % 3_000_000_000)", \#
        "name": "\#(name)", "locations": [{"$type": "community.lexicon.location.geo", "latitude": "\#(lat)", "longitude": "\#(lon)"}], \#
        "variants": \#(variants), "attributes": {\#(attributes)}, "relations": {"within": [\#(within)]}}, "importance": \#(next() % 100)}
        """#)
    }
    let attribution = #"""
    [{"dataset": "openstreetmap.org", "collection": "node", "release": "2026-03-16T01:00:01Z", "source": "https://www.openstreetmap.org/", \#
    "licenses": ["https://opendatacommons.org/licenses/odbl/1-0/"], "attribution": "https://www.openstreetmap.org/copyright"}]
    """#
    return Data(#"{"publishedAt": "2026-10-14T07:54:27Z", "attribution": \#(attribution), "records": [\#(records.joined(separator: ", "))]}"#.utf8)
}

/// `JSONSerialization`'s output as a `JSONValue`, to time the whole path a JSONSerialization-based parser would
/// take. A boolean is an `NSNumber` whose Objective-C type is `c` on every platform this runs on.
func jsonValue(_ any: Any) -> JSONValue {
    switch any {
    case let s as String: return .string(s)
    case let n as NSNumber: return String(cString: n.objCType) == "c" ? .bool(n.boolValue) : .number(n.doubleValue)
    case let a as [Any]: return .array(a.map(jsonValue))
    case let o as [String: Any]: return .object(o.mapValues(jsonValue))
    default: return .null
    }
}

/// Median wall time in milliseconds of `runs` calls, after two untimed ones.
func median(runs: Int = 15, _ body: () throws -> Void) rethrows -> Double {
    try body()
    try body()
    var times: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return times.sorted()[runs / 2]
}

// The tile cache's cost: resident memory with the default budget full, and the time of a search over a warm
// region as a user types (contract §10). The tiles are synthetic, served by an in-process transport.

private let recordsPerTile = 886
private let fillTiles = 64           // about 54 MiB of bodies, so the 50 MiB budget fills and evicts
private let fillSearches = 8         // each over its own 8 tiles, as a dense city's region is
private let warmTiles = 41           // about 36k records, as PR #6 measured the per-keystroke cost over

private let tileBodies: [Data] = (0..<fillTiles).map { syntheticTile(records: recordsPerTile, seed: UInt64($0) &+ 1) }
private let accentedBodies: [Data] = (0..<warmTiles).map {
    syntheticTile(records: recordsPerTile, seed: UInt64($0) &+ 1, accented: true)
}

/// Answers getTiles from the dataset: "fill.{start}.{count}" lists those tiles; any other dataset lists the
/// first `warmTiles`, or for `accentedRegion` the accented ones. A tile request gets a fresh copy of its body, as from the network, so the cache cannot
/// share the transport's buffer.
private struct BenchTransport: HTTPTransport {
    func get(_ url: URL) async throws -> HTTPResponse {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if url.path.hasSuffix("/org.atgeo.getTiles") {
            let dataset = components.queryItems?.first { $0.name == "dataset" }?.value ?? ""
            let parts = dataset.split(separator: ".")
            let range = parts.first == "fill" ? Int(parts[1])!..<(Int(parts[1])! + Int(parts[2])!) : 0..<warmTiles
            let accented = components.queryItems?.first { $0.name == "bbox" }?.value == queryBbox(accentedRegion)
            let tiles = range.map { "\"https://tiles.bench/\(accented ? "a" : "")\($0).json\"" }.joined(separator: ",")
            return HTTPResponse(status: 200, body: Data("{\"tiles\": [\(tiles)]}".utf8))
        }
        let name = url.deletingPathExtension().lastPathComponent
        let body = name.hasPrefix("a") ? accentedBodies[Int(name.dropFirst())!] : tileBodies[Int(name)!]
        return HTTPResponse(status: 200, body: body.withUnsafeBytes { Data($0) })
    }
}

/// Manchester, NH, where the synthetic records are; the second, slightly larger box gets the accented tiles.
private let region = Region.bbox(minLon: -71.5, minLat: 42.96, maxLon: -71.4, maxLat: 43.04)
private let accentedRegion = Region.bbox(minLon: -71.51, minLat: 42.95, maxLon: -71.39, maxLat: 43.05)

/// The box the client sends for a bbox region, snapped outward to 0.01 degrees (contract §3).
private func queryBbox(_ region: Region) -> String {
    guard case let .bbox(minLon, minLat, maxLon, maxLat) = region else { return "" }
    return [(minLon / 0.01).rounded(.down), (minLat / 0.01).rounded(.down), (maxLon / 0.01).rounded(.up), (maxLat / 0.01).rounded(.up)]
        .map { String(format: "%.2f", $0 * 0.01) }.joined(separator: ",")
}

/// Resident memory in bytes: the physical footprint on Apple platforms, the figure the system limits an app
/// or extension by; RSS from /proc on Linux.
private func residentBytes() -> Int {
    #if canImport(Darwin)
    // task_self_trap() rather than mach_task_self_, a global var that Swift 6.0 rejects as not concurrency-safe.
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    #else
    guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
    let pages = statm.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
    return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    #endif
}

/// Hands the allocator's free pages back to the system, so that resident memory is what is live plus
/// fragmentation, not what earlier, freed allocations left behind. Looked up at run time, since Sources import
/// only Foundation (CI checks it): malloc_trim is glibc's, malloc_zone_pressure_relief Apple's.
private func releaseFreeMemory() {
    #if canImport(Darwin)
    typealias Relief = @convention(c) (UnsafeMutableRawPointer?, Int) -> Int
    // RTLD_DEFAULT, which Swift does not import on Darwin.
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_zone_pressure_relief") {
        _ = unsafeBitCast(f, to: Relief.self)(nil, 0)
    }
    #else
    typealias Trim = @convention(c) (Int) -> Int32
    if let f = dlsym(nil, "malloc_trim") { _ = unsafeBitCast(f, to: Trim.self)(0) }
    #endif
}

private func mib(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }

func measureCache() async {
    let bodyBytes = tileBodies.map(\.count).reduce(0, +)
    let client = AtgeoClient(server: URL(string: "https://bench.example")!, transport: BenchTransport())
    releaseFreeMemory()
    let before = residentBytes()
    for i in 0..<fillSearches {
        _ = try! await client.searchPlaces(region: region, dataset: "fill.\(i * 8).8")
    }
    let grown = residentBytes() - before
    releaseFreeMemory()
    let live = residentBytes() - before
    // Every tile body is the same size to within a few bytes, so the cache holds the budget's worth of them.
    let tileSize = bodyBytes / fillTiles
    let cached = AtgeoClient.defaultCacheBudgetBytes / tileSize * tileSize
    let ratio = { (bytes: Int) in String(format: "%.2f", Double(bytes) / Double(cached)) }
    print("Tile cache, default budget full after \(fillSearches) searches of 8 tiles (\(fillTiles) tiles, \(mib(bodyBytes)) MiB of bodies)\n")
    print("| Bodies cached, MiB | Resident growth, MiB | Ratio | After releasing free memory, MiB | Ratio |")
    print("|---:|---:|---:|---:|---:|")
    print("| \(mib(cached)) | \(mib(grown)) | \(ratio(grown)) | \(mib(live)) | \(ratio(live)) |\n")
    withExtendedLifetime(client) {}
}

/// A search with text over a warm region of `warmTiles` tiles, as a user types: no requests, so the time is
/// parsing, if any, and ranking.
func timeWarmSearch() async {
    print("\nA search with text over a warm region (\(warmTiles) tiles, \(warmTiles * recordsPerTile) records), median ms of 20\n")
    print("| Names | Places in the region | ms |")
    print("|---|---:|---:|")
    let cases: [(names: String, region: Region, typed: String)] = [
        ("ASCII", region, "manchester s"), ("accented", accentedRegion, "bäckerei mü"),
    ]
    for c in cases {
        let client = AtgeoClient(server: URL(string: "https://bench.example")!, transport: BenchTransport())
        let warm = try! await client.searchPlaces(region: c.region, dataset: "openstreetmap.org", collection: "node")
        let texts = (1...c.typed.count).map { String(c.typed.prefix($0)) }
        var times: [Double] = []
        for text in (texts + texts).prefix(20) {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try! await client.searchPlaces(region: c.region, text: text, dataset: "openstreetmap.org", collection: "node")
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let names = Set(warm.places.compactMap { $0.place["name"]?.stringValue })
        let accented = names.filter { $0.utf8.contains { $0 >= 0x80 } }.count * 100 / max(names.count, 1)
        print("| \(c.names), \(accented)% non-ASCII | \(warm.places.count) | \(String(format: "%.1f", times.sorted()[times.count / 2])) |")
    }
}

// First, before anything else has grown the heap, so the resident-memory deltas are the cache's.
await measureCache()

var bodies: [(name: String, data: Data)] = [
    ("synthetic", syntheticTile(records: 886)), ("synthetic, accented", syntheticTile(records: 886, accented: true)),
]
for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(1)
    }
    bodies.append((URL(fileURLWithPath: path).lastPathComponent, data))
}

#if os(Linux)
let platform = "Linux"
#else
let platform = ProcessInfo.processInfo.operatingSystemVersionString
#endif
print("JSON parsing, \(platform), median ms of 15\n")
print("| Body | KiB | Records | parseJSON | JSONDecoder → JSONValue | JSONSerialization | JSONSerialization → JSONValue |")
print("|---|---:|---:|---:|---:|---:|---:|")
for (name, data) in bodies {
    var value = JSONValue.null
    let decoder = try median { value = try JSONDecoder().decode(JSONValue.self, from: data) }
    let parser = try median { _ = try parseJSON(data) }
    let serialization = try median { _ = try JSONSerialization.jsonObject(with: data) }
    let converted = try median { _ = jsonValue(try JSONSerialization.jsonObject(with: data)) }
    // The parsers must agree, or the timings compare different work.
    guard jsonValue(try JSONSerialization.jsonObject(with: data)) == value,
        try parseJSON(data) == value
    else {
        FileHandle.standardError.write(Data("\(name): the parsers disagree\n".utf8))
        exit(1)
    }
    let records = value["records"]?.arrayValue?.count ?? 0
    let ms = { (t: Double) in String(format: "%.1f", t) }
    print("| \(name) | \(data.count / 1024) | \(records) | \(ms(parser)) | \(ms(decoder)) | \(ms(serialization)) | \(ms(converted)) |")
}

print("\nThe client's whole per-tile parse (body to the records a search reads), \(platform), median ms of 15\n")
print("| Body | KiB | ms |")
print("|---|---:|---:|")
for (name, data) in bodies {
    let tile = try median { _ = try benchmarkParseTile(data) }
    print("| \(name) | \(data.count / 1024) | \(String(format: "%.1f", tile)) |")
}

await timeWarmSearch()

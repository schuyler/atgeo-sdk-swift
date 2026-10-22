// Times JSON parsing of a tile-sized body (design review note 12), including the client's own parser. Not part of `swift test`: run it as
// `swift run -c release atgeo-bench [tile.json ...]`. With no arguments it times a synthetic tile shaped like
// an OSM tile from places.atgeo.org; each argument adds a real body read from that file.
@_spi(Benchmark) import Atgeo
import Foundation

/// A deterministic tile: `count` records with the shape and size of the OSM tiles places.atgeo.org serves
/// (about 990 bytes each: a point with string coordinates, five attributes, four `within` relations, an
/// integer importance; one record in twenty has a variant).
func syntheticTile(records count: Int) -> Data {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed >> 33
    }
    func word() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<(4 + Int(next() % 8))).map { _ in letters[Int(next() % 26)] })
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

/// `JSONValue`'s decoder with `String` tried first. `JSONValue.init(from:)` tries `Bool`, then `Double`, then
/// `String`, so each string value, most of a tile, first throws two `DecodingError`s. This times what those
/// throws cost; it is not what the client runs.
enum StringFirst: Decodable {
    case null, bool(Bool), number(Double), string(String), array([StringFirst]), object([String: StringFirst])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let a = try? container.decode([StringFirst].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode([String: StringFirst].self))
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .number(let d): .number(d)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(\.jsonValue))
        case .object(let o): .object(o.mapValues(\.jsonValue))
        }
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

var bodies: [(name: String, data: Data)] = [("synthetic", syntheticTile(records: 886))]
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
print("| Body | KiB | Records | JSONDecoder → JSONValue | same, String first | JSONSerialization | JSONSerialization → JSONValue | parseJSON |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for (name, data) in bodies {
    var value = JSONValue.null
    let decoder = try median { value = try JSONDecoder().decode(JSONValue.self, from: data) }
    let stringFirst = try median { _ = try JSONDecoder().decode(StringFirst.self, from: data) }
    let parser = try median { _ = try parseJSON(data) }
    let serialization = try median { _ = try JSONSerialization.jsonObject(with: data) }
    let converted = try median { _ = jsonValue(try JSONSerialization.jsonObject(with: data)) }
    // The parsers must agree, or the timings compare different work.
    guard jsonValue(try JSONSerialization.jsonObject(with: data)) == value,
        try JSONDecoder().decode(StringFirst.self, from: data).jsonValue == value,
        try parseJSON(data) == value
    else {
        FileHandle.standardError.write(Data("\(name): the parsers disagree\n".utf8))
        exit(1)
    }
    let records = value["records"]?.arrayValue?.count ?? 0
    let ms = { (t: Double) in String(format: "%.1f", t) }
    print("| \(name) | \(data.count / 1024) | \(records) | \(ms(decoder)) | \(ms(stringFirst)) | \(ms(serialization)) | \(ms(converted)) | \(ms(parser)) |")
}

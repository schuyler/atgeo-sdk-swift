import Foundation

// ---------- Contract §7: normalization, exactly as the Swift spec §6 writes it ----------
let whitespace: Set<Unicode.Scalar> = [
    "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}",
    "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
    "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
    "\u{205F}", "\u{3000}", "\u{FEFF}",
]

func normalize(_ s: String) -> String {
    let folded = s.lowercased().decomposedStringWithCompatibilityMapping
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for u in folded.unicodeScalars {
        if u.properties.generalCategory == .nonspacingMark { continue }
        if whitespace.contains(u) { pendingSpace = !out.isEmpty; continue }
        if pendingSpace { out.append(" "); pendingSpace = false }
        out.append(u)
    }
    return String(out)
}

// ---------- Contract §7: Jaro-Winkler on UTF-16 code units ----------
func jaro(_ a: [UInt16], _ b: [UInt16]) -> Double {
    if a == b { return 1 }
    if a.isEmpty || b.isEmpty { return 0 }
    let reach = max(0, max(a.count, b.count) / 2 - 1)
    var aM = [Bool](repeating: false, count: a.count)
    var bM = [Bool](repeating: false, count: b.count)
    var matches = 0
    for i in 0..<a.count {
        let lo = max(0, i - reach), hi = min(b.count - 1, i + reach)
        if lo > hi { continue }   // JS's for-loop simply doesn't run; Swift's lo...hi would trap
        for j in lo...hi where !bM[j] && a[i] == b[j] {
            aM[i] = true; bM[j] = true; matches += 1; break
        }
    }
    if matches == 0 { return 0 }
    var t = 0, j = 0
    for i in 0..<a.count where aM[i] {
        while !bM[j] { j += 1 }
        if a[i] != b[j] { t += 1 }
        j += 1
    }
    let m = Double(matches)
    return (m / Double(a.count) + m / Double(b.count) + (m - Double(t) / 2) / m) / 3
}
func jaroWinkler(_ sa: String, _ sb: String) -> Double {
    let a = Array(sa.utf16), b = Array(sb.utf16)
    let sim = jaro(a, b)
    var p = 0
    while p < 4 && p < a.count && p < b.count && a[p] == b[p] { p += 1 }
    return sim + Double(p) * 0.1 * (1 - sim)
}

// ---------- Contract §3: regions, snapping, bbox strings ----------
let DEG_TO_M = 111194.927
let EARTH_RADIUS_M = 6371008.8
let EPS = 1e-9
let rad = Double.pi / 180

enum Region { case circle(lat: Double, lon: Double, radius: Double); case bbox(Double, Double, Double, Double) }

func lonSegments(_ minLon: Double, _ maxLon: Double) -> [(Double, Double)] {
    minLon <= maxLon ? [(minLon, maxLon)] : [(minLon, 180), (-180, maxLon)]
}
func circleBox(_ lat: Double, _ lon: Double, _ radius: Double) -> (Double, Double, Double, Double) {
    let half = radius / DEG_TO_M
    let minLat = max(lat - half, -90), maxLat = min(lat + half, 90)
    let sinHalfLon = sin(half * rad) / cos(lat * rad)
    if minLat == -90 || maxLat == 90 || !(sinHalfLon < 1) { return (-180, minLat, 180, maxLat) }
    let halfLon = asin(sinHalfLon) / rad
    func wrap(_ x: Double) -> Double { x > 180 ? x - 360 : x < -180 ? x + 360 : x }
    return (wrap(lon - halfLon), minLat, wrap(lon + halfLon), maxLat)
}
func snapDown(_ x: Double) -> Int { let r = (x * 100).rounded(); return abs(x * 100 - r) < EPS ? Int(r) : Int((x * 100).rounded(.down)) }
func snapUp(_ x: Double) -> Int { let r = (x * 100).rounded(); return abs(x * 100 - r) < EPS ? Int(r) : Int((x * 100).rounded(.up)) }
func snapSpan(_ lo0: Double, _ hi0: Double, _ limit: Int) -> (Int, Int) {
    var lo = snapDown(lo0), hi = snapUp(hi0)
    if lo == hi { if hi < limit * 100 { hi += 1 } else { lo -= 1 } }
    return (lo, hi)
}
// Integer formatting: no Foundation, no locale, no negative zero.
func fixed(_ units: Int) -> String {
    let a = abs(units)
    return "\(units < 0 ? "-" : "")\(a / 100).\(a % 100 < 10 ? "0" : "")\(a % 100)"
}
func fixedFoundation(_ units: Int) -> String { String(format: "%.2f", Double(units) / 100) }
func queryBboxes(_ region: Region) -> [String] {
    let (minLon, minLat, maxLon, maxLat): (Double, Double, Double, Double)
    switch region {
    case let .bbox(a, b, c, d): (minLon, minLat, maxLon, maxLat) = (a, b, c, d)
    case let .circle(lat, lon, r): (minLon, minLat, maxLon, maxLat) = circleBox(lat, lon, r)
    }
    let (lat0, lat1) = snapSpan(minLat, maxLat, 90)
    return lonSegments(minLon, maxLon).map { lo, hi in
        let (lon0, lon1) = snapSpan(lo, hi, 180)
        return [lon0, lat0, lon1, lat1].map(fixed).joined(separator: ",")
    }
}

// ---------- Contract §6: distance ----------
func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let a = pow(sin((lat2 - lat1) * rad / 2), 2) + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin((lon2 - lon1) * rad / 2), 2)
    return 2 * EARTH_RADIUS_M * asin(min(1, sqrt(a)))
}
func lonIn(_ lon: Double, _ segs: [(Double, Double)]) -> Bool { segs.contains { lon >= $0.0 && lon <= $0.1 } }
func gap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
func covers(_ s: Double, _ n: Double, _ segs: [(Double, Double)], _ lat: Double, _ lon: Double) -> Bool {
    if lat < s || lat > n { return false }
    return abs(lat) == 90 || lonIn(lon, segs) || (abs(lon) == 180 && lonIn(-lon, segs))
}
struct Box { let south: Double, north: Double, segs: [(Double, Double)] }
func distanceToBox(_ b: Box, _ lat: Double, _ lon: Double) -> Double {
    if covers(b.south, b.north, b.segs, lat, lon) { return 0 }
    var lonStar = lon
    if !lonIn(lon, b.segs) {
        let ends = b.segs.flatMap { [$0.0, $0.1] }
        lonStar = ends.dropFirst().reduce(ends[0]) { best, e in gap(e, lon) < gap(best, lon) ? e : best }
    }
    let phi0 = lat * rad, dLon = gap(lonStar, lon) * rad
    let phiC = atan2(sin(phi0), cos(phi0) * cos(dLon)) / rad
    return min(haversine(lat, lon, min(max(phiC, b.south), b.north), lonStar),
               haversine(lat, lon, b.south, lonStar), haversine(lat, lon, b.north, lonStar))
}

// ---------- runner ----------
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { pass += 1 } else { fail += 1; print("FAIL \(name) \(detail())") }
}
func scalars(_ s: String) -> String { s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") }
let fixtures = CommandLine.arguments[1]
func loadJSON(_ name: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixtures + "/" + name)))
}

print("== normalize.json")
for c in loadJSON("normalize.json") as! [[String: String]] {
    let got = normalize(c["input"]!)
    check("normalize \(c["input"]!.debugDescription)", got == c["expected"]!, "got \(got.debugDescription) [\(scalars(got))] want [\(scalars(c["expected"]!))]")
}
print("== jaro-winkler.json")
for c in loadJSON("jaro-winkler.json") as! [[String: Any]] {
    let a = c["a"] as! String, b = c["b"] as! String, want = c["score"] as! Double
    let got = jaroWinkler(a, b)
    check("jw \(a) / \(b)", abs(got - want) <= 5e-7, "got \(got) want \(want)")
    check("jw symmetric \(a) / \(b)", got == jaroWinkler(b, a))
}
check("jw emoji by code units", abs(jaroWinkler("😀😁", "😀😂") - 0.8833333333333334) < 1e-12, "\(jaroWinkler("😀😁", "😀😂"))")

print("== contract §7 examples not in the fixture")
let sigma = normalize("ΟΔΟΣ")
check("final sigma ΟΔΟΣ -> οδος (U+03C2 last)", sigma == "οδο\u{03C2}", "got [\(scalars(sigma))]")
check("İstanbul -> istanbul", normalize("İstanbul") == "istanbul", "got [\(scalars(normalize("İstanbul")))]")
check("ẞ -> ß", normalize("ẞ") == "ß", "got [\(scalars(normalize("ẞ")))]")
check("① -> 1", normalize("①") == "1")
check("½ -> 1⁄2", normalize("½") == "1\u{2044}2", "got [\(scalars(normalize("½")))]")
check("a+U+20DD unchanged (Me kept)", normalize("a\u{20DD}") == "a\u{20DD}")
check("U+200B not whitespace", normalize("a\u{200B}b") == "a\u{200B}b")
check("U+0085 not whitespace", normalize("a\u{85}b") == "a\u{85}b")

print("== contract §3 worked bbox examples")
let bboxTable: [(Region, [String])] = [
    (.circle(lat: 37.7598, lon: -122.4194, radius: 1000), ["-122.44,37.75,-122.40,37.77"]),
    (.circle(lat: 10, lon: 20, radius: 0), ["20.00,10.00,20.01,10.01"]),
    (.circle(lat: 0, lon: 179.999, radius: 5000), ["179.95,-0.05,180.00,0.05", "-180.00,-0.05,-179.95,0.05"]),
    (.circle(lat: 0, lon: -179.999, radius: 5000), ["179.95,-0.05,180.00,0.05", "-180.00,-0.05,-179.95,0.05"]),
    (.circle(lat: 89.9, lon: 0, radius: 50000), ["-180.00,89.45,180.00,90.00"]),
    (.circle(lat: 80, lon: 0, radius: 100000), ["-5.19,79.10,5.19,80.90"]),
    (.circle(lat: -0.0, lon: -0.0, radius: 0), ["0.00,0.00,0.01,0.01"]),
    (.bbox(-122.42, 37.77, -122.41, 37.78), ["-122.42,37.77,-122.41,37.78"]),
    (.bbox(-122.4194155, 37.7749295, -122.4094155, 37.7849295), ["-122.42,37.77,-122.40,37.79"]),
    (.bbox(170, 10, -170, 20), ["170.00,10.00,180.00,20.00", "-180.00,10.00,-170.00,20.00"]),
    (.bbox(180, 90, 180, 90), ["179.99,89.99,180.00,90.00"]),
    (.bbox(10, 10, 10.5, 10), ["10.00,10.00,10.50,10.01"]),
    (.circle(lat: 60, lon: 0, radius: 20 * 111194.927), ["-43.17,40.00,43.17,80.00"]),
    (.bbox(10.005, 20.005, 10.005, 20.005), ["10.00,20.00,10.01,20.01"]),
]
for (i, (r, want)) in bboxTable.enumerated() { check("bbox row \(i)", queryBboxes(r) == want, "got \(queryBboxes(r)) want \(want)") }
var k = 0
while k < 9000 { // region.test.ts "does not widen grid-aligned values anywhere on the grid"
    let lat = [Double(k + 1) / 100, Double(k + 6) / 100], lon = [-Double(k + 8) / 100, -Double(k + 5) / 100]
    let want = [lon[0], lat[0], lon[1], lat[1]].map { fixedFoundation(Int(($0 * 100).rounded())) }.joined(separator: ",")
    check("grid \(k)", queryBboxes(.bbox(lon[0], lat[0], lon[1], lat[1])) == [want], "got \(queryBboxes(.bbox(lon[0], lat[0], lon[1], lat[1]))) want \(want)")
    k += 97
}

print("== contract §6 worked distance examples")
check("1 deg lat", abs(haversine(0, 0, 1, 0) - 111195.0802335329) / 111195.0802335329 < 1e-6, "\(haversine(0, 0, 1, 0))")
check("SF-LA", abs(haversine(37.7749, -122.4194, 34.0522, -118.2437) - 559121.3493517868) / 559121.3493517868 < 1e-6)
check("point 0.001,0", abs(haversine(0, 0, 0.001, 0) - 111.19508023353292) / 111.19508023353292 < 1e-6)
let box = { (n: Double, s: Double, e: Double, w: Double) in Box(south: s, north: n, segs: lonSegments(w, e)) }
let distTable: [(Box, Double, Double, Double)] = [
    (box(46, 44, 11, 9), 45, 10, 0),
    (box(46, 44, 11, 9), 45, 8, 78624.79923702011),
    (box(46, 44, 11, 9), 47, 10, 111195.0802335329),
    (box(46, 44, 11, 9), 47, 8, 134989.80127268212),
    (box(80, 70, 30, 10), 75, 60, 826787.9307589367),
    (box(50, 40, -170, -180), 45, 180, 0),
    (box(10, -10, -170, 170), 0, 160, 1111950.8023353291),
]
for (i, (b, lat, lon, want)) in distTable.enumerated() {
    let got = distanceToBox(b, lat, lon)
    check("dist row \(i)", want == 0 ? got == 0 : abs(got - want) / want < 1e-6, "got \(got) want \(want)")
}
check("containment exact: 46.0986,10.5 in box", distanceToBox(box(47, 46, 11, 10), 46.0986, 10.5) == 0)
check("pole centre in box excluding lon 0", distanceToBox(box(-80, -90, 20, 10), -90, 0) == 0)

print("== Swift semantics the spec relies on")
print("Int size bytes:", MemoryLayout<Int>.size)
print("String(format: %.2f, -0.0) =", String(format: "%.2f", -0.0))
print("(-2.5).rounded() =", (-2.5).rounded(), " (JS Math.round(-2.5) = -2)")
print("(2.5).rounded() =", (2.5).rounded())
print("Double(\"0x10\") =", Double("0x10") as Any, " (JS parseFloat -> 0)")
print("Double(\" 1\") =", Double(" 1") as Any)
print("Double(\"1.5abc\") =", Double("1.5abc") as Any)
print("Double(\"Infinity\") =", Double("Infinity") as Any, " Double(\"inf\") =", Double("inf") as Any, " Double(\"nan\") =", Double("nan") as Any)
print("Double(\"+1.5e2\") =", Double("+1.5e2") as Any, " Double(\".5\") =", Double(".5") as Any, " Double(\"5.\") =", Double("5.") as Any)
print("String == canonical equivalence: \"\\u{E9}\" == \"e\\u{301}\" ->", "\u{E9}" == "e\u{301}")
print("String < vs UTF-16: \"\\u{10000}\" < \"\\u{FF61}\" ->", "\u{10000}" < "\u{FF61}", " utf16 precedes ->", "\u{10000}".utf16.lexicographicallyPrecedes("\u{FF61}".utf16), " (JS: true)")
print("\"https://a/10\" < \"https://a/9\" ->", "https://a/10" < "https://a/9", " \"https://A\" < \"https://a\" ->", "https://A" < "https://a")
print("Character.isWhitespace U+0085:", Character("\u{85}").isWhitespace, " U+FEFF:", Character("\u{FEFF}").isWhitespace, " U+200B:", Character("\u{200B}").isWhitespace)
print("lowercaseMapping U+03A3 (Σ):", scalars(Unicode.Scalar(0x3A3)!.properties.lowercaseMapping), " U+0130 (İ):", scalars(Unicode.Scalar(0x130)!.properties.lowercaseMapping))
print("\"ΟΔΟΣ\".lowercased() =", scalars("ΟΔΟΣ".lowercased()))
print("NSString lowercased(with: nil) ΟΔΟΣ =", scalars(("ΟΔΟΣ" as NSString).lowercased(with: nil)))
var comps = URLComponents(string: "https://places.atgeo.org/xrpc/org.atgeo.getPlace")!
comps.queryItems = [URLQueryItem(name: "uri", value: "a+b&c=d#e f%g,h:i/j?k")]
print("URLComponents.queryItems encodes value \"a+b&c=d#e f%g,h:i/j?k\" as:", comps.percentEncodedQuery ?? "nil")
let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
print("addingPercentEncoding(unreserved):", "a+b&c=d#e f%g,h:i/j?k".addingPercentEncoding(withAllowedCharacters: unreserved) ?? "nil")
print("URL trailing slash: URL(string: \"http://localhost:8000/\")!.absoluteString =", URL(string: "http://localhost:8000/")!.absoluteString)

// JSONValue decode ordering through JSONDecoder
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}
let sample = #"[true, false, 0, 1, 1.5, "1", "true", null, 9007199254740993, -0.0, 1e300, {"a":[]}]"#.data(using: .utf8)!
print("JSONDecoder JSONValue:", (try? JSONDecoder().decode([JSONValue].self, from: sample)) as Any)
struct Rec: Decodable { let importance: Int64? }
print("Int64 from 0.5 ->", (try? JSONDecoder().decode(Rec.self, from: #"{"importance":0.5}"#.data(using: .utf8)!)) as Any)
print("Int64 from 9223372036854775807 ->", (try? JSONDecoder().decode(Rec.self, from: #"{"importance":9223372036854775807}"#.data(using: .utf8)!))?.importance as Any)
print("JSONDecoder on 1e400 ->", (try? JSONDecoder().decode([JSONValue].self, from: "[1e400]".data(using: .utf8)!)) as Any)

print("\n\(pass) passed, \(fail) failed")

import Foundation

// Reading a place's location (contract §5), distance and containment (§6).

private let earthRadiusM = 6371008.8

struct Locations {
    struct Box {
        var south: Double
        var north: Double
        /// As read, so that `west > east` marks a box across the antimeridian (contract §5).
        var west: Double
        var east: Double
        var segments: [LonSegment]
    }
    var point: (lat: Double, lon: Double)?
    var bbox: Box?
}

/// A coordinate from a JSON number, or from a string holding a decimal number. `Double(String)` also
/// accepts hex floats, `inf` and `nan`, so a string must consist of decimal-number characters only and
/// the result must be finite (design review, note 8). Anything else is no coordinate (contract §16).
func coordinate(_ v: JSONValue?) -> Double? {
    let d: Double?
    switch v {
    case .number(let n)?:
        d = n
    case .string(let s)?:
        d = s.utf8.allSatisfy({ "+-.0123456789eE".utf8.contains($0) }) ? Double(s) : nil
    default:
        d = nil
    }
    guard let d, d.isFinite else { return nil }
    return d
}

func locate(_ value: JSONObject) -> Locations {
    var result = Locations()
    for element in value["locations"]?.arrayValue ?? [] {
        // A non-object element, `null` included (contract §16), is skipped.
        guard let loc = element.objectValue, let type = loc["$type"]?.stringValue else { continue }
        if ordinalEqual(type, "community.lexicon.location.geo") && result.point == nil {
            if let lat = coordinate(loc["latitude"]), let lon = coordinate(loc["longitude"]) {
                result.point = (lat, lon)
            }
        } else if ordinalEqual(type, "community.lexicon.location.bbox") && result.bbox == nil {
            if let south = coordinate(loc["south"]), let north = coordinate(loc["north"]),
               let west = coordinate(loc["west"]), let east = coordinate(loc["east"]) {
                result.bbox = Locations.Box(south: south, north: north, west: west, east: east, segments: lonSegments(west, east))
            }
        }
    }
    return result
}

/// The `name` and `location` accessors of a hit or place record (contract §8): the first usable point and the
/// first usable box, the box with its west and east as given.
func placeLocation(_ value: JSONObject) -> PlaceLocation {
    let locations = locate(value)
    return PlaceLocation(
        point: locations.point.map { .init(lat: $0.lat, lon: $0.lon) },
        bbox: locations.bbox.map { .init(south: $0.south, west: $0.west, north: $0.north, east: $0.east) })
}

func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let rad = Double.pi / 180
    let sLat = sin((lat2 - lat1) * rad / 2)
    let sLon = sin((lon2 - lon1) * rad / 2)
    let a = sLat * sLat + cos(lat1 * rad) * cos(lat2 * rad) * sLon * sLon
    return 2 * earthRadiusM * asin(min(1, a.squareRoot()))
}

private func lonInSegments(_ lon: Double, _ segments: [LonSegment]) -> Bool {
    segments.contains { lon >= $0.lo && lon <= $0.hi }
}

private func lonSegmentsOverlap(_ a: [LonSegment], _ b: [LonSegment]) -> Bool {
    a.contains { x in b.contains { y in x.lo <= y.hi && y.lo <= x.hi } }
}

private func angularGap(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
}

/// `lon` if a segment holds it, else the nearest endpoint; on a tie the first in segment order wins.
private func nearestLon(_ lon: Double, _ segments: [LonSegment]) -> Double {
    if lonInSegments(lon, segments) { return lon }
    let ends = segments.flatMap { [$0.lo, $0.hi] }
    var best = ends[0]
    for e in ends.dropFirst() where angularGap(e, lon) < angularGap(best, lon) { best = e }
    return best
}

/// ±180 are one meridian, and every meridian meets at a pole.
private func covers(_ south: Double, _ north: Double, _ segments: [LonSegment], _ lat: Double, _ lon: Double) -> Bool {
    if lat < south || lat > north { return false }
    return abs(lat) == 90 || lonInSegments(lon, segments) || (abs(lon) == 180 && lonInSegments(-lon, segments))
}

/// The box-to-box form of covers(): boxes touching ±180 meet at the seam, and boxes reaching a pole meet there.
private func meets(_ box: Locations.Box, _ south: Double, _ north: Double, _ segments: [LonSegment]) -> Bool {
    let lo = max(box.south, south)
    let hi = min(box.north, north)
    if lo > hi { return false }
    let twins = box.segments.flatMap { s -> [LonSegment] in
        var out = [s]
        if s.hi == 180 { out.append((-180, -180)) }
        if s.lo == -180 { out.append((180, 180)) }
        return out
    }
    return hi == 90 || lo == -90 || lonSegmentsOverlap(twins, segments)
}

/// Metres from (lat, lon) to the nearest point of the place; nil without a location. Containment is tested
/// first, so it yields exactly 0 rather than trigonometric round-trip noise.
func distanceTo(_ locations: Locations, lat: Double, lon: Double) -> Double? {
    if let point = locations.point {
        if covers(point.lat, point.lat, [(point.lon, point.lon)], lat, lon) { return 0 }
        return haversine(lat, lon, point.lat, point.lon)
    }
    guard let box = locations.bbox else { return nil }
    if covers(box.south, box.north, box.segments, lat, lon) { return 0 }
    // Along the nearest meridian, cos(d) = R cos(phi - phiC); phiC is where that meridian comes closest.
    let lonStar = nearestLon(lon, box.segments)
    let phi0 = lat * .pi / 180
    let dLon = angularGap(lonStar, lon) * .pi / 180
    let phiC = atan2(sin(phi0), cos(phi0) * cos(dLon)) * 180 / .pi
    return min(
        haversine(lat, lon, min(max(phiC, box.south), box.north), lonStar),
        haversine(lat, lon, box.south, lonStar),
        haversine(lat, lon, box.north, lonStar))
}

func inRegion(_ locations: Locations, _ region: Region) -> Bool {
    switch region {
    case let .bbox(minLon, minLat, maxLon, maxLat):
        let segments = lonSegments(minLon, maxLon)
        if let point = locations.point { return covers(minLat, maxLat, segments, point.lat, point.lon) }
        guard let box = locations.bbox else { return false }
        return meets(box, minLat, maxLat, segments)
    case let .circle(lat, lon, radius):
        guard let d = distanceTo(locations, lat: lat, lon: lon) else { return false }
        return d <= radius
    }
}

import Foundation

// Regions, contract §3.

public enum Region: Sendable, Hashable {
    /// Radius in metres.
    case circle(lat: Double, lon: Double, radius: Double)
    /// Degrees. `west > east` crosses the antimeridian.
    case bbox(west: Double, south: Double, east: Double, north: Double)
}

let degToM = 111194.927
private let epsilon = 1e-9

/// The bbox and circle checks, in the contract's order. The similarity-requires-text check needs the
/// normalized text and lives in the client.
func validateRegion(_ region: Region) throws(AtgeoArgumentError) {
    func ok(_ n: Double, _ limit: Double) -> Bool { n.isFinite && abs(n) <= limit }
    switch region {
    case let .bbox(minLon, minLat, maxLon, maxLat):
        if !ok(minLon, 180) || !ok(maxLon, 180) || !ok(minLat, 90) || !ok(maxLat, 90) || minLat > maxLat {
            throw .invalidRegion("invalid bbox")
        }
    case let .circle(lat, lon, radius):
        if !ok(lat, 90) || !ok(lon, 180) || !radius.isFinite || radius < 0 {
            throw .invalidRegion("invalid circle")
        }
    }
}

func center(_ region: Region) -> (lat: Double, lon: Double) {
    switch region {
    case let .circle(lat, lon, _):
        return (lat, lon)
    case let .bbox(minLon, minLat, maxLon, maxLat):
        var lon = minLon <= maxLon ? (minLon + maxLon) / 2 : (minLon + maxLon + 360) / 2
        if lon > 180 { lon -= 360 }
        return ((minLat + maxLat) / 2, lon)
    }
}

typealias LonSegment = (lo: Double, hi: Double)

/// A box with minLon > maxLon crosses the antimeridian: two segments.
func lonSegments(_ minLon: Double, _ maxLon: Double) -> [LonSegment] {
    minLon <= maxLon ? [(minLon, maxLon)] : [(minLon, 180), (-180, maxLon)]
}

/// The circle's enclosing box; minLon > maxLon when it wraps the antimeridian.
func circleBox(lat: Double, lon: Double, radius: Double) -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
    let half = radius / degToM
    let minLat = max(lat - half, -90)
    let maxLat = min(lat + half, 90)
    // Half-width of a spherical cap: asin(sin r / cos lat). At or past 1 (or NaN) the cap holds a pole.
    let sinHalfLon = sin(half * .pi / 180) / cos(lat * .pi / 180)
    if minLat == -90 || maxLat == 90 || !(sinHalfLon < 1) { return (-180, minLat, 180, maxLat) }
    let halfLon = asin(sinHalfLon) * 180 / .pi
    func wrap(_ x: Double) -> Double { x > 180 ? x - 360 : x < -180 ? x + 360 : x }
    return (wrap(lon - halfLon), minLat, wrap(lon + halfLon), maxLat)
}

// `rounded()` is half away from zero where JavaScript's Math.round is half up; the difference never
// matters, because `r` is used only when x * 100 is within 1e-9 of an integer (contract §3).
private func snapDown(_ x: Double) -> Int {
    let r = (x * 100).rounded()
    return Int(abs(x * 100 - r) < epsilon ? r : (x * 100).rounded(.down))
}

private func snapUp(_ x: Double) -> Int {
    let r = (x * 100).rounded()
    return Int(abs(x * 100 - r) < epsilon ? r : (x * 100).rounded(.up))
}

/// Outward snap to hundredths of a degree; a point or line widens by one step, inward at the axis limit.
private func snapSpan(_ min: Double, _ max: Double, limit: Int) -> (lo: Int, hi: Int) {
    var lo = snapDown(min)
    var hi = snapUp(max)
    if lo == hi {
        if hi < limit * 100 { hi += 1 } else { lo -= 1 }
    }
    return (lo, hi)
}

/// Hundredths of a degree with exactly two decimals. Integer arithmetic, so there is no negative zero and
/// no locale (design review, note 7).
private func fixed(_ units: Int) -> String {
    let a = abs(units)
    return "\(units < 0 ? "-" : "")\(a / 100).\(a % 100 < 10 ? "0" : "")\(a % 100)"
}

/// Snapped, serialized getTiles bbox strings, one per antimeridian half, in call order.
func queryBboxes(_ region: Region) -> [String] {
    let (minLon, minLat, maxLon, maxLat): (Double, Double, Double, Double)
    switch region {
    case let .bbox(a, b, c, d): (minLon, minLat, maxLon, maxLat) = (a, b, c, d)
    case let .circle(lat, lon, radius): (minLon, minLat, maxLon, maxLat) = circleBox(lat: lat, lon: lon, radius: radius)
    }
    let lat = snapSpan(minLat, maxLat, limit: 90)
    return lonSegments(minLon, maxLon).map { segment in
        let lon = snapSpan(segment.lo, segment.hi, limit: 180)
        return [lon.lo, lat.lo, lon.hi, lat.hi].map(fixed).joined(separator: ",")
    }
}

/// The `bbox` a keyword search sends (contract §16): the smallest box of whole degrees the server accepts that
/// covers the input, as `west,south,east,north` integers. `region` is validated as a bbox first. Plain integers,
/// so there is no `-0`, no fraction and no exponent. A zero-width span widens by one cell, inward at the axis
/// limit; a box that crosses the antimeridian keeps its shape only if its snapped edges still cross validly, else
/// it becomes the full band.
func keywordBbox(_ region: KeywordRegion) -> String {
    // The input is finite and within ±180 and ±90 (validateRegion), so the conversions to Int cannot trap.
    func span(_ low: Double, _ high: Double, limit: Int) -> (lo: Int, hi: Int) {
        var lo = Int(low.rounded(.down))
        var hi = Int(high.rounded(.up))
        if lo == hi {
            if hi < limit { hi += 1 } else { lo -= 1 }
        }
        return (lo, hi)
    }
    let lat = span(region.south, region.north, limit: 90)
    // A crossing box is decided on its input values first: a west of exactly 180 is the meridian at -180, and an
    // east of exactly -180 is the one at 180, so each continues below as a plain box.
    var west = region.west
    var east = region.east
    if west == 180 && west > east { west = -180 }
    if east == -180 && west > east { east = 180 }
    let lon: (lo: Int, hi: Int)
    if west > east {
        let w = Int(west.rounded(.down))
        let e = Int(east.rounded(.up))
        lon = w > 0 && e < 0 ? (w, e) : (-180, 180)
    } else {
        lon = span(west, east, limit: 180)
    }
    return [lon.lo, lat.lo, lon.hi, lat.hi].map { String($0) }.joined(separator: ",")
}

/// The keyword region of a bbox region, or of the box enclosing a circle (contract §18, step 5).
func enclosingKeywordRegion(of region: Region) -> KeywordRegion {
    switch region {
    case let .bbox(west, south, east, north):
        return KeywordRegion(west: west, south: south, east: east, north: north)
    case let .circle(lat, lon, radius):
        let box = circleBox(lat: lat, lon: lon, radius: radius)
        return KeywordRegion(west: box.minLon, south: box.minLat, east: box.maxLon, north: box.maxLat)
    }
}

/// `validateRegion` for a keyword region, which is a bbox: the checks of contract §3, with the same message.
func validateKeywordRegion(_ region: KeywordRegion) throws(AtgeoArgumentError) {
    try validateRegion(.bbox(west: region.west, south: region.south, east: region.east, north: region.north))
}

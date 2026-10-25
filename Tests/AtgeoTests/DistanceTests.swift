import Foundation
import Testing
@testable import Atgeo

// Port of test/distance.test.ts, plus the contract §5 and §6 worked examples.

private func boxAt(_ south: Double, _ north: Double, _ west: Double, _ east: Double) -> Locations {
    locate(place("b", "Box", [bboxLocation(north: north, south: south, east: east, west: west)]))
}

private func pointAt(_ lat: Double, _ lon: Double) -> Locations {
    locate(place("p", "Point", [point(lat, lon)]))
}

/// Minimum haversine distance from the center to a dense sampling of the box boundary.
private func sampledDistance(_ lat: Double, _ lon: Double, _ south: Double, _ north: Double, _ west: Double, _ east: Double) -> Double {
    let steps = 100000
    let spans: [(Double, Double)] = west <= east ? [(west, east)] : [(west, 180), (-180, east)]
    var best = Double.infinity
    for (lo, hi) in spans {
        for i in 0...steps {
            let la = south + (north - south) * Double(i) / Double(steps)
            let lo2 = lo + (hi - lo) * Double(i) / Double(steps)
            for (a, b) in [(la, lo), (la, hi), (south, lo2), (north, lo2)] {
                best = min(best, haversine(lat, lon, a, b))
            }
        }
    }
    return best
}

private func closeRelative(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return b == 0 ? a == 0 : abs(a - b) / abs(b) < 1e-6
}

@Suite("distanceTo: containment is exactly zero") struct ContainmentIsExactlyZero {
    @Test("for a latitude that does not survive a radian round trip")
    func radianRoundTrip() { #expect(distanceTo(boxAt(46, 47, 10, 11), lat: 46.0986, lon: 10.5) == 0) }

    @Test("for center lon 180 in a box with west -180")
    func centreLon180() { #expect(distanceTo(boxAt(40, 50, -180, -170), lat: 45, lon: 180) == 0) }

    @Test("for center lon -180 in a box with east 180")
    func centreLonMinus180() { #expect(distanceTo(boxAt(40, 50, 170, 180), lat: 45, lon: -180) == 0) }

    @Test("for a pole center in a box reaching the pole whose longitudes exclude 0")
    func pole() { #expect(distanceTo(boxAt(-90, -80, 10, 20), lat: -90, lon: 0) == 0) }

    @Test("for a point exactly at the center")
    func pointAtCentre() { #expect(distanceTo(pointAt(46.0986, 10.5), lat: 46.0986, lon: 10.5) == 0) }

    @Test("for a point at a seam longitude and a center at its twin", arguments: [(180.0, -180.0), (-180, 180)])
    func seamTwin(pointLon: Double, centerLon: Double) {
        #expect(distanceTo(pointAt(10, pointLon), lat: 10, lon: centerLon) == 0)
    }
}

@Suite("distanceTo: outside a box") struct OutsideABox {
    @Test("matches the sampled boundary distance", arguments: [
        ("due south within the longitude range", 0.0, 5.0, [10.0, 20, 0, 10]),
        ("east of a high-latitude box", 65, 10, [60, 70, 20, 30]),
        ("more than 90 degrees of longitude away", 50, 0, [40, 60, 120, 140]),
        ("across the antimeridian from a box", 60, -179, [55, 65, 175, 179]),
        ("from an antimeridian-crossing box", 45, -160, [40, 50, 170, -170]),
        ("west of an antimeridian-crossing box", 45, 150, [40, 50, 170, -170]),
    ])
    func sampled(name: String, lat: Double, lon: Double, box: [Double]) throws {
        let (south, north, west, east) = (box[0], box[1], box[2], box[3])
        let expected = sampledDistance(lat, lon, south, north, west, east)
        let actual = try #require(distanceTo(boxAt(south, north, west, east), lat: lat, lon: lon))
        // vitest's toBeCloseTo(expected, 1) is |diff| < 0.05.
        #expect(abs(actual - expected) < 0.05, "\(name)")
    }

    @Test("is strictly less than the latitude-clamped distance for a high-latitude box to the east")
    func lessThanClamped() throws {
        let clamped = haversine(65, 10, 65, 20)
        let actual = try #require(distanceTo(boxAt(60, 70, 20, 30), lat: 65, lon: 10))
        #expect(actual < clamped - 1000)
    }
}

@Suite("distanceTo: no location") struct NoLocation {
    @Test("is nil") func isNil() { #expect(distanceTo(locate(place("n", "None", [])), lat: 0, lon: 0) == nil) }
}

@Suite("inRegion: bbox region seams") struct BboxRegionSeams {
    private static func region(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> Region {
        .bbox(west: west, south: south, east: east, north: north)
    }

    @Test("keeps")
    func keeps() {
        let cases: [(String, Locations, Region)] = [
            ("a point at lon 180 in a region with west -180", pointAt(45, 180), Self.region(-180, 40, -170, 50)),
            ("a point at lon -180 in a region with east 180", pointAt(45, -180), Self.region(170, 40, 180, 50)),
            ("a box ending at 180 and a region starting at -180", boxAt(40, 50, 170, 180), Self.region(-180, 40, -170, 50)),
            ("a box starting at -180 and a region ending at 180", boxAt(40, 50, -180, -170), Self.region(170, 40, 180, 50)),
            ("a point at the pole whatever its longitude", pointAt(90, 0), Self.region(10, 80, 20, 90)),
            ("a box reaching the pole at other longitudes", boxAt(85, 90, 100, 110), Self.region(10, 80, 20, 90)),
        ]
        for (name, locations, region) in cases { #expect(inRegion(locations, region), "\(name)") }
    }

    @Test("drops")
    func drops() {
        let cases: [(String, Locations, Region)] = [
            ("a point just short of the seam", pointAt(45, 179.99), Self.region(-180, 40, -170, 50)),
            ("a box just short of the seam", boxAt(40, 50, 160, 179.99), Self.region(-180, 40, -170, 50)),
            ("a polar box when the region stops short of the pole", boxAt(85, 90, 100, 110), Self.region(10, 80, 20, 89.99)),
        ]
        for (name, locations, region) in cases { #expect(!inRegion(locations, region), "\(name)") }
    }
}

@Suite("contract §6 worked examples") struct DistanceWorkedExamples {
    @Test func haversineExamples() {
        #expect(closeRelative(haversine(0, 0, 1, 0), 111195.0802335329))
        #expect(closeRelative(haversine(37.7749, -122.4194, 34.0522, -118.2437), 559121.3493517868))
    }

    // Box given as north, south, east, west, as in the contract's table.
    @Test(arguments: [
        ([46.0, 44, 11, 9], 45.0, 10.0, 0.0),
        ([46, 44, 11, 9], 45, 8, 78624.79923702011),
        ([46, 44, 11, 9], 47, 10, 111195.0802335329),
        ([46, 44, 11, 9], 47, 8, 134989.80127268212),
        ([80, 70, 30, 10], 75, 60, 826787.9307589367),
        ([50, 40, -170, -180], 45, 180, 0),
        ([10, -10, -170, 170], 0, 160, 1111950.8023353291),
    ])
    func box(nsew: [Double], lat: Double, lon: Double, metres: Double) {
        let locations = locate(place("b", "Box", [bboxLocation(north: nsew[0], south: nsew[1], east: nsew[2], west: nsew[3])]))
        let d = distanceTo(locations, lat: lat, lon: lon)
        // Containment exact, everything else to 1e-6 relative.
        #expect(closeRelative(d, metres), "got \(String(describing: d))")
    }

    @Test func pointExample() {
        #expect(closeRelative(distanceTo(pointAt(0.001, 0), lat: 0, lon: 0), 111.19508023353292))
    }

    @Test func circleUsesTheTrueRadius() {
        let north = pointAt(0.001, 0)
        #expect(inRegion(north, .circle(lat: 0, lon: 0, radius: 111.2)))
        #expect(!inRegion(north, .circle(lat: 0, lon: 0, radius: 111.1)))
        #expect(!inRegion(locate(place("n", "None", [])), .circle(lat: 0, lon: 0, radius: 1e9)))
    }

    @Test func aPlaceWithBothIsJudgedOnThePoint() {
        let both = locate(place("x", "X", [point(0, 0), bboxLocation(north: 50, south: 40, east: 10, west: 0)]))
        #expect(!inRegion(both, .bbox(west: 0, south: 40, east: 10, north: 50)))
    }
}

@Suite("contract §5 locate") struct LocateTests {
    private func geo(_ lat: JSONValue, _ lon: JSONValue) -> JSONValue {
        .object(["$type": .string("community.lexicon.location.geo"), "latitude": lat, "longitude": lon])
    }

    @Test func readsNumbersAndDecimalStrings() {
        let p = locate(["locations": .array([geo(.number(1.5), .string("-2.5e1"))])]).point
        #expect(p?.lat == 1.5 && p?.lon == -25)
    }

    @Test("rejects", arguments: [
        JSONValue.string("inf"), .string("Infinity"), .string("nan"), .string("0x10"), .string(" 1.5"),
        .string("1.5abc"), .string(""), .array([.number(0.5)]), .array([.string("0.5")]), .bool(true), .null,
        .object([:]),
    ])
    func rejects(_ v: JSONValue) {
        #expect(locate(["locations": .array([geo(v, .number(0))])]).point == nil)
    }

    @Test func firstUsablePointWinsAndSkipsUnusableElements() {
        let value: JSONObject = ["locations": .array([
            .null, .number(3), .string("x"), .array([]),
            geo(.string("x"), .number(0)),
            .object(["$type": .string("community.lexicon.location.other"), "latitude": .number(9), "longitude": .number(9)]),
            geo(.number(1), .number(2)),
            geo(.number(3), .number(4)),
        ])]
        let p = locate(value).point
        #expect(p?.lat == 1 && p?.lon == 2)
    }

    @Test func boxCrossingTheAntimeridianHasTwoSegments() throws {
        let box = try #require(locate(place("b", "B", [bboxLocation(north: 1, south: 0, east: -170, west: 170)])).bbox)
        #expect(box.segments.map { [$0.lo, $0.hi] } == [[170, 180], [-180, -170]])
    }

    @Test func coordinatesAreNotRangeChecked() {
        let p = locate(["locations": .array([geo(.number(95), .number(200))])]).point
        #expect(p?.lat == 95 && p?.lon == 200)
    }

    @Test func locationsMustBeAnArray() {
        #expect(locate(["locations": geo(.number(1), .number(2))]).point == nil)
        #expect(locate([:]).point == nil)
    }

    @Test func typeIsComparedByCodeUnits() {
        // U+212A KELVIN SIGN is canonically equivalent to K; nothing else may match the $type either.
        let lookalike = JSONValue.object(["$type": .string("community.lexicon.location.geo\u{301}"), "latitude": .number(1), "longitude": .number(2)])
        #expect(locate(["locations": .array([lookalike])]).point == nil)
        #expect(ordinalEqual("\u{212A}", "K") == false && "\u{212A}" == "K")
    }
}

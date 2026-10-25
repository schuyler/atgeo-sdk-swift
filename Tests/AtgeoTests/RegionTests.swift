import Foundation
import Testing
@testable import Atgeo

/// Internal entry points only; the region.test.ts port, which drives the client, comes in step 8.
@Suite struct RegionTests {
    // Contract §3, "Worked examples, computed with the reference implementation".
    @Test("contract §3 worked table", arguments: [
        (Region.circle(lat: 37.7598, lon: -122.4194, radius: 1000), ["-122.44,37.75,-122.40,37.77"]),
        (.circle(lat: 10, lon: 20, radius: 0), ["20.00,10.00,20.01,10.01"]),
        (.circle(lat: 0, lon: 179.999, radius: 5000), ["179.95,-0.05,180.00,0.05", "-180.00,-0.05,-179.95,0.05"]),
        (.circle(lat: 0, lon: -179.999, radius: 5000), ["179.95,-0.05,180.00,0.05", "-180.00,-0.05,-179.95,0.05"]),
        (.circle(lat: 89.9, lon: 0, radius: 50000), ["-180.00,89.45,180.00,90.00"]),
        (.circle(lat: 80, lon: 0, radius: 100000), ["-5.19,79.10,5.19,80.90"]),
        (.circle(lat: -0.0, lon: -0.0, radius: 0), ["0.00,0.00,0.01,0.01"]),
        (.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78), ["-122.42,37.77,-122.41,37.78"]),
        (.bbox(west: -122.4194155, south: 37.7749295, east: -122.4094155, north: 37.7849295),
         ["-122.42,37.77,-122.40,37.79"]),
        (.bbox(west: 170, south: 10, east: -170, north: 20), ["170.00,10.00,180.00,20.00", "-180.00,10.00,-170.00,20.00"]),
        (.bbox(west: 180, south: 90, east: 180, north: 90), ["179.99,89.99,180.00,90.00"]),
        (.bbox(west: 10, south: 10, east: 10.5, north: 10), ["10.00,10.00,10.50,10.01"]),
    ])
    func workedTable(region: Region, expected: [String]) {
        #expect(queryBboxes(region) == expected)
    }

    // region.test.ts, "degenerate spans".
    @Test func stepsMinDownAtTheAxisLimits() {
        #expect(queryBboxes(.bbox(west: 0, south: 90, east: 0, north: 90)) == ["0.00,89.99,0.01,90.00"])
        #expect(queryBboxes(.bbox(west: 180, south: 0, east: 180, north: 0)) == ["179.99,0.00,180.00,0.01"])
    }

    @Test func doesNotWidenASpanThatSnappingAlreadyOpened() {
        #expect(queryBboxes(.bbox(west: 10.005, south: 20.005, east: 10.005, north: 20.005)) == ["10.00,20.00,10.01,20.01"])
    }

    // region.test.ts, "does not widen grid-aligned values anywhere on the grid". The expected strings come
    // from Foundation's %.2f here, an independent formatter, so the integer formatter is checked against it.
    @Test func doesNotWidenGridAlignedValuesAnywhereOnTheGrid() {
        var boxes = 0
        for k in stride(from: 0, to: 9000, by: 97) {
            let lat = [Double(k + 1) / 100, Double(k + 6) / 100]
            let lon = [-Double(k + 8) / 100, -Double(k + 5) / 100]
            let expected = [lon[0], lat[0], lon[1], lat[1]].map { String(format: "%.2f", $0) }.joined(separator: ",")
            #expect(queryBboxes(.bbox(west: lon[0], south: lat[0], east: lon[1], north: lat[1])) == [expected])
            boxes += 1
        }
        #expect(boxes == 93)
    }

    @Test func emitsHundredthsWithinRange() {
        let regions: [Region] = [
            .circle(lat: 89.99, lon: 179.99, radius: 1e7), .circle(lat: -89.99, lon: -179.99, radius: 1e7),
            .bbox(west: -180, south: -90, east: 180, north: 90), .bbox(west: 179.995, south: -90, east: -179.995, north: -89.995),
        ]
        for region in regions {
            for bbox in queryBboxes(region) {
                let parts = bbox.split(separator: ",").map(String.init)
                #expect(parts.count == 4)
                for (i, part) in parts.enumerated() {
                    #expect(part.wholeMatch(of: /-?\d+\.\d\d/) != nil, "\(bbox)")
                    let v = Double(part)!
                    #expect(abs(v) <= (i % 2 == 0 ? 180 : 90), "\(bbox)")
                }
            }
        }
    }

    // Contract §3, "Centre".
    @Test func centre() {
        let a = center(.bbox(west: 170, south: 10, east: -170, north: 20))
        #expect(a.lat == 15 && a.lon == 180)
        let b = center(.bbox(west: 100, south: 0, east: -100, north: 0))
        #expect(b.lat == 0 && b.lon == 180)
        let c = center(.bbox(west: 160, south: 0, east: -100, north: 0))
        #expect(c.lon == -150)
        let d = center(.circle(lat: 1, lon: 2, radius: 3))
        #expect(d.lat == 1 && d.lon == 2)
    }

    @Test("rejects", arguments: [
        (Region.bbox(west: -181, south: 0, east: 0, north: 0), "invalid bbox"),
        (.bbox(west: 0, south: 0, east: 180.0001, north: 0), "invalid bbox"),
        (.bbox(west: 0, south: -91, east: 0, north: 0), "invalid bbox"),
        (.bbox(west: 0, south: 1, east: 0, north: 0), "invalid bbox"),
        (.bbox(west: .nan, south: 0, east: 0, north: 0), "invalid bbox"),
        (.bbox(west: 0, south: 0, east: 0, north: .infinity), "invalid bbox"),
        (.circle(lat: 91, lon: 0, radius: 1), "invalid circle"),
        (.circle(lat: 0, lon: -180.5, radius: 1), "invalid circle"),
        (.circle(lat: 0, lon: 0, radius: -1), "invalid circle"),
        (.circle(lat: 0, lon: 0, radius: .infinity), "invalid circle"),
        (.circle(lat: .nan, lon: 0, radius: 1), "invalid circle"),
    ])
    func rejects(region: Region, message: String) {
        #expect(throws: AtgeoArgumentError.invalidRegion(message)) { try validateRegion(region) }
    }

    @Test("accepts", arguments: [
        Region.bbox(west: 170, south: 0, east: -170, north: 1),
        .bbox(west: 1, south: 2, east: 1, north: 2),
        .bbox(west: -180, south: -90, east: 180, north: 90),
        .circle(lat: 0, lon: 0, radius: 0),
        .circle(lat: 90, lon: -180, radius: 1),
    ])
    func accepts(region: Region) throws {
        try validateRegion(region)
    }
}

// MARK: - Port of test/region.test.ts, through the client and the fake server

private func emitted(_ region: Region) async throws -> [String] {
    let server = try FakeServer()
    _ = try await server.client().searchPlaces(region: region, dataset: "overturemaps.org", collection: "place")
    return server.getTilesRequests.map { param($0, "bbox") ?? "" }
}

/// The two halves of a crossing region are fetched concurrently (contract §4.2), so the order they reach
/// the server in is not pinned. Compares sorted, which still catches a missing or repeated request.
private func emittedInAnyOrder(_ region: Region) async throws -> [String] {
    try await emitted(region).sorted()
}

private func parse(_ bbox: String) -> [Double] { bbox.split(separator: ",").map { Double($0)! } }

@Suite("coordinate serialization") struct CoordinateSerialization {
    @Test("emits only two-decimal coordinates", arguments: [
        ("full GPS precision circle", Region.circle(lat: 37.7749295, lon: -122.4194155, radius: 250.123456)),
        ("full GPS precision bbox", .bbox(west: -122.4194155, south: 37.7749295, east: -122.4094155, north: 37.7849295)),
        ("trailing zeros", .bbox(west: -122.4, south: 37.7, east: -122.3, north: 37.8)),
        ("scientific notation tiny", .bbox(west: 1e-7, south: 1e-7, east: 2e-7, north: 2e-7)),
        ("scientific notation", .bbox(west: 3.7749e1, south: 3.7749e1, east: 3.775e1, north: 3.776e1)),
        ("negative scientific notation", .bbox(west: -1e-7, south: -2e-7, east: 1e-7, north: 2e-7)),
        ("tiny radius", .circle(lat: 12.3456789, lon: 98.7654321, radius: 1e-9)),
        ("radius zero", .circle(lat: 12.3456789, lon: 98.7654321, radius: 0)),
        ("zero-area bbox", .bbox(west: 10.123456, south: 20.123456, east: 10.123456, north: 20.123456)),
        ("negative zero bbox", .bbox(west: -0.0, south: -0.0, east: 0, north: 0)),
        ("negative zero circle", .circle(lat: -0.0, lon: -0.0, radius: 0)),
        ("tiny negative", .bbox(west: -0.0001, south: -0.0001, east: -0.00001, north: -0.00001)),
        ("circle at pole", .circle(lat: 90, lon: 0, radius: 1000)),
        ("circle at antimeridian", .circle(lat: 0, lon: 180, radius: 1000)),
        ("crossing bbox", .bbox(west: 179.123456, south: 1.987654, east: -179.123456, north: 2.987654)),
    ])
    func twoDecimals(name: String, region: Region) async throws {
        let boxes = try await emitted(region)
        #expect(boxes.count > 0)
        for bbox in boxes {
            let parts = bbox.split(separator: ",").map(String.init)
            #expect(parts.count == 4, "\(name)")
            for c in parts { #expect(c.wholeMatch(of: /-?\d{1,3}\.\d{2}/) != nil, "\(name): \(c)") }
        }
    }

    @Test("never emits a coordinate outside the valid range")
    func validRange() async throws {
        let regions: [Region] = [
            .bbox(west: -180, south: -90, east: 180, north: 90),
            .bbox(west: 180, south: 90, east: 180, north: 90),
            .bbox(west: -180, south: -90, east: -180, north: -90),
            .circle(lat: 90, lon: 180, radius: 5),
            .circle(lat: -90, lon: -180, radius: 5),
            .circle(lat: 89.999, lon: 179.999, radius: 100000),
        ]
        for region in regions {
            for bbox in try await emitted(region) {
                let v = parse(bbox)
                #expect(v[0] >= -180 && v[2] <= 180 && v[1] >= -90 && v[3] <= 90, "\(bbox)")
                #expect(v[0] < v[2] && v[1] < v[3], "\(bbox)")
            }
        }
    }
}

@Suite("outward snapping") struct OutwardSnapping {
    @Test("floors mins and ceils maxes")
    func floorsAndCeils() async throws {
        #expect(try await emitted(.bbox(west: -122.4194155, south: 37.7749295, east: -122.4094155, north: 37.7849295))
                == ["-122.42,37.77,-122.40,37.79"])
    }

    @Test("contains the caller's region for arbitrary precision input")
    func containsTheRegion() async throws {
        let inputs: [[Double]] = [
            [-122.419415, 37.774929, -122.418001, 37.775001],
            [0.001, 0.002, 0.003, 0.004],
            [-0.004, -0.003, -0.002, -0.001],
            [151.2093, -33.8688, 151.2193, -33.8588],
            [-73.9857, 40.7484, -73.9757, 40.7584],
        ]
        for i in inputs {
            let boxes = try await emitted(.bbox(west: i[0], south: i[1], east: i[2], north: i[3]))
            let v = parse(try #require(boxes.first))
            #expect(v[0] <= i[0] && v[1] <= i[1] && v[2] >= i[2] && v[3] >= i[3])
            #expect(v[2] - v[0] < i[2] - i[0] + 0.0201)
            #expect(v[3] - v[1] < i[3] - i[1] + 0.0201)
        }
    }

    @Test("does not widen a grid-aligned bbox through float error")
    func gridAligned() async throws {
        #expect(try await emitted(.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)) == ["-122.42,37.77,-122.41,37.78"])
    }

    @Test("does not widen grid-aligned values anywhere on the grid")
    func gridAlignedAnywhere() async throws {
        for k in stride(from: 0, to: 9000, by: 97) {
            let lat = [Double(k + 1) / 100, Double(k + 6) / 100]
            let lon = [-Double(k + 8) / 100, -Double(k + 5) / 100]
            let expected = [lon[0], lat[0], lon[1], lat[1]].map { String(format: "%.2f", $0) }.joined(separator: ",")
            #expect(try await emitted(.bbox(west: lon[0], south: lat[0], east: lon[1], north: lat[1])) == [expected])
        }
    }
}

@Suite("degenerate spans") struct DegenerateSpans {
    @Test("widens a grid-aligned point by one step")
    func point() async throws { #expect(try await emitted(.bbox(west: 10, south: 20, east: 10, north: 20)) == ["10.00,20.00,10.01,20.01"]) }

    @Test("widens a zero radius circle on the grid")
    func zeroRadius() async throws { #expect(try await emitted(.circle(lat: 20, lon: 10, radius: 0)) == ["10.00,20.00,10.01,20.01"]) }

    @Test("widens negative zero")
    func negativeZero() async throws { #expect(try await emitted(.bbox(west: -0.0, south: -0.0, east: 0, north: 0)) == ["0.00,0.00,0.01,0.01"]) }

    @Test("widens a line")
    func line() async throws { #expect(try await emitted(.bbox(west: 10, south: 20, east: 10.5, north: 20)) == ["10.00,20.00,10.50,20.01"]) }

    @Test("steps min down at latitude 90 and longitude 180")
    func axisLimits() async throws {
        #expect(try await emitted(.bbox(west: 0, south: 90, east: 0, north: 90)) == ["0.00,89.99,0.01,90.00"])
        #expect(try await emitted(.bbox(west: 180, south: 0, east: 180, north: 0)) == ["179.99,0.00,180.00,0.01"])
    }

    @Test("does not widen a span that snapping already opened")
    func alreadyOpened() async throws {
        #expect(try await emitted(.bbox(west: 10.005, south: 20.005, east: 10.005, north: 20.005)) == ["10.00,20.00,10.01,20.01"])
    }
}

@Suite("circle to bbox") struct CircleToBbox {
    @Test("uses 111194.927 m per degree of latitude")
    func metresPerDegree() async throws { #expect(try await emitted(.circle(lat: 0, lon: 0, radius: 111194.927)) == ["-1.00,-1.00,1.00,1.00"]) }

    @Test("widens longitude to the spherical cap's half-width")
    func capHalfWidth() async throws {
        let v = parse(try #require(try await emitted(.circle(lat: 60, lon: 10, radius: 111194.927)).first))
        // vitest's toBeCloseTo(x, 1) is |diff| < 0.05.
        #expect(abs(v[1] - 59) < 0.05 && abs(v[3] - 61) < 0.05)
        #expect(v[0] <= 8 && v[0] >= 7.99)
        #expect(v[2] >= 12 && v[2] <= 12.01)
    }

    // asin(sin 20° / cos 60°) = 43.16°; the flat 20° / cos 60° is 40°.
    @Test("reaches the cap's true east and west edges at high latitude")
    func trueEdges() async throws { #expect(try await emitted(.circle(lat: 60, lon: 0, radius: 20 * 111194.927)) == ["-43.17,40.00,43.17,80.00"]) }

    @Test("covers all longitudes for a polar circle")
    func polar() async throws {
        let north = try await emitted(.circle(lat: 89.9, lon: 12.34, radius: 50000))
        #expect(north.count == 1)
        let n = parse(north[0])
        #expect([n[0], n[2], n[3]] == [-180, 180, 90])
        #expect(n[1] <= 89.46 && n[1] >= 89.44)
        let south = try await emitted(.circle(lat: -89.9, lon: -45, radius: 50000))
        #expect(south.count == 1)
        let s = parse(south[0])
        #expect([s[0], s[2], s[1]] == [-180, 180, -90])
        #expect(s[3] <= -89.44 && s[3] >= -89.46)
    }
}

@Suite("antimeridian") struct Antimeridian {
    @Test("splits a crossing bbox into two getTiles calls")
    func splitsBbox() async throws {
        #expect(try await emittedInAnyOrder(.bbox(west: 170, south: 10, east: -170, north: 20)) == ["170.00,10.00,180.00,20.00", "-180.00,10.00,-170.00,20.00"].sorted())
    }

    @Test("splits a circle that wraps past 180")
    func wrapsPast180() async throws {
        #expect(try await emittedInAnyOrder(.circle(lat: 0, lon: 179.5, radius: 111194.927)) == ["178.50,-1.00,180.00,1.00", "-180.00,-1.00,-179.50,1.00"].sorted())
    }

    @Test("splits a circle that wraps past -180")
    func wrapsPastMinus180() async throws {
        #expect(try await emittedInAnyOrder(.circle(lat: 0, lon: -179.5, radius: 111194.927)) == ["179.50,-1.00,180.00,1.00", "-180.00,-1.00,-178.50,1.00"].sorted())
    }

    @Test("issues a single call for a non-crossing bbox")
    func singleCall() async throws { #expect(try await emitted(.bbox(west: -10, south: 10, east: 10, north: 20)).count == 1) }

    @Test("snaps each half independently")
    func snapsEachHalf() async throws {
        #expect(try await emittedInAnyOrder(.bbox(west: 170.123, south: 10.123, east: -170.123, north: 20.123)) == ["170.12,10.12,180.00,20.13", "-180.00,10.12,-170.12,20.13"].sorted())
    }

    @Test("merges results from both halves")
    func mergesHalves() async throws {
        let west = tileURL("west"), east = tileURL("east")
        let server = try FakeServer(
            tilesets: [overture([
                FakeTile(url: west, records: [record(place("w", "West", [point(15, 175)]))]),
                FakeTile(url: east, records: [record(place("e", "East", [point(15, -175)]))]),
            ])],
            tilesFor: { bbox in .tiles(bbox.hasPrefix("170") ? [west] : [east]) })
        let result = try await server.client().searchPlaces(region: .bbox(west: 170, south: 10, east: -170, north: 20), dataset: "overturemaps.org", collection: "place")
        #expect(result.places.compactMap(\.origin).sorted() == [placeOrigin("e"), placeOrigin("w")])
        #expect(result.complete)
    }
}

@Suite("invalid regions") struct InvalidRegions {
    @Test("throws before any request", arguments: [
        ("NaN lat", Region.circle(lat: .nan, lon: 0, radius: 10)),
        ("NaN lon", .circle(lat: 0, lon: .nan, radius: 10)),
        ("Infinity lon", .circle(lat: 0, lon: .infinity, radius: 10)),
        ("NaN radius", .circle(lat: 0, lon: 0, radius: .nan)),
        ("Infinity radius", .circle(lat: 0, lon: 0, radius: .infinity)),
        ("negative radius", .circle(lat: 0, lon: 0, radius: -1)),
        ("lat above 90", .circle(lat: 90.01, lon: 0, radius: 10)),
        ("lat below -90", .circle(lat: -91, lon: 0, radius: 10)),
        ("lon above 180", .circle(lat: 0, lon: 180.5, radius: 10)),
        ("lon below -180", .circle(lat: 0, lon: -181, radius: 10)),
        ("bbox NaN", .bbox(west: 0, south: 0, east: .nan, north: 1)),
        ("bbox Infinity", .bbox(west: 0, south: 0, east: 1, north: .infinity)),
        ("bbox -Infinity", .bbox(west: -.infinity, south: 0, east: 1, north: 1)),
        ("bbox minLat > maxLat", .bbox(west: 0, south: 10, east: 1, north: 5)),
        ("bbox lat above 90", .bbox(west: 0, south: 0, east: 1, north: 91)),
        ("bbox lat below -90", .bbox(west: 0, south: -91, east: 1, north: 0)),
        ("bbox lon above 180", .bbox(west: 0, south: 0, east: 181, north: 1)),
        ("bbox lon below -180", .bbox(west: -181, south: 0, east: 1, north: 1)),
    ])
    func rejects(name: String, region: Region) async throws {
        let server = try FakeServer()
        let expected: AtgeoArgumentError
        if case .bbox = region { expected = .invalidRegion("invalid bbox") } else { expected = .invalidRegion("invalid circle") }
        await #expect(throws: expected) { _ = try await server.client().searchPlaces(region: region, dataset: "overturemaps.org", collection: "place") }
        #expect(server.requests.isEmpty)
    }

    @Test("accepts west > east")
    func acceptsCrossing() async throws {
        _ = try await FakeServer().client().searchPlaces(region: .bbox(west: 170, south: 0, east: -170, north: 1), dataset: "overturemaps.org", collection: "place")
    }

    @Test("throws for similarity sort without text, before any request")
    func similarityWithoutText() async throws {
        let server = try FakeServer()
        for text in [nil, "", "   ", "\u{301}"] as [String?] {
            await #expect(throws: AtgeoArgumentError.similarityRequiresText) {
                _ = try await server.client().searchPlaces(region: .bbox(west: 0, south: 0, east: 1, north: 1), dataset: "overturemaps.org", text: text, collection: "place", sort: .similarity)
            }
        }
        #expect(server.requests.isEmpty)
    }
}

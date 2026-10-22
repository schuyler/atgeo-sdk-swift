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
        (.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78), ["-122.42,37.77,-122.41,37.78"]),
        (.bbox(minLon: -122.4194155, minLat: 37.7749295, maxLon: -122.4094155, maxLat: 37.7849295),
         ["-122.42,37.77,-122.40,37.79"]),
        (.bbox(minLon: 170, minLat: 10, maxLon: -170, maxLat: 20), ["170.00,10.00,180.00,20.00", "-180.00,10.00,-170.00,20.00"]),
        (.bbox(minLon: 180, minLat: 90, maxLon: 180, maxLat: 90), ["179.99,89.99,180.00,90.00"]),
        (.bbox(minLon: 10, minLat: 10, maxLon: 10.5, maxLat: 10), ["10.00,10.00,10.50,10.01"]),
    ])
    func workedTable(region: Region, expected: [String]) {
        #expect(queryBboxes(region) == expected)
    }

    // region.test.ts, "degenerate spans".
    @Test func stepsMinDownAtTheAxisLimits() {
        #expect(queryBboxes(.bbox(minLon: 0, minLat: 90, maxLon: 0, maxLat: 90)) == ["0.00,89.99,0.01,90.00"])
        #expect(queryBboxes(.bbox(minLon: 180, minLat: 0, maxLon: 180, maxLat: 0)) == ["179.99,0.00,180.00,0.01"])
    }

    @Test func doesNotWidenASpanThatSnappingAlreadyOpened() {
        #expect(queryBboxes(.bbox(minLon: 10.005, minLat: 20.005, maxLon: 10.005, maxLat: 20.005)) == ["10.00,20.00,10.01,20.01"])
    }

    // region.test.ts, "does not widen grid-aligned values anywhere on the grid". The expected strings come
    // from Foundation's %.2f here, an independent formatter, so the integer formatter is checked against it.
    @Test func doesNotWidenGridAlignedValuesAnywhereOnTheGrid() {
        var boxes = 0
        for k in stride(from: 0, to: 9000, by: 97) {
            let lat = [Double(k + 1) / 100, Double(k + 6) / 100]
            let lon = [-Double(k + 8) / 100, -Double(k + 5) / 100]
            let expected = [lon[0], lat[0], lon[1], lat[1]].map { String(format: "%.2f", $0) }.joined(separator: ",")
            #expect(queryBboxes(.bbox(minLon: lon[0], minLat: lat[0], maxLon: lon[1], maxLat: lat[1])) == [expected])
            boxes += 1
        }
        #expect(boxes == 93)
    }

    @Test func emitsHundredthsWithinRange() {
        let regions: [Region] = [
            .circle(lat: 89.99, lon: 179.99, radius: 1e7), .circle(lat: -89.99, lon: -179.99, radius: 1e7),
            .bbox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90), .bbox(minLon: 179.995, minLat: -90, maxLon: -179.995, maxLat: -89.995),
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
        let a = center(.bbox(minLon: 170, minLat: 10, maxLon: -170, maxLat: 20))
        #expect(a.lat == 15 && a.lon == 180)
        let b = center(.bbox(minLon: 100, minLat: 0, maxLon: -100, maxLat: 0))
        #expect(b.lat == 0 && b.lon == 180)
        let c = center(.bbox(minLon: 160, minLat: 0, maxLon: -100, maxLat: 0))
        #expect(c.lon == -150)
        let d = center(.circle(lat: 1, lon: 2, radius: 3))
        #expect(d.lat == 1 && d.lon == 2)
    }

    @Test("rejects", arguments: [
        (Region.bbox(minLon: -181, minLat: 0, maxLon: 0, maxLat: 0), "invalid bbox"),
        (.bbox(minLon: 0, minLat: 0, maxLon: 180.0001, maxLat: 0), "invalid bbox"),
        (.bbox(minLon: 0, minLat: -91, maxLon: 0, maxLat: 0), "invalid bbox"),
        (.bbox(minLon: 0, minLat: 1, maxLon: 0, maxLat: 0), "invalid bbox"),
        (.bbox(minLon: .nan, minLat: 0, maxLon: 0, maxLat: 0), "invalid bbox"),
        (.bbox(minLon: 0, minLat: 0, maxLon: 0, maxLat: .infinity), "invalid bbox"),
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
        Region.bbox(minLon: 170, minLat: 0, maxLon: -170, maxLat: 1),
        .bbox(minLon: 1, minLat: 2, maxLon: 1, maxLat: 2),
        .bbox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90),
        .circle(lat: 0, lon: 0, radius: 0),
        .circle(lat: 90, lon: -180, radius: 1),
    ])
    func accepts(region: Region) throws {
        try validateRegion(region)
    }
}

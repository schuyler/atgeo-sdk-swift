import Foundation
import Testing
@testable import Atgeo

// Port of test/accessors.test.ts: `name` and `location` on SearchHit and PlaceRecord (contract §5, §8, §9).

private let tile = tileURL("a")
private let region = Region.bbox(west: -179, south: -80, east: 179, north: 80)

/// Serves one placeholder place and swaps `value` into every answer, because the fake validates against the
/// lexicon and a value the lexicon rejects (no name, a numeric coordinate) could not be served otherwise.
private struct Swapping: HTTPTransport {
    let base: FakeServer
    let value: JSONObject
    func get(_ url: URL) async throws -> HTTPResponse {
        let response = try await base.get(url)
        guard case .object(var body)? = try? decodeJSON(response.body) else { return response }
        if case .array(var records)? = body["records"], case .object(var first)? = records.first {
            first["value"] = .object(value)
            records[0] = .object(first)
            body["records"] = .array(records)
        } else if body["value"] != nil {
            body["value"] = .object(value)
        }
        return HTTPResponse(status: response.status, body: try JSONEncoder().encode(JSONValue.object(body)))
    }
}

private func make(_ value: JSONObject) throws -> (any HTTPTransport, FakeServer) {
    let fake = try FakeServer(tilesets: [overture([FakeTile(url: tile, records: [record(place("x", "Placeholder", [point(1, 1)]), importance: 1)])])])
    return (Swapping(base: fake, value: value), fake)
}

private struct Seen: Equatable {
    var name: String?
    var location: PlaceLocation
}

/// The hit from a search, the record from getPlace on a warm cache, and the record from getPlace on a cold one.
private func seen(_ value: JSONObject) async throws -> [Seen] {
    let (transport, fake) = try make(value)
    let warm = AtgeoClient(server: URL(string: fake.server)!, transport: transport)
    let hit = try #require(try await warm.searchPlaces(region: region, dataset: "overturemaps.org").places.first)
    let before = fake.requests.count
    let cached = try await warm.getPlace(origin: placeOrigin("x"))
    // The warm getPlace is answered from the cache: no request of any kind.
    #expect(fake.requests.count == before)
    let (coldTransport, coldFake) = try make(value)
    let network = try await AtgeoClient(server: URL(string: coldFake.server)!, transport: coldTransport).getPlace(origin: placeOrigin("x"))
    return [Seen(name: hit.name, location: hit.location), Seen(name: cached.name, location: cached.location),
            Seen(name: network.name, location: network.location)]
}

private func allThree(_ value: JSONObject, _ check: (Seen) -> Void) async throws {
    let results = try await seen(value)
    #expect(results.count == 3)
    results.forEach(check)
}

private func geo(_ latitude: JSONValue, _ longitude: JSONValue) -> JSONValue {
    .object(["$type": .string("community.lexicon.location.geo"), "latitude": latitude, "longitude": longitude])
}

private func box(_ south: JSONValue, _ north: JSONValue, _ west: JSONValue, _ east: JSONValue) -> JSONValue {
    .object(["$type": .string("community.lexicon.location.bbox"), "south": south, "north": north, "west": west, "east": east])
}

private func pt(_ lat: Double, _ lon: Double) -> PlaceLocation.Point { .init(lat: lat, lon: lon) }
private func bx(_ south: Double, _ west: Double, _ north: Double, _ east: Double) -> PlaceLocation.Box {
    .init(south: south, west: west, north: north, east: east)
}

@Suite("name") struct NameAccessor {
    @Test func isThePlacesName() async throws {
        try await allThree(place("x", "Zanzibar", [point(10, 20)])) { #expect($0.name == "Zanzibar") }
    }

    @Test func isNilWhenAbsent() async throws {
        var value = place("x", "ignored", [point(10, 20)])
        value["name"] = nil
        try await allThree(value) { #expect($0.name == nil) }
    }

    @Test func isNilWhenNotAString() async throws {
        try await allThree(place("x", "ignored", [point(10, 20)], ["name": .number(42)])) { #expect($0.name == nil) }
    }

    @Test func emptyStringIsKept() async throws {
        try await allThree(place("x", "", [point(10, 20)])) { #expect($0.name == "") }
    }
}

@Suite("location") struct LocationAccessor {
    @Test func holdsThePointAndTheBox() async throws {
        try await allThree(place("x", "P", [point(10.5, 20.25), bboxLocation(north: 12, south: 8, east: 22, west: 18)])) {
            #expect($0.location == PlaceLocation(point: pt(10.5, 20.25), bbox: bx(8, 18, 12, 22)))
        }
    }

    @Test func isNilForWhatThePlaceLacks() async throws {
        try await allThree(place("x", "P", [point(10, 20)])) { #expect($0.location == PlaceLocation(point: pt(10, 20), bbox: nil)) }
        try await allThree(place("x", "P", [bboxLocation(north: 12, south: 8, east: 22, west: 18)])) {
            #expect($0.location == PlaceLocation(point: nil, bbox: bx(8, 18, 12, 22)))
        }
    }

    @Test func takesTheFirstUsableGeoAndTheFirstUsableBboxSkippingUnusableOnes() async throws {
        let value = place("x", "P", [
            geo(.string("abc"), .string("1")),
            geo(.array([.number(0.5)]), .number(2)),
            box(.string("1"), .string("2"), .string("3"), .null),
            .null,
            geo(.number(10), .string("20.5")),
            box(.number(-5), .number(5), .number(170), .number(-170)),
            geo(.string("30"), .string("40")),
            box(.string("1"), .string("2"), .string("3"), .string("4")),
        ])
        try await allThree(value) {
            #expect($0.location == PlaceLocation(point: pt(10, 20.5), bbox: bx(-5, 170, 5, -170)))
        }
    }

    @Test func keepsAnAntimeridianBoxAsGivenWestGreaterThanEast() async throws {
        try await allThree(place("x", "P", [bboxLocation(north: 10, south: -10, east: 170, west: -170)])) {
            #expect($0.location == PlaceLocation(point: nil, bbox: bx(-10, -170, 10, 170)))
        }
        try await allThree(place("x", "P", [bboxLocation(north: 10, south: -10, east: -170, west: 170)])) {
            #expect($0.location == PlaceLocation(point: nil, bbox: bx(-10, 170, 10, -170)))
        }
    }

    @Test func aPlaceWithNoUsableLocationHasAnEmptyOne() {
        let hit = SearchHit(origin: nil, place: ["locations": .array([geo(.string("x"), .string("y"))])], importance: nil, distance: 0, score: nil)
        #expect(hit.location == PlaceLocation(point: nil, bbox: nil))
    }
}

@Suite("accessors on built values") struct AccessorsOnBuiltValues {
    // Computed properties: memberwise inits and Codable are unchanged, and the accessors follow `place`.
    @Test func followPlaceAndLeaveCodableAlone() throws {
        let value = place("x", "Zanzibar", [point(10, 20), bboxLocation(north: 12, south: 8, east: 22, west: 18)])
        let hit = SearchHit(origin: "o", place: value, importance: nil, distance: 1, score: nil)
        let record = PlaceRecord(origin: "o", place: value, importance: nil)
        for (name, location) in [(hit.name, hit.location), (record.name, record.location)] {
            #expect(name == "Zanzibar")
            #expect(location == PlaceLocation(point: pt(10, 20), bbox: bx(8, 18, 12, 22)))
        }
        let json = try #require(String(data: JSONEncoder().encode(hit), encoding: .utf8))
        #expect(!json.contains("\"location\"") && !json.contains("\"bbox\""))
        #expect(try JSONDecoder().decode(SearchHit.self, from: JSONEncoder().encode(hit)) == hit)
        #expect(try JSONDecoder().decode(PlaceRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test func placeLocationRoundTripsThroughJSON() throws {
        let location = PlaceLocation(point: pt(1, 2), bbox: bx(-1, 170, 1, -170))
        #expect(try JSONDecoder().decode(PlaceLocation.self, from: JSONEncoder().encode(location)) == location)
    }
}

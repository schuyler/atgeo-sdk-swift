import Foundation
import Testing
@testable import Atgeo

// Port of test/frozenPlace.test.ts. The reference freezes the `place` it hands out, because that object is the one its
// tile cache holds, and copies each attribution entry per answer (contract §8, §9: "a port either hands out
// immutable values or copies them"). Swift needs neither step: `SearchHit`, `PlaceRecord`, `Attribution` and
// `JSONValue` are structs and enums, so every answer is the app's own copy, the cache keeps its own, and an app that
// changes what it was given (it must declare the variable `var` to do so) changes nothing the client holds. Arrays
// and dictionaries copy on write, so the copy is lazy, and it goes all the way down: unlike the reference's shallow
// freeze, a nested object or array is the app's too. These tests pin that.

private let tile = tileURL("a")
private let region = Region.bbox(west: -122.42, south: 37.77, east: -122.41, north: 37.78)
private let origin = placeOrigin("cafe")

private func makeValue() -> JSONObject {
    place("cafe", "Zanzibar Cafe", [point(37.775, -122.415)], [
        "variants": .array([.object(["name": .string("Zanzibar")])]),
        "attributes": .object(["kind": .string("cafe"), "tags": .array([.string("coffee")])]),
    ])
}

private func setup(licenses: [String]? = nil) throws -> (FakeServer, AtgeoClient) {
    var tileset = overture([FakeTile(url: tile, records: [record(makeValue(), importance: 5)])])
    if let licenses {
        tileset.collections = [[
            "dataset": .string("overturemaps.org"), "collection": .string("place"), "release": .string("2026-01-01"),
            "licenses": .array(licenses.map(JSONValue.string)),
        ]]
    }
    let fake = try FakeServer(tilesets: [tileset])
    return (fake, fake.client())
}

private func firstHit(_ client: AtgeoClient) async throws -> SearchHit {
    try #require(try await client.searchPlaces(region: region, dataset: "overturemaps.org", collection: "place").places.first)
}

@Suite("a search hit's place is the app's own value") struct HitPlace {
    @Test("changing a copy leaves a later search over the same cached tile, and getPlace(origin:) from the cache, unchanged")
    func copyIsIndependent() async throws {
        let (fake, client) = try setup()
        var hit = try await firstHit(client)
        hit.place["name"] = .string("Changed")
        hit.place["attributes"] = nil
        hit.place["extra"] = .number(1)
        let again = try await firstHit(client)
        #expect(again.place == makeValue())
        #expect(try await client.getPlace(origin: origin).place == makeValue())
        #expect(fake.requests.filter { $0.absoluteString == tile }.count == 1)
    }

    @Test("changing a nested object or array of the copy changes nothing either, unlike the reference's shallow freeze")
    func nestedValuesAreCopiedToo() async throws {
        let (_, client) = try setup()
        var hit = try await firstHit(client)
        guard case .object(var attributes)? = hit.place["attributes"], case .array(var variants)? = hit.place["variants"] else {
            Issue.record("expected an attributes object and a variants array")
            return
        }
        attributes["kind"] = .string("changed")
        variants.append(.object(["name": .string("Added")]))
        hit.place["attributes"] = .object(attributes)
        hit.place["variants"] = .array(variants)
        let again = try await firstHit(client)
        #expect(again.place == makeValue())
        #expect(again.place["variants"]?.arrayValue?.count == 1)
    }

    @Test("a hit from getPlace(origin:) over the network is a copy too")
    func networkPlace() async throws {
        let (fake, client) = try setup()
        var fetched = try await client.getPlace(origin: origin)
        #expect(fake.requests.contains { $0.path == "/xrpc/org.atgeo.getPlace" })
        fetched.place["name"] = .string("Changed")
        #expect(fetched.place != makeValue())
        #expect(try await client.getPlace(origin: origin).place == makeValue())
    }
}

@Suite("a search result's attribution is the app's own value") struct ResultAttribution {
    @Test("changing it leaves the next search's alone, and the cache's")
    func nextSearchUnchanged() async throws {
        let licenses = ["https://l.example/1"]
        let (fake, client) = try setup(licenses: licenses)
        var r1 = try await client.searchPlaces(region: region, dataset: "overturemaps.org", collection: "place")
        let original = r1.attribution
        #expect(original.first?.licenses == licenses)
        try #require(!r1.attribution.isEmpty)
        r1.attribution[0].licenses?.append("https://l.example/changed")
        r1.attribution[0].release = "changed"
        r1.attribution.reverse()
        let r2 = try await client.searchPlaces(region: region, dataset: "overturemaps.org", collection: "place")
        #expect(r2.attribution == original)
        #expect(r2.attribution.first?.licenses == licenses)
        // Nothing was refetched to get there: the second search read the cache the first search's app could not reach.
        #expect(fake.requests.filter { $0.absoluteString == tile }.count == 1)
        #expect(try await client.getPlace(origin: origin).attribution == original)
    }

    @Test("a hit's collection is a copy: changing it changes the next search's hit by nothing")
    func hitCollection() async throws {
        let (_, client) = try setup()
        var hit = try await firstHit(client)
        #expect(hit.collection == CollectionKey(dataset: "overturemaps.org", collection: "place"))
        hit.collection?.collection = "changed"
        #expect(try await firstHit(client).collection == CollectionKey(dataset: "overturemaps.org", collection: "place"))
    }
}

import Foundation
@testable import Atgeo

// The record builders the reference keeps in test/helpers/fakeServer.ts.

func placeOrigin(_ id: String) -> String { "urn:atgeo:overturemaps.org:place:\(id)" }

/// JavaScript's toFixed(6), which prints negative zero as 0.000000 where %.6f prints -0.000000.
private func toFixed6(_ x: Double) -> String { String(format: "%.6f", x == 0 ? 0 : x) }

func point(_ lat: Double, _ lon: Double) -> JSONValue {
    .object([
        "$type": .string("community.lexicon.location.geo"),
        "latitude": .string(toFixed6(lat)),
        "longitude": .string(toFixed6(lon)),
    ])
}

func bboxLocation(north: Double, south: Double, east: Double, west: Double) -> JSONValue {
    .object([
        "$type": .string("community.lexicon.location.bbox"),
        "north": .string(toFixed6(north)),
        "south": .string(toFixed6(south)),
        "east": .string(toFixed6(east)),
        "west": .string(toFixed6(west)),
    ])
}

func place(_ id: String, _ name: String, _ locations: [JSONValue], _ extra: JSONObject = [:]) -> JSONObject {
    let base: JSONObject = [
        "$type": .string("org.atgeo.place"),
        "origin": .string(placeOrigin(id)),
        "name": .string(name),
        "locations": .array(locations),
    ]
    return base.merging(extra) { _, new in new }
}

func record(_ value: JSONObject, importance: Int64? = nil, uri: String? = nil) -> TileRecord {
    TileRecord(value: value, uri: uri, importance: importance)
}

/// What the fake's `overture(...)` tileset credits: its one collection (and no references).
let overturePlaceAttribution = Attribution(dataset: "overturemaps.org", collection: "place")

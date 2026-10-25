import Foundation
import Testing
@testable import Atgeo

// The five lenient readers of contract §1 against fixtures/lenient-readers.json (port of test/wire.test.ts). A case is
// a response body and either what the reader keeps of it, in JSON terms, or `decodingError`. A field the reader
// leaves absent is a missing key, so the comparison is exact. The tilePayload result is `{records, attribution?}`.

struct LenientCase: Sendable, CustomTestStringConvertible {
    var reader: String
    var name: String
    var body: JSONValue
    var result: JSONValue?
    var decodingError: Bool
    var testDescription: String { "\(reader): \(name)" }
}

private let readers = ["getTiles", "tilePayload", "getPlace", "describeService", "describeTileset"]

private func cases() throws -> [LenientCase] {
    try #require(try fixture("lenient-readers.json").arrayValue).map { c in
        LenientCase(
            reader: try #require(c["reader"]?.stringValue), name: try #require(c["name"]?.stringValue),
            body: try #require(c["body"]), result: c["result"], decodingError: c["decodingError"]?.boolValue ?? false)
    }
}

/// What a Swift value looks like once encoded, which leaves out a nil optional, as the fixture leaves out an absent field.
private func terms<T: Encodable>(_ value: T) throws -> JSONValue {
    try decodeJSON(JSONEncoder().encode(value))
}

/// Runs the named reader and puts what it kept into the fixture's terms. This is the one mapping a port's runner has
/// to write per reader (contract §13).
private func read(_ reader: String, _ body: JSONValue) throws -> JSONValue {
    switch reader {
    case "getTiles":
        let list = try tileList(body)
        return .object(["tiles": .array(list.tiles.map(JSONValue.string)), "overview": .bool(list.overview)])
    case "tilePayload":
        let payload = try tilePayload(body)
        var out: JSONObject = ["records": .array(payload.records.map { r in
            var o: JSONObject = ["value": .object(r.value)]
            if let uri = r.uri { o["uri"] = .string(uri) }
            if let importance = r.importance { o["importance"] = .number(Double(importance)) }
            return .object(o)
        })]
        if let attribution = payload.attribution { out["attribution"] = try terms(attribution) }
        return .object(out)
    case "getPlace":
        let place = try placeRecord(body, origin: "ignored")
        var out: JSONObject = ["value": .object(place.place), "attribution": try terms(place.attribution)]
        if let importance = place.importance { out["importance"] = .number(Double(importance)) }
        return .object(out)
    case "describeService":
        return try terms(serviceDescription(body))
    case "describeTileset":
        return try terms(tileset(body))
    default:
        Issue.record("unknown reader \(reader)")
        return .null
    }
}

@Suite("lenient readers") struct LenientReaders {
    @Test func hasACaseForEveryReader() throws {
        #expect(Set(try cases().map(\.reader)) == Set(readers))
        #expect(try cases().count == 104)
    }

    @Test("reads the body as the fixture says", arguments: try cases())
    func reads(_ c: LenientCase) throws {
        if c.decodingError {
            #expect(throws: DecodingError.self) { _ = try read(c.reader, c.body) }
        } else {
            #expect(try read(c.reader, c.body) == c.result)
        }
    }
}

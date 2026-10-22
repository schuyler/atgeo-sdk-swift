import Foundation
import Testing
@testable import Atgeo

/// Reads a vendored file from `Fixtures/` (see `Fixtures/SOURCE`). Shared by the fixture-driven suites.
func fixtureData(_ path: String) throws -> Data {
    let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: dir.appendingPathComponent(path))
}

func fixture(_ path: String) throws -> JSONValue {
    try decodeJSON(fixtureData(path))
}

private func decode(_ text: String) throws -> JSONValue {
    try decodeJSON(Data(text.utf8))
}

@Suite struct JSONValueTests {
    @Test("Bool before Double before String", arguments: [
        ("true", JSONValue.bool(true)),
        ("false", .bool(false)),
        ("1", .number(1)),
        ("0", .number(0)),
        ("1.5", .number(1.5)),
        ("1e300", .number(1e300)),
        (#""1""#, .string("1")),
        (#""true""#, .string("true")),
        ("null", .null),
    ])
    func scalar(text: String, expected: JSONValue) throws {
        #expect(try decode(text) == expected)
    }

    @Test func negativeZeroKeepsItsSign() throws {
        let d = try #require(try decode("-0.0").doubleValue)
        #expect(d == 0 && d.sign == .minus)
    }

    @Test func nesting() throws {
        let v = try decode(#"{"a":[1,true,"x",null,{"b":[]}],"c":{}}"#)
        #expect(v == .object([
            "a": .array([.number(1), .bool(true), .string("x"), .null, .object(["b": .array([])])]),
            "c": .object([:]),
        ]))
    }

    @Test func accessors() throws {
        let v = try decode(#"{"s":"x","n":2,"b":false,"a":[7],"o":{"k":null}}"#)
        #expect(v["s"]?.stringValue == "x")
        #expect(v["n"]?.doubleValue == 2)
        #expect(v["b"]?.boolValue == false)
        #expect(v["a"]?[0] == .number(7))
        #expect(v["a"]?[1] == nil)
        #expect(v["a"]?[-1] == nil)
        #expect(v["o"]?.objectValue == ["k": .null])
        #expect(v["o"]?["k"] == .null)
        #expect(v["missing"] == nil)
        #expect(v["n"]?.stringValue == nil)
        #expect(v["s"]?.doubleValue == nil)
        #expect(v["a"]?["k"] == nil)
        #expect(v[0] == nil)
    }

    @Test func encodesNullAsJSONNull() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["k": .null]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"k":null}"#)
    }

    @Test func roundTrips() throws {
        let v = try decode(#"{"a":[1.5,true,"x",null],"b":{"c":-2}}"#)
        #expect(try decodeJSON(JSONEncoder().encode(v)) == v)
    }

    @Test func rejectsNonJSON() {
        #expect(throws: DecodingError.self) { try decode("not json") }
        #expect(throws: DecodingError.self) { try decode("") }
    }

    @Test func noUsableBodyIsADecodingError() {
        let error: any Error = noUsableBody("no tiles array")
        guard case DecodingError.dataCorrupted(let context) = error else {
            Issue.record("expected dataCorrupted, got \(error)")
            return
        }
        #expect(context.debugDescription == "no tiles array")
    }

    @Test("vendored files decode", arguments: [
        "normalize.json", "jaro-winkler.json", "ranking-scenarios.json",
        "lexicon/address.json", "lexicon/bbox.json", "lexicon/defs.json", "lexicon/describeService.json",
        "lexicon/describeTileset.json", "lexicon/geo.json", "lexicon/getPlace.json", "lexicon/getTiles.json",
        "lexicon/place.json", "lexicon/tilePayload.json",
    ])
    func vendoredFileDecodes(path: String) throws {
        let v = try fixture(path)
        #expect(v.arrayValue != nil || v.objectValue != nil)
    }

    @Test func sourceNamesBothCommits() throws {
        let source = String(decoding: try fixtureData("SOURCE"), as: UTF8.self)
        #expect(source.contains("atgeo-sdk-js 0ff4aab9e3e2c43a55adf9eb8dcd7565c02931ec"))
        #expect(source.contains("garganorn 85bd4b3"))
    }
}

import Foundation
import Testing
@_spi(Benchmark) @testable import Atgeo

// The byte-level parser on its own (design review note 12). ToleranceTests holds the margins CONFORMANCE.md
// records; this file holds the grammar.

private func parse(_ text: String) throws -> JSONValue { try parseJSON(Data(text.utf8)) }

private func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }

@Suite struct JSONParserTests {
    @Test("accepts", arguments: [
        ("[]", JSONValue.array([])),
        ("{}", .object([:])),
        (" \t\r\n[ 1 , 2 ]\n", .array([.number(1), .number(2)])),
        (#"{"a":"b","c":{"d":[true,false,null]}}"#, .object(["a": .string("b"), "c": .object(["d": .array([.bool(true), .bool(false), .null])])])),
        ("0", .number(0)),
        ("-1", .number(-1)),
        ("1E2", .number(100)),
        ("1e+2", .number(100)),
        ("-1.5e-3", .number(-0.0015)),
        ("0.1", .number(0.1)),
        ("123456789012345", .number(123_456_789_012_345)),
        ("-123456789012345", .number(-123_456_789_012_345)),
        ("1234567890123456", .number(1_234_567_890_123_456)),
        ("9007199254740993", .number(9_007_199_254_740_992)),
        ("12345678901234567890123", .number(12345678901234567890123)),
        (#""""#, .string("")),
        (#""é""#, .string("é")),
        (#""é""#, .string("é")),
        (#""é""#, .string("é")),
        (#""😀""#, .string("😀")),
        (#""\"\\\/\b\f\n\r\t""#, .string("\"\\/\u{8}\u{C}\n\r\t")),
        (#""\u0000""#, .string("\u{0}")),
        (#""aAb""#, .string("aAb")),
        (#""tab\there""#, .string("tab\there")),
    ])
    func accepts(text: String, expected: JSONValue) throws {
        #expect(try parse(text) == expected)
    }

    @Test("rejects", arguments: [
        "", " ", "[", "]", "{", "}", "[1,]", "[,1]", "[1 2]", #"{"a":1,}"#, #"{"a" 1}"#, #"{"a":}"#, "{1:2}", "{'a':1}",
        "01", "-01", "-", "1.", ".5", "1e", "1e+", "+1", "0x10", "1.5f", "NaN", "Infinity", "-Infinity",
        "tru", "nul", "truex", "True", "[1] x", "[1][2]", "1 2",
        #""abc"#, #""\x""#, #""\u12""#, #""\u12G4""#, #""\"#, #""\u"#, "\"a\tb\"", "\"a\nb\"",
        "/* c */ 1", "// c\n1", "\u{00A0}1", "\u{FEFF}", "[\"a\",]",
    ])
    func rejects(text: String) {
        #expect(throws: DecodingError.self) { try parse(text) }
    }

    @Test func negativeZeroKeepsItsSign() throws {
        for text in ["-0", "-0.0", "-0e5"] {
            let d = try #require(try parse(text).doubleValue)
            #expect(d == 0 && d.sign == .minus, "\(text)")
        }
    }

    @Test func numbersOutOfRangeAreInfinityAndZero() throws {
        #expect(try parse("1e400") == .number(.infinity))
        #expect(try parse("-1e400") == .number(-.infinity))
        #expect(try parse("1e-400") == .number(0))
    }

    @Test func theLastDuplicateKeyWins() throws {
        #expect(try parse(#"{"a":1,"b":2,"a":3}"#) == .object(["a": .number(3), "b": .number(2)]))
    }

    @Test func loneSurrogatesBecomeTheReplacementCharacter() throws {
        #expect(try parse(#""\uD800""#) == .string("\u{FFFD}"))
        #expect(try parse(#""\uDC00x""#) == .string("\u{FFFD}x"))
        #expect(try parse(#""\uD800x""#) == .string("\u{FFFD}x"))
        #expect(try parse(#""\uD800A""#) == .string("\u{FFFD}A"))
        #expect(try parse(#""\uD800𐀀""#) == .string("\u{FFFD}\u{10000}"))
        #expect(throws: DecodingError.self) { try parse(#""\uD800\u00G0""#) }
    }

    @Test func invalidUTF8BecomesTheReplacementCharacter() throws {
        let body = Data([0x5B, 0x22, 0x61, 0xFF, 0x62, 0x22, 0x5D])  // ["a\xFFb"]
        #expect(try parseJSON(body) == .array([.string("a\u{FFFD}b")]))
        let escaped = Data([0x22, 0x5C, 0x6E, 0xC3, 0x22])  // "\n\xC3"
        #expect(try parseJSON(escaped) == .string("\n\u{FFFD}"))
    }

    @Test func aLeadingByteOrderMarkIsSkipped() throws {
        #expect(try parseJSON(Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8)) == .object([:]))
        #expect(throws: DecodingError.self) { try parseJSON(Data("[]".utf8) + Data([0xEF, 0xBB, 0xBF])) }
    }

    @Test func nestingIsLimitedTo512() throws {
        #expect(throws: Never.self) { try parse(nested(512)) }
        #expect(throws: DecodingError.self) { try parse(nested(513)) }
        #expect(throws: DecodingError.self) { try parse(String(repeating: #"{"a":"#, count: 513) + "1" + String(repeating: "}", count: 513)) }
        #expect(throws: DecodingError.self) { try parse(nested(100_000)) }
    }

    @Test func errorsNameTheByte() {
        do {
            _ = try parse("[1,]")
            Issue.record("expected an error")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription.hasSuffix("at byte 3"), "\(context.debugDescription)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // JSONDecoder agrees on every valid body it can read, which is all of these.
    @Test("agrees with JSONDecoder on the vendored files", arguments: [
        "normalize.json", "jaro-winkler.json", "ranking-scenarios.json",
        "lexicon/address.json", "lexicon/bbox.json", "lexicon/defs.json", "lexicon/describeService.json",
        "lexicon/describeTileset.json", "lexicon/geo.json", "lexicon/getPlace.json", "lexicon/getTiles.json",
        "lexicon/place.json", "lexicon/tilePayload.json",
    ])
    func agreesWithJSONDecoder(path: String) throws {
        let data = try fixtureData(path)
        #expect(try parseJSON(data) == JSONDecoder().decode(JSONValue.self, from: data))
    }
}

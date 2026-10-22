import Foundation
import Testing
@testable import Atgeo

struct JaroWinklerCase: Sendable, CustomTestStringConvertible {
    var a: String
    var b: String
    var score: Double
    var testDescription: String { "\(a) / \(b)" }
}

private func jaroWinklerCases() throws -> [JaroWinklerCase] {
    try #require(try fixture("jaro-winkler.json").arrayValue).map {
        JaroWinklerCase(
            a: try #require($0["a"]?.stringValue),
            b: try #require($0["b"]?.stringValue),
            score: try #require($0["score"]?.doubleValue))
    }
}

@Suite struct SimilarityTests {
    @Test("scores", arguments: try jaroWinklerCases())
    func scores(_ c: JaroWinklerCase) {
        // The fixture gives six decimals; vitest's toBeCloseTo(score, 6) is |diff| < 5e-7.
        #expect(abs(jaroWinkler(c.a, c.b) - c.score) < 5e-7)
    }

    @Test("is symmetric", arguments: try jaroWinklerCases())
    func symmetric(_ c: JaroWinklerCase) {
        #expect(jaroWinkler(c.a, c.b) == jaroWinkler(c.b, c.a))
    }

    @Test func fixtureIsTheVendoredOne() throws {
        #expect(try jaroWinklerCases().count == 33)
    }

    // Contract §7: each emoji is a surrogate pair, so the strings share three of four code units.
    @Test func comparesUTF16CodeUnits() {
        #expect(jaroWinkler("😀😁", "😀😂") == 0.8833333333333334)
    }

    // Precomposed and decomposed é are equal as Swift Strings but not as code units.
    @Test func doesNotUseCanonicalEquivalence() {
        #expect(jaroWinkler("\u{E9}", "e\u{301}") < 1)
    }

    // |a| > |b| + reach empties the inner window; a closed range would trap here.
    @Test func emptyMatchWindow() {
        #expect(jaroWinkler("starbux", "bar") >= 0)
        #expect(jaroWinkler("bar", "starbux") == jaroWinkler("starbux", "bar"))
    }
}

/// textScore against the reference's own values (rank.ts, run under tsx).
@Suite struct TextScoreTests {
    @Test(arguments: [
        ("Starbucks", 0.9047619047619048),
        ("Star Bakery", 0.8740259740259739),
        ("Stardust Bar", 0.8529761904761906),
    ])
    func contractExamples(name: String, expected: Double) {
        #expect(textScore(query: normalize("Starbux"), value: ["name": .string(name)]) == expected)
    }

    @Test func belowThresholdIsDropped() {
        #expect(textScore(query: normalize("Starbux"), value: ["name": .string("Home Depot")]) < scoreThreshold)
    }

    @Test func variantNameCounts() {
        let value: JSONObject = ["name": .string("München"), "variants": .array([.object(["name": .string("Munich")])])]
        #expect(textScore(query: normalize("Munich"), value: value) == 1)
    }

    // A space followed by a kept combining mark (Me) is one grapheme cluster, but JavaScript's split(" ") splits it.
    @Test func splitsWordsOnCodeUnits() {
        #expect(textScore(query: "a b", value: ["name": .string("a \u{20DD}b")]) == 0.7166666666666667)
    }

    // The reference throws on the null variant (contract §16); a port skips it, and every other unusable variant.
    @Test func unusableVariantsAreSkipped() {
        let value: JSONObject = ["name": .string("x"), "variants": .array([
            .null, .number(3), .string("s"), .object(["name": .number(5)]), .object(["name": .string("a b")]),
        ])]
        #expect(textScore(query: "a b", value: value) == 1)
    }

    @Test func noNamesScoresZero() {
        #expect(textScore(query: "a", value: [:]) == 0)
        #expect(textScore(query: "a", value: ["name": .string("  "), "variants": .string("x")]) == 0)
    }
}

import Foundation
import Testing
@testable import Atgeo

// Port of test/matchTiers.test.ts: fixtures/match-tiers.json against the internal tier function (contract §7).

struct MatchTierCase: Sendable, CustomTestStringConvertible {
    var name: String
    var query: String
    var place: JSONObject
    var tier: Int
    var testDescription: String { name }
}

private func cases() throws -> [MatchTierCase] {
    try #require(try fixture("match-tiers.json").arrayValue).map { c in
        let p = try #require(c["place"])
        var value: JSONObject = ["name": .string(try #require(p["name"]?.stringValue))]
        if let variants = p["variants"] { value["variants"] = variants }
        return MatchTierCase(
            name: try #require(c["name"]?.stringValue), query: try #require(c["query"]?.stringValue),
            place: value, tier: Int(try #require(c["tier"]?.doubleValue)))
    }
}

@Suite struct MatchTierTests {
    @Test("match tiers", arguments: try cases())
    func tier(_ c: MatchTierCase) {
        #expect(matchTier(normalize(c.query), c.place) == c.tier)
    }

    @Test func fixtureIsTheVendoredOne() throws {
        #expect(try cases().count == 36)
    }

    // Contract §7: a grapheme-wise hasPrefix says no, the code-unit prefix says yes.
    @Test func prefixIsByCodeUnitsNotGraphemes() {
        #expect(!"\u{915}\u{93F}".hasPrefix("\u{915}"))
        #expect(matchTier("\u{915}", ["name": .string("\u{915}\u{93F}")]) == 1)
    }

    @Test func tokensMayNotBeSpreadOverANameAndAVariant() {
        let value: JSONObject = ["name": .string("Alpha"), "variants": .array([.object(["name": .string("Beta")])])]
        #expect(matchTier("alpha beta", value) == 2)
        #expect(matchTier("beta", value) == 1)
    }

    @Test func aQueryThatFoldsAwayMatchesEverything() {
        #expect(matchTier("&", ["name": .string("Anything")]) == 1)
    }
}

/// Contract §8: tier sorts first in every mode, and an overview answer with text keeps tier 1 only.
@Suite struct TierOrderingTests {
    // "Starbucks" is an exact (tier 1) match for "starb" but far away and a lower-importance record; "Starbux Cafe"
    // scores higher by similarity yet matches only fuzzily (tier 2) and sits nearer.
    private let records = [
        TileRecord(value: place("fuzzy", "Starbux", [point(0, 0.001)]), importance: 100),
        TileRecord(value: place("exact", "Starbucks", [point(0, 0.01)]), importance: 1),
    ]
    private let region = Region.circle(lat: 0, lon: 0, radius: 5000)

    @Test("tier 1 first in every sort mode", arguments: SortMode.allCases)
    func tierFirst(_ sort: SortMode) {
        let hits = rank(records, region: region, query: "starbuc", sort: sort)
        #expect(hits.compactMap(\.origin) == [placeOrigin("exact"), placeOrigin("fuzzy")])
    }

    @Test func withoutTextTheOrderIsUnchanged() {
        let hits = rank(records, region: region, query: "", sort: .fused)
        #expect(hits.compactMap(\.origin) == [placeOrigin("fuzzy"), placeOrigin("exact")])
    }

    @Test("an overview answer with text drops tier 2, in every sort mode", arguments: SortMode.allCases)
    func overviewDropsFuzzy(_ sort: SortMode) {
        let hits = rank(records, region: region, query: "starbuc", sort: sort, overview: true)
        #expect(hits.compactMap(\.origin) == [placeOrigin("exact")])
        // Without text, nothing is dropped.
        if sort != .similarity {
            #expect(rank(records, region: region, query: "", sort: sort, overview: true).count == 2)
        }
    }
}

/// Contract §7: tier 1 is kept at any score, tier 2 needs 0.8, and a query whose words all fold away needs 0.6.
@Suite struct ScoreThresholds {
    private let region = Region.circle(lat: 0, lon: 0, radius: 5000)

    private func kept(_ names: [String], query: String, overview: Bool = false) -> [String] {
        let records = names.enumerated().map { i, name in TileRecord(value: place("r\(i)", name, [point(0, 0.001)])) }
        return rank(records, region: region, query: normalize(query), sort: .fused, overview: overview).compactMap { $0.place["name"]?.stringValue }
    }

    @Test func aWordMatchIsKeptWhateverItsScore() {
        let name = "Bar & Grill at the Old Quarry"
        #expect(textScore(query: "qu", value: ["name": .string(name)]) < 0.6)
        #expect(kept([name], query: "qu") == [name])
    }

    @Test func aFuzzyMatchNeedsPointEight() {
        #expect(textScore(query: "xqzjvkwpfhgy", value: ["name": .string("Qwizify")]) < 0.8)
        #expect(kept(["Qwizify"], query: "xqzjvkwpfhgy").isEmpty)
        // One typo scores above 0.8 and is kept.
        #expect(kept(["Cafe"], query: "cfae") == ["Cafe"])
    }

    @Test func aQueryWhoseWordsAllFoldAwayKeepsOnlyScoresOfPointSix() {
        #expect(kept(["&", "Anything"], query: "&") == ["&"])
    }

    @Test func overviewStillDropsFuzzyMatchesThatClearTheThreshold() {
        #expect(kept(["Cafe"], query: "cfae", overview: true).isEmpty)
    }
}

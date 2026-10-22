import Foundation
import Testing
@testable import Atgeo

struct NormalizeCase: Sendable, CustomTestStringConvertible {
    var input: String
    var expected: String
    var testDescription: String { "normalizes \(input)" }
}

private func normalizeCases() throws -> [NormalizeCase] {
    try #require(try fixture("normalize.json").arrayValue).map {
        NormalizeCase(input: try #require($0["input"]?.stringValue), expected: try #require($0["expected"]?.stringValue))
    }
}

/// The six cases the upstream fixture gains in schuyler/atgeo-sdk-js#14 (contract §7). Kept here until
/// `Fixtures/SOURCE` is re-pinned past that PR, then deleted (plan step 9).
private let finalSigmaCases = [
    NormalizeCase(input: "ΟΔΟΣ", expected: "οδος"),
    NormalizeCase(input: "Ὀδυσσεύς", expected: "οδυσσευς"),
    NormalizeCase(input: "Α.Σ.", expected: "α.ς."),
    NormalizeCase(input: "ΑΣ.Α", expected: "ασ.α"),
    NormalizeCase(input: "İstanbul", expected: "istanbul"),
    NormalizeCase(input: "ẞ", expected: "ß"),
]

@Suite struct NormalizeTests {
    // Compared by UTF-16 code units: `String ==` is canonical equivalence and would pass a port that skipped NFKD.
    @Test(arguments: try normalizeCases())
    func fixture(_ c: NormalizeCase) {
        #expect(Array(normalize(c.input).utf16) == Array(c.expected.utf16))
    }

    @Test(arguments: finalSigmaCases)
    func finalSigma(_ c: NormalizeCase) {
        #expect(Array(normalize(c.input).utf16) == Array(c.expected.utf16))
    }

    @Test func fixtureIsTheVendoredOne() throws {
        #expect(try normalizeCases().count == 30)
    }

    @Test func lowercaseSigmaInTheInputIsLeftAlone() {
        #expect(Array(normalize("οδοσ").utf16) == Array("οδοσ".utf16))
    }
}

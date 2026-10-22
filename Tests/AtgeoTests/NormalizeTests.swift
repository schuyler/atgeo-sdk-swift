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

@Suite struct NormalizeTests {
    // Compared by UTF-16 code units: `String ==` is canonical equivalence and would pass a port that skipped NFKD.
    @Test(arguments: try normalizeCases())
    func fixture(_ c: NormalizeCase) {
        #expect(Array(normalize(c.input).utf16) == Array(c.expected.utf16))
    }

    @Test func fixtureIsTheVendoredOne() throws {
        #expect(try normalizeCases().count == 41)
    }

    @Test func lowercaseSigmaInTheInputIsLeftAlone() {
        #expect(Array(normalize("οδοσ").utf16) == Array("οδοσ".utf16))
    }
}

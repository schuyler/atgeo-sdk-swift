import Foundation

// Text matching, contract §7.

/// JavaScript's `\s`, exactly. `Character.isWhitespace`, Swift `Regex`'s `\s` and
/// `CharacterSet.whitespacesAndNewlines` all include U+0085 and exclude U+FEFF.
private let whitespace: Set<Unicode.Scalar> = [
    "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}",
    "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
    "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
    "\u{205F}", "\u{3000}", "\u{FEFF}",
]

/// Unicode default full lowercase mapping, plus SpecialCasing's Final_Sigma condition.
///
/// Neither `String.lowercased()` (no Final_Sigma) nor `NSString.lowercased(with:)` (does not skip
/// `.`, `:` or `·` as case-ignorables) matches V8; see design review addendum A.
func lowercase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, u) in scalars.enumerated() {
        guard u.value == 0x03A3 else {
            out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
            continue
        }
        // Final_Sigma: a cased letter before and none after, skipping case-ignorables on both sides.
        var before = false, j = i - 1
        while j >= 0 {
            let p = scalars[j].properties
            if p.isCaseIgnorable { j -= 1; continue }
            before = p.isCased; break
        }
        var after = false, k = i + 1
        while k < scalars.count {
            let p = scalars[k].properties
            if p.isCaseIgnorable { k += 1; continue }
            after = p.isCased; break
        }
        out.append(before && !after ? "\u{03C2}" : "\u{03C3}")
    }
    return String(out)
}

/// Lowercase, NFKD, drop Mn, collapse whitespace runs to one space and trim.
func normalize(_ s: String) -> String {
    let folded = lowercase(s).decomposedStringWithCompatibilityMapping
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for u in folded.unicodeScalars {
        if u.properties.generalCategory == .nonspacingMark { continue }
        if whitespace.contains(u) { pendingSpace = !out.isEmpty; continue }
        if pendingSpace { out.append(" "); pendingSpace = false }
        out.append(u)
    }
    return String(out)
}

/// Jaro similarity over UTF-16 code units, as the reference compares JavaScript strings.
private func jaro(_ a: [UInt16], _ b: [UInt16]) -> Double {
    if a == b { return 1 }
    if a.isEmpty || b.isEmpty { return 0 }
    let reach = max(0, max(a.count, b.count) / 2 - 1)
    var aMatched = [Bool](repeating: false, count: a.count)
    var bMatched = [Bool](repeating: false, count: b.count)
    var matches = 0
    for i in 0..<a.count {
        // A `while`, not `lo...hi`: the window is empty when |a| > |b| + reach, and a closed range traps.
        var j = max(0, i - reach)
        let hi = min(b.count - 1, i + reach)
        while j <= hi {
            if !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
            j += 1
        }
    }
    if matches == 0 { return 0 }
    var transpositions = 0
    var j = 0
    for i in 0..<a.count where aMatched[i] {
        while !bMatched[j] { j += 1 }
        if a[i] != b[j] { transpositions += 1 }
        j += 1
    }
    let m = Double(matches)
    return (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
}

func jaroWinkler(_ a: [UInt16], _ b: [UInt16]) -> Double {
    let sim = jaro(a, b)
    var prefix = 0
    while prefix < 4 && prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
    return sim + Double(prefix) * 0.1 * (1 - sim)
}

/// Compares by UTF-16 code units, never by `String` equality (which is canonical equivalence).
func jaroWinkler(_ a: String, _ b: String) -> Double {
    jaroWinkler(Array(a.utf16), Array(b.utf16))
}

let scoreThreshold = 0.6
private let maxQueryTokens = 12

/// Splits on U+0020 by code unit, as JavaScript's `split(" ")` does. `String.split` would not split a
/// space that a following combining mark joins into one grapheme cluster.
private func words(_ s: [UInt16]) -> [[UInt16]] {
    s.split(separator: 0x20, omittingEmptySubsequences: false).map(Array.init)
}

private func scoreName(_ query: [UInt16], _ tokens: [[UInt16]], _ name: [UInt16]) -> Double {
    let nameTokens = words(name)
    var sum = 0.0
    for t in tokens {
        sum += nameTokens.map { jaroWinkler(t, $0) }.max()!
    }
    return 0.5 * jaroWinkler(query, name) + 0.5 * (sum / Double(tokens.count))
}

/// The best score of the place's name and variant names against a normalized, non-empty query.
func textScore(query: String, value: JSONObject) -> Double {
    let q = Array(query.utf16)
    let tokens = Array(words(q).prefix(maxQueryTokens))
    var raw: [String] = []
    if let name = value["name"]?.stringValue { raw.append(name) }
    for variant in value["variants"]?.arrayValue ?? [] {
        // A variant that is not an object, `null` included (contract §16), or has no string name is skipped.
        if let name = variant["name"]?.stringValue { raw.append(name) }
    }
    var best = 0.0
    for name in raw {
        let n = normalize(name)
        if n.isEmpty { continue }
        best = max(best, scoreName(q, tokens, Array(n.utf16)))
    }
    return best
}

/// Ordinal equality, as JavaScript's `===` on strings. `String ==` is canonical equivalence, under which
/// for example U+212A KELVIN SIGN equals "K".
func ordinalEqual(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

/// A dictionary or set key that hashes and compares a string by UTF-16 code units. `String` keys merge
/// canonically equivalent strings, which JavaScript keeps apart.
struct OrdinalKey: Hashable, Sendable {
    let string: String
    init(_ string: String) { self.string = string }
    static func == (a: OrdinalKey, b: OrdinalKey) -> Bool { ordinalEqual(a.string, b.string) }
    func hash(into hasher: inout Hasher) {
        for unit in string.utf16 { hasher.combine(unit) }
    }
}

/// Ordinal order, by UTF-16 code units, as JavaScript's `<` on strings.
func ordinalLess(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

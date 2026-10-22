import Foundation
let whitespace: Set<Unicode.Scalar> = ["\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"]

/// Unicode default (locale-independent) full lowercase mapping, including SpecialCasing's Final_Sigma context.
func lowercase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, u) in scalars.enumerated() {
        if u.value == 0x03A3 {
            // Final_Sigma: preceded by a cased letter with only case-ignorables between, and not followed by one.
            var before = false, j = i - 1
            while j >= 0 { let p = scalars[j].properties; if p.isCaseIgnorable { j -= 1; continue }; before = p.isCased; break }
            var after = false, k = i + 1
            while k < scalars.count { let p = scalars[k].properties; if p.isCaseIgnorable { k += 1; continue }; after = p.isCased; break }
            out.append(before && !after ? "\u{03C2}" : "\u{03C3}")
        } else {
            out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
        }
    }
    return String(out)
}
func normalize(_ s: String) -> String {
    let folded = lowercase(s).decomposedStringWithCompatibilityMapping
    var out = String.UnicodeScalarView(); var pending = false
    for u in folded.unicodeScalars {
        if u.properties.generalCategory == .nonspacingMark { continue }
        if whitespace.contains(u) { pending = !out.isEmpty; continue }
        if pending { out.append(" "); pending = false }
        out.append(u)
    }
    return String(out)
}
func sc(_ s: String) -> String { s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") }
let fixtures = CommandLine.arguments[1]
var fail = 0
for c in try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixtures + "/normalize.json"))) as! [[String: String]] {
    if Array(normalize(c["input"]!).utf16) != Array(c["expected"]!.utf16) { fail += 1 }
}
FileHandle.standardError.write("normalize.json (utf16 compare), hand Final_Sigma: failures = \(fail)\n".data(using: .utf8)!)
for line in try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n") {
    print(sc(normalize(String(line))))
}

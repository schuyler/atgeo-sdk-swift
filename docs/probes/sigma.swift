import Foundation
let whitespace: Set<Unicode.Scalar> = ["\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"]
func normalize(_ s: String) -> String {
    let folded = (s as NSString).lowercased(with: nil).decomposedStringWithCompatibilityMapping
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
var fail = 0
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1] + "/normalize.json"))
for c in try! JSONSerialization.jsonObject(with: data) as! [[String: String]] {
    if normalize(c["input"]!) != c["expected"]! { fail += 1; print("FAIL", c["input"]!, sc(normalize(c["input"]!))) }
}
print("NSString variant: normalize.json failures =", fail)
for s in ["ΟΔΟΣ", "ΟΔΟΣ ΑΒ", "Σ", "ΣΑ", "İstanbul", "ẞ", "ΑΣ.", "Ὀδυσσεύς"] { print(s, "->", normalize(s), "[\(sc(normalize(s)))]") }

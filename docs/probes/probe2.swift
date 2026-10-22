import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    if Array(normalize(c["input"]!).utf16) != Array(c["expected"]!.utf16) { fail += 1; print("FAIL", c["input"]!) }
}
print("normalize.json by UTF-16 code units, NSString variant: failures =", fail)
print("== sigma cases (NSString lowercased(with: nil))")
let sigmaCases = ["οδοσ", "ΟΔΟσ", "οδοΣ", "ΣΣ", "ΑΣ ΑΣ", "ΑΣ'", "ΑΣ1", "aΣ", "ΑΣb", "Α.Σ.", "Σ.", "ΑΣ.Α", "ΑΣ'Α", "1Σ", "ΑΣ\u{0301}", "Ά\u{0301}Σ", "ΑΣ\u{200B}Α", "ΑΣ-ΒΣ", "ΑΣ_ΒΣ", "ΒΑΣΙΛΙΣΣΑ", "Σ Σ", "ΑΣ\u{AD}Α"]
for s in sigmaCases { print(s.debugDescription, "->", sc(normalize(s))) }

print("== percentEncodedQueryItems on Linux")
let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved)! }
for base in ["https://places.atgeo.org", "http://localhost:8000", "http://localhost:8000/", "http://localhost:8000/base/"] {
    var c = URLComponents(string: base + "/xrpc/org.atgeo.getPlace")!
    c.percentEncodedQueryItems = [URLQueryItem(name: enc("uri"), value: enc("urn:atgeo:a:b:x+y z&w=1#f%"))]
    print(base, "->", c.url?.absoluteString ?? "nil")
}
var c2 = URLComponents(string: "https://places.atgeo.org/xrpc/org.atgeo.getTiles")!
c2.percentEncodedQueryItems = [URLQueryItem(name: "dataset", value: enc("overturemaps.org")), URLQueryItem(name: "collection", value: enc("place")), URLQueryItem(name: "bbox", value: enc("-122.42,37.77,-122.41,37.78"))]
print("getTiles ->", c2.url!.absoluteString)
let parsed = URLComponents(string: c2.url!.absoluteString)!
print("round-trip queryItems ->", parsed.queryItems!.map { "\($0.name)=\($0.value ?? "")" })

print("== JSON edge: 1e400 and huge ints")
for s in ["[1e400]", "[9223372036854775808]", "[-9223372036854775808]", "[123456789012345678901234567890]"] {
    let d = s.data(using: .utf8)!
    print(s, "JSONSerialization:", (try? JSONSerialization.jsonObject(with: d)).map { "\($0)" } ?? "throws", " JSONDecoder [Double]:", (try? JSONDecoder().decode([Double].self, from: d)).map { "\($0)" } ?? "throws")
}
print("Int64(1.9) =", Int64(1.9), " Int64(-1.9) =", Int64(-1.9), " Int64(-0.9) =", Int64(-0.9))
print("Double(units)/100 for units=0 ->", (Double(0) / 100).sign == .minus ? "-0.0" : "0.0")

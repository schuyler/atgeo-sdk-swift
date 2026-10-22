import Foundation
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}
for s in [#"["\uD800"]"#, #"["😀"]"#, #"{"a":1,"a":2}"#, #"{"é":1,"é":2}"#, #"[1E400]"#, #"[-1e400]"#, #"[1e-400]"#, "[01]", "[1.]", "[.5]", "[NaN]", "[Infinity]"] {
    let d = s.data(using: .utf8)!
    print(s, "-> JSONDecoder:", (try? JSONDecoder().decode(JSONValue.self, from: d)).map { "\($0)" } ?? "throws", "| JSONSerialization:", (try? JSONSerialization.jsonObject(with: d)).map { "\($0)" } ?? "throws")
}
// Int64 subtraction overflow in comparator
let a: Int64 = .max, b: Int64 = -1
print("Int64 comparator overflow check:", a &- b, "(wrapping); plain '-' would trap")
// -0.0 pattern match
let v = -0.0
switch v { case 0: print("-0.0 matches pattern 0: yes"); default: print("no") }

import Foundation
enum J: Decodable { case n(Double), s(String), o([String: J]), a([J]), nul, b(Bool)
  init(from d: Decoder) throws { let c = try d.singleValueContainer()
    if c.decodeNil() { self = .nul } else if let b = try? c.decode(Bool.self) { self = .b(b) } else if let n = try? c.decode(Double.self) { self = .n(n) } else if let s = try? c.decode(String.self) { self = .s(s) } else if let a = try? c.decode([J].self) { self = .a(a) } else { self = .o(try c.decode([String: J].self)) } } }
for s in [#"{"a":1,"a":2}"#, "[1e-400]", #"["\uD800"]"#] {
  let d = s.data(using: .utf8)!
  print(s, "| JSONDecoder:", (try? JSONDecoder().decode(J.self, from: d)).map { "\($0)" } ?? "throws", "| JSONSerialization:", (try? JSONSerialization.jsonObject(with: d)).map { "\($0)" } ?? "throws")
}

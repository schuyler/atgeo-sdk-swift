import Foundation

/// Parses a response body into a `JSONValue` (design review note 12). Strict RFC 8259, any value at the top
/// level, read straight from the bytes. It behaves as `JSON.parse` does where Swift can, on every platform:
/// `1e400` is infinity and `1e-400` zero, the last of duplicate keys wins, invalid UTF-8 becomes U+FFFD as
/// in the reference's `response.text()`, and a leading byte-order mark is skipped. A lone surrogate escape,
/// which a Swift `String` cannot hold, becomes U+FFFD. Nesting deeper than 512 fails, as in Foundation.
/// Errors are `DecodingError.dataCorrupted`. Exposed to `atgeo-bench` only, as SPI.
@_spi(Benchmark) public func parseJSON(_ data: Data) throws -> JSONValue {
    try data.withUnsafeBytes { raw in
        var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
        return try parser.document()
    }
}

private let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
private let minus = UInt8(ascii: "-"), plus = UInt8(ascii: "+"), dot = UInt8(ascii: "."), zero = UInt8(ascii: "0")

private func isDigit(_ b: UInt8) -> Bool { b &- zero < 10 }

private struct JSONParser {
    static let maxDepth = 512

    let bytes: UnsafeBufferPointer<UInt8>
    var i = 0
    var depth = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    func error(_ message: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "\(message) at byte \(i)"))
    }

    var atEnd: Bool { i >= bytes.count }

    mutating func document() throws -> JSONValue {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        skipWhitespace()
        let v = try value()
        skipWhitespace()
        guard atEnd else { throw error("unexpected text after the value") }
        return v
    }

    mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func value() throws -> JSONValue {
        guard !atEnd else { throw error("unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return .object(try object())
        case UInt8(ascii: "["): return .array(try array())
        case quote: return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case minus, zero...UInt8(ascii: "9"): return .number(try number())
        default: throw error("unexpected character")
        }
    }

    mutating func literal(_ word: StaticString) throws {
        let n = word.utf8CodeUnitCount
        guard bytes.count - i >= n else { throw error("unexpected end of input") }
        for k in 0..<n where bytes[i + k] != word.utf8Start[k] { throw error("invalid literal") }
        i += n
    }

    mutating func enter() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw error("nesting deeper than \(Self.maxDepth)") }
        i += 1
        skipWhitespace()
    }

    mutating func object() throws -> JSONObject {
        try enter()
        defer { depth -= 1 }
        var result = JSONObject()
        if !atEnd, bytes[i] == UInt8(ascii: "}") { i += 1; return result }
        while true {
            guard !atEnd, bytes[i] == quote else { throw error("expected a string key") }
            let key = try string()
            skipWhitespace()
            guard !atEnd, bytes[i] == colon else { throw error("expected ':'") }
            i += 1
            skipWhitespace()
            result[key] = try value()  // a later duplicate replaces an earlier one, as in JSON.parse
            skipWhitespace()
            guard !atEnd else { throw error("unexpected end of input") }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return result }
            guard bytes[i] == comma else { throw error("expected ',' or '}'") }
            i += 1
            skipWhitespace()
        }
    }

    mutating func array() throws -> [JSONValue] {
        try enter()
        defer { depth -= 1 }
        var result: [JSONValue] = []
        if !atEnd, bytes[i] == UInt8(ascii: "]") { i += 1; return result }
        while true {
            result.append(try value())
            skipWhitespace()
            guard !atEnd else { throw error("unexpected end of input") }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return result }
            guard bytes[i] == comma else { throw error("expected ',' or ']'") }
            i += 1
            skipWhitespace()
        }
    }

    /// At the opening quote. A string without escapes, most of a tile, is decoded straight from the input.
    mutating func string() throws -> String {
        i += 1
        let start = i
        while i < bytes.count {
            let b = bytes[i]
            if b == quote {
                defer { i += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            }
            if b == backslash { return try escapedString(from: start) }
            guard b >= 0x20 else { throw error("control character in string") }
            i += 1
        }
        throw error("unterminated string")
    }

    /// At the first backslash of a string that began at `start`.
    mutating func escapedString(from start: Int) throws -> String {
        var buffer = Array(bytes[start..<i])
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            switch b {
            case quote:
                return String(decoding: buffer, as: UTF8.self)
            case backslash:
                guard !atEnd else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case quote, backslash, UInt8(ascii: "/"): buffer.append(e)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var unit = try hex4()
                    // A high surrogate takes a following low one as its pair; anything else leaves it lone.
                    if 0xD800...0xDBFF ~= unit, bytes.count - i >= 6, bytes[i] == backslash, bytes[i + 1] == UInt8(ascii: "u") {
                        let resume = i
                        i += 2
                        let low = try hex4()
                        if 0xDC00...0xDFFF ~= low {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = resume
                        }
                    }
                    UTF8.encode(Unicode.Scalar(unit) ?? "\u{FFFD}") { buffer.append($0) }
                default:
                    i -= 1
                    throw error("invalid escape")
                }
            default:
                guard b >= 0x20 else { i -= 1; throw error("control character in string") }
                buffer.append(b)
            }
        }
        throw error("unterminated string")
    }

    mutating func hex4() throws -> UInt32 {
        guard bytes.count - i >= 4 else { throw error("unexpected end of input") }
        var unit: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[i]
            let digit: UInt8
            switch b {
            case zero...UInt8(ascii: "9"): digit = b - zero
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = b - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = b - UInt8(ascii: "A") + 10
            default: throw error("invalid \\u escape")
            }
            unit = unit << 4 | UInt32(digit)
            i += 1
        }
        return unit
    }

    /// Checks the JSON number grammar, then converts. An integer of up to 15 digits is below 2^53 and exact
    /// in a double, so it skips the text conversion; it accumulates in `Int64`, since `Int` is 32 bits on
    /// watchOS. Anything else goes through `Double(String)`, which rounds correctly, gives infinity on
    /// overflow and zero on underflow.
    mutating func number() throws -> Double {
        let start = i
        let negative = bytes[i] == minus
        if negative { i += 1 }
        guard !atEnd, isDigit(bytes[i]) else { throw error("invalid number") }
        if bytes[i] == zero {
            i += 1
        } else {
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        }
        let integerEnd = i
        if i < bytes.count, bytes[i] == dot {
            i += 1
            guard !atEnd, isDigit(bytes[i]) else { throw error("invalid number") }
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] | 0x20 == UInt8(ascii: "e") {
            i += 1
            if i < bytes.count, bytes[i] == plus || bytes[i] == minus { i += 1 }
            guard !atEnd, isDigit(bytes[i]) else { throw error("invalid number") }
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        }
        let digitsStart = negative ? start + 1 : start
        if integerEnd == i, i - digitsStart <= 15 {
            var n: Int64 = 0
            for k in digitsStart..<i { n = n * 10 + Int64(bytes[k] - zero) }
            return negative ? -Double(n) : Double(n)
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        guard let d = Double(text) else { throw error("invalid number") }
        return d
    }
}

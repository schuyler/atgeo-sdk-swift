import Foundation

/// A JSON value, surfaced untouched (contract §1). Numbers are `Double`, so integers beyond 2^53 lose
/// precision exactly as in the JavaScript client. Key order is not preserved.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Double before String, so that `true` is not read as 1 and `1` not as "1".
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try container.decode(JSONObject.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

public typealias JSONObject = [String: JSONValue]

extension JSONValue {
    /// `nil` unless `.object`.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// `nil` unless `.array` and in range.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }
}

/// Decodes a response body. Every 2xx body goes through here once, then through the lenient mappers;
/// nothing decodes a response with a synthesized `Decodable` (design review, addendum B).
func decodeJSON(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

/// The error for a body that is JSON but has no usable body in contract §1's narrow sense.
func noUsableBody(_ description: String) -> DecodingError {
    .dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: description))
}

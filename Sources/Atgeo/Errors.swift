import Foundation

/// A non-2xx answer from the server. `code` is the server's error name, or "HttpError" (contract §1).
public struct AtgeoError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    /// The response's HTTP status, so a caller can tell a refused request (4xx) from a server failure
    /// (5xx) without matching on `code`, which is an open list.
    public let status: Int

    public init(code: String, message: String, status: Int) {
        self.code = code
        self.message = message
        self.status = status
    }
}

/// A bad argument, raised before any request (contract §3).
public enum AtgeoArgumentError: Error, Sendable, Equatable {
    case invalidRegion(String)        // the message names what was wrong
    case similarityRequiresText
}

// Without LocalizedError, `localizedDescription` is Foundation's generic "The operation could not be
// completed. (Atgeo.AtgeoError error 1.)", which drops the server's message.

extension AtgeoError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { "\(message) (\(code))" }
    public var description: String { "AtgeoError(\(code), HTTP \(status)): \(message)" }
}

extension AtgeoArgumentError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .invalidRegion(let what): what
        case .similarityRequiresText: "sort .similarity requires search text"
        }
    }

    public var description: String { "AtgeoArgumentError: \(errorDescription!)" }
}

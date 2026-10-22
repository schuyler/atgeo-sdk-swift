/// A non-2xx answer from the server. `code` is the server's error name, or "HttpError" (contract §1).
public struct AtgeoError: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A bad argument, raised before any request (contract §3).
public enum AtgeoArgumentError: Error, Sendable, Equatable {
    case invalidRegion(String)        // the message names what was wrong
    case similarityRequiresText
}

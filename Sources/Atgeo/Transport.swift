import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The HTTP seam and XRPC URLs, contract §1 and spec §4.

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    /// GET the URL exactly as given. Must throw on cancellation. Must not follow its own caching policy by default.
    func get(_ url: URL) async throws -> HTTPResponse
}

/// Sent in place of URLSession's own, which on Apple platforms is `<app> (<build>) CFNetwork/<version>
/// Darwin/<version>`: it names the app and gives away the OS version (contract §12, item 5).
let userAgent = "atgeo-client-swift"

/// The default transport. Sets `Accept: application/json`, `User-Agent: atgeo-client-swift` and
/// `Accept-Language: *` on every request; the last replaces the one URLSession derives from the user's
/// locale. Whatever else URLSession adds by itself (Accept-Encoding, for one) varies by platform.
public struct URLSessionTransport: HTTPTransport {
    /// Ephemeral, with no URL cache and no cookies: the client starts cold on every launch (contract §10, §14).
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.defaultSession) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        let (body, response) = try await session.data(for: request)
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
    }
}

/// RFC 3986 unreserved characters. Everything else in a query name or value is percent-encoded, `+`, `,`
/// and `:` included; `URLComponents.queryItems` would leave `+` raw, which a form decoder reads as a space.
private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

func percentEncode(_ s: String) -> String {
    // Fails only for a string that is not valid Unicode, which a Swift String cannot be.
    s.addingPercentEncoding(withAllowedCharacters: unreserved)!
}

/// The server with every trailing slash removed (contract §1, §2). `URL(string: "http://h/")` keeps its slash,
/// and appending "/xrpc/…" to it would give "//xrpc/…".
func xrpcBase(_ server: URL) -> String {
    var base = server.absoluteString
    while base.hasSuffix("/") { base.removeLast() }
    return base
}

/// `{base}/xrpc/{nsid}` with the parameters in the order given, each name and value percent-encoded and
/// assigned through `percentEncodedQueryItems`; no query at all without parameters.
func xrpcURL(base: String, nsid: String, _ params: [(name: String, value: String)]) -> URL? {
    guard var components = URLComponents(string: "\(base)/xrpc/\(nsid)") else { return nil }
    if !params.isEmpty {
        components.percentEncodedQueryItems = params.map { URLQueryItem(name: percentEncode($0.name), value: percentEncode($0.value)) }
    }
    return components.url
}

/// Fetches a URL exactly as given and returns the body. The body is read before the status is checked, so
/// a non-2xx answer is always reported with the server's own code (contract §1).
func fetchBody(_ transport: any HTTPTransport, _ url: URL) async throws -> Data {
    let response = try await transport.get(url)
    guard (200..<300).contains(response.status) else { throw atgeoError(status: response.status, body: response.body) }
    return response.body
}

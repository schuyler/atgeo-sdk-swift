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

/// Sent in place of URLSession's own, which on Apple platforms is `<app>/<build> CFNetwork/<version>
/// Darwin/<version>`: it names the app and gives away the OS version (contract §12, item 5).
let userAgent = "atgeo-client-swift"

/// The default transport. Sets `Accept: application/json`, `User-Agent: atgeo-client-swift` and
/// `Accept-Language: *` on every request; the last replaces the one URLSession derives from the user's
/// locale. Whatever else URLSession adds by itself (Accept-Encoding, for one) varies by platform.
///
/// A body larger than `maxBodyBytes`, counted after URLSession has decoded any `Content-Encoding`, fails the
/// request with `URLError(.dataLengthExceedsMaximum)`: a network failure, and inside a search a failed tile
/// (contract §14). The server names the tile URLs, and a megabyte of gzip can decode to a gigabyte.
public struct URLSessionTransport: HTTPTransport {
    /// Ephemeral, with no URL cache and no cookies: the client starts cold on every launch (contract §10, §14).
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // FoundationNetworking consults only a session delegate about redirects, not a task delegate.
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    /// 32 MiB, as the Kotlin port's; the largest tiles places.atgeo.org serves are about 2 MB.
    public static let defaultMaxBodyBytes = 32 * 1024 * 1024

    private let session: URLSession
    private let maxBodyBytes: Int

    /// A session of your own may set headers in `httpAdditionalHeaders`; the `User-Agent` and
    /// `Accept-Language` this transport sets on each request take precedence over them.
    ///
    /// A redirect to anything but an http or https URL without credentials fails the request with
    /// `URLError(.redirectToNonExistentLocation)`, as `fetch` refuses it, rather than send a password. On Apple
    /// platforms that holds for any session; on Linux, where FoundationNetworking asks only a session's own
    /// delegate about redirects, only for `defaultSession`, and a session of your own follows its own policy.
    ///
    /// `maxBodyBytes` must be positive, as in the Kotlin port; a negative cap would fail even an empty body
    /// on Linux and not on Apple platforms.
    public init(session: URLSession = URLSessionTransport.defaultSession, maxBodyBytes: Int = URLSessionTransport.defaultMaxBodyBytes) {
        precondition(maxBodyBytes > 0, "maxBodyBytes must be positive")
        self.session = session
        self.maxBodyBytes = maxBodyBytes
    }

    public func get(_ url: URL) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        let tooLarge = URLError(.dataLengthExceedsMaximum, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #if canImport(FoundationNetworking)
        // FoundationNetworking has no bytes(for:); it does call a task delegate given to data(for:delegate:).
        let limit = BodyLimit(maxBodyBytes)
        let body: Data, response: URLResponse
        do {
            (body, response) = try await session.data(for: request, delegate: limit)
        } catch where limit.exceeded {
            throw tooLarge
        }
        // The delegate's cancel can land after the last byte has arrived, so the body is checked too.
        if limit.exceeded || body.count > maxBodyBytes { throw tooLarge }
        #else
        // Apple platforms do not pass the body to data(for:delegate:)'s delegate, and reading bytes(for:) a byte
        // at a time costs several times as long (CI, 2 MiB over loopback: 8 to 13 ms against 3 to 5). So a plain
        // data task carries a task delegate that collects the body in the chunks URLSession delivers.
        let collector = BodyCollector(maxBodyBytes)
        let task = session.dataTask(with: request)
        task.delegate = collector
        let body: Data
        do {
            body = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.start(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch where collector.exceeded {
            throw tooLarge
        }
        let response = task.response
        #endif
        let http = response as? HTTPURLResponse
        // A redirect the delegate declined comes back as the 3xx itself; it is a network failure, as in fetch.
        if let http, [301, 302, 303, 307, 308].contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           !isAllowedRedirect(URL(string: location, relativeTo: http.url ?? url)?.absoluteURL) {
            throw refusedRedirect()
        }
        return HTTPResponse(status: http?.statusCode ?? 0, body: body)
    }
}

/// Declines a redirect to anything but an http or https URL without credentials, for the default session.
/// A session the app supplies keeps its own redirect policy on Linux, where only a session delegate is asked.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(isAllowedRedirect(request.url) ? request : nil)
    }
}

#if canImport(FoundationNetworking)

/// Counts a task's body as it arrives, decoded, and cancels the task once it passes the limit, so that an
/// oversized body is not read to the end. A task delegate, not a session one, so that it works on a session
/// the app supplies; FoundationNetworking calls a task delegate only for `data(for:delegate:)`.
private final class BodyLimit: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var received = 0
    private var over = false

    init(_ limit: Int) { self.limit = limit }

    var exceeded: Bool { lock.withLock { over } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            received += data.count
            if received > limit && !over { over = true; return true }
            return false
        }
        if cancel { dataTask.cancel() }
    }
}
#else
/// Collects a data task's body as URLSession delivers it, decoded, and cancels the task once it passes the
/// limit, so that an oversized body is not read to the end. A task delegate, so that it works on a session the
/// app supplies.
private final class BodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var body = Data()
    private var over = false
    private var continuation: CheckedContinuation<Data, any Error>?
    /// The task's outcome, when it finished before `start`: a task cancelled before it was resumed, as one is
    /// when its Swift task was already cancelled, can complete before the continuation is handed over.
    private var outcome: Result<Data, any Error>?

    init(_ limit: Int) { self.limit = limit }

    var exceeded: Bool { lock.withLock { over } }

    /// Apple platforms ask a task delegate about redirects, so this holds for a session the app supplies too.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(isAllowedRedirect(request.url) ? request : nil)
    }

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        let finished = lock.withLock { () -> Result<Data, any Error>? in
            if outcome == nil { self.continuation = continuation }
            return outcome
        }
        if let finished { continuation.resume(with: finished) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            if over { return false }
            if body.count + data.count > limit {
                over = true
                body = Data()
                return true
            }
            body.append(data)
            return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Result<Data, any Error>) in
            let result: Result<Data, any Error>
            if over {
                result = .failure(URLError(.dataLengthExceedsMaximum))
            } else if let error {
                result = .failure(error)
            } else {
                result = .success(body)
            }
            defer { self.continuation = nil }
            if self.continuation == nil { outcome = result }
            return (self.continuation, result)
        }
        continuation?.resume(with: result)
    }
}
#endif

/// Whether the default transport follows a redirect: only to an http or https URL without credentials, as
/// `fetch` does, so that no redirect sends a password or reads a `file:` URL (contract §4.4). URLSession would
/// send a `Location: http://user:pw@host/` as `Authorization: Basic`.
private func isAllowedRedirect(_ url: URL?) -> Bool {
    guard let url else { return false }
    return tileRequestURL(url.absoluteString) != nil
}

/// A refused redirect: a network failure, and inside a tile fetch a `transport` failure.
private func refusedRedirect() -> URLError {
    URLError(.redirectToNonExistentLocation, userInfo: [
        NSLocalizedDescriptionKey: "redirect to a URL that is not http or https without credentials",
    ])
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

/// The URL a tile is fetched from, or nil when contract §4.4 refuses it: a failed tile, with no request made.
///
/// The tile URL is first trimmed as WHATWG URL parsing (the reference's `fetch`) trims it: leading and
/// trailing C0 controls and spaces removed, tab, LF and CR dropped anywhere. Then it must be an absolute
/// `http` or `https` URL with a host and no credentials, both as `isHTTPURL` reads the string and as
/// Foundation parses it, so that no transport, the default or an app's, ever sees `file:` or a password.
/// The second reading matters where Foundation's parse differs from WHATWG's: Foundation on Linux reads
/// `https://h\@x/y` as user `h\` at host `x`, where WHATWG reads host `h` and path `/@x/y`. The userinfo is
/// checked percent-encoded, since `URL.user` is nil for one that does not decode (`h%5C%FF`).
func tileRequestURL(_ tile: String) -> URL? {
    let trimmed = trimmedLikeWHATWG(tile)
    guard isHTTPURL(trimmed), let url = URL(string: trimmed),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.percentEncodedHost, !host.isEmpty,
          components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
          url.user == nil, url.password == nil,
          // Foundation maps a non-ASCII host (IDNA, NFKC), which can turn a character into a delimiter:
          // `localhost\u{2100}x` becomes host `localhosta/cx`. What it would send must read the same again.
          isHTTPURL(url.absoluteString), let again = URL(string: url.absoluteString),
          again.host == url.host, again.port == url.port
    else { return nil }
    return url
}

/// What a refused tile fails with: `URLError(.unsupportedURL)`, which is what FoundationNetworking itself
/// throws for a `file:` or `ftp:` URL.
func refusedTileURL() -> URLError {
    URLError(.unsupportedURL, userInfo: [
        NSLocalizedDescriptionKey: "tile URL is not an absolute http or https URL without credentials",
    ])
}

/// Leading and trailing C0 controls and spaces removed, and tab, LF and CR dropped anywhere, as WHATWG URL
/// parsing does before it reads a URL.
func trimmedLikeWHATWG(_ s: String) -> String {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
          let last = scalars.lastIndex(where: { $0.value > 0x20 }) else { return "" }
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: scalars[first...last].filter { $0 != "\t" && $0 != "\n" && $0 != "\r" })
    return String(kept)
}

/// An absolute `http` or `https` URL (scheme in any case) with a non-empty host and no credentials, read as
/// the Rust and Python ports read it. The authority ends at `/`, `\`, `?` or `#`, as a special URL's does in
/// WHATWG. Any `@` before the first `/`, `?` or `#` is refused, a backslash notwithstanding, since Foundation
/// does not end the authority at a backslash and would read what precedes the `@` as a userinfo; so is an empty
/// userinfo (`https://@h/x`), which `fetch` would drop and fetch (CONFORMANCE.md). The host holds no `%`, a
/// bracketed host only hex digits, `:` and `.`, and a port is at most 65535, as WHATWG requires.
func isHTTPURL(_ url: String) -> Bool {
    let bytes = Array(url.utf8)
    let separator = Array("://".utf8)
    guard let end = bytes.indices.first(where: { bytes[$0...].starts(with: separator) }) else { return false }
    let scheme = bytes[..<end].map { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) ? $0 | 0x20 : $0 }
    guard scheme == Array("http".utf8) || scheme == Array("https".utf8) else { return false }
    let rest = bytes[(end + separator.count)...]
    if rest.prefix(while: { !"/?#".utf8.contains($0) }).contains(UInt8(ascii: "@")) { return false }
    let authority = rest.prefix { !"/\\?#".utf8.contains($0) }
    // NFKC, which IDNA applies to a host, maps some characters to delimiters (`\u{FF1A}` to `:`, `\u{2100}` to
    // `a/c`, `\u{FF20}` to `@`); WHATWG then refuses the host, so refuse one that gains any.
    let mapped = String(decoding: authority, as: UTF8.self).precomposedStringWithCompatibilityMapping
    if delimiterCount(mapped) != delimiterCount(String(decoding: authority, as: UTF8.self)) { return false }
    let host: ArraySlice<UInt8>
    let afterHost: ArraySlice<UInt8>
    if authority.first == UInt8(ascii: "[") {
        guard let close = authority.firstIndex(of: UInt8(ascii: "]")) else { return false }
        host = authority[(authority.startIndex + 1)..<close]
        guard host.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") }) else { return false }
        afterHost = authority[(close + 1)...]
    } else {
        host = authority.prefix { $0 != UInt8(ascii: ":") }
        afterHost = authority[host.endIndex...]
    }
    guard !host.isEmpty, !host.contains(UInt8(ascii: "%")) else { return false }
    if afterHost.isEmpty { return true }
    guard afterHost.first == UInt8(ascii: ":") else { return false }
    let port = afterHost.dropFirst()
    guard port.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return false }
    let value = port.drop { $0 == UInt8(ascii: "0") }
    return value.count < 5 || (value.count == 5 && Array(value).lexicographicallyPrecedes(Array("65536".utf8)))
}

/// The characters a host cannot hold, or that would end or split it: delimiters, `%`, brackets, whitespace
/// and controls.
private func delimiterCount(_ s: String) -> Int {
    s.unicodeScalars.filter { "/\\?#@:%[]".unicodeScalars.contains($0) || $0.properties.isWhitespace || $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }.count
}

private func isHexDigit(_ b: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b | 0x20)
}

/// Fetches a URL exactly as given and returns the body. The body is read before the status is checked, so
/// a non-2xx answer is always reported with the server's own code (contract §1).
func fetchBody(_ transport: any HTTPTransport, _ url: URL) async throws -> Data {
    try checkedBody(try await transport.get(url))
}

/// The body of a 2xx response; for any other status, the `AtgeoError` the body describes.
func checkedBody(_ response: HTTPResponse) throws -> Data {
    guard (200..<300).contains(response.status) else { throw atgeoError(status: response.status, body: response.body) }
    return response.body
}

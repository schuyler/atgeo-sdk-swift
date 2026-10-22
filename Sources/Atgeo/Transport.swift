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

/// The default transport. Sets `Accept: application/json` on every request and nothing else; whatever
/// URLSession adds by itself (User-Agent, Accept-Language, Accept-Encoding) varies by platform.
///
/// A body larger than `maxBodyBytes`, counted after URLSession has decoded any `Content-Encoding`, fails the
/// request with `URLError(.dataLengthExceedsMaximum)`: a network failure, and inside a search a failed tile
/// (contract §14). The server names the tile URLs, and a few kilobytes of gzip can decode to gigabytes.
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

    /// 32 MiB, as the Kotlin port's; the largest tiles places.atgeo.org serves are about 2 MB.
    public static let defaultMaxBodyBytes = 32 * 1024 * 1024

    private let session: URLSession
    private let maxBodyBytes: Int

    public init(session: URLSession = URLSessionTransport.defaultSession, maxBodyBytes: Int = URLSessionTransport.defaultMaxBodyBytes) {
        self.session = session
        self.maxBodyBytes = maxBodyBytes
    }

    public func get(_ url: URL) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
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

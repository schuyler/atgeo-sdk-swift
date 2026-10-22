// Compile-only probe for Swift 6 language mode on Linux: can the spec's transport shape be Sendable?
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable { public var status: Int; public var body: Data }
public protocol HTTPTransport: Sendable { func get(_ url: URL) async throws -> HTTPResponse }

public struct URLSessionTransport: HTTPTransport {
    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()
    let session: URLSession
    public init(session: URLSession = URLSessionTransport.defaultSession) { self.session = session }
    public func get(_ url: URL) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: URLRequest(url: url))
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

public actor Client {
    let transport: any HTTPTransport
    let now: @Sendable () -> Date
    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.now = now
    }
}

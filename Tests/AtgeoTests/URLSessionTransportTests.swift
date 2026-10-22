import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

/// The default transport against a real loopback server (spec §7), since the fake replaces it everywhere
/// else. `TransportTests.swift` is the transport.test.ts port, in step 8.
@Suite struct URLSessionTransportTests {
    private let transport = URLSessionTransport()

    @Test func a4xxWithAJSONErrorBodyCarriesTheServersCode() async throws {
        let server = try Loopback { _ in
            .init(status: 400, headers: [("Content-Type", "application/json")],
                  body: Data(#"{"error":"BboxTooLarge","message":"bbox too large"}"#.utf8))
        }
        await #expect(throws: AtgeoError(code: "BboxTooLarge", message: "bbox too large", status: 400)) {
            _ = try await fetchBody(transport, server.url("/xrpc/org.atgeo.getTiles"))
        }
    }

    @Test func a4xxWithAnEmptyBodyIsAnHttpError() async throws {
        let server = try Loopback { _ in .init(status: 404) }
        await #expect(throws: AtgeoError(code: "HttpError", message: "HTTP 404", status: 404)) {
            _ = try await fetchBody(transport, server.url("/missing"))
        }
    }

    @Test func a2xxReturnsTheBody() async throws {
        let server = try Loopback { _ in .init(status: 200, body: Data("{}".utf8)) }
        #expect(try await fetchBody(transport, server.url("/ok")) == Data("{}".utf8))
    }

    @Test func aSameSchemeRedirectIsFollowed() async throws {
        let server = try Loopback { request in
            request.path == "/start"
                ? .init(status: 302, headers: [("Location", "/final")])
                : .init(status: 200, body: Data(#"{"tiles":[]}"#.utf8))
        }
        let body = try await fetchBody(transport, server.url("/start"))
        #expect(body == Data(#"{"tiles":[]}"#.utf8))
        #expect(server.received.map(\.path) == ["/start", "/final"])
        // The redirected request carries the transport's headers too, not URLSession's own (contract §12, item 5).
        for request in server.received {
            let agent = request.headers.filter { $0.name.lowercased() == "user-agent" }.map(\.value)
            let language = request.headers.filter { $0.name.lowercased() == "accept-language" }.map(\.value)
            #expect(agent == ["atgeo-client-swift"], "\(request.path)")
            #expect(language == ["*"], "\(request.path)")
        }
    }

    /// `fetch` refuses a redirect to a URL with credentials or to anything but http or https; URLSession would
    /// follow one and send the credentials as `Authorization: Basic`.
    /// (`Location: file:///etc/hostname` is not here: FoundationNetworking reads it as a path on the same host,
    /// `http://127.0.0.1:PORT/etc/hostname`, and follows that; CONFORMANCE.md.)
    @Test(arguments: ["http://user:pw@127.0.0.1:PORT/final", "http://@127.0.0.1:PORT/final", "ftp://127.0.0.1:PORT/final",
                      "http://u%FF@127.0.0.1:PORT/final"])
    func aRedirectToARefusedURLIsANetworkFailure(_ location: String) async throws {
        let port = PortHolder()
        let server = try Loopback { request in
            request.path == "/start"
                ? .init(status: 302, headers: [("Location", location.replacingOccurrences(of: "PORT", with: "\(port.value)"))])
                : .init(status: 200, body: Data("{}".utf8))
        }
        port.value = server.port
        do {
            let response = try await transport.get(server.url("/start"))
            Issue.record("expected a network failure, got \(response.status) \(String(decoding: response.body, as: UTF8.self).prefix(80))")
        } catch {
            #expect((error as? URLError)?.code == .redirectToNonExistentLocation, "\(error)")
        }
        #expect(server.received.map(\.path) == ["/start"], "\(server.received.map(\.path))")
        #expect(server.received.allSatisfy { !$0.headers.contains { $0.name.lowercased() == "authorization" } })
    }

    #if !canImport(FoundationNetworking)
    /// On Apple platforms the transport's task delegate is asked about redirects in place of the session's; it
    /// passes an allowed redirect on to the app's own session delegate, so the app's policy still holds.
    @Test func anAppSessionDelegateThatDeclinesRedirectsIsStillAsked() async throws {
        let server = try Loopback { request in
            request.path == "/start" ? .init(status: 302, headers: [("Location", "/final")]) : .init(status: 200, body: Data("{}".utf8))
        }
        let delegate = RedirectDelegate(follow: false)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let response = try await URLSessionTransport(session: session).get(server.url("/start"))
        #expect(response.status == 302)
        #expect(server.received.map(\.path) == ["/start"])
        #expect(delegate.asked == 1)
    }

    @Test func aCredentialedRedirectIsRefusedEvenWhenTheAppDelegateWouldFollowIt() async throws {
        let port = PortHolder()
        let server = try Loopback { request in
            request.path == "/start"
                ? .init(status: 302, headers: [("Location", "http://user:pw@127.0.0.1:\(port.value)/final")])
                : .init(status: 200, body: Data("{}".utf8))
        }
        port.value = server.port
        let delegate = RedirectDelegate(follow: true)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        do {
            let response = try await URLSessionTransport(session: session).get(server.url("/start"))
            Issue.record("expected a network failure, got \(response.status)")
        } catch {
            #expect((error as? URLError)?.code == .redirectToNonExistentLocation, "\(error)")
        }
        #expect(server.received.map(\.path) == ["/start"])
        #expect(delegate.asked == 0)
    }
    #endif

    @Test func cancellingTheTaskAbortsAHeldRequest() async throws {
        let server = try Loopback { _ in .init(status: 200, body: Data("{}".utf8), hold: true) }
        let transport = self.transport
        let task = Task { try await transport.get(server.url("/held")) }
        #expect(await server.waitForHeldRequest())
        task.cancel()
        // A watchdog: if cancellation did not abort the request, releasing it lets the task finish with a 200,
        // and the expectation below fails instead of the test hanging.
        let watchdog = Task.detached { try await Task.sleep(nanoseconds: 5_000_000_000); server.release() }
        let result = await task.result
        watchdog.cancel()
        server.release()
        switch result {
        case .success(let response):
            Issue.record("expected cancellation, got status \(response.status)")
        case .failure(let error):
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            #expect(cancelled, "got \(error)")
        }
    }

    /// A task already cancelled when the request starts: the transport cancels it before resuming it, and
    /// the task's completion can then arrive before the transport is waiting for it.
    @Test func aTaskCancelledBeforeTheRequestFailsWithoutHanging() async throws {
        let server = try Loopback { _ in .init(status: 200, body: Data("{}".utf8), hold: true) }
        let transport = self.transport
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.get(server.url("/held"))
        }
        let watchdog = Task.detached { try await Task.sleep(nanoseconds: 5_000_000_000); server.release() }
        let result = await task.result
        watchdog.cancel()
        server.release()
        switch result {
        case .success(let response):
            Issue.record("expected cancellation, got status \(response.status)")
        case .failure(let error):
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            #expect(cancelled, "got \(error)")
        }
    }

    @Test func sendsItsFixedHeadersAndNothingFromTheRequest() async throws {
        let marker = "zanzibar-quokka-7749295"
        let server = try Loopback { _ in .init(status: 200) }
        _ = try await transport.get(server.url("/echo/\(marker)?q=\(marker)"))
        let request = try #require(server.received.first)
        #expect(request.method == "GET")
        let accept = request.headers.filter { $0.name.lowercased() == "accept" }.map(\.value)
        #expect(accept == ["application/json"])
        let agent = request.headers.filter { $0.name.lowercased() == "user-agent" }.map(\.value)
        #expect(agent == ["atgeo-client-swift"])
        // Replaces the locale-derived one URLSession would add (en-US,en;q=0.9 on Apple CI runners, en on Linux).
        let language = request.headers.filter { $0.name.lowercased() == "accept-language" }.map(\.value)
        #expect(language == ["*"])
        for (name, value) in request.headers {
            #expect(!name.lowercased().contains(marker) && !value.lowercased().contains(marker), "\(name): \(value)")
        }
    }
}

@Suite struct XRPCURLTests {
    // Design review finding 2: queryItems leaves + raw; the unreserved set encodes everything else.
    @Test func encodesEveryReservedCharacter() throws {
        let url = try #require(xrpcURL(base: "http://localhost:8000", nsid: "org.atgeo.getPlace", [("uri", "a+b&c=d#e f%g,h:i/j?k~")]))
        #expect(url.absoluteString == "http://localhost:8000/xrpc/org.atgeo.getPlace?uri=a%2Bb%26c%3Dd%23e%20f%25g%2Ch%3Ai%2Fj%3Fk~")
    }

    @Test func encodesNonASCIIAsUTF8() throws {
        let url = try #require(xrpcURL(base: "https://h", nsid: "n", [("slug", "caf\u{E9} \u{1F600}")]))
        #expect(url.absoluteString == "https://h/xrpc/n?slug=caf%C3%A9%20%F0%9F%98%80")
    }

    @Test func keepsParameterOrderAndOmitsAnEmptyQuery() throws {
        let tiles = try #require(xrpcURL(base: "https://h", nsid: "org.atgeo.getTiles",
                                         [("dataset", "d"), ("collection", "c"), ("bbox", "-1.00,2.00,3.00,4.00")]))
        #expect(tiles.absoluteString == "https://h/xrpc/org.atgeo.getTiles?dataset=d&collection=c&bbox=-1.00%2C2.00%2C3.00%2C4.00")
        #expect(try #require(xrpcURL(base: "https://h", nsid: "org.atgeo.describeService", [])).absoluteString
                == "https://h/xrpc/org.atgeo.describeService")
    }

    @Test("strips every trailing slash", arguments: [
        ("http://localhost:8000/", "http://localhost:8000"),
        ("http://localhost:8000//", "http://localhost:8000"),
        ("https://places.atgeo.org", "https://places.atgeo.org"),
        ("https://h/base/", "https://h/base"),
    ])
    func stripsTrailingSlashes(server: String, base: String) throws {
        #expect(xrpcBase(try #require(URL(string: server))) == base)
        #expect(try #require(xrpcURL(base: xrpcBase(URL(string: server)!), nsid: "n", [])).absoluteString == "\(base)/xrpc/n")
    }
}

private final class PortHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16 = 0
    var value: UInt16 {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }
}

#if !canImport(FoundationNetworking)
/// An app's session delegate that follows redirects or declines them, and counts how often it is asked.
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let follow: Bool
    private let lock = NSLock()
    private var count = 0
    init(follow: Bool) { self.follow = follow }
    var asked: Int { lock.withLock { count } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { count += 1 }
        completionHandler(follow ? request : nil)
    }
}
#endif

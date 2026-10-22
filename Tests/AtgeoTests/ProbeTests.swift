import Foundation
import Testing
@testable import Atgeo

#if !canImport(FoundationNetworking)
/// Collects a task's body through a task-specific delegate, cancelling past a limit.
private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    let lock = NSLock()
    var body = Data()
    var over = false
    var calls = 0
    var continuation: CheckedContinuation<Data, Error>?
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            calls += 1
            if body.count + data.count > limit { over = true; return true }
            body.append(data); return false
        }
        if cancel { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = lock.withLock { () -> CheckedContinuation<Data, Error>? in defer { continuation = nil }; return continuation }
        if let error { c?.resume(throwing: error) } else { c?.resume(returning: lock.withLock { body }) }
    }
}

private func viaTaskDelegate(_ url: URL, limit: Int) async throws -> (Data, Int, Bool) {
    let collector = Collector(limit: limit)
    let task = URLSessionTransport.defaultSession.dataTask(with: url)
    task.delegate = collector
    do {
        let data = try await withCheckedThrowingContinuation { c in
            collector.lock.withLock { collector.continuation = c }
            task.resume()
        }
        return (data, collector.calls, collector.over)
    } catch {
        return (Data(), collector.calls, collector.over)
    }
}

private func ms(_ body: () async throws -> Void) async rethrows -> Double {
    var times: [Double] = []
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    return times.sorted()[3]
}

@Suite(.serialized) struct ProbeTests {
    @Test func probe() async throws {
        let two = Data(repeating: 0x30, count: 2 << 20)
        let server = try Loopback { request in
            request.path == "/two" ? .init(status: 200, body: two)
                : .init(status: 200, headers: [("Content-Encoding", "gzip")], body: gzipOfZeros(128 << 20), trickle: (bytes: 4096, pause: 0.005))
        }
        let url = server.url("/two")
        let plain = try await ms { _ = try await URLSessionTransport.defaultSession.data(from: url) }
        let streamed = try await ms {
            let (bytes, _) = try await URLSessionTransport.defaultSession.bytes(from: url)
            var buffer: [UInt8] = []
            buffer.reserveCapacity(2 << 20)
            for try await b in bytes { buffer.append(b) }
            precondition(buffer.count == 2 << 20)
        }
        var calls = 0
        let delegated = try await ms {
            let (data, n, _) = try await viaTaskDelegate(url, limit: 32 << 20)
            precondition(data.count == 2 << 20, "task delegate got \(data.count)")
            calls = n
        }
        print("PROBE 2 MiB: data(from:) \(plain) ms, bytes(from:) loop \(streamed) ms, task delegate \(delegated) ms in \(calls) calls")
        let (_, bombCalls, over) = try await viaTaskDelegate(server.url("/bomb"), limit: 4 << 20)
        let sent = await server.waitForBodySent()
        print("PROBE bomb via task delegate: over=\(over) calls=\(bombCalls) server sent \(String(describing: sent))")
    }
}
#endif

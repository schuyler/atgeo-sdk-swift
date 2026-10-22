import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal HTTP/1.1 server on 127.0.0.1 for the default transport's tests (spec §7). One request per
/// connection, answered by `handler`; a response marked `hold` waits until `release()` is called. No
/// third-party dependency.
final class Loopback: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Header names as sent, in order.
        var headers: [(name: String, value: String)]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [(name: String, value: String)] = []
        var body: Data = Data()
        var hold = false
    }

    private let listener: Int32
    let port: UInt16
    private let handler: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var requests: [Request] = []
    private let released = DispatchSemaphore(value: 0)
    private var heldCount = 0
    private let heldArrived = DispatchSemaphore(value: 0)

    var received: [Request] { lock.withLock { requests } }

    init(_ handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit { close(listener) }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    /// Lets every held response go.
    func release() { for _ in 0..<lock.withLock({ heldCount }) { released.signal() } }

    /// Waits until a held request has arrived, or the timeout passes. The semaphore is waited on off the
    /// cooperative pool: blocking a pool thread here can starve the task that sends the request, since Apple
    /// platforms size the pool to the core count and the whole suite runs on it in parallel.
    func waitForHeldRequest(timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [heldArrived] in
                continuation.resume(returning: heldArrived.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private func acceptLoop() {
        while true {
            let conn = accept(listener, nil, nil)
            if conn < 0 { return }   // the listener was closed
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            Thread { [self] in serve(conn) }.start()
        }
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = Array("\r\n\r\n".utf8)
        while !buffer.containsSubsequence(terminator) {
            let n = recv(conn, &chunk, chunk.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let head = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let request = Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
        lock.withLock { requests.append(request) }
        let response = handler(request)
        if response.hold {
            lock.withLock { heldCount += 1 }
            heldArrived.signal()
            released.wait()
        }
        var text = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        write(conn, Data(text.utf8) + response.body)
    }

    private func write(_ conn: Int32, _ data: Data) {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(conn, raw.baseAddress! + offset, raw.count - offset, flags)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard count >= needle.count else { return false }
        return (0...(count - needle.count)).contains { Array(self[$0..<($0 + needle.count)]) == needle }
    }
}

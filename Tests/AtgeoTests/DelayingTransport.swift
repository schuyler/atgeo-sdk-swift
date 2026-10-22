import Foundation
@testable import Atgeo

/// Wraps a transport, delaying the URLs `delay` names, and records how many requests were in flight at
/// once. The delay is a cancellable sleep, so a long one is a held request that task cancellation aborts.
final class DelayingTransport: HTTPTransport, @unchecked Sendable {
    private let base: any HTTPTransport
    private let delay: @Sendable (URL) -> TimeInterval?
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var finished: [URL] = []

    init(_ base: any HTTPTransport, delay: @escaping @Sendable (URL) -> TimeInterval?) {
        self.base = base
        self.delay = delay
    }

    /// The most requests that were in flight at once.
    var peakInFlight: Int { lock.withLock { peak } }
    /// URLs in the order their responses completed.
    var completionOrder: [URL] { lock.withLock { finished } }

    func get(_ url: URL) async throws -> HTTPResponse {
        lock.withLock {
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let seconds = delay(url) { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let response = try await base.get(url)
        lock.withLock { finished.append(url) }
        return response
    }
}

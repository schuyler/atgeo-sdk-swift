import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

/// A gzip member holding `count` ASCII zeros: a fixed-Huffman deflate block of one literal and then matches of
/// 258 bytes at distance 1, 13 bits each, so about 160 to 1. Built here because Foundation has no zlib.
func gzipOfZeros(_ count: Int) -> Data {
    var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
    var bits: UInt64 = 0, used = 0
    /// Deflate packs from the low bit; Huffman codes go most significant bit first.
    func put(_ value: UInt64, _ n: Int) {
        bits |= value << UInt64(used)
        used += n
        while used >= 8 { out.append(UInt8(bits & 0xFF)); bits >>= 8; used -= 8 }
    }
    func code(_ value: UInt64, _ n: Int) {
        var reversed: UInt64 = 0
        for i in 0..<n where value & (1 << UInt64(i)) != 0 { reversed |= 1 << UInt64(n - 1 - i) }
        put(reversed, n)
    }
    put(1, 1)                                     // the final block
    put(1, 2)                                     // fixed Huffman codes
    let literal: UInt64 = 0x30 + 0x30             // "0": literals 0-143 are 8 bits from 0b00110000
    code(literal, 8)
    for _ in 0..<((count - 1) / 258) {
        code(0b1100_0101, 8)                      // length 258 is code 285
        code(0, 5)                                // distance 1 is code 0
    }
    for _ in 0..<((count - 1) % 258) { code(literal, 8) }
    code(0, 7)                                    // end of block
    if used > 0 { out.append(UInt8(bits & 0xFF)) }

    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        table[i] = c
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for _ in 0..<count { crc = table[Int((crc ^ 0x30) & 0xFF)] ^ (crc >> 8) }
    crc ^= 0xFFFF_FFFF
    for value in [crc, UInt32(truncatingIfNeeded: count)] {
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
    return Data(out)
}

/// The default transport's cap on a response body, contract §14.
@Suite struct BodyCapTests {
    @Test func theZeroBombDecodesToWhatItClaims() async throws {
        let server = try Loopback { _ in .init(status: 200, headers: [("Content-Encoding", "gzip")], body: gzipOfZeros(1_000_003)) }
        let response = try await URLSessionTransport().get(server.url("/small"))
        #expect(response.body == Data(repeating: 0x30, count: 1_000_003))
    }

    @Test func aBodyAtTheCapPassesAndOneByteMoreFails() async throws {
        let server = try Loopback { request in .init(status: 200, body: Data(repeating: 0x20, count: request.path == "/at" ? 1000 : 1001)) }
        let transport = URLSessionTransport(maxBodyBytes: 1000)
        #expect(try await transport.get(server.url("/at")).body.count == 1000)
        await expectOverCap { _ = try await transport.get(server.url("/over")) }
    }

    @Test func aGzipBodyIsCappedByItsDecodedSize() async throws {
        let server = try Loopback { _ in .init(status: 200, headers: [("Content-Encoding", "gzip")], body: gzipOfZeros(1001)) }
        await expectOverCap { _ = try await URLSessionTransport(maxBodyBytes: 1000).get(server.url("/bomb")) }
    }

    /// The body is sent slowly enough that the cap is passed long before the end: the transfer must stop
    /// there, not be read to the end and then rejected.
    @Test func aGzipBombIsAbandonedPartWay() async throws {
        let bomb = gzipOfZeros(128 * 1024 * 1024)
        let server = try Loopback { _ in
            .init(status: 200, headers: [("Content-Encoding", "gzip")], body: bomb, trickle: (bytes: 4096, pause: 0.005))
        }
        // A 4 MiB cap rather than the default, to keep the read short in a debug build.
        await expectOverCap { _ = try await URLSessionTransport(maxBodyBytes: 4 << 20).get(server.url("/bomb")) }
        let sent = try #require(await server.waitForBodySent())
        #expect(!sent.complete)
        // 4 MiB is a 32nd of the decoded body; allow generously for what was in flight at the cancel.
        #expect(sent.bytes < bomb.count / 2, "sent \(sent.bytes) of \(bomb.count)")
    }

    @Test func anOversizedTileIsAFailedTile() async throws {
        let base = Box()
        let server = try Loopback { request in
            switch request.path {
            case let p where p.hasPrefix("/xrpc/org.atgeo.getTiles"):
                .init(status: 200, body: Data(#"{"tiles":["\#(base.value)/big","\#(base.value)/small"]}"#.utf8))
            case "/big":
                .init(status: 200, headers: [("Content-Encoding", "gzip")], body: gzipOfZeros(2000))
            default:
                .init(status: 200, body: Data(#"{"records":[]}"#.utf8))
            }
        }
        base.value = "http://127.0.0.1:\(server.port)"
        let client = AtgeoClient(server: URL(string: base.value)!, transport: URLSessionTransport(maxBodyBytes: 1000))
        let result = try await client.searchPlaces(region: .bbox(west: 0, south: 0, east: 0.01, north: 0.01), dataset: "overturemaps.org", collection: "place")
        #expect(result.tiles == .init(fetched: 1, failed: 1))
        #expect(!result.complete)
    }
}

/// By code: a `URLError`'s equality includes its userInfo, which carries the failing URL.
private func expectOverCap(_ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("expected URLError(.dataLengthExceedsMaximum), got a body", sourceLocation: sourceLocation)
    } catch {
        #expect((error as? URLError)?.code == .dataLengthExceedsMaximum, "got \(error)", sourceLocation: sourceLocation)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

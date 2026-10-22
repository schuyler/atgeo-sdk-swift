import Testing
@testable import Atgeo

@Suite("ASCII normalization") struct ASCIINormalization {
    @Test("agrees with the full Unicode path on every ASCII character and on mixed strings")
    func agrees() {
        var inputs = (0..<128).map { String(UnicodeScalar(UInt8($0))) }
        inputs += ["  Alpha\tBETA\u{0B}cafe\r\n ", "\u{0C}", "", "A  B", "x\u{0}y", "Ünïcödé is not ASCII"]
        var seed: UInt64 = 1
        for _ in 0..<2_000 {
            var s: [UInt8] = []
            for _ in 0..<12 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                s.append(UInt8(seed >> 57))
            }
            inputs.append(String(decoding: s, as: UTF8.self))
        }
        for s in inputs {
            #expect(Array(normalize(s).utf16) == Array(normalizeUnicode(s).utf16), "\(s.debugDescription)")
        }
    }
}

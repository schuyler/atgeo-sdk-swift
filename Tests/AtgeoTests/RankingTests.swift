import Foundation
import Testing
@testable import Atgeo

struct RankingScenario: Sendable, CustomTestStringConvertible {
    var name: String
    var dataset: String
    var collection: String
    var region: Region
    var text: String?
    var sort: SortMode
    /// The fake server answers getTiles with an overview (contract §8).
    var overview: Bool
    var records: [TileRecord]
    var top: [(k: Int, origins: [String])]
    var absent: [String]
    var testDescription: String { name }
}

private func scenarios() throws -> [RankingScenario] {
    try #require(try fixture("ranking-scenarios.json").arrayValue).map { s in
        let r = try #require(s["region"])
        let region: Region
        if let b = r["bbox"]?.arrayValue?.compactMap(\.doubleValue), b.count == 4 {
            region = .bbox(west: b[0], south: b[1], east: b[2], north: b[3])
        } else {
            region = .circle(
                lat: try #require(r["lat"]?.doubleValue), lon: try #require(r["lon"]?.doubleValue),
                radius: try #require(r["radius"]?.doubleValue))
        }
        let records = try #require(s["records"]?.arrayValue).map { rec in
            TileRecord(value: try #require(rec["value"]?.objectValue), uri: nil, importance: int64(rec["importance"]))
        }
        let expect = try #require(s["expect"])
        let top = try #require(expect["top"]?.arrayValue).map { t in
            (k: Int(try #require(t["k"]?.doubleValue)), origins: try #require(t["origins"]?.arrayValue).compactMap(\.stringValue))
        }
        return RankingScenario(
            name: try #require(s["name"]?.stringValue),
            dataset: try #require(s["dataset"]?.stringValue),
            collection: try #require(s["collection"]?.stringValue),
            region: region,
            text: s["text"]?.stringValue,
            sort: s["sort"]?.stringValue.flatMap(SortMode.init(rawValue:)) ?? .fused,
            overview: s["overview"]?.boolValue ?? false,
            records: records,
            top: top,
            absent: expect["absent"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }
}

private func hit(_ origin: String?) -> TileRecord {
    var value = place("x", "X", [point(0, 0)])
    value["origin"] = origin.map(JSONValue.string)
    return TileRecord(value: value)
}

private func origins(_ hits: [SearchHit]) -> [String?] { hits.map(\.origin) }

/// The fixture through contract §4.6 to §4.9 (no network), as a search of the scenario's dataset and collection
/// (contract §8).
@Suite struct RankingTests {
    @Test("ranking scenarios", arguments: try scenarios())
    func scenario(_ s: RankingScenario) {
        let places = assemble(
            records: s.records, region: s.region, query: normalize(s.text ?? ""), sort: s.sort,
            dataset: s.dataset, collection: s.collection, overview: s.overview)
        let got = places.compactMap(\.origin)
        for (k, wanted) in s.top {
            for origin in wanted { #expect(got.prefix(k).contains(origin), "\(origin) in top \(k) of \(got)") }
        }
        for origin in s.absent { #expect(!got.contains(origin), "\(origin) absent from \(got)") }
        if s.top.isEmpty { #expect(got.isEmpty) }
    }

    @Test func fixtureIsTheVendoredOne() throws {
        #expect(try scenarios().count == 19)
    }

    // Addendum E: a literal (b.importance ?? 0) - (a.importance ?? 0) traps here.
    @Test func importanceAcrossTheWholeRangeDoesNotOverflow() {
        let records = [
            TileRecord(value: place("a", "A", [point(0, 0)]), importance: -1),
            TileRecord(value: place("b", "B", [point(0, 0)]), importance: .max),
            TileRecord(value: place("c", "C", [point(0, 0)]), importance: nil),
            TileRecord(value: place("d", "D", [point(0, 0)]), importance: -9223372036854774784),
        ]
        let hits = rank(records, region: .circle(lat: 0, lon: 0, radius: 1), query: "", sort: .fused)
        #expect(origins(hits) == ["b", "c", "a", "d"].map { placeOrigin($0) })
    }

    // "\u{10000}" < "\u{FF61}" by UTF-16 code units (a surrogate pair starts with 0xD800), not by String's <.
    @Test func originsCompareByCodeUnits() {
        #expect(!("\u{10000}" < "\u{FF61}"))
        let records = [hit("\u{FF61}"), hit(nil), hit("\u{10000}")]
        let hits = rank(records, region: .circle(lat: 0, lon: 0, radius: 1), query: "", sort: .fused)
        #expect(origins(hits) == ["\u{10000}", "\u{FF61}", nil])
    }

    @Test func tiesOnEveryComparatorKeepInputOrder() {
        let a = TileRecord(value: ["name": .string("1"), "locations": .array([point(0, 0)])])
        let b = TileRecord(value: ["name": .string("2"), "locations": .array([point(0, 0)])])
        for sort in SortMode.allCases {
            let hits = rank([a, b, a, b], region: .circle(lat: 0, lon: 0, radius: 1), query: "", sort: sort)
            #expect(hits.map { $0.place["name"]?.stringValue } == ["1", "2", "1", "2"])
        }
    }

    @Test func dedupeKeysByCodeUnitsAndKeepsKeylessRecords() {
        let pre = TileRecord(value: ["origin": .string("urn:x:\u{E9}")])
        let dec = TileRecord(value: ["origin": .string("urn:x:e\u{301}")])
        let viaUri = TileRecord(value: [:], uri: "urn:x:\u{E9}")
        let keyless = TileRecord(value: ["n": .number(1)])
        #expect(dedupe([pre, dec, viaUri, keyless, keyless]) == [pre, dec, keyless, keyless])
    }

    @Test func collectionPrefixIsByCodeUnitsWithTheTrailingColon() {
        let r = { (o: String) in TileRecord(value: ["origin": .string(o)]) }
        #expect(inCollection(r("urn:atgeo:osm:way:1"), dataset: "osm", collection: "way"))
        #expect(!inCollection(r("urn:atgeo:osm:wayside:1"), dataset: "osm", collection: "way"))
        #expect(!inCollection(TileRecord(value: [:], uri: "urn:atgeo:osm:way:1"), dataset: "osm", collection: "way"))
        // A combining mark after the colon joins it into one grapheme; JavaScript's startsWith still matches.
        #expect(inCollection(r("urn:atgeo:osm:way:\u{301}1"), dataset: "osm", collection: "way"))
        #expect(!"urn:atgeo:osm:way:\u{301}1".hasPrefix("urn:atgeo:osm:way:"))
    }
}

/// Port of test/ranking.test.ts: the same fixture, through the client and the fake server.
@Suite struct RankingThroughTheClientTests {
    @Test("ranking scenarios", arguments: try scenarios())
    func scenario(_ s: RankingScenario) async throws {
        let url = "https://places.atgeo.org/tiles/t0.json"
        let body: JSONObject = ["tiles": .array([.string(url)]), "overview": .bool(true)]
        var tilesFor: (@Sendable (String) -> TilesForAnswer)?
        if s.overview { tilesFor = { _ in TilesForAnswer.body(body) } }
        let server = try FakeServer(tilesets: [overture([FakeTile(url: url, records: s.records)])], tilesFor: tilesFor)
        let places = try await server.client().searchPlaces(region: s.region, dataset: s.dataset, text: s.text, collection: s.collection, sort: s.sort).places
        let got = places.compactMap(\.origin)
        for (k, wanted) in s.top {
            for origin in wanted { #expect(got.prefix(k).contains(origin), "\(origin) in top \(k) of \(got)") }
        }
        for origin in s.absent { #expect(!got.contains(origin), "\(origin) absent from \(got)") }
        if s.top.isEmpty { #expect(got.isEmpty) }
    }
}

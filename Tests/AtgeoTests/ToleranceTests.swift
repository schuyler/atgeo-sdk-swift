import Foundation
import Testing
@testable import Atgeo

// No reference counterpart: every contract §16 behaviour is one where the reference crashes or is laxer
// than §1, so the reference has no test of it. Unit level here (bodies in, values out); step 8 adds the
// same cases through the fake server.

private func json(_ text: String) throws -> JSONValue { try decodeJSON(Data(text.utf8)) }

private func isDecodingError(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch is DecodingError { return true } catch { return false }
}

private let here = Region.circle(lat: 0, lon: 0, radius: 1000)

@Suite("contract §16, bullet 1: getTiles bodies") struct GetTilesBodies {
    @Test("no tiles array is no usable tile list", arguments: ["{}", "[]", #"{"tiles":"x"}"#, "null", "0", #""s""#, #"{"tiles":null}"#])
    func noTilesArray(body: String) throws {
        let v = try json(body)
        #expect(isDecodingError { _ = try tileList(v) })
    }

    @Test func nonStringEntriesAreSkipped() throws {
        let list = try tileList(try json(#"{"tiles":["https://a/1",2,null,{"u":"x"},["y"],true,"https://a/2"]}"#))
        #expect(list.tiles == ["https://a/1", "https://a/2"])
    }
}

@Suite("contract §16, bullet 2: null locations and variants") struct NullElements {
    @Test func nullLocationIsSkippedAndALaterOneUsed() {
        let value: JSONObject = ["origin": .string("o"), "locations": .array([.null, point(0, 0)])]
        #expect(assemble(records: [TileRecord(value: value)], region: here, query: "", sort: .fused,
                         dataset: "d", collection: nil).count == 1)
    }

    @Test func nullVariantIsSkippedWithText() {
        let value: JSONObject = [
            "origin": .string("o"), "name": .string("Munich"),
            "variants": .array([.null]), "locations": .array([point(0, 0)]),
        ]
        let hits = assemble(records: [TileRecord(value: value)], region: here, query: "munich", sort: .fused,
                            dataset: "d", collection: nil)
        #expect(hits.first?.score == 1)
    }
}

@Suite("contract §16, bullet 3: unusable records") struct UnusableRecords {
    @Test func unusableRecordsAreSkippedAndTheTileKept() throws {
        let payload = try json(#"""
        {"records":[1,"s",[],null,{"uri":"u0"},{"value":null,"uri":"u1"},{"value":3,"uri":"u2"},
                    {"value":"v","uri":"u3"},{"value":[],"uri":"u4"},{"value":{"name":"ok"},"uri":"u5"}]}
        """#)
        let records = try tileRecords(payload)
        #expect(records == [TileRecord(value: ["name": .string("ok")], uri: "u5")])
    }

    @Test func aTileOfOnlyUnusableRecordsIsStillUsed() throws {
        #expect(try tileRecords(try json(#"{"records":[null,1]}"#)).isEmpty)
        #expect(try tileRecords(try json(#"{"records":[]}"#)).isEmpty)
    }

    // The reference consumes the dedupe key of a scalar-valued record, losing a later good copy.
    @Test func aScalarValueDoesNotConsumeItsDedupeKey() throws {
        let records = try tileRecords(try json(#"""
        {"records":[{"value":5,"uri":"urn:x"},
                    {"value":{"locations":[{"$type":"community.lexicon.location.geo","latitude":"0","longitude":"0"}]},"uri":"urn:x"}]}
        """#))
        let hits = assemble(records: records, region: here, query: "", sort: .fused, dataset: "d", collection: nil)
        #expect(hits.map(\.origin) == ["urn:x"])
    }

    @Test("a payload that is not a records object fails the tile",
          arguments: ["null", "[]", "1", #""s""#, "{}", #"{"records":{}}"#, #"{"records":"x"}"#])
    func badPayload(body: String) throws {
        let v = try json(body)
        #expect(isDecodingError { _ = try tileRecords(v) })
    }
}

@Suite("contract §16, bullet 4: wrong-typed fields are absent") struct WrongTypedFields {
    @Test func nonStringUriIsAbsent() throws {
        let records = try tileRecords(try json(#"{"records":[{"value":{},"uri":5},{"value":{},"uri":{"a":1}}]}"#))
        #expect(records.map(\.uri) == [nil, nil])
        #expect(records.map(recordKey) == [nil, nil])
    }

    @Test func nonNumberImportanceIsAbsent() throws {
        let records = try tileRecords(try json(#"{"records":[{"value":{},"importance":"5"},{"value":{},"importance":[5]},{"value":{},"importance":true},{"value":{},"importance":null}]}"#))
        #expect(records.map(\.importance) == [nil, nil, nil, nil])
    }

    @Test("importance range and truncation", arguments: [
        ("1", Int64?.some(1)), ("1.9", 1), ("-1.9", -1), ("-0.9", 0), ("0", 0),
        ("9007199254740993", 9007199254740992),
        ("9223372036854774784", 9223372036854774784),
        ("9223372036854775807", nil), ("9223372036854775808", nil), ("-9223372036854775808", nil), ("1e300", nil),
    ])
    func importance(literal: String, expected: Int64?) throws {
        let records = try tileRecords(try json(#"{"records":[{"value":{},"importance":\#(literal)}]}"#))
        #expect(records.first?.importance == expected)
    }

    @Test func oneElementArrayCoordinateIsNoLocation() {
        let value: JSONObject = ["locations": .array([.object([
            "$type": .string("community.lexicon.location.geo"), "latitude": .array([.number(0.5)]), "longitude": .number(0),
        ])])]
        #expect(locate(value).point == nil)
    }

    @Test("error body fields are judged on their own", arguments: [
        (#"{"error":"BboxTooLarge","message":"too big"}"#, "BboxTooLarge", "too big"),
        (#"{"error":"BboxTooLarge"}"#, "BboxTooLarge", "HTTP 400"),
        (#"{"message":"too big"}"#, "HttpError", "too big"),
        (#"{"error":5,"message":"too big"}"#, "HttpError", "too big"),
        (#"{"error":"X","message":{"m":1}}"#, "X", "HTTP 400"),
        (#"{"error":null,"message":null}"#, "HttpError", "HTTP 400"),
        ("null", "HttpError", "HTTP 400"),
        (#"["BboxTooLarge"]"#, "HttpError", "HTTP 400"),
        (#""BboxTooLarge""#, "HttpError", "HTTP 400"),
        ("", "HttpError", "HTTP 400"),
        ("<html>", "HttpError", "HTTP 400"),
    ])
    func errorBody(body: String, code: String, message: String) {
        #expect(atgeoError(status: 400, body: Data(body.utf8)) == AtgeoError(code: code, message: message))
    }

    @Test func unknownCodesPassThrough() {
        #expect(atgeoError(status: 503, body: Data(#"{"error":"SomethingNew"}"#.utf8)) == AtgeoError(code: "SomethingNew", message: "HTTP 503"))
    }
}

@Suite("contract §16, bullet 5: getPlace and describe bodies") struct PlaceAndDescribeBodies {
    @Test("getPlace with no record object", arguments: ["null", "{}", #"{"record":null}"#, #"{"record":"x"}"#, #"{"record":[]}"#, "[]", "1"])
    func noRecord(body: String) throws {
        let v = try json(body)
        #expect(isDecodingError { _ = try placeRecord(v, origin: "o") })
    }

    @Test func getPlaceReturnsTheCallersOrigin() throws {
        let r = try placeRecord(try json(#"{"uri":"other","record":{"name":"N"},"importance":7}"#), origin: "mine")
        #expect(r == PlaceRecord(origin: "mine", place: ["name": .string("N")], importance: 7))
        #expect(try placeRecord(try json(#"{"record":{},"importance":"7"}"#), origin: "o").importance == nil)
    }

    @Test("describe bodies that are not objects", arguments: ["null", "false", "0", #""""#, "[]", "true", "1"])
    func describeNotAnObject(body: String) throws {
        let v = try json(body)
        #expect(isDecodingError { _ = try serviceDescription(v) })
        #expect(isDecodingError { _ = try tileset(v) })
    }
}

@Suite("overview truthiness") struct OverviewTruthiness {
    // nil: the field is absent.
    @Test(arguments: [
        (String?.none, false), ("null", false), ("false", false), ("0", false), ("-0", false), ("-0.0", false),
        (#""""#, false), ("true", true), ("1", true), ("-1", true), ("0.5", true), (#""false""#, true),
        (#""0""#, true), (#"" ""#, true), ("[]", true), ("{}", true),
    ])
    func overview(literal: String?, expected: Bool) throws {
        let body = literal.map { #"{"tiles":[],"overview":\#($0)}"# } ?? #"{"tiles":[]}"#
        #expect(try tileList(try json(body)).overview == expected)
    }
}

@Suite("describe types read leniently") struct DescribeTypes {
    @Test func serviceDescriptionDefaultsAndDrops() throws {
        #expect(try serviceDescription(try json("{}")) == ServiceDescription(did: nil, tilesets: []))
        let s = try serviceDescription(try json(#"""
        {"did":5,"tilesets":[null,1,{"slug":"a","collections":"x"},{"slug":7,"collections":[null,{"dataset":"d","collection":3,"extra":1}]}],"unknown":true}
        """#))
        #expect(s.did == nil)
        #expect(s.tilesets == [
            .init(slug: "a", collections: []),
            .init(slug: nil, collections: [CollectionRef(dataset: "d", collection: nil)]),
        ])
        #expect(try serviceDescription(try json(#"{"tilesets":"x"}"#)).tilesets == [])
    }

    @Test func tilesetDefaultsAndDrops() throws {
        let empty = try tileset(try json("{}"))
        #expect(empty == Tileset(slug: nil, publishedAt: nil, extent: nil, collections: [], references: nil))
        let t = try tileset(try json(#"""
        {"slug":"s","publishedAt":5,"extent":{"north":"1","south":2,"east":"3"},
         "collections":[null,{"dataset":"d","recordCount":12.7,"licenses":["a",1,"b"],"categories":[{"value":"v","count":3},2,{"count":1e300}],"locationFormats":"x"}],
         "references":[{"dataset":"r","licenses":"x"},"y"]}
        """#))
        #expect(t.slug == "s")
        #expect(t.publishedAt == nil)
        #expect(t.extent == Tileset.Extent(north: "1", south: nil, east: "3", west: nil))
        #expect(t.collections.count == 1)
        let c = try #require(t.collections.first)
        #expect(c.dataset == "d" && c.recordCount == 12 && c.licenses == ["a", "b"] && c.locationFormats == nil)
        #expect(c.categories == [.init(value: "v", count: 3), .init(value: nil, count: nil)])
        #expect(t.references == [CollectionAttribution(dataset: "r", collection: nil, release: nil, source: nil, licenses: nil, attribution: nil)])
        #expect(try tileset(try json(#"{"extent":"x","collections":{},"references":5}"#)).extent == nil)
    }

    // Addendum B: the synthesized decoder is strict and is never used on a response.
    @Test func synthesizedCodableIsStrict() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ServiceDescription.self, from: Data("{}".utf8)) }
    }
}

/// Addendum C: the parser's behaviour at the margins, as CONFORMANCE.md records it. The parser is the
/// port's own (note 12), so these hold on every platform; under JSONDecoder the first four differed.
@Suite("parser margins (CONFORMANCE.md)") struct ParserMargins {
    @Test func overflowingNumberIsInfinity() throws {
        #expect(try json("[1e400]") == .array([.number(.infinity)]))
    }

    @Test func underflowingNumberIsZero() throws {
        #expect(try json("[1e-400]") == .array([.number(0)]))
    }

    @Test func duplicateKeysKeepTheLastValue() throws {
        #expect(try json(#"{"a":1,"a":2}"#)["a"] == .number(2))
    }

    @Test func loneSurrogateEscapeBecomesTheReplacementCharacter() throws {
        #expect(try json(#"["\uD800"]"#) == .array([.string("\u{FFFD}")]))
    }

    // Precomposed and decomposed é: equal as Swift Strings, so one key, holding the later value.
    @Test func canonicallyEquivalentKeysMerge() throws {
        let o = try #require(try json(#"{"é":1,"é":2}"#).objectValue)
        #expect(o.count == 1)
        #expect(o.values.first == .number(2))
    }

    @Test func integersBeyond2To53RoundAsInJavaScript() throws {
        #expect(try json("9007199254740993") == .number(9007199254740992))
    }
}

// MARK: - The same cases end to end, through the client and the fake server's raw-body seam

private let sf = Region.bbox(minLon: -122.42, minLat: 37.77, maxLon: -122.41, maxLat: 37.78)
private let getTilesPath = "https://places.atgeo.org/xrpc/org.atgeo.getTiles"
private let getPlacePath = "https://places.atgeo.org/xrpc/org.atgeo.getPlace"
private let geoAt = #"{"$type":"community.lexicon.location.geo","latitude":"37.775","longitude":"-122.415"}"#

private func raw(_ status: Int, _ text: String) -> HTTPResponse { HTTPResponse(status: status, body: Data(text.utf8)) }

private func throwsDecodingError(_ body: () async throws -> Void) async -> Bool {
    do { try await body(); return false } catch is DecodingError { return true } catch { return false }
}

@Suite("contract §16 through the client") struct ToleranceThroughTheClient {
    @Test("a getTiles body with no tiles array fails the search and caches nothing",
          arguments: ["{}", "[]", #"{"tiles":"x"}"#, "null"])
    func noTileList(body: String) async throws {
        let server = try FakeServer(rawBodies: [getTilesPath: raw(200, body)])
        let client = server.client()
        #expect(await throwsDecodingError { _ = try await client.searchPlaces(region: sf) })
        #expect(await throwsDecodingError { _ = try await client.searchPlaces(region: sf) })
        #expect(server.getTilesRequests.count == 2)
    }

    @Test func nonStringTileEntriesAreSkippedNotCountedAsFailed() async throws {
        let tile = tileURL("a")
        let server = try FakeServer(
            tilesets: [overture([FakeTile(url: tile, records: [record(place("a", "A", [point(37.775, -122.415)]))])])],
            rawBodies: [getTilesPath: raw(200, #"{"tiles":[5,null,"\#(tile)",{"u":1}]}"#)])
        let result = try await server.client().searchPlaces(region: sf)
        #expect(result.tiles == .init(fetched: 1, failed: 0))
        #expect(result.places.count == 1)
    }

    @Test func nullLocationsAndVariantsAreSkipped() async throws {
        let value = place("a", "Munich", [.null, point(37.775, -122.415)], ["variants": .array([.null, .object(["name": .string("München")])])])
        let server = try FakeServer(tilesets: [overture([FakeTile(url: tileURL("a"), records: [record(value)])])])
        let result = try await server.client().searchPlaces(region: sf, text: "munchen")
        #expect(result.places.map(\.origin) == [placeOrigin("a")])
    }

    @Test func unusableRecordsAreSkippedTheTileKeptAndPlaceStillWorks() async throws {
        let tile = tileURL("a")
        let server = try FakeServer(rawBodies: [
            getTilesPath: raw(200, #"{"tiles":["\#(tile)"]}"#),
            tile: raw(200, #"""
            {"records":[1,"s",[],null,{"value":null,"uri":"urn:x:1"},{"value":5,"uri":"urn:x:2"},
                        {"value":{"locations":[\#(geoAt)]},"uri":"urn:x:2","importance":"9"},
                        {"value":{"locations":[\#(geoAt)]},"uri":7,"importance":[1]}]}
            """#),
        ])
        let client = server.client()
        let result = try await client.searchPlaces(region: sf, dataset: "overturemaps.org")
        #expect(result.tiles == .init(fetched: 1, failed: 0))
        #expect(result.places.map(\.origin) == ["urn:x:2", nil])
        #expect(result.places.map(\.importance) == [nil, nil])
        server.goOffline()
        #expect(try await client.place(origin: "urn:x:2").place["locations"] != nil)
    }

    @Test func aOneElementArrayCoordinateIsNoLocation() async throws {
        let tile = tileURL("a")
        let server = try FakeServer(rawBodies: [
            getTilesPath: raw(200, #"{"tiles":["\#(tile)"]}"#),
            tile: raw(200, #"{"records":[{"value":{"origin":"o","locations":[{"$type":"community.lexicon.location.geo","latitude":[37.775],"longitude":"-122.415"}]}}]}"#),
        ])
        #expect(try await server.client().searchPlaces(region: sf, dataset: "overturemaps.org").places.isEmpty)
    }

    // Under JSONDecoder, 1e400 anywhere in a tile failed the whole tile; now it is infinity, which the
    // importance range check makes absent (contract §1), as in the reference.
    @Test func aTileHoldingAnOverflowingNumberIsUsed() async throws {
        let tile = tileURL("a")
        let server = try FakeServer(rawBodies: [
            getTilesPath: raw(200, #"{"tiles":["\#(tile)"]}"#),
            tile: raw(200, #"{"records":[{"value":{"origin":"o","locations":[\#(geoAt)],"extra":1e400},"importance":1e400}]}"#),
        ])
        let result = try await server.client().searchPlaces(region: sf, dataset: "overturemaps.org")
        #expect(result.tiles == .init(fetched: 1, failed: 0))
        #expect(result.places.map(\.origin) == ["o"])
        #expect(result.places.first?.importance == nil)
        #expect(result.places.first?.place["extra"] == .number(.infinity))
    }

    @Test("error body fields that are not strings are absent", arguments: [
        (#"{"error":5,"message":["m"]}"#, "HttpError", "HTTP 400"),
        ("null", "HttpError", "HTTP 400"),
        (#"{"error":"BboxTooLarge","message":7}"#, "BboxTooLarge", "HTTP 400"),
    ])
    func errorBody(body: String, code: String, message: String) async throws {
        let server = try FakeServer(rawBodies: [getTilesPath: raw(400, body)])
        await #expect(throws: AtgeoError(code: code, message: message)) { _ = try await server.client().searchPlaces(region: sf) }
    }

    @Test("a getPlace body with no record object is a decoding error", arguments: ["null", "{}", #"{"uri":"u","record":null}"#, #"{"uri":"u","record":"x"}"#])
    func getPlaceWithoutRecord(body: String) async throws {
        let server = try FakeServer(rawBodies: [getPlacePath: raw(200, body)])
        #expect(await throwsDecodingError { _ = try await server.client().place(origin: "urn:x:1") })
    }

    @Test("a describe body that is not an object is a decoding error, and is not cached", arguments: ["null", "false", "0", #""""#, "[]"])
    func describeNotAnObject(body: String) async throws {
        let server = try FakeServer(rawBodies: [
            "https://places.atgeo.org/xrpc/org.atgeo.describeService": raw(200, body),
            "https://places.atgeo.org/xrpc/org.atgeo.describeTileset": raw(200, body),
        ])
        let client = server.client()
        #expect(await throwsDecodingError { _ = try await client.describeService() })
        #expect(await throwsDecodingError { _ = try await client.describeService() })
        #expect(await throwsDecodingError { _ = try await client.describeTileset("s") })
        #expect(server.requests.count == 3)
    }

    @Test func aTileThatIsNotJSONCountsAsFailed() async throws {
        let tile = tileURL("a")
        let server = try FakeServer(rawBodies: [getTilesPath: raw(200, #"{"tiles":["\#(tile)"]}"#), tile: raw(200, "<html>")])
        let result = try await server.client().searchPlaces(region: sf)
        #expect(result.tiles == .init(fetched: 0, failed: 1))
    }

    @Test func aGetTilesBodyThatIsNotJSONIsADecodingError() async throws {
        let server = try FakeServer(rawBodies: [getTilesPath: raw(200, "<html>")])
        #expect(await throwsDecodingError { _ = try await server.client().searchPlaces(region: sf) })
    }
}

// CONFORMANCE.md, "Tile URLs": a tile URL is fetched through URL(string:), whose answer for a character
// that is not allowed raw differs by Foundation. This pins the table's claim on every CI platform.
@Suite("tile URLs with characters not allowed raw") struct TileURLCharacters {
    @Test func aSpaceIsEncodedOrTheURLIsRejected() {
        let url = URL(string: "https://tiles.example/a b.json")
        #if os(Linux)
        #expect(url?.absoluteString == "https://tiles.example/a%20b.json")
        #else
        if #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) {
            #expect(url?.absoluteString == "https://tiles.example/a%20b.json")
        } else {
            #expect(url == nil)
        }
        #endif
    }
}

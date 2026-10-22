import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Atgeo

// A request-capturing HTTPTransport modelled on the reference's test/helpers/fakeServer.ts (spec §7). There
// is no Swift lexicon validator, so the fake validates its own configuration, every request and every
// response against the minimum contract §13 asks for (design review, note 15), from the vendored lexicons.

let defaultServer = "https://places.atgeo.org"
private let publishedAt = "2026-01-01T00:00:00Z"

struct FakeTile: Sendable {
    var url: String
    /// Wire records, so that the configuration tests can build invalid ones.
    var records: [JSONValue]

    init(url: String, records: [TileRecord]) {
        self.url = url
        self.records = records.map(wire)
    }

    init(url: String, raw: [JSONValue]) {
        self.url = url
        self.records = raw
    }
}

struct FakeTileset: Sendable {
    var slug: String?
    /// Each holds `dataset` and `collection`, and may hold the other collectionInfo fields.
    var collections: [JSONObject]
    var references: [JSONObject]?
    var tiles: [FakeTile]
}

func overture(_ tiles: [FakeTile]) -> FakeTileset {
    FakeTileset(
        slug: "overture-place",
        collections: [["dataset": .string("overturemaps.org"), "collection": .string("place")]],
        tiles: tiles)
}

/// A tile record as it goes on the wire.
func wire(_ r: TileRecord) -> JSONValue {
    var o: JSONObject = ["value": .object(r.value)]
    if let importance = r.importance { o["importance"] = .number(Double(importance)) }
    if let uri = r.uri { o["uri"] = .string(uri) }
    return .object(o)
}

/// What `tilesFor` answers once dataset and collection selection has passed.
enum TilesForAnswer: Sendable {
    case tiles([String])
    /// A whole getTiles body, validated like any other answer.
    case body(JSONObject)
    case error(code: String, message: String)
}

struct FakeServerConfigurationError: Error, CustomStringConvertible {
    var description: String
}

final class FakeServer: HTTPTransport, @unchecked Sendable {
    let server: String
    private let tilesets: [FakeTileset]
    private let tilesFor: (@Sendable (String) -> TilesForAnswer)?
    private let failTiles: Set<String>
    /// Served before any routing, keyed by full URL or by URL without its query; never validated.
    private let rawBodies: [String: HTTPResponse]

    private let lock = NSLock()
    private var captured: [URL] = []
    private var offline = false

    /// Every request URL, in order.
    var requests: [URL] { lock.withLock { captured } }
    var requestStrings: [String] { requests.map(\.absoluteString) }

    init(
        server: String = defaultServer,
        tilesets: [FakeTileset] = [overture([])],
        tilesFor: (@Sendable (String) -> TilesForAnswer)? = nil,
        failTiles: [String] = [],
        rawBodies: [String: HTTPResponse] = [:]
    ) throws {
        self.server = server
        self.tilesets = tilesets
        self.tilesFor = tilesFor
        self.failTiles = Set(failTiles)
        self.rawBodies = rawBodies
        for tileset in tilesets {
            try Self.validateDescriptor(Self.descriptor(tileset))
            for tile in tileset.tiles { try Self.validatePayload(Self.tileBody(tileset, tile.records)) }
        }
    }

    /// After this, every request fails as a network failure.
    func goOffline() { lock.withLock { offline = true } }

    func get(_ url: URL) async throws -> HTTPResponse {
        let isOffline = lock.withLock { () -> Bool in
            captured.append(url)
            return offline
        }
        if isOffline { throw URLError(.notConnectedToInternet) }
        return handle(url)
    }

    // MARK: Routing

    private func handle(_ url: URL) -> HTTPResponse {
        let href = url.absoluteString
        let withoutQuery = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        if let raw = rawBodies[href] ?? rawBodies[withoutQuery] { return raw }

        if href.hasPrefix("\(server)/xrpc/") {
            let nsid = url.lastPathComponent
            let params: [(String, String)]
            switch Self.formDecodedParams(url) {
            case .success(let p): params = p
            case .failure(let error): return xrpcError("InvalidRequest", error.message)
            }
            switch nsid {
            case "org.atgeo.getTiles":
                if let problem = Self.checkParams(params, required: ["dataset", "bbox"], optional: ["collection"]) {
                    return xrpcError("InvalidRequest", problem)
                }
                let p = Dictionary(params, uniquingKeysWith: { a, _ in a })
                if p["bbox"]!.wholeMatch(of: /-?\d+\.\d\d,-?\d+\.\d\d,-?\d+\.\d\d,-?\d+\.\d\d/) == nil {
                    return xrpcError("InvalidRequest", "bbox \(p["bbox"]!) is not a snapped box")
                }
                return getTiles(dataset: p["dataset"]!, collection: p["collection"], bbox: p["bbox"]!)
            case "org.atgeo.getPlace":
                if let problem = Self.checkParams(params, required: ["uri"], optional: []) { return xrpcError("InvalidRequest", problem) }
                let uri = params[0].1
                // format: uri. At minimum a scheme followed by a colon, and no whitespace.
                if uri.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\S+/) == nil {
                    return xrpcError("InvalidRequest", "uri must be a URI")
                }
                return getPlace(uri)
            case "org.atgeo.describeService":
                if let problem = Self.checkParams(params, required: [], optional: []) { return xrpcError("InvalidRequest", problem) }
                return answer(describeService())
            case "org.atgeo.describeTileset":
                if let problem = Self.checkParams(params, required: ["slug"], optional: []) { return xrpcError("InvalidRequest", problem) }
                let slug = params[0].1
                guard let tileset = tilesets.first(where: { $0.slug.map { ordinalEqual($0, slug) } ?? false }) else {
                    return xrpcError("TilesetNotFound", "Tileset \(slug) not found")
                }
                return answer(Self.descriptor(tileset))
            default:
                return xrpcError("MethodNotImplemented", "Method \(nsid) not implemented", status: 501)
            }
        }

        for tileset in tilesets {
            if let tile = tileset.tiles.first(where: { ordinalEqual($0.url, href) }) {
                if failTiles.contains(tile.url) { return HTTPResponse(status: 500, body: Data("upstream error".utf8)) }
                return json(Self.tileBody(tileset, tile.records))
            }
        }
        return HTTPResponse(status: 404, body: Data("Not found".utf8))
    }

    private func getTiles(dataset: String, collection: String?, bbox: String) -> HTTPResponse {
        func carries(_ t: FakeTileset, _ matches: (JSONObject) -> Bool) -> Bool { t.collections.contains(where: matches) }
        let withDataset = tilesets.filter { carries($0) { $0["dataset"]?.stringValue == dataset } }
        if withDataset.isEmpty { return xrpcError("DatasetNotFound", "Dataset \(dataset) not found") }
        let selected = withDataset.filter {
            carries($0) { c in c["dataset"]?.stringValue == dataset && (collection == nil || c["collection"]?.stringValue == collection) }
        }
        if selected.isEmpty { return xrpcError("CollectionNotFound", "Collection \(collection ?? "") not found") }
        let urls = selected.flatMap { $0.tiles.map(\.url) }.sorted(by: ordinalLess)
        switch tilesFor?(bbox) ?? .tiles(urls) {
        case .tiles(let tiles): return answer(["tiles": .array(tiles.map(JSONValue.string))])
        case .body(let body): return answer(body)
        case .error(let code, let message): return xrpcError(code, message)
        }
    }

    private func getPlace(_ origin: String) -> HTTPResponse {
        let parts = origin.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return xrpcError("PlaceNotFound", "Place \(origin) not found") }
        let (dataset, collection, rest) = (parts[2], parts[3], parts.dropFirst(4).joined(separator: ":"))
        for tileset in tilesets {
            guard tileset.collections.contains(where: { $0["dataset"]?.stringValue == dataset && $0["collection"]?.stringValue == collection }) else { continue }
            for tile in tileset.tiles {
                if let found = tile.records.first(where: { $0["value"]?["origin"]?.stringValue.map { ordinalEqual($0, origin) } ?? false }) {
                    var body: JSONObject = ["uri": .string("\(server)/\(dataset)/\(collection)/\(rest)"), "record": found["value"]!]
                    if let importance = found["importance"] { body["importance"] = importance }
                    return answer(body)
                }
            }
        }
        return xrpcError("PlaceNotFound", "Place \(origin) not found")
    }

    private func describeService() -> JSONObject {
        let host = URL(string: server)?.host ?? ""
        return [
            "did": .string("did:web:\(host)"),
            "tilesets": .array(tilesets.map { t in
                .object([
                    "slug": t.slug.map(JSONValue.string) ?? .null,
                    "collections": .array(t.collections.map { .object(["dataset": $0["dataset"] ?? .null, "collection": $0["collection"] ?? .null]) }),
                ])
            }),
        ]
    }

    // MARK: Bodies

    private static func descriptor(_ t: FakeTileset) -> JSONObject {
        var d: JSONObject = ["collections": .array(t.collections.map(JSONValue.object))]
        if let slug = t.slug { d["slug"] = .string(slug) }
        if let references = t.references { d["references"] = .array(references.map(JSONValue.object)) }
        return d
    }

    private static func tileBody(_ t: FakeTileset, _ records: [JSONValue]) -> JSONObject {
        let attributionKeys = ["dataset", "collection", "release", "source", "licenses", "attribution"]
        let attribution = t.collections.map { c in JSONValue.object(c.filter { attributionKeys.contains($0.key) }) }
            + (t.references ?? []).map(JSONValue.object)
        return ["publishedAt": .string(publishedAt), "attribution": .array(attribution), "records": .array(records)]
    }

    /// Validates a response the fake builds itself; an invalid one is a bug in the test, so it fails the test.
    private func answer(_ body: JSONObject) -> HTTPResponse {
        if let problem = Self.problemWithResponse(body) { Issue.record("fake server built an invalid response: \(problem)") }
        return json(body)
    }

    private func json(_ body: JSONObject, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONEncoder().encode(JSONValue.object(body)))
    }

    private func xrpcError(_ code: String, _ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": .string(code), "message": .string(message)], status: status)
    }

    // MARK: Validation

    /// Query parameters as a form-decoding server reads them: `+` is a space. So a client that left `+` raw
    /// would be caught here, as design review finding 2 describes.
    private static func formDecodedParams(_ url: URL) -> Result<[(String, String)], ParamError> {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else { return .success([]) }
        var out: [(String, String)] = []
        for item in items {
            func decode(_ s: String) -> String? { s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
            guard let name = decode(item.name), let value = decode(item.value ?? "") else {
                return .failure(ParamError(message: "malformed percent-encoding"))
            }
            out.append((name, value))
        }
        return .success(out)
    }

    struct ParamError: Error { var message: String }

    private static func checkParams(_ params: [(String, String)], required: Set<String>, optional: Set<String>) -> String? {
        let names = params.map(\.0)
        if Set(names).count != names.count { return "repeated parameter in \(names)" }
        if let unknown = names.first(where: { !required.contains($0) && !optional.contains($0) }) { return "unknown parameter \(unknown)" }
        if let missing = required.subtracting(names).sorted().first { return "missing required parameter \(missing)" }
        return nil
    }

    private static func isInteger(_ v: JSONValue) -> Bool {
        guard case .number(let d) = v else { return false }
        return d.isFinite && d.rounded(.towardZero) == d
    }

    private static func validateDescriptor(_ d: JSONObject) throws {
        guard d["slug"]?.stringValue != nil else { throw FakeServerConfigurationError(description: #"descriptor must have property "slug""#) }
        guard let collections = d["collections"]?.arrayValue else {
            throw FakeServerConfigurationError(description: #"descriptor must have property "collections""#)
        }
        for c in collections where c["dataset"]?.stringValue == nil || c["collection"]?.stringValue == nil {
            throw FakeServerConfigurationError(description: "collection \(c) must have a string dataset and collection")
        }
    }

    private static func validatePayload(_ body: JSONObject) throws {
        guard let records = body["records"]?.arrayValue else { throw FakeServerConfigurationError(description: #"payload must have property "records""#) }
        for (i, r) in records.enumerated() {
            guard r.objectValue != nil else { throw FakeServerConfigurationError(description: "records/\(i) must be an object") }
            guard let value = r["value"] else { throw FakeServerConfigurationError(description: #"records/\#(i) must have property "value""#) }
            if let importance = r["importance"], !isInteger(importance) {
                throw FakeServerConfigurationError(description: "records/\(i)/importance must be an integer")
            }
            if let uri = r["uri"], uri.stringValue == nil { throw FakeServerConfigurationError(description: "records/\(i)/uri must be a string") }
            // org.atgeo.place: an object with a string name.
            guard value.objectValue != nil else { throw FakeServerConfigurationError(description: "records/\(i)/value must be an object") }
            guard value["name"]?.stringValue != nil else {
                throw FakeServerConfigurationError(description: #"records/\#(i)/value must have property "name""#)
            }
        }
    }

    /// The required response fields of note 15, by which body is being sent.
    private static func problemWithResponse(_ body: JSONObject) -> String? {
        if let tiles = body["tiles"] {
            guard let list = tiles.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else { return "tiles must be an array of strings" }
            if let overview = body["overview"], overview.boolValue == nil { return "overview must be a boolean" }
            return nil
        }
        if body["record"] != nil {
            return body["uri"]?.stringValue == nil ? "getPlace needs a uri" : nil
        }
        if body["did"] != nil || body["tilesets"] != nil {
            return body["did"]?.stringValue == nil || body["tilesets"]?.arrayValue == nil ? "describeService needs did and tilesets" : nil
        }
        if body["slug"] != nil || body["collections"] != nil {
            return (try? validateDescriptor(body)) == nil ? "invalid tileset descriptor" : nil
        }
        return "unrecognised response \(body.keys.sorted())"
    }
}

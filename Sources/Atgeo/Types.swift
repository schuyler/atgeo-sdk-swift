import Foundation

// Public result and describe types (spec §3), and the lenient mappers that read every response body from
// `JSONValue`. Nothing here decodes a response with a synthesized `Decodable` (design review, addendum B):
// the synthesized `Codable` conformances are strict and exist for apps that persist what they fetched.

public enum SortMode: String, Sendable, CaseIterable, Codable { case fused, distance, similarity }

// Every public type has a public memberwise initializer, which Swift does not synthesize for code outside the
// module, so an app can build results for its own tests and previews. The client never uses them on a response.

public struct SearchResult: Sendable, Equatable, Codable {
    public var places: [SearchHit]
    /// `tiles.failed == 0`.
    public var complete: Bool
    public var overview: Bool
    public var tiles: TileCounts
    /// Each tile that failed, in tile URL order (contract §4.4); `tiles.failed` is its count.
    public var tileFailures: [TileFailure]
    /// The credit for every collection whose data the search's tiles hold (contract §4.10).
    public var attribution: [Attribution]
    public struct TileCounts: Sendable, Equatable, Codable {
        public var fetched: Int
        public var failed: Int
        public init(fetched: Int, failed: Int) { self.fetched = fetched; self.failed = failed }
    }

    public init(places: [SearchHit], complete: Bool, overview: Bool, tiles: TileCounts, tileFailures: [TileFailure] = [], attribution: [Attribution] = []) {
        self.places = places
        self.complete = complete
        self.overview = overview
        self.tiles = tiles
        self.tileFailures = tileFailures
        self.attribution = attribution
    }

    private enum CodingKeys: String, CodingKey { case places, complete, overview, tiles, tileFailures, attribution }

    /// Written by hand so that a result encoded before `tileFailures` existed still decodes, with none.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = try c.decode([SearchHit].self, forKey: .places)
        complete = try c.decode(Bool.self, forKey: .complete)
        overview = try c.decode(Bool.self, forKey: .overview)
        tiles = try c.decode(TileCounts.self, forKey: .tiles)
        tileFailures = try c.decodeIfPresent([TileFailure].self, forKey: .tileFailures) ?? []
        attribution = try c.decodeIfPresent([Attribution].self, forKey: .attribution) ?? []
    }
}

/// A tile that failed in a search (contract §4.4). `url`, `kind` and `status` are the same in every atgeo SDK;
/// `error` is this port's own and is left out of `==` and of coding.
public struct TileFailure: Sendable, Equatable, Codable {
    /// Where the failure arose.
    public enum Kind: String, Sendable, Codable {
        /// The URL is not an absolute `http` or `https` URL, or carries credentials; no request was made.
        case refused
        /// The server answered non-2xx.
        case status
        /// The server answered 2xx with a body that is not a usable tile payload.
        case decode
        /// The transport threw: a network error, a timeout, a body over its cap, or anything an app's
        /// transport throws.
        case transport
    }

    /// The tile URL as the tile list gave it.
    public var url: String
    public var kind: Kind
    /// The HTTP status for `.status`, else nil.
    public var status: Int?
    /// What failed: `URLError(.unsupportedURL)` for `.refused`, the `AtgeoError` for `.status`, the parse error
    /// for `.decode`, and the transport's own error for `.transport`. The client always sets it; it is nil only
    /// in a failure decoded from JSON, since an error does not encode, or one built with nil.
    public var error: (any Error)?

    public init(url: String, kind: Kind, status: Int? = nil, error: (any Error)?) {
        self.url = url
        self.kind = kind
        self.status = status
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case url, kind, status }

    /// Compares `url` (by UTF-16 code units, as the contract compares strings), `kind` and `status`; not `error`.
    public static func == (a: TileFailure, b: TileFailure) -> Bool {
        ordinalEqual(a.url, b.url) && a.kind == b.kind && a.status == b.status
    }
}

/// Where a place is, as its first usable geo point and first usable bbox (contract §5), in the lexicon's field
/// names. Either or both may be nil.
public struct PlaceLocation: Sendable, Equatable, Codable {
    public var point: Point?
    public var bbox: Box?

    /// A point in degrees.
    public struct Point: Sendable, Equatable, Codable {
        public var lat: Double
        public var lon: Double
        public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    }

    /// A box in degrees, as the lexicon names its sides, kept as read: `west > east` crosses the antimeridian.
    public struct Box: Sendable, Equatable, Codable {
        public var south: Double
        public var west: Double
        public var north: Double
        public var east: Double
        public init(south: Double, west: Double, north: Double, east: Double) {
            self.south = south; self.west = west; self.north = north; self.east = east
        }
    }

    public init(point: Point? = nil, bbox: Box? = nil) { self.point = point; self.bbox = bbox }
}

public struct SearchHit: Sendable, Equatable, Codable {
    public var origin: String?
    public var place: JSONObject
    public var importance: Int64?
    public var distance: Double      // metres
    public var score: Double?        // 0...1, nil without text
    /// The collection the hit belongs to, matched against its tile's attribution (contract §8); nil when none matches.
    public var collection: CollectionKey?

    public init(origin: String?, place: JSONObject, importance: Int64?, distance: Double, score: Double?, collection: CollectionKey? = nil) {
        self.origin = origin
        self.place = place
        self.importance = importance
        self.distance = distance
        self.score = score
        self.collection = collection
    }

    /// The place's `name` when it is a string, else nil (contract §8).
    public var name: String? { place["name"]?.stringValue }

    /// Where the place is (contract §8): the first usable point and the first usable box of `place`.
    public var location: PlaceLocation { placeLocation(place) }
}

public struct PlaceRecord: Sendable, Equatable, Codable {
    public var origin: String
    public var place: JSONObject
    public var importance: Int64?
    /// The collections the place's data comes from, as served and in served order (contract §9); empty when none.
    public var attribution: [Attribution]

    public init(origin: String, place: JSONObject, importance: Int64?, attribution: [Attribution] = []) {
        self.origin = origin
        self.place = place
        self.importance = importance
        self.attribution = attribution
    }

    /// The place's `name` when it is a string, else nil (contract §8).
    public var name: String? { place["name"]?.stringValue }

    /// Where the place is (contract §8): the first usable point and the first usable box of `place`.
    public var location: PlaceLocation { placeLocation(place) }

    private enum CodingKeys: String, CodingKey { case origin, place, importance, attribution }

    /// Written by hand so that a record encoded before `attribution` existed still decodes, with none.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(String.self, forKey: .origin)
        place = try c.decode(JSONObject.self, forKey: .place)
        importance = try c.decodeIfPresent(Int64.self, forKey: .importance)
        attribution = try c.decodeIfPresent([Attribution].self, forKey: .attribution) ?? []
    }
}

/// The dataset and collection a hit belongs to (contract §8).
public struct CollectionKey: Sendable, Hashable, Codable {
    public var dataset: String
    public var collection: String
    public init(dataset: String, collection: String) { self.dataset = dataset; self.collection = collection }
}

/// A credit for one collection (`org.atgeo.defs#collectionAttribution`), read leniently (contract §1).
public struct Attribution: Sendable, Hashable, Codable {
    public var dataset: String
    public var collection: String
    public var release: String?, source: String?, licenses: [String]?, attribution: String?
    public init(
        dataset: String, collection: String,
        release: String? = nil, source: String? = nil, licenses: [String]? = nil, attribution: String? = nil
    ) {
        self.dataset = dataset
        self.collection = collection
        self.release = release
        self.source = source
        self.licenses = licenses
        self.attribution = attribution
    }
}

public struct CollectionRef: Sendable, Equatable, Codable {
    public var dataset: String?
    public var collection: String?
    public init(dataset: String?, collection: String?) { self.dataset = dataset; self.collection = collection }
}

public struct ServiceDescription: Sendable, Equatable, Codable {
    public var did: String?
    /// The server's tile budget; informational (contract §9).
    public var maxTiles: Int64?
    public var tilesets: [ServedTileset]        // empty when missing
    public struct ServedTileset: Sendable, Equatable, Codable {
        public var slug: String?
        public var collections: [CollectionRef]
        public init(slug: String?, collections: [CollectionRef]) { self.slug = slug; self.collections = collections }
    }

    public init(did: String?, tilesets: [ServedTileset], maxTiles: Int64? = nil) {
        self.did = did
        self.tilesets = tilesets
        self.maxTiles = maxTiles
    }
}

public struct CollectionAttribution: Sendable, Equatable, Codable {
    public var dataset: String?, collection: String?
    public var release: String?, source: String?, licenses: [String]?, attribution: String?

    public init(
        dataset: String?, collection: String?,
        release: String? = nil, source: String? = nil, licenses: [String]? = nil, attribution: String? = nil
    ) {
        self.dataset = dataset
        self.collection = collection
        self.release = release
        self.source = source
        self.licenses = licenses
        self.attribution = attribution
    }
}

public struct CollectionInfo: Sendable, Equatable, Codable {
    public var dataset: String?, collection: String?
    public var release: String?, source: String?, licenses: [String]?, attribution: String?
    public var recordCount: Int64?, locationFormats: [String]?, containmentTypes: [String]?
    public var categories: [CategoryCount]?, attributes: [String]?
    public struct CategoryCount: Sendable, Equatable, Codable {
        public var value: String?
        public var count: Int64?
        public init(value: String?, count: Int64?) { self.value = value; self.count = count }
    }

    public init(
        dataset: String?, collection: String?,
        release: String? = nil, source: String? = nil, licenses: [String]? = nil, attribution: String? = nil,
        recordCount: Int64? = nil, locationFormats: [String]? = nil, containmentTypes: [String]? = nil,
        categories: [CategoryCount]? = nil, attributes: [String]? = nil
    ) {
        self.dataset = dataset
        self.collection = collection
        self.release = release
        self.source = source
        self.licenses = licenses
        self.attribution = attribution
        self.recordCount = recordCount
        self.locationFormats = locationFormats
        self.containmentTypes = containmentTypes
        self.categories = categories
        self.attributes = attributes
    }
}

public struct Tileset: Sendable, Equatable, Codable {
    public var slug: String?
    public var publishedAt: String?
    public var extent: Extent?
    public var collections: [CollectionInfo]    // empty when missing
    public var references: [CollectionAttribution]?
    /// The tileset's overview band, when it has one (contract §9).
    public var overview: Overview?
    public struct Overview: Sendable, Equatable, Codable {
        public var records: Int64?
        public init(records: Int64?) { self.records = records }
    }
    public struct Extent: Sendable, Equatable, Codable {
        public var north: String?, south: String?, east: String?, west: String?
        public init(north: String?, south: String?, east: String?, west: String?) {
            self.north = north
            self.south = south
            self.east = east
            self.west = west
        }
    }

    public init(
        slug: String?, publishedAt: String? = nil, extent: Extent? = nil,
        collections: [CollectionInfo], references: [CollectionAttribution]? = nil, overview: Overview? = nil
    ) {
        self.slug = slug
        self.publishedAt = publishedAt
        self.extent = extent
        self.collections = collections
        self.references = references
        self.overview = overview
    }
}

/// A usable record from a tile payload (contract §4.4): `value` is an object; `uri` and `importance` are
/// absent unless they are a string and an in-range number (contract §1).
struct TileRecord: Sendable, Equatable {
    var value: JSONObject
    var uri: String?
    var importance: Int64?
}

/// A tile payload as the lenient reader keeps it (contract §1): the usable records, and the `attribution`
/// when the payload has an array there.
struct TilePayload: Sendable, Equatable {
    var records: [TileRecord]
    var attribution: [Attribution]?
}

// MARK: - Lenient readers

/// A JSON number in the signed 64-bit range, truncated toward zero. The guard is symmetric, so -2^63 is
/// absent too (contract §1); `Int64(d)` traps out of range and `Int64(exactly:)` rejects a fraction.
func int64(_ v: JSONValue?) -> Int64? {
    guard case .number(let d)? = v, d.isFinite, d.magnitude < 9223372036854775808 else { return nil }
    return Int64(d)
}

/// JavaScript truthiness of a JSON value: false when absent, null, false, 0, -0 or "" (contract §1).
func truthy(_ v: JSONValue?) -> Bool {
    switch v {
    case nil, .null?: return false
    case .bool(let b)?: return b
    case .number(let d)?: return d != 0
    case .string(let s)?: return !s.isEmpty
    case .array?, .object?: return true
    }
}

/// An optional list of strings: nil unless an array; elements that are not strings are dropped.
private func strings(_ v: JSONValue?) -> [String]? {
    v?.arrayValue?.compactMap(\.stringValue)
}

/// A list of objects mapped by `read`: elements that are not objects are dropped. Nil unless an array.
private func objects<T>(_ v: JSONValue?, _ read: (JSONValue) -> T) -> [T]? {
    v?.arrayValue?.filter { $0.objectValue != nil }.map(read)
}

// MARK: - Response mappers

/// A tile payload's usable records. A payload that is not an object, or has no `records` array, throws
/// and the tile counts as failed; an unusable record is skipped and never fails the tile (contract §4.4).
func tileRecords(_ payload: JSONValue) throws -> [TileRecord] {
    guard let records = payload["records"]?.arrayValue else { throw noUsableBody("tile payload has no records array") }
    return records.compactMap { r in
        guard let value = r["value"]?.objectValue else { return nil }
        return TileRecord(value: value, uri: r["uri"]?.stringValue, importance: int64(r["importance"]))
    }
}

/// A tile payload: `tileRecords` and the attribution (contract §1).
func tilePayload(_ payload: JSONValue) throws -> TilePayload {
    TilePayload(records: try tileRecords(payload), attribution: payload["attribution"]?.arrayValue.map(attributionEntries))
}

/// The entries of an `attribution` list: an element is kept only if it is an object whose `dataset` and `collection`
/// are both strings. `release`, `source` and `attribution` are strings or absent, `licenses` the string elements of an
/// array or absent; each field is read on its own, other fields are ignored, and served order and duplicates stay
/// (contract §1).
func attributionEntries(_ list: [JSONValue]) -> [Attribution] {
    list.compactMap { v in
        guard let dataset = v["dataset"]?.stringValue, let collection = v["collection"]?.stringValue else { return nil }
        return Attribution(
            dataset: dataset, collection: collection,
            release: v["release"]?.stringValue, source: v["source"]?.stringValue,
            licenses: strings(v["licenses"]), attribution: v["attribution"]?.stringValue)
    }
}

/// A getTiles body: the string entries of `tiles`, and `overview` by JavaScript truthiness. No `tiles`
/// array is no usable tile list (contract §1, §16).
func tileList(_ body: JSONValue) throws -> (tiles: [String], overview: Bool) {
    guard let tiles = body["tiles"]?.arrayValue else { throw noUsableBody("getTiles response has no tiles array") }
    return (tiles.compactMap(\.stringValue), truthy(body["overview"]))
}

/// A getPlace body. The caller's `origin` is returned, not the response's `uri` (contract §9).
func placeRecord(_ body: JSONValue, origin: String) throws -> PlaceRecord {
    guard let value = body["value"]?.objectValue else { throw noUsableBody("getPlace response has no value object") }
    return PlaceRecord(
        origin: origin, place: value, importance: int64(body["importance"]),
        attribution: body["attribution"]?.arrayValue.map(attributionEntries) ?? [])
}

private func collectionRef(_ v: JSONValue) -> CollectionRef {
    CollectionRef(dataset: v["dataset"]?.stringValue, collection: v["collection"]?.stringValue)
}

func serviceDescription(_ body: JSONValue) throws -> ServiceDescription {
    guard body.objectValue != nil else { throw noUsableBody("describeService response is not an object") }
    let tilesets = objects(body["tilesets"]) { t in
        ServiceDescription.ServedTileset(
            slug: t["slug"]?.stringValue,
            collections: objects(t["collections"], collectionRef) ?? [])
    }
    return ServiceDescription(did: body["did"]?.stringValue, tilesets: tilesets ?? [], maxTiles: int64(body["maxTiles"]))
}

private func collectionAttribution(_ v: JSONValue) -> CollectionAttribution {
    CollectionAttribution(
        dataset: v["dataset"]?.stringValue, collection: v["collection"]?.stringValue,
        release: v["release"]?.stringValue, source: v["source"]?.stringValue,
        licenses: strings(v["licenses"]), attribution: v["attribution"]?.stringValue)
}

private func collectionInfo(_ v: JSONValue) -> CollectionInfo {
    CollectionInfo(
        dataset: v["dataset"]?.stringValue, collection: v["collection"]?.stringValue,
        release: v["release"]?.stringValue, source: v["source"]?.stringValue,
        licenses: strings(v["licenses"]), attribution: v["attribution"]?.stringValue,
        recordCount: int64(v["recordCount"]),
        locationFormats: strings(v["locationFormats"]), containmentTypes: strings(v["containmentTypes"]),
        categories: objects(v["categories"]) { c in
            CollectionInfo.CategoryCount(value: c["value"]?.stringValue, count: int64(c["count"]))
        },
        attributes: strings(v["attributes"]))
}

func tileset(_ body: JSONValue) throws -> Tileset {
    guard body.objectValue != nil else { throw noUsableBody("describeTileset response is not an object") }
    let extent = body["extent"].flatMap { e -> Tileset.Extent? in
        guard e.objectValue != nil else { return nil }
        return Tileset.Extent(
            north: e["north"]?.stringValue, south: e["south"]?.stringValue,
            east: e["east"]?.stringValue, west: e["west"]?.stringValue)
    }
    return Tileset(
        slug: body["slug"]?.stringValue,
        publishedAt: body["publishedAt"]?.stringValue,
        extent: extent,
        collections: objects(body["collections"], collectionInfo) ?? [],
        references: objects(body["references"], collectionAttribution),
        overview: body["overview"].flatMap { o in
            o.objectValue == nil ? nil : Tileset.Overview(records: int64(o["records"]))
        })
}

/// The `AtgeoError` for a non-2xx response: `error` and `message` are each used when the body is a JSON
/// object holding a string there, and judged on their own (contract §1, §16).
func atgeoError(status: Int, body: Data) -> AtgeoError {
    let json = try? decodeJSON(body)
    return AtgeoError(
        code: json?["error"]?.stringValue ?? "HttpError",
        message: json?["message"]?.stringValue ?? "HTTP \(status)",
        status: status)
}

import Foundation

// Public result and describe types (spec §3), and the lenient mappers that read every response body from
// `JSONValue`. Nothing here decodes a response with a synthesized `Decodable` (design review, addendum B):
// the synthesized `Codable` conformances are strict and exist for apps that persist what they fetched.

public enum SortMode: String, Sendable, CaseIterable, Codable { case fused, distance, similarity }

// Every public type has a public memberwise initializer, which Swift does not synthesize for code outside the
// module, so an app can build results for its own tests and previews. The client never uses them on a response.

public struct SearchResult: Sendable, Equatable, Codable {
    public var places: [SearchHit]
    public var complete: Bool
    public var overview: Bool
    public var tiles: TileCounts
    public struct TileCounts: Sendable, Equatable, Codable {
        public var fetched: Int
        public var failed: Int
        public init(fetched: Int, failed: Int) { self.fetched = fetched; self.failed = failed }
    }

    public init(places: [SearchHit], complete: Bool, overview: Bool, tiles: TileCounts) {
        self.places = places
        self.complete = complete
        self.overview = overview
        self.tiles = tiles
    }
}

public struct SearchHit: Sendable, Equatable, Codable {
    public var origin: String?
    public var place: JSONObject
    public var importance: Int64?
    public var distance: Double      // metres
    public var score: Double?        // 0...1, nil without text

    public init(origin: String?, place: JSONObject, importance: Int64?, distance: Double, score: Double?) {
        self.origin = origin
        self.place = place
        self.importance = importance
        self.distance = distance
        self.score = score
    }
}

public struct PlaceRecord: Sendable, Equatable, Codable {
    public var origin: String
    public var place: JSONObject
    public var importance: Int64?

    public init(origin: String, place: JSONObject, importance: Int64?) {
        self.origin = origin
        self.place = place
        self.importance = importance
    }
}

public struct CollectionRef: Sendable, Equatable, Codable {
    public var dataset: String?
    public var collection: String?
    public init(dataset: String?, collection: String?) { self.dataset = dataset; self.collection = collection }
}

public struct ServiceDescription: Sendable, Equatable, Codable {
    public var did: String?
    public var tilesets: [ServedTileset]        // empty when missing
    public struct ServedTileset: Sendable, Equatable, Codable {
        public var slug: String?
        public var collections: [CollectionRef]
        public init(slug: String?, collections: [CollectionRef]) { self.slug = slug; self.collections = collections }
    }

    public init(did: String?, tilesets: [ServedTileset]) { self.did = did; self.tilesets = tilesets }
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
        collections: [CollectionInfo], references: [CollectionAttribution]? = nil
    ) {
        self.slug = slug
        self.publishedAt = publishedAt
        self.extent = extent
        self.collections = collections
        self.references = references
    }
}

/// A usable record from a tile payload (contract §4.4): `value` is an object; `uri` and `importance` are
/// absent unless they are a string and an in-range number (contract §1, §16).
struct TileRecord: Sendable, Equatable {
    var value: JSONObject
    var uri: String?
    var importance: Int64?
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

/// A getTiles body: the string entries of `tiles`, and `overview` by JavaScript truthiness. No `tiles`
/// array is no usable tile list (contract §1, §16).
func tileList(_ body: JSONValue) throws -> (tiles: [String], overview: Bool) {
    guard let tiles = body["tiles"]?.arrayValue else { throw noUsableBody("getTiles response has no tiles array") }
    return (tiles.compactMap(\.stringValue), truthy(body["overview"]))
}

/// A getPlace body. The caller's `origin` is returned, not the response's `uri` (contract §9).
func placeRecord(_ body: JSONValue, origin: String) throws -> PlaceRecord {
    guard let record = body["record"]?.objectValue else { throw noUsableBody("getPlace response has no record object") }
    return PlaceRecord(origin: origin, place: record, importance: int64(body["importance"]))
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
    return ServiceDescription(did: body["did"]?.stringValue, tilesets: tilesets ?? [])
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
        references: objects(body["references"], collectionAttribution))
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

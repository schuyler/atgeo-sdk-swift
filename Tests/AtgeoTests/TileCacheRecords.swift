import Foundation
@testable import Atgeo

/// The record-level calls CacheTests was written against, before the cache held bodies: `set` stores the
/// records as a tile body with a size of the test's choosing, and `get` and `find` parse it again, as the
/// client does for a tile that is not memoized. Eviction, recency and the lookup are the cache's own.
extension TileCache {
    mutating func set(_ url: String, records: [TileRecord], size: Int) {
        let body = try! JSONEncoder().encode(JSONValue.object(["records": .array(records.map(wire))]))
        insert(url, body: body, keys: try! parseTile(body).keys, size: size, attribution: [])
    }

    mutating func get(_ url: String) -> [TileRecord]? {
        read(url).map { try! parseTile($0.body).records.map(\.record) }
    }

    func find(key: String) -> TileRecord? {
        lookup(key: key).lazy.compactMap { firstRecord(try! parseTile($0.body).records, key: key) }.first
    }
}

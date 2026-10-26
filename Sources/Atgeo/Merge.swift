import Foundation

// Dedupe and the collection filter, contract §4.6 and §4.7.

/// `value.origin` if a string, else the record's `uri`, else none.
func recordKey(_ r: TileRecord) -> String? {
    r.value["origin"]?.stringValue ?? r.uri
}

/// Keeps the first copy of each key, in the order given; records without a key all pass. Keys are
/// compared by UTF-16 code units, so origins differing only in normalization form stay distinct.
func dedupe(_ records: [TileRecord]) -> [TileRecord] {
    dedupe(records.map(PreparedRecord.init)).map(\.record)
}

func dedupe(_ records: [PreparedRecord]) -> [PreparedRecord] {
    var seen = Set<[UInt16]>()
    return records.filter { p in
        guard let key = recordKey(p.record) else { return true }
        return seen.insert(Array(key.utf16)).inserted
    }
}

/// Keeps records whose `value.origin` is a string starting with `urn:atgeo:{dataset}:{collection}:`,
/// by code units. `String.hasPrefix` compares grapheme clusters, which a combining mark after the final
/// colon would change.
func inCollection(_ r: TileRecord, dataset: String, collection: String) -> Bool {
    guard let origin = r.value["origin"]?.stringValue else { return false }
    return origin.utf16.starts(with: "urn:atgeo:\(dataset):\(collection):".utf16)
}

/// The collection a hit belongs to (contract §8): the first entry, in served order, of the tile's attribution whose
/// `urn:atgeo:{dataset}:{collection}:` prefixes `value.origin`, by code units. Only `value.origin` counts, never
/// the `uri` fallback, and the origin is never split. A fresh key holding just the two names; nil when none matches.
func hitCollection(_ r: TileRecord, attribution: [Attribution]) -> CollectionKey? {
    guard let origin = r.value["origin"]?.stringValue else { return nil }
    let units = origin.utf16
    for entry in attribution where units.starts(with: "urn:atgeo:\(entry.dataset):\(entry.collection):".utf16) {
        return CollectionKey(dataset: entry.dataset, collection: entry.collection)
    }
    return nil
}

/// Contract §4.6 to §4.9 over the concatenated records of the used tiles, in URL order. `query` is
/// already normalized; "" means no text. `collection` is the resolved collection, nil for a whole dataset.
func assemble(
    records: [TileRecord], region: Region, query: String, sort: SortMode, dataset: String, collection: String?,
    overview: Bool = false
) -> [SearchHit] {
    assemble(records.map(PreparedRecord.init), region: region, query: query, sort: sort, dataset: dataset, collection: collection,
             overview: overview)
}

func assemble(
    _ records: [PreparedRecord], region: Region, query: String, sort: SortMode, dataset: String, collection: String?,
    overview: Bool = false
) -> [SearchHit] {
    let kept = dedupe(records)
        .filter { p in collection.map { inCollection(p.record, dataset: dataset, collection: $0) } ?? true }
        .filter { inRegion(locate($0.record.value), region) }
    return rank(kept, region: region, query: query, sort: sort, overview: overview)
}

import Foundation

// The tile cache and the one-hour caches, contract §10. In memory only; nothing is persisted.

/// A tile record with the work every search would repeat on it done once: its names normalized (contract §7).
struct PreparedRecord: Sendable, Equatable {
    var record: TileRecord
    var names: [[UInt16]]

    init(_ record: TileRecord) {
        self.record = record
        names = normalizedNames(record.value)
    }
}

/// A tile body to the records a search reads, and the hashes of their keys (contract §4.6).
///
/// The cache indexes a tile by key hashes, not by the keys: a tile's keys, held as strings, are thousands of
/// small allocations made among its parse tree's, and once the tree is freed they pin its pages; measured on
/// Linux, they made the cache 1.75 times its bodies' size rather than 1.1. A hash is only a candidate, which
/// `TileCache.lookup(key:)`'s caller confirms by parsing the tile.
func parseTile(_ body: Data) throws -> (records: [PreparedRecord], keys: Set<Int>) {
    let records = try tileRecords(decodeJSON(body))
    return (records.map(PreparedRecord.init), Set(records.compactMap { recordKey($0).map { OrdinalKey($0).hashValue } }))
}

/// The first of `records` whose key (contract §4.6) is `key`, by UTF-16 code units.
func firstRecord(_ records: [PreparedRecord], key: String) -> TileRecord? {
    records.first { recordKey($0.record).map { ordinalEqual($0, key) } ?? false }?.record
}

/// Parses a cached body. A global async function runs off the caller's actor (SE-0338), so the client's actor
/// is not held for the parse.
func parseCachedTile(_ body: Data) async throws -> [PreparedRecord] {
    try parseTile(body).records
}

/// Tiles by URL, least recently used first out, capped at a byte budget. URLs are keyed as served,
/// by UTF-16 code units.
///
/// The cache holds each tile's body as served, which is what the budget counts, and the keys of its records
/// for `lookup(key:)`. Parsed, a tile takes about four times its body size, so the parsed records of only the
/// latest search's tiles are kept, outside the budget, as a memo (contract §10). A memoized tile is used only
/// while the cache still holds the entry it was parsed from, so what the cache holds, its recency order, and
/// so what a search fetches, are exactly as they would be without the memo.
struct TileCache {
    /// A cached tile: its body, and its records when they are memoized.
    struct Tile {
        var body: Data
        var records: [PreparedRecord]?
        /// Identifies the entry, so records parsed from it can be memoized only while it is still cached.
        var generation: Int

        func parsed() async throws -> [PreparedRecord] {
            if let records { return records }
            return try await parseCachedTile(body)
        }
    }

    private struct Entry {
        var body: Data
        var keys: Set<Int>
        var size: Int
        var generation: Int
    }

    private let budget: Int
    private let memoize: Bool
    private var entries: [OrdinalKey: Entry] = [:]
    /// Recency order, least recently used first. A few hundred keys for 50 MiB, so an array is fine.
    private var order: [OrdinalKey] = []
    private var memo: [OrdinalKey: (generation: Int, records: [PreparedRecord])] = [:]
    private var generations = 0
    private(set) var total = 0

    /// `memoize: false` parses every read again; tests compare the two.
    init(budget: Int, memoize: Bool = true) {
        self.budget = budget
        self.memoize = memoize
    }

    var urls: [String] { order.map(\.string) }

    /// The URLs whose records are memoized and current.
    var memoized: [String] { order.filter { memo[$0] != nil }.map(\.string) }

    /// A search's read: marks the tile most recently used.
    mutating func read(_ url: String) -> Tile? {
        let key = OrdinalKey(url)
        guard let entry = entries[key] else { return nil }
        touch(key)
        return tile(key, entry)
    }

    /// Adds the tile's size, then evicts least recently used tiles until the total is within budget. A tile
    /// larger than the budget evicts every other tile and then itself. Replacing a URL subtracts its old size.
    /// Returns the new entry's generation.
    @discardableResult
    mutating func insert(_ url: String, body: Data, keys: Set<Int>, size: Int) -> Int {
        let key = OrdinalKey(url)
        if let old = entries[key] { total -= old.size }
        generations += 1
        entries[key] = Entry(body: body, keys: keys, size: size, generation: generations)
        memo[key] = nil
        touch(key)
        total += size
        while total > budget, let victim = order.first {
            order.removeFirst()
            memo[victim] = nil
            total -= entries.removeValue(forKey: victim)?.size ?? 0
        }
        return generations
    }

    /// Replaces the memo with one search's parsed tiles, keeping those whose entry is still cached.
    mutating func keepParsed(_ tiles: [(url: String, generation: Int, records: [PreparedRecord])]) {
        memo = [:]
        guard memoize else { return }
        for tile in tiles {
            let key = OrdinalKey(tile.url)
            if entries[key]?.generation == tile.generation { memo[key] = (tile.generation, tile.records) }
        }
    }

    /// The tiles that may hold a record whose key (contract §4.6) equals `key`, by UTF-16 order of their
    /// URLs. The first that does is the one `getPlace` reads; a later one is there only if an earlier one's
    /// key hash collided. Does not change recency (contract §9).
    func lookup(key: String) -> [Tile] {
        let wanted = OrdinalKey(key).hashValue
        return entries.filter { $0.value.keys.contains(wanted) }
            .sorted { ordinalLess($0.key.string, $1.key.string) }
            .map { tile($0.key, $0.value) }
    }

    private func tile(_ key: OrdinalKey, _ entry: Entry) -> Tile {
        let memoized = memo[key].flatMap { $0.generation == entry.generation ? $0.records : nil }
        return Tile(body: entry.body, records: memoized, generation: entry.generation)
    }

    private mutating func touch(_ key: OrdinalKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Values that expire a fixed time after being set, by wall-clock time: fresh while now < set + ttl.
struct TtlCache<Value> {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [OrdinalKey: (value: Value, expires: Date)] = [:]

    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.now = now
    }

    func get(_ key: String) -> Value? {
        guard let entry = entries[OrdinalKey(key)], now() < entry.expires else { return nil }
        return entry.value
    }

    mutating func set(_ key: String, _ value: Value) {
        entries[OrdinalKey(key)] = (value, now().addingTimeInterval(ttl))
    }
}

/// The client's whole per-tile parse, body to the records a search reads, for atgeo-bench. Returns the
/// record count.
@_spi(Benchmark) public func benchmarkParseTile(_ body: Data) throws -> Int {
    try parseTile(body).records.count
}

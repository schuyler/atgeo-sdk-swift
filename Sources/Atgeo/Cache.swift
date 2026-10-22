import Foundation

// The tile cache and the one-hour caches, contract §10. In memory only; nothing is persisted.

/// Tiles by URL, least recently used first out, capped at a byte budget. URLs are keyed as served,
/// by UTF-16 code units.
struct TileCache {
    private struct Entry {
        var records: [TileRecord]
        var size: Int
    }

    private let budget: Int
    private var entries: [OrdinalKey: Entry] = [:]
    /// Recency order, least recently used first. A few hundred keys for 50 MiB, so an array is fine.
    private var order: [OrdinalKey] = []
    private(set) var total = 0

    init(budget: Int) { self.budget = budget }

    var urls: [String] { order.map(\.string) }

    /// A search's read: marks the tile most recently used.
    mutating func get(_ url: String) -> [TileRecord]? {
        let key = OrdinalKey(url)
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.records
    }

    /// Adds the tile's size, then evicts least recently used tiles until the total is within budget. A tile
    /// larger than the budget evicts every other tile and then itself. Replacing a URL subtracts its old size.
    mutating func set(_ url: String, records: [TileRecord], size: Int) {
        let key = OrdinalKey(url)
        if let old = entries[key] { total -= old.size }
        entries[key] = Entry(records: records, size: size)
        touch(key)
        total += size
        while total > budget, let victim = order.first {
            order.removeFirst()
            total -= entries.removeValue(forKey: victim)?.size ?? 0
        }
    }

    /// The record whose key (contract §4.6) equals `key`, from the lowest tile URL by UTF-16 order that holds
    /// one; within a tile, the first. Does not change recency (contract §9).
    func find(key: String) -> TileRecord? {
        var best: (url: String, record: TileRecord)?
        for (url, entry) in entries {
            if let best, !ordinalLess(url.string, best.url) { continue }
            if let record = entry.records.first(where: { recordKey($0).map { ordinalEqual($0, key) } ?? false }) {
                best = (url.string, record)
            }
        }
        return best?.record
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

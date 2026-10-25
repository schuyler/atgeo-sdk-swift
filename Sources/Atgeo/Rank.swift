import Foundation

// Hit construction and ordering, contract §8.

/// Relative spherical area; a point is 0, so it ranks before any box containing it.
private func specificity(_ locations: Locations) -> Double {
    guard locations.point == nil, let box = locations.bbox else { return 0 }
    let rad = Double.pi / 180
    let width = box.segments.reduce(0) { $0 + ($1.hi - $1.lo) * rad }
    return (sin(box.north * rad) - sin(box.south * rad)) * width
}

/// Scores are non-negative, where half away from zero agrees with JavaScript's Math.round.
private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

/// Three-way comparison: compare, never subtract (design review, addendum E). A subtraction of `Int64`
/// importances traps on overflow. NaN compares neither way and so ties, as a NaN difference does in JS.
private func compare<T: Comparable>(_ x: T, _ y: T) -> Int { x < y ? -1 : x > y ? 1 : 0 }

private struct Ranked {
    var hit: SearchHit
    var specificity: Double
    var index: Int
}

private typealias Comparator = @Sendable (Ranked, Ranked) -> Int

private let byScore: Comparator = { a, b in compare(round3(b.hit.score ?? 0), round3(a.hit.score ?? 0)) }
private let byImportance: Comparator = { a, b in compare(b.hit.importance ?? 0, a.hit.importance ?? 0) }
private let byDistance: Comparator = { a, b in compare(a.hit.distance, b.hit.distance) }
private let bySpecificity: Comparator = { a, b in compare(a.specificity, b.specificity) }
/// Equal origins tie; a nil origin sorts after any string; otherwise ordinal, by UTF-16 code units.
private let byOrigin: Comparator = { a, b in
    switch (a.hit.origin, b.hit.origin) {
    case (nil, nil): return 0
    case (nil, _): return 1
    case (_, nil): return -1
    case let (x?, y?):
        if x.utf16.elementsEqual(y.utf16) { return 0 }
        return x.utf16.lexicographicallyPrecedes(y.utf16) ? -1 : 1
    }
}

/// Builds the hits for records that passed the region filter, drops those scoring below the threshold,
/// and sorts them. `query` is already normalized; "" means no text.
func rank(_ records: [TileRecord], region: Region, query: String, sort: SortMode) -> [SearchHit] {
    rank(records.map(PreparedRecord.init), region: region, query: query, sort: sort)
}

func rank(_ records: [PreparedRecord], region: Region, query: String, sort: SortMode) -> [SearchHit] {
    let middle = center(region)
    var ranked: [Ranked] = []
    for prepared in records {
        let record = prepared.record
        let score = query.isEmpty ? nil : textScore(query: query, names: prepared.names)
        if let score, score < scoreThreshold { continue }
        let locations = locate(record.value)
        // The region filter already required a location, so there is always a distance.
        guard let distance = distanceTo(locations, lat: middle.lat, lon: middle.lon) else { continue }
        let hit = SearchHit(
            origin: recordKey(record), place: record.value, importance: record.importance,
            distance: distance, score: score, collection: hitCollection(record, attribution: prepared.attribution))
        ranked.append(Ranked(hit: hit, specificity: specificity(locations), index: ranked.count))
    }

    let order: [Comparator] = switch sort {
    case .distance: [byDistance, bySpecificity, byImportance, byScore, byOrigin]
    case .similarity: [byScore, byDistance, byOrigin]
    case .fused: [byScore, byImportance, byDistance, byOrigin]
    }
    // Fold the comparators as the reference does; the input index is the final tie-break, so stability does
    // not depend on the toolchain's sort.
    return ranked.sorted { a, b in
        for cmp in order {
            let d = cmp(a, b)
            if d != 0 { return d < 0 }
        }
        return a.index < b.index
    }.map(\.hit)
}

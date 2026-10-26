import Foundation

/// A client for the atgeo gazetteer that searches places without telling the server what you searched for.
///
/// A search sends only a coarse, snapped box, the dataset and the collection; the search text and the precise
/// region never leave the device (contract §12). A client holds three in-memory caches that every call made
/// on it shares, and persists nothing.
public actor AtgeoClient {
    public static let defaultServer = URL(string: "https://places.atgeo.org")!
    public static let defaultCacheBudgetBytes = 50 * 1024 * 1024

    private static let maxTilesInFlight = 8
    private static let ttl: TimeInterval = 3600

    private struct LoadedTile: Sendable {
        var generation: Int
        var records: [PreparedRecord]
        var attribution: [Attribution]
    }

    private struct TileList: Sendable {
        var tiles: [String]
        var overview: Bool
    }

    private let base: String
    private let transport: any HTTPTransport
    /// Where a returned search's failed tiles are logged; tests pass their own.
    private let log: @Sendable (TileFailure) -> Void
    private var tiles: TileCache
    /// Caches `body` under `url` as if it had been fetched, without parsing it; for tests of a cached tile
    /// that fails to parse again, which a real fetch cannot cache.
    func cacheUnparsedTile(_ url: String, body: Data) {
        _ = tiles.insert(url, body: body, keys: [], size: body.count, attribution: [])
    }
    private var tileLists: TtlCache<TileList>
    private var service: TtlCache<ServiceDescription>
    /// Tile bodies parsed, fetched or cached, for tests.
    private(set) var tileParses = 0
    /// The tile cache's URLs, least recently used first, and those whose records are memoized; for tests.
    var cachedTileURLs: [String] { tiles.urls }
    var memoizedTileURLs: [String] { tiles.memoized }

    public init(
        server: URL = AtgeoClient.defaultServer,
        transport: any HTTPTransport = URLSessionTransport(),
        cacheBudgetBytes: Int = AtgeoClient.defaultCacheBudgetBytes
    ) {
        self.init(server: server, transport: transport, cacheBudgetBytes: cacheBudgetBytes, now: { Date() })
    }

    /// For atgeo-bench, which measures the cache with and without the memo.
    @_spi(Benchmark) public init(server: URL, transport: any HTTPTransport, memoize: Bool) {
        self.init(server: server, transport: transport, cacheBudgetBytes: Self.defaultCacheBudgetBytes, now: { Date() },
                  memoize: memoize)
    }

    /// Takes the clock both one-hour caches read, so tests can expire them.
    /// `memoize: false` parses every cached tile again on each read, so tests can show the memo changes nothing.
    /// `log` receives each failed tile of a search that returns, in URL order.
    init(
        server: URL, transport: any HTTPTransport, cacheBudgetBytes: Int, now: @escaping @Sendable () -> Date,
        memoize: Bool = true, log: @escaping @Sendable (TileFailure) -> Void = logTileFailure
    ) {
        base = xrpcBase(server)
        self.transport = transport
        self.log = log
        tiles = TileCache(budget: cacheBudgetBytes, memoize: memoize)
        tileLists = TtlCache(ttl: Self.ttl, now: now)
        service = TtlCache(ttl: Self.ttl, now: now)
    }

    /// Places in `region`, filtered and ranked on the device by `text` (contract §4).
    ///
    /// `dataset` is required and has no default (contract §4.1). With a `collection` the search covers that
    /// collection; without one, the whole dataset.
    ///
    /// - Throws: `AtgeoArgumentError` before any request, for an invalid region or for `.similarity` without
    ///   text; `AtgeoError` when `getTiles` answers non-2xx; `DecodingError` when its body holds no tile
    ///   list; the transport's error on a network failure or cancellation. A tile that fails is reported in
    ///   `tileFailures` and counted in `tiles.failed`, never thrown, unless the search was cancelled.
    public func searchPlaces(
        region: Region,
        dataset: String,
        text: String? = nil,
        collection: String? = nil,
        sort: SortMode = .fused
    ) async throws -> SearchResult {
        try validateRegion(region)
        let query = normalize(text ?? "")
        if sort == .similarity && query.isEmpty { throw AtgeoArgumentError.similarityRequiresText }
        // No checkCancellation() here: a fully cached search completes even when cancelled (contract §11).

        let lists = try await tileLists(dataset: dataset, collection: collection, bboxes: queryBboxes(region))
        var seen = Set<OrdinalKey>()
        let urls = lists.flatMap(\.tiles).filter { seen.insert(OrdinalKey($0)).inserted }.sorted(by: ordinalLess)
        let (loaded, failures) = try await fetchTiles(urls)
        tiles.keepParsed(loaded.map { ($0.key.string, $0.value.generation, $0.value.records) })

        // In URL order, whatever order the tiles arrived in, so the dedupe winner is fixed (contract §4.3), and
        // so are the failures (§4.4).
        let records = urls.flatMap { loaded[OrdinalKey($0)]?.records ?? [] }
        let result = SearchResult(
            places: assemble(records, region: region, query: query, sort: sort,
                             dataset: dataset, collection: collection),
            complete: failures.isEmpty,
            overview: lists.contains(where: \.overview),
            tiles: .init(fetched: loaded.count, failed: failures.count),
            tileFailures: failures.sorted { ordinalLess($0.url, $1.url) },
            attribution: attributionUnion(urls.compactMap { loaded[OrdinalKey($0)]?.attribution }))
        // Logged only now, when the search is sure to return them, and in their order (contract §14).
        result.tileFailures.forEach(log)
        return result
    }

    /// One tile list per bbox, in bbox order. Both cache keys are looked up before any request, so only misses
    /// are fetched, concurrently; a failure fails the search and caches nothing for its key (contract §4.2).
    private func tileLists(dataset: String, collection: String?, bboxes: [String]) async throws -> [TileList] {
        let keys = bboxes.map { "\(dataset)|\(collection ?? "")|\($0)" }
        var lists = keys.map { tileLists.get($0) }
        let missing = lists.indices.filter { lists[$0] == nil }
        if missing.isEmpty { return lists.map { $0! } }

        let transport = self.transport
        let urls = try missing.map { i -> URL in
            var params: [(name: String, value: String)] = [("dataset", dataset)]
            if let collection { params.append(("collection", collection)) }
            params.append(("bbox", bboxes[i]))
            guard let url = xrpcURL(base: base, nsid: "org.atgeo.getTiles", params) else { throw URLError(.badURL) }
            return url
        }
        try await withThrowingTaskGroup(of: (Int, TileList).self) { group in
            for (i, url) in zip(missing, urls) {
                group.addTask {
                    let list = try tileList(decodeJSON(try await fetchBody(transport, url)))
                    return (i, TileList(tiles: list.tiles, overview: list.overview))
                }
            }
            // The first failure leaves the group, which cancels the other half (allowed, contract §14).
            for try await (i, list) in group {
                tileLists.set(keys[i], list)
                lists[i] = list
            }
        }
        return lists.map { $0! }
    }

    /// Loads the tiles at most `maxTilesInFlight` requests at a time, in URL order. A cached tile is used without
    /// a request and marked recently used; the lookup happens here, on the actor, before a child is added. A
    /// cached tile whose records are not memoized is parsed again in a child that takes no request slot, so
    /// requests go out exactly when they would if every cached tile were memoized. A failed tile is reported,
    /// not retried and not thrown, unless the search was cancelled (contract §4.4). The failures come back in
    /// completion order; the caller sorts them.
    private func fetchTiles(_ urls: [String]) async throws -> (loaded: [OrdinalKey: LoadedTile], failures: [TileFailure]) {
        enum Child: Sendable {
            case fetched(url: String, body: Data, records: [PreparedRecord], keys: Set<Int>, attribution: [Attribution])
            case parsed(url: String, generation: Int, records: [PreparedRecord], attribution: [Attribution])
            /// A fetch that failed, which held a request slot.
            case failed(TileFailure)
            /// A cached tile that failed to parse again, which held none.
            case reparseFailed(TileFailure)
        }
        let transport = self.transport
        return try await withThrowingTaskGroup(
            of: Child.self, returning: (loaded: [OrdinalKey: LoadedTile], failures: [TileFailure]).self
        ) { group in
            var loaded: [OrdinalKey: LoadedTile] = [:]
            var failures: [TileFailure] = []
            var pending = urls[...]
            var children = 0
            func addNext() {
                while let url = pending.popFirst() {
                    if let cached = tiles.read(url) {
                        if let records = cached.records {
                            loaded[OrdinalKey(url)] = LoadedTile(generation: cached.generation, records: records, attribution: cached.attribution)
                        } else {
                            group.addTask {
                                // The body parsed when it was fetched, and parsing is deterministic, so this does
                                // not fail. Were it to, the tile would be a `decode` failure rather than trap.
                                do {
                                    return .parsed(url: url, generation: cached.generation, records: try await cached.parsed(), attribution: cached.attribution)
                                } catch {
                                    return .reparseFailed(try tileFailure(url, .decode, error))
                                }
                            }
                            children += 1
                        }
                        continue
                    }
                    group.addTask {
                        // Each step that handles input from the server or the app is guarded, and its failure is
                        // named by where it arose, not by the error's type (contract §4.4). Checked here, before
                        // any transport sees the URL.
                        guard let u = tileRequestURL(url) else { return .failed(try tileFailure(url, .refused, refusedTileURL())) }
                        let response: HTTPResponse
                        do { response = try await transport.get(u) } catch { return .failed(try tileFailure(url, .transport, error)) }
                        let body: Data
                        do { body = try checkedBody(response) } catch {
                            return .failed(try tileFailure(url, .status, error, status: response.status))
                        }
                        do {
                            // Parsed here, in the child, so the actor is not held while it runs.
                            let (records, keys, attribution) = try parseTileWithAttribution(body)
                            return .fetched(url: url, body: body, records: records, keys: keys, attribution: attribution)
                        } catch {
                            return .failed(try tileFailure(url, .decode, error))
                        }
                    }
                    children += 1
                    return
                }
            }
            for _ in 0..<Self.maxTilesInFlight { addNext() }
            while children > 0, let child = try await group.next() {
                children -= 1
                switch child {
                case let .fetched(url, body, records, keys, attribution):
                    // Outside the child's guards: an error here would fail the search, not the tile.
                    tileParses += 1
                    let generation = tiles.insert(url, body: body, keys: keys, size: body.count, attribution: attribution)
                    loaded[OrdinalKey(url)] = LoadedTile(generation: generation, records: records, attribution: attribution)
                    addNext()
                case let .parsed(url, generation, records, attribution):
                    tileParses += 1
                    loaded[OrdinalKey(url)] = LoadedTile(generation: generation, records: records, attribution: attribution)
                case let .failed(failure):
                    failures.append(failure)
                    addNext()
                case let .reparseFailed(failure):
                    tileParses += 1
                    failures.append(failure)
                }
            }
            return (loaded, failures)
        }
    }

    /// The place whose origin is `origin`: from any cached tile without a request, else from the server's
    /// `org.atgeo.getPlace` (contract §9). The returned `origin` is the caller's.
    ///
    /// - Throws: `AtgeoError` (`PlaceNotFound` and others) for a non-2xx answer; `DecodingError` for a body
    ///   with no `value` object; the transport's error on a network failure or cancellation.
    public func getPlace(origin: String) async throws -> PlaceRecord {
        // The scan reads only each tile's key hashes; the lowest tile URL that has the key is parsed off the
        // actor unless it is memoized. Within that tile, the first record with the key wins.
        for tile in tiles.lookup(key: origin) {
            if tile.records == nil { tileParses += 1 }
            if let cached = firstRecord((try? await tile.parsed()) ?? [], key: origin) {
                return PlaceRecord(origin: origin, place: cached.value, importance: cached.importance, attribution: tile.attribution)
            }
        }
        guard let url = xrpcURL(base: base, nsid: "org.atgeo.getPlace", [("uri", origin)]) else { throw URLError(.badURL) }
        return try placeRecord(decodeJSON(try await fetchBody(transport, url)), origin: origin)
    }

    /// The tilesets the server serves; cached for an hour (`org.atgeo.describeService`).
    public func describeService() async throws -> ServiceDescription {
        if let cached = service.get("") { return cached }
        guard let url = xrpcURL(base: base, nsid: "org.atgeo.describeService", []) else { throw URLError(.badURL) }
        let description = try serviceDescription(decodeJSON(try await fetchBody(transport, url)))
        service.set("", description)
        return description
    }

    /// One tileset's descriptor; never cached (`org.atgeo.describeTileset`).
    public func describeTileset(_ slug: String) async throws -> Tileset {
        guard let url = xrpcURL(base: base, nsid: "org.atgeo.describeTileset", [("slug", slug)]) else { throw URLError(.badURL) }
        return try tileset(decodeJSON(try await fetchBody(transport, url)))
    }
}

/// The failed tile; or, if the search was cancelled, the error rethrown, so that a cancelled search fails
/// rather than reporting its tiles as failed (contract §4.4).
private func tileFailure(_ url: String, _ kind: TileFailure.Kind, _ error: any Error, status: Int? = nil) throws -> TileFailure {
    if Task.isCancelled { throw error }
    return TileFailure(url: url, kind: kind, status: status, error: error)
}

/// The union of the used tiles' attribution (contract §4.10). `lists` is in tile URL order, whatever order the tiles
/// arrived in. The first entry for each (dataset, collection) pair wins, with no field filled in from a later one;
/// the pair is a tuple, compared by UTF-16 code units, never a joined string. Sorted by dataset, then collection,
/// in the ordinal order of §4.3.
private func attributionUnion(_ lists: [[Attribution]]) -> [Attribution] {
    struct Pair: Hashable {
        var dataset: OrdinalKey
        var collection: OrdinalKey
    }
    var seen = Set<Pair>()
    var union: [Attribution] = []
    for entry in lists.joined() where seen.insert(Pair(dataset: OrdinalKey(entry.dataset), collection: OrdinalKey(entry.collection))).inserted {
        union.append(entry)
    }
    return union.sorted { a, b in
        ordinalEqual(a.dataset, b.dataset) ? ordinalLess(a.collection, b.collection) : ordinalLess(a.dataset, b.dataset)
    }
}

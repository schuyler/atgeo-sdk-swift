import Foundation

/// A client for the atgeo gazetteer that searches nearby places without telling the server what you searched for,
/// and says so in the method name when a search might.
///
/// `searchNearby` sends only a coarse, snapped box, the dataset and the collection; the search text and the precise
/// region never leave the device (contract §12). Text leaves the device only through the methods whose names contain
/// `Keyword`, and every result's `disclosed` says what the call sent. A client holds three in-memory caches that
/// every call made on it shares, and persists nothing.
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
    public func searchNearby(
        region: Region,
        dataset: String,
        text: String? = nil,
        collection: String? = nil,
        sort: SortMode = .fused
    ) async throws -> NearbySearchResult {
        try validateRegion(region)
        let query = normalize(text ?? "")
        if sort == .similarity && query.isEmpty { throw AtgeoArgumentError.similarityRequiresText }
        // No checkCancellation() here: a fully cached search completes even when cancelled (contract §11).

        let (lists, listRequested) = try await tileLists(dataset: dataset, collection: collection, bboxes: queryBboxes(region))
        var seen = Set<OrdinalKey>()
        let urls = lists.flatMap(\.tiles).filter { seen.insert(OrdinalKey($0)).inserted }.sorted(by: ordinalLess)
        let (loaded, failures, tileRequested) = try await fetchTiles(urls)
        tiles.keepParsed(loaded.map { ($0.key.string, $0.value.generation, $0.value.records) })

        // In URL order, whatever order the tiles arrived in, so the dedupe winner is fixed (contract §4.3), and
        // so are the failures (§4.4).
        let records = urls.flatMap { loaded[OrdinalKey($0)]?.records ?? [] }
        let overview = lists.contains(where: \.overview)
        let result = NearbySearchResult(
            places: assemble(records, region: region, query: query, sort: sort,
                             dataset: dataset, collection: collection, overview: overview),
            complete: failures.isEmpty,
            overview: overview,
            tiles: .init(fetched: loaded.count, failed: failures.count),
            tileFailures: failures.sorted { ordinalLess($0.url, $1.url) },
            attribution: attributionUnion(urls.compactMap { loaded[OrdinalKey($0)]?.attribution }),
            // The 0.01 degree grid went out if a getTiles request or a tile fetch was attempted; a tile the client
            // refused was not attempted, and a fetch that then failed was (contract §4.11).
            disclosed: Disclosure(keyword: false, region: listRequested || tileRequested ? 0.01 : nil))
        // Logged only now, when the search is sure to return them, and in their order (contract §14).
        result.tileFailures.forEach(log)
        return result
    }

    /// One tile list per bbox, in bbox order, and whether any `getTiles` request was made. Both cache keys are looked
    /// up before any request, so only misses are fetched, concurrently; a failure fails the search and caches nothing
    /// for its key (contract §4.2).
    private func tileLists(dataset: String, collection: String?, bboxes: [String]) async throws -> (lists: [TileList], requested: Bool) {
        let keys = bboxes.map { "\(dataset)|\(collection ?? "")|\($0)" }
        var lists = keys.map { tileLists.get($0) }
        let missing = lists.indices.filter { lists[$0] == nil }
        if missing.isEmpty { return (lists.map { $0! }, false) }

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
        return (lists.map { $0! }, true)
    }

    /// Loads the tiles at most `maxTilesInFlight` requests at a time, in URL order. A cached tile is used without
    /// a request and marked recently used; the lookup happens here, on the actor, before a child is added. A
    /// cached tile whose records are not memoized is parsed again in a child that takes no request slot, so
    /// requests go out exactly when they would if every cached tile were memoized. A failed tile is reported,
    /// not retried and not thrown, unless the search was cancelled (contract §4.4). The failures come back in
    /// completion order; the caller sorts them. `requested` is whether any tile fetch was attempted, a refused URL
    /// not being one (contract §4.11).
    private func fetchTiles(_ urls: [String]) async throws -> (loaded: [OrdinalKey: LoadedTile], failures: [TileFailure], requested: Bool) {
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
            of: Child.self, returning: (loaded: [OrdinalKey: LoadedTile], failures: [TileFailure], requested: Bool).self
        ) { group in
            var loaded: [OrdinalKey: LoadedTile] = [:]
            var failures: [TileFailure] = []
            var requested = false
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
                        // A cancelled search sends nothing more, even through a transport that ignores cancellation
                        // (contract §11).
                        try Task.checkCancellation()
                        let response: HTTPResponse
                        do { response = try await transport.get(u) } catch { return .failed(try tileFailure(url, .transport, error)) }
                        // A transport that ignores cancellation may return 200 after the search was cancelled.
                        try Task.checkCancellation()
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
                    requested = true
                    let generation = tiles.insert(url, body: body, keys: keys, size: body.count, attribution: attribution)
                    loaded[OrdinalKey(url)] = LoadedTile(generation: generation, records: records, attribution: attribution)
                    addNext()
                case let .parsed(url, generation, records, attribution):
                    tileParses += 1
                    loaded[OrdinalKey(url)] = LoadedTile(generation: generation, records: records, attribution: attribution)
                case let .failed(failure):
                    // The request was attempted unless the URL was refused.
                    if failure.kind != .refused { requested = true }
                    failures.append(failure)
                    addNext()
                case let .reparseFailed(failure):
                    tileParses += 1
                    failures.append(failure)
                }
            }
            return (loaded, failures, requested)
        }
    }

    /// Places whose name matches `keyword`, asked of the server. This sends the keyword (contract §16).
    ///
    /// One `org.atgeo.searchPlaces` request with the `dataset`, the `collection` only if given, `q` equal to
    /// `keyword` exactly as passed, and the `region` snapped outward to whole degrees only if given; nothing is
    /// cached. The hits are the server's, in its order, with no distance and no score; `disclosed` is
    /// `keyword: true` and a region of 1 degree if a region was given. A keyword the server cannot use, which is
    /// one with no word of two or more characters (contract §17), is not an argument error: the server answers
    /// `KeywordRequired`.
    ///
    /// - Throws: `AtgeoArgumentError` before any request for a `region` that is not a valid bbox; `AtgeoError` when
    ///   the server answers non-2xx (`KeywordRequired`, `InvalidRequest` for a keyword over 256 bytes of UTF-8, and
    ///   others); `DecodingError` when the body has no `places` array; the transport's error on a network failure
    ///   or cancellation. A request whose task is already cancelled is not sent.
    public func searchByKeyword(
        keyword: String,
        dataset: String,
        collection: String? = nil,
        region: KeywordRegion? = nil
    ) async throws -> KeywordSearchResult {
        if let region { try validateKeywordRegion(region) }
        var params: [(name: String, value: String)] = [("dataset", dataset)]
        if let collection { params.append(("collection", collection)) }
        params.append(("q", keyword))
        if let region { params.append(("bbox", keywordBbox(region))) }
        guard let url = xrpcURL(base: base, nsid: "org.atgeo.searchPlaces", params) else { throw URLError(.badURL) }
        let places = try searchedPlaces(decodeJSON(try await fetchBody(transport, url)))
        return KeywordSearchResult(
            places: places.map { p in
                KeywordHit(
                    origin: p.origin, place: p.value, importance: p.importance,
                    collection: collectionOf(p.value, attribution: p.attribution))
            },
            attribution: attributionUnion(places.map(\.attribution)),
            disclosed: Disclosure(keyword: true, region: region == nil ? nil : 1))
    }

    /// A nearby search with `keyword` as its text and, only if that finds no word match, a keyword request
    /// (contract §18). The keyword stays on the device unless no nearby hit matches it word for word (match tier 1)
    /// and it can qualify (contract §17); then it is sent as `searchByKeyword` sends it, with the nearby region as
    /// a box snapped to whole degrees for `.degree` and no region for `.none`. `disclosed` says which.
    ///
    /// The keyword's hits come first, then the nearby hits whose origin the keyword's do not hold. A keyword the
    /// server refuses with `KeywordRequired` leaves the nearby result, with `disclosed.keyword` true.
    ///
    /// - Throws: As `searchNearby`, and as `searchByKeyword` for the second half. A failure after the nearby half,
    ///   including a cancellation, loses the nearby result, and the keyword may have reached the server.
    public func searchNearbyThenByKeyword(
        region: Region,
        dataset: String,
        keyword: String,
        keywordRegion: KeywordRegionMode,
        collection: String? = nil,
        sort: SortMode = .fused
    ) async throws -> FallbackSearchResult {
        let nearby = try await searchNearby(region: region, dataset: dataset, text: keyword, collection: collection, sort: sort)
        let tokens = queryTokens(normalize(keyword))
        // Solid hit: a tier 1 hit, at any score. And a keyword the server would refuse is not sent.
        if nearby.places.contains(where: { matchTier(tokens, names: normalizedNames($0.place)) == 1 }) || !qualifies(keyword) {
            return FallbackSearchResult(nearby)
        }
        let sentRegion: KeywordRegion? = keywordRegion == .degree ? enclosingKeywordRegion(of: region) : nil
        let found: KeywordSearchResult
        do {
            found = try await searchByKeyword(keyword: keyword, dataset: dataset, collection: collection, region: sentRegion)
        } catch let error as AtgeoError where error.code == "KeywordRequired" {
            // The qualifying check let through a keyword the server refuses (contract §18, step 8): the nearby
            // result, with the keyword reported as sent.
            let grid: Double? = sentRegion == nil ? nil : 1
            return FallbackSearchResult(nearby, disclosed: Disclosure(keyword: true, region: nearby.disclosed.region ?? grid))
        }
        // A hit with no origin is never left out. Origins are compared by code units, as in JavaScript.
        let origins = Set(found.places.compactMap { $0.origin.map(OrdinalKey.init) })
        let remaining = nearby.places.filter { hit in hit.origin.map { !origins.contains(OrdinalKey($0)) } ?? true }
        return FallbackSearchResult(
            nearby,
            places: found.places.map(PlaceHit.keyword) + remaining.map(PlaceHit.nearby),
            attribution: attributionUnion([nearby.attribution, found.attribution]),
            disclosed: Disclosure(keyword: true, region: nearby.disclosed.region ?? found.disclosed.region))
    }

    /// An autocompleter for a text field: each of its `searchByKeyword(_:)` calls supersedes the previous call on
    /// it. Two fields on one page make two autocompleters, which do not supersede each other (contract §19).
    ///
    /// - Throws: `AtgeoArgumentError` for a `region` that is not a valid bbox, as `searchByKeyword`.
    public nonisolated func autocompleteByKeyword(
        dataset: String,
        collection: String? = nil,
        region: KeywordRegion? = nil
    ) throws -> KeywordAutocomplete {
        if let region { try validateKeywordRegion(region) }
        return KeywordAutocomplete(client: self, dataset: dataset, collection: collection, region: region)
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

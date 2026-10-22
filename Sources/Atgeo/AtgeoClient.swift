import Foundation

/// A client for the atgeo gazetteer that searches places without telling the server what you searched for.
///
/// A search sends only a coarse, snapped box, the dataset and the collection; the search text and the precise
/// region never leave the device (contract §12). A client holds three in-memory caches that every call made
/// on it shares, and persists nothing.
public actor AtgeoClient {
    public static let defaultServer = URL(string: "https://places.atgeo.org")!
    public static let defaultCacheBudgetBytes = 50 * 1024 * 1024

    private static let defaultDataset = "overturemaps.org"
    private static let defaultCollection = "place"
    private static let maxTilesInFlight = 8
    private static let ttl: TimeInterval = 3600

    private struct TileList: Sendable {
        var tiles: [String]
        var overview: Bool
    }

    private let base: String
    private let transport: any HTTPTransport
    private var tiles: TileCache
    private var tileLists: TtlCache<TileList>
    private var service: TtlCache<ServiceDescription>

    public init(
        server: URL = AtgeoClient.defaultServer,
        transport: any HTTPTransport = URLSessionTransport(),
        cacheBudgetBytes: Int = AtgeoClient.defaultCacheBudgetBytes
    ) {
        self.init(server: server, transport: transport, cacheBudgetBytes: cacheBudgetBytes, now: { Date() })
    }

    /// Takes the clock both one-hour caches read, so tests can expire them.
    init(server: URL, transport: any HTTPTransport, cacheBudgetBytes: Int, now: @escaping @Sendable () -> Date) {
        base = xrpcBase(server)
        self.transport = transport
        tiles = TileCache(budget: cacheBudgetBytes)
        tileLists = TtlCache(ttl: Self.ttl, now: now)
        service = TtlCache(ttl: Self.ttl, now: now)
    }

    /// Places in `region`, filtered and ranked on the device by `text` (contract §4).
    ///
    /// Without a dataset the search covers `overturemaps.org` / `place`; with a dataset and no collection,
    /// the whole dataset.
    ///
    /// - Throws: `AtgeoArgumentError` before any request, for an invalid region or for `.similarity` without
    ///   text; `AtgeoError` when `getTiles` answers non-2xx; `DecodingError` when its body holds no tile
    ///   list; the transport's error on a network failure or cancellation. A tile that fails is counted in
    ///   `tiles.failed`, never thrown.
    public func searchPlaces(
        region: Region,
        text: String? = nil,
        dataset: String? = nil,
        collection: String? = nil,
        sort: SortMode = .fused
    ) async throws -> SearchResult {
        try validateRegion(region)
        let query = normalize(text ?? "")
        if sort == .similarity && query.isEmpty { throw AtgeoArgumentError.similarityRequiresText }
        // Contract §4.1: the collection defaults only when the dataset does.
        let resolvedCollection = collection ?? (dataset == nil ? Self.defaultCollection : nil)
        let resolvedDataset = dataset ?? Self.defaultDataset
        // No checkCancellation() here: a fully cached search completes even when cancelled (contract §11).

        let lists = try await tileLists(dataset: resolvedDataset, collection: resolvedCollection, bboxes: queryBboxes(region))
        var seen = Set<OrdinalKey>()
        let urls = lists.flatMap(\.tiles).filter { seen.insert(OrdinalKey($0)).inserted }.sorted(by: ordinalLess)
        let (loaded, failed) = try await fetchTiles(urls)

        // In URL order, whatever order the tiles arrived in, so the dedupe winner is fixed (contract §4.3).
        let records = urls.flatMap { loaded[OrdinalKey($0)] ?? [] }
        return SearchResult(
            places: assemble(records: records, region: region, query: query, sort: sort,
                             dataset: resolvedDataset, collection: resolvedCollection),
            complete: failed == 0,
            overview: lists.contains(where: \.overview),
            tiles: .init(fetched: loaded.count, failed: failed))
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

    /// Loads the tiles at most `maxTilesInFlight` at a time, in URL order. A cached tile is used without a
    /// request and marked recently used; the lookup happens here, on the actor, before a child is added. A
    /// failed tile is counted, not retried and not thrown, unless the search was cancelled (contract §4.4).
    private func fetchTiles(_ urls: [String]) async throws -> (loaded: [OrdinalKey: [TileRecord]], failed: Int) {
        let transport = self.transport
        return try await withThrowingTaskGroup(
            of: (url: String, records: [TileRecord]?, size: Int).self,
            returning: (loaded: [OrdinalKey: [TileRecord]], failed: Int).self
        ) { group in
            var loaded: [OrdinalKey: [TileRecord]] = [:]
            var failed = 0
            var pending = urls[...]
            var running = 0
            func addNext() {
                while let url = pending.popFirst() {
                    if let cached = tiles.get(url) {
                        loaded[OrdinalKey(url)] = cached
                        continue
                    }
                    group.addTask {
                        do {
                            guard let u = URL(string: url) else { throw URLError(.badURL) }
                            let body = try await fetchBody(transport, u)
                            // Decoded here, in the child, so the actor is not held while it runs.
                            return (url, try tileRecords(decodeJSON(body)), body.count)
                        } catch {
                            if Task.isCancelled { throw error }
                            return (url, nil, 0)
                        }
                    }
                    running += 1
                    return
                }
            }
            for _ in 0..<Self.maxTilesInFlight { addNext() }
            while running > 0, let result = try await group.next() {
                running -= 1
                if let records = result.records {
                    tiles.set(result.url, records: records, size: result.size)
                    loaded[OrdinalKey(result.url)] = records
                } else {
                    failed += 1
                }
                addNext()
            }
            return (loaded, failed)
        }
    }

    /// The place whose origin is `origin`: from any cached tile without a request, else from the server's
    /// `org.atgeo.getPlace` (contract §9). The returned `origin` is the caller's.
    ///
    /// - Throws: `AtgeoError` (`PlaceNotFound` and others) for a non-2xx answer; `DecodingError` for a body
    ///   with no `record` object; the transport's error on a network failure or cancellation.
    public func place(origin: String) async throws -> PlaceRecord {
        if let cached = tiles.find(key: origin) {
            return PlaceRecord(origin: origin, place: cached.value, importance: cached.importance)
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

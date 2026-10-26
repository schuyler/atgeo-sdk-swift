# Atgeo

A Swift client for the atgeo gazetteer served by [garganorn](https://github.com/schuyler/garganorn), which searches places without telling the server what you searched for.

It's a port of [@atgeo/client](https://github.com/schuyler/atgeo-sdk-js), the TypeScript reference, and behaves the same way: same requests on the wire, same filtering, scoring and ranking. It runs on iOS 15, macOS 12, tvOS 15, watchOS 8 and visionOS 1 or later, and on Linux, needs a Swift 6 toolchain, and has no dependencies beyond Foundation.

## Synopsis

```swift
import Atgeo

let atgeo = AtgeoClient()

let result = try await atgeo.searchPlaces(
    region: .circle(lat: 39.9526, lon: -75.1652, radius: 1000),  // meters
    dataset: "overturemaps.org",
    text: "Starbux"
)

for hit in result.places {
    print(hit.place["name"]?.stringValue ?? "-", Int(hit.distance), hit.score ?? 0, hit.origin ?? "-")
}
```

Credit the data: `result.attribution` lists the collections whose data the search used, and each hit's `collection` says which one it came from. Misspellings are fine; matching is fuzzy, and that finds the Starbucks around Philadelphia's City Hall. The public server at places.atgeo.org has a limited dataset for now, mostly the east coast, so a search elsewhere may come back empty. If `result.complete` is `false`, some tiles failed to load and the results are partial. If `result.overview` is `true`, the region was too big to search in full and you got only its most important places; see [Overview answers](#overview-answers).

## Installation

This isn't tagged yet; it stays unversioned until beta testing ends. Add it with Swift Package Manager, pinned to a commit:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/schuyler/atgeo-sdk-swift", revision: "<commit-sha>"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Atgeo", package: "atgeo-sdk-swift")]),
]
```

In Xcode, that's File > Add Package Dependencies with the dependency rule set to Commit. Pin a full commit SHA rather than a branch: the API is still changing, and breaking changes land on `main`.

## Constructing a client

```swift
let atgeo = AtgeoClient(
    server: URL(string: "http://localhost:8000")!,  // default: https://places.atgeo.org
    transport: myTransport,                         // default: URLSessionTransport()
    cacheBudgetBytes: 10 * 1024 * 1024              // default: 50 MiB
)
```

Point `server` at your own garganorn to run against your own data; see [Server requirements](#server-requirements). `transport` is anything conforming to `HTTPTransport`, a protocol with one method, `get(_ url: URL) async throws -> HTTPResponse`; it's there for tests, proxies, or a `URLSession` of your own (`URLSessionTransport(session:)`). `URLSessionTransport` refuses a response body over 32 MiB, counted after gzip and friends are decoded, since the server picks the tile URLs and a megabyte of gzip can unpack to a gigabyte; the largest real tiles are about 2 MB. A refused tile is a failed tile, and anything else fails like a network error. `maxBodyBytes:` changes the limit. If you bring your own transport, it's yours to cap. `URLSessionTransport` also refuses a redirect to anything but `http` or `https`, or to a URL with a username or password, as `fetch` does; on Linux that holds only for its default session, since FoundationNetworking asks only a session's own delegate about redirects. The budget caps the in-memory tile cache (see [Caching](#caching)).

`AtgeoClient` is an actor. One client can be shared across tasks, and every call made on it shares its caches.

## API

Every method is `async throws`. Cancel the calling `Task` to abort one.

### `searchPlaces(region:dataset:text:collection:sort:) -> SearchResult`

| Parameter | Meaning |
|---|---|
| `region` | Required. A circle or bounding box (below). |
| `dataset` | Required, with no default. The dataset to search, such as `overturemaps.org` or `openstreetmap.org`. It's a plain `String`, so leaving it out doesn't compile; an empty string is sent as given and the server answers for itself. |
| `text` | Optional search text. Matched fuzzily against each place's `name` and its `variants[].name`, after lowercasing and stripping accents and extra whitespace. Each name is scored against the whole query and against the query's first 12 words one at a time; words past the 12th count only in the whole-query comparison. |
| `collection` | Optional. Restricts the search to one collection of the dataset, such as `way`. |
| `sort` | `.fused` (default), `.distance`, or `.similarity`. |

Regions:

```swift
.circle(lat: 39.9526, lon: -75.1652, radius: 1000)              // radius in meters
.bbox(west: -75.18, south: 39.94, east: -75.14, north: 39.96)  // degrees
```

Datasets and collections work like this:

- With only a `dataset`, you search the whole dataset, every collection together. `dataset: "openstreetmap.org"` returns nodes, ways and relations in one list, ranked together by importance (importance is comparable across the tilesets one producer builds from one dataset). Add `collection: "way"` to get only ways.
- With a `collection` too, you search that collection.

A collection-filtered search keeps only records whose `origin` starts with `urn:atgeo:{dataset}:{collection}:`. A record with no `origin` matches no collection filter, so such a search never returns one. A dataset-only search has no filter and returns those records too.

A bbox with `west > east` crosses the antimeridian. A place with a point location is kept if the point falls inside the region; a place with only a bounding box is kept if that box touches the region.

The result:

```swift
public struct SearchResult {
    public var places: [SearchHit]
    public var complete: Bool        // false if any tile failed to load
    public var overview: Bool        // true if the server answered with its coarse overview; see below
    public var tiles: TileCounts     // .fetched and .failed
    public var tileFailures: [TileFailure]  // each failed tile, in tile URL order; see Errors
    public var attribution: [Attribution]  // who to credit; see Attribution, below
}

public struct SearchHit {
    public var origin: String?       // the place's identity: place.origin, else the tile record's uri, else nil
    public var place: JSONObject     // the record value, exactly as served
    public var importance: Int64?    // an integer relative to its tileset; nil if it has none
    public var distance: Double      // meters from the region's center to the nearest point of the place; 0 if the place contains the center
    public var score: Double?        // 0 to 1 text similarity; nil if no text was given
    public var collection: CollectionKey?  // the collection this place belongs to (dataset and collection); nil if the tile doesn't say
}
```

`JSONObject` is `[String: JSONValue]`, and `JSONValue` is an enum of the six JSON types, with `stringValue`, `doubleValue`, `boolValue`, `arrayValue` and `objectValue` accessors and subscripts by key and index, so `hit.place["locations"]?[0]?["latitude"]?.stringValue` reads what you'd expect. Nothing about a place is decoded into a Swift type: `place` is the gazetteer's value untouched, every key as served. Importance lives on `hit.importance` and identity on `hit.origin`.

Every result type has a public initializer, so you can build a `SearchResult` or a `PlaceRecord` for your own tests and SwiftUI previews without a server. They're `Codable` too, so a saved place can be a `PlaceRecord` written with `JSONEncoder`. One catch: a number too large for a double, which no garganorn sends, is read as infinity (as JavaScript reads it), and `JSONEncoder` refuses to write infinity unless you set its `nonConformingFloatEncodingStrategy`.

When `text` is given, places scoring below 0.6 are dropped.

#### Attribution

```swift
public struct Attribution {              // org.atgeo.defs#collectionAttribution
    public var dataset: String
    public var collection: String
    public var release: String?, source: String?, licenses: [String]?, attribution: String?
}
public struct CollectionKey { public var dataset: String; public var collection: String }
```

`result.attribution` is the credit for every collection whose data the search's tiles hold, references included: a hit's `within` relations carry a containing division's name, so an app that shows that name shows that collection's data too. It has one entry per (dataset, collection), sorted by dataset and then collection (by UTF-16 code units, like the reference), and it's always a list, empty when no tile was used or none carried any. It covers every tile the search used, whether or not a record in it survived the filtering; a tile that failed contributes nothing. When two tiles give different entries for one collection, the lowest tile URL wins.

`hit.collection` is the entry of the hit's own tile whose `urn:atgeo:{dataset}:{collection}:` starts the hit's `place.origin` (the first, if several do). It's `nil` for a hit whose `place` has no `origin`, even one keyed by a `uri`, and when the tile doesn't list a matching collection.

Sort modes:

- `.fused` orders by text similarity (best first), breaking near-ties by the hit's `importance`, then by distance. Without text, that means importance, then distance. This is the one you usually want.
- `.distance` orders nearest first, then smaller place first (so the most specific of the places containing the center leads), then by importance, then similarity. Text still filters out poor matches.
- `.similarity` orders by text similarity, then nearest first. It throws without `text`.

Similarity is compared to three decimal places, so scores that differ only beyond that count as ties. Remaining ties break on `origin` (a hit with no `origin` sorts last), so ordering is deterministic.

#### Overview answers

When a region is too large for the server's regular tile budget and the collection has an overview, the server answers with that instead: a coarse tileset holding only the most important places. The search still runs normally over those tiles, and `overview` is `true`. The list is not everything in the region.

`overview` and `complete` are independent: `complete` says whether every tile the server named loaded, and `overview` says whether the server named a thin set of tiles to begin with. If `overview` is `true`, don't treat the results as exhaustive. Show something like "zoom in for more" and search a smaller region to get the full set.

#### Places that appear in more than one tile

A place can be stored in several tiles. The client keeps one hit per origin (or per `uri`, for a record with no origin); when the copies differ, the copy from the lowest tile URL wins. Garganorn's copies are byte-identical, so this only matters for other producers' tilesets. The [JS README](https://github.com/schuyler/atgeo-sdk-js#places-that-appear-in-more-than-one-tile) has the long version.

### `getPlace(origin:) -> PlaceRecord`

Returns a `PlaceRecord` with `origin`, `place`, `importance` and `attribution` (a `[Attribution]`), as in a hit. Pass the `origin` of a hit. If a cached tile holds the place, no request is made, and `attribution` is that tile's, from the lowest tile URL if several hold the place; otherwise the client asks the server (`org.atgeo.getPlace`) directly and `attribution` is the response's. Either way it's a list in the order the server sent it, duplicates included, empty if there is none.

#### Changing what you're handed

The `place` of a hit, and the answers to `getPlace(origin:)`, can be the very value the tile cache holds. In Swift that's fine: `SearchHit`, `PlaceRecord`, `Attribution`, `JSONValue` and the rest are structs and enums, so what you get is your own copy, and changing it (you'd have to declare it `var`) changes nothing the client holds or hands out later. That goes all the way down: unlike the JavaScript client, which freezes a place shallowly, a nested object or array is yours too.

### `describeTileset(_ slug:) -> Tileset`

Returns the tileset's descriptor: `slug`, `collections` (each with `dataset`, `collection` and optional `release`, `source`, `licenses`, `attribution`, `recordCount`, `locationFormats`, `containmentTypes`, `categories` and `attributes`), and optional `publishedAt`, `extent`, `references` and `overview`. `overview` is `Tileset.Overview(records:)`, the number of records in the tileset's overview band, and is `nil` when the tileset has none. Not cached.

### `describeService() -> ServiceDescription`

Returns the server's `did`, its `tilesets` (each with a `slug` and its `collections`, as `dataset` and `collection`) and `maxTiles`, the server's tile budget. `maxTiles` is for information only: tile zooms are adaptive, so you can't tell from it whether a box fits. Cached for an hour.

Every field of the describe types is optional, and a field the server drops or retypes comes back `nil` rather than failing the call. Like the result types, they're `Codable` and have public initializers.

### Errors

- `AtgeoError` has a `code`, a `message` and the HTTP `status`, which tells a request the server refused (4xx) from one it failed to answer (5xx) without matching on codes. Its `localizedDescription` is the message followed by the code in parentheses, and `AtgeoArgumentError`'s says what was wrong with the arguments. A non-2xx response from the server becomes an `AtgeoError` whose `code` and message come from the server's JSON error body; if there isn't one, the code is `HttpError`. Apart from `HttpError`, every code comes from the server: for example `PlaceNotFound`, `TilesetNotFound`, `DatasetNotFound`, `CollectionNotFound`, `BboxTooLarge`, or `InvalidRequest`.
- `searchPlaces` throws `AtgeoArgumentError` for an invalid region (non-finite or out-of-range coordinates, `south > north`, negative radius) and for `.similarity` without text, before any request.
- A 2xx body that isn't JSON, or has nothing usable in it (no `tiles` list, no `value` object for `getPlace(origin:)`; the older `{uri, record}` shape counts as having none), throws `DecodingError`.
- A failed `getTiles` request fails the whole search. A failed tile does not: that tile is skipped, not retried, and listed in `tileFailures`, which `tiles.failed` counts, and `complete` is `false`. A tile URL that isn't an absolute `http` or `https` URL, or that carries a username or password, is a failed tile too, and never reaches the transport, yours included.
- A `TileFailure` has the tile's `url` as the server gave it, a `kind` saying where it failed, the HTTP `status` for `.status`, and the `error` itself. The kinds: `.refused` (the URL check above; no request, and the error is `URLError(.unsupportedURL)`), `.status` (a non-2xx answer; the error is its `AtgeoError`), `.decode` (a 2xx whose body isn't a tile payload) and `.transport` (whatever the transport threw: a network error, a timeout, a body over the cap, or anything your own transport throws, an `AtgeoError` included). `url`, `kind` and `status` are what every atgeo SDK reports; `error` is Swift's own, so `==` and `Codable` leave it out. The client always sets it; it's `nil` only in a failure decoded from JSON or one you built with `nil` yourself. Decoding a `kind` this version doesn't know throws. A cancelled search throws rather than listing its tiles as failed.
- On Apple platforms each failed tile of a search that returns is also logged at debug level, subsystem `org.atgeo`, category `tiles`, with its kind and status public and its URL and error private: a tile URL says roughly where you searched. Nothing goes anywhere but your device's log, and nothing at all on Linux.
- Network errors come from the transport as-is, `URLError` by default. Cancellation throws `CancellationError` or `URLError(.cancelled)`, whichever got there first, or the error of a tile that failed after the cancel (a `DecodingError`, an `AtgeoError`, `URLError(.unsupportedURL)`), so check `Task.isCancelled` rather than matching the error. A call answered entirely from cache completes normally, even if its task was already cancelled.

## Privacy

Your search text never leaves the device. Neither does your precise location.

To search, the client asks the server which tiles cover an area, downloads those tiles, and does the matching, filtering, and ranking locally. The only location a search sends is a bounding box (two across the antimeridian), snapped outward to a 0.01 degree grid (roughly 1 km of latitude) before it goes out; alongside it go the search's dataset and, if it has one, its collection. Your exact region is used only on the device, to filter and to compute distances.

What does go on the wire:

- `getTiles` with the snapped bbox, the search's dataset, and its collection if it has one. A region that crosses the antimeridian sends two.
- Requests for the tile URLs the server returned, exactly as served, minus any already in the cache. So the server can tell which of those tiles this client fetched before (that you searched near here recently) but nothing finer than the tiles themselves.
- `describeService` and `describeTileset`, only if you call them.
- `getPlace(origin:)` on a cache miss sends the origin of the place you asked for.

The server also sees your IP address and whatever headers your transport sends. The default one sets `Accept: application/json`, `User-Agent: atgeo-client-swift` and `Accept-Language: *`, the same on every device. Left to itself, `URLSession` on Apple platforms would send a User-Agent naming your app, its build, and the CFNetwork and Darwin versions (so the OS version), and an Accept-Language listing the user's languages. It still adds headers of its own, such as `Accept-Encoding`, which vary by platform. A transport you supply sends whatever its stack does. Snapping hides where in a ~1 km cell you are; it doesn't hide the cell.

## Caching

`getTiles` responses and the service description are cached for an hour. Tiles are cached in memory, least recently used out first, up to `cacheBudgetBytes` (measured as the size of each tile's response body). Searching a region again while its tile list and tiles are warm makes no requests at all. `getPlace(origin:)` checks cached tiles before asking the server.

The budget counts each tile's response body, and the bodies are what the cache keeps, so the budget is close to what it costs: 1.0 to 1.4 times, measured below, the rest being an index for `getPlace(origin:)` and allocator overhead. Parsed, a tile takes about four times its body size, so only the latest search's tiles stay parsed, outside the budget. Searching the same region again with different text, as a user types, parses nothing. A tile from an older search is parsed again from its body when a search or `getPlace(origin:)` reaches it, which takes about 9 ms for an 870 KiB tile on a Linux server, or 17 ms when most of its names aren't ASCII and have to go through Unicode normalization.

Measured with `atgeo-bench`, which fills the default 50 MiB budget with synthetic tiles shaped like the OSM tiles places.atgeo.org serves (49.4 MiB of bodies), in a release build. On Linux the figure is RSS; on macOS it's the process's physical footprint, the number iOS and watchOS limit an app or extension by. Each is read after asking the allocator to return free pages:

| | Linux (x86_64) | macOS 14 | macOS 26 |
|---|---:|---:|---:|
| Parsed records, as the cache held them until October 2026 | 202 MiB (4.1×) | 181 MiB (3.7×) | 210 MiB (4.3×) |
| Bodies and the key index | 54 MiB (1.1×) | 48 MiB (1.0×) | 67 MiB (1.4×) |
| Plus the latest search's 8 tiles parsed | 102 MiB (2.1×) | 70 MiB (1.4×) | 82–94 MiB (1.7–1.9×) |

The parsed tiles of one search cost about four times their bodies (26 MiB for these 8 tiles, which are 7 MB of bodies); on Linux the total comes out higher than that because glibc holds on to pages that earlier searches' parsed tiles left fragmented. So budget for the default 50 MiB plus four to seven times the size of one search's tiles. In an extension or on watchOS, a smaller `cacheBudgetBytes` is still a good idea.

A search with text over a warm region of 36k records takes about 245 ms on Linux and 185 to 250 ms on the macOS CI runners, down from 575 to 675 ms, since names are normalized once per parse rather than on every search.

There is no persistence; a new client starts cold. The default transport uses an ephemeral `URLSession` with no URL cache and no cookies, so nothing is cached behind the client's back either.

## Performance

The client parses responses with its own JSON parser, about 270 lines that go straight from bytes to `JSONValue`. It reads an 870 KiB tile in 4 to 8 ms on CI's Linux, macOS 26 and macOS 14 runners, where `JSONDecoder` took 95 to 165 ms and `JSONSerialization` 7 to 16. Node's `JSON.parse` takes about 3. Parsing runs off the actor: a fetched tile as it arrives, with at most 8 fetches in flight, and a cached tile that isn't among the latest search's parsed tiles alongside them (see Caching, above).

To measure on your own machine, `swift run -c release atgeo-bench` times a synthetic tile against `JSONDecoder` and `JSONSerialization`, and measures the tile cache's memory and a search over a warm region; pass it paths to time real tiles too. CI runs it on Linux, current macOS and macOS 14, and puts the table in each job's summary.

## Development

```sh
swift build
swift test
```

`Tests/AtgeoTests/Fixtures/` holds the reference client's language-neutral fixtures and lexicons, vendored at the atgeo-sdk-js commit named in `Fixtures/SOURCE`. The test suite runs the fixtures and ports the reference's tests against a fake server that checks its own traffic against the lexicons.

`CONFORMANCE.md` lists where this port differs from the reference at the edges the [port contract](https://github.com/schuyler/atgeo-sdk-js/blob/main/docs/port-contract.md) leaves open, mostly in how malformed JSON is handled. None of it comes up with a garganorn server. `docs/design-review.md` is the plan this port was built to.

There's also an end-to-end run against a live server, which isn't part of `swift test`:

```sh
ATGEO_SERVER=http://localhost:8000 swift run -c release atgeo-e2e
```

It also checks `maxTiles`, the search's attribution, hit collections and `getPlace(origin:)`'s attribution, so it fails against a server that predates [schuyler/garganorn#27](https://github.com/schuyler/garganorn/issues/27). Until that's deployed, it can't pass; that is expected, and the checks stay.

It takes the same environment variables as the reference's `scripts/e2e.ts`: `ATGEO_SERVER` (default `http://localhost:8000`), `ATGEO_DATASET` (default `openstreetmap.org`), `ATGEO_COLLECTION` (default none), and `ATGEO_REGION` as `lat,lon,radius` in meters (default `43.0,-71.45,3000`, Manchester, NH). It prints a line per step, exits non-zero on the first failure, and finishes by timing the parser on the largest tile it fetched.

## Server requirements

The client needs a garganorn that serves `org.atgeo.getTiles`, `getPlace`, `describeService` and `describeTileset`, and it follows the tile URLs `getTiles` returns as-is.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

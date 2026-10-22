# Swift SDK design review and implementation plan

Reviewed: `atgeo-sdk-js/docs/swift-sdk-spec.md` and `docs/port-contract.md` at `ae773d5`, against the
reference source in `src/`, the tests in `test/`, and the fixtures. `atgeo-sdk-swift` is an empty repository.

Everything marked **verified** was run here on Linux x86_64 with the Swift 6.4.1 release toolchain
(the current release, 2026-10-12) and Node 22.22 (ICU 77, Unicode 16). Everything marked **unverified**
needs a Mac or the CI matrix.

## Verdict

The design is sound and can be built as written, with the amendments below. The architecture choices
(actor client, `JSONValue` place model, injected `HTTPTransport`, no dependencies, Linux as a first-class
target) are the right ones for this contract. The contract itself is unusually precise, and the reference
tests transcribe cleanly.

Findings 1 to 4 and 6 below were adopted into the spec at `9d83e6c` (see the addendum); finding 5 was
withdrawn. They are kept as written, with the evidence, and each heading says so.

## What was verified against the fixtures

| Check | Result |
|---|---|
| `fixtures/normalize.json`, spec §6 recipe as written | 30/30 pass |
| `fixtures/normalize.json`, recipe with `NSString.lowercased(with: nil)` | 30/30 pass |
| `fixtures/jaro-winkler.json`, UTF-16 recipe, within 5e-7, plus symmetry | 33/33 pass |
| Emoji surrogate-pair example from contract §7 | pass (0.8833333333333334) |
| Contract §3 worked bbox table, 12 rows, plus two from `region.test.ts` | 14/14 pass |
| `region.test.ts` "grid-aligned values anywhere on the grid" (93 boxes) | pass |
| Contract §6 worked distance table and exact-containment cases | pass at 1e-6 relative, containment exact |
| `-strict-concurrency` / Swift 6 language mode compile of the transport and actor shape, Linux | compiles clean; `URLSession` is `Sendable` in FoundationNetworking 6.4 |
| `JSONDecoder` into a `JSONValue` enum, Bool before Double before String, Linux | correct for `true`, `1`, `1.5`, `"1"`, `"true"`, `null`, `-0.0`, `1e300` |

So the spec's acknowledged gap ("recipes have not been run against the fixtures from Swift") is closed,
with one correction (finding 1).

## Findings that change the spec

### 1. `String.lowercased()` does not apply the Greek final-sigma rule (verified; adopted in `9d83e6c` as a warning, resolved in addendum A)

Contract §7 requires `ΟΔΟΣ` → `οδος` ending in U+03C2. The stdlib's `lowercased()` maps per scalar
with `Unicode.Scalar.Properties.lowercaseMapping`, which is context-free, so it yields U+03C3. V8 (and
Java, which the Kotlin spec relies on) implement the Final_Sigma condition from SpecialCasing.

Measured here:

| Input | V8 | `String.lowercased()` | `NSString.lowercased(with: nil)` |
|---|---|---|---|
| `ΟΔΟΣ` | οδο**ς** | οδο**σ** | οδο**ς** |
| `Ὀδυσσεύς` | οδυσσευ**ς** | οδυσσευ**σ** | οδυσσευ**ς** |
| `Σ`, `ΣΑ`, `İstanbul`, `ẞ` | σ, σα, istanbul, ß | same | same |

Why it matters even though both sides are normalized by the same function on one device: a served
name already carrying a lowercase ς stays ς under both, while a query typed in capitals lowercases to σ
under the stdlib and ς under V8. Greek names would score differently in Swift than in the other SDKs.

Fix, as first written: `(s as NSString).lowercased(with: nil)`. **Superseded by addendum A**: that call
diverges from V8 on six of 41 cases once the context around the sigma contains `.`, `:` or `·`, so the
fix is the hand-written Final_Sigma rule using `isCased`/`isCaseIgnorable`, which matches V8 on every
case tried. The stdlib's newer Unicode tables are a side benefit.

Also add two cases to `fixtures/normalize.json` upstream (`ΟΔΟΣ` → `οδος`, `Ὀδυσσεύς` → `οδυσσευς`)
so that all three ports pin this. The current fixture has no Greek, which is why the recipe passed 30/30
while violating the contract.

### 2. `URLComponents.queryItems` leaves `+` raw (verified; adopted in `9d83e6c`)

Spec §4 says to build XRPC URLs with `URLComponents` and `queryItems` and "never build query strings by
hand". Measured: the value `a+b&c=d#e f%g,h:i/j?k` is emitted as `a+b%26c%3Dd%23e%20f%25g,h:i/j?k`.
`&`, `=`, `#`, space and `%` are encoded, as the contract requires, but `+` is not, and the contract
lists `+` among the characters that must be encoded. A server decoding form-style queries turns a raw
`+` into a space. Every parameter is a caller-supplied string (`dataset`, `collection`, `slug`, and above all
`getPlace`'s `uri`, where a URN or URL can contain `+`).

Fix: percent-encode each value with `addingPercentEncoding(withAllowedCharacters:)` over the RFC 3986
unreserved set (`A-Z a-z 0-9 - . _ ~`) and assign `percentEncodedQueryItems` (the spec's wording; an
earlier draft here said `percentEncodedQuery`, which also works). Measured output for the same
value: `a%2Bb%26c%3Dd%23e%20f%25g%2Ch%3Ai%2Fj%3Fk`. `URLSearchParams` differs only in characters that
decode identically: `+` for a space, `%7E` for `~`, and a raw `*`. Keep the "no hand-built query strings"
rule for the *assembly*; the *encoding* must be explicit.

Related: `URL(string: "http://localhost:8000/")` keeps its trailing slash. Strip trailing slashes from
`server` at init, as the contract §2 requires.

### 3. `Int` is 32-bit on watchOS arm64_32 (adopted in `9d83e6c`)

Spec §3 and §8: "`importance` is `Int`, which is 64-bit on every supported platform". watchOS 8 is a
listed platform floor, and the arm64_32 watches (an ILP32 ABI where `Int` is 32 bits) are inside it. The
exact model list is from memory and unverified; the material point does not depend on it. Contract §1 requires a signed 64-bit decode.

Fix: `Int64` for `SearchHit.importance`, `PlaceRecord.importance`, `CollectionInfo.recordCount` and
`CategoryCount.count`. Verified that `JSONDecoder` decodes `9223372036854775807` into `Int64` exactly
and rejects `0.5` (tile counts as failed, which contract §1 allows). Alternatively drop watchOS from the
platform list; `Int64` is the cheaper change.

### 4. Ordinal string comparison is needed in two more places (verified; adopted in `9d83e6c`)

Spec §6 correctly says the tile URL sort must use `utf16.lexicographicallyPrecedes`, not `<`. Measured:
`"\u{10000}" < "\u{FF61}"` is `false` in Swift and `true` by UTF-16 order (and in JS). The spec does
not say the same for:

- the `byOrigin` comparator (contract §8: "ordinal string comparison");
- `TileCache.find`'s "lowest URL" rule, which §6 mentions but without the method.

Also measured: `"\u{E9}" == "e\u{301}"` is `true` in Swift (canonical equivalence). The Jaro `a == b`
shortcut and the common-prefix loop must run on the `[UInt16]` arrays, never on `String`. The spec's
recipe already does this; say so explicitly, since it is the first thing a porter "simplifies".

Rule for the spec: every string comparison the contract calls "ordinal" or "UTF-16" operates on
`.utf16`, and `String`'s `==` and `<` are never used on origins, URLs or names.

## Findings about the spec's own reasoning

### 5. The `getPlace` → `place(origin:)` rename (withdrawn)

As first written, this finding argued for `getPlace(origin:)` on parity grounds: §3 keeps the other three
XRPC names "because they are the names of the server queries they wrap", and `getPlace` is one too.
**Withdrawn.** The spec's `place(origin:)` is the idiomatic choice: the API Design Guidelines drop `get`
prefixes as needless words, and Apple names network-backed, async, throwing value producers as noun
phrases (`URLSession.data(for:)`, CloudKit's `record(for:)`, WeatherKit's `weather(for:)`). The parity
argument is weaker than it looked, since the other three names read as verbs in Swift anyway, so keeping
them costs nothing, while `getPlace` would be the one method that reads as Objective-C. The doc comment
cites `org.atgeo.getPlace` so a reader can still find the server query. Decision: `place(origin:)`, as
the spec says. `place(for origin:)` would follow Apple's prepositional precedent more closely and is a
reasonable alternative; either is fine, the plan uses the spec's spelling.

### 6. Toolchain floor: pick Swift 6.0 tools and drop the XCTest hedge (adopted in `9d83e6c`)

§2 says tools version 5.9; §7 says swift-testing "with XCTest as the fallback if the package must build
with 5.9". `import Testing` does not compile on a 5.9 toolchain, so the hedge means maintaining two test
suites or choosing one now. Swift 6.0 shipped in September 2024; the current release is 6.4.1.
Recommendation: `// swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]` (which makes the
`-strict-concurrency=complete` flag redundant, since language mode 6 makes data races errors), and
swift-testing only. Keep the platform floors (iOS 15, macOS 12) as they are; they are runtime floors for
`URLSession.data(for:)`, independent of the toolchain.

## Implementation notes (no spec change needed, but write them down)

7. **bbox formatting.** Snapped values are integers (hundredths of a degree). Format them as integers:
   `"\(sign)\(a / 100).\(a % 100 < 10 ? "0" : "")\(a % 100)"` with `a = abs(units)`. This avoids
   `String(format:)` (Foundation, and verified to print `-0.00` for negative zero) and the `-0.0`
   remap. Verified against all 14 worked rows and the 93-box grid test.
8. **`Double(String)` accepts `inf`, `Infinity`, `nan` and hex floats (`0x10` → 16).** The `isFinite`
   check after parsing is mandatory, not optional. Hex is a divergence from `parseFloat` (which gives 0)
   that the contract's §5 freedom does not quite cover; garganorn never emits it. Cheapest exact guard:
   accept a string only if every character is in `+-.0123456789eE` before calling `Double(_:)`.
9. **Jaro inner loop.** When `i - reach > b.count - 1`, the JS `for` loop runs zero times; a Swift
   `lo...hi` range with `lo > hi` traps. Guard it. (Hit while writing the probe.)
10. **Rounding.** `(x * 100).rounded()` is half-away-from-zero (`-2.5` → `-3`; JS gives `-2`). Harmless
    here, as contract §3 explains, because the epsilon test fails on any half. `round3` only sees
    non-negative scores. No change, but a comment in the code.
11. **Keep CPU and decoding off the actor.** Decode tile JSON inside the task-group child, not after
    hopping back to the actor. The spec says fetches run outside the actor; say decoding does too.
    Likewise, look up both tile-list cache keys on the actor *before* the `async let` pair, so only
    misses become requests (the spec says this for tiles, not for tile lists).
12. **`JSONDecoder` performance is unknown.** The recursive-enum decode is correct on Linux (verified)
    and, by my reading of the old Darwin implementation, on iOS 15–17 too (it refuses CFBoolean for
    numeric types and numbers for Bool). It is also slow for large payloads. Measure with a real
    garganorn tile before the first release; a 200-line byte-level parser is the fallback and would also
    remove the Foundation-version variable entirely. Note `1e400` fails to decode on Linux and the 2024+
    Foundation (tile counts as failed), where `JSON.parse` yields `Infinity`; allowed, a compliant
    server never sends it. Old Darwin `JSONSerialization` was not measured.
13. **TileCache has no eviction test in the reference.** Contract §13 lists "LRU eviction" under
    `cache.test.ts`, but that file tests warm regions, expiry and the `getPlace` scan only. The
    place.garden wiki records your 2026-10-16 decision not to add budget/eviction tests to the JS
    client. The Swift cache is a fresh implementation of a precise §10 algorithm (replace subtracts old
    size, oversize tile evicts everything including itself); a direct unit test of the `TileCache` type
    is cheap and does not touch the JS client. Recommend adding it in Swift regardless.
14. **Fake-server fidelity.** With `HTTPTransport.get(_ url: URL)` as the only seam, the client cannot
    set headers or a body, so the captured `headers`/`body` are empty by construction. The §12 privacy
    tests remain meaningful on the URL (raw and percent-decoded) and the request kinds; there is nothing
    to assert about method or body.
15. **Minimum request validation in the fake** (contract §13), from the lexicons: `getTiles` requires
    `dataset` and `bbox`, optional `collection`, no other names; `bbox` matches
    `^-?\d+\.\d\d,-?\d+\.\d\d,-?\d+\.\d\d,-?\d+\.\d\d$`; `getPlace` requires `uri` with `format: uri`
    (the reference test sends `not a uri` and expects `InvalidRequest`, so at minimum reject a value
    without a scheme followed by `:`); `describeTileset` requires `slug`. Responses: `getTiles.tiles`
    array, `getPlace.uri` + `record`, `describeService.did` + `tilesets`, tile payload `records`.
16. **e2e script.** `Scripts/e2e.swift` cannot import the module as a loose script. Make it an
    executable target (`atgeo-e2e`) in `Package.swift`; `swift test` ignores executables.
17. **Open question 1 (CoreLocation):** agree, no. If wanted later, a `#if canImport(CoreLocation)`
    extension in a separate file costs nothing on Linux.

## Unverified, needs a Mac or CI

- `JSONDecoder` Bool/Double/String ordering under the pre-2024 Darwin Foundation (iOS 15–17, macOS
  12–14). Reasoned above; put a test on the macOS runner with the deployment target lowered.
- `URLSession.data(for:)` cancellation propagation on Linux (FoundationNetworking). Needs a slow fake
  endpoint or a transport that sleeps; add one cancellation test.
- `decomposedStringWithCompatibilityMapping` Unicode table versions on Darwin vs Linux. Fixtures pass
  on Linux; CI will show skew on macOS if any. (`lowercased(with:)` is no longer used; see addendum A.)

## Implementation plan

Order chosen so each step is testable before the next starts, and so the pure parts land before anything
touches the network. "Pure" includes the JSON model, which `locate` and `textScore` read from, so it is in
step 0.

| Step | Files | Verified by |
|---|---|---|
| 0 | `Package.swift` (tools 6.0, language mode 6, library `Atgeo`, test target with `Fixtures/` resources, executable target `atgeo-e2e`); `.github/workflows/ci.yml` (ubuntu `swift:6.4-noble` container and macos-latest, each `swift build && swift test`, no `-strict-concurrency` flag since language mode 6 covers it, plus a grep that `Sources/` imports only `Foundation` and `FoundationNetworking`); `.gitignore`; `CONFORMANCE.md` skeleton; `Sources/Atgeo/JSONValue.swift` (the enum, the accessors, `Codable`, `decodeJSON(_ data: Data) throws -> JSONValue`, and a `noUsableBody(_:)` helper that builds the `DecodingError` with a `Context`); `Sources/Atgeo/Errors.swift` (`AtgeoError`, `AtgeoArgumentError`); vendored `fixtures/*.json` and `test/lexicon/*.json` from `9d83e6c`; `Tests/AtgeoTests/Fixtures/SOURCE` recording both the atgeo-sdk-js commit (contract §13) and the garganorn commit from upstream `test/lexicon/SOURCE` (spec §7) | `swift build` and `swift test` green on both runners with a `JSONValueTests.swift` that decodes the sample from the first review (Bool before Double before String, `null`, `-0.0`, nesting) |
| 1 | `Text.swift`: normalize with the hand Final_Sigma rule (addendum A), jaroWinkler, scoreName, `textScore(query:value: JSONObject)` | `NormalizeTests.swift`: `normalize.json` compared by UTF-16 code units, plus the six sigma/`İ`/`ẞ` cases kept locally until the upstream fixture has them (contract §7 says a port tests them itself meanwhile). `SimilarityTests.swift`: `jaro-winkler.json` within 5e-7 and the symmetry test from `similarity.test.ts` |
| 2 | `Region.swift`: `Region`, `validateRegion` (the bbox and circle checks, in the contract's order; the similarity-requires-text check needs `normalize` and lives in the client, step 8), center, circleBox, snapping, `queryBboxes` with note 7's integer formatter (either formatter satisfies the contract; the `-0.0` remap is dead with integer units) | `RegionTests.swift` (internal entry points only; the `region.test.ts` port comes in step 8): contract §3 worked table and the grid test |
| 3 | `Locations.swift`: `locate(_ value: JSONObject)` (note 8), haversine, covers, meets, distanceTo, inRegion; `Tests/AtgeoTests/Builders.swift` with the `place`, `point`, `bboxLocation`, `record` builders the reference keeps in `fakeServer.ts`, reused by step 7 | `DistanceTests.swift`: contract §6 table and the `distance.test.ts` port, which is pure |
| 4 | `Types.swift` (`SortMode`, `SearchResult`, `SearchHit`, `PlaceRecord`, the describe types with `Int64` fields, and the lenient mappers from `JSONValue` for: a tile payload, a tile list (string entries kept, non-strings skipped, no `tiles` array → `noUsableBody`), a getPlace body, both describe types, an error body → `(code, message)`, and overview truthiness); `Merge.swift` (recordKey, dedupe keyed by UTF-16 code units, collection-prefix filter; one file added to the spec's §2 layout); `Rank.swift` (three-way comparators per addendum E, `byOrigin` by code units, index tie-break); an internal `assemble(records:region:query:sort:dataset:collection:) -> [SearchHit]` running contract §4.6 to §4.9 | `RankingTests.swift` (fixture through `assemble`; the `ranking.test.ts` port through the client comes in step 8); `ToleranceTests.swift` at unit level, bodies in, values out, one test per contract §16 bullet plus the overview table, the error-body rule and the describe-type rules; on the macOS runner, the same file re-measures addendum C's `JSONDecoder` cases and the Bool/Double/String ordering with the deployment target lowered, and `CONFORMANCE.md` is updated from it |
| 5 | `Cache.swift`: `TileCache`, `TtlCache` with injected `now` | `CacheTests.swift` (unit level; the `cache.test.ts` port comes in step 8): TTL fresh at `set + 3,599,999` ms and a miss at exactly `set + 3,600,000`; replace subtracts the old size; an oversize tile leaves an empty cache; eviction order after reads; `find(key:)` compares keys by UTF-16 code units, picks the lowest `absoluteString` by UTF-16 order on a pair where `String <` disagrees, and does not change eviction order |
| 6 | `Transport.swift`: `HTTPTransport`, `HTTPResponse`, `URLSessionTransport` (ephemeral session per spec §4; sets `Accept: application/json` on every request and nothing else), the XRPC URL builder (finding 2; trailing slashes stripped from `server`), and the internal GET helper that returns the body `Data` after reading it, checking the status, and throwing `AtgeoError` from step 4's error-body mapper; `Tests/AtgeoTests/Loopback.swift`, a minimal test-only HTTP/1.1 listener over POSIX sockets that can answer with a given status and body, redirect, echo request headers, and hold a response open until told to release it (no third-party dependency) | `URLSessionTransportTests.swift` (the spec §7 loopback test; `TransportTests.swift` is reserved for the `transport.test.ts` port in step 8): 4xx with a JSON error body → `AtgeoError.code` from the body; 4xx with an empty body → `HttpError`, `HTTP 4xx`; a same-scheme redirect is followed; a held response plus task cancellation throws; the echoed request has `Accept: application/json`, and no header name or value contains the test's marker string. The encoder has its own unit test |
| 7 | `Tests/AtgeoTests/FakeServer.swift` (note 15 and spec §7: tilesets, `tilesFor`, `failTiles`, `server`, `goOffline`, tile bodies with `publishedAt` and `attribution`, URL capture), plus a raw-body seam (`rawBodies: [URL: (status: Int, body: Data)]`) so step 8 can serve malformed tile, tile-list, getPlace and describe bodies; `Tests/AtgeoTests/DelayingTransport.swift`, a wrapper that delays named URLs and records the peak number of in-flight requests; `FakeServerTests.swift` | the four "requests" tests port as is; of the five "configuration" tests, "accepts a valid configuration" ports as is and the four rejections (value without `name`, record without `value`, float importance, descriptor without `slug`) are reproduced by the fake's own validation, written to match |
| 8 | `AtgeoClient.swift`: contract §4.1 to §4.5 and every rule in spec §5, among them the dataset/collection table and the `collection` parameter sent only when present, the key `"{dataset}|{collection or empty}|{bbox}"`, both tile-list keys looked up on the actor before the `async let` pair, nothing cached on a failed `getTiles`, cache lookup on the actor before a child is added, at most 8 children in flight, decoding in the child tasks, assembly in URL order from a dictionary after the group finishes, no `checkCancellation()` at the top; `place(origin:)`, `describeService`, `describeTileset`; the similarity-requires-text check; an internal `init` threading `now` to both TTL caches | `RegionTests`, `MergeTests`, `ClientTests`, `TransportTests`, `CacheTests`, `OverviewTests`, `PrivacyTests` and `RankingTests` gain the ports of their reference files; `ToleranceTests` gains the same cases through the fake; `ConcurrencyTests.swift` (no reference counterpart): with 20 tiles behind `DelayingTransport`, peak in-flight is 8; a held tile plus task cancellation throws rather than reporting `failed: 1`; a cancelled task on a warm cache still returns; a failed `getTiles` followed by a retry issues a second request |
| 9 | `Sources/atgeo-e2e/main.swift` (note 16), `README.md` (install by `.package(url:revision:)`, the e2e environment variables, the privacy and caching sections mirrored from the JS README), `CONFORMANCE.md` completed | manual e2e run against a local garganorn, which is also where note 12's `JSONDecoder` timing on a real tile is measured; re-pin `SOURCE` and delete the local sigma cases once the upstream fixture PR merges |

Files added to the spec's §2 layout, in one place: `Errors.swift`, `Merge.swift`, `Sources/atgeo-e2e/`,
`CONFORMANCE.md`; in tests, `Builders.swift`, `Loopback.swift`, `DelayingTransport.swift`,
`JSONValueTests.swift`, `ToleranceTests.swift`, `URLSessionTransportTests.swift`, `ConcurrencyTests.swift`.
Every reference `test/*.test.ts` still has its one `*Tests.swift`.

How the reference tests port (step 8 unless noted):

- `client.test.ts` "retired wire names" and "universal runtime": skipped as tests; the CI grep in step 0
  is the equivalent.
- `region.test.ts` "throws synchronously": there is no sync/async distinction for an `async throws`
  method; assert the `AtgeoArgumentError` case (not the message string) and zero captured requests.
- `merge.test.ts` "determinism": uses step 7's `DelayingTransport`.
- `cache.test.ts` expiry: uses the internal client `init` with a test clock.
- `privacy.test.ts`: asserts on URLs only (raw and percent-decoded) and on request kinds; the method and
  body are fixed by the protocol shape, so there is nothing to assert about them.

Steps 1 to 6 verify through internal entry points and fixtures only, because every reference test file
except `normalize.test.ts`, `similarity.test.ts` and `distance.test.ts` drives `AtgeoClient` through the
fake server, which does not exist until step 7.

The probe code written for this review (normalize with the hand rule, Jaro-Winkler, `queryBboxes` with
the integer formatter, `distanceTo`, the fixture runner) lives in this session's scratchpad at
`/tmp/claude-0/-home-user/bacf2527-a7c3-5eef-9605-42b675143a52/scratchpad/probe/` and `probe3/`, and
disappears with the container. The recipes it transcribes are in the spec and in this document, so if it
is not preserved, steps 1 to 3 are written from those; that changes the estimate, not the correctness.

Decisions this plan makes that the spec leaves open or says differently:

- **Public method name.** `place(origin:)`, as the spec says. Finding 5, which argued for
  `getPlace(origin:)`, is withdrawn (decided 2026-10-22).
- **Transport headers.** Spec §7 says the transport adds "only fixed headers of its own" and the loopback
  test checks "the exact request headers". The platform's defaults are not fixed (addendum D), so this
  plan departs: the transport sets `Accept: application/json` and nothing else, and the test asserts that
  header and the absence of the marker string, not an exact set.
- **bbox formatting.** Note 7's integer formatter instead of spec §6's `String(format: "%.2f", …)` with a
  `-0.0` remap. Same output on every worked example.
- **`Merge.swift` and `Errors.swift`** are added to the spec's §2 layout; the error-body mapping (step 4)
  and the status check that throws (step 6) are in different files.
- **e2e** is an executable target, not `Scripts/e2e.swift` (note 16).
- **CI** pins `swift:6.4-noble` and drops the `-strict-concurrency=complete` flag, and adds the import grep.
- **`Int64.min`** reads as absent under the `magnitude < 2^63` guard. That is a deliberate departure from
  contract §1 (which puts it inside the range) for parity with the Kotlin spec's identical guard, and is
  recorded in `CONFORMANCE.md`.
- **`CONFORMANCE.md`** also holds the Unicode known-skew list the spec §6 mentions, and its parser
  entries are labelled "with `JSONDecoder`; measured on Linux; re-measured on macOS in step 4", to be
  revised if note 12's fallback parser is ever adopted.
- **`ToleranceTests.swift` and `ConcurrencyTests.swift`** have no reference counterpart, a deliberate
  addition to the spec's one-to-one file rule, because every §16 behaviour is one where the reference
  crashes and the reference has no cancellation or concurrency-cap test.

Upstream changes to `atgeo-sdk-js` that this plan assumes: see "Plan changes" at the end of the addendum,
which supersedes the list that stood here.

---

# Addendum: review of the spec changes at `9d83e6c` (PR #11)

Six commits touch all three docs. The contract gains a tolerance principle, a lenient-decoding rule for
every response, and §16 "Known reference deviations". The Swift spec adopts `Int64`, tools 6.0 with
language mode 6, explicit query encoding, a warning about final sigma, a code-unit comparison section,
and an `isFinite` check. Findings 1 to 4 and 6 of the original review are now in the text; finding 5
(the `getPlace` rename) is not.

## Verified here

| New prescription | Result |
|---|---|
| Final_Sigma by hand "while lowercasing", as §6 now describes it | matches V8 on 41 cases including `Α.Σ.`, `Ο.Α.Σ.Α.`, `ΑΣ'Α`, `ΑΣ_ΒΣ`, `ΑΣ\u{200B}Α`, pre-existing lowercase sigmas; fixture 30/30 compared by UTF-16 code units |
| `percentEncodedQueryItems` with values encoded over the unreserved set, Linux | emits `uri=urn%3Aatgeo%3Aa%3Ab%3Ax%2By%20z%26w%3D1%23f%25`; `URLSearchParams` emits the same except `+` for the space, which decodes identically |
| `Int64(d)` after `d.isFinite && d.magnitude < 2^63` | `1.9` → 1, `-1.9` → -1, `-0.9` → 0; `9223372036854775808` decodes to a `Double` of exactly 2^63 and is excluded by the guard |
| Jaro empty-range guard | the `Starbux` scenario is what trips it; a `while` or an `if lo > hi { continue }` both work |

## Findings on the new text

### A. Make the Final_Sigma rule definite, and do not substitute Foundation's lowercasing (verified)

§6 says the stdlib "is expected to differ" and to apply Final_Sigma by hand "if it differs". It does
differ, on every final sigma. The hand rule as written is correct and small:

```swift
if u.value == 0x03A3 {
    // SpecialCasing Final_Sigma: a cased letter before (skipping case-ignorables), none after.
    var before = false, j = i - 1
    while j >= 0 { let p = scalars[j].properties; if p.isCaseIgnorable { j -= 1; continue }; before = p.isCased; break }
    var after = false, k = i + 1
    while k < scalars.count { let p = scalars[k].properties; if p.isCaseIgnorable { k += 1; continue }; after = p.isCased; break }
    out.append(before && !after ? "\u{03C2}" : "\u{03C3}")
} else {
    out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
}
```

The tempting one-liner, `(s as NSString).lowercased(with: nil)`, passes the fixture but diverges from V8
on six of the 41 cases, in both directions: `Α.Σ.` → `α.σ.` where V8 gives `α.ς.`, and `ΑΣ.Α`, `ΑΣ..Α`,
`ΑΣ:Α`, `aΣ.b`, `ΑΣ·Α` → `ς` where V8 gives `σ`. CoreFoundation does not treat the MidLetter and
MidNumLet case-ignorables (`.`, `:`, `·`) as ignorable on either side, while it does skip `'`, U+2019,
U+02BC, U+200B and U+00AD. Greek abbreviations such as `Ο.Α.Σ.Α.` would score differently. The spec
should name this so nobody "simplifies" to it later, and should spell out "skipping case-ignorables"
for the following side as well as the preceding one, since that is exactly where implementations differ.
(An earlier draft of this addendum said one case of 41; the NSString variant had only been run on 22.)

Fixture: the contract §7 now says the fixture lacks the sigma, `İ` and `ẞ` cases "until it does". All
three recipes (V8, JVM, and now Swift) agree, so add them now, and include the pair `Α.Σ.` → `α.ς.` and
`ΑΣ.Α` → `ασ.α`, which discriminate a correct Final_Sigma from CoreFoundation's in both directions.

### B. One lenient decoding path, not two

The Swift spec now prescribes two mechanisms: describe types are read "with `try?` from a keyed
container", and tile records are read "from `JSONValue`, not through `Codable`". The Kotlin spec was
changed to a single path (parse to `JsonElement`, map by hand). Do the same here: decode every 2xx body
to `JSONValue` once, then map with the lenient accessors. Then "no usable body" (§1), the error-body
rule (object with string `error`/`message`, each judged alone), the `overview` truthiness table
(`.null`, `.bool(false)`, `.number(0)`, `.string("")` and absent are false, everything else true), tile
records, and the describe types are all the same ten lines of pattern matching, and the keyed-container
path disappears. Keep synthesized `Codable` on the describe structs for apps that persist them, but say
plainly that the synthesized decoder is strict (a missing `tilesets` fails it) and is never used on a
server response. The "no usable body" cases then throw a hand-built `DecodingError` (it needs a
`Context`), which is one helper.

### C. `CONFORMANCE.md` entries this port will need (contract §5, new)

The contract now asks each port to list the number-parsing forms its parser treats differently. For
Swift, measured:

- `Double(String)` accepts hex floats (`"0x10"` → 16; `parseFloat` gives 0) and `inf`/`infinity`/`nan`
  in any case (rejected by the `isFinite` check), and rejects leading whitespace and trailing text.
- A JSON number literal that overflows a double (`1e400`) fails to parse under both `JSONDecoder` and
  `JSONSerialization` on Linux, so a tile containing one anywhere counts as failed. `JSON.parse` yields
  `Infinity` and the reference carries on. One that underflows (`1e-400`) fails under `JSONDecoder` but
  parses to 0 under `JSONSerialization` and `JSON.parse`. A compliant server never sends either.
- Duplicate keys: `JSONDecoder` into `[String: JSONValue]` keeps the first value (`{"a":1,"a":2}` → 1);
  `JSONSerialization` and `JSON.parse` keep the last. Keeping `JSONDecoder` as the parser (note 12)
  chooses first-wins knowingly; the same applies to the canonically-equivalent-key merge below.
- A lone surrogate escape (`"\uD800"`) fails under both Swift parsers; `JSON.parse` accepts it. The tile
  counts as failed.
- The `Int64` range guard `magnitude < 2^63` also excludes exactly `Int64.min`, which is inside the
  contract's range. The Kotlin spec has the same guard, so the ports agree; one line here.
- Integers beyond 2^53 round as in JavaScript (verified `9007199254740993` → `…992`), which the contract
  now requires.
- `[String: JSONValue]` merges two keys that are canonically equivalent (`é` precomposed vs decomposed);
  JavaScript keeps both. Contract §1 says every key is surfaced as served. A code-unit-keyed dictionary
  would fix it at the cost of every app's ergonomics; document it as a margin instead.

### D. Smaller points

- **Trailing slash.** Verified: `URLComponents(string: server + "/xrpc/…")` yields `//xrpc/…` when
  `server` ends in `/`. Contract §2 requires stripping; the Swift spec's `server: URL` parameter
  should say the initializer does it.
- **`String(format:)` and `-0.0`.** With `units` an integer, `Double(units) / 100` is never `-0.0`, so
  the remap is dead code. The integer formatter from the first review (`"\(sign)\(a / 100).…"`) needs
  neither it nor Foundation; still a recommendation, not a correction.
- **Default headers.** The spec says the default transport adds "only fixed headers of its own". They
  are not fixed. Measured on Linux against a loopback server, FoundationNetworking's ephemeral session
  sends `Accept: */*`, `Accept-Encoding`, `Accept-Language: en`, and a `User-Agent` carrying the process
  name and the libcurl version. Darwin adds a locale-derived `Accept-Language` as well (from memory).
  None of these is a §12 concern, but the loopback test that asserts "the exact request headers" should
  assert only on headers the client sets itself; setting `Accept` and `User-Agent` explicitly in the
  transport makes that set non-empty and platform-independent.
- **`getPlace` rename** (original finding 5): the spec's `place(origin:)` stands; the finding is
  withdrawn, see finding 5 for why.
- **Stale text.** The status paragraph still says the recipes have not been run from Swift (they have:
  30/30, 33/33, every worked table) and contract §7 still says the runtime "is expected to differ" (it
  does). CI still passes `-Xswiftc -strict-concurrency=complete`, redundant under language mode 6, and
  uses the `swift:6` image, which should be pinned (`swift:6.4-noble`). `Scripts/e2e.swift` cannot
  import the module as a loose script; make it an executable target. Add `CONFORMANCE.md` to the layout
  in §2.

### E. `byImportance` must compare, not subtract (found by the independent review)

Contract §8 writes `byImportance` as `(b.importance ?? 0) - (a.importance ?? 0)` and the Swift spec says
to fold the comparators exactly as the reference does. With `Int64`, a literal transcription traps on
overflow when two importances span more than 2^63 (`Int64.max` against `-1`), and the contract allows
negatives and the full range on untrusted server data. Write every comparator as a three-way comparison
and return the sign, never a difference. The spec should say so where it says "fold them exactly as the
reference does", in the same breath as the `lo...hi` warning.

## Plan changes

- Step 1 implements the hand Final_Sigma rule above; the probe already does, and passes.
- Step 4 decodes everything through `JSONValue` (finding B); `Types.swift` gains the lenient mappers
  and loses any `Decodable` use on responses.
- Step 0 adds `CONFORMANCE.md` with the entries in C.
- The upstream PR now needs: the fixture additions (six cases: `ΟΔΟΣ`, `Ὀδυσσεύς`, `Α.Σ.`, `ΑΣ.Α`,
  `İstanbul`, `ẞ`), the status paragraph, the "expected to differ" sentence, "skipping case-ignorables"
  on both sides in §6, finding B's wording, finding E's "compare, do not subtract", and the §13
  correction from the first review (`cache.test.ts` has no eviction test, which the current contract
  still claims), the §13 case count (30 becomes 36) and the §7 "until it does" sentence; findings 1 to 4
  and 6 of the first review are done.
- Step 4 writes every comparator as a three-way comparison (finding E).

## Revision note

A third consistency review followed the second. It moved `JSONValue` and the error types to step 0
(steps 1 and 3 read from them), settled the header decision as `Accept` only with a stated assertion,
split the error-body mapper from the status check and said which step owns each, named every test file
including the ones the one-to-one rule does not predict, fixed the fake-server test counts, removed a
false claim that the fixtures had not changed since `09ec2b9`, marked the main-body findings as adopted
or withdrawn, and replaced the main body's upstream list with a pointer to the addendum's.

A second, consistency-and-completeness review followed. It found that step 0 depended on an upstream
fixture change that does not exist yet, that the contract's tolerance rules (§1, §16) had no test in any
step, that `recordKey`/`dedupe`/the collection filter had no file, that cancellation and several cache
rules had no tests, and that the method name, the transport headers, the loopback server's design and
the `AtgeoError` mapping's home were left to the implementer. The plan table and the decisions list
above are the result. The method name was then decided: `place(origin:)`, finding 5 withdrawn.

This document was revised after an independent fresh-eyes review that re-ran the probes and wrote new
ones. It corrected addendum A (six divergent cases, both directions, not one), added finding E and the
parser-semantics entries in C, reordered the plan so the fake server precedes the client-driven tests,
added the loopback transport test and the `fakeServer.test.ts` port to the plan, re-pinned the fixture
vendoring, and marked the watch model list and the old-Darwin parser behaviour as unverified.

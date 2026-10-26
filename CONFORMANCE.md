# Conformance

Where this port's behaviour differs from the TypeScript reference at the margins the port contract
leaves open (`atgeo-sdk-js/docs/port-contract.md` §5, §14), and the Unicode skew list spec §6 asks for.
None of these cases arises from a compliant garganorn server.

The fixtures and lexicons are vendored at the commits named in `Tests/AtgeoTests/Fixtures/SOURCE`: atgeo-sdk-js
`2710a14ba7d9485ddb6c00975f396e95389ac419` (the pin follow-up to the squash merge of schuyler/atgeo-sdk-js#43, `89539c49e014deb49464b278af2b7bc6f9df09fc`; `src/` and `fixtures/` are identical at both) and
garganorn `2009984de02e9b3cbdf0f645213c99ec90ea3406`. CI's `fixtures` job holds them to those pins byte for byte.

## JSON parsing

Responses are parsed by the port's own parser (`Sources/Atgeo/JSONParser.swift`) into `JSONValue`, so these
margins are the same on every platform. `ToleranceTests` and `JSONParserTests` assert each one, in every CI
job that runs the tests. Before this parser the client used `JSONDecoder`, which
failed a tile on `1e400`, `1e-400` or a lone surrogate and kept the first of duplicate keys.

| Input | This port | Reference (`JSON.parse`) |
|---|---|---|
| A lone surrogate escape (`"\uD800"`) | U+FFFD, since a Swift `String` cannot hold a lone surrogate | the lone code unit, kept |
| Two keys that are canonically equivalent (`é` precomposed and decomposed) | merged into one key of `[String: JSONValue]`, holding the later value | kept as two keys |
| Nesting deeper than 512 arrays or objects | parse error; inside a tile, a `decode` failure. The parser is iterative, so no depth overflows the stack | accepted |

Where the two agree, at margins a port might get wrong: a number literal that overflows a double (`1e400`) is
infinity and one that underflows (`1e-400`) is zero; the last of duplicate keys wins; invalid UTF-8 becomes
U+FFFD, as the reference's `response.text()` makes it; a leading byte-order mark is skipped; integers beyond
2^53 round to the nearest double (`9007199254740993` → `…992`).

## Numbers

| Input | This port | Reference |
|---|---|---|
| A coordinate string holding a hex float (`"0x10"`) | rejected: a string is read only if every character is in `+-.0123456789eE` | `parseFloat` gives `0` |
| `"inf"`, `"Infinity"`, `"nan"` in any case | no location (non-finite) | no location (non-finite) |
| Leading whitespace or trailing text (`" 1.5"`, `"1.5abc"`) | no location | `parseFloat` reads the leading number |
| `importance` of exactly -2^63 (`Int64.min`) | absent: the range guard is `magnitude < 2^63`, symmetric, as contract §1 and the Kotlin port have it | kept as the number |

## Tile URLs

Before any transport sees a tile URL, the client trims it as WHATWG URL parsing does (leading and trailing C0
controls and spaces removed, tab, LF and CR dropped) and checks it (`tileRequestURL` in
`Sources/Atgeo/Transport.swift`, contract §4.4). Anything that fails the check is a failed tile, with no request
made, whatever transport the client has. The check reads the URL twice:

- As a string, as the Rust and Python ports do: `http` or `https` in any case followed by `://`; the authority
  ending at `/`, `\`, `?` or `#`; a non-empty host with no `%`, a bracketed host of hex digits, `:` and `.` only;
  a bracketed host that WHATWG's IPv6 parser accepts (`[127.0.0.1]`, `[a]`, `[:::1]` are refused); a port, if any,
  of digits and at most 65535. No `@` may appear before the first `/`, `?` or `#`, a backslash
  notwithstanding, since Foundation does not end the authority at a backslash. The authority must gain no
  delimiter, `%`, bracket, whitespace or control under NFKC, which IDNA applies to a host, and hold none of the
  code points Foundation drops or maps where WHATWG refuses them or maps them otherwise (below). The scheme is
  lowercased in the URL handed to the transport, as WHATWG writes it.
- As Foundation parses it: `URL(string:)` must succeed, and its `URLComponents` must have an http or https
  scheme, a non-empty host, and no user or password, checked percent-encoded. `URL.user` alone is not enough:
  for `https://h\%FF@x/y` Foundation reads the userinfo `h%5C%FF`, which does not decode, so `URL.user` is nil
  while `URLSessionTransport` still sends it as `Authorization: Basic`. The URL Foundation would send
  (`absoluteString`) must pass the string check too, and parse again to the same host and port. These are
  defence in depth: the string check refuses every URL they are known to catch before Foundation reads it.

Before this check, every URL `URL(string:)` could parse went to the transport: a relative URL, `file:`, `ftp:`,
and credentials, which `URLSessionTransport` on Linux sent as `Authorization: Basic` (and `Basic Og==` for an
empty userinfo). On Linux it threw `URLError(.unsupportedURL)` for `file:` and `ftp:`. Nobody established
whether Apple's URLSession would have read a `file:` tile, and with the check in place it no longer matters.

| Input | This port | Reference (`fetch`) |
|---|---|---|
| An empty userinfo (`https://@h/x`, `https://:@h/x`) | a failed tile: any `@` before the host is refused, as in the Rust and Python ports, which contract §4.4 allows since a compliant server never sends one. It carries no credentials, but FoundationNetworking would send it as `Authorization: Basic Og==` | the userinfo dropped, the URL fetched |
| An http(s) URL with other than two slashes, or with backslashes, after the scheme (`https:h/x`, `https:/h/x`, `https:///h/x`, `https:\\h\x`) | a failed tile | `https://h/x` |
| A backslash ending the authority (`https://h\x/y`) | a failed tile on Linux, where `URL(string:)` returns nil, and on Apple platforms before iOS 17 / macOS 14 | host `h`, the backslash read as `/` |
| An `@` after a backslash in the authority (`https://h\@x/y`, `https://h\x@y/z`) | a failed tile: Foundation reads what precedes the `@` as a userinfo and the rest as the host | host `h`, the rest of it path |
| A backslash in the path (`https://h/a\b`) | fetched with it percent-encoded (`/a%5Cb`), on Linux; Apple platforms before iOS 17 / macOS 14 return nil and the tile fails | `/a/b` |
| A port over 65535, or a bracketed host that is not an IPv6 address | a failed tile, `refused`, as in the reference | refused (an invalid URL) |
| An uppercase scheme (`HTTPS://h/x`) | fetched, with the scheme lowercased; FoundationNetworking fails `HTTPS:` as an unsupported URL | fetched |
| U+1E9E (capital sharp s) in the host | a failed tile, `refused`: Foundation maps it to `ß` (`xn--…`) | mapped to `ss` and fetched |
| A default-ignorable code point WHATWG refuses in a host: U+115F, U+1160, U+17B4, U+17B5, U+180E, U+1D173 to U+1D17A, U+200C to U+200F, U+2061 to U+2063, U+2065 to U+206F, U+3164, U+FFA0 | a failed tile, `refused`; Foundation would drop most of them silently | refused |
| U+200B, U+2060, U+2064, U+FEFF, U+00AD or U+034F in the host | dropped and fetched (`a`, U+200B, `b.example` is `ab.example`) | dropped and fetched |
| A `%` in the host (`https://h%41/x`) | a failed tile, `refused`: Foundation would send the escape as written | decoded and fetched (host `ha`) |
| `{`, `}`, `"` or `` ` `` in the host | a failed tile, `refused`: `URL(string:)` returns nil on Linux | fetched, and DNS fails it |
| A non-ASCII character in the authority that NFKC, which IDNA applies, maps to a delimiter, `%`, a bracket, whitespace or a control (`h：8080`, `localhost℀x`, `h％40x`, `h＃x`, `u＠h`, `u﹫h`: U+FF1A, U+2100, U+FF05, U+FF03, U+FF20, U+FE6B) | a failed tile, `refused`. Foundation would map it and send a host or port WHATWG never reads (on Linux, `localhosta/cx` and port 8080; macOS 14 reads host `localhosta` and path `/cx/y`; the macOS and iOS simulator on CI's macos-latest return nil). The URL Foundation would send must also pass the check again and parse to the same host and port | refused |
| A plain IDN host (`bücher.example`) | fetched in punycode (`xn--bcher-kva.example`) on Linux | punycode |
| A forbidden host code point (`<`, `^`) | a failed tile, `refused`: `URL(string:)` returns nil on Linux | refused |
| A shorthand or hex IPv4 host WHATWG rewrites (`http://0x7f.1/x`, `http://127.1/x`) | sent with the host as written; FoundationNetworking fails it with `URLError(.badURL)` (-1000) before resolving anything, a `transport` failure | rewritten to `127.0.0.1` and fetched |
| A host WHATWG refuses that the check passes: a last label that looks numeric but is not a valid IPv4 address (`localhost.1`, `a.0x10`, `a.09`, `1.2.3.4.5`, `99999999999`), or a letter IDNA disallows (U+2132, U+2183) | sent as written, the letters in punycode: a `transport` failure, or fetched if the name resolves | refused |
| A NUL or other C0 control, or a space, at either end of a tile URL | trimmed before the check, as WHATWG does; one inside the URL is percent-encoded by `URL(string:)` on Linux (`?q`, NUL, `z` sent as `?q%00z`) | trimmed; inside, percent-encoded |
| A tile URL holding a character not allowed raw in a URL (a space, say) | percent-encoded and fetched, on Linux and on Apple platforms from iOS 17 / macOS 14 (Apple's `URL(string:)` encodes invalid characters from those releases on); before them `URL(string:)` returns nil and the tile counts as failed | percent-encoded and fetched |

## Redirects

`URLSessionTransport` declines a redirect to anything but an http or https URL without credentials, checked as
tile URLs are, and fails the request with `URLError(.redirectToNonExistentLocation)`: a network failure, and in
a search a `transport` failure. `fetch` refuses the same redirects; before this, URLSession followed
`Location: http://user:pw@host/` and sent `Authorization: Basic`.

| Case | This port | Reference (`fetch`) |
|---|---|---|
| A 3xx with an empty or unparsable `Location` | a `transport` failure, `URLError(.redirectToNonExistentLocation)`, as `fetch` fails it | a network failure |
| A session the app supplies, on Apple platforms | the transport's task delegate is asked in place of the session's; a redirect the check allows is passed on to the session's own delegate, so the app's policy (declining, or rewriting the request) still holds | refused |
| A session the app supplies, on Linux | follows its own redirect policy: FoundationNetworking asks only a session's own delegate about redirects, not the transport's task delegate, so only `defaultSession` carries the check. On Apple platforms the task delegate is asked, so every session has it | refused |
| `Location: file:///…`, `data:…` or `javascript:…` on Linux | FoundationNetworking reads it as a path on the current host (`http://host/etc/hostname`) and follows that, which the check allows; it never reads a file | a network failure |
| `Location: //user:pw@host/x` on Linux | followed to `host`, with the credentials dropped | a network failure |
| A `Location` holding backslashes (`\\h\x`) on Linux | followed as a path on the current host | `\` read as `/`: `//h/x`, another host |
| A redirect target whose host Foundation maps before the check reads it (`Location: http://ẞ/…`, `http://` U+1160 `…`) | checked after Foundation's IDNA mapping, so followed: `ẞ` to `xn--zca`, U+1160 dropped. The redirecting server could name those hosts directly | `ẞ` to `ss`; U+1160 refused |
| `Location: http:///x` | followed to `/x` on the current host | host `x` |

## Failed tiles

`SearchResult.tileFailures` reports each failed tile in tile URL order with the `url`, `kind` and `status`
contract §4.4 pins, plus `error`, which `==` and `Codable` leave out. The port's choices where the contract
leaves them open:

- `error` for `.refused` is `URLError(.unsupportedURL)`, what FoundationNetworking itself throws for `file:`.
- `.status` comes only from the client's own status check, `.transport` from anything `HTTPTransport.get`
  throws, an `AtgeoError` from an app's transport included.
- A cached tile whose body fails to parse again is `.decode`; parsing is deterministic, so only a test that
  caches an unparsable body reaches it.
- Decoding a `TileFailure` whose `kind` is not one of the four, as a later version might write, throws
  `DecodingError`, and so does decoding the `SearchResult` holding it.
- A cancelled search throws the in-flight tile's own error, as the reference does, rather than report failures.
- Each failure of a search that returns is logged with `os.Logger` (subsystem `org.atgeo`, category `tiles`) at
  debug level on Apple platforms, in URL order, after the search has finished and just before it returns, kind
  and status public, URL and error description private. A search that throws, cancelled or not, logs nothing.
  Nothing is logged on Linux.

## Unicode skew

Cases of `fixtures/normalize.json` that fail on one platform and pass on another because of Unicode
version differences between Foundation builds. None: all 41 cases, at the pinned commit, pass on every
CI platform (Linux, current macOS and macOS 14), including the Final_Sigma abbreviations, `İ` and `ẞ`.

## Fixtures and their runners

- `normalize.json`, `jaro-winkler.json`: as before.
- `ranking-scenarios.json`: run twice, through the internal pipeline and through the client, each as a search of
  the scenario's `dataset` and `collection` (`RankingTests`).
- `lenient-readers.json` (104 cases): `LenientReaderTests` runs all five readers and maps what each keeps into
  the fixture's JSON terms by encoding the Swift value, so a nil optional is a missing key. The `tilePayload`
  result is `{records, attribution?}`.
- `attribution-scenarios.json` (12 scenarios): `AttributionScenarioTests`, with contract §13's rules: a fresh
  client per scenario, a raw server that lists the scenario's tiles unsorted and serves each tile verbatim, the
  default error body for a tile with a status and no body, no text and the default sort. Hits are compared as a
  multiset of `(origin, collection)`, and each hit's `collection` must encode to exactly `dataset` and
  `collection`.
- Tile arrival order, which a fixture cannot express: the same runner reruns every scenario with more than one
  tile with the lowest URL's response delayed most, so the highest URL arrives first, and asserts both that the
  delays took effect and that the attribution and hits are unchanged.
- Cache and copy behaviour (`CacheTests`, `ClientTests`, `ValueSemanticsTests`): warm and offline searches keep
  their attribution and hit collections, `getPlace(origin:)` answers with the lowest-URL source tile's attribution
  or the response's, and a tile with no attribution, or one that isn't a list, gives an empty list.

## Copies of what you're handed

Contract §8 and §9 ask a port to hand out immutable values or copies of the place and the attribution. Swift
does neither explicitly: `SearchHit`, `PlaceRecord`, `Attribution`, `CollectionKey` and `JSONValue` are values,
and arrays and dictionaries copy on write, so an app that changes an answer changes its own copy. This goes
deeper than the reference's shallow `Object.freeze`: nested objects and arrays are the app's too. The tests
change an answer's `licenses`, release, order and nested place values and look at the next search and the next
`getPlace(origin:)`.

## Required dataset

`dataset` is a non-optional `String` in `searchPlaces(region:dataset:text:collection:sort:)`, so contract §4.1's
"missing or non-string dataset" and "collection without a dataset" argument errors cannot arise: the call does not
compile. There is no `AtgeoArgumentError` case for them. An empty string is sent as given.

## Circle snapping

The circle's enclosing box is written operation for operation as contract §3 asks
(`half * .pi / 180` groups left to right), but `sin`, `cos` and `asin` come from the platform's libm, which can differ from V8's in the last bit for some
inputs, and snapping can move an edge across a grid line when it does. It changes which cell is asked for, never
what the wire reveals. No Swift-specific count has been measured.

## Tile attribution in the cache

Contract §10 lets a port that caches bodies parse the attribution again with them. This one reads a tile's
attribution once, when the tile is fetched, and keeps it in the cache entry next to the body. A tile's size is
still its body length, so the budget does not count it; the lists are small (a few entries per tile) and sit
outside the budget, like the memo. Results are identical either way: a cached tile's records still carry the
attribution of the tile they came from.

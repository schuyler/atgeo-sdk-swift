# Conformance

Where this port's behaviour differs from the TypeScript reference at the margins the port contract
leaves open (`atgeo-sdk-js/docs/port-contract.md` §5, §14), and the Unicode skew list spec §6 asks for.
None of these cases arises from a compliant garganorn server.

The fixtures are vendored at the commit named in `Tests/AtgeoTests/Fixtures/SOURCE`.

## JSON parsing

Responses are parsed by the port's own parser (`Sources/Atgeo/JSONParser.swift`) into `JSONValue`, so these
margins are the same on every platform. `ToleranceTests` and `JSONParserTests` assert each one, in every CI
job that runs the tests. Before this parser the client used `JSONDecoder`, which
failed a tile on `1e400`, `1e-400` or a lone surrogate and kept the first of duplicate keys.

| Input | This port | Reference (`JSON.parse`) |
|---|---|---|
| A lone surrogate escape (`"\uD800"`) | U+FFFD, since a Swift `String` cannot hold a lone surrogate | the lone code unit, kept |
| Two keys that are canonically equivalent (`é` precomposed and decomposed) | merged into one key of `[String: JSONValue]`, holding the later value | kept as two keys |
| Nesting deeper than 512 arrays or objects | parse error; inside a tile, the tile counts as failed | accepted |

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
`Sources/Atgeo/Transport.swift`, contract §4.4): it must be an absolute `http` or `https` URL, scheme in any
case, with a non-empty host and no credentials, both as the string reads (the authority ends at `/`, `\`, `?`
or `#`, as in the Rust and Python ports) and as `URL(string:)` parses it. Anything else is a failed tile, with
no request made, whatever transport the client has. Before this check, every URL `URL(string:)` could parse went
to the transport: a relative URL, `file:`, `ftp:`, and credentials, which `URLSessionTransport` on Linux sent as
`Authorization: Basic` (and `Basic Og==` for an empty userinfo). On Linux it threw `URLError(.unsupportedURL)` for
`file:` and `ftp:`; whether Apple's URLSession would have read a `file:` tile was never established, and no
longer matters.

| Input | This port | Reference (`fetch`) |
|---|---|---|
| An empty userinfo (`https://@h/x`, `https://:@h/x`) | a failed tile: any `@` before the host is refused, as in the Rust and Python ports, which contract §4.4 allows since a compliant server never sends one. It carries no credentials, but FoundationNetworking would send it as `Authorization: Basic Og==` | the userinfo dropped, the URL fetched |
| An http(s) URL without its slashes (`https:h/x`) | a failed tile | `https://h/x` |
| A backslash ending the authority (`https://h\x/y`, `https://h\@x/y`) | a failed tile. On Linux `URL(string:)` returns nil for the first and reads the second as user `h\` at host `x`, so it disagrees with the string check and the URL is refused; Apple platforms before iOS 17 / macOS 14 return nil for both | host `h`, the backslash read as `/` |
| A backslash in the path (`https://h/a\b`) | fetched with it percent-encoded (`/a%5Cb`), on Linux; Apple platforms before iOS 17 / macOS 14 return nil and the tile fails | `/a/b` |
| A tile URL holding a character not allowed raw in a URL (a space, say) | percent-encoded and fetched, on Linux and on Apple platforms from iOS 17 / macOS 14 (Apple's `URL(string:)` encodes invalid characters from those releases on); before them `URL(string:)` returns nil and the tile counts as failed | percent-encoded and fetched |

## Unicode skew

Cases of `fixtures/normalize.json` that fail on one platform and pass on another because of Unicode
version differences between Foundation builds. None: all 41 cases, at the pinned commit, pass on every
CI platform (Linux, current macOS and macOS 14), including the Final_Sigma abbreviations, `İ` and `ẞ`.

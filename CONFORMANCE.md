# Conformance

Where this port's behaviour differs from the TypeScript reference at the margins the port contract
leaves open (`atgeo-sdk-js/docs/port-contract.md` §5, §14), and the Unicode skew list spec §6 asks for.
None of these cases arises from a compliant garganorn server.

The fixtures are vendored at the commit named in `Tests/AtgeoTests/Fixtures/SOURCE`.

## JSON parsing

Responses are parsed with `JSONDecoder` into `JSONValue`. Entries below are with `JSONDecoder`, and
`ToleranceTests` asserts each one on every CI platform: Linux (Swift 6.4.1), current macOS, and macOS 14,
whose Foundation predates the 2024 rewrite and is what iOS 15-17 and macOS 12-14 run. All three agree.

| Input | This port | Reference (`JSON.parse`) |
|---|---|---|
| A number literal that overflows a double (`1e400`) | parse error; inside a tile, the tile counts as failed | `Infinity`; the search carries on |
| A number literal that underflows (`1e-400`) | parse error; inside a tile, the tile counts as failed | `0` |
| Duplicate keys (`{"a":1,"a":2}`) | the first value wins | the last value wins |
| A lone surrogate escape (`"\uD800"`) | parse error; inside a tile, the tile counts as failed | accepted |
| Two keys that are canonically equivalent (`é` precomposed and decomposed) | merged into one key of `[String: JSONValue]` | kept as two keys |
| Integers beyond 2^53 | rounded to the nearest double, as in JavaScript (`9007199254740993` → `…992`) | same |

## Numbers

| Input | This port | Reference |
|---|---|---|
| A coordinate string holding a hex float (`"0x10"`) | rejected: a string is read only if every character is in `+-.0123456789eE` | `parseFloat` gives `0` |
| `"inf"`, `"Infinity"`, `"nan"` in any case | no location (non-finite) | no location (non-finite) |
| Leading whitespace or trailing text (`" 1.5"`, `"1.5abc"`) | no location | `parseFloat` reads the leading number |
| `importance` of exactly -2^63 (`Int64.min`) | absent: the range guard is `magnitude < 2^63`, symmetric, as contract §1 and the Kotlin port have it | kept as the number |

## Unicode skew

Cases of `fixtures/normalize.json` that fail on one platform and pass on another because of Unicode
version differences between Foundation builds. None so far.

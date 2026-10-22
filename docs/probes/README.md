# Probes

Throwaway Swift programs written while reviewing the port spec, kept because `docs/design-review.md`
cites their results and because `probe.swift` and `sigma2.swift` are direct transcriptions of the
contract's recipes that pass every fixture. They are not part of the package and are not built by
`swift build`. None has dependencies beyond Foundation.

Run on Linux with a Swift 6.4.1 toolchain (what the results were measured with) or any Swift 6:

```sh
swiftc -O -o probe probe.swift && ./probe path/to/atgeo-sdk-js/fixtures
swiftc -O -o sigma2 sigma2.swift && ./sigma2 path/to/atgeo-sdk-js/fixtures cases.txt > hand.out
node v8-cases.js > v8.out   # see below for the one-liner
diff hand.out sigma2-v8.out
```

| File | What it establishes |
|---|---|
| `probe.swift` | Contract §7 normalize (spec §6 recipe, stdlib `lowercased()`), Jaro-Winkler on UTF-16, §3 snapping and bbox strings with the integer formatter, §6 distance; runs `normalize.json`, `jaro-winkler.json`, every worked table and the grid test; then prints the Swift semantics the review relies on. 223 pass, 1 fail: the stdlib's missing Final_Sigma. |
| `sigma.swift` | The same normalize with `NSString.lowercased(with: nil)`: passes the fixture, and matches V8 on the first 8 sigma cases. Superseded by `ns41.swift`, which shows it diverging on 6 of 41. |
| `sigma2.swift` | Normalize with the hand-written Final_Sigma rule (addendum A of the review). Passes the fixture by UTF-16 comparison; `sigma2-hand-rule.out` equals `sigma2-v8.out` line for line over `cases.txt`. This is the recipe the port uses. |
| `cases.txt` | 41 inputs exercising Final_Sigma: abbreviations, apostrophes, combining marks, zero-width and soft-hyphen characters, pre-existing lowercase sigmas, `İ`, `ẞ`, `ǅ`. |
| `sigma2-v8.out` | V8's output for `cases.txt` (Node 22.22, ICU 77, Unicode 16), scalars per line, from `s.toLowerCase().normalize("NFKD").replace(/\p{Mn}/gu, "").replace(/\s+/g, " ").trim()`. |
| `ns41.swift`, `ns41-nsstring.out` | The NSString variant over all 41 cases; diverges from V8 on `Α.Σ.`, `ΑΣ.Α`, `ΑΣ..Α`, `ΑΣ:Α`, `aΣ.b`, `ΑΣ·Α`. |
| `probe2.swift` | `percentEncodedQueryItems` on Linux, trailing-slash behaviour of `URLComponents`, JSON number edges (`1e400`, 2^63), `Int64(Double)` truncation. |
| `dup.swift`, `surrogate.swift` | `JSONDecoder` vs `JSONSerialization`: duplicate keys (first vs last wins), `1e-400` (throws vs 0), lone surrogate escapes (both throw). |
| `sendable.swift` | Compiles clean with `-swift-version 6`: the `HTTPTransport`/`URLSessionTransport`/actor shape is `Sendable` on Linux. |
| `hdr.swift`, `srv.py` | What FoundationNetworking's ephemeral `URLSession` sends by default, captured by a one-shot loopback server: `Accept: */*`, `Accept-Encoding`, `Accept-Language: en`, a `User-Agent` with the process name and libcurl version. |

The V8 one-liner used for `sigma2-v8.out`:

```js
const n = s => s.toLowerCase().normalize("NFKD").replace(/\p{Mn}/gu, "").replace(/\s+/g, " ").trim();
const sc = s => [...s].map(c => "U+" + c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")).join(" ");
for (const l of require("fs").readFileSync("cases.txt", "utf8").split("\n").filter(Boolean)) console.log(sc(n(l)));
```

import Foundation

/// A usable record from a tile payload (contract §4.4): `value` is an object; `uri` and `importance` are
/// absent unless they are a string and an in-range number (contract §1, §16).
struct TileRecord: Sendable, Equatable {
    var value: JSONObject
    var uri: String?
    var importance: Int64?
}

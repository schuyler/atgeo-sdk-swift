import Foundation
#if canImport(os)
import os
#endif

/// Logs a failed tile at debug level, and never above (contract §14), on platforms with `os`; elsewhere nothing.
/// Only the failure's own fields. The kind and status are public; the URL and the error's description are
/// private (the default), since a tile URL reveals the coarse area searched and an app's transport may put
/// anything in an error (contract §12). Nothing from the search text or the region.
func logTileFailure(_ failure: TileFailure) {
    #if canImport(os)
    let logger = Logger(subsystem: "org.atgeo", category: "tiles")
    let error = failure.error.map { String(describing: $0) } ?? ""
    if let status = failure.status {
        logger.debug("tile failed, \(failure.kind.rawValue, privacy: .public) \(status, privacy: .public): \(failure.url): \(error)")
    } else {
        logger.debug("tile failed, \(failure.kind.rawValue, privacy: .public): \(failure.url): \(error)")
    }
    #endif
}

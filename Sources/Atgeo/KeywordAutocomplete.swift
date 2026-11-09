import Foundation

/// An autocompleter, returned by `AtgeoClient.autocompleteByKeyword(dataset:collection:region:)` (contract §19).
/// Each text field makes its own: "the previous call" belongs to the autocompleter, so two fields on one page that
/// share a client do not supersede each other. Beyond its options it holds only the previous call's task, and
/// caches nothing.
public actor KeywordAutocomplete {
    private let client: AtgeoClient
    private let dataset: String
    private let collection: String?
    private let region: KeywordRegion?
    /// The previous call's task, which the next call cancels.
    private var previous: Task<KeywordSearchResult, any Error>?
    /// Counts calls, so a call can tell that a later one superseded it.
    private var generation = 0

    init(client: AtgeoClient, dataset: String, collection: String?, region: KeywordRegion?) {
        self.client = client
        self.dataset = dataset
        self.collection = collection
        self.region = region
    }

    /// The places whose names match `keyword`, as `AtgeoClient.searchByKeyword` returns them, and an empty result,
    /// sent nowhere, for a keyword the server would refuse (contract §17).
    ///
    /// Every keyword that qualifies is sent to the server as given, prefixes included. The server keeps no log of
    /// it (garganorn's privacy design), but an operator who is hostile can record what it receives. Debouncing
    /// reduces how many prefixes go out, and is the app's choice; this method does not debounce.
    ///
    /// A call supersedes the previous call on this autocompleter, which throws `CancellationError`, although its
    /// caller's task was not cancelled: a `CancellationError` from an autocompleter's call means "superseded", and
    /// the app ignores that answer and shows the newest call's. A caller that cancels its own call cancels its
    /// request, and gets `CancellationError` or `URLError(.cancelled)`; a call whose task is already cancelled
    /// sends nothing.
    ///
    /// - Throws: `AtgeoError` as `searchByKeyword` does, except that `KeywordRequired`, a keyword the server
    ///   refused although it qualified, resolves with an empty result whose `disclosed.keyword` is true, since the
    ///   keyword went out.
    public func searchByKeyword(_ keyword: String) async throws -> KeywordSearchResult {
        // Supersede the previous call, if any, so that it ends with `CancellationError`.
        previous?.cancel()
        generation += 1
        let mine = generation
        // A call whose caller has already cancelled it sends nothing.
        try Task.checkCancellation()

        // The caller's `await` sits outside the task that does the work, so the work can be cancelled on its own.
        let client = self.client, dataset = self.dataset, collection = self.collection, region = self.region
        let work = Task {
            try await Self.answer(keyword, client: client, dataset: dataset, collection: collection, region: region)
        }
        previous = work
        defer { if generation == mine { previous = nil } }

        let result: KeywordSearchResult
        do {
            // The caller's own cancellation cancels the work, and so the request (contract §11).
            result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            // Superseded, whatever the work threw: `URLError(.cancelled)`, or an injected transport's own error.
            if generation != mine { throw CancellationError() }
            throw error
        }
        // The work may not have noticed that it was cancelled, as a transport that ignores cancellation does not.
        if generation != mine { throw CancellationError() }
        return result
    }

    /// One call's work. A keyword that cannot qualify answers with nothing and sends nothing.
    private static func answer(
        _ keyword: String, client: AtgeoClient, dataset: String, collection: String?, region: KeywordRegion?
    ) async throws -> KeywordSearchResult {
        guard qualifies(keyword) else {
            return KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: false, region: nil))
        }
        do {
            return try await client.searchByKeyword(keyword: keyword, dataset: dataset, collection: collection, region: region)
        } catch let error as AtgeoError where error.code == "KeywordRequired" {
            // As for a keyword the qualifying check skips, except that this one went out (contract §19).
            let grid: Double? = region == nil ? nil : 1
            return KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: true, region: grid))
        }
    }
}

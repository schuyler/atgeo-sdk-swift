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
    /// The previous call's work, which the next call cancels.
    private var previous: Task<Void, Never>?
    /// Counts calls, so a call can tell that a later one superseded it.
    private var generation = 0
    /// The current call's caller, waiting. Whoever takes it resumes it, so it is resumed exactly once.
    private var waiter: CheckedContinuation<KeywordSearchResult, any Error>?

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
    /// request, and gets `CancellationError` at once, though a transport that ignores cancellation is still
    /// working; a call whose task is already cancelled sends nothing, and throws `CancellationError` unless the
    /// keyword cannot qualify, when it resolves empty because there is nothing to cancel (contract §19).
    ///
    /// - Throws: `AtgeoError` as `searchByKeyword` does, except that `KeywordRequired`, a keyword the server
    ///   refused although it qualified, resolves with an empty result whose `disclosed.keyword` is true, since the
    ///   keyword went out.
    public func searchByKeyword(_ keyword: String) async throws -> KeywordSearchResult {
        // Supersede the previous call, if any: its caller is told now, whatever its transport is doing.
        finish(.failure(CancellationError()))
        previous?.cancel()
        generation += 1
        let mine = generation
        // Nothing is sent for a keyword that cannot qualify, so there is nothing to cancel (contract §19).
        guard qualifies(keyword) else {
            return KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: false, region: nil))
        }
        // A call whose caller has already cancelled it sends nothing.
        try Task.checkCancellation()

        // The work runs in a task of its own, so it can be cancelled on its own, and reports to the waiter.
        let client = self.client, dataset = self.dataset, collection = self.collection, region = self.region
        previous = Task {
            let outcome: Result<KeywordSearchResult, any Error>
            do {
                outcome = .success(try await Self.answer(keyword, client: client, dataset: dataset, collection: collection, region: region))
            } catch {
                outcome = .failure(error)
            }
            await self.finish(outcome, call: mine)
        }
        // The caller's own cancellation cancels the work, and so the request (contract §11).
        return try await withTaskCancellationHandler {
            try await self.wait(call: mine)
        } onCancel: {
            // Synchronous and not isolated, so it hops onto the actor, and may run before `wait` has stored the caller.
            Task { await self.cancel(call: mine) }
        }
    }

    /// Stores the caller of call `mine` until `finish` resumes it.
    private func wait(call mine: Int) async throws -> KeywordSearchResult {
        try await withCheckedThrowingContinuation { continuation in
            guard generation == mine else { return continuation.resume(throwing: CancellationError()) }
            waiter = continuation
            // Already cancelled, so `cancel(call:)` may have run before the caller was stored.
            if Task.isCancelled { cancel(call: mine) }
        }
    }

    /// The caller of call `mine` cancelled it.
    private func cancel(call mine: Int) {
        guard generation == mine else { return }
        previous?.cancel()
        finish(.failure(CancellationError()))
    }

    /// Resumes the waiting caller, if call `mine` (default: the current one) still has one.
    private func finish(_ outcome: Result<KeywordSearchResult, any Error>, call mine: Int? = nil) {
        if let mine, mine != generation { return }
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(with: outcome)
    }

    /// One call's work.
    private static func answer(
        _ keyword: String, client: AtgeoClient, dataset: String, collection: String?, region: KeywordRegion?
    ) async throws -> KeywordSearchResult {
        do {
            return try await client.searchByKeyword(keyword: keyword, dataset: dataset, collection: collection, region: region)
        } catch let error as AtgeoError where error.code == "KeywordRequired" {
            // As for a keyword the qualifying check skips, except that this one went out (contract §19).
            let grid: Double? = region == nil ? nil : 1
            return KeywordSearchResult(places: [], attribution: [], disclosed: Disclosure(keyword: true, region: grid))
        }
    }
}

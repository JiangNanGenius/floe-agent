// SPDX-License-Identifier: MPL-2.0
// FloeFileProvider — enumerators (S5 C4).
//
// * Every invocation finishes EXACTLY ONCE: one page of items followed by
//   finishEnumerating(upTo: nextPage) — or one change batch followed by
//   finishEnumeratingChanges(upTo: moreComing:) — and no callback is ever
//   invoked after the finish. The system re-invokes with the returned token
//   when more data remains, so a single invocation never loops internally.
// * `invalidate()` cancels the enumerator-owned task; a cancelled task never
//   touches its (now invalid) observer afterwards.
// * Folder enumerators use the store's keyset pagination: a mutation during
//   pagination can neither drop rows nor duplicate them, and every page is
//   delivered in stable (case-insensitive name, id) order. Cross-page drift
//   under concurrent rename/create/delete converges through the change
//   journal and container signals — the keyset is mutation-stable per page,
//   not a point-in-time snapshot, and this file makes no stronger claim.
// * The working-set enumerator answers changes from the journaled monotonic
//   sequence in batches split at the observer's suggested size; an anchor
//   below the retention floor (or from the future) finishes with
//   syncAnchorExpired so the system drops stale caches instead of trusting a
//   false clean diff. Deletes are published as tombstone identifiers.
// * Observers are framework-owned non-Sendable values; they are boxed and
//   invoked on the calling task exactly once per stage.

import Foundation
import FileProvider
import FloePersistence

final class SharedDocumentsFolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerID: String
    private let bridge: SharedDocumentsFileProviderBridge
    private var enumerationTask: Task<Void, Never>?

    init(containerID: String, bridge: SharedDocumentsFileProviderBridge) {
        self.containerID = containerID
        self.bridge = bridge
    }

    func invalidate() {
        // The framework guarantees no observer callbacks matter after
        // invalidation; cancelling the owned task guarantees we make none.
        enumerationTask?.cancel()
    }

    func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let observerBox = UnsafeSendableFileProviderBox(value: observer)
        let rawPage = page.rawValue as Data
        let initial = rawPage == (NSFileProviderPage.initialPageSortedByName as Data)
            || rawPage == (NSFileProviderPage.initialPageSortedByDate as Data)
        let cursor: Data? = initial ? nil : rawPage
        enumerationTask = Task { [bridge, containerID] in
            let observer = observerBox.value
            do {
                // ONE page per invocation; the next-page token hands the
                // remainder to the system's next call.
                let pageResult = try await bridge.childrenPage(
                    parentID: containerID,
                    cursorToken: cursor,
                    limit: SharedDocumentsStoreLayout.defaultPageSize
                )
                guard !Task.isCancelled else { return }
                if !pageResult.items.isEmpty {
                    observer.didEnumerate(pageResult.items)
                }
                guard !Task.isCancelled else { return }
                observer.finishEnumerating(upTo: pageResult.nextCursorToken.map(NSFileProviderPage.init(rawValue:)))
            } catch is CancellationError {
                // Invalidated mid-flight: the observer is no longer valid.
            } catch {
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingWithError(
                    SharedDocumentsFileProviderErrorMapper.map(error, identifier: nil)
                )
            }
        }
    }
}

final class SharedDocumentsWorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let bridge: SharedDocumentsFileProviderBridge
    private var enumerationTask: Task<Void, Never>?

    init(bridge: SharedDocumentsFileProviderBridge) {
        self.bridge = bridge
    }

    func invalidate() {
        enumerationTask?.cancel()
    }

    func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let observerBox = UnsafeSendableFileProviderBox(value: observer)
        let rawPage = page.rawValue as Data
        let initial = rawPage == (NSFileProviderPage.initialPageSortedByName as Data)
            || rawPage == (NSFileProviderPage.initialPageSortedByDate as Data)
        let cursor: Data? = initial ? nil : rawPage
        enumerationTask = Task { [bridge, cursor] in
            let observer = observerBox.value
            do {
                // The working set is "every live item", paged by the same
                // stable keyset order as folders; one page per invocation.
                let pageResult = try await bridge.workingSetPage(
                    cursorToken: cursor,
                    limit: SharedDocumentsStoreLayout.maxPageSize
                )
                guard !Task.isCancelled else { return }
                if !pageResult.items.isEmpty {
                    observer.didEnumerate(pageResult.items)
                }
                guard !Task.isCancelled else { return }
                observer.finishEnumerating(upTo: pageResult.nextCursorToken.map(NSFileProviderPage.init(rawValue:)))
            } catch is CancellationError {
                // Invalidated mid-flight: the observer is no longer valid.
            } catch {
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingWithError(
                    SharedDocumentsFileProviderErrorMapper.map(error, identifier: nil)
                )
            }
        }
    }

    func enumerateChanges(
        for observer: any NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let observerBox = UnsafeSendableFileProviderBox(value: observer)
        let rawAnchor = anchor.rawValue as Data
        enumerationTask = Task { [bridge, rawAnchor] in
            let observer = observerBox.value
            do {
                let suggested: Int? = observer.suggestedBatchSize
                let effectiveSuggested = suggested ?? 0
                let batchLimit = effectiveSuggested > 0
                    ? min(effectiveSuggested, SharedDocumentsStoreLayout.maxChangeBatch)
                    : SharedDocumentsStoreLayout.defaultChangeBatch
                // ONE batch per invocation, finished exactly once; when
                // moreComing is true the system re-invokes from the returned
                // anchor. No callback ever fires after the finish.
                let batch = try await bridge.changeBatch(anchor: rawAnchor, limit: batchLimit)
                guard !Task.isCancelled else { return }
                if !batch.updates.isEmpty {
                    observer.didUpdate(batch.updates)
                }
                if !batch.deletions.isEmpty {
                    observer.didDeleteItems(withIdentifiers: batch.deletions)
                }
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: batch.nextAnchor), moreComing: batch.more)
            } catch is CancellationError {
                // Invalidated mid-flight: the observer is no longer valid.
            } catch {
                guard !Task.isCancelled else { return }
                observer.finishEnumeratingWithError(
                    SharedDocumentsFileProviderErrorMapper.mapChangeEnumerationError(error)
                )
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completionBox = UnsafeSendableFileProviderBox(value: completionHandler)
        Task { [bridge] in
            guard let anchor = try? await bridge.currentAnchor() else {
                completionBox.value(nil)
                return
            }
            completionBox.value(NSFileProviderSyncAnchor(rawValue: anchor))
        }
    }
}

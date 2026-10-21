// SPDX-License-Identifier: MPL-2.0
// FloeFileProvider — replicated extension entry (S5 C4).
//
// `NSFileProviderReplicatedExtension` is available on the iOS 16+ SDK
// (FILEPROVIDER_API_AVAILABILITY_V3_IOS); this target's deployment is 26,
// so no runtime availability dance is needed. The extension is a thin shell:
// all policy lives in `SharedDocumentsFileProviderBridge` so the app test
// bundle can compile and exercise the identical source without hosting a
// FileProvider domain.
//
// Progress/callback contract: every method returns an NSProgress whose
// cancellation token feeds the store's chunk-boundary checks; each
// completion handler fires exactly once (SharedDocumentsCallOnce). The
// cancellation handler does not synthesize completions — the store answers
// cancellation promptly at the next boundary (including inside the
// committing SQL transaction) and the single completion path reports the
// real outcome (pre-commit cancel preserves prior bytes; a committed result
// is reported as committed, never rolled back fictionally). Committed
// mutations signal the affected containers (old/new parent + working set)
// through NSFileProviderManager.signalEnumerator so an active Files app sees
// them; signalling is advisory and idempotent and never rewrites the
// committed result.

import Foundation
import FileProvider
import FloePersistence
import os

final class FloeFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let bridge: SharedDocumentsFileProviderBridge
    private let unavailableError: NSError?

    init(domain: NSFileProviderDomain) {
        self.domain = domain
        let manager = NSFileProviderManager.managerForDomain(domain)
        let managerBox = UnsafeSendableFileProviderBox(value: manager)
        // Real post-commit enumeration signal. Fire-and-forget: a signal
        // failure is logged and dropped — the data is committed either way,
        // and signalling again after a retry is idempotent (no duplicates).
        let signalProvider: (@Sendable (SharedDocumentsSignalContainer) -> Void) = { container in
            guard let manager = managerBox.value else { return }
            let identifier: NSFileProviderItemIdentifier
            switch container.kind {
            case .workingSet:
                identifier = .workingSet
            case .root:
                identifier = .rootContainer
            case .item:
                identifier = NSFileProviderItemIdentifier(container.rawIdentifier)
            }
            manager.signalEnumerator(for: identifier) { error in
                if let error {
                    Logger(
                        subsystem: "org.floeagent.ios.fileprovider",
                        category: "shared-documents"
                    ).error("signalEnumerator failed for \(identifier.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        if let root = SharedDocumentsStoreLayout.backendRoot(),
           let store = try? SQLiteSharedDocumentsStore(root: root) {
            self.bridge = SharedDocumentsFileProviderBridge(
                store: store,
                domainIdentifier: domain.identifier.rawValue,
                signalProvider: signalProvider,
                materializationRootProvider: {
                    // The FileProvider per-domain temporary directory is on
                    // the same volume as the user-visible URL, so the system
                    // can clone the fetched bytes cheaply.
                    guard let manager = managerBox.value else {
                        throw SharedDocumentsError.storageCorrupted("file provider manager unavailable")
                    }
                    guard let url = try manager.temporaryDirectoryURL() else {
                        throw SharedDocumentsError.storageCorrupted("file provider temporary directory unavailable")
                    }
                    return url
                }
            )
            self.unavailableError = nil
        } else {
            // Honest degradation: without the App Group backend the provider
            // reports cannotSynchronize (surfaced as a retryable domain
            // error) instead of pretending empty success.
            self.bridge = SharedDocumentsFileProviderBridge(
                store: UnavailableSharedDocumentsStore(),
                domainIdentifier: domain.identifier.rawValue,
                signalProvider: signalProvider
            )
            self.unavailableError = NSError(
                domain: NSFileProviderErrorDomain,
                code: -2005, // NSFileProviderErrorCannotSynchronize
                userInfo: [
                    NSLocalizedDescriptionKey: "Shared Documents storage is unavailable in this process"
                ]
            )
        }
        super.init()
    }

    func invalidate() {
        // The store is process-scoped and cheap; nothing to release.
    }

    // MARK: Metadata / contents

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = makeProgress()
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        let once = SharedDocumentsCallOnce()
        let completion = UnsafeSendableFileProviderBox(value: completionHandler)
        Task { [bridge, unavailableError] in
            if let unavailableError {
                once.complete { completion.value(nil, unavailableError) }
                return
            }
            do {
                let item = try await bridge.item(for: identifier)
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                once.complete { completion.value(item, nil) }
            } catch {
                once.complete {
                    completion.value(nil, SharedDocumentsFileProviderErrorMapper.map(error, identifier: identifier))
                }
            }
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = makeProgress()
        let once = SharedDocumentsCallOnce()
        let cancellation = SharedDocumentsBridgeCancellation()
        progress.cancellationHandler = { cancellation.cancel() }
        let completion = UnsafeSendableFileProviderBox(value: completionHandler)
        let versionBox = UnsafeSendableFileProviderBox(value: requestedVersion)
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        Task { [bridge, unavailableError] in
            if let unavailableError {
                once.complete { completion.value(nil, nil, unavailableError) }
                return
            }
            do {
                let (url, item) = try await bridge.fetchContents(
                    for: itemIdentifier,
                    requestedVersion: versionBox.value,
                    cancellation: cancellation
                )
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                once.complete { completion.value(url, item, nil) }
            } catch {
                once.complete {
                    completion.value(nil, nil, SharedDocumentsFileProviderErrorMapper.map(error, identifier: itemIdentifier))
                }
            }
        }
        return progress
    }

    // MARK: Mutations

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = makeProgress(estimatedContentURL: url)
        let once = SharedDocumentsCallOnce()
        let cancellation = SharedDocumentsBridgeCancellation()
        progress.cancellationHandler = { cancellation.cancel() }
        let report = makeProgressReporter(progress: progress)
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        let completion = UnsafeSendableFileProviderBox(value: completionHandler)
        let template = UnsafeSendableFileProviderBox(value: itemTemplate)
        Task { [bridge, unavailableError] in
            if let unavailableError {
                once.complete { completion.value(nil, [], false, unavailableError) }
                return
            }
            do {
                let outcome = try await bridge.create(
                    basedOn: template.value,
                    fields: fields,
                    contents: url,
                    options: options,
                    cancellation: cancellation,
                    progress: report
                )
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                once.complete { completion.value(outcome.item, [], false, nil) }
            } catch {
                once.complete {
                    completion.value(
                        nil,
                        [],
                        false,
                        SharedDocumentsFileProviderErrorMapper.map(error, identifier: template.value.itemIdentifier)
                    )
                }
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = makeProgress(estimatedContentURL: newContents)
        let once = SharedDocumentsCallOnce()
        let cancellation = SharedDocumentsBridgeCancellation()
        progress.cancellationHandler = { cancellation.cancel() }
        let report = makeProgressReporter(progress: progress)
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        let completion = UnsafeSendableFileProviderBox(value: completionHandler)
        let itemBox = UnsafeSendableFileProviderBox(value: item)
        let versionBox = UnsafeSendableFileProviderBox(value: version)
        Task { [bridge, unavailableError] in
            if let unavailableError {
                once.complete { completion.value(nil, [], false, unavailableError) }
                return
            }
            do {
                let outcome = try await bridge.modify(
                    itemBox.value,
                    baseVersion: versionBox.value,
                    changedFields: changedFields,
                    contents: newContents,
                    options: options,
                    cancellation: cancellation,
                    progress: report
                )
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                once.complete {
                    completion.value(outcome.item, outcome.stillPending, outcome.shouldFetchContent, nil)
                }
            } catch {
                once.complete {
                    completion.value(
                        nil,
                        [],
                        false,
                        SharedDocumentsFileProviderErrorMapper.map(error, identifier: itemBox.value.itemIdentifier)
                    )
                }
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = makeProgress()
        let once = SharedDocumentsCallOnce()
        let cancellation = SharedDocumentsBridgeCancellation()
        progress.cancellationHandler = { cancellation.cancel() }
        let completion = UnsafeSendableFileProviderBox(value: completionHandler)
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        Task { [bridge, unavailableError] in
            if let unavailableError {
                once.complete { completion.value(unavailableError) }
                return
            }
            do {
                try await bridge.delete(
                    identifier: identifier,
                    baseVersion: version,
                    options: options,
                    cancellation: cancellation
                )
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                once.complete { completion.value(nil) }
            } catch {
                once.complete {
                    completion.value(SharedDocumentsFileProviderErrorMapper.map(error, identifier: identifier))
                }
            }
        }
        return progress
    }

    // MARK: Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if let unavailableError {
            throw unavailableError
        }
        if containerItemIdentifier == .trashContainer {
            // Trash is not advertised by this provider; the system falls
            // back to a permanent delete (deleteItem), which we support.
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        if containerItemIdentifier == .workingSet {
            return SharedDocumentsWorkingSetEnumerator(bridge: bridge)
        }
        let id = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: containerItemIdentifier)
        return SharedDocumentsFolderEnumerator(containerID: id, bridge: bridge)
    }

    // MARK: Helpers

    private func makeProgress(estimatedContentURL: URL? = nil) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if let estimatedContentURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: estimatedContentURL.path),
           let size = attributes[.size] as? Int64, size > 0 {
            progress.totalUnitCount = size
        }
        return progress
    }

    private func makeProgressReporter(progress: Progress) -> (@Sendable (Int64) -> Void) {
        let progressBox = UnsafeSendableFileProviderBox(value: progress)
        return { completed in
            let progress = progressBox.value
            progress.completedUnitCount = min(max(completed, 0), progress.totalUnitCount)
        }
    }
}

/// Failing store used when the App Group backend cannot be opened in the
/// extension process. Every operation throws; nothing pretends success.
private struct UnavailableSharedDocumentsStore: SharedDocumentsStore {
    private func unavailable() -> SharedDocumentsError {
        .storageCorrupted("shared documents backend unavailable")
    }

    func item(id: String) async throws -> SharedDocumentsItem { throw unavailable() }
    func item(parentID: String, name: String) async throws -> SharedDocumentsItem? { throw unavailable() }
    func committedContentURL(id: String) async throws -> URL? { throw unavailable() }
    func children(parentID: String, cursorToken: Data?, limit: Int) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?) { throw unavailable() }
    func allItems(cursorToken: Data?, limit: Int) async throws -> (items: [SharedDocumentsItem], nextCursorToken: Data?) { throw unavailable() }
    func allLiveItems() async throws -> [SharedDocumentsItem] { throw unavailable() }
    func beginContentStage(cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> UUID { throw unavailable() }
    func writeContent(_ data: Data, operationID: UUID, cancellation: (any SharedDocumentsOperationCancellation)?) async throws { throw unavailable() }
    func finishContentStage(operationID: UUID, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsContentStage { throw unavailable() }
    func discardContentStage(operationID: UUID) async throws { throw unavailable() }
    func stageContentFromURL(
        _ sourceURL: URL,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> SharedDocumentsContentStage { throw unavailable() }
    func commitCreate(parentID: String, name: String, kind: SharedDocumentsItemKind, stage: SharedDocumentsContentStage?, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsItem { throw unavailable() }
    func commitReplace(id: String, stage: SharedDocumentsContentStage, expected: SharedDocumentsExpectedVersions, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsItem { throw unavailable() }
    func commitMetadata(id: String, newName: String?, newParentID: String?, expected: SharedDocumentsExpectedVersions, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsItem { throw unavailable() }
    func commitModify(id: String, newName: String?, newParentID: String?, stage: SharedDocumentsContentStage, expected: SharedDocumentsExpectedVersions, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsItem { throw unavailable() }
    func commitDelete(id: String, expected: SharedDocumentsExpectedVersions, recursive: Bool, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> (deletedIDs: [String], byteCount: Int64) { throw unavailable() }
    func restoreContent(id: String, targetContentVersion: Int, expected: SharedDocumentsExpectedVersions, cancellation: (any SharedDocumentsOperationCancellation)?) async throws -> SharedDocumentsItem { throw unavailable() }
    func withLeasedContentSnapshot<T: Sendable>(
        id: String,
        cancellation: (any SharedDocumentsOperationCancellation)?,
        // Match the imported Persistence contract without changing this
        // extension target's default executor behavior for unrelated tasks.
        _ body: nonisolated(nonsending) @Sendable (SharedDocumentsLeasedContentSnapshot) async throws -> T
    ) async throws -> T { throw unavailable() }
    func currentAnchor() async throws -> Data { throw unavailable() }
    func changes(anchor: Data, limit: Int) async throws -> (changes: [SharedDocumentsChange], nextAnchor: Data, more: Bool) { throw unavailable() }
    func pruneChanges(olderThan cutoff: Date) async throws -> Int { throw unavailable() }
    func anchorExpiryFloor() async throws -> Int { throw unavailable() }
    func recoverInterruptedOperations() async throws -> SharedDocumentsRecoveryReport { throw unavailable() }
    func close() async throws { throw unavailable() }
}

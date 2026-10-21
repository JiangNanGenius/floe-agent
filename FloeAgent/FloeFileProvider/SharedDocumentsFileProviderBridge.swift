// SPDX-License-Identifier: MPL-2.0
// FloeFileProvider — replicated-extension bridge (S5 C4).
//
// Owns every policy decision between the FileProvider framework and the
// authoritative `SharedDocumentsStore`:
//
// * Identifier mapping is validated in both directions; the root container
//   is the only virtual identity. Trash and packages are NOT advertised:
//   trash enumeration reports NSFeatureUnsupportedError (Files then offers a
//   permanent delete, which this provider supports), and package/symlink/
//   alias templates fail with cannotSynchronize instead of being silently
//   flattened.
// * create/modify/delete verify the exact item identity and expected base
//   versions. Unknown creates never blind-rename: name collisions surface as
//   real `filenameCollision` errors carrying the committed colliding item.
//   A combined name/parent/content modify commits in ONE store transaction
//   (the extension plist advertises atomic changes); a partial commit is
//   never reported as success, and a failure leaves the prior committed
//   bytes/name/versions untouched.
// * Base versions are decoded against the real SDK contract:
//   `beforeFirstSyncComponent` on both components means "never synced" and
//   the mutation applies against the committed CAS base (any concurrent
//   writer still fails closed via versionConflict). Anything else that is
//   not one of our `c<n>.m<n>` tokens is malformed and fails closed — a
//   corrupt version can never grant a blind overwrite.
// * Cancellation is checked at every staged chunk, at commit admission and
//   inside the committing SQL transaction; a pre-commit cancel preserves the
//   prior bytes/version, a post-commit reality is reported as committed
//   (never a fake rollback). Every framework callback fires exactly once.
// * fetchContents runs a leased snapshot: the store pairs the exact item
//   with the exact byte URL in one read and holds the per-item lease across
//   the streamed copy + digest, so replace/delete/recovery cannot race byte
//   deletion. The copied temp file is owned and removed on failure/cancel.
// * Committed mutations signal the affected containers (old/new parent +
//   working set) through the `signalProvider` seam so an active Files app
//   sees committed changes. Signalling is advisory and idempotent: a signal
//   failure never rewrites the committed result, and retrying a committed
//   mutation never duplicates data.
// * Working-set changes come from the journaled monotonic sequence; one
//   batch collapses same-ID rows to their coherent final state (an item
//   inserted and deleted inside one batch is invisible; later rows win),
//   and an anchor below the retention floor finishes with
//   syncAnchorExpired — never a false clean diff.

import Foundation
import FileProvider
import UniformTypeIdentifiers
import FloeCore
import FloePersistence
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Concurrency shims

/// Completion handlers supplied by the FileProvider framework are not
/// declared Sendable; they are invoked exactly once under the call-once
/// lock, so passing them across the task boundary is manually verified.
struct UnsafeSendableFileProviderBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Thread-safe exactly-once completion gate.
final class SharedDocumentsCallOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    /// Runs `body` only for the first caller; later calls are dropped.
    func complete(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        body()
    }
}

/// Cancellation token shared between the returned NSProgress and the store.
public final class SharedDocumentsBridgeCancellation: SharedDocumentsOperationCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - Bridge errors (pre-mapped context the error mapper needs)

enum SharedDocumentsBridgeError: Error {
    /// A create/modify hit a committed item at the target location; the
    /// system resolves the bounce or merges.
    case collision(existing: SharedDocumentsItem)
    /// A delete was rejected because the committed versions moved on.
    case rejectedDeletion(existing: SharedDocumentsItem)
    /// The system's base version was neither `beforeFirstSyncComponent` nor
    /// one of our `c<n>.m<n>` tokens. Failing closed: the mutation is
    /// refused rather than applied against an unknown base.
    case malformedBaseVersion
}

/// SDK-accurate reading of the base version handed back by the system.
enum SharedDocumentsBaseVersion: Sendable, Equatable {
    /// Both components are `NSFileProviderItemVersion.beforeFirstSyncComponent`:
    /// the system never synced this item, so there is no base to conflict
    /// with. The mutation applies against the committed CAS base, which still
    /// fails closed when a concurrent writer moved the item.
    case beforeFirstSync
    /// One component carries our exact `c<n>.m<n>` token.
    case exact(SharedDocumentsExpectedVersions)
    /// Not before-first-sync and not ours: corrupt or foreign data.
    case malformed
}

// MARK: - Bridge

/// Stateless, Sendable adapter over the store actor.
final class SharedDocumentsFileProviderBridge: Sendable {
    let store: any SharedDocumentsStore
    let domainIdentifier: String
    /// Advisory post-commit enumeration signals (real
    /// `NSFileProviderManager.signalEnumerator` in the extension; a recorder
    /// in tests). Fire-and-forget: a signal failure never rewrites the
    /// committed result.
    let signalProvider: (@Sendable (SharedDocumentsSignalContainer) -> Void)?
    /// Directory the extension materializes fetched content into (the
    /// FileProvider per-domain temporary directory, so the system can clone
    /// the bytes onto its volume). Injected for prepared tests.
    let materializationRootProvider: @Sendable () throws -> URL

    init(
        store: any SharedDocumentsStore,
        domainIdentifier: String = SharedDocumentsIdentity.domainIdentifier,
        signalProvider: (@Sendable (SharedDocumentsSignalContainer) -> Void)? = nil,
        materializationRootProvider: @escaping @Sendable () throws -> URL = {
            FileManager.default.temporaryDirectory
        }
    ) {
        self.store = store
        self.domainIdentifier = domainIdentifier
        self.signalProvider = signalProvider
        self.materializationRootProvider = materializationRootProvider
    }

    private func signal(_ containers: [SharedDocumentsSignalContainer]) {
        guard let signalProvider else { return }
        for container in containers {
            signalProvider(container)
        }
    }

    // MARK: item / fetch

    func item(for identifier: NSFileProviderItemIdentifier) async throws -> SharedDocumentsFileProviderItem {
        let id = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: identifier)
        let stored = try await store.item(id: id)
        return SharedDocumentsFileProviderItem(item: stored)
    }

    func fetchContents(
        for identifier: NSFileProviderItemIdentifier,
        requestedVersion: NSFileProviderItemVersion?,
        cancellation: SharedDocumentsBridgeCancellation? = nil
    ) async throws -> (URL, SharedDocumentsFileProviderItem) {
        let id = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: identifier)
        // Local-only authority: the committed bytes are the answer, paired
        // with their exact immutable version+metadata under the per-item
        // lease. `requestedVersion` is currently always nil (documented in
        // the SDK); a stale requested version never triggers pretend-remote
        // recovery. The Sendable value crossing the lease boundary is the
        // store's item struct; the NSFileProviderItem wrapper is built on
        // this side.
        let (url, stored) = try await store.withLeasedContentSnapshot(id: id, cancellation: cancellation) { snapshot in
            let base: URL
            do {
                base = try self.materializationRootProvider()
            } catch {
                throw SharedDocumentsError.storageCorrupted("materialization directory unavailable")
            }
            let destination = base.appendingPathComponent(
                "\(id)-v\(snapshot.contentVersion)-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try await SharedDocumentsStreamedIO.copyRegularFile(
                    snapshot.contentURL,
                    to: destination,
                    cancellation: cancellation
                )
                let digest = try FloeDigest.sha256Hex(
                    ofFileAt: destination,
                    isCancelled: { cancellation?.isCancelled() == true }
                )
                guard digest == snapshot.sha256 else {
                    throw SharedDocumentsError.contentDigestMismatch(
                        expected: snapshot.sha256 ?? "unknown",
                        actual: digest
                    )
                }
                return (destination, snapshot.item)
            } catch let error as CancellationError {
                try? FileManager.default.removeItem(at: destination)
                throw SharedDocumentsError.cancelled
            } catch {
                // The destination is owned temp storage: never leak a
                // partial copy after a failure or cancellation.
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        return (url, SharedDocumentsFileProviderItem(item: stored))
    }

    // MARK: create

    struct CreateOutcome {
        /// nil means "refused without error" (dataless re-import with no
        /// match): the system deletes the on-disk source.
        var item: SharedDocumentsFileProviderItem?
    }

    func create(
        basedOn template: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        cancellation: SharedDocumentsBridgeCancellation,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> CreateOutcome {
        let parentID = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: template.parentItemIdentifier)
        let name = template.filename
        // The ObjC protocol permits iOS templates to supply either the modern
        // UTType or the legacy UTI. Unknown types cannot silently become files.
        guard let type = template.contentType ?? template.typeIdentifier.flatMap({ UTType($0) }) else {
            throw SharedDocumentsError.specialFileRefused
        }
        let kind: SharedDocumentsItemKind = type.conforms(to: .folder) ? .folder : .file

        // Declared support: folders and regular files only.
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) || type.conforms(to: .package) {
            throw SharedDocumentsError.specialFileRefused
        }
        if fields.contains(.filename) == false, name.isEmpty {
            throw SharedDocumentsError.invalidName(name)
        }

        let existing = try? await store.item(parentID: parentID, name: name)
        if let existing, options.contains(.mayAlreadyExist) {
            // Idempotent re-import: same name and (when content is present)
            // identical size+digest means the disk item IS the committed
            // item. A digest mismatch is a real collision, not a match.
            if kind == .folder || url == nil {
                return CreateOutcome(item: SharedDocumentsFileProviderItem(item: existing))
            }
            let stage = try await stageContents(of: url!, cancellation: cancellation, progress: progress)
            if stage.byteCount == existing.byteCount {
                let stagedDigest = stage.sha256
                if stagedDigest == existing.sha256 {
                    try? await store.discardContentStage(operationID: stage.operationID)
                    return CreateOutcome(item: SharedDocumentsFileProviderItem(item: existing))
                }
            }
            try? await store.discardContentStage(operationID: stage.operationID)
            throw SharedDocumentsBridgeError.collision(existing: existing)
        }
        if let existing {
            throw SharedDocumentsBridgeError.collision(existing: existing)
        }

        switch kind {
        case .folder:
            let created = try await store.commitCreate(
                parentID: parentID,
                name: name,
                kind: .folder,
                stage: nil,
                cancellation: cancellation
            )
            signal([.item(parentID), .workingSet])
            return CreateOutcome(item: SharedDocumentsFileProviderItem(item: created))
        case .file:
            guard let url else {
                // Dataless re-import without a match: refuse without error so
                // the system removes the dataless source.
                return CreateOutcome(item: nil)
            }
            let stage = try await stageContents(of: url, cancellation: cancellation, progress: progress)
            do {
                let created = try await store.commitCreate(
                    parentID: parentID,
                    name: name,
                    kind: .file,
                    stage: stage,
                    cancellation: cancellation
                )
                signal([.item(parentID), .workingSet])
                return CreateOutcome(item: SharedDocumentsFileProviderItem(item: created))
            } catch {
                // Staged bytes are ours; never leak them after a failed commit.
                try? await store.discardContentStage(operationID: stage.operationID)
                throw error
            }
        }
    }

    // MARK: modify

    struct ModifyOutcome {
        /// nil asks the system to delete the on-disk item.
        var item: SharedDocumentsFileProviderItem?
        var stillPending: NSFileProviderItemFields
        var shouldFetchContent: Bool
    }

    private static let supportedModifyFields: NSFileProviderItemFields = [
        .contents,
        .filename,
        .parentItemIdentifier,
        .contentModificationDate,
    ]

    func modify(
        _ item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderModifyItemOptions,
        cancellation: SharedDocumentsBridgeCancellation,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> ModifyOutcome {
        let id = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: item.itemIdentifier)
        let current = try await store.item(id: id)
        let base = Self.decodeBaseVersion(baseVersion)
        let pending = changedFields.subtracting(Self.supportedModifyFields)
        var stillPending = pending
        let committedBase = SharedDocumentsExpectedVersions(
            content: current.contentVersion,
            metadata: current.metadataVersion
        )

        switch base {
        case .malformed:
            // A corrupt or foreign base version can never grant a write.
            throw SharedDocumentsBridgeError.malformedBaseVersion
        case .beforeFirstSync:
            // The system never synced this item: apply against the committed
            // CAS base; a concurrent writer still fails closed below.
            break
        case .exact(let base):
            if base != committedBase {
                // The disk copy was stale. We are the server: reconcile to
                // the committed state and let the system re-fetch if content
                // moved.
                if options.contains(.failOnConflict) {
                    throw SharedDocumentsBridgeError.collision(existing: current)
                }
                return ModifyOutcome(
                    item: SharedDocumentsFileProviderItem(item: current),
                    stillPending: pending,
                    shouldFetchContent: base.content != current.contentVersion
                )
            }
        }

        var working = current
        let wantsName = changedFields.contains(.filename)
        let wantsParent = changedFields.contains(.parentItemIdentifier)
        let wantsContent = changedFields.contains(.contents)
        // Stage FIRST (before any commit): a cancelled or failed stage leaves
        // the store untouched, and a combined modify then commits metadata +
        // content in ONE transaction.
        var stage: SharedDocumentsContentStage?
        if wantsContent {
            if let url {
                stage = try await stageContents(of: url, cancellation: cancellation, progress: progress)
            } else {
                // Content change requested without bytes: report it pending
                // and commit only the metadata subset.
                stillPending.insert(.contents)
            }
        }

        do {
            if wantsParent {
                // Trash is not advertised; reparenting to the trash container
                // is refused as unsupported rather than silently re-homed.
                if item.parentItemIdentifier == .trashContainer {
                    throw SharedDocumentsError.specialFileRefused
                }
            }
            let newParent = wantsParent
                ? try SharedDocumentsFileProviderIdentity.storeIdentifier(for: item.parentItemIdentifier)
                : nil
            if (wantsName || wantsParent), let stage {
                // ONE combined CAS transaction: name/parent move and content
                // replace commit together (the plist advertises atomic
                // changes), with the prior bytes/name/versions preserved on
                // any failure.
                working = try await store.commitModify(
                    id: id,
                    newName: wantsName ? item.filename : nil,
                    newParentID: newParent,
                    stage: stage,
                    expected: working.versions,
                    cancellation: cancellation
                )
            } else if wantsName || wantsParent {
                working = try await store.commitMetadata(
                    id: id,
                    newName: wantsName ? item.filename : nil,
                    newParentID: newParent,
                    expected: working.versions,
                    cancellation: cancellation
                )
            } else if let stage {
                working = try await store.commitReplace(
                    id: id,
                    stage: stage,
                    expected: working.versions,
                    cancellation: cancellation
                )
            }
        } catch {
            if let stage {
                try? await store.discardContentStage(operationID: stage.operationID)
            }
            throw error
        }

        let newParentID = wantsParent
            ? try? SharedDocumentsFileProviderIdentity.storeIdentifier(for: item.parentItemIdentifier)
            : nil
        var containers: [SharedDocumentsSignalContainer] = []
        if let newParentID, newParentID != current.parentID {
            containers.append(.item(current.parentID))
            containers.append(.item(newParentID))
        } else {
            containers.append(.item(current.parentID))
        }
        containers.append(.workingSet)
        signal(containers)

        return ModifyOutcome(
            item: SharedDocumentsFileProviderItem(item: working),
            stillPending: stillPending,
            shouldFetchContent: false
        )
    }

    // MARK: delete

    struct DeleteOutcome {
        var deletedIDs: [String]
    }

    func delete(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        cancellation: SharedDocumentsBridgeCancellation
    ) async throws -> DeleteOutcome {
        let id = try SharedDocumentsFileProviderIdentity.storeIdentifier(for: identifier)
        if cancellation.isCancelled() { throw SharedDocumentsError.cancelled }
        let current: SharedDocumentsItem
        do {
            current = try await store.item(id: id)
        } catch SharedDocumentsError.itemNotFound {
            // Only a true itemNotFound maps to absence (success, nothing
            // deleted); storage/read errors propagate as real failures.
            return DeleteOutcome(deletedIDs: [])
        }
        switch Self.decodeBaseVersion(baseVersion) {
        case .malformed:
            // Refuse: an unverifiable base must not authorize a delete.
            throw SharedDocumentsBridgeError.malformedBaseVersion
        case .beforeFirstSync:
            // Never synced: delete by identity with the committed CAS base.
            break
        case .exact(let base):
            if base != SharedDocumentsExpectedVersions(
                content: current.contentVersion,
                metadata: current.metadataVersion
            ) {
                throw SharedDocumentsBridgeError.rejectedDeletion(existing: current)
            }
        }
        let result = try await store.commitDelete(
            id: id,
            expected: current.versions,
            recursive: options.contains(.recursive),
            cancellation: cancellation
        )
        signal([.item(current.parentID), .workingSet])
        return DeleteOutcome(deletedIDs: result.deletedIDs)
    }

    // MARK: enumeration

    func childrenPage(
        parentID: String,
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsFileProviderItem], nextCursorToken: Data?) {
        let page = try await store.children(parentID: parentID, cursorToken: cursorToken, limit: limit)
        return (page.items.map { SharedDocumentsFileProviderItem(item: $0) }, page.nextCursorToken)
    }

    func workingSetPage(
        cursorToken: Data?,
        limit: Int
    ) async throws -> (items: [SharedDocumentsFileProviderItem], nextCursorToken: Data?) {
        let page = try await store.allItems(cursorToken: cursorToken, limit: limit)
        return (page.items.map { SharedDocumentsFileProviderItem(item: $0) }, page.nextCursorToken)
    }

    /// Collapses one journal batch to a coherent per-ID final state: the
    /// LAST row for an identifier wins; an item inserted and deleted inside
    /// the same batch is invisible to the system (it never saw either); an
    /// update followed by a delete publishes only the deletion. Intermediate
    /// rename churn inside one batch never reaches Files as duplicate or
    /// contradictory callbacks.
    func changeBatch(
        anchor: Data,
        limit: Int
    ) async throws -> (updates: [SharedDocumentsFileProviderItem], deletions: [NSFileProviderItemIdentifier], nextAnchor: Data, more: Bool) {
        let batch = try await store.changes(anchor: anchor, limit: limit)
        var order: [String] = []
        var sawInsert: Set<String> = []
        var finalByID: [String: SharedDocumentsChange] = [:]
        for change in batch.changes {
            if finalByID[change.itemID] == nil { order.append(change.itemID) }
            if change.kind == .insert { sawInsert.insert(change.itemID) }
            finalByID[change.itemID] = change
        }
        var updates: [SharedDocumentsFileProviderItem] = []
        var deletions: [NSFileProviderItemIdentifier] = []
        for id in order {
            guard let change = finalByID[id] else { continue }
            if change.kind == .delete {
                if sawInsert.contains(id) { continue }
                deletions.append(
                    SharedDocumentsFileProviderIdentity.providerIdentifier(for: id)
                )
            } else {
                updates.append(SharedDocumentsFileProviderItem(item: change.item))
            }
        }
        return (updates, deletions, batch.nextAnchor, batch.more)
    }

    func currentAnchor() async throws -> Data {
        try await store.currentAnchor()
    }

    // MARK: staging

    /// Streams a system-provided content file into the store's leased
    /// staging area with bounded buffers, verifying it is a regular file
    /// (never a symlink/special file) and within the size ceiling. The real
    /// streaming implementation is the store's `stageContentFromURL`, shared
    /// with the app export path — one implementation, not per-caller loops.
    func stageContents(
        of url: URL,
        cancellation: SharedDocumentsBridgeCancellation,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws -> SharedDocumentsContentStage {
        try await store.stageContentFromURL(url, cancellation: cancellation, progress: progress)
    }

    // MARK: version decoding

    /// SDK-accurate decoder for the base version the system hands back.
    /// beforeFirstSync (verified against the real
    /// `NSFileProviderItemVersion.beforeFirstSyncComponent` header contract)
    /// is distinct from malformed: the former applies against the committed
    /// CAS base, the latter fails closed.
    static func decodeBaseVersion(_ version: NSFileProviderItemVersion) -> SharedDocumentsBaseVersion {
        let beforeFirstSync = NSFileProviderItemVersion.beforeFirstSyncComponent
        if version.contentVersion == beforeFirstSync, version.metadataVersion == beforeFirstSync {
            return .beforeFirstSync
        }
        for component in [version.contentVersion, version.metadataVersion] {
            if let decoded = decodeVersionComponent(component) {
                return .exact(decoded)
            }
        }
        return .malformed
    }

    static func decodeVersionComponent(_ data: Data) -> SharedDocumentsExpectedVersions? {
        guard data != NSFileProviderItemVersion.beforeFirstSyncComponent,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("c"),
              let separator = text.firstIndex(of: "m")
        else {
            return nil
        }
        let contentText = text[text.index(after: text.startIndex)..<separator]
        let metadataText = text[text.index(after: separator)...]
        guard let content = Int(contentText), let metadata = Int(metadataText) else { return nil }
        return SharedDocumentsExpectedVersions(content: content, metadata: metadata)
    }
}

// MARK: - Error mapping

enum SharedDocumentsFileProviderErrorMapper {
    // NSFileProviderErrorDomain codes, from <FileProvider/NSFileProviderError.h>.
    // Spelled as integers to stay independent of NS_ERROR_ENUM import shape.
    private static let codeCannotSynchronize = -2005
    private static let codeSyncAnchorExpired = -1002
    private static let codeDirectoryNotEmpty = -1007
    private static let codeDeletionRejected = -1006

    static func map(
        _ error: Error,
        identifier: NSFileProviderItemIdentifier?
    ) -> NSError {
        if let bridgeError = error as? SharedDocumentsBridgeError {
            switch bridgeError {
            case .collision(let existing):
                return NSError.fileProviderErrorForCollision(
                    with: SharedDocumentsFileProviderItem(item: existing)
                )
            case .rejectedDeletion(let existing):
                return NSError.fileProviderErrorForRejectedDeletion(
                    of: SharedDocumentsFileProviderItem(item: existing)
                )
            case .malformedBaseVersion:
                // Retryable, not a conflict: the truth is intact and the
                // system may re-issue with a real base version.
                return cannotSynchronize(underlying: bridgeError)
            }
        }
        guard let error = error as? SharedDocumentsError else {
            return cannotSynchronize(underlying: error)
        }
        switch error {
        case .cancelled:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        case .itemNotFound, .parentNotFound:
            let id = identifier ?? .rootContainer
            return NSError.fileProviderErrorForNonExistentItem(withIdentifier: id)
        case .folderNotEmpty:
            return NSError(domain: NSFileProviderErrorDomain, code: codeDirectoryNotEmpty)
        case .deleteLimitExceeded:
            // Bounded recursive delete refused by policy; the system
            // re-creates from the working set metadata.
            return NSError(domain: NSFileProviderErrorDomain, code: codeDeletionRejected)
        case .invalidCursor:
            return NSError(domain: NSFileProviderErrorDomain, code: codeSyncAnchorExpired)
        case .versionConflict, .invalidName, .invalidItemID, .parentNotAFolder,
             .nameCollision, .contentDigestMismatch, .contentTooLarge,
             .specialFileRefused, .storageCorrupted:
            return cannotSynchronize(underlying: error)
        }
    }

    static func mapChangeEnumerationError(_ error: Error) -> NSError {
        if let error = error as? SharedDocumentsError, error == .invalidCursor {
            return NSError(domain: NSFileProviderErrorDomain, code: codeSyncAnchorExpired)
        }
        return map(error, identifier: nil)
    }

    private static func cannotSynchronize(underlying: Error) -> NSError {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: codeCannotSynchronize,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
    }
}

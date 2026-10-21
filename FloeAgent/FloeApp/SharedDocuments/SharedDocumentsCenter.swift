// SPDX-License-Identifier: MPL-2.0
// FloeApp — Shared Documents center (S5 C4 app integration).
//
// App-owned entry point for the local Files provider location:
//
// * `registerDomainIfNeeded()` reconciles exactly ONE stable domain
//   ("shared-documents") via `NSFileProviderManager.getDomains`/`addDomain`.
//   It never removes or re-registers other domains and never claims the
//   location is mounted: registration success only means the system accepted
//   the domain; actual Files visibility is answered separately by
//   `userVisibleRootURL()` (nil until the system materializes the root).
// * `exportFile(sourceURL:name:)` streams an already-produced file (from the
//   existing export/share flows) into the store through the same leased
//   staging + CAS commit path the extension uses. It never touches the task
//   database, credentials, ShareInbox, or Notes/Canvas editor state, and it
//   does not fabricate receipts: the receipt carries the committed versions,
//   byte count and digest, or the call throws.
// * Opening a document from this location stays on the existing importer
//   pipeline; this center performs no task/model auto-run from payloads.

#if canImport(UIKit)
import Foundation
import FileProvider
import FloeCore
import FloePersistence

// MARK: - Errors

enum SharedDocumentsCenterError: Error, Sendable, Equatable, LocalizedError {
    case appGroupMissing
    case storeOpenFailed(String)
    case sourceUnreadable
    case exportFailed(String)
    case domainUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appGroupMissing:
            return SharedDocumentsCopy.appGroupMissingMessage
        case .storeOpenFailed(let detail):
            return SharedDocumentsCopy.storeOpenFailedMessage(detail)
        case .sourceUnreadable:
            return SharedDocumentsCopy.exportFailedMessage(
                SharedDocumentsCenterError.isChinese ? "源文件不可读" : "the source file is unreadable"
            )
        case .exportFailed(let detail):
            return SharedDocumentsCopy.exportFailedMessage(detail)
        case .domainUnavailable(let detail):
            return SharedDocumentsCopy.exportFailedMessage(detail)
        }
    }

    private static var isChinese: Bool {
        Locale.current.language.languageCode?.identifier.hasPrefix("zh") == true
    }
}

// MARK: - State / receipt

enum SharedDocumentsDomainState: Sendable, Equatable {
    /// Not yet reconciled this launch.
    case unknown
    /// Domain present in the system list. NOT a mount claim.
    case registered
    /// Actionable failure (storage missing, system error, ...).
    case failed(String)
}

struct SharedDocumentsExportReceipt: Sendable, Equatable {
    var name: String
    var itemID: String
    var contentVersion: Int
    var byteCount: Int64
    var sha256: String
}

// MARK: - Center

@MainActor
final class SharedDocumentsCenter: ObservableObject {
    static let shared = SharedDocumentsCenter()

    @Published private(set) var domainState: SharedDocumentsDomainState = .unknown

    private let store: (any SharedDocumentsStore)?
    private let storeError: SharedDocumentsCenterError?
    private var registrationTask: Task<Void, Never>?

    /// Test seam for post-commit enumeration signals. The default sends real
    /// `NSFileProviderManager.signalEnumerator` calls for the stable domain;
    /// prepared tests inject a recorder instead. Signalling is advisory: a
    /// failure never changes the committed export result.
    var signalProvider: (@Sendable (SharedDocumentsSignalContainer) -> Void)?

    init(signalProvider: (@Sendable (SharedDocumentsSignalContainer) -> Void)? = nil) {
        self.signalProvider = signalProvider
        if let root = SharedDocumentsStoreLayout.backendRoot() {
            do {
                self.store = try SQLiteSharedDocumentsStore(root: root)
                self.storeError = nil
            } catch {
                self.store = nil
                self.storeError = .storeOpenFailed(String(describing: error))
            }
        } else {
            self.store = nil
            self.storeError = .appGroupMissing
        }
    }

    private func signal(_ containers: [SharedDocumentsSignalContainer]) {
        let provider = signalProvider ?? Self.defaultSignalProvider
        for container in containers {
            provider(container)
        }
    }

    /// Advisory re-enumeration of the affected containers after a committed
    /// mutation. Fire-and-forget: a failed signal is logged by the closure
    /// and dropped — committed bytes stay committed, and a retried export
    /// signals again without duplicating data.
    private static let defaultSignalProvider: @Sendable (SharedDocumentsSignalContainer) -> Void = { container in
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(SharedDocumentsIdentity.domainIdentifier),
            displayName: SharedDocumentsCopy.locationName
        )
        guard let manager = NSFileProviderManager.managerForDomain(domain) else { return }
        let identifier: NSFileProviderItemIdentifier
        switch container.kind {
        case .workingSet:
            identifier = .workingSet
        case .root:
            identifier = .rootContainer
        case .item:
            identifier = NSFileProviderItemIdentifier(container.rawIdentifier)
        }
        manager.signalEnumerator(for: identifier) { _ in
            // Advisory: the export is committed regardless of signal result.
        }
    }

    /// Reconciles only the stable own domain. Never erases, removes, or
    /// re-registers other domains or user data.
    func start() {
        guard registrationTask == nil else { return }
        registrationTask = Task { [weak self] in
            guard let self else { return }
            defer { registrationTask = nil }
            do {
                let report = try await recoverInterruptedOperations()
                guard report.missingContentItemIDs.isEmpty else {
                    domainState = .failed(SharedDocumentsCopy.registrationFailedMessage)
                    return
                }
                await reconcileDomain()
            } catch {
                domainState = .failed(SharedDocumentsCopy.registrationFailedMessage)
            }
        }
    }

    func registerDomainIfNeeded() async {
        start()
        await registrationTask?.value
    }

    private func reconcileDomain() async {
        if let storeError {
            domainState = .failed(storeError.localizedDescription)
            return
        }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(SharedDocumentsIdentity.domainIdentifier),
            displayName: SharedDocumentsCopy.locationName
        )
        do {
            let existing = try await Self.domains()
            if existing.contains(where: { $0.identifier == domain.identifier }) {
                domainState = .registered
                return
            }
            try await Self.addDomain(domain)
            domainState = .registered
        } catch {
            domainState = .failed(String(describing: error))
        }
    }

    /// Truthful mount signal: non-nil only when the system can hand back a
    /// user-visible URL for the domain root.
    func userVisibleRootURL() async -> URL? {
        guard domainState == .registered else { return nil }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(SharedDocumentsIdentity.domainIdentifier),
            displayName: SharedDocumentsCopy.locationName
        )
        guard let manager = NSFileProviderManager.managerForDomain(domain) else { return nil }
        return await withCheckedContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// Streams a produced file into the Shared Documents root. The caller
    /// keeps ownership of the source URL; bytes are staged by the store
    /// (bounded streaming on the store actor — never a MainActor copy loop)
    /// and committed with digest verification.
    @discardableResult
    func exportFile(
        sourceURL: URL,
        name: String,
        cancellation: (any SharedDocumentsOperationCancellation)? = nil
    ) async throws -> SharedDocumentsExportReceipt {
        guard let store else {
            throw storeError ?? SharedDocumentsCenterError.storeOpenFailed("uninitialized")
        }
        guard Self.isReadableRegularFile(sourceURL) else {
            throw SharedDocumentsCenterError.sourceUnreadable
        }
        let stage: SharedDocumentsContentStage
        do {
            stage = try await store.stageContentFromURL(sourceURL, cancellation: cancellation, progress: nil)
        } catch let error as SharedDocumentsError {
            throw SharedDocumentsCenterError.exportFailed(error.localizedDescription)
        } catch {
            throw SharedDocumentsCenterError.exportFailed(String(describing: error))
        }
        do {
            let created = try await store.commitCreate(
                parentID: SharedDocumentsIdentity.rootItemID,
                name: name,
                kind: .file,
                stage: stage,
                cancellation: cancellation
            )
            let receipt = SharedDocumentsExportReceipt(
                name: created.name,
                itemID: created.id,
                contentVersion: created.contentVersion,
                byteCount: created.byteCount,
                sha256: created.sha256 ?? ""
            )
            signal([.rootContainer, .workingSet])
            return receipt
        } catch let error as SharedDocumentsError {
            try? await store.discardContentStage(operationID: stage.operationID)
            throw SharedDocumentsCenterError.exportFailed(error.localizedDescription)
        } catch {
            try? await store.discardContentStage(operationID: stage.operationID)
            throw SharedDocumentsCenterError.exportFailed(String(describing: error))
        }
    }

    /// Reconciles interrupted staging/orphans. Storage failures throw;
    /// missing committed content remains visible in the recovery report.
    func recoverInterruptedOperations() async throws -> SharedDocumentsRecoveryReport {
        guard let store else {
            throw storeError ?? SharedDocumentsCenterError.storeOpenFailed("uninitialized")
        }
        return try await store.recoverInterruptedOperations()
    }

    // MARK: - Validation

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    // MARK: - FileProvider domain plumbing

    private static func domains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomains { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains ?? [])
                }
            }
        }
    }

    private static func addDomain(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
#endif

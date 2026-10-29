import Foundation
import FloeCore
import Crypto

public struct DocumentSession: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalURL: URL
    public let workingURL: URL
    public let recoveryURL: URL

    /// Native editor generations live here until the host settles or explicitly
    /// discards them. A clean working file alone cannot prove these are saved.
    public var engineCopyDirectory: URL {
        workingURL.deletingLastPathComponent().appendingPathComponent("engine", isDirectory: true)
    }

    public init(id: UUID, originalURL: URL, workingURL: URL, recoveryURL: URL) {
        self.id = id
        self.originalURL = originalURL
        self.workingURL = workingURL
        self.recoveryURL = recoveryURL
    }
}

/// Immutable bytes handed to the system's Save a Copy picker. Exporting does
/// not change the original file or the session's conflict-detection baseline.
public struct DocumentExportSnapshot: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let fileURL: URL
}

public protocol DocumentWorkspace: Sendable {
    func open(securityScopedURL: URL) async throws -> DocumentSession
    func save(_ session: DocumentSession) async throws
    func close(_ session: DocumentSession) async
    func discardChangesAndClose(_ session: DocumentSession) async
}

/// Safe file lifecycle used by the native Collabora adapter. Editors always
/// mutate a private working copy; save coordinates replacement and leaves a
/// recovery copy if replacement fails.
public actor SecurityScopedDocumentWorkspace: DocumentWorkspace {
    public nonisolated static let ownershipDidChange = Notification.Name("org.floeagent.document.ownershipChanged")
    private final class LifecycleRegistry: @unchecked Sendable {
        private final class Entry {
            weak var value: SecurityScopedDocumentWorkspace?
            init(_ value: SecurityScopedDocumentWorkspace) { self.value = value }
        }
        private let lock = NSLock()
        private var entries: [Entry] = []
        private var suspended = false
        func register(_ workspace: SecurityScopedDocumentWorkspace) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.value == nil }
            entries.append(Entry(workspace))
        }
        var isSuspended: Bool {
            lock.lock(); defer { lock.unlock() }; return suspended
        }
        func snapshot(suspended: Bool) -> [SecurityScopedDocumentWorkspace] {
            lock.lock(); defer { lock.unlock() }
            self.suspended = suspended
            entries.removeAll { $0.value == nil }
            return entries.compactMap(\.value)
        }
        func requestSuspension() {
            lock.lock(); suspended = true; lock.unlock()
        }
    }
    private static let lifecycleRegistry = LifecycleRegistry()
    private let fileManager: FileManager
    private let root: URL
    private var scopedSessions: Set<UUID> = []
    private var sessions: [UUID: DocumentSession] = [:]
    private var savedDigests: [UUID: String] = [:]
    private var savedWorkingDigests: [UUID: String] = [:]
    private var manifests: [UUID: DocumentRecoveryManifest] = [:]
    private var recoveryLeases: [UUID: DocumentRecoveryLease] = [:]
    private var exports: [UUID: DocumentExportSnapshot] = [:]
    private var recoveryVersionsBySession: [UUID: [String: DocumentRecoveryVersion]] = [:]
    private var storageSuspended = false
    private var suspensionGeneration: UInt64 = 0
    private var suspendedManifests: [UUID: String] = [:]

    public init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeDocuments", isDirectory: true)
        self.root = base
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        Self.lifecycleRegistry.register(self)
    }

    deinit {
        for id in scopedSessions { sessions[id]?.originalURL.stopAccessingSecurityScopedResource() }
    }

    public func open(securityScopedURL url: URL) async throws -> DocumentSession {
        guard !storageSuspended, !Self.lifecycleRegistry.isSuspended else { throw CancellationError() }
        let generation = suspensionGeneration
        let budget = try await StorageOperationBudget.begin()
        guard !storageSuspended, generation == suspensionGeneration else {
            budget.finish(); throw CancellationError()
        }
        var adoptedBudget = false
        defer { if !adoptedBudget { budget.finish() } }
        guard url.isFileURL else {
            throw FloeError.validationFailed("Document URL must be a file URL")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let working = directory.appendingPathComponent("working").appendingPathExtension(url.pathExtension)
        let recovery = directory.appendingPathComponent("recovery").appendingPathExtension(url.pathExtension)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let lease = try DocumentRecoveryLease(directory: directory, budget: budget)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                do { try fileManager.copyItem(at: source, to: working) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let session = DocumentSession(id: id, originalURL: url, workingURL: working, recoveryURL: recovery)
            if url.pathExtension.lowercased() == "pptx" {
                try fileManager.copyItem(at: working, to: chartBaselineURL(session))
            }
            let manifest = DocumentRecoveryManifest(id: id,
                originalBookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                displayName: url.lastPathComponent, fileExtension: url.pathExtension,
                committedDigest: try Self.digest(working), updatedAt: Date())
            try manifest.write(to: directory)
            manifests[id] = manifest
            recoveryLeases[id] = lease
            adoptedBudget = true
            savedDigests[id] = manifest.committedDigest
            savedWorkingDigests[id] = manifest.workingSavedDigest ?? manifest.committedDigest
            sessions[id] = session
            if scoped { scopedSessions.insert(id) }
            return session
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func save(_ session: DocumentSession) async throws {
        try requireActiveLease(session)
        guard sessions[session.id] == session, let expectedDigest = savedDigests[session.id] else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        let workingDigest = try Self.digest(session.workingURL)
        // Preserve the user's edit before attempting any writeback. The engine
        // must finish writing its private copy before invoking this method.
        try preserveRecoveryCopy(session, expectedDigest: workingDigest)
        try preserveChartWorkbookFormatting(in: session.recoveryURL, for: session)
        let newDigest = try Self.digest(session.recoveryURL)
        try OfficeNativeSaveValidation.validate(session.recoveryURL)
        guard var manifest = manifests[session.id] else {
            throw FloeError.validationFailed("Document recovery record is unavailable")
        }
        // Journal the intended bytes before touching the original. If the app
        // terminates after replacement, resumption can reconcile this digest.
        manifest.committedDigest = expectedDigest
        manifest.pendingDigest = newDigest
        manifest.pendingWorkingDigest = workingDigest
        manifest.updatedAt = Date()
        try manifest.write(to: session.workingURL.deletingLastPathComponent())
        manifests[session.id] = manifest

        var coordinationError: NSError?
        var replacementError: Error?
        NSFileCoordinator().coordinate(writingItemAt: session.originalURL, options: .forReplacing, error: &coordinationError) { destination in
            let mutationLock = ManagedFileMutationLock.shared
            mutationLock.lock(); defer { mutationLock.unlock() }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".floe-save-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try Self.checkStorageAdmission()
                // Compare while holding the coordinated write. Metadata alone
                // misses same-size or timestamp-preserving external changes.
                guard try Self.digest(destination) == expectedDigest else {
                    throw OfficeDocumentError.revisionConflict
                }
                // Use the verified recovery snapshot. A later engine autosave
                // may replace workingURL while coordinated writeback waits.
                try fileManager.copyItem(at: session.recoveryURL, to: staging)
                guard try Self.digest(staging) == newDigest else {
                    throw FloeError.validationFailed("Editor is still writing; finish the edit before saving")
                }
                try Self.checkStorageAdmission()
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } catch { replacementError = error }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
        // The coordinated replacement is already committed. Adopt its actual
        // digests in memory even if subsequent baseline/journal maintenance
        // fails; retain the pending journal and recovery copy and report that
        // failure, but never trap this process on the old source CAS digest.
        savedDigests[session.id] = newDigest
        savedWorkingDigests[session.id] = workingDigest
        if session.workingURL.pathExtension.lowercased() == "pptx" { try replaceChartBaseline(session, from: session.recoveryURL) }
        manifest.committedDigest = newDigest
        manifest.workingSavedDigest = workingDigest
        manifest.pendingDigest = nil
        manifest.pendingWorkingDigest = nil
        manifest.updatedAt = Date()
        try manifest.write(to: session.workingURL.deletingLastPathComponent())
        manifests[session.id] = manifest
        try? fileManager.removeItem(at: session.recoveryURL)
    }

    /// Read-only proof that the current original still equals this session's
    /// committed baseline. The editor's clean preview no-op skips `save`, and
    /// `save` is the only place that CAS-checks the original under coordination
    /// and the mutation lock; this reopens exactly that comparison as a read.
    /// Never writes the original, recovery copy or manifest, and never rebases
    /// `savedDigests`/`savedWorkingDigests`: a later save must still compare
    /// against the same baseline. Working-copy cleanliness is the caller's
    /// separate check and is deliberately not claimed here.
    public func verifyCommittedOriginal(_ session: DocumentSession) throws {
        try requireActiveLease(session)
        guard sessions[session.id] == session, let expectedDigest = savedDigests[session.id] else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: session.originalURL, options: [], error: &coordinationError) { source in
            let mutationLock = ManagedFileMutationLock.shared
            mutationLock.lock(); defer { mutationLock.unlock() }
            do {
                // A real regular readable file only: a vanished original or a
                // directory substitution must fail closed, never read as clean.
                try requireRegularCopy(source)
                // Metadata alone misses same-size, timestamp-preserving
                // external rewrites, so compare the actual bytes like `save`
                // does before promoting.
                guard try Self.digest(source) == expectedDigest else {
                    throw OfficeDocumentError.revisionConflict
                }
            } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
    }

    /// Call only after the native editor acknowledges persistence to workingURL.
    /// Copy and verify before exposing the URL; later autosaves cannot mutate it.
    public func prepareExport(_ session: DocumentSession) throws -> DocumentExportSnapshot {
        try requireActiveLease(session)
        guard sessions[session.id] == session else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        try requireRegularCopy(session.workingURL)
        let expected = try Self.digest(session.workingURL)
        let id = UUID()
        let directory = session.workingURL.deletingLastPathComponent()
            .appendingPathComponent("exports", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let copy = directory.appendingPathComponent(session.originalURL.lastPathComponent)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: session.workingURL, to: copy)
            guard try Self.digest(copy) == expected else {
                throw FloeError.validationFailed("Editor is still writing; finish the edit before exporting")
            }
            try preserveChartWorkbookFormatting(in: copy, for: session)
            try OfficeNativeSaveValidation.validate(copy)
            let snapshot = DocumentExportSnapshot(id: id, fileURL: copy)
            exports[id] = snapshot
            return snapshot
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Snapshot the *current original* for comparison without rebasing the
    /// editor or replacing its recoverable working copy.
    public func prepareCurrentExport(_ session: DocumentSession) throws -> DocumentExportSnapshot {
        try requireActiveLease(session)
        guard sessions[session.id] == session else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        let id = UUID()
        let directory = session.workingURL.deletingLastPathComponent()
            .appendingPathComponent("exports", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let copy = directory.appendingPathComponent(session.originalURL.lastPathComponent)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: session.originalURL, options: [], error: &coordinationError) { source in
                let lock = ManagedFileMutationLock.shared
                lock.lock(); defer { lock.unlock() }
                do {
                    try requireRegularCopy(source)
                    let digest = try Self.digest(source)
                    try fileManager.copyItem(at: source, to: copy)
                    guard try Self.digest(copy) == digest, try Self.digest(source) == digest else {
                        throw OfficeDocumentError.revisionConflict
                    }
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let snapshot = DocumentExportSnapshot(id: id, fileURL: copy)
            exports[id] = snapshot
            return snapshot
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// The picker has finished reading this exact snapshot, on success or cancel.
    /// Working/recovery copies remain available regardless of export outcome.
    public func finishExport(_ snapshot: DocumentExportSnapshot) {
        guard exports[snapshot.id] == snapshot else { return }
        exports[snapshot.id] = nil
        let directory = snapshot.fileURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: directory)
        let parent = directory.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
    }

    public func hasUncommittedWorkingCopy(_ session: DocumentSession) throws -> Bool {
        try requireActiveLease(session)
        guard sessions[session.id] == session, let saved = savedWorkingDigests[session.id] ?? savedDigests[session.id] else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        return try Self.digest(session.workingURL) != saved
    }

    /// List only recognized regular copies inside the registered session. The
    /// digest also prevents restoring changed bytes from a stale version row.
    public func recoveryVersions(_ session: DocumentSession) throws -> [DocumentRecoveryVersion] {
        try requireActiveLease(session)
        guard sessions[session.id] == session else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        let directory = session.workingURL.deletingLastPathComponent()
        var candidates: [(URL, DocumentRecoveryVersion.Kind)] = [
            (session.workingURL, .current), (session.recoveryURL, .lastSave)
        ]
        for (name, kind) in [("engine", DocumentRecoveryVersion.Kind.editor), ("revisions", .previousEdit), ("exports", .export)] {
            let parent = directory.appendingPathComponent(name, isDirectory: true)
            guard (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            for child in (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
                guard UUID(uuidString: child.lastPathComponent) != nil,
                      (try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).map({ $0.isSymbolicLink != true && $0.isDirectory == true }) == true else { continue }
                // Enumeration can expand /var to /private/var. Reconstruct from
                // our owned parent and the validated single directory name.
                let ownedChild = parent.appendingPathComponent(child.lastPathComponent, isDirectory: true)
                candidates.append((ownedChild.appendingPathComponent(name == "exports" ? session.originalURL.lastPathComponent : session.workingURL.lastPathComponent), kind))
            }
        }
        var versions: [DocumentRecoveryVersion] = []
        var seen = Set<String>()
        for (file, kind) in candidates {
            guard (try? requireOwnedRecoveryCopy(file, directory: directory)) != nil,
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let digest = try? Self.digest(file) else { continue }
            // Identical editor generations add no recoverable content. Current
            // and last-save copies appear first so their identity wins ties.
            guard seen.insert(digest).inserted else { continue }
            let relative = String(file.path.dropFirst(directory.path.count + 1))
            versions.append(DocumentRecoveryVersion(id: relative, kind: kind, fileURL: file,
                updatedAt: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0, sha256: digest))
        }
        recoveryVersionsBySession[session.id] = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
        return versions.sorted { left, right in
            if left.kind == .current { return right.kind != .current }
            if right.kind == .current { return false }
            return left.updatedAt > right.updatedAt
        }
    }

    /// The host must close its editor first. Preserve the prior working bytes
    /// as a selectable version; this never writes or rebases the original.
    public func restoreRecoveryVersion(_ version: DocumentRecoveryVersion, in session: DocumentSession) throws {
        try requireActiveLease(session)
        guard sessions[session.id] == session,
              recoveryVersionsBySession[session.id]?[version.id] == version else {
            throw FloeError.validationFailed("Document recovery version is no longer available")
        }
        let directory = session.workingURL.deletingLastPathComponent()
        try requireOwnedRecoveryCopy(version.fileURL, directory: directory)
        guard try Self.digest(version.fileURL) == version.sha256 else {
            throw FloeError.validationFailed("Document recovery version changed; refresh before choosing it")
        }
        if version.kind == .current { return }
        let staging = directory.appendingPathComponent(".floe-restore-\(UUID())")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: version.fileURL, to: staging)
        guard try Self.digest(staging) == version.sha256 else {
            throw FloeError.validationFailed("Document recovery version changed while copying")
        }
        let oldDigest = try Self.digest(session.workingURL)
        let previousDirectory = directory.appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
            let previous = previousDirectory.appendingPathComponent(session.workingURL.lastPathComponent)
            try fileManager.copyItem(at: session.workingURL, to: previous)
            guard try Self.digest(previous) == oldDigest else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fileManager.removeItem(at: previousDirectory)
            throw error
        }
        _ = try fileManager.replaceItemAt(session.workingURL, withItemAt: staging)
        recoveryVersionsBySession[session.id] = nil
        if var manifest = manifests[session.id] {
            manifest.updatedAt = Date()
            try manifest.write(to: directory)
            manifests[session.id] = manifest
        }
    }

    /// Retained sessions only. An active editor in any workspace instance keeps
    /// its lease and is omitted; malformed records and all their files survive.
    public func recoveryRecords() async throws -> [DocumentRecoveryRecord] {
        guard !storageSuspended, !Self.lifecycleRegistry.isSuspended else { throw CancellationError() }
        let budget = try await StorageOperationBudget.begin()
        defer { budget.finish() }
        guard !storageSuspended else { throw CancellationError() }
        try budget.check()
        let directories = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var records: [DocumentRecoveryRecord] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), sessions[id] == nil else { continue }
            do {
                let (manifest, lease) = try loadRecovery(id)
                let copy = manifest.session(originalURL: directory, directory: directory)
                try requireRegularCopy(copy.workingURL)
                let modified = try? copy.workingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                records.append(DocumentRecoveryRecord(id: id, displayName: manifest.displayName,
                    updatedAt: max(manifest.updatedAt, modified ?? manifest.updatedAt),
                    workingURL: copy.workingURL, recoveryURL: copy.recoveryURL,
                    hasEngineCopies: fileManager.fileExists(atPath: copy.engineCopyDirectory.path)))
                withExtendedLifetime(lease) {}
            } catch { continue }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func resumeRecovery(id: UUID) async throws -> DocumentSession {
        guard !storageSuspended, !Self.lifecycleRegistry.isSuspended else { throw CancellationError() }
        let generation = suspensionGeneration
        let budget = try await StorageOperationBudget.begin()
        guard !storageSuspended, generation == suspensionGeneration else {
            budget.finish(); throw CancellationError()
        }
        var adoptedBudget = false
        defer { if !adoptedBudget { budget.finish() } }
        guard sessions[id] == nil else {
            throw FloeError.validationFailed("This document recovery session is already open")
        }
        var (manifest, lease) = try loadRecovery(id, budget: budget)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        var stale = false
        let original = try URL(resolvingBookmarkData: manifest.originalBookmark,
            options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard original.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = original.startAccessingSecurityScopedResource()
        do {
            let session = manifest.session(originalURL: original, directory: directory)
            try requireRegularCopy(session.workingURL)
            if let intended = manifest.pendingDigest {
                var current: String?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: original, options: [], error: &coordinationError) { source in
                    current = try? Self.digest(source)
                }
                // Never adopt an unrelated external revision as our baseline.
                if coordinationError == nil, current == intended {
                    manifest.reconcileCommittedPending(currentDigest: intended)
                }
            }
            if stale {
                manifest.originalBookmark = try original.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            manifest.updatedAt = Date()
            try manifest.write(to: directory)
            sessions[id] = session
            savedDigests[id] = manifest.committedDigest
            savedWorkingDigests[id] = manifest.workingSavedDigest ?? manifest.committedDigest
            manifests[id] = manifest
            recoveryLeases[id] = lease
            adoptedBudget = true
            if scoped { scopedSessions.insert(id) }
            return session
        } catch {
            if scoped { original.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func loadRecovery(_ id: UUID, budget: StorageOperationLease? = nil) throws -> (DocumentRecoveryManifest, DocumentRecoveryLease) {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else {
            throw FloeError.validationFailed("Recovery directory is outside its document workspace")
        }
        _ = try DocumentRecoveryManifest.read(from: directory)
        let lease = try DocumentRecoveryLease(directory: directory, budget: budget)
        return (try DocumentRecoveryManifest.read(from: directory), lease)
    }

    private func requireRegularCopy(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FloeError.validationFailed("Recovery working copy is missing or unsafe")
        }
    }

    private func requireOwnedRecoveryCopy(_ url: URL, directory: URL) throws {
        guard url.path.hasPrefix(directory.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        var item = url
        while item.path != directory.path {
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CocoaError(.fileReadNoPermission)
            }
            item.deleteLastPathComponent()
        }
        try requireRegularCopy(url)
    }

    /// A normal close never discards edits. Dirty or unreadable copies remain
    /// in Application Support for recovery; explicit discard is separate. Native
    /// generations may be newer than workingURL when engine persistence failed.
    public func close(_ session: DocumentSession) async {
        guard sessions[session.id] == session else { return }
        // A suspended/conflicted session no longer owns its directory. Keep
        // recovery bytes; never retire a directory another process may own.
        guard !storageSuspended, recoveryLeases[session.id] != nil else {
            release(session); return
        }
        let clean = (try? Self.digest(session.workingURL)).map { $0 == (savedWorkingDigests[session.id] ?? savedDigests[session.id]) } ?? false
        let directory = session.workingURL.deletingLastPathComponent()
        let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Conservatively retain native generations, recovery files, and unknown
        // sidecars. The editor must settle them before ordinary cleanup is safe.
        let ownedNames: Set<String> = [session.workingURL.lastPathComponent, chartBaselineURL(session).lastPathComponent, DocumentRecoveryManifest.fileName, DocumentRecoveryLease.fileName]
        let onlyWorkingCopy = entries.map { $0.allSatisfy { ownedNames.contains($0.lastPathComponent) } } ?? false
        if clean && onlyWorkingCopy { retire(directory) }
        release(session)
    }

    public func discardChangesAndClose(_ session: DocumentSession) async {
        guard sessions[session.id] == session else { return }
        guard !storageSuspended, recoveryLeases[session.id] != nil else {
            release(session); return
        }
        retire(session.workingURL.deletingLastPathComponent())
        release(session)
    }

    private func release(_ session: DocumentSession) {
        if scopedSessions.remove(session.id) != nil { session.originalURL.stopAccessingSecurityScopedResource() }
        sessions[session.id] = nil
        savedDigests[session.id] = nil
        savedWorkingDigests[session.id] = nil
        manifests[session.id] = nil
        recoveryLeases[session.id] = nil
        recoveryVersionsBySession[session.id] = nil
        suspendedManifests[session.id] = nil
    }

    /// Called on real process backgrounding, after the current synchronous
    /// actor operation finishes. Keep working/recovery files, release only
    /// kernel ownership; foreground must reacquire and validate before use.
    public func suspendForBackground() {
        suspensionGeneration &+= 1
        storageSuspended = true
        for (id, session) in sessions where recoveryLeases[id] != nil {
            suspendedManifests[id] = try? recoveryFingerprint(session)
        }
        recoveryLeases.removeAll()
    }

    public nonisolated static func suspendAllForBackground() async {
        for workspace in lifecycleRegistry.snapshot(suspended: true) {
            await workspace.suspendForBackground()
        }
    }

    /// A synchronous admission fence for the App's expiration callback. A
    /// coordinated write that resumes later must re-check before replacement.
    public nonisolated static func requestBackgroundSuspension() {
        lifecycleRegistry.requestSuspension()
    }

    public nonisolated static func resumeAllAfterSuspension() async -> Int {
        var conflicts = 0
        for workspace in lifecycleRegistry.snapshot(suspended: false) {
            conflicts += await workspace.resumeAfterSuspension().count
        }
        return conflicts
    }

    @discardableResult
    public func resumeAfterSuspension() async -> [UUID] {
        guard storageSuspended else { return [] }
        let generation = suspensionGeneration
        var conflicts: [UUID] = []
        for (id, session) in sessions {
            do {
                let budget = try await StorageOperationBudget.begin()
                var adoptedBudget = false
                defer { if !adoptedBudget { budget.finish() } }
                guard generation == suspensionGeneration, storageSuspended else {
                    budget.finish(); return conflicts
                }
                guard sessions[id] == session else { budget.finish(); continue }
                let lease = try DocumentRecoveryLease(
                    directory: session.workingURL.deletingLastPathComponent(), budget: budget)
                guard let expected = suspendedManifests[id],
                      try recoveryFingerprint(session) == expected else {
                    throw OfficeDocumentError.revisionConflict
                }
                recoveryLeases[id] = lease
                adoptedBudget = true
                suspendedManifests[id] = nil
            } catch {
                conflicts.append(id)
                NotificationCenter.default.post(name: Self.ownershipDidChange, object: nil,
                                                userInfo: ["sessionID": id])
            }
        }
        guard generation == suspensionGeneration else { return conflicts }
        storageSuspended = false
        return conflicts
    }

    private func requireActiveLease(_ session: DocumentSession) throws {
        guard !storageSuspended, !Self.lifecycleRegistry.isSuspended else { throw CancellationError() }
        guard let lease = recoveryLeases[session.id] else {
            throw OfficeDocumentError.revisionConflict
        }
        try lease.check()
    }

    private nonisolated static func checkStorageAdmission() throws {
        guard !lifecycleRegistry.isSuspended else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func recoveryFingerprint(_ session: DocumentSession) throws -> String {
        let manifestURL = session.workingURL.deletingLastPathComponent()
            .appendingPathComponent(DocumentRecoveryManifest.fileName)
        try requireRegularCopy(manifestURL)
        try requireRegularCopy(session.workingURL)
        return try Self.digest(manifestURL) + ":" + Self.digest(session.workingURL)
    }

    private func retire(_ directory: URL) {
        // Rename while the session lock is held. A concurrent recovery request
        // cannot acquire a newly-created lock inside a half-deleted directory.
        let retired = root.appendingPathComponent(".closed-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: directory, to: retired)
            try fileManager.removeItem(at: retired)
        } catch { /* Retain anything that could not be cleaned up safely. */ }
    }

    /// A native format export is a stable private snapshot, never the live
    /// engine-owned workingURL. Used by native PPTX export as well as save and
    /// prepareExport; the immutable baseline survives external source changes.
    public func preserveChartWorkbookFormatting(in exportedURL: URL, for session: DocumentSession) throws {
        try requireActiveLease(session)
        guard sessions[session.id] == session else { throw FloeError.validationFailed("Document session is closed or belongs to another workspace") }
        guard exportedURL.pathExtension.lowercased() == "pptx", session.workingURL.pathExtension.lowercased() == "pptx" else { return }
        guard exportedURL.standardizedFileURL != session.workingURL.standardizedFileURL else { throw FloeError.validationFailed("Chart formatting requires a stable export or recovery snapshot") }
        try requireRegularCopy(exportedURL)
        let baseline = chartBaselineURL(session)
        // Old retained sessions predate the baseline. A matching original may
        // seed it, but an unrelated external revision can never be adopted.
        if !fileManager.fileExists(atPath: baseline.path) {
            var coordinationError: NSError?, readError: Error?
            let stage = baseline.deletingLastPathComponent().appendingPathComponent(".chart-seed-\(UUID())")
            defer { try? fileManager.removeItem(at: stage) }
            NSFileCoordinator().coordinate(readingItemAt: session.originalURL, options: [], error: &coordinationError) { source in
                do {
                    guard try Self.digest(source) == savedDigests[session.id] else { throw OfficeDocumentError.revisionConflict }
                    try fileManager.copyItem(at: source, to: stage)
                    guard try Self.digest(stage) == savedDigests[session.id],
                          try Self.digest(source) == savedDigests[session.id] else { throw OfficeDocumentError.revisionConflict }
                } catch { readError = error }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            try fileManager.moveItem(at: stage, to: baseline)
        }
        _ = try OfficeEmbeddedWorkbookPreservation.preserve(originalURL: baseline, savedURL: exportedURL)
    }

    private func chartBaselineURL(_ session: DocumentSession) -> URL {
        session.workingURL.deletingLastPathComponent().appendingPathComponent("chart-format-baseline.pptx")
    }
    private func replaceChartBaseline(_ session: DocumentSession, from source: URL) throws {
        let baseline = chartBaselineURL(session)
        let staged = baseline.deletingLastPathComponent().appendingPathComponent(".chart-baseline-\(UUID())")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: source, to: staged)
        guard try Self.digest(staged) == Self.digest(source) else { throw OfficeDocumentError.revisionConflict }
        if fileManager.fileExists(atPath: baseline.path) { _ = try fileManager.replaceItemAt(baseline, withItemAt: staged) }
        else { try fileManager.moveItem(at: staged, to: baseline) }
    }

    private func preserveRecoveryCopy(_ session: DocumentSession, expectedDigest: String) throws {
        let stage = session.recoveryURL.deletingLastPathComponent()
            .appendingPathComponent(".floe-recovery-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.copyItem(at: session.workingURL, to: stage)
        guard try Self.digest(stage) == expectedDigest else {
            throw FloeError.validationFailed("Editor is still writing; previous recovery copy was preserved")
        }
        if fileManager.fileExists(atPath: session.recoveryURL.path) {
            _ = try fileManager.replaceItemAt(session.recoveryURL, withItemAt: stage)
        } else {
            try fileManager.moveItem(at: stage, to: session.recoveryURL)
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

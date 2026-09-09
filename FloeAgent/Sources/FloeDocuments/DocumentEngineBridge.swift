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
    private let fileManager: FileManager
    private let root: URL
    private var scopedSessions: Set<UUID> = []
    private var sessions: [UUID: DocumentSession] = [:]
    private var savedDigests: [UUID: String] = [:]
    private var manifests: [UUID: DocumentRecoveryManifest] = [:]
    private var recoveryLeases: [UUID: DocumentRecoveryLease] = [:]
    private var exports: [UUID: DocumentExportSnapshot] = [:]
    private var recoveryVersionsBySession: [UUID: [String: DocumentRecoveryVersion]] = [:]

    public init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeDocuments", isDirectory: true)
        self.root = base
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit {
        for id in scopedSessions { sessions[id]?.originalURL.stopAccessingSecurityScopedResource() }
    }

    public func open(securityScopedURL url: URL) async throws -> DocumentSession {
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
            let lease = try DocumentRecoveryLease(directory: directory)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                do { try fileManager.copyItem(at: source, to: working) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let session = DocumentSession(id: id, originalURL: url, workingURL: working, recoveryURL: recovery)
            let manifest = DocumentRecoveryManifest(id: id,
                originalBookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                displayName: url.lastPathComponent, fileExtension: url.pathExtension,
                committedDigest: try Self.digest(working), updatedAt: Date())
            try manifest.write(to: directory)
            manifests[id] = manifest
            recoveryLeases[id] = lease
            savedDigests[id] = manifest.committedDigest
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
        guard sessions[session.id] == session, let expectedDigest = savedDigests[session.id] else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        let newDigest = try Self.digest(session.workingURL)
        // Preserve the user's edit before attempting any writeback. The engine
        // must finish writing its private copy before invoking this method.
        try preserveRecoveryCopy(session, expectedDigest: newDigest)
        try OfficeNativeSaveValidation.validate(session.recoveryURL)
        guard var manifest = manifests[session.id] else {
            throw FloeError.validationFailed("Document recovery record is unavailable")
        }
        // Journal the intended bytes before touching the original. If the app
        // terminates after replacement, resumption can reconcile this digest.
        manifest.committedDigest = expectedDigest
        manifest.pendingDigest = newDigest
        manifest.updatedAt = Date()
        try manifest.write(to: session.workingURL.deletingLastPathComponent())
        manifests[session.id] = manifest

        var coordinationError: NSError?
        var replacementError: Error?
        NSFileCoordinator().coordinate(writingItemAt: session.originalURL, options: .forReplacing, error: &coordinationError) { destination in
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".floe-save-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staging) }
            do {
                // Compare while holding the coordinated write. Metadata alone
                // misses same-size or timestamp-preserving external changes.
                guard try Self.digest(destination) == expectedDigest else {
                    throw FloeError.validationFailed("Document changed outside this editor; keep the edited copy and resolve the conflict before saving")
                }
                // Use the verified recovery snapshot. A later engine autosave
                // may replace workingURL while coordinated writeback waits.
                try fileManager.copyItem(at: session.recoveryURL, to: staging)
                guard try Self.digest(staging) == newDigest else {
                    throw FloeError.validationFailed("Editor is still writing; finish the edit before saving")
                }
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } catch { replacementError = error }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
        savedDigests[session.id] = newDigest
        manifest.committedDigest = newDigest
        manifest.pendingDigest = nil
        manifest.updatedAt = Date()
        try manifest.write(to: session.workingURL.deletingLastPathComponent())
        manifests[session.id] = manifest
        try? fileManager.removeItem(at: session.recoveryURL)
    }

    /// Call only after the native editor acknowledges persistence to workingURL.
    /// Copy and verify before exposing the URL; later autosaves cannot mutate it.
    public func prepareExport(_ session: DocumentSession) throws -> DocumentExportSnapshot {
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
            try OfficeNativeSaveValidation.validate(copy)
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
        guard sessions[session.id] == session, let saved = savedDigests[session.id] else {
            throw FloeError.validationFailed("Document session is closed or belongs to another workspace")
        }
        return try Self.digest(session.workingURL) != saved
    }

    /// List only recognized regular copies inside the registered session. The
    /// digest also prevents restoring changed bytes from a stale version row.
    public func recoveryVersions(_ session: DocumentSession) throws -> [DocumentRecoveryVersion] {
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
    public func recoveryRecords() throws -> [DocumentRecoveryRecord] {
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

    public func resumeRecovery(id: UUID) throws -> DocumentSession {
        guard sessions[id] == nil else {
            throw FloeError.validationFailed("This document recovery session is already open")
        }
        var (manifest, lease) = try loadRecovery(id)
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
                    manifest.committedDigest = intended
                    manifest.pendingDigest = nil
                }
            }
            if stale {
                manifest.originalBookmark = try original.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            manifest.updatedAt = Date()
            try manifest.write(to: directory)
            sessions[id] = session
            savedDigests[id] = manifest.committedDigest
            manifests[id] = manifest
            recoveryLeases[id] = lease
            if scoped { scopedSessions.insert(id) }
            return session
        } catch {
            if scoped { original.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func loadRecovery(_ id: UUID) throws -> (DocumentRecoveryManifest, DocumentRecoveryLease) {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else {
            throw FloeError.validationFailed("Recovery directory is outside its document workspace")
        }
        _ = try DocumentRecoveryManifest.read(from: directory)
        let lease = try DocumentRecoveryLease(directory: directory)
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
        let clean = (try? Self.digest(session.workingURL)).map { $0 == savedDigests[session.id] } ?? false
        let directory = session.workingURL.deletingLastPathComponent()
        let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Conservatively retain native generations, recovery files, and unknown
        // sidecars. The editor must settle them before ordinary cleanup is safe.
        let ownedNames: Set<String> = [session.workingURL.lastPathComponent, DocumentRecoveryManifest.fileName, DocumentRecoveryLease.fileName]
        let onlyWorkingCopy = entries.map { $0.allSatisfy { ownedNames.contains($0.lastPathComponent) } } ?? false
        if clean && onlyWorkingCopy { retire(directory) }
        release(session)
    }

    public func discardChangesAndClose(_ session: DocumentSession) async {
        guard sessions[session.id] == session else { return }
        retire(session.workingURL.deletingLastPathComponent())
        release(session)
    }

    private func release(_ session: DocumentSession) {
        if scopedSessions.remove(session.id) != nil { session.originalURL.stopAccessingSecurityScopedResource() }
        sessions[session.id] = nil
        savedDigests[session.id] = nil
        manifests[session.id] = nil
        recoveryLeases[session.id] = nil
        recoveryVersionsBySession[session.id] = nil
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
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

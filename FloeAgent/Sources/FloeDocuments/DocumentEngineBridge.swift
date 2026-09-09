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

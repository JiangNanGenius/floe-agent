import Foundation
import FloeCore
import Crypto

public struct DocumentSession: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalURL: URL
    public let workingURL: URL
    public let recoveryURL: URL

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

/// Safe file lifecycle used by the future Collabora adapter. Editors always
/// mutate a private working copy; save coordinates replacement and leaves a
/// recovery copy if replacement fails.
public actor SecurityScopedDocumentWorkspace: DocumentWorkspace {
    private let fileManager: FileManager
    private let root: URL
    private var scopedSessions: Set<UUID> = []
    private var sessions: [UUID: DocumentSession] = [:]
    private var savedDigests: [UUID: String] = [:]

    public init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeDocuments", isDirectory: true)
        self.root = base
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
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
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                do { try fileManager.copyItem(at: source, to: working) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let session = DocumentSession(id: id, originalURL: url, workingURL: working, recoveryURL: recovery)
            savedDigests[id] = try Self.digest(working)
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
        if fileManager.fileExists(atPath: session.recoveryURL.path) {
            try fileManager.removeItem(at: session.recoveryURL)
        }
        try fileManager.copyItem(at: session.workingURL, to: session.recoveryURL)

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
                try fileManager.copyItem(at: session.workingURL, to: staging)
                guard try Self.digest(staging) == newDigest else {
                    throw FloeError.validationFailed("Editor is still writing; finish the edit before saving")
                }
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } catch { replacementError = error }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
        savedDigests[session.id] = newDigest
        try? fileManager.removeItem(at: session.recoveryURL)
    }

    /// A normal close never discards edits. Dirty or unreadable copies remain
    /// in Application Support for recovery; explicit discard is separate.
    public func close(_ session: DocumentSession) async {
        guard sessions[session.id] == session else { return }
        let clean = (try? Self.digest(session.workingURL)).map { $0 == savedDigests[session.id] } ?? false
        release(session)
        if clean { try? fileManager.removeItem(at: session.workingURL.deletingLastPathComponent()) }
    }

    public func discardChangesAndClose(_ session: DocumentSession) async {
        guard sessions[session.id] == session else { return }
        release(session)
        try? fileManager.removeItem(at: session.workingURL.deletingLastPathComponent())
    }

    private func release(_ session: DocumentSession) {
        if scopedSessions.remove(session.id) != nil { session.originalURL.stopAccessingSecurityScopedResource() }
        sessions[session.id] = nil
        savedDigests[session.id] = nil
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

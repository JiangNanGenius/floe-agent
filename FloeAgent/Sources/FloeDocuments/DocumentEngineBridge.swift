import Foundation
import FloeCore

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
}

/// Safe file lifecycle used by the future Collabora adapter. Editors always
/// mutate a private working copy; save coordinates replacement and leaves a
/// recovery copy if replacement fails.
public actor SecurityScopedDocumentWorkspace: DocumentWorkspace {
    private let fileManager: FileManager
    private let root: URL
    private var scopedSessions: Set<UUID> = []

    public init(root: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = root ?? fileManager.temporaryDirectory.appendingPathComponent("FloeDocuments", isDirectory: true)
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
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let working = directory.appendingPathComponent("working").appendingPathExtension(url.pathExtension)
        let recovery = directory.appendingPathComponent("recovery").appendingPathExtension(url.pathExtension)
        do {
            try fileManager.copyItem(at: url, to: working)
            if scoped { scopedSessions.insert(id) }
            return DocumentSession(id: id, originalURL: url, workingURL: working, recoveryURL: recovery)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func save(_ session: DocumentSession) async throws {
        guard fileManager.fileExists(atPath: session.workingURL.path) else {
            throw FloeError.storageCorrupted("Document working copy is missing")
        }
        if fileManager.fileExists(atPath: session.recoveryURL.path) {
            try fileManager.removeItem(at: session.recoveryURL)
        }
        try fileManager.copyItem(at: session.originalURL, to: session.recoveryURL)

        var coordinationError: NSError?
        var replacementError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: session.originalURL,
            options: .forReplacing,
            error: &coordinationError
        ) { destination in
            do {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: session.workingURL,
                    backupItemName: nil,
                    options: []
                )
                try fileManager.copyItem(at: destination, to: session.workingURL)
            } catch {
                replacementError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let replacementError { throw replacementError }
        try? fileManager.removeItem(at: session.recoveryURL)
    }

    public func close(_ session: DocumentSession) async {
        if scopedSessions.remove(session.id) != nil {
            session.originalURL.stopAccessingSecurityScopedResource()
        }
        try? fileManager.removeItem(at: session.workingURL.deletingLastPathComponent())
    }
}

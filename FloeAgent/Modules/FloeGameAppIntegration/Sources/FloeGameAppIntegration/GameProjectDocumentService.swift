// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One bounded directory page over the project's saved revision. Files are
/// metadata only; bytes are read through `read`.
public struct GameProjectEntry: Codable, Equatable, Sendable, Identifiable {
    public let path: GameRelativePath
    public let isDirectory: Bool
    public let bytes: Int
    public let sha256: String?

    public var id: String { path.value }
    public init(path: GameRelativePath, isDirectory: Bool, bytes: Int, sha256: String?) {
        self.path = path
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct GameProjectDirectoryPage: Equatable, Sendable {
    public let revision: String
    public let directory: String
    public let entries: [GameProjectEntry]
    public let offset: Int
    public let nextOffset: Int?
    public let totalEntries: Int
    public let isComplete: Bool
}

/// One bounded UTF-8 page. `offset` and `nextOffset` are byte offsets into the
/// same saved file, adjusted to code-point boundaries. The page carries the
/// exact saved revision and full-file digest so a caller can detect changes
/// before an edit.
public struct GameTextPage: Equatable, Sendable {
    public let path: GameRelativePath
    public let revision: String
    public let sha256: String
    public let totalBytes: Int
    public let offset: Int
    public let nextOffset: Int?
    public let text: String

    public var isComplete: Bool { nextOffset == nil }
    public var byteCount: Int { text.utf8.count }
}

public enum GameDocumentChange: Equatable, Sendable {
    case write(GameRelativePath, Data)
    case remove(GameRelativePath)
}

public struct GameRevisionSummary: Codable, Equatable, Sendable, Identifiable {
    public let revision: String
    public let parent: String?
    public let title: String
    public let engine: GameEngineID?
    public let fileCount: Int
    public let directoryCount: Int
    public let revisionIndex: Int

    public var id: String { revision }
    public init(project: GameStoredProject, revisionIndex: Int) {
        self.revision = project.revision
        self.parent = project.parent
        self.title = project.title
        self.engine = project.engine
        self.fileCount = project.files.count
        self.directoryCount = project.directories.count
        self.revisionIndex = revisionIndex
    }
}

public enum GameDocumentError: Error, Equatable, LocalizedError {
    case staleRevision(expected: String, actual: String)
    case notUTF8(GameRelativePath)
    case binaryFile(GameRelativePath)
    case fileTooLarge(GameRelativePath, bytes: Int, limit: Int)
    case invalidOffset(Int)
    case invalidPageLimit(Int)
    case invalidWriteLimit(Int)
    case noChanges
    case duplicateChange(GameRelativePath)
    case engineConversionRequiresNewProject

    public var errorDescription: String? {
        switch self {
        case .staleRevision(let expected, let actual):
            return "The project changed (expected revision \(expected), actual \(actual)). Reopen the current saved state."
        case .notUTF8(let path):
            return "\(path.value) is not valid UTF-8 text. Use the file browser or the existing IDE instead."
        case .binaryFile(let path):
            return "\(path.value) appears to be binary. Use a native asset editor or the existing IDE."
        case .fileTooLarge(let path, let bytes, let limit):
            return "\(path.value) is \(bytes) bytes; this text operation is limited to \(limit) bytes."
        case .invalidOffset(let offset):
            return "The text offset \(offset) is invalid."
        case .invalidPageLimit(let limit):
            return "The page limit \(limit) is outside the supported range."
        case .invalidWriteLimit(let limit):
            return "The edit limit \(limit) is outside the supported range."
        case .noChanges:
            return "The edit did not contain any file changes."
        case .duplicateChange(let path):
            return "The edit contains more than one operation for \(path.value)."
        case .engineConversionRequiresNewProject:
            return "Changing the engine creates a new project. The original project is never overwritten."
        }
    }
}

/// Concrete file/AI edit surface over the shared `FileGameProjectRepository`.
/// It never creates a second file tree: reads and commits use the repository's
/// immutable objects and expected-revision CAS. The App remains responsible
/// for resolving the live workspace root and for any native editor drafts.
public actor GameProjectDocumentService {
    public let repository: FileGameProjectRepository
    public let maximumTextBytes: Int
    public let maximumPageBytes: Int
    public let maximumWriteBytes: Int

    public init(repository: FileGameProjectRepository,
                maximumTextBytes: Int = 8 * 1_024 * 1_024,
                maximumPageBytes: Int = 128 * 1_024,
                maximumWriteBytes: Int = 2 * 1_024 * 1_024) {
        self.repository = repository
        self.maximumTextBytes = max(1_024, maximumTextBytes)
        self.maximumPageBytes = max(1_024, min(1_024 * 1_024, maximumPageBytes))
        self.maximumWriteBytes = max(1_024, maximumWriteBytes)
    }

    /// Opens the exact revision captured by the host context. A stale context
    /// is rejected before any bytes are returned.
    public func currentProject(_ context: GameProjectContext) async throws -> GameStoredProject {
        let project = try await repository.open(context.projectID, owner: context.owner)
        guard project.revision == context.savedRevision else {
            throw GameDocumentError.staleRevision(expected: context.savedRevision, actual: project.revision)
        }
        let current = try GameProjectContext(projectID: project.projectID, owner: project.owner,
                                             rootURL: context.rootURL,
                                             savedRevision: project.revision,
                                             environmentID: context.environmentID)
        try context.validate(current: current)
        return project
    }

    /// A nil directory pages the full saved inventory. An explicit directory pages its direct children.
    /// Names are always project-relative; no method
    /// accepts an absolute path or follows a filesystem symlink.
    public func list(_ context: GameProjectContext, directory: String? = nil,
                     offset: Int = 0, limit: Int = 200) async throws -> GameProjectDirectoryPage {
        guard offset >= 0 else { throw GameDocumentError.invalidOffset(offset) }
        guard (1...1_000).contains(limit) else { throw GameDocumentError.invalidPageLimit(limit) }
        let project = try await currentProject(context)
        let prefix = try GameToolPathRule.validateDirectory(directory) ?? ""
        let inDirectory: (String) -> Bool = { path in
            if directory == nil { return true }
            if prefix.isEmpty { return !path.contains("/") }
            return path.hasPrefix(prefix + "/") &&
                !path.dropFirst(prefix.count + 1).contains("/")
        }
        var entries: [GameProjectEntry] = []
        for file in project.files where inDirectory(file.path.value) {
            entries.append(.init(path: file.path, isDirectory: false,
                                 bytes: file.bytes, sha256: file.sha256))
        }
        for path in project.directories where inDirectory(path.value) {
            entries.append(.init(path: path, isDirectory: true, bytes: 0, sha256: nil))
        }
        entries.sort { $0.path.value < $1.path.value }
        let start = min(offset, entries.count)
        let end = min(start + limit, entries.count)
        let page = Array(entries[start..<end])
        return .init(revision: project.revision, directory: normalisedDirectory(prefix),
                     entries: page, offset: start,
                     nextOffset: end < entries.count ? end : nil,
                     totalEntries: entries.count, isComplete: end >= entries.count)
    }

    /// Bounded UTF-8 text read. The complete file is decoded only after a
    /// limit check; a page is cut at code-point boundaries.
    public func read(_ context: GameProjectContext, path: GameRelativePath,
                     offset: Int = 0, limit: Int? = nil) async throws -> GameTextPage {
        let pageLimit = limit ?? maximumPageBytes
        guard (1...maximumPageBytes).contains(pageLimit) else {
            throw GameDocumentError.invalidPageLimit(pageLimit)
        }
        guard offset >= 0 else { throw GameDocumentError.invalidOffset(offset) }
        let project = try await currentProject(context)
        guard let file = project.files.first(where: { $0.path == path }) else {
            throw GameProjectError.unreadableFile(path.value)
        }
        guard file.bytes <= maximumTextBytes else {
            throw GameDocumentError.fileTooLarge(path, bytes: file.bytes, limit: maximumTextBytes)
        }
        let data = try await repository.read(project.projectID, owner: project.owner,
                                             revision: project.revision, path: path)
        guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
            throw GameProjectError.corruptStorage
        }
        return try textPage(data, path: path, revision: project.revision, sha256: file.sha256,
                            offset: offset, limit: pageLimit)
    }

    /// One atomic CAS commit. The caller passes the exact revision it read.
    /// A concurrent save/import produces the repository's real conflict; no
    /// change is applied.
    public func commit(_ context: GameProjectContext,
                       expectedRevision: String,
                       changes: [GameDocumentChange],
                       title: String? = nil) async throws -> GameStoredProject {
        guard !changes.isEmpty else { throw GameDocumentError.noChanges }
        var seen = Set<GameRelativePath>()
        var total = 0
        var repoChanges: [GameFileChange] = []
        for change in changes {
            switch change {
            case .write(let path, let data):
                guard seen.insert(path).inserted else { throw GameDocumentError.duplicateChange(path) }
                guard data.count <= maximumWriteBytes,
                      total <= maximumWriteBytes - data.count else {
                    throw GameDocumentError.invalidWriteLimit(total + data.count)
                }
                total += data.count
                repoChanges.append(.write(path, data))
            case .remove(let path):
                guard seen.insert(path).inserted else { throw GameDocumentError.duplicateChange(path) }
                repoChanges.append(.remove(path))
            }
        }
        try await verify(context, expectedRevision: expectedRevision)
        let project = try await repository.commit(context.projectID, owner: context.owner,
                                                  expectedRevision: expectedRevision,
                                                  changes: repoChanges, title: title)
        return project
    }

    /// Move/rename as one atomic revision, using the repository's relocation
    /// primitive. Unknown files are retained; no collision overwrites a file.
    public func relocate(_ context: GameProjectContext,
                         expectedRevision: String,
                         moves: [GameFileRelocation],
                         removeEmptyDirectories: Bool = false) async throws -> GameStoredProject {
        guard !moves.isEmpty else { throw GameDocumentError.noChanges }
        try await verify(context, expectedRevision: expectedRevision)
        return try await repository.relocateFiles(context.projectID, owner: context.owner,
                                                  expectedRevision: expectedRevision,
                                                  moves: moves,
                                                  removeEmptyDirectories: removeEmptyDirectories)
    }

    /// Saved revision history, newest first. It is metadata only and bounded
    /// by the repository's own history limit.
    public func history(_ context: GameProjectContext, limit: Int = 32) async throws -> [GameRevisionSummary] {
        guard (1...1_024).contains(limit) else { throw GameDocumentError.invalidPageLimit(limit) }
        _ = try await currentProject(context)
        let values = try await repository.history(context.projectID, owner: context.owner, limit: limit)
        return values.enumerated().map { GameRevisionSummary(project: $0.element, revisionIndex: $0.offset) }
    }

    /// Read one historical UTF-8 file for an explicit rollback/copy review.
    /// The live IDE/working tree is not modified by this read.
    public func readHistorical(_ context: GameProjectContext,
                               historicalRevision: String,
                               path: GameRelativePath,
                               offset: Int = 0,
                               limit: Int? = nil) async throws -> GameTextPage {
        let pageLimit = limit ?? maximumPageBytes
        guard (1...maximumPageBytes).contains(pageLimit) else {
            throw GameDocumentError.invalidPageLimit(pageLimit)
        }
        guard offset >= 0 else { throw GameDocumentError.invalidOffset(offset) }
        let project = try await currentProject(context)
        let data = try await repository.readHistorical(project.projectID, owner: project.owner,
                                                       expectedRevision: project.revision,
                                                       historicalRevision: historicalRevision,
                                                       path: path)
        guard data.count <= maximumTextBytes else {
            throw GameDocumentError.fileTooLarge(path, bytes: data.count, limit: maximumTextBytes)
        }
        return try textPage(data, path: path, revision: historicalRevision, sha256: GameDigest.sha256(data),
                            offset: offset, limit: pageLimit)
    }

    private func textPage(_ data: Data, path: GameRelativePath, revision: String, sha256: String,
                          offset: Int, limit: Int) throws -> GameTextPage {
        if data.contains(0) { throw GameDocumentError.binaryFile(path) }
        guard String(data: data, encoding: .utf8) != nil else { throw GameDocumentError.notUTF8(path) }
        guard offset <= data.count else { throw GameDocumentError.invalidOffset(offset) }
        var start = offset
        while start > 0, start < data.count, data[start] & 0xc0 == 0x80 { start -= 1 }
        var end = start + min(limit, data.count - start)
        while end > start, end < data.count, data[end] & 0xc0 == 0x80 { end -= 1 }
        // A byte limit smaller than the next complete scalar cannot make progress.
        guard end > start || start == data.count else { throw GameDocumentError.invalidPageLimit(limit) }
        return .init(path: path, revision: revision, sha256: sha256, totalBytes: data.count,
                     offset: start, nextOffset: end < data.count ? end : nil,
                     text: String(decoding: data[start..<end], as: UTF8.self))
    }

    /// Explicit history restore: creates a new HEAD whose parent is the
    /// current revision, so the previous bytes remain reachable. It never
    /// rewrites an imported folder or a frozen source.
    public func restore(_ context: GameProjectContext,
                        expectedRevision: String,
                        historicalRevision: String) async throws -> GameStoredProject {
        try await verify(context, expectedRevision: expectedRevision)
        return try await repository.restore(context.projectID, owner: context.owner,
                                            expectedRevision: expectedRevision,
                                            historicalRevision: historicalRevision)
    }

    /// Read-only check used by the App before opening a native editor or a
    /// run/build. It does not touch the working tree.
    public func verify(_ context: GameProjectContext, expectedRevision: String? = nil) async throws {
        let project = try await currentProject(context)
        if let expectedRevision, project.revision != expectedRevision {
            throw GameDocumentError.staleRevision(expected: expectedRevision, actual: project.revision)
        }
    }

    private func normalisedDirectory(_ value: String) -> String {
        value.isEmpty ? "." : value
    }
}

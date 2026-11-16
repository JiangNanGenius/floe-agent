// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Resolved by the existing host workspace/lease service, never by imported
/// game metadata. The live directory is shared with the existing IDE and Git.
public struct GameWorkingTreeBinding: Equatable, Sendable {
    public let workspaceID: UUID
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let rootURL: URL
    public let environmentID: String?

    public init(workspaceID: UUID, context: GameProjectContext) throws {
        if case .conversation(_, let id) = context.owner, id != workspaceID {
            throw GameProjectError.ownershipMismatch
        }
        self.workspaceID = workspaceID; projectID = context.projectID
        owner = context.owner; rootURL = context.rootURL; environmentID = context.environmentID
    }
}

public struct GameWorkingTreeSnapshot: Equatable, Sendable {
    public let binding: GameWorkingTreeBinding
    public let revision: String
    public let directories: [GameRelativePath]
    public let files: [GameProjectFile]
    public init(binding: GameWorkingTreeBinding, revision: String,
                directories: [GameRelativePath], files: [GameProjectFile]) throws {
        guard GameProjectContext.validIdentifier(revision) else { throw GameProjectError.invalidContext }
        self.binding = binding; self.revision = revision
        self.directories = directories; self.files = files
    }
}

/// Returned only by a repository with an actual host working-tree port.
/// A standalone qualification repository cannot impersonate the live IDE.
public struct GameWorkingProjectSnapshot: Sendable {
    public let project: GameStoredProject
    public let binding: GameWorkingTreeBinding
}

/// A trusted host may retain imported administrative data in immutable
/// history instead of replacing the existing IDE's Git repository. Files
/// selected for the live tree must be unchanged members of the full import.
public struct GameWorkingTreeImportTree: Sendable {
    public let directories: [GameRelativePath]
    public let files: [GameProjectFile]
    public init(directories: [GameRelativePath], files: [GameProjectFile]) {
        self.directories = directories; self.files = files
    }
}

/// A synchronous host transaction joins the immutable revision HEAD and the
/// actual managed workspace files without holding an NSLock across await.
///
/// Implementations retain existing path/mutation guards, validate the entire
/// expected tree, preserve .git administrative state, stage recoverable old
/// bytes, apply/verify the changes, then invoke publishMetadata EXACTLY once.
/// Failure before metadata publication must safely restore owned changes or
/// retain explicit recovery material if another writer changed those bytes.
/// Do not roll back a newer external writer. After successful publication,
/// optional journal cleanup cannot turn the commit into a reported failure.
public protocol GameWorkingTreePort: Sendable {
    func importedTree(_ project: GameStoredProject, limits: GameRepositoryLimits) throws -> GameWorkingTreeImportTree
    func snapshot(projectID: UUID, owner: GameProjectOwner,
                  limits: GameRepositoryLimits) throws -> GameWorkingTreeSnapshot
    func read(_ file: GameProjectFile, snapshot: GameWorkingTreeSnapshot,
              limits: GameRepositoryLimits) throws -> Data
    func transact(project: GameStoredProject, previous: GameStoredProject?,
                  limits: GameRepositoryLimits,
                  readObject: (GameProjectFile) throws -> Data,
                  objectURL: (GameProjectFile) throws -> URL,
                  publishMetadata: (String?) throws -> Void) throws
}

extension GameWorkingTreePort {
    public func importedTree(_ project: GameStoredProject, limits: GameRepositoryLimits) throws -> GameWorkingTreeImportTree {
        .init(directories: project.directories, files: project.files)
    }
}

/// Durable metadata only. The caller supplies its host-owned recovery storage;
/// these helpers grant no workspace access and never execute game code.
public enum GameWorkingTreeJournalFiles {
    public static func write(_ data: Data, to url: URL) throws {
        try GameFileStorage.directory(url.deletingLastPathComponent())
        try GameFileStorage.atomicWrite(data, to: url)
    }
    public static func read(_ url: URL, maximum: Int) throws -> Data {
        try GameFileStorage.read(url, maximum: maximum, honorCancellation: false)
    }
}

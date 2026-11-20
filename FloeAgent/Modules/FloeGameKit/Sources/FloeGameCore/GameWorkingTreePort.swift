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

/// A persistence key only. A caller must already own the project and use its
/// resolved live root for all file access. Only the iOS container UUID varies.
public enum GameSpaceRootIdentity {
    public static func persistedPath(_ path: String, owner: GameProjectOwner) -> String {
        persistedPath(path, owner: owner,
                      support: FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first)
    }

    /// Relocation-stable identity for persisted root references. An App-owned
    /// root keeps a container-relative token so a TestFlight/container UUID
    /// change does not invalidate recovery journals or selection records;
    /// every other root stays a strict absolute path. The token always names
    /// the actual owner so two owners can never alias one directory.
    static func persistedPath(_ path: String, owner: GameProjectOwner, support: URL?) -> String {
        guard let support,
              let prefix = Self.containerPrefix(support: support) else { return path }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard path == "/" + parts.dropFirst().joined(separator: "/"),
              parts.starts(with: prefix),
              parts.count >= prefix.count + 2,
              UUID(uuidString: parts[prefix.count]) != nil else { return path }
        // The path may come from a former container; only its UUID format is
        // validated, then it is stripped exactly like the live root's UUID.
        let suffix = parts.dropFirst(prefix.count + 1)
        switch owner {
        case .space:
            // <container>/Library/Application Support/FloeAgent/PersonalContent/
            //   <record>/.../<name>.floeproject/Game/Files
            guard parts.count >= prefix.count + 8,
                  suffix.starts(with: ["Library", "Application Support", "FloeAgent", "PersonalContent"]),
                  suffix.suffix(2).elementsEqual(["Game", "Files"]),
                  suffix.dropLast(2).last?.hasSuffix(".floeproject") == true else { return path }
            return "space-library:" + suffix.dropFirst(4).joined(separator: "/")
        case .conversation(let conversationID, let workspaceID):
            // Only the exact app-owned per-task root of THIS owner relocates:
            // <container>/Library/Application Support/FloeAgent/PrivateTasks/
            //   <conversationID>. Other chat roots stay strict absolute paths.
            // `suffix` is an ArraySlice: never index it, compare bounds+last.
            let task = conversationID.uuidString.lowercased()
            guard suffix.count == 5,
                  suffix.starts(with: ["Library", "Application Support", "FloeAgent", "PrivateTasks"]),
                  suffix.last?.caseInsensitiveCompare(task) == .orderedSame else { return path }
            return "chat-task:" + task + "/" + workspaceID.uuidString.lowercased()
        }
    }

    /// [.../Containers/Data/Application] prefix components of an iOS-style
    /// Application Support URL, or nil on hosts without that layout.
    private static func containerPrefix(support: URL) -> [String]? {
        let resolved = support.resolvingSymlinksInPath()
        let container = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let prefix = container.deletingLastPathComponent().pathComponents
        guard prefix.suffix(3).elementsEqual(["Containers", "Data", "Application"]),
              UUID(uuidString: container.lastPathComponent) != nil else { return nil }
        return prefix
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
    /// Write/import boundaries require actual bytes even when a host keeps
    /// metadata-based fingerprint hints for repeated read-only discovery.
    func verifiedSnapshot(projectID: UUID, owner: GameProjectOwner,
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
    public func verifiedSnapshot(projectID: UUID, owner: GameProjectOwner,
                                 limits: GameRepositoryLimits) throws -> GameWorkingTreeSnapshot {
        try snapshot(projectID: projectID, owner: owner, limits: limits)
    }
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

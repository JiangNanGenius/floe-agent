// SPDX-License-Identifier: MPL-2.0
//
// C01ProjectLibrary — the ONE real user-project library over the ORIGINAL
// `workspaces` table and the ORIGINAL managed storage layout.
//
// Main-settled contract (2026-11-01, C01 project seam):
//   * a managed project is exactly ONE `workspaces` row of kind `.project`
//     with an EMPTY security-scoped bookmark and
//     `internal_relative_path == "Projects/<projectUUID>"`. There is no
//     second project table, JSON registry, migration or DDL. The root is
//     `<accepted storageRoot>/Workspace/Projects/<projectUUID>` (0700,
//     non-following at every managed component).
//   * create validates the name and creates exactly ONE leaf. Opening an
//     existing project NEVER recreates a missing leaf: the typed root state
//     is reported instead, and the Linux/G04 resolvers fail closed.
//   * rename/assign/delete carry the OUTER revision `project.<uuid>` whose
//     version is the exact persisted `workspaces.updated_at` bytes. The
//     compare-and-swap is one SQLite writer transaction; a stale revision
//     writes nothing.
//   * `assign` is pre-first-run only. It requires an ordinary durable
//     conversation with no messages and no runs, no existing ownership
//     binding, no live run/G04 lease, and it holds the ORIGINAL
//     `RunDomainDeletionLifecycle` launch fence across the ownership insert.
//     Existing tasks are never silently relocated.
//   * `delete` defaults to `deleteRoot = false` and returns an explicit
//     retained-root receipt. Byte removal happens only for an explicit
//     `deleteRoot = true`, only under `Workspace/Projects/<uuid>`, and only
//     through a non-following cleaner. Foreign work is refused; an explicit
//     `stopActiveTasks` uses the ORIGINAL deletion lifecycle fence/drain and
//     aborts every acquired fence if any drain fails. Cancellation is never
//     treated as termination.
//   * Notes/private-task roots, WorkspaceTransfers, recovered edits,
//     credentials, environment layers and exports are never touched.
//
// This source is source-only: it is NOT compiled or executed by the
// authoring package. Main owns integration, compilation and device checks.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkspaceTools

// MARK: - Managed root layout (the ONE shared resolver)

/// Deterministic managed-root layout shared by the project library, the
/// Linux workspace authority and the G04 file/editor graph. Nothing here
/// guesses a first project, follows a symlink, accepts a SAF URI as POSIX,
/// or creates a missing project leaf after creation.
public enum C01ProjectRootRemoval: Sendable, Equatable {
    case removed
    case absent
    case failed(String)
}

public enum C01ProjectRootLayout {
    public static let projectsComponent = "Projects"
    public static let maximumProjectNameBytes = 240
    public static let maximumProjectNameCharacters = 80

    public static func internalRelativePath(projectID: UUID) -> String {
        "\(projectsComponent)/\(projectID.uuidString)"
    }

    public static func projectID(fromInternalRelativePath path: String?) -> UUID? {
        guard let path else { return nil }
        let prefix = "\(projectsComponent)/"
        guard path.hasPrefix(prefix) else { return nil }
        let leaf = String(path.dropFirst(prefix.count))
        guard !leaf.isEmpty, !leaf.contains("/"),
              let id = UUID(uuidString: leaf), id.uuidString == leaf else {
            return nil
        }
        return id
    }

    /// A managed project row: exact kind, empty bookmark and the exact
    /// deterministic relative path for its own id.
    public static func isManagedProject(_ record: WorkspaceRecord) -> Bool {
        record.kind == .project
            && record.rootBookmark.isEmpty
            && projectID(fromInternalRelativePath: record.internalRelativePath) == record.id
    }

    public static func workspaceDirectory(rootPath: String) -> String {
        rootPath + "/Workspace"
    }

    public static func projectsDirectory(rootPath: String) -> String {
        workspaceDirectory(rootPath: rootPath) + "/\(projectsComponent)"
    }

    public static func projectDirectory(rootPath: String, projectID: UUID) -> String {
        projectsDirectory(rootPath: rootPath) + "/\(projectID.uuidString)"
    }

    public enum RootState: Sendable, Equatable {
        case available
        case missing
        case unsafe(String)

        public var wireValue: String {
            switch self {
            case .available: return "available"
            case .missing: return "missing"
            case .unsafe: return "unsafe"
            }
        }

        public var issue: String? {
            if case .unsafe(let reason) = self { return reason }
            return nil
        }
    }

    /// Non-following inspection of the exact managed project leaf. A missing
    /// leaf is honestly `.missing` — never recreated. A symlink, regular
    /// file, special entry, unreadable component or wrong 0700 mode is
    /// `.unsafe` and is touched NOTHING.
    public static func inspectProjectDirectory(rootPath: String,
                                               projectID: UUID) -> RootState {
        guard rootPath.hasPrefix("/"), !rootPath.contains("\0") else {
            return .unsafe("storageRootInvalid")
        }
        let workspace = workspaceDirectory(rootPath: rootPath)
        switch WorkspaceNoFollow.kind(workspace) {
        case .directory: break
        case .missing: return .missing
        default: return .unsafe("workspaceComponentUnsafe")
        }
        let projects = projectsDirectory(rootPath: rootPath)
        switch WorkspaceNoFollow.kind(projects) {
        case .directory: break
        case .missing: return .missing
        default: return .unsafe("projectsComponentUnsafe")
        }
        let leaf = projectDirectory(rootPath: rootPath, projectID: projectID)
        switch WorkspaceNoFollow.kind(leaf) {
        case .directory:
            break
        case .missing:
            return .missing
        default:
            return .unsafe("projectRootNotDirectory")
        }
        guard let metadata = WorkspaceNoFollow.metadata(leaf),
              (metadata.mode & 0o7777) == 0o700 else {
            return .unsafe("projectRootPermissions")
        }
        return .available
    }

    /// Canonical root path for an already-validated persisted record. The
    /// private-task shape remains byte-identical to the original G02 rule;
    /// the project shape must be the managed project row. Returns nil for
    /// every other shape (no bookmark/SAF reinterpretation, no first guess).
    public static func canonicalRootPath(rootPath: String,
                                         record: WorkspaceRecord,
                                         conversationID: UUID) -> String? {
        switch record.kind {
        case .privateTask:
            guard record.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)"
            else { return nil }
            return workspaceDirectory(rootPath: rootPath) + "/PrivateTasks/\(conversationID.uuidString)"
        case .project:
            guard isManagedProject(record) else { return nil }
            return projectDirectory(rootPath: rootPath, projectID: record.id)
        }
    }

    /// Create the managed `Workspace`/`Projects` components (only when
    /// absent) and exactly ONE project leaf. Returns the created leaf path.
    /// Existing entries are never adopted: an existing leaf is a typed
    /// refusal so unknown bytes cannot be renamed into a new project.
    public static func createProjectDirectory(rootPath: String,
                                              projectID: UUID) -> Result<String, C01ProjectError> {
        guard rootPath.hasPrefix("/"), !rootPath.contains("\0"),
              WorkspaceNoFollow.kind(rootPath) == .directory else {
            return .failure(.rootUnsafe("storageRootUnsafe"))
        }
        let workspace = workspaceDirectory(rootPath: rootPath)
        if !ensureOwnedDirectory(workspace) {
            return .failure(.rootUnsafe("workspaceComponentUnsafe"))
        }
        let projects = projectsDirectory(rootPath: rootPath)
        if !ensureOwnedDirectory(projects) {
            return .failure(.rootUnsafe("projectsComponentUnsafe"))
        }
        let leaf = projectDirectory(rootPath: rootPath, projectID: projectID)
        switch WorkspaceNoFollow.kind(leaf) {
        case .missing:
            break
        case .directory:
            return .failure(.rootCreateFailed("projectRootAlreadyExists"))
        default:
            return .failure(.rootUnsafe("projectRootNotDirectory"))
        }
        guard mkdir(leaf, 0o700) == 0 else {
            return .failure(.rootCreateFailed("mkdirFailed:\(errno)"))
        }
        guard WorkspaceNoFollow.kind(leaf) == .directory,
              chmod(leaf, 0o700) == 0,
              let metadata = WorkspaceNoFollow.metadata(leaf),
              (metadata.mode & 0o7777) == 0o700 else {
            _ = rmdir(leaf)
            return .failure(.rootCreateFailed("postCreateValidation"))
        }
        return .success(leaf)
    }

    /// Remove ONLY the exact project leaf after an explicit deleteRoot.
    ///
    /// The removal is descriptor-relative: open the accepted root, then
    /// `Workspace`, then `Projects`, then the UUID leaf with
    /// `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`; children are enumerated from the
    /// opened directory and removed with `unlinkat` (AT_REMOVEDIR for
    /// directories). A symlink/directory-entry swap therefore cannot redirect
    /// traversal to another tree. The shared `Workspace`/`Projects`
    /// components are never removed. Depth/entry bounds and an honest
    /// `.failed` receipt are retained; this is not a new sandbox claim.
    public static func removeProjectDirectory(rootPath: String,
                                              projectID: UUID) -> C01ProjectRootRemoval {
        guard rootPath.hasPrefix("/"), !rootPath.contains("\0") else {
            return .failed("storageRootInvalid")
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFd = open(rootPath, flags)
        guard rootFd >= 0 else {
            return errno == ENOENT ? .absent : .failed("rootOpenFailed:\(errno)")
        }
        defer { close(rootFd) }
        var rootInfo = stat()
        guard fstat(rootFd, &rootInfo) == 0,
              (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            return .failed("rootNotDirectory")
        }
        let workspaceFd = openat(rootFd, "Workspace", flags)
        guard workspaceFd >= 0 else {
            return errno == ENOENT ? .absent : .failed("workspaceOpenFailed:\(errno)")
        }
        defer { close(workspaceFd) }
        var workspaceInfo = stat()
        guard fstat(workspaceFd, &workspaceInfo) == 0,
              (workspaceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              workspaceInfo.st_dev == rootInfo.st_dev else {
            return .failed("workspaceComponentUnsafe")
        }
        let projectsFd = openat(workspaceFd, "Projects", flags)
        guard projectsFd >= 0 else {
            return errno == ENOENT ? .absent : .failed("projectsOpenFailed:\(errno)")
        }
        defer { close(projectsFd) }
        var projectsInfo = stat()
        guard fstat(projectsFd, &projectsInfo) == 0,
              (projectsInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              projectsInfo.st_dev == workspaceInfo.st_dev else {
            return .failed("projectsComponentUnsafe")
        }
        let leafName = projectID.uuidString
        let leafFd = openat(projectsFd, leafName, flags)
        guard leafFd >= 0 else {
            return errno == ENOENT ? .absent : .failed("projectOpenFailed:\(errno)")
        }
        defer { close(leafFd) }
        var leafInfo = stat()
        guard fstat(leafFd, &leafInfo) == 0,
              (leafInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              leafInfo.st_dev == projectsInfo.st_dev else {
            return .failed("projectRootUnsafe")
        }
        var budget = C01ProjectRemovalBudget()
        switch removeDescriptorChildren(leafFd, depth: 0, budget: &budget) {
        case .failure(let reason):
            return .failed(reason)
        case .success:
            break
        }
        // The NAME may have been replaced after opening the leaf. Remove only
        // when it still names the exact opened inode; otherwise retain it.
        var current = stat()
        let currentResult = leafName.withCString {
            fstatat(projectsFd, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard currentResult == 0,
              (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              current.st_dev == leafInfo.st_dev,
              current.st_ino == leafInfo.st_ino else {
            return .failed("projectRootReplaced")
        }
        let removed = leafName.withCString { unlinkat(projectsFd, $0, AT_REMOVEDIR) }
        if removed == 0 { return .removed }
        if errno == ENOENT { return .absent }
        return .failed("rmdirFailed:\(errno)")
    }

    private static func removeDescriptorChildren(
        _ dirFd: Int32, depth: Int, budget: inout C01ProjectRemovalBudget
    ) -> C01ProjectRemovalWalkResult {
        guard depth <= maximumRemovalDepth else { return .failure("depthLimit") }
        let scanFd = dup(dirFd)
        guard scanFd >= 0 else { return .failure("scanDupFailed:\(errno)") }
        guard let dir = fdopendir(scanFd) else {
            close(scanFd)
            return .failure("scanOpenFailed:\(errno)")
        }
        defer { closedir(dir) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        while let entry = readdir(dir) {
            var nameTuple = entry.pointee.d_name
            let nameCapacity = MemoryLayout.size(ofValue: nameTuple)
            let decodedName = withUnsafePointer(to: &nameTuple) { raw in
                raw.withMemoryRebound(to: CChar.self,
                                      capacity: nameCapacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name = decodedName else { return .failure("entryNameInvalidUTF8") }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                return .failure("entryNameUnsafe")
            }
            budget.entries += 1
            guard budget.entries <= maximumRemovalEntries else {
                return .failure("entryLimit")
            }
            var info = stat()
            let statResult = name.withCString {
                fstatat(dirFd, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { return .failure("entryStatFailed:\(errno)") }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                let childFd = name.withCString { openat(dirFd, $0, flags) }
                guard childFd >= 0 else {
                    return .failure("childOpenFailed:\(errno)")
                }
                var childInfo = stat()
                guard fstat(childFd, &childInfo) == 0,
                      (childInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      childInfo.st_dev == info.st_dev,
                      childInfo.st_ino == info.st_ino else {
                    close(childFd)
                    return .failure("childIdentityChanged")
                }
                let childResult = removeDescriptorChildren(
                    childFd, depth: depth + 1, budget: &budget)
                close(childFd)
                if case .failure(let reason) = childResult { return .failure(reason) }
                var now = stat()
                let nowResult = name.withCString {
                    fstatat(dirFd, $0, &now, AT_SYMLINK_NOFOLLOW)
                }
                guard nowResult == 0,
                      now.st_dev == childInfo.st_dev,
                      now.st_ino == childInfo.st_ino else {
                    return .failure("childReplaced")
                }
                let removed = name.withCString {
                    unlinkat(dirFd, $0, AT_REMOVEDIR)
                }
                guard removed == 0 else {
                    return .failure("childRmdirFailed:\(errno)")
                }
            case mode_t(S_IFREG), mode_t(S_IFLNK):
                let removed = name.withCString { unlinkat(dirFd, $0, 0) }
                guard removed == 0 else {
                    return .failure("unlinkFailed:\(errno)")
                }
            default:
                return .failure("entryUnsafe")
            }
        }
        return .success
    }

    private static func ensureOwnedDirectory(_ path: String) -> Bool {
        switch WorkspaceNoFollow.kind(path) {
        case .directory:
            return true
        case .missing:
            if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
            return WorkspaceNoFollow.kind(path) == .directory
        default:
            return false
        }
    }

    private enum C01ProjectRemovalWalkResult {
        case success
        case failure(String)
    }

    private struct C01ProjectRemovalBudget {
        var entries = 0
    }

    private static let maximumRemovalEntries = 200_000
    private static let maximumRemovalDepth = 48

}

// MARK: - Typed errors

public enum C01ProjectError: Error, Sendable, Equatable {
    case invalidPayload(String)
    case invalidName
    case notFound
    case notProject
    case rootMissing
    case rootUnsafe(String)
    case rootCreateFailed(String)
    case staleRevision
    case conversationNotFound
    case purposeNotOrdinary
    case taskNotEmpty
    case taskAlreadyBound
    case taskBusy
    case projectBusy
    case ownerChanged
    case fenceHeld
    case drainFailed(String)
    case retired
    case storeFailed(String)

    public var wireCode: String {
        switch self {
        case .invalidPayload: return "invalidPayload"
        case .invalidName: return "invalidName"
        case .notFound, .conversationNotFound: return "notFound"
        case .notProject: return "notProject"
        case .rootMissing: return "rootMissing"
        case .rootUnsafe: return "rootUnsafe"
        case .rootCreateFailed: return "rootCreateFailed"
        case .staleRevision: return "staleRevision"
        case .purposeNotOrdinary: return "purposeNotOrdinary"
        case .taskNotEmpty: return "taskNotEmpty"
        case .taskAlreadyBound: return "taskAlreadyBound"
        case .taskBusy: return "taskBusy"
        case .projectBusy: return "projectBusy"
        case .ownerChanged: return "ownerChanged"
        case .fenceHeld: return "fenceHeld"
        case .drainFailed: return "drainFailed"
        case .retired: return "retired"
        case .storeFailed: return "storeFailed"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidPayload(let reason): return reason
        case .rootUnsafe(let reason): return reason
        case .rootCreateFailed(let reason): return reason
        case .drainFailed(let reason): return reason
        case .storeFailed(let reason): return reason
        default: return nil
        }
    }
}

// MARK: - Project value layer

public struct C01ProjectRow: Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// Exact persisted `workspaces.updated_at` string. This is the OUTER
    /// `project.<uuid>` revision version; it is never re-encoded here.
    public let revision: String
    public let createdAtRaw: String
    public let updatedAtRaw: String
    public let taskCount: Int

    public init(id: UUID, name: String, revision: String,
                createdAtRaw: String, updatedAtRaw: String, taskCount: Int) {
        self.id = id
        self.name = name
        self.revision = revision
        self.createdAtRaw = createdAtRaw
        self.updatedAtRaw = updatedAtRaw
        self.taskCount = taskCount
    }
}

public struct C01ProjectTaskRow: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let purpose: String
    public let updatedAtRaw: String
    public let isPinned: Bool
    public let isArchived: Bool

    public init(id: UUID, title: String, purpose: String,
                updatedAtRaw: String, isPinned: Bool, isArchived: Bool) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.updatedAtRaw = updatedAtRaw
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

public struct C01ProjectDetail: Sendable, Equatable {
    public let project: C01ProjectRow
    public let rootState: C01ProjectRootLayout.RootState
    public let tasks: [C01ProjectTaskRow]
    public let tasksTruncated: Bool

    public init(project: C01ProjectRow,
                rootState: C01ProjectRootLayout.RootState,
                tasks: [C01ProjectTaskRow], tasksTruncated: Bool) {
        self.project = project
        self.rootState = rootState
        self.tasks = tasks
        self.tasksTruncated = tasksTruncated
    }
}

public struct C01ProjectAssignmentReceipt: Sendable, Equatable {
    public let projectID: UUID
    public let conversationID: UUID
    public let revision: String
    public let alreadyAssigned: Bool
    public let fenceSettled: Bool
}

public struct C01ProjectDeleteReceipt: Sendable, Equatable {
    public let projectID: UUID
    public let rootRetained: Bool
    public let retainedRelativeRoot: String?
    public let rootRemoval: C01ProjectRootRemoval?
    public let fencesSettled: Bool
}


public actor C01ProjectLibrary {
    public static let defaultPageLimit = 50
    public static let maximumPageLimit = 100
    private static let maximumTaskProjection = 100

    public let epoch: UInt64
    private let cluster: G02OwnedStoreCluster
    private let rootPath: String
    private let lifecycleProvider: @Sendable () -> (any ConversationDeletionLifecycle)?
    private let liveCheck: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    /// Test-only override for the detached-token boundary probe. Production
    /// always uses the real RunDomain/G04/shell/job/registry ladder below.
    private let liveOwnedWorkProbe: (@Sendable ([UUID]) async -> Bool)?

    /// Production initializer: the accepted generation's ONE owned store
    /// cluster. No second DatabaseManager, no new table.
    public init(epoch: UInt64, cluster: G02OwnedStoreCluster) {
        self.epoch = epoch
        self.cluster = cluster
        self.rootPath = cluster.identity.root.path
        self.lifecycleProvider = {
            RunDomainFacade.current(epoch: epoch)?.1
        }
        self.liveCheck = {
            G02NativeRootEpoch.readback() == epoch
                && G02RuntimeComposition.shared.installedComposition?.epoch == epoch
        }
        self.now = { Date() }
        self.liveOwnedWorkProbe = nil
    }

    /// Test/qualification seam (same module): real stores, injected
    /// lifecycle/live clock. Production code never calls this.
    init(epoch: UInt64, cluster: G02OwnedStoreCluster,
         lifecycleProvider: @escaping @Sendable () -> (any ConversationDeletionLifecycle)?,
         liveCheck: @escaping @Sendable () -> Bool,
         now: @escaping @Sendable () -> Date = { Date() },
         liveOwnedWorkProbe: (@Sendable ([UUID]) async -> Bool)? = nil) {
        self.epoch = epoch
        self.cluster = cluster
        self.rootPath = cluster.identity.root.path
        self.lifecycleProvider = lifecycleProvider
        self.liveCheck = liveCheck
        self.now = now
        self.liveOwnedWorkProbe = liveOwnedWorkProbe
    }

    private var store: SQLiteWorkspaceStore { cluster.workspaceStore }
    private var database: DatabaseManager { cluster.database }

    // MARK: List / detail

    /// Deterministic bounded page of MANAGED projects only. Legacy private
    /// tasks, Notes and any external/bookmark project row are excluded by the
    /// exact kind/path/bookmark predicate — never by "first project".
    public func list(limit: Int = C01ProjectLibrary.defaultPageLimit,
                     offset: Int = 0) async throws -> [C01ProjectRow] {
        try requireLive()
        let boundedLimit = min(max(limit, 1), Self.maximumPageLimit)
        let boundedOffset = min(max(offset, 0), 100_000)
        let rows = try await database.reader { db -> [C01ProjectRow] in
            // The SELECT must carry every column the shared row parser
            // validates (`projectRow(from:)`: kind/root_bookmark/
            // internal_relative_path). GRDB returns nil for a column that
            // is not in the result set, and a nil managed-identity column
            // fails the parser guard — the row would be silently dropped
            // and every page would look authoritatively empty.
            try Row.fetchAll(db, sql: """
                SELECT w.id, w.name, w.kind, w.root_bookmark,
                       w.internal_relative_path,
                       w.created_at, w.updated_at,
                       (SELECT COUNT(*) FROM conversation_workspace_ownership o
                        JOIN conversations c ON c.id = o.conversation_id
                        WHERE o.workspace_id = w.id
                          AND c.purpose = 'ordinary') AS task_count
                FROM workspaces w
                WHERE w.kind = 'project'
                  AND length(w.root_bookmark) = 0
                  AND w.internal_relative_path = 'Projects/' || w.id
                ORDER BY w.updated_at DESC, w.id ASC
                LIMIT ? OFFSET ?
                """, arguments: [boundedLimit, boundedOffset])
                .compactMap(Self.projectRow(from:))
        }
        try requireLive()
        return rows
    }

    public func get(projectID: UUID) async throws -> C01ProjectDetail {
        try requireLive()
        let row = try await loadManagedRow(projectID: projectID)
        try requireLive()
        let rootState = C01ProjectRootLayout.inspectProjectDirectory(
            rootPath: rootPath, projectID: projectID)
        let tasks = try await taskProjection(projectID: projectID)
        try requireLive()
        return C01ProjectDetail(project: row.0, rootState: rootState,
                                tasks: tasks.rows, tasksTruncated: tasks.truncated)
    }

    /// Read-only eligibility projection used by the pre-first-run assigner
    /// and by focused tests. It performs no mutation and is not an authority
    /// by itself (assign revalidates inside its writer transaction).
    public func assignmentEligibility(projectID: UUID,
                                      conversationID: UUID) async throws -> Bool {
        try requireLive()
        _ = try await loadManagedRow(projectID: projectID)
        return try await database.reader { db in
            guard let purpose = try String.fetchOne(
                db, sql: "SELECT purpose FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]), purpose == "ordinary" else {
                return false
            }
            if try String.fetchOne(
                db, sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) != nil { return false }
            let messages = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let runs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            let pendingInputs = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_user_inputs WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]) ?? 0
            return messages == 0 && runs == 0 && pendingInputs == 0
        }
    }

    // MARK: Create

    public func create(name: String) async throws -> C01ProjectRow {
        try requireLive()
        let normalized = try Self.validateName(name)
        let projectID = UUID()
        let createdAt = now()
        switch C01ProjectRootLayout.createProjectDirectory(rootPath: rootPath,
                                                           projectID: projectID) {
        case .failure(let error):
            throw error
        case .success:
            break
        }
        let record = WorkspaceRecord(
            id: projectID,
            name: normalized,
            rootBookmark: Data(),
            activeTarget: .local,
            kind: .project,
            internalRelativePath: C01ProjectRootLayout.internalRelativePath(projectID: projectID),
            createdAt: createdAt,
            updatedAt: createdAt)
        do {
            try await store.saveWorkspace(record)
        } catch {
            // Only remove the exact leaf this call created, and only if it
            // is still an empty directory. A foreign/replaced or non-empty
            // entry is retained (rmdir refuses it); never recurse over data
            // that appeared after creation.
            let leaf = C01ProjectRootLayout.projectDirectory(
                rootPath: rootPath, projectID: projectID)
            if WorkspaceNoFollow.kind(leaf) == .directory { _ = rmdir(leaf) }
            throw C01ProjectError.storeFailed("create")
        }
        let loaded = try await loadManagedRow(projectID: projectID)
        return loaded.0
    }

    // MARK: Rename (exact persisted updated_at CAS)

    public func rename(projectID: UUID, name: String,
                       expectedRevision: String) async throws -> C01ProjectRow {
        try requireLive()
        let normalized = try Self.validateName(name)
        guard !expectedRevision.isEmpty else { throw C01ProjectError.staleRevision }
        let nowRaw = mutatedRevision(after: expectedRevision)
        let changed = try await database.writer { db -> Bool in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM workspaces WHERE id = ?",
                arguments: [projectID.uuidString]) else {
                throw C01ProjectError.notFound
            }
            try Self.requireManagedProjectRow(row, projectID: projectID)
            guard (row["updated_at"] as String) == expectedRevision else {
                throw C01ProjectError.staleRevision
            }
            try db.execute(sql: """
                UPDATE workspaces
                SET name = ?, updated_at = ?
                WHERE id = ? AND kind = 'project'
                  AND length(root_bookmark) = 0
                  AND internal_relative_path = 'Projects/' || id
                  AND updated_at = ?
                """, arguments: [normalized, nowRaw, projectID.uuidString, expectedRevision])
            guard db.changesCount == 1 else { throw C01ProjectError.staleRevision }
            return true
        }
        guard changed else { throw C01ProjectError.staleRevision }
        try requireLive()
        return try await loadManagedRow(projectID: projectID).0
    }

    // MARK: Pre-first-run assignment

    /// Assign an EXISTING empty ordinary conversation before its first run.
    /// The outer project revision is the exact persisted updated_at; the
    /// launch fence is the ORIGINAL RunDomainDeletionLifecycle (it invalidates
    /// the conversation's launch epoch and refuses while another guard is
    /// live). Existing ownership/file relocation is refused, never performed.
    public func assign(projectID: UUID, conversationID: UUID,
                       expectedRevision: String) async throws -> C01ProjectAssignmentReceipt {
        try requireLive()
        guard !expectedRevision.isEmpty else { throw C01ProjectError.staleRevision }
        let (project, detail) = try await loadManagedRow(projectID: projectID)
        switch detail {
        case .available: break
        case .missing: throw C01ProjectError.rootMissing
        case .unsafe(let reason): throw C01ProjectError.rootUnsafe(reason)
        }
        guard project.revision == expectedRevision else {
            throw C01ProjectError.staleRevision
        }
        guard let lifecycle = lifecycleProvider() else {
            throw C01ProjectError.fenceHeld
        }
        // Fast pre-check: live run/G04 work is refused BEFORE a deletion
        // fence can invalidate its launch scope/cancel its file lease.
        if await hasLiveOwnedWork([conversationID]) {
            throw C01ProjectError.taskBusy
        }
        // Fast pre-check: a conversation already bound elsewhere is refused
        // before any fence is minted (no silent relocation of old bytes).
        if let bound = try await store.workspaceID(conversationID: conversationID),
           bound != projectID {
            throw C01ProjectError.taskAlreadyBound
        }
        let operationID = UUID()
        let fence: ConversationDeletionFence
        do {
            fence = try await lifecycle.beginDeletionFence(
                conversationID: conversationID, epoch: epoch, operationID: operationID)
        } catch let failure as ConversationDeletionLifecycleFailure {
            throw Self.mapLifecycleFailure(failure)
        } catch {
            throw C01ProjectError.fenceHeld
        }
        do {
            try requireLive()
            guard C01ProjectRootLayout.inspectProjectDirectory(
                rootPath: rootPath, projectID: projectID) == .available else {
                throw C01ProjectError.rootMissing
            }
            if let (domain, _) = RunDomainFacade.current(epoch: epoch) {
                let owners = await domain.owners(conversationID: conversationID)
                let workspaceLeases = await domain.g04WorkspaceDrainEvidenceCount(
                    conversationID: conversationID)
                guard owners.isEmpty, workspaceLeases == 0 else {
                    throw C01ProjectError.taskBusy
                }
            }
            let nowRawValue = mutatedRevision(after: expectedRevision)
            let outcome = try await database.writer { db -> (String, Bool) in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM workspaces WHERE id = ?",
                    arguments: [projectID.uuidString]) else {
                    throw C01ProjectError.notFound
                }
                try Self.requireManagedProjectRow(row, projectID: projectID)
                guard (row["updated_at"] as String) == expectedRevision else {
                    throw C01ProjectError.staleRevision
                }
                guard let conversation = try Row.fetchOne(
                    db, sql: "SELECT id, purpose FROM conversations WHERE id = ?",
                    arguments: [conversationID.uuidString]) else {
                    throw C01ProjectError.conversationNotFound
                }
                guard (conversation["purpose"] as String) == "ordinary" else {
                    throw C01ProjectError.purposeNotOrdinary
                }
                let ownership = try String.fetchOne(
                    db, sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?",
                    arguments: [conversationID.uuidString])
                if let ownership {
                    guard ownership == projectID.uuidString else {
                        throw C01ProjectError.taskAlreadyBound
                    }
                    // Idempotent retry: ownership already matches. Do not
                    // bump the project revision or move anything.
                    return ((row["updated_at"] as String), true)
                }
                let messages = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                    arguments: [conversationID.uuidString]) ?? 0
                let runs = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM runs WHERE conversation_id = ?",
                    arguments: [conversationID.uuidString]) ?? 0
                let pendingInputs = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM pending_user_inputs WHERE conversation_id = ?",
                    arguments: [conversationID.uuidString]) ?? 0
                guard messages == 0, runs == 0, pendingInputs == 0 else {
                    throw C01ProjectError.taskNotEmpty
                }
                let nowRaw = nowRawValue
                try db.execute(sql: """
                    UPDATE workspaces
                    SET updated_at = ?
                    WHERE id = ? AND kind = 'project'
                      AND length(root_bookmark) = 0
                      AND internal_relative_path = 'Projects/' || id
                      AND updated_at = ?
                    """, arguments: [nowRaw, projectID.uuidString, expectedRevision])
                guard db.changesCount == 1 else { throw C01ProjectError.staleRevision }
                try db.execute(sql: """
                    INSERT INTO conversation_workspace_ownership
                        (conversation_id, workspace_id, assigned_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET
                        workspace_id = excluded.workspace_id,
                        assigned_at = excluded.assigned_at
                    WHERE conversation_workspace_ownership.workspace_id <> excluded.workspace_id
                    """, arguments: [conversationID.uuidString,
                                      projectID.uuidString, nowRaw])
                return (nowRaw, false)
            }
            let settlement = await lifecycle.commitDeletionFence(fence)
            let settled: Bool
            switch settlement {
            case .released, .alreadySettled:
                settled = true
            case .refusedForeignToken, .unavailable:
                _ = await lifecycle.abortDeletionFence(fence)
                settled = false
            }
            // The durable assignment/ownership/CAS transaction already
            // committed. A fence-settlement anomaly must not be reported as
            // an assignment failure (the UI would then delete a REAL empty
            // assigned task). Report the receipt honestly and let the next
            // launch surface any residual fence refusal.
            return C01ProjectAssignmentReceipt(
                projectID: projectID, conversationID: conversationID,
                revision: outcome.0, alreadyAssigned: outcome.1,
                fenceSettled: settled)
        } catch {
            _ = await lifecycle.abortDeletionFence(fence)
            throw Self.normalize(error)
        }
    }

    // MARK: Delete

    /// Delete the project row. Remaining tasks are rehomed by the ORIGINAL
    /// store's exact conditional transaction (patch 0011, never deleted).
    /// `deleteRoot` defaults to false and returns an explicit retained-root
    /// receipt; true uses the descriptor-relative Projects/<uuid> cleaner
    /// only after the DB commit.
    public func delete(projectID: UUID, expectedRevision: String,
                       deleteRoot: Bool = false,
                       stopActiveTasks: Bool = false) async throws
        -> C01ProjectDeleteReceipt {
        try requireLive()
        guard !expectedRevision.isEmpty else { throw C01ProjectError.staleRevision }
        let (project, rootState) = try await loadManagedRow(projectID: projectID)
        guard project.revision == expectedRevision else {
            throw C01ProjectError.staleRevision
        }
        switch rootState {
        case .unsafe(let reason): throw C01ProjectError.rootUnsafe(reason)
        case .available, .missing: break
        }
        let conversations = try await store.conversations(workspaceID: projectID)
        guard conversations.count <= 512 else { throw C01ProjectError.projectBusy }
        // A project owns ordinary tasks only. A foreign (Notes) row is a
        // preserved independent workspace: refuse the whole delete instead
        // of rehoming or touching it.
        for conversationID in conversations {
            guard let conversation = try await cluster.conversationStore
                .conversation(id: conversationID),
                  conversation.purpose == .ordinary else {
                throw C01ProjectError.projectBusy
            }
        }
        let lifecycle = lifecycleProvider()
        if !conversations.isEmpty, lifecycle == nil {
            throw C01ProjectError.fenceHeld
        }
        if !stopActiveTasks, await hasLiveOwnedWork(conversations) {
            throw C01ProjectError.projectBusy
        }
        var fences: [ConversationDeletionFence] = []
        do {
            for conversationID in conversations {
                try requireLive()
                guard let lifecycle else { throw C01ProjectError.fenceHeld }
                let fence: ConversationDeletionFence
                do {
                    fence = try await lifecycle.beginDeletionFence(
                        conversationID: conversationID, epoch: epoch,
                        operationID: UUID())
                } catch let failure as ConversationDeletionLifecycleFailure {
                    throw Self.mapLifecycleFailure(failure)
                } catch {
                    throw C01ProjectError.fenceHeld
                }
                fences.append(fence)
            }
            if stopActiveTasks, !fences.isEmpty {
                guard let lifecycle else { throw C01ProjectError.fenceHeld }
                // ALWAYS invoke the ORIGINAL drain for EVERY acquired fence —
                // never only when a run/G04 bool happened to be true. A
                // detached exec.shell or durable job can outlive its terminal
                // run and is still real owned work.
                for fence in fences {
                    do {
                        _ = try await lifecycle.drainOwnedWork(fence: fence)
                    } catch {
                        for acquired in fences {
                            _ = await lifecycle.abortDeletionFence(acquired)
                        }
                        throw C01ProjectError.drainFailed("ownedWork")
                    }
                }
            } else if await hasLiveOwnedWork(conversations) {
                if let lifecycle {
                    for fence in fences { _ = await lifecycle.abortDeletionFence(fence) }
                }
                throw C01ProjectError.projectBusy
            }
            try requireLive()
            // ONE atomic ORIGINAL-store transaction checks the exact persisted
            // project revision AND the exact fenced conversation snapshot,
            // then rehomes survivors and deletes the row. A rename/assign
            // that won after our snapshot makes this `.staleRevision` /
            // `.ownerChanged` with NOTHING deleted or rehomed. No timestamp
            // pre-claim and no separate destructive transaction exist.
            let outcome = try await store.deleteWorkspaceConditional(
                id: projectID,
                expectedUpdatedAt: expectedRevision,
                expectedConversationIDs: conversations)
            switch outcome {
            case .deleted:
                break
            case .notFound:
                throw C01ProjectError.notFound
            case .staleRevision:
                throw C01ProjectError.staleRevision
            case .ownerChanged:
                throw C01ProjectError.ownerChanged
            }
            var fencesSettled = true
            if let lifecycle {
                for fence in fences {
                    let settlement = await lifecycle.commitDeletionFence(fence)
                    switch settlement {
                    case .released, .alreadySettled:
                        break
                    case .refusedForeignToken, .unavailable:
                        _ = await lifecycle.abortDeletionFence(fence)
                        fencesSettled = false
                    }
                }
            }
            let relativeRoot = C01ProjectRootLayout.internalRelativePath(projectID: projectID)
            guard deleteRoot else {
                return C01ProjectDeleteReceipt(
                    projectID: projectID, rootRetained: true,
                    retainedRelativeRoot: relativeRoot, rootRemoval: nil,
                    fencesSettled: fencesSettled)
            }
            let removal = C01ProjectRootLayout.removeProjectDirectory(
                rootPath: rootPath, projectID: projectID)
            let retained: Bool
            switch removal {
            case .removed, .absent: retained = false
            case .failed: retained = true
            }
            return C01ProjectDeleteReceipt(
                projectID: projectID, rootRetained: retained,
                retainedRelativeRoot: retained ? relativeRoot : nil,
                rootRemoval: removal, fencesSettled: fencesSettled)
        } catch {
            if let lifecycle {
                for fence in fences {
                    _ = await lifecycle.abortDeletionFence(fence)
                }
            }
            throw Self.normalize(error)
        }
    }

    // MARK: - Internal reads

    /// Read-only pre-flight over EVERY real owned-work surface for these
    /// exact conversations:
    ///  * ORIGINAL run-domain ownership and G04 file-operation leases;
    ///  * retained `exec.shell` ledger receipts
    ///    (`RuntimeFacadeLinuxBindings.tokensForConversation(epoch:)`);
    ///  * durable job lifecycle receipts (`G03JobLifecycle`).
    /// A token counts only while `RuntimeOwnedWorkRegistry.isAttached` is true
    /// (detach happens at real completion). An absent run domain never skips
    /// the shell/job checks; no aggregate/unknown state counts as quiescent.
    private func hasLiveOwnedWork(_ conversationIDs: [UUID]) async -> Bool {
        if let liveOwnedWorkProbe {
            return await liveOwnedWorkProbe(conversationIDs)
        }
        let registry = RuntimeOwnedWorkRegistry.shared
        let domainPair = RunDomainFacade.current(epoch: epoch)
        let jobs = G03JobLifecycle.current.flatMap { $0.epoch == epoch ? $0 : nil }
        for conversationID in conversationIDs {
            if let (domain, _) = domainPair {
                if !(await domain.owners(conversationID: conversationID)).isEmpty {
                    return true
                }
                if let leases = await domain.workspaceOperationLeases[conversationID],
                   !leases.isEmpty {
                    return true
                }
            }
            let shellTokens = RuntimeFacadeLinuxBindings.shared
                .tokensForConversation(conversationID, epoch: epoch)
            if shellTokens.contains(where: { registry.isAttached($0) }) {
                return true
            }
            // C01 separated stdio: the channel's real engine lease is owned by
            // C01ManagedServiceDomain. Its Ram record remains visible until the
            // runtime proves the terminal release, so a live MCP stdio process
            // keeps this conversation non-quiescent for deletion/relocation.
            if C01ManagedServiceDomain.shared.liveStdioConversations(epoch: epoch)
                .contains(conversationID) {
                return true
            }
            if let jobs {
                let jobTokens = await jobs.tokensForConversation(conversationID)
                if jobTokens.contains(where: { registry.isAttached($0) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Persisted revision must strictly advance even when the wall clock
    /// resolves to the same millisecond as the previous write (fixed-clock
    /// test fixtures and fast retries). If the encoded candidate is not
    /// lexicographically later, advance the previous instant by 1 ms until
    /// the exact persisted string changes.
    private func mutatedRevision(after expected: String) -> String {
        let candidate = RunWireDate.encode(now())
        if candidate > expected { return candidate }
        guard let current = RunWireDate.decode(expected) else { return candidate }
        var bump = current
        var encoded = candidate
        var attempts = 0
        while encoded <= expected, attempts < 1_000 {
            bump = bump.addingTimeInterval(0.001)
            encoded = RunWireDate.encode(bump)
            attempts += 1
        }
        return encoded
    }

    private func requireLive() throws {
        // The injected production check already proves the accepted native
        // root epoch AND the exact installed composition. The test seam
        // supplies its own real-store check; no second epoch lookup is
        // fabricated here.
        guard liveCheck() else { throw C01ProjectError.retired }
    }

    private func loadManagedRow(projectID: UUID) async throws
        -> (C01ProjectRow, C01ProjectRootLayout.RootState) {
        let project = try await database.reader { db -> C01ProjectRow in
            guard let raw = try Row.fetchOne(
                db, sql: "SELECT * FROM workspaces WHERE id = ?",
                arguments: [projectID.uuidString]) else {
                throw C01ProjectError.notFound
            }
            try Self.requireManagedProjectRow(raw, projectID: projectID)
            let count = try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM conversation_workspace_ownership
                    WHERE workspace_id = ?
                    """, arguments: [projectID.uuidString]) ?? 0
            guard let id = UUID(uuidString: raw["id"] as String),
                  let updated = raw["updated_at"] as String? else {
                throw C01ProjectError.notProject
            }
            return C01ProjectRow(
                id: id, name: raw["name"] as String,
                revision: updated,
                createdAtRaw: raw["created_at"] as String,
                updatedAtRaw: updated, taskCount: count)
        }
        let state = C01ProjectRootLayout.inspectProjectDirectory(
            rootPath: rootPath, projectID: projectID)
        return (project, state)
    }

    private func taskProjection(projectID: UUID) async throws
        -> (rows: [C01ProjectTaskRow], truncated: Bool) {
        return try await database.reader { db -> (rows: [C01ProjectTaskRow], truncated: Bool) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.title, c.purpose, c.updated_at,
                       c.pinned_at, c.archived_at
                FROM conversation_workspace_ownership o
                JOIN conversations c ON c.id = o.conversation_id
                WHERE o.workspace_id = ? AND c.purpose = 'ordinary'
                ORDER BY (c.pinned_at IS NULL), c.pinned_at DESC,
                         c.updated_at DESC, c.id ASC
                LIMIT ?
                """, arguments: [projectID.uuidString,
                                  Self.maximumTaskProjection + 1])
            var projected: [C01ProjectTaskRow] = []
            for row in rows.prefix(Self.maximumTaskProjection) {
                guard let id = UUID(uuidString: row["id"] as String) else { continue }
                projected.append(C01ProjectTaskRow(
                    id: id,
                    title: String((row["title"] as String).prefix(120)),
                    purpose: row["purpose"] as String,
                    updatedAtRaw: row["updated_at"] as String,
                    isPinned: (row["pinned_at"] as String?) != nil,
                    isArchived: (row["archived_at"] as String?) != nil))
            }
            return (projected, rows.count > Self.maximumTaskProjection)
        }
    }

    private static func requireManagedProjectRow(_ row: Row, projectID: UUID) throws {
        guard (row["kind"] as String) == WorkspaceKind.project.rawValue,
              (row["internal_relative_path"] as String?)
                == C01ProjectRootLayout.internalRelativePath(projectID: projectID),
              let bookmark = row["root_bookmark"] as Data?, bookmark.isEmpty else {
            throw C01ProjectError.notProject
        }
        guard let id = UUID(uuidString: row["id"] as String), id == projectID else {
            throw C01ProjectError.notProject
        }
    }

    private static func projectRow(from row: Row) -> C01ProjectRow? {
        guard let id = UUID(uuidString: row["id"] as String),
              (row["internal_relative_path"] as String?)
                == C01ProjectRootLayout.internalRelativePath(projectID: id),
              (row["kind"] as String) == WorkspaceKind.project.rawValue,
              let bookmark = row["root_bookmark"] as Data?, bookmark.isEmpty,
              let updated = row["updated_at"] as String? else { return nil }
        return C01ProjectRow(
            id: id,
            name: row["name"] as String,
            revision: updated,
            createdAtRaw: row["created_at"] as String,
            updatedAtRaw: updated,
            taskCount: row["task_count"] as Int? ?? 0)
    }

    private static func validateName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= maximumNameCharacters,
              name.utf8.count <= C01ProjectRootLayout.maximumProjectNameBytes,
              !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 }),
              !name.contains("/"), !name.contains("\\") else {
            throw C01ProjectError.invalidName
        }
        return name
    }

    private static let maximumNameCharacters = C01ProjectRootLayout.maximumProjectNameCharacters

    private static func mapLifecycleFailure(_ failure: ConversationDeletionLifecycleFailure)
        -> C01ProjectError {
        switch failure {
        case .epochMismatch, .ownerUnavailable: return .fenceHeld
        case .fenceHeld: return .fenceHeld
        case .conversationNotFound: return .conversationNotFound
        case .fenceTokenRefused: return .fenceHeld
        case .drainUnavailable(let reason): return .drainFailed(reason)
        case .reportUnavailable(let reason): return .drainFailed(reason)
        }
    }

    private static func normalize(_ error: Error) -> C01ProjectError {
        if let typed = error as? C01ProjectError { return typed }
        if let failure = error as? ConversationDeletionLifecycleFailure {
            return mapLifecycleFailure(failure)
        }
        return .storeFailed("unexpected")
    }
}

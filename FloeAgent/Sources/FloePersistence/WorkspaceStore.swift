// FloePersistence — Workspace / recent-file / approval-grant store.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§5. Deterministic ordering
// throughout; writes are cancellation-safe because GRDB serialises writers.
// Credentials and file contents are never persisted here.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// A per-workspace recently opened file entry. Only the relative path and
/// display metadata are stored; the file body never enters the database.
public struct RecentFile: Sendable, Hashable {
    public var workspaceID: UUID
    public var relativePath: String
    public var displayName: String
    public var lastOpenedAt: Date

    public init(
        workspaceID: UUID,
        relativePath: String,
        displayName: String = "",
        lastOpenedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.displayName = displayName
        self.lastOpenedAt = lastOpenedAt
    }
}

/// A remembered approval scope ("this run / current project / host").
/// Carries only the tool name, normalised relative paths and expiry —
/// never argument bodies or secrets.
public struct StoredGrant: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var workspaceID: UUID?
    public var hostID: UUID?
    public var toolName: String
    public var paths: [String]
    public var singleUse: Bool
    public var policyName: String
    public var decidedAt: Date
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        hostID: UUID? = nil,
        toolName: String,
        paths: [String] = [],
        singleUse: Bool = true,
        policyName: String,
        decidedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.hostID = hostID
        self.toolName = toolName
        self.paths = paths
        self.singleUse = singleUse
        self.policyName = policyName
        self.decidedAt = decidedAt
        self.expiresAt = expiresAt
    }
}

/// Durable workspace access: CRUD, conversation links, recent files and
/// persisted approval grants.
public protocol WorkspaceStore: Sendable {
    func workspaces() async throws -> [WorkspaceRecord]
    func workspace(id: UUID) async throws -> WorkspaceRecord?
    func saveWorkspace(_ workspace: WorkspaceRecord) async throws
    func deleteWorkspace(id: UUID) async throws
    func touchLastOpened(id: UUID) async throws

    func linkConversation(workspaceID: UUID, conversationID: UUID) async throws
    func unlinkConversation(workspaceID: UUID, conversationID: UUID) async throws
    func conversations(workspaceID: UUID) async throws -> [UUID]

    func recordRecentFile(_ file: RecentFile) async throws
    func recentFiles(workspaceID: UUID) async throws -> [RecentFile]
    func removeRecentFile(workspaceID: UUID, relativePath: String) async throws

    func saveGrant(_ grant: StoredGrant) async throws
    func activeGrants(toolName: String, workspaceID: UUID?, hostID: UUID?) async throws -> [StoredGrant]
    /// Every stored grant regardless of scope or expiry (settings UI
    /// aggregates and renders them; expiry is a display concern there).
    func allGrants() async throws -> [StoredGrant]
    /// Removes one grant by id; deleting an absent id is a no-op.
    func deleteGrant(id: UUID) async throws
}

/// SQLite/GRDB implementation of `WorkspaceStore`.
public actor SQLiteWorkspaceStore: WorkspaceStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: Workspaces

    public func workspaces() async throws -> [WorkspaceRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM workspaces ORDER BY name COLLATE NOCASE, id"
            ).map(Self.workspace(from:))
        }
    }

    public func workspace(id: UUID) async throws -> WorkspaceRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM workspaces WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.workspace(from: row)
        }
    }

    public func saveWorkspace(_ workspace: WorkspaceRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces (
                        id, name, root_bookmark, last_opened_at,
                        active_target_kind, active_target_host_id,
                        inspector_state_json, instructions_rel_path,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        root_bookmark = excluded.root_bookmark,
                        last_opened_at = excluded.last_opened_at,
                        active_target_kind = excluded.active_target_kind,
                        active_target_host_id = excluded.active_target_host_id,
                        inspector_state_json = excluded.inspector_state_json,
                        instructions_rel_path = excluded.instructions_rel_path,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    workspace.id.uuidString,
                    workspace.name,
                    workspace.rootBookmark,
                    workspace.lastOpenedAt.map(PersistenceCodec.encode),
                    workspace.activeTarget.kindName,
                    workspace.activeTarget.hostID?.uuidString,
                    Self.encodeInspectorState(workspace.inspectorState),
                    workspace.instructionsRelativePath,
                    PersistenceCodec.encode(workspace.createdAt),
                    PersistenceCodec.encode(workspace.updatedAt)
                ]
            )
        }
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM workspaces WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    public func touchLastOpened(id: UUID) async throws {
        let now = PersistenceCodec.encode(Date())
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE workspaces SET last_opened_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.uuidString]
            )
        }
    }

    // MARK: Conversation links

    public func linkConversation(workspaceID: UUID, conversationID: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspace_conversations (workspace_id, conversation_id, created_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(workspace_id, conversation_id) DO NOTHING
                    """,
                arguments: [
                    workspaceID.uuidString,
                    conversationID.uuidString,
                    PersistenceCodec.encode(Date())
                ]
            )
        }
    }

    public func unlinkConversation(workspaceID: UUID, conversationID: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    DELETE FROM workspace_conversations
                    WHERE workspace_id = ? AND conversation_id = ?
                    """,
                arguments: [workspaceID.uuidString, conversationID.uuidString]
            )
        }
    }

    public func conversations(workspaceID: UUID) async throws -> [UUID] {
        try await database.reader { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT conversation_id FROM workspace_conversations
                    WHERE workspace_id = ? ORDER BY created_at, conversation_id
                    """,
                arguments: [workspaceID.uuidString]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    // MARK: Recent files

    public func recordRecentFile(_ file: RecentFile) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspace_recent_files (
                        workspace_id, relative_path, display_name, last_opened_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(workspace_id, relative_path) DO UPDATE SET
                        display_name = excluded.display_name,
                        last_opened_at = excluded.last_opened_at
                    """,
                arguments: [
                    file.workspaceID.uuidString,
                    file.relativePath,
                    file.displayName,
                    PersistenceCodec.encode(file.lastOpenedAt)
                ]
            )
        }
    }

    public func recentFiles(workspaceID: UUID) async throws -> [RecentFile] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM workspace_recent_files
                    WHERE workspace_id = ?
                    ORDER BY last_opened_at DESC, relative_path
                    """,
                arguments: [workspaceID.uuidString]
            ).map(Self.recentFile(from:))
        }
    }

    public func removeRecentFile(workspaceID: UUID, relativePath: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    DELETE FROM workspace_recent_files
                    WHERE workspace_id = ? AND relative_path = ?
                    """,
                arguments: [workspaceID.uuidString, relativePath]
            )
        }
    }

    // MARK: Approval grants

    public func saveGrant(_ grant: StoredGrant) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO approval_grants (
                        id, workspace_id, host_id, tool_name, paths_json,
                        single_use, policy_name, decided_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        workspace_id = excluded.workspace_id,
                        host_id = excluded.host_id,
                        tool_name = excluded.tool_name,
                        paths_json = excluded.paths_json,
                        single_use = excluded.single_use,
                        policy_name = excluded.policy_name,
                        decided_at = excluded.decided_at,
                        expires_at = excluded.expires_at
                    """,
                arguments: [
                    grant.id.uuidString,
                    grant.workspaceID?.uuidString,
                    grant.hostID?.uuidString,
                    grant.toolName,
                    Self.encodePaths(grant.paths),
                    grant.singleUse,
                    grant.policyName,
                    PersistenceCodec.encode(grant.decidedAt),
                    grant.expiresAt.map(PersistenceCodec.encode)
                ]
            )
        }
    }

    public func activeGrants(
        toolName: String,
        workspaceID: UUID?,
        hostID: UUID?
    ) async throws -> [StoredGrant] {
        try await database.reader { db in
            // Scope matching: a grant applies when every stored scope column
            // either matches the query or is NULL (scope-less grant). This
            // lets "current project" (workspace_id) and "host" (host_id)
            // grants be looked up independently.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM approval_grants
                    WHERE tool_name = ?
                      AND (workspace_id IS ? OR workspace_id = ?)
                      AND (host_id IS ? OR host_id = ?)
                    ORDER BY decided_at DESC, id
                    """,
                arguments: [
                    toolName,
                    workspaceID?.uuidString, workspaceID?.uuidString,
                    hostID?.uuidString, hostID?.uuidString
                ]
            )
            let now = Date()
            return try rows
                .map(Self.grant(from:))
                // Expired grants are treated as inactive.
                .filter { grant in
                    guard let expiresAt = grant.expiresAt else { return true }
                    return expiresAt > now
                }
        }
    }

    public func allGrants() async throws -> [StoredGrant] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM approval_grants ORDER BY decided_at DESC, id"
            ).map(Self.grant(from:))
        }
    }

    public func deleteGrant(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM approval_grants WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - Row mapping

    private static func workspace(from row: Row) throws -> WorkspaceRecord {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid workspace identifier")
        }
        let hostID: UUID? = (row["active_target_host_id"] as String?).flatMap(UUID.init(uuidString:))
        return WorkspaceRecord(
            id: id,
            name: row["name"],
            rootBookmark: row["root_bookmark"],
            lastOpenedAt: (row["last_opened_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) },
            activeTarget: WorkspaceTarget(kindName: row["active_target_kind"], hostID: hostID),
            inspectorState: try decodeInspectorState(row["inspector_state_json"]),
            instructionsRelativePath: row["instructions_rel_path"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"])
        )
    }

    private static func recentFile(from row: Row) throws -> RecentFile {
        guard let workspaceID = UUID(uuidString: row["workspace_id"]) else {
            throw FloeError.storageCorrupted("Invalid workspace identifier in recent files")
        }
        return RecentFile(
            workspaceID: workspaceID,
            relativePath: row["relative_path"],
            displayName: row["display_name"],
            lastOpenedAt: try PersistenceCodec.decodeDate(row["last_opened_at"])
        )
    }

    private static func grant(from row: Row) throws -> StoredGrant {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid approval grant identifier")
        }
        let workspaceID: UUID? = (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:))
        let hostID: UUID? = (row["host_id"] as String?).flatMap(UUID.init(uuidString:))
        return StoredGrant(
            id: id,
            workspaceID: workspaceID,
            hostID: hostID,
            toolName: row["tool_name"],
            paths: try decodePaths(row["paths_json"]),
            singleUse: row["single_use"],
            policyName: row["policy_name"],
            decidedAt: try PersistenceCodec.decodeDate(row["decided_at"]),
            expiresAt: (row["expires_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
        )
    }

    // MARK: - JSON helpers

    private static func encodeInspectorState(_ state: InspectorState) -> String {
        guard
            let data = try? JSONEncoder().encode(state),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private static func decodeInspectorState(_ json: String) throws -> InspectorState {
        guard !json.isEmpty else { return InspectorState() }
        do {
            return try JSONDecoder().decode(InspectorState.self, from: Data(json.utf8))
        } catch {
            throw FloeError.storageCorrupted("Invalid inspector state JSON in workspace row")
        }
    }

    private static func encodePaths(_ paths: [String]) -> String {
        guard
            let data = try? JSONEncoder().encode(paths),
            let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }

    private static func decodePaths(_ json: String) throws -> [String] {
        guard !json.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: Data(json.utf8))
        } catch {
            throw FloeError.storageCorrupted("Invalid paths JSON in approval grant row")
        }
    }
}

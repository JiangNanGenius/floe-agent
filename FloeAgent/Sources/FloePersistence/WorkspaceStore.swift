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
    func workspaceID(conversationID: UUID) async throws -> UUID?
    func assignConversation(workspaceID: UUID, conversationID: UUID) async throws
    func taskPolicy(conversationID: UUID) async throws -> TaskPolicy
    func saveTaskPolicy(_ policy: TaskPolicy) async throws

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
                        created_at, updated_at, kind, internal_relative_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        root_bookmark = excluded.root_bookmark,
                        last_opened_at = excluded.last_opened_at,
                        active_target_kind = excluded.active_target_kind,
                        active_target_host_id = excluded.active_target_host_id,
                        inspector_state_json = excluded.inspector_state_json,
                        instructions_rel_path = excluded.instructions_rel_path,
                        kind = excluded.kind,
                        internal_relative_path = excluded.internal_relative_path,
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
                    PersistenceCodec.encode(workspace.updatedAt),
                    workspace.kind.rawValue,
                    workspace.internalRelativePath
                ]
            )
        }
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await database.writer { db in
            // A task must never become ownerless. Removing a project moves
            // each surviving task into its own Floe-managed private workspace
            // before the external project bookmark is removed.
            try Self.moveOwnedConversationsToPrivateWorkspaces(
                in: db,
                workspaceID: id,
                now: PersistenceCodec.encode(Date())
            )
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
        try await assignConversation(workspaceID: workspaceID, conversationID: conversationID)
        // Compatibility projection only. New production paths read/write the
        // canonical one-to-one ownership table.
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspace_conversations
                        (workspace_id, conversation_id, created_at)
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
            if try String.fetchOne(
                db,
                sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) == workspaceID.uuidString {
                try Self.moveConversationToPrivateWorkspace(
                    in: db,
                    conversationID: conversationID.uuidString,
                    now: PersistenceCodec.encode(Date())
                )
            }
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
                    SELECT conversation_id FROM conversation_workspace_ownership
                    WHERE workspace_id = ? ORDER BY assigned_at, conversation_id
                    """,
                arguments: [workspaceID.uuidString]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    public func workspaceID(conversationID: UUID) async throws -> UUID? {
        try await database.reader { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT workspace_id FROM conversation_workspace_ownership
                    WHERE conversation_id = ?
                    """,
                arguments: [conversationID.uuidString]
            ).flatMap(UUID.init(uuidString:))
        }
    }

    public func assignConversation(workspaceID: UUID, conversationID: UUID) async throws {
        try await database.writer { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?)",
                arguments: [workspaceID.uuidString]
            ) == true else { throw FloeError.notFound("workspace \(workspaceID.uuidString)") }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                arguments: [conversationID.uuidString]
            ) == true else { throw FloeError.notFound("conversation \(conversationID.uuidString)") }
            try db.execute(
                sql: """
                    INSERT INTO conversation_workspace_ownership
                        (conversation_id, workspace_id, assigned_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET
                        workspace_id = excluded.workspace_id,
                        assigned_at = excluded.assigned_at
                    WHERE conversation_workspace_ownership.workspace_id <> excluded.workspace_id
                    """,
                arguments: [
                    conversationID.uuidString,
                    workspaceID.uuidString,
                    PersistenceCodec.encode(Date())
                ]
            )
        }
    }

    private static func moveOwnedConversationsToPrivateWorkspaces(
        in db: Database,
        workspaceID: UUID,
        now: String
    ) throws {
        let conversationIDs = try String.fetchAll(
            db,
            sql: "SELECT conversation_id FROM conversation_workspace_ownership WHERE workspace_id = ?",
            arguments: [workspaceID.uuidString]
        )
        for conversationID in conversationIDs {
            try moveConversationToPrivateWorkspace(
                in: db,
                conversationID: conversationID,
                now: now
            )
        }
    }

    private static func moveConversationToPrivateWorkspace(
        in db: Database,
        conversationID: String,
        now: String
    ) throws {
        let workspaceID = UUID().uuidString
        let title = try String.fetchOne(
            db,
            sql: "SELECT title FROM conversations WHERE id = ?",
            arguments: [conversationID]
        ) ?? ""
        let displayName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Chat" : String(title.prefix(80))
        try db.execute(
            sql: """
                INSERT INTO workspaces (
                    id, name, root_bookmark, last_opened_at,
                    active_target_kind, active_target_host_id,
                    inspector_state_json, instructions_rel_path,
                    created_at, updated_at, kind, internal_relative_path
                ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}', NULL, ?, ?,
                          'privateTask', ?)
                """,
            arguments: [
                workspaceID, displayName, Data(), now, now,
                "PrivateTasks/\(conversationID)"
            ]
        )
        try db.execute(
            sql: """
                UPDATE conversation_workspace_ownership
                SET workspace_id = ?, assigned_at = ?
                WHERE conversation_id = ?
                """,
            arguments: [workspaceID, now, conversationID]
        )
    }

    public func taskPolicy(conversationID: UUID) async throws -> TaskPolicy {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_policies WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) else { return TaskPolicy(conversationID: conversationID) }
            return try Self.taskPolicy(from: row)
        }
    }

    public func saveTaskPolicy(_ policy: TaskPolicy) async throws {
        try await database.writer { db in
            let tools = try policy.allowedToolNames.map { try Self.encodeJSON(Array($0).sorted()) }
            try db.execute(
                sql: """
                    INSERT INTO task_policies (
                        conversation_id, approval_mode, allowed_tool_names_json,
                        file_paths_json, network_allowed, browser_control_allowed,
                        upload_allowed, credentials_allowed, remote_execution_allowed,
                        recovery_policy, notification_policy, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET
                        approval_mode = excluded.approval_mode,
                        allowed_tool_names_json = excluded.allowed_tool_names_json,
                        file_paths_json = excluded.file_paths_json,
                        network_allowed = excluded.network_allowed,
                        browser_control_allowed = excluded.browser_control_allowed,
                        upload_allowed = excluded.upload_allowed,
                        credentials_allowed = excluded.credentials_allowed,
                        remote_execution_allowed = excluded.remote_execution_allowed,
                        recovery_policy = excluded.recovery_policy,
                        notification_policy = excluded.notification_policy,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    policy.conversationID.uuidString, policy.approvalMode, tools,
                    try Self.encodeJSON(policy.filePaths), policy.networkAllowed,
                    policy.browserControlAllowed, policy.uploadAllowed,
                    policy.credentialsAllowed, policy.remoteExecutionAllowed,
                    policy.recoveryPolicy.rawValue, policy.notificationPolicy.rawValue,
                    PersistenceCodec.encode(policy.updatedAt)
                ]
            )
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
            kind: WorkspaceKind(rawValue: row["kind"]) ?? .project,
            internalRelativePath: row["internal_relative_path"],
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

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode task policy")
        }
        return result
    }

    private static func taskPolicy(from row: Row) throws -> TaskPolicy {
        // Read every column NULL-safely. A legacy row written before a column
        // existed (or a partially-migrated row) must surface as a defaulted
        // policy, never crash the inspector on open/save.
        guard let conversationID = UUID(uuidString: row["conversation_id"]) else {
            throw FloeError.storageCorrupted("Invalid task policy conversation id")
        }
        let recoveryRaw: String? = row["recovery_policy"]
        let notificationsRaw: String? = row["notification_policy"]
        let recovery = recoveryRaw.flatMap(TaskRecoveryPolicy.init(rawValue:)) ?? .safePoint
        let notifications = notificationsRaw.flatMap(TaskNotificationPolicy.init(rawValue:)) ?? .stages
        let toolsJSON: String? = row["allowed_tool_names_json"]
        let tools = try toolsJSON.map {
            Set(try JSONDecoder().decode([String].self, from: Data($0.utf8)))
        }
        let pathsJSON: String = row["file_paths_json"] ?? "[]"
        let filePaths = (try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8))) ?? []
        return TaskPolicy(
            conversationID: conversationID,
            approvalMode: row["approval_mode"],
            allowedToolNames: tools,
            filePaths: filePaths,
            networkAllowed: row["network_allowed"],
            browserControlAllowed: row["browser_control_allowed"],
            uploadAllowed: row["upload_allowed"],
            credentialsAllowed: row["credentials_allowed"],
            remoteExecutionAllowed: row["remote_execution_allowed"],
            recoveryPolicy: recovery,
            notificationPolicy: notifications,
            updatedAt: (try? PersistenceCodec.decodeDate(row["updated_at"])) ?? Date()
        )
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

// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — trusted task/project resource association for `media.project`
// (job-385365036e904fb1).
//
// A media project opened by the user is not AI-editable merely because its
// recorded provenance names a task or a workspace. This file owns the ONE
// explicit trusted association that makes a selected project editable by ONE
// real task:
//
//  * the explicit selection is a host-only App operation protected by the
//    full accepted Root epoch + process owner token (JNI in
//    G09R2MediaToolAuthorityABI.swift). Native derives project storage from
//    the accepted project registry and validates the real task/workspace;
//  * the association is stored in the SAME accepted SQLite database (an
//    additive table, no second project database). It records only digests,
//    identities and the stable selection op id — never a path that can select
//    storage;
//  * a pending association authorizes NOTHING. The FIRST canonical
//    runtime-approved `media.project` call for the same task/project
//    validates the runtime-issued non-Codable authority read-only against the
//    original arguments/context and atomically pins the exact environment,
//    environment-binding digest and real workspace. Later calls must match
//    the pinned value; a nil environment is an explicit `none` state, never a
//    wildcard;
//  * a different task/environment/workspace is refused until a new explicit
//    trusted selection. Legacy chat/workspace-owned projects keep their exact
//    original ownership checks and never gain a binding implicitly.
//
// This is not a second approval engine: the ordinary runtime authority still
// decides whether a call is allowed. The association only names the trusted
// resource that the user selected, and the JNI issuer is not reachable from
// model-authored JSON.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeAndroidWorkbench

// MARK: - Typed failures

/// One bounded, user-actionable media task-binding refusal. Internal callers
/// map this to `FloeError`; the JNI maps the stable `code` to an App JSON
/// refusal without leaking paths or tokens.
enum G09R2MediaTaskBindingFailure: Error, Sendable, Equatable {
    case notReady
    case taskRequired
    case taskUnknown
    case workspaceUnavailable
    case projectGone
    case projectChanged
    case projectNotBindable(String)
    case projectAlreadyBound
    case bindingPending
    case bindingMissing
    case bindingRevoked
    case bindingMismatch
    case selectionConflict
    case storageUnresolved
    case environmentMismatch
    case workspaceMismatch
    case runtimeAuthorityInvalid(String)
    case proposalMissing
    case databaseUnavailable

    var code: String {
        switch self {
        case .notReady: return "notReady"
        case .taskRequired: return "taskRequired"
        case .taskUnknown: return "taskUnknown"
        case .workspaceUnavailable: return "workspaceUnavailable"
        case .projectGone: return "projectGone"
        case .projectChanged: return "projectChanged"
        case .projectNotBindable: return "projectNotBindable"
        case .projectAlreadyBound: return "projectAlreadyBound"
        case .bindingPending: return "bindingPending"
        case .bindingMissing: return "bindingMissing"
        case .bindingRevoked: return "bindingRevoked"
        case .bindingMismatch: return "bindingMismatch"
        case .selectionConflict: return "selectionConflict"
        case .storageUnresolved: return "storageUnresolved"
        case .environmentMismatch: return "environmentMismatch"
        case .workspaceMismatch: return "workspaceMismatch"
        case .runtimeAuthorityInvalid: return "runtimeAuthorityInvalid"
        case .proposalMissing: return "proposalMissing"
        case .databaseUnavailable: return "databaseUnavailable"
        }
    }

    var message: String {
        switch self {
        case .notReady:
            return "AI editing is not available yet; wait for the on-device runtime and try again"
        case .taskRequired:
            return "select the task that should own this media project"
        case .taskUnknown:
            return "the selected task no longer exists"
        case .workspaceUnavailable:
            return "the selected task has no usable workspace"
        case .projectGone:
            return "the media project no longer exists"
        case .projectChanged:
            return "the media project changed; reopen it and try again"
        case .projectNotBindable(let detail):
            return "this media project cannot be connected to the selected task (\(detail))"
        case .projectAlreadyBound:
            return "this media project is already connected to another task"
        case .bindingPending:
            return "the media project connection is waiting for its first authorized task call"
        case .bindingMissing:
            return "this media project is not connected to a task"
        case .bindingRevoked:
            return "the media project connection was removed"
        case .bindingMismatch:
            return "the media project connection no longer matches this task"
        case .selectionConflict:
            return "a different selection already used this operation"
        case .storageUnresolved:
            return "the media project storage does not match the selected task"
        case .environmentMismatch:
            return "the media project belongs to a different task environment"
        case .workspaceMismatch:
            return "the media project belongs to a different workspace"
        case .runtimeAuthorityInvalid(let detail):
            return "the media edit was not authorized for this exact task call (\(detail))"
        case .proposalMissing:
            return "the pending media proposal no longer exists"
        case .databaseUnavailable:
            return "the media project connection could not be read"
        }
    }

    var floError: FloeError {
        switch self {
        case .projectGone, .proposalMissing:
            return .notFound(message)
        case .taskRequired, .taskUnknown, .workspaceUnavailable, .projectNotBindable,
             .projectAlreadyBound, .bindingMismatch, .environmentMismatch,
             .workspaceMismatch, .runtimeAuthorityInvalid:
            return .unauthorized
        case .databaseUnavailable:
            return .storageCorrupted(message)
        default:
            return .validationFailed(message)
        }
    }
}

// MARK: - Wire DTOs (host-only JNI)

struct G09R2MediaTaskSelectionRequest: Decodable, Sendable {
    var selectionOpID: String
    var projectID: UUID
    var taskID: UUID
    var expectedRevision: Int64?
    var replaceExisting: Bool?
}

struct G09R2MediaTaskRevokeRequest: Decodable, Sendable {
    var projectID: UUID
    var bindingID: UUID?
    var taskID: UUID?
}

struct G09R2MediaProjectGrantRequest: Decodable, Sendable {
    var projectID: UUID
    var proposalID: UUID
    var revision: Int64
    var taskID: UUID?
}

struct G09R2MediaTaskBindingView: Encodable, Sendable {
    var bindingID: String
    var selectionOpID: String
    var projectID: String
    var taskID: String
    var workspaceID: String
    var state: String
    var storage: String
    var projectRevision: Int64
    var environment: String?
    var environmentID: String?
}

struct G09R2MediaToolAuthorityReply: Encodable, Sendable {
    var ok: Bool
    var error: String?
    var message: String?
    var binding: G09R2MediaTaskBindingView?
    var grantID: String?
    var projectID: String?
    var proposalID: String?
    var revision: Int64?
}

// MARK: - Durable association

struct G09R2MediaTaskBindingRecord: Sendable {
    enum State: String, Sendable, Equatable {
        case pending
        case pinned
        case revoked
    }

    var bindingID: UUID
    var selectionOpID: String
    var rootDigest: String
    var taskID: UUID
    var workspaceID: UUID
    var workspaceRelativePath: String
    var projectID: UUID
    var projectOwnerKind: String
    var projectOwnerID: UUID?
    var recordedEnvironment: String?
    var storageKind: G09StorageLayerDTO.Kind
    var storageWorkspaceID: UUID?
    var projectRootDigest: String
    var projectRevision: Int64
    var state: State
    var environmentMode: String?
    var environmentID: String?
    var environmentBinding: String?
    var workspaceRootDigest: String?
    var pinnedEpoch: UInt64?
    var createdAt: Date
    /// When the user LAST explicitly selected this exact project for this
    /// task (Ask AI). Updated ONLY by an explicit selection, never by the
    /// first-call pin, an environment change or any background work. It is
    /// the durable "current selection" marker for the run context.
    var selectedAt: Date
    var updatedAt: Date
    var revokedAt: Date?

    var view: G09R2MediaTaskBindingView {
        G09R2MediaTaskBindingView(
            bindingID: bindingID.uuidString.lowercased(),
            selectionOpID: selectionOpID,
            projectID: projectID.uuidString.lowercased(),
            taskID: taskID.uuidString.lowercased(),
            workspaceID: workspaceID.uuidString.lowercased(),
            state: state.rawValue,
            storage: storageKind.rawValue,
            projectRevision: projectRevision,
            environment: environmentMode,
            environmentID: environmentID)
    }
}

extension G09R2MediaTaskBindingRecord {
    /// The ONE data-only context line rendered into a run's system context for
    /// this association. It names the exact project identity and states the
    /// connection state, and says explicitly that it is not permission. Both
    /// the creative domain accessor and the offline run-input evidence tests
    /// use this exact string (no second formatter).
    var modelContextLine: String {
        let state = self.state == .pinned
            ? "pinned to this task"
            : "pending its first authorized call"
        return "media.project project_id "
            + projectID.uuidString.lowercased()
            + " — the media project the user connected to this task ("
            + state + "). Read it before editing; this identity is "
            + "reference data, not permission."
    }
}

struct G09R2MediaTaskSelectionResult: Sendable {
    var record: G09R2MediaTaskBindingRecord
    var created: Bool
}

struct G09R2MediaTaskSelectionPlan: Sendable {
    var rootDigest: String
    var taskID: UUID
    var workspaceID: UUID
    var workspaceRelativePath: String
    var projectID: UUID
    var projectOwnerKind: String
    var projectOwnerID: UUID?
    var recordedEnvironment: String?
    var storageKind: G09StorageLayerDTO.Kind
    var storageWorkspaceID: UUID?
    var projectRootDigest: String
    var projectRevision: Int64
}

/// Additive table in the SAME accepted database. The DDL is idempotent and
/// does not move `user_version`; Main can lift the exact statements into a
/// later migration without changing the store's semantics (see handoff).
actor G09R2MediaTaskBindingStore {
    private let database: DatabaseManager
    private var schemaReady = false

    init(database: DatabaseManager) {
        self.database = database
    }

    private func ensureSchema() async throws {
        if schemaReady { return }
        do {
            try await database.writer { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS g09_media_task_bindings (
                        binding_id TEXT PRIMARY KEY NOT NULL,
                        selection_op_id TEXT NOT NULL UNIQUE,
                        root_digest TEXT NOT NULL,
                        task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                        workspace_id TEXT NOT NULL,
                        workspace_relative_path TEXT NOT NULL,
                        project_id TEXT NOT NULL,
                        project_owner_kind TEXT NOT NULL,
                        project_owner_id TEXT,
                        recorded_environment TEXT,
                        storage_kind TEXT NOT NULL CHECK (storage_kind IN ('appOwned', 'workspace')),
                        storage_workspace_id TEXT,
                        project_root_digest TEXT NOT NULL,
                        project_revision INTEGER NOT NULL,
                        state TEXT NOT NULL CHECK (state IN ('pending', 'pinned', 'revoked')),
                        environment_mode TEXT CHECK (environment_mode IN ('explicit', 'none')),
                        environment_id TEXT,
                        environment_binding TEXT,
                        workspace_root_digest TEXT,
                        pinned_epoch INTEGER,
                        created_at REAL NOT NULL,
                        selected_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        revoked_at REAL
                    ) STRICT
                    """)
                // Additive, idempotent column for a table created by an
                // earlier build of this store (no user_version change and no
                // second store). Pre-fix rows were created by an explicit
                // selection, so created_at is their truthful marker.
                let columns = try Row.fetchAll(
                    db, sql: "PRAGMA table_info(g09_media_task_bindings)")
                let names = Set(columns.compactMap { $0["name"] as String? })
                if !names.contains("selected_at") {
                    try db.execute(sql: """
                        ALTER TABLE g09_media_task_bindings
                        ADD COLUMN selected_at REAL
                        """)
                    try db.execute(sql: """
                        UPDATE g09_media_task_bindings
                        SET selected_at = created_at
                        WHERE selected_at IS NULL
                        """)
                }
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_g09_media_task_bindings_active_project
                    ON g09_media_task_bindings(project_id)
                    WHERE state IN ('pending', 'pinned')
                    """)
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_g09_media_task_bindings_task
                    ON g09_media_task_bindings(task_id, state)
                    """)
            }
            schemaReady = true
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    /// The active (pending/pinned) association for one project, never a
    /// revoked row. A missing row is the ordinary "no explicit binding" case.
    func active(projectID: UUID) async throws -> G09R2MediaTaskBindingRecord? {
        try await ensureSchema()
        do {
            return try await database.reader { db in
                try Self.active(projectID: projectID, db: db)
            }
        } catch let failure as G09R2MediaTaskBindingFailure {
            throw failure
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    /// The ONE exact explicit selection currently in force for this task: the
    /// active (pending/pinned) association whose `selected_at` marker is the
    /// newest. The marker is written ONLY by an explicit Ask AI selection (a
    /// same-project reselection refreshes it), never by the first-call pin or
    /// any background work, so it is the real current selection rather than a
    /// recency guess.
    ///
    /// READ-ONLY: a database that never used the explicit association has no
    /// table and returns nil WITHOUT creating one. Revoked rows are never
    /// returned. This is model context, not authority: every `media.project`
    /// call still goes through the binding/runtime authorization path.
    func currentSelection(taskID: UUID) async throws
        -> G09R2MediaTaskBindingRecord? {
        do {
            return try await database.reader { db in
                guard try Self.tableExists(db) else { return nil }
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM g09_media_task_bindings
                        WHERE task_id = ? AND state IN ('pending', 'pinned')
                        ORDER BY COALESCE(selected_at, created_at) DESC,
                                 created_at DESC, binding_id DESC
                        LIMIT 1
                        """,
                    arguments: [taskID.uuidString])
                return try row.map { try Self.record(from: $0) }
            }
        } catch let failure as G09R2MediaTaskBindingFailure {
            throw failure
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    /// Read-only existence probe: this store's own additive table may not
    /// exist in a database that never used the explicit association, and a
    /// run-context read must never create it as a side effect.
    private static func tableExists(_ db: Database) throws -> Bool {
        try Row.fetchOne(
            db,
            sql: """
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'g09_media_task_bindings'
                """) != nil
    }

    /// Explicit trusted selection. The caller has already validated the real
    /// task/workspace/project; this transaction decides idempotency vs an
    /// explicit replacement and enforces one active association per project.
    func select(plan: G09R2MediaTaskSelectionPlan,
                request: G09R2MediaTaskSelectionRequest,
                now: Date = Date()) async throws -> G09R2MediaTaskSelectionResult {
        try await ensureSchema()
        do {
            return try await database.writer { db in
                try Self.prune(db: db, now: now)
                if let existing = try Self.bySelection(request.selectionOpID, db: db) {
                    guard existing.projectID == plan.projectID,
                          existing.taskID == plan.taskID,
                          existing.workspaceID == plan.workspaceID,
                          existing.storageKind == plan.storageKind,
                          existing.storageWorkspaceID == plan.storageWorkspaceID else {
                        throw G09R2MediaTaskBindingFailure.selectionConflict
                    }
                    guard existing.state != .revoked else {
                        throw G09R2MediaTaskBindingFailure.bindingRevoked
                    }
                    return G09R2MediaTaskSelectionResult(
                        record: existing, created: false)
                }
                if let active = try Self.active(projectID: plan.projectID, db: db) {
                    if active.taskID == plan.taskID,
                       active.workspaceID == plan.workspaceID,
                       active.storageKind == plan.storageKind,
                       active.storageWorkspaceID == plan.storageWorkspaceID,
                       active.projectID == plan.projectID {
                        // A NEW explicit selection operation for an already
                        // associated project (same task/workspace/storage):
                        // keep the exact association and authority untouched,
                        // but move the durable current-selection marker. This
                        // is what lets a reselection of an older project win
                        // over any number of newer associations.
                        try db.execute(sql: """
                            UPDATE g09_media_task_bindings
                            SET selected_at = ?
                            WHERE binding_id = ? AND state IN ('pending', 'pinned')
                            """, arguments: [now.timeIntervalSince1970,
                                             active.bindingID.uuidString])
                        guard let refreshed = try Self.byID(active.bindingID, db: db) else {
                            throw G09R2MediaTaskBindingFailure.databaseUnavailable
                        }
                        return G09R2MediaTaskSelectionResult(
                            record: refreshed, created: false)
                    }
                    guard request.replaceExisting == true else {
                        throw G09R2MediaTaskBindingFailure.projectAlreadyBound
                    }
                    try db.execute(sql: """
                        UPDATE g09_media_task_bindings
                        SET state = 'revoked', revoked_at = ?, updated_at = ?
                        WHERE binding_id = ? AND state IN ('pending', 'pinned')
                        """, arguments: [now.timeIntervalSince1970,
                                         now.timeIntervalSince1970,
                                         active.bindingID.uuidString])
                }
                let record = G09R2MediaTaskBindingRecord(
                    bindingID: UUID(),
                    selectionOpID: request.selectionOpID,
                    rootDigest: plan.rootDigest,
                    taskID: plan.taskID,
                    workspaceID: plan.workspaceID,
                    workspaceRelativePath: plan.workspaceRelativePath,
                    projectID: plan.projectID,
                    projectOwnerKind: plan.projectOwnerKind,
                    projectOwnerID: plan.projectOwnerID,
                    recordedEnvironment: plan.recordedEnvironment,
                    storageKind: plan.storageKind,
                    storageWorkspaceID: plan.storageWorkspaceID,
                    projectRootDigest: plan.projectRootDigest,
                    projectRevision: plan.projectRevision,
                    state: .pending,
                    environmentMode: nil,
                    environmentID: nil,
                    environmentBinding: nil,
                    workspaceRootDigest: nil,
                    pinnedEpoch: nil,
                    createdAt: now,
                    selectedAt: now,
                    updatedAt: now,
                    revokedAt: nil)
                try Self.insert(record, db: db)
                return G09R2MediaTaskSelectionResult(record: record, created: true)
            }
        } catch let failure as G09R2MediaTaskBindingFailure {
            throw failure
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    /// Atomic pending -> pinned CAS. The update only succeeds for the exact
    /// pending row under the SAME root/task/project; a concurrent winner is
    /// returned so the caller can require byte-for-byte pinned equality.
    func pin(bindingID: UUID,
             rootDigest: String,
             taskID: UUID,
             projectID: UUID,
             environmentMode: String,
             environmentID: String?,
             environmentBinding: String,
             workspaceRootDigest: String,
             epoch: UInt64,
             now: Date = Date()) async throws -> G09R2MediaTaskBindingRecord? {
        try await ensureSchema()
        do {
            return try await database.writer { db in
                try db.execute(sql: """
                    UPDATE g09_media_task_bindings
                    SET state = 'pinned', environment_mode = ?, environment_id = ?,
                        environment_binding = ?, workspace_root_digest = ?,
                        pinned_epoch = ?, updated_at = ?
                    WHERE binding_id = ? AND state = 'pending' AND root_digest = ?
                      AND task_id = ? AND project_id = ?
                    """, arguments: [environmentMode,
                                     environmentID,
                                     environmentBinding,
                                     workspaceRootDigest,
                                     Int64(bitPattern: epoch),
                                     now.timeIntervalSince1970,
                                     bindingID.uuidString,
                                     rootDigest,
                                     taskID.uuidString,
                                     projectID.uuidString])
                return try Self.byID(bindingID, db: db)
            }
        } catch let failure as G09R2MediaTaskBindingFailure {
            throw failure
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    func revoke(projectID: UUID, bindingID: UUID?, taskID: UUID?,
                now: Date = Date()) async throws -> Bool {
        try await ensureSchema()
        do {
            return try await database.writer { db in
                try db.execute(sql: """
                    UPDATE g09_media_task_bindings
                    SET state = 'revoked', revoked_at = ?, updated_at = ?
                    WHERE project_id = ? AND state IN ('pending', 'pinned')
                      AND (? IS NULL OR binding_id = ?)
                      AND (? IS NULL OR task_id = ?)
                    """, arguments: [now.timeIntervalSince1970,
                                     now.timeIntervalSince1970,
                                     projectID.uuidString,
                                     bindingID?.uuidString,
                                     bindingID?.uuidString,
                                     taskID?.uuidString,
                                     taskID?.uuidString])
                return db.changesCount == 1
            }
        } catch let failure as G09R2MediaTaskBindingFailure {
            throw failure
        } catch {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
    }

    // MARK: Row helpers

    private static func active(projectID: UUID, db: Database) throws
        -> G09R2MediaTaskBindingRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM g09_media_task_bindings
                WHERE project_id = ? AND state IN ('pending', 'pinned')
                ORDER BY created_at DESC LIMIT 1
                """,
            arguments: [projectID.uuidString]) else {
            return nil
        }
        return try record(from: row)
    }

    private static func bySelection(_ opID: String, db: Database) throws
        -> G09R2MediaTaskBindingRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM g09_media_task_bindings WHERE selection_op_id = ?",
            arguments: [opID]) else {
            return nil
        }
        return try record(from: row)
    }

    private static func byID(_ id: UUID, db: Database) throws
        -> G09R2MediaTaskBindingRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM g09_media_task_bindings WHERE binding_id = ?",
            arguments: [id.uuidString]) else {
            return nil
        }
        return try record(from: row)
    }

    private static func insert(_ record: G09R2MediaTaskBindingRecord,
                               db: Database) throws {
        try db.execute(sql: """
            INSERT INTO g09_media_task_bindings (
                binding_id, selection_op_id, root_digest, task_id,
                workspace_id, workspace_relative_path, project_id,
                project_owner_kind, project_owner_id, recorded_environment,
                storage_kind, storage_workspace_id, project_root_digest,
                project_revision, state, environment_mode, environment_id,
                environment_binding, workspace_root_digest, pinned_epoch,
                created_at, selected_at, updated_at, revoked_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.bindingID.uuidString,
                record.selectionOpID,
                record.rootDigest,
                record.taskID.uuidString,
                record.workspaceID.uuidString,
                record.workspaceRelativePath,
                record.projectID.uuidString,
                record.projectOwnerKind,
                record.projectOwnerID?.uuidString,
                record.recordedEnvironment,
                record.storageKind.rawValue,
                record.storageWorkspaceID?.uuidString,
                record.projectRootDigest,
                record.projectRevision,
                record.state.rawValue,
                record.environmentMode,
                record.environmentID,
                record.environmentBinding,
                record.workspaceRootDigest,
                record.pinnedEpoch.map { Int64(bitPattern: $0) },
                record.createdAt.timeIntervalSince1970,
                record.selectedAt.timeIntervalSince1970,
                record.updatedAt.timeIntervalSince1970,
                record.revokedAt?.timeIntervalSince1970,
            ])
    }

    private static func record(from row: Row) throws
        -> G09R2MediaTaskBindingRecord {
        guard let bindingID = UUID(uuidString: row["binding_id"]),
              let taskID = UUID(uuidString: row["task_id"]),
              let workspaceID = UUID(uuidString: row["workspace_id"]),
              let projectID = UUID(uuidString: row["project_id"]),
              let storageKind = G09StorageLayerDTO.Kind(rawValue: row["storage_kind"]),
              let state = G09R2MediaTaskBindingRecord.State(rawValue: row["state"]) else {
            throw G09R2MediaTaskBindingFailure.databaseUnavailable
        }
        let ownerID: UUID? = (row["project_owner_id"] as String?).flatMap(UUID.init(uuidString:))
        let storageWorkspaceID: UUID? =
            (row["storage_workspace_id"] as String?).flatMap(UUID.init(uuidString:))
        let pinnedEpoch: UInt64? = (row["pinned_epoch"] as Int64?)
            .map { UInt64(bitPattern: $0) }
        return G09R2MediaTaskBindingRecord(
            bindingID: bindingID,
            selectionOpID: row["selection_op_id"],
            rootDigest: row["root_digest"],
            taskID: taskID,
            workspaceID: workspaceID,
            workspaceRelativePath: row["workspace_relative_path"],
            projectID: projectID,
            projectOwnerKind: row["project_owner_kind"],
            projectOwnerID: ownerID,
            recordedEnvironment: row["recorded_environment"],
            storageKind: storageKind,
            storageWorkspaceID: storageWorkspaceID,
            projectRootDigest: row["project_root_digest"],
            projectRevision: row["project_revision"],
            state: state,
            environmentMode: row["environment_mode"],
            environmentID: row["environment_id"],
            environmentBinding: row["environment_binding"],
            workspaceRootDigest: row["workspace_root_digest"],
            pinnedEpoch: pinnedEpoch,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            selectedAt: (row["selected_at"] as Double?)
                .map { Date(timeIntervalSince1970: $0) }
                ?? Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            revokedAt: (row["revoked_at"] as Double?)
                .map { Date(timeIntervalSince1970: $0) })
    }

    /// Bounded retention: retired associations older than 30 days are removed
    /// and the table is capped at 512 rows (active rows are never selected by
    /// the delete order until they are revoked).
    private static func prune(db: Database, now: Date) throws {
        try db.execute(sql: """
            DELETE FROM g09_media_task_bindings
            WHERE state = 'revoked' AND revoked_at IS NOT NULL AND revoked_at < ?
            """, arguments: [now.addingTimeInterval(-30 * 24 * 60 * 60)
                .timeIntervalSince1970])
        let count = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM g09_media_task_bindings") ?? 0
        guard count > 512 else { return }
        try db.execute(sql: """
            DELETE FROM g09_media_task_bindings
            WHERE binding_id IN (
                SELECT binding_id FROM g09_media_task_bindings
                WHERE state = 'revoked'
                ORDER BY updated_at ASC LIMIT ?
            )
            """, arguments: [count - 512])
    }
}

// MARK: - Resolution / authorization

enum G09R2MediaTaskBindingCoordinator {
    struct TaskContext: Sendable {
        var taskID: UUID
        var workspaceID: UUID
        var workspaceRelativePath: String
        var workspaceRoot: URL
    }

    /// Explicit trusted App selection. There is no runtime call context here:
    /// the association is recorded pending and grants no model access.
    static func select(service: G09CreativeDomainService,
                       request: G09R2MediaTaskSelectionRequest,
                       now: Date = Date()) async throws
        -> G09R2MediaTaskBindingRecord {
        guard let cluster = await service.r2BoundCluster(),
              await service.r2IsGenerationLive(epoch: cluster.epoch),
              !(await service.r2IsRootStopping(epoch: cluster.epoch)) else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard let store = await service.r2TaskBindingStore() else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard G09CreativeWire.safeOperationID(request.selectionOpID) else {
            throw G09R2MediaTaskBindingFailure.selectionConflict
        }
        guard request.expectedRevision == nil || (request.expectedRevision ?? -1) >= 0 else {
            throw G09R2MediaTaskBindingFailure.projectChanged
        }
        let task = try await resolveTask(service: service, cluster: cluster,
                                         conversationID: request.taskID)
        let provenance: G09R2MediaProjectProvenance
        do {
            provenance = try G09R2MediaToolAccess.readProvenance(
                directory: cluster.media.projectDirectoryPath,
                projectID: request.projectID)
        } catch {
            throw G09R2MediaTaskBindingFailure.projectGone
        }
        let storage = try resolveStorage(
            provenance: provenance, task: task, cluster: cluster,
            projectID: request.projectID)
        let origin = try origin(provenance: provenance, task: task,
                                projectID: request.projectID)
        let loaded: G09MediaProjectHost.Loaded
        do {
            loaded = try await cluster.media.load(
                id: request.projectID, requested: storage, origin: origin)
        } catch {
            throw mapProjectError(error)
        }
        guard loaded.writable else {
            throw G09R2MediaTaskBindingFailure.storageUnresolved
        }
        if let expected = request.expectedRevision,
           loaded.project.revision != expected {
            throw G09R2MediaTaskBindingFailure.projectChanged
        }
        let plan = G09R2MediaTaskSelectionPlan(
            rootDigest: pathDigest(cluster.root.path),
            taskID: task.taskID,
            workspaceID: task.workspaceID,
            workspaceRelativePath: task.workspaceRelativePath,
            projectID: request.projectID,
            projectOwnerKind: provenance.ownerKind,
            projectOwnerID: provenance.ownerID,
            recordedEnvironment: provenance.environmentID,
            storageKind: storage.kind,
            storageWorkspaceID: storage.workspaceID,
            projectRootDigest: pathDigest(loaded.storage.rootURL.path),
            projectRevision: loaded.project.revision)
        let result = try await store.select(plan: plan, request: request, now: now)
        return result.record
    }

    static func revoke(service: G09CreativeDomainService,
                       request: G09R2MediaTaskRevokeRequest,
                       now: Date = Date()) async throws -> Bool {
        guard let store = await service.r2TaskBindingStore() else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard let cluster = await service.r2BoundCluster(),
              await service.r2IsGenerationLive(epoch: cluster.epoch),
              !(await service.r2IsRootStopping(epoch: cluster.epoch)) else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        return try await store.revoke(
            projectID: request.projectID, bindingID: request.bindingID,
            taskID: request.taskID, now: now)
    }

    /// First-call pin + later-call exact matching for ONE immutable call.
    /// Returns nil only when no explicit association exists (legacy path).
    static func authorizeBound(service: G09CreativeDomainService,
                               mailbox: G09R2MediaRenderHostMailbox,
                               call: G09R2MediaToolCallContext) async throws
        -> G09R2MediaToolSession? {
        guard let cluster = await service.r2BoundCluster(),
              await service.r2IsGenerationLive(epoch: cluster.epoch),
              !(await service.r2IsRootStopping(epoch: cluster.epoch)) else {
            throw G09R2MediaToolFailure.generationStopped.floError
        }
        guard mailbox.isBound(to: cluster.epoch),
              mailbox.consumerReady(epoch: cluster.epoch) else {
            throw G09R2MediaToolFailure.consumerUnavailable.floError
        }
        guard let store = await service.r2TaskBindingStore() else {
            throw G09R2MediaToolFailure.generationStopped.floError
        }
        let active: G09R2MediaTaskBindingRecord?
        do {
            active = try await store.active(projectID: call.projectID)
        } catch {
            throw G09R2MediaToolFailure.storageUnresolved.floError
        }
        guard var record = active else { return nil }
        guard !call.context.temporaryReadOnly else {
            throw FloeError.unauthorized
        }
        guard let conversationID = call.context.conversationID,
              conversationID == record.taskID else {
            throw G09R2MediaTaskBindingFailure.taskRequired.floError
        }
        let task = try await resolveTask(service: service, cluster: cluster,
                                         conversationID: record.taskID)
        guard task.workspaceID == record.workspaceID,
              task.workspaceRelativePath == record.workspaceRelativePath else {
            throw G09R2MediaTaskBindingFailure.workspaceMismatch.floError
        }
        guard pathDigest(cluster.root.path) == record.rootDigest else {
            throw G09R2MediaTaskBindingFailure.notReady.floError
        }
        let provenance: G09R2MediaProjectProvenance
        do {
            provenance = try G09R2MediaToolAccess.readProvenance(
                directory: cluster.media.projectDirectoryPath,
                projectID: record.projectID)
        } catch {
            throw G09R2MediaTaskBindingFailure.projectGone.floError
        }
        guard provenance.ownerKind == record.projectOwnerKind,
              provenance.ownerID == record.projectOwnerID,
              provenance.environmentID == record.recordedEnvironment else {
            throw G09R2MediaTaskBindingFailure.projectChanged.floError
        }
        let storage = G09StorageLayerDTO(
            kind: record.storageKind, workspaceID: record.storageWorkspaceID)
        let origin = try origin(provenance: provenance, task: task,
                                projectID: record.projectID)
        let loaded: G09MediaProjectHost.Loaded
        do {
            loaded = try await cluster.media.load(
                id: record.projectID, requested: storage, origin: origin)
        } catch {
            throw mapProjectError(error).floError
        }
        guard loaded.writable,
              pathDigest(loaded.storage.rootURL.path) == record.projectRootDigest else {
            throw G09R2MediaTaskBindingFailure.storageUnresolved.floError
        }
        // The runtime's real workspace root is the only workspace identity
        // this pin may use. It must be the SAME trusted workspace row derived
        // from the task; a different path is never accepted as a wildcard.
        guard let contextWorkspace = call.context.workspaceRootURL else {
            throw G09R2MediaTaskBindingFailure.environmentMismatch.floError
        }
        guard G09R2MediaToolFile.pathsEquivalent(
            contextWorkspace.path, task.workspaceRoot.path) else {
            throw G09R2MediaTaskBindingFailure.workspaceMismatch.floError
        }
        let workspaceDigest = pathDigest(contextWorkspace.path)
        guard workspaceDigest == pathDigest(task.workspaceRoot.path) else {
            throw G09R2MediaTaskBindingFailure.workspaceMismatch.floError
        }
        if let recordedEnvironment = record.recordedEnvironment,
           recordedEnvironment != call.context.environmentID {
            throw G09R2MediaTaskBindingFailure.environmentMismatch.floError
        }
        let environmentMode = call.context.environmentID == nil ? "none" : "explicit"
        let environmentBinding = RuntimeAuthorityDigest.environmentBinding(
            workspaceRootURL: contextWorkspace,
            conversationID: call.context.conversationID)

        switch record.state {
        case .pending:
            let binding: RuntimeAuthorityBinding
            do {
                binding = try call.runtimeAuthorityBinding()
            } catch {
                throw G09R2MediaTaskBindingFailure.runtimeAuthorityInvalid("unrepresentableCall")
                    .floError
            }
            let validation = await call.context.validatedRuntimeAuthority(
                binding: binding, store: call.authorityStore)
            guard validation.isValid else {
                throw G09R2MediaTaskBindingFailure.runtimeAuthorityInvalid(
                    validation.failureReason ?? "invalid").floError
            }
            let pinned: G09R2MediaTaskBindingRecord?
            do {
                pinned = try await store.pin(
                    bindingID: record.bindingID,
                    rootDigest: record.rootDigest,
                    taskID: record.taskID,
                    projectID: record.projectID,
                    environmentMode: environmentMode,
                    environmentID: call.context.environmentID,
                    environmentBinding: environmentBinding,
                    workspaceRootDigest: workspaceDigest,
                    epoch: cluster.epoch)
            } catch {
                throw G09R2MediaTaskBindingFailure.databaseUnavailable.floError
            }
            guard let pinned, pinned.state == .pinned,
                  pinned.environmentMode == environmentMode,
                  pinned.environmentID == call.context.environmentID,
                  pinned.environmentBinding == environmentBinding,
                  pinned.workspaceRootDigest == workspaceDigest else {
                throw G09R2MediaTaskBindingFailure.bindingMismatch.floError
            }
            record = pinned
        case .pinned:
            guard record.environmentMode == environmentMode,
                  record.environmentID == call.context.environmentID,
                  record.environmentBinding == environmentBinding,
                  record.workspaceRootDigest == workspaceDigest else {
                throw G09R2MediaTaskBindingFailure.environmentMismatch.floError
            }
        case .revoked:
            return nil
        }

        let taskDigest = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-task/2|\(cluster.epoch)|" +
            "\(record.taskID.uuidString.lowercased())|" +
            "\(record.workspaceID.uuidString.lowercased())|" +
            "\(environmentMode):\(record.environmentID ?? "")|" +
            "\(record.bindingID.uuidString.lowercased())").utf8))
        let storageProof = record.storageKind == .appOwned
            ? "appOwned"
            : "workspace:\(record.storageWorkspaceID?.uuidString.lowercased() ?? "")"
        let accessProof = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-access/2|\(cluster.epoch)|\(taskDigest)|" +
            "\(record.projectID.uuidString.lowercased())|\(storageProof)|" +
            "\(loaded.project.revision)|\(record.bindingID.uuidString.lowercased())").utf8))
        return G09R2MediaToolSession(
            epoch: cluster.epoch,
            root: cluster.root,
            media: cluster.media,
            project: loaded.project,
            storage: storage,
            origin: origin,
            projectRoot: loaded.storage.rootURL.standardizedFileURL,
            conversationID: record.taskID,
            workspaceID: record.workspaceID,
            taskDigest: taskDigest,
            accessProof: accessProof,
            bindingID: record.bindingID)
    }

    /// Host-only proposal grant issuance for the pinned association. The App
    /// request names an EXISTING proposal; native re-authorizes the exact
    /// task/workspace/project/revision and reuses the original single-use
    /// `MediaProposalGrantStore`. No model-visible mint action exists.
    static func issueGrant(service: G09CreativeDomainService,
                           grants: G09R2MediaToolGrants,
                           proposals: G09R2MediaToolProposalStore,
                           request: G09R2MediaProjectGrantRequest,
                           now: Date = Date()) async throws -> String {
        guard let cluster = await service.r2BoundCluster(),
              await service.r2IsGenerationLive(epoch: cluster.epoch),
              !(await service.r2IsRootStopping(epoch: cluster.epoch)) else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard let store = await service.r2TaskBindingStore() else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard let record = try await store.active(projectID: request.projectID) else {
            throw G09R2MediaTaskBindingFailure.bindingMissing
        }
        guard record.state == .pinned else {
            throw G09R2MediaTaskBindingFailure.bindingPending
        }
        if let taskID = request.taskID, taskID != record.taskID {
            throw G09R2MediaTaskBindingFailure.bindingMismatch
        }
        guard pathDigest(cluster.root.path) == record.rootDigest else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        let task = try await resolveTask(service: service, cluster: cluster,
                                         conversationID: record.taskID)
        guard task.workspaceID == record.workspaceID,
              task.workspaceRelativePath == record.workspaceRelativePath else {
            throw G09R2MediaTaskBindingFailure.workspaceMismatch
        }
        let provenance: G09R2MediaProjectProvenance
        do {
            provenance = try G09R2MediaToolAccess.readProvenance(
                directory: cluster.media.projectDirectoryPath,
                projectID: record.projectID)
        } catch {
            throw G09R2MediaTaskBindingFailure.projectGone
        }
        guard provenance.ownerKind == record.projectOwnerKind,
              provenance.ownerID == record.projectOwnerID,
              provenance.environmentID == record.recordedEnvironment else {
            throw G09R2MediaTaskBindingFailure.projectChanged
        }
        let storage = G09StorageLayerDTO(
            kind: record.storageKind, workspaceID: record.storageWorkspaceID)
        let origin = try origin(provenance: provenance, task: task,
                                projectID: record.projectID)
        let loaded: G09MediaProjectHost.Loaded
        do {
            loaded = try await cluster.media.load(
                id: record.projectID, requested: storage, origin: origin)
        } catch {
            throw mapProjectError(error)
        }
        guard loaded.writable,
              pathDigest(loaded.storage.rootURL.path) == record.projectRootDigest else {
            throw G09R2MediaTaskBindingFailure.storageUnresolved
        }
        guard loaded.project.revision == request.revision else {
            throw G09R2MediaTaskBindingFailure.projectChanged
        }
        let session = makeSession(
            cluster: cluster, record: record, loaded: loaded,
            storage: storage, origin: origin, environmentMode: record.environmentMode,
            environmentID: record.environmentID)
        guard let proposal = try? await proposals.load(
            id: request.proposalID, session: session),
              proposal.projectID == record.projectID else {
            throw G09R2MediaTaskBindingFailure.proposalMissing
        }
        return try await grants.issue(
            session: session, proposalID: request.proposalID,
            revision: request.revision, now: now)
    }
}

// MARK: - Shared helpers

extension G09R2MediaTaskBindingCoordinator {
    static func resolveTask(service: G09CreativeDomainService,
                            cluster: G09R2BoundCluster,
                            conversationID: UUID) async throws -> TaskContext {
        guard let workspaceStore = await service.r2WorkspaceStore(),
              let conversationStore = await service.r2ConversationStore() else {
            throw G09R2MediaTaskBindingFailure.notReady
        }
        guard (try? await conversationStore.conversation(id: conversationID)) != nil else {
            throw G09R2MediaTaskBindingFailure.taskUnknown
        }
        guard let workspaceID = try? await workspaceStore.workspaceID(
            conversationID: conversationID),
              let record = try? await workspaceStore.workspace(id: workspaceID),
              record.kind == .privateTask || record.kind == .project,
              let relative = record.internalRelativePath,
              G09CreativeAssetHost.safeRelativePath(relative),
              !relative.isEmpty else {
            throw G09R2MediaTaskBindingFailure.workspaceUnavailable
        }
        let base = URL(fileURLWithPath: cluster.root.path, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
        let root = base.appendingPathComponent(relative, isDirectory: true)
            .standardizedFileURL
        guard root.path.hasPrefix(base.path + "/") else {
            throw G09R2MediaTaskBindingFailure.workspaceUnavailable
        }
        return TaskContext(
            taskID: conversationID, workspaceID: workspaceID,
            workspaceRelativePath: relative, workspaceRoot: root)
    }

    static func resolveStorage(provenance: G09R2MediaProjectProvenance,
                               task: TaskContext,
                               cluster: G09R2BoundCluster,
                               projectID: UUID) throws -> G09StorageLayerDTO {
        let appOwned = cluster.root.artifactStoreURL
            .appendingPathComponent("WorkbenchRoot", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL
        let recorded = provenance.taskWorkspacePath
            .flatMap(G09R2MediaToolFile.normalizeAbsolutePath)
        let recordedIsAppOwned = recorded.map {
            G09R2MediaToolFile.pathsEquivalent($0, appOwned.path)
        } ?? false
        let recordedIsWorkspace = recorded.map {
            G09R2MediaToolFile.pathsEquivalent($0, task.workspaceRoot.path)
        } ?? false

        switch provenance.ownerKind {
        case "chat":
            guard provenance.ownerID == task.taskID else {
                throw G09R2MediaTaskBindingFailure.projectNotBindable("another task")
            }
            if recordedIsAppOwned {
                return G09StorageLayerDTO(kind: .appOwned)
            }
            if recordedIsWorkspace {
                return G09StorageLayerDTO(kind: .workspace, workspaceID: task.workspaceID)
            }
            // Chat-owned records must name their concrete storage. A nil
            // recorded path is not a wildcard for the app-owned root.
            throw G09R2MediaTaskBindingFailure.storageUnresolved
        case "workspace":
            guard provenance.ownerID == task.workspaceID else {
                throw G09R2MediaTaskBindingFailure.projectNotBindable("another workspace")
            }
            if recordedIsAppOwned {
                return G09StorageLayerDTO(kind: .appOwned)
            }
            if recordedIsWorkspace {
                return G09StorageLayerDTO(kind: .workspace, workspaceID: task.workspaceID)
            }
            // A workspace-owned record without a concrete recorded storage is
            // ambiguous; never guess between the workspace and app-owned root.
            throw G09R2MediaTaskBindingFailure.storageUnresolved
        case "standalone":
            guard provenance.ownerID == nil || provenance.ownerID == projectID else {
                throw G09R2MediaTaskBindingFailure.projectNotBindable("another owner")
            }
            guard recordedIsAppOwned || recorded == nil else {
                throw G09R2MediaTaskBindingFailure.storageUnresolved
            }
            return G09StorageLayerDTO(kind: .appOwned)
        case "files", "canvas":
            guard recordedIsAppOwned || recorded == nil else {
                throw G09R2MediaTaskBindingFailure.storageUnresolved
            }
            return G09StorageLayerDTO(kind: .appOwned)
        default:
            throw G09R2MediaTaskBindingFailure.projectNotBindable(
                provenance.ownerKind.isEmpty ? "unknown owner" : provenance.ownerKind)
        }
    }

    static func origin(provenance: G09R2MediaProjectProvenance,
                       task: TaskContext,
                       projectID: UUID) throws -> G09CreativeOriginDTO {
        switch provenance.ownerKind {
        case "chat":
            return G09CreativeOriginDTO(
                kind: .chat, ownerID: task.taskID,
                environmentID: provenance.environmentID)
        case "workspace":
            return G09CreativeOriginDTO(
                kind: .workspace, ownerID: task.workspaceID,
                environmentID: provenance.environmentID)
        case "standalone":
            return G09CreativeOriginDTO(
                kind: .standalone, ownerID: provenance.ownerID ?? projectID,
                environmentID: provenance.environmentID)
        case "files":
            return G09CreativeOriginDTO(
                kind: .files, ownerID: provenance.ownerID,
                environmentID: provenance.environmentID)
        case "canvas":
            return G09CreativeOriginDTO(
                kind: .canvas, ownerID: provenance.ownerID,
                environmentID: provenance.environmentID)
        default:
            throw G09R2MediaTaskBindingFailure.projectNotBindable(
                provenance.ownerKind.isEmpty ? "unknown owner" : provenance.ownerKind)
        }
    }

    static func mapProjectError(_ error: Error) -> G09R2MediaTaskBindingFailure {
        if let failure = error as? G09R2MediaTaskBindingFailure { return failure }
        if let typed = error as? G09CreativeError {
            switch typed {
            case .mediaProjectNotFound, .corruptProject:
                return .projectGone
            case .revisionConflict:
                return .projectChanged
            case .crossOwnerRefused, .untrustedOwner, .provenanceMismatch,
                 .invalidOrigin, .storageLayerRequired, .workspaceStorageUnavailable:
                return .projectNotBindable("owner or storage mismatch")
            case .staleGeneration, .acceptedRootNotLive, .runtimeUnavailable:
                return .notReady
            default:
                return .storageUnresolved
            }
        }
        if let r2 = error as? G09R2Error {
            switch r2.wire {
            case .rendererUnavailable, .renderCancelled:
                return .notReady
            default:
                return .storageUnresolved
            }
        }
        if error is CancellationError { return .notReady }
        return .storageUnresolved
    }

    static func pathDigest(_ path: String) -> String {
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return FloeDigest.sha256Hex(Data(canonical.utf8))
    }

    static func makeSession(cluster: G09R2BoundCluster,
                            record: G09R2MediaTaskBindingRecord,
                            loaded: G09MediaProjectHost.Loaded,
                            storage: G09StorageLayerDTO,
                            origin: G09CreativeOriginDTO,
                            environmentMode: String?,
                            environmentID: String?) -> G09R2MediaToolSession {
        let mode = environmentMode ?? (environmentID == nil ? "none" : "explicit")
        let taskDigest = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-task/2|\(cluster.epoch)|" +
            "\(record.taskID.uuidString.lowercased())|" +
            "\(record.workspaceID.uuidString.lowercased())|" +
            "\(mode):\(environmentID ?? "")|" +
            "\(record.bindingID.uuidString.lowercased())").utf8))
        let storageProof = storage.kind == .appOwned
            ? "appOwned"
            : "workspace:\(storage.workspaceID?.uuidString.lowercased() ?? "")"
        let accessProof = FloeDigest.sha256Hex(Data((
            "floe.g09.mediatool-access/2|\(cluster.epoch)|\(taskDigest)|" +
            "\(record.projectID.uuidString.lowercased())|\(storageProof)|" +
            "\(loaded.project.revision)|\(record.bindingID.uuidString.lowercased())").utf8))
        return G09R2MediaToolSession(
            epoch: cluster.epoch, root: cluster.root,
            media: cluster.media, project: loaded.project,
            storage: storage, origin: origin,
            projectRoot: loaded.storage.rootURL.standardizedFileURL,
            conversationID: record.taskID,
            workspaceID: record.workspaceID,
            taskDigest: taskDigest,
            accessProof: accessProof,
            bindingID: record.bindingID)
    }
}

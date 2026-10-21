// FloePersistence — atomic conversation/run launch preparation.
//
// A launch is durable as one unit before provider I/O begins. This closes
// the race where a newly-created conversation could be deleted while an
// asynchronously-started run was still trying to insert its foreign key.
//
// ANDROID MIRROR (2026-10-20, job-651733384b1f4e60): this file was a symlink
// to FloeAgent/Sources/FloePersistence/RunLaunchStore.swift and is now a
// regular reviewed mirror so the narrow G02 first-activation repair can land
// WITHOUT writing through the protected upstream link. Upstream original
// SHA-256 at mirror time: 71b35d16cf332a7e8bcb45ff9034dfed52631ecea5849128608
// b1a688d3872fd. The ONLY behavioral delta is the reviewed
// `activatesEmptyOrdinaryHeader` request opt-in below: every original caller
// keeps the exact original semantics (default false), and the new branch runs
// inside the SAME original writer transaction (canonical privateTask
// workspace + ownership + task policy for a GENUINELY EMPTY ordinary header
// that was created through the conversation domain without any ownership).
//
// SECOND MIRROR DELTA (goal-core code batch, job-7efd60bb51d14f02,
// 2026-10-21): the additive `AtomicIntelligenceRunLaunchStore.prepare`
// overload with a post-digest-CAS, pre-first-write atomic commit hook used
// by `plan.accept` and the structured `goalDefinition` launch. Every
// original caller and public method keeps its exact original behavior
// (existing signatures are unchanged; the private transaction helper just
// gains a nil-defaulted parameter threaded to the new hook site).

import Foundation
import GRDB
import FloeCore
import FloeModels

/// Everything required to make the first durable snapshot of one run.
/// `conversationID == nil` creates a conversation in the same transaction;
/// a non-nil identifier must already exist.
public struct RunLaunchRequest: Sendable, Hashable {
    public var conversationID: UUID?
    /// Native draft identity used for preselected resource grants. It creates
    /// a new row only; an existing conversation must never be replaced.
    public var newConversationID: UUID?
    public var conversationTitle: String
    public var runID: UUID
    public var goal: String
    public var initialState: String
    public var workspaceID: UUID?
    public var attachments: [AttachmentRef]
    public var startedAt: Date
    public var conversationMode: String
    public var initialPolicy: DraftTaskPolicy
    /// `goalContinuation` is an internal cycle prompt. It is durable for
    /// audit/recovery, but is not rendered as a user-authored chat message.
    public var messageRole: String
    public var providerID: UUID?
    public var modelID: UUID?
    public var providerName: String?
    public var modelName: String?
    /// Full configuration snapshots let the launch transaction repair a
    /// missing/stale relational row before inserting the run. Older callers
    /// may continue to provide only ids.
    public var providerProfile: ProviderProfile?
    public var modelProfile: ModelProfile?
    /// ANDROID MIRROR DELTA (G02 first activation, default FALSE = the exact
    /// original semantics): trusted ordinary callers may opt in so the FIRST
    /// send against a GENUINELY EMPTY ordinary header — one created through
    /// the conversation domain with no canonical workspace/task policy yet —
    /// establishes its own canonical privateTask workspace, ownership and
    /// task policy INSIDE this same writer transaction. The writer proves
    /// (same transaction): ordinary purpose, existing header, and NO prior
    /// runs/messages/committed attachments/policy/ownership. Any used,
    /// nonempty, foreign, notes, archived/deleted or contradictory header is
    /// refused exactly like before; nothing is ever auto-healed or moved.
    public var activatesEmptyOrdinaryHeader: Bool = false

    public init(
        conversationID: UUID? = nil,
        newConversationID: UUID? = nil,
        conversationTitle: String = "",
        runID: UUID = UUID(),
        goal: String,
        initialState: String = "preparing",
        workspaceID: UUID? = nil,
        attachments: [AttachmentRef] = [],
        conversationMode: String = "chat",
        initialPolicy: DraftTaskPolicy = DraftTaskPolicy(),
        messageRole: String = "user",
        providerID: UUID? = nil,
        modelID: UUID? = nil,
        providerName: String? = nil,
        modelName: String? = nil,
        providerProfile: ProviderProfile? = nil,
        modelProfile: ModelProfile? = nil,
        startedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.newConversationID = newConversationID
        self.conversationTitle = conversationTitle
        self.runID = runID
        self.goal = goal
        self.initialState = initialState
        self.workspaceID = workspaceID
        self.attachments = attachments
        self.conversationMode = conversationMode
        self.initialPolicy = initialPolicy
        self.messageRole = messageRole
        self.providerID = providerID
        self.modelID = modelID
        self.providerName = providerName
        self.modelName = modelName
        self.providerProfile = providerProfile
        self.modelProfile = modelProfile
        self.startedAt = startedAt
    }
}

/// Durable identities returned only after the complete launch transaction
/// commits. Callers may safely navigate to these records immediately.
public struct PreparedRun: Sendable, Hashable {
    public var conversation: ConversationRecord
    public var workspace: WorkspaceRecord
    public var run: RunRecord
    public var userMessage: PersistedMessage
    public var attachments: [AttachmentRef]
    public var createdConversation: Bool

    public init(
        conversation: ConversationRecord,
        workspace: WorkspaceRecord,
        run: RunRecord,
        userMessage: PersistedMessage,
        attachments: [AttachmentRef],
        createdConversation: Bool
    ) {
        self.conversation = conversation
        self.workspace = workspace
        self.run = run
        self.userMessage = userMessage
        self.attachments = attachments
        self.createdConversation = createdConversation
    }
}

public protocol RunLaunchStore: Sendable {
    func prepare(_ request: RunLaunchRequest) async throws -> PreparedRun
}

/// GRDB implementation. `DatabaseManager.writer` supplies one serialized
/// transaction, so any validation or insert failure rolls the entire launch
/// back — there can be neither an empty conversation nor an orphan run.
/// Trusted same-writer raw-row validation capability. Ordinary wire launches
/// require this explicitly; a protocol-only store cannot silently omit CAS.
public protocol ExistingConversationRunLaunchStore: RunLaunchStore {
    func prepare(_ request: RunLaunchRequest,
                 expectedRow: @escaping @Sendable (Database, Row?) throws -> Void) async throws -> PreparedRun
}

/// ANDROID MIRROR ADDITION (goal-core code batch, job-7efd60bb51d14f02,
/// 2026-10-21; additive — the two protocols/methods above are byte-equal to
/// the reviewed mirror before this batch): the C1 atomic intelligence seam.
/// `plan.accept` (accepted plan + optional GoalFromPlanFactory goal) and the
/// structured `goalDefinition` on an ordinary goal-mode `run.start` must
/// commit through the ORIGINAL statement twins INSIDE the SAME writer
/// transaction that commits the run + user message + launch, AFTER the
/// existing-row digest CAS and BEFORE any relational repair or run row. A
/// throw anywhere rolls the WHOLE launch back: no accepted-plan irrecoverable
/// residue, no half goal, no orphan run — one DatabaseManager, schema v46,
/// no second store, no new table, no network inside the transaction (the
/// commit closure runs only durable statements over values already proven at
/// admission). Only the durable `SQLiteRunLaunchStore` (the reviewed mirror)
/// provides this capability; the ORIGINAL EphemeralRunLaunchStore never
/// conforms, so a temporary launch structurally cannot carry intelligence.
public protocol AtomicIntelligenceRunLaunchStore: ExistingConversationRunLaunchStore {
    func prepare(_ request: RunLaunchRequest,
                 expectedRow: @escaping @Sendable (Database, Row?) throws -> Void,
                 atomicIntelligence: (@Sendable (Database) throws -> Void)?) async throws -> PreparedRun
}

public actor SQLiteRunLaunchStore: ExistingConversationRunLaunchStore, AtomicIntelligenceRunLaunchStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func prepare(_ request: RunLaunchRequest) async throws -> PreparedRun {
        try await prepareTransaction(request, expectedRow: nil, atomicIntelligence: nil)
    }

    /// Additive Android seam, following ConversationStore's expectedRow
    /// overload. The original method remains the default for all callers.
    public func prepare(_ request: RunLaunchRequest,
                        expectedRow: @escaping @Sendable (Database, Row?) throws -> Void) async throws -> PreparedRun {
        guard request.conversationID != nil else {
            throw FloeError.validationFailed("Existing-row proof requires an existing conversation")
        }
        return try await prepareTransaction(request, expectedRow: expectedRow,
                                            atomicIntelligence: nil)
    }

    /// ANDROID MIRROR ADDITION (goal-core code batch): the C1 atomic
    /// intelligence commit. Requires an existing conversation (the digest
    /// CAS runs first); the `atomicIntelligence` closure — plan-revision /
    /// goal-row statement twins — executes INSIDE the same writer
    /// transaction immediately after the expected-row proof and before any
    /// configuration repair or run/message insert. A throw rolls back every
    /// durable effect of this launch (provable C0 no-effect). Original
    /// callers keep the two methods above unchanged.
    public func prepare(_ request: RunLaunchRequest,
                        expectedRow: @escaping @Sendable (Database, Row?) throws -> Void,
                        atomicIntelligence: (@Sendable (Database) throws -> Void)?) async throws -> PreparedRun {
        guard request.conversationID != nil else {
            throw FloeError.validationFailed("Existing-row proof requires an existing conversation")
        }
        return try await prepareTransaction(request, expectedRow: expectedRow,
                                            atomicIntelligence: atomicIntelligence)
    }

    private func prepareTransaction(
        _ request: RunLaunchRequest,
        expectedRow: (@Sendable (Database, Row?) throws -> Void)?,
        atomicIntelligence: (@Sendable (Database) throws -> Void)?
    ) async throws -> PreparedRun {
        guard request.conversationID == nil || request.newConversationID == nil else {
            throw FloeError.validationFailed("Choose an existing or a new conversation identity, not both")
        }
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            throw FloeError.validationFailed("Goal must not be empty")
        }
        guard ["chat", "plan", "goal"].contains(request.conversationMode) else {
            throw FloeError.validationFailed("Unknown conversation mode")
        }
        guard ["user", "goalContinuation"].contains(request.messageRole) else {
            throw FloeError.validationFailed("Unknown launch message role")
        }

        return try await database.writer { db in
            // Validate against the CURRENT complete raw row before ANY
            // relational configuration, workspace, policy, run or message
            // write. A stale/absent/purpose refusal leaves no side effects.
            if let expectedRow, let conversationID = request.conversationID {
                let row = try Row.fetchOne(db,
                    sql: "SELECT * FROM conversations WHERE id = ?",
                    arguments: [conversationID.uuidString])
                try expectedRow(db, row)
            }
            // ANDROID MIRROR ADDITION (goal-core code batch): the atomic
            // intelligence commit runs ONLY after the existing-row digest
            // CAS succeeded and BEFORE the first durable write of this
            // launch, inside this same serialized transaction. Throwing
            // here rolls back everything (nothing was written yet); the
            // closure performs durable statements only — never network IO.
            if let atomicIntelligence {
                try atomicIntelligence(db)
            }
            let now = request.startedAt
            let conversation: ConversationRecord
            let createdConversation: Bool
            let eligibleEmptyOrdinaryHeader: Bool

            var resolvedProviderID = request.providerID
            var resolvedModelID = request.modelID

            // Repair relational configuration in the same transaction as the
            // run. This is important for device-local models: an older build
            // or a CloudKit reconciliation may have removed their local-only
            // rows while the picker still holds a valid installed profile.
            if let provider = request.providerProfile {
                try provider.validate()
                try ConfigurationCodec.write(provider, to: db)
                resolvedProviderID = provider.id
            }
            if let model = request.modelProfile {
                try ConfigurationCodec.validate(model)
                guard model.providerID == resolvedProviderID else {
                    throw FloeError.invalidConfiguration("The selected model belongs to a different provider")
                }
                let canonical = try ConfigurationCodec.write(model, to: db)
                resolvedModelID = canonical.id
            }

            // Resolve relational configuration before creating any durable
            // conversation/run rows. This turns a stale picker selection into
            // an actionable preflight error instead of leaking SQLite's
            // FOREIGN KEY diagnostic into the composer.
            if let providerID = resolvedProviderID {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM providers WHERE id = ? AND is_enabled = 1)",
                    arguments: [providerID.uuidString]
                ) == true else {
                    throw FloeError.invalidConfiguration(
                        "The selected provider is no longer available. Refresh the model list and choose another provider."
                    )
                }
            }
            if let modelID = resolvedModelID {
                guard let providerID = resolvedProviderID else {
                    throw FloeError.invalidConfiguration("A selected model requires a provider")
                }
                guard try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM models
                            WHERE id = ? AND provider_id = ? AND is_enabled = 1
                        )
                        """,
                    arguments: [modelID.uuidString, providerID.uuidString]
                ) == true else {
                    throw FloeError.invalidConfiguration(
                        "The selected model is not installed or has been disabled. Refresh the model list and choose an available model."
                    )
                }
            }

            if let conversationID = request.conversationID {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM conversations WHERE id = ?",
                    arguments: [conversationID.uuidString]
                ) else {
                    throw FloeError.notFound("conversation \(conversationID.uuidString)")
                }
                conversation = try Self.conversation(from: row)
                // Prove eligibility from raw SQLite values. The original
                // decoder intentionally defaults unknown purposes and does
                // not load archivedAt; neither is activation authority.
                eligibleEmptyOrdinaryHeader = (row["purpose"] as String?) == "ordinary"
                    && (row["archived_at"] as String?) == nil
                createdConversation = false
            } else {
                conversation = ConversationRecord(
                    id: request.newConversationID ?? UUID(),
                    title: request.conversationTitle,
                    createdAt: now,
                    updatedAt: now
                )
                try db.execute(
                    sql: """
                        INSERT INTO conversations (id, title, created_at, updated_at, mode, title_origin)
                        VALUES (?, ?, ?, ?, ?, 'autoPending')
                        """,
                    arguments: [
                        conversation.id.uuidString,
                        conversation.title,
                        PersistenceCodec.encode(conversation.createdAt),
                        PersistenceCodec.encode(conversation.updatedAt),
                        request.conversationMode
                    ]
                )
                createdConversation = true
                eligibleEmptyOrdinaryHeader = false
            }

            try db.execute(
                sql: "UPDATE conversations SET mode = ? WHERE id = ?",
                arguments: [request.conversationMode, conversation.id.uuidString]
            )

            if let workspaceID = request.workspaceID {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?)",
                    arguments: [workspaceID.uuidString]
                ) == true else {
                    throw FloeError.notFound("workspace \(workspaceID.uuidString)")
                }
            }

            let owningWorkspaceID: UUID
            let rawOwner = try String.fetchOne(
                db,
                sql: """
                    SELECT workspace_id FROM conversation_workspace_ownership
                    WHERE conversation_id = ?
                    """,
                arguments: [conversation.id.uuidString]
            )
            if rawOwner != nil, rawOwner.flatMap({ UUID(uuidString: $0) }) == nil {
                // A present-but-unparseable owner is the original corruption
                // refusal; never silently repaired.
                throw FloeError.storageCorrupted("Conversation has no canonical workspace")
            }
            if let existingOwner = rawOwner.flatMap({ UUID(uuidString: $0) }) {
                if let requested = request.workspaceID, requested != existingOwner {
                    throw FloeError.validationFailed(
                        "A task workspace is fixed after its first message; use Move Task instead"
                    )
                }
                // Existing correct canonical workspace is reused as-is.
                owningWorkspaceID = existingOwner
            } else if try createdConversation
                        || (request.activatesEmptyOrdinaryHeader
                            && eligibleEmptyOrdinaryHeader
                            && Self.isGenuinelyEmptyHeader(
                                db, conversationID: conversation.id)) {
                // FIRST DURABLE BINDING of this header inside the SAME
                // original writer transaction: either this transaction just
                // created the header (exact original behavior) or the
                // trusted G02 first-send activation binds a provably empty
                // ordinary header that the conversation domain created
                // without any ownership yet. Same statements, same header
                // id, and `createdConversation` keeps its exact original
                // meaning (the header row itself already existed for
                // activation).
                owningWorkspaceID = try Self.establishCanonicalOwnership(
                    db, conversation: conversation, request: request, now: now)
            } else {
                // A used/nonempty orphan, a foreign/notes/temporary header,
                // an archived one, or an activation attempt without the
                // trusted opt-in refuses exactly like the original code —
                // never auto-healed, never moved, never rebound behind the
                // user.
                throw FloeError.storageCorrupted("Conversation has no canonical workspace")
            }

            let run = RunRecord(
                id: request.runID,
                conversationID: conversation.id,
                state: request.initialState,
                goal: goal,
                startedAt: now,
                providerID: resolvedProviderID,
                modelID: resolvedModelID,
                providerName: request.providerName,
                modelName: request.modelName,
                conversationMode: request.conversationMode
            )
            try db.execute(
                sql: """
                    INSERT INTO runs (
                        id, conversation_id, state, goal, started_at, ended_at, goal_id,
                        provider_id, model_id, provider_name_snapshot, model_name_snapshot,
                        conversation_mode
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    run.id.uuidString,
                    run.conversationID.uuidString,
                    run.state,
                    run.goal,
                    PersistenceCodec.encode(run.startedAt),
                    run.providerID?.uuidString,
                    run.modelID?.uuidString,
                    run.providerName,
                    run.modelName,
                    run.conversationMode
                ]
            )

            let messageID = UUID()
            try db.execute(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at, run_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    messageID.uuidString,
                    conversation.id.uuidString,
                    request.messageRole,
                    goal,
                    PersistenceCodec.encode(now),
                    run.id.uuidString
                ]
            )
            var normalizedAttachments: [AttachmentRef] = []
            normalizedAttachments.reserveCapacity(request.attachments.count)
            for attachment in request.attachments {
                var normalized = attachment
                normalized.conversationID = conversation.id
                normalized.messageID = messageID
                normalizedAttachments.append(normalized)
                try Self.insertAttachment(normalized, db: db)
            }

            var parts = [MessagePart(
                messageID: messageID,
                partIndex: 0,
                kind: .text,
                text: goal,
                createdAt: now
            )]
            parts.append(contentsOf: normalizedAttachments.enumerated().map { offset, attachment in
                MessagePart(
                    messageID: messageID,
                    partIndex: offset + 1,
                    kind: attachment.kind == .image ? .image : .file,
                    attachmentID: attachment.id,
                    metadata: ["name": attachment.displayName],
                    createdAt: now
                )
            })
            let userMessage = PersistedMessage(
                id: messageID,
                conversationID: conversation.id,
                role: request.messageRole,
                content: goal,
                createdAt: now,
                parts: parts,
                runID: run.id
            )
            for part in parts {
                try Self.insertPart(part, db: db)
            }

            guard let workspaceRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM workspaces WHERE id = ?",
                arguments: [owningWorkspaceID.uuidString]
            ) else {
                throw FloeError.storageCorrupted("Canonical workspace disappeared during launch")
            }
            let owningWorkspace = try Self.workspace(from: workspaceRow)

            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [PersistenceCodec.encode(now), conversation.id.uuidString]
            )
            guard let activationProof = try RunActivationIdentity.current(
                db: db, conversationID: conversation.id) else {
                throw FloeError.storageCorrupted("Launch activation owner disappeared")
            }
            let status = try JSONSerialization.data(withJSONObject: [
                "state": "preparing",
                "floeActivation": ["version": 1, "kind": request.messageRole, "proof": activationProof],
            ], options: [.sortedKeys])
            let statusJSON = String(decoding: status, as: UTF8.self)
            try db.execute(
                sql: """
                    INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                    VALUES (?, ?, 1, 'status', ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    run.id.uuidString,
                    statusJSON,
                    PersistenceCodec.encode(now)
                ]
            )

            var updatedConversation = conversation
            updatedConversation.updatedAt = now
            return PreparedRun(
                conversation: updatedConversation,
                workspace: owningWorkspace,
                run: run,
                userMessage: userMessage,
                attachments: normalizedAttachments,
                createdConversation: createdConversation
            )
        }
    }

    private static func insertAttachment(_ attachment: AttachmentRef, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO attachments (
                    id, conversation_id, message_id, kind, display_name, uti,
                    byte_count, sha256, storage, url_bookmark, relative_path, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                attachment.id.uuidString,
                attachment.conversationID?.uuidString,
                attachment.messageID?.uuidString,
                attachment.kind.rawValue,
                attachment.displayName,
                attachment.uti,
                attachment.byteCount,
                attachment.sha256,
                attachment.storage.rawValue,
                attachment.urlBookmark,
                attachment.relativePath,
                PersistenceCodec.encode(attachment.createdAt)
            ]
        )
    }

    private static func insertPart(_ part: MessagePart, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO message_parts (
                    id, message_id, part_index, kind, text, attachment_id,
                    metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                part.id.uuidString,
                part.messageID.uuidString,
                part.partIndex,
                part.kind.rawValue,
                part.text,
                part.attachmentID?.uuidString,
                try PersistenceCodec.jsonObject(part.metadata),
                PersistenceCodec.encode(part.createdAt)
            ]
        )
    }

    /// The exact original new-conversation statements: mint (or bind the
    /// explicit requested) canonical privateTask workspace, then insert the
    /// ownership and task-policy rows. Shared by the original created-header
    /// path and the reviewed G02 first-activation path so both stay one
    /// statement-set.
    private static func establishCanonicalOwnership(
        _ db: Database, conversation: ConversationRecord,
        request: RunLaunchRequest, now: Date
    ) throws -> UUID {
        let owningWorkspaceID: UUID
        if let requested = request.workspaceID {
            owningWorkspaceID = requested
        } else {
            owningWorkspaceID = UUID()
            let privateName = request.conversationTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(
                sql: """
                    INSERT INTO workspaces (
                        id, name, root_bookmark, last_opened_at,
                        active_target_kind, active_target_host_id,
                        inspector_state_json, instructions_rel_path,
                        created_at, updated_at, kind, internal_relative_path
                    ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}', NULL,
                              ?, ?, 'privateTask', ?)
                    """,
                arguments: [
                    owningWorkspaceID.uuidString,
                    privateName.isEmpty ? "Chat" : String(privateName.prefix(80)),
                    Data(), PersistenceCodec.encode(now), PersistenceCodec.encode(now),
                    "PrivateTasks/\(conversation.id.uuidString)"
                ]
            )
        }
        try db.execute(
            sql: """
                INSERT INTO conversation_workspace_ownership
                    (conversation_id, workspace_id, assigned_at)
                VALUES (?, ?, ?)
                """,
            arguments: [
                conversation.id.uuidString,
                owningWorkspaceID.uuidString,
                PersistenceCodec.encode(now)
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO task_policies (
                    conversation_id, approval_mode, recovery_policy,
                    notification_policy, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                conversation.id.uuidString,
                request.initialPolicy.approvalMode.rawValue,
                request.initialPolicy.recoveryPolicy.rawValue,
                request.initialPolicy.notificationPolicy.rawValue,
                PersistenceCodec.encode(now)
            ]
        )
        return owningWorkspaceID
    }

    /// G02 first-activation emptiness proof (same writer): the header must
    /// have NO runs, messages, committed attachments or task-policy rows
    /// yet (ownership absence was already established by the caller site).
    private static func isGenuinelyEmptyHeader(
        _ db: Database, conversationID: UUID
    ) throws -> Bool {
        func noRows(_ sql: String) throws -> Bool {
            try Bool.fetchOne(db, sql: sql, arguments: [conversationID.uuidString]) == false
        }
        return try noRows("SELECT EXISTS(SELECT 1 FROM runs WHERE conversation_id = ?)")
            && noRows("SELECT EXISTS(SELECT 1 FROM messages WHERE conversation_id = ?)")
            && noRows("SELECT EXISTS(SELECT 1 FROM attachments WHERE conversation_id = ?)")
            && noRows("SELECT EXISTS(SELECT 1 FROM task_policies WHERE conversation_id = ?)")
    }

    private static func conversation(from row: Row) throws -> ConversationRecord {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid conversation identifier")
        }
        return ConversationRecord(
            id: id,
            title: row["title"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"]),
            titleOrigin: ConversationTitleOrigin(rawValue: row["title_origin"] as String? ?? "autoPending")
                ?? .autoPending,
            purpose: ConversationPurpose(rawValue: row["purpose"]) ?? .ordinary
        )
    }

    private static func workspace(from row: Row) throws -> WorkspaceRecord {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid workspace identifier")
        }
        let hostID: UUID? = (row["active_target_host_id"] as String?).flatMap(UUID.init(uuidString:))
        let inspectorJSON: String = row["inspector_state_json"]
        let inspector = (try? JSONDecoder().decode(InspectorState.self, from: Data(inspectorJSON.utf8)))
            ?? InspectorState()
        return WorkspaceRecord(
            id: id,
            name: row["name"],
            rootBookmark: row["root_bookmark"],
            lastOpenedAt: (row["last_opened_at"] as String?).flatMap {
                try? PersistenceCodec.decodeDate($0)
            },
            activeTarget: WorkspaceTarget(kindName: row["active_target_kind"], hostID: hostID),
            inspectorState: inspector,
            instructionsRelativePath: row["instructions_rel_path"],
            kind: WorkspaceKind(rawValue: row["kind"]) ?? .project,
            internalRelativePath: row["internal_relative_path"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"])
        )
    }
}

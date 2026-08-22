// FloePersistence — atomic conversation/run launch preparation.
//
// A launch is durable as one unit before provider I/O begins. This closes
// the race where a newly-created conversation could be deleted while an
// asynchronously-started run was still trying to insert its foreign key.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// Everything required to make the first durable snapshot of one run.
/// `conversationID == nil` creates a conversation in the same transaction;
/// a non-nil identifier must already exist.
public struct RunLaunchRequest: Sendable, Hashable {
    public var conversationID: UUID?
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

    public init(
        conversationID: UUID? = nil,
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
public actor SQLiteRunLaunchStore: RunLaunchStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func prepare(_ request: RunLaunchRequest) async throws -> PreparedRun {
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
            let now = request.startedAt
            let conversation: ConversationRecord
            let createdConversation: Bool

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
                createdConversation = false
            } else {
                conversation = ConversationRecord(
                    id: UUID(),
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
            if createdConversation {
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
            } else {
                guard let rawOwner = try String.fetchOne(
                    db,
                    sql: """
                        SELECT workspace_id FROM conversation_workspace_ownership
                        WHERE conversation_id = ?
                        """,
                    arguments: [conversation.id.uuidString]
                ), let owner = UUID(uuidString: rawOwner) else {
                    throw FloeError.storageCorrupted("Conversation has no canonical workspace")
                }
                if let requested = request.workspaceID, requested != owner {
                    throw FloeError.validationFailed(
                        "A task workspace is fixed after its first message; use Move Task instead"
                    )
                }
                owningWorkspaceID = owner
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
                modelName: request.modelName
            )
            try db.execute(
                sql: """
                    INSERT INTO runs (
                        id, conversation_id, state, goal, started_at, ended_at, goal_id,
                        provider_id, model_id, provider_name_snapshot, model_name_snapshot
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)
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
                    run.modelName
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
            try db.execute(
                sql: """
                    INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                    VALUES (?, ?, 1, 'status', ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    run.id.uuidString,
                    #"{"state":"preparing"}"#,
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
                ?? .autoPending
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

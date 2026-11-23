// FloePersistence — Conversation / message / content-part / attachment store.
// See docs/ALPHA_DAILY_PLAN.md (Persistence v3). Secret-free by construction.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// Durable product ownership; document assistants never enter ordinary chat projections.
/// `.temporary` marks an ephemeral (RAM-only) conversation: it must never be written
/// to SQLite — ordinary projections filter `purpose = 'ordinary'` and promotion
/// rewrites the record as `.ordinary` before saving. See `TemporaryChatSession`.
public enum ConversationPurpose: String, Sendable, Hashable {
    case ordinary, notes, temporary
}

/// Persistent presentation ownership, independent of execution purpose.
/// A lightweight authoring operation uses the ordinary durable runtime but
/// stays out of the ordinary conversation list until explicitly converted.
/// (Aligned with the unchanged iOS data model: iOS v53 stores the same
/// column with the same defaults and CHECK contract — see
/// V55ConversationContinuity.)
public enum ConversationVisibility: String, Codable, Sendable, Hashable {
    case normal, skillAuthoring
}

/// Durable native editor ownership. Presentation ownership never grants
/// document access and remains independent of ordinary run execution purpose.
public struct ConversationEditorOwnership: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable { case file, canvas }
    public let kind: Kind
    public let documentID: UUID
    public let containerID: UUID

    public init(kind: Kind, documentID: UUID, containerID: UUID) {
        self.kind = kind; self.documentID = documentID; self.containerID = containerID
    }
    public static func file(_ id: UUID) -> Self {
        .init(kind: .file, documentID: id, containerID: id)
    }
    public static func canvas(_ id: UUID, documentID: UUID) -> Self {
        .init(kind: .canvas, documentID: documentID, containerID: id)
    }
}

/// A conversation row with its plain-text projection. Structured multimodal
/// parts are loaded separately via `parts(messageID:)`.
public struct ConversationRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var titleOrigin: ConversationTitleOrigin
    public var archivedAt: Date?
    public var purpose: ConversationPurpose
    /// Persistent presentation ownership (iOS v53 semantics; schema v55).
    /// `.normal` for every row written before visibility existed.
    public var visibility: ConversationVisibility
    /// Durable native editor ownership (iOS v61 semantics; schema v55);
    /// `nil` unless a native editor assistant claimed the row.
    public var editorOwnership: ConversationEditorOwnership?
    /// Optional durable sidebar pin (schema v50). `nil` for every row written
    /// before pinning existed and for ordinary unpinned rows. The moment a
    /// row moved INTO the pinned group; the column lives on the conversation
    /// row itself (never a parallel per-device UI store), so rename, archive,
    /// restore and workspace moves preserve it. Pinning never touches
    /// `updated_at`, so it cannot fake activity.
    public var pinnedAt: Date?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        titleOrigin: ConversationTitleOrigin = .autoPending,
        archivedAt: Date? = nil,
        purpose: ConversationPurpose = .ordinary,
        visibility: ConversationVisibility = .normal,
        pinnedAt: Date? = nil,
        editorOwnership: ConversationEditorOwnership? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.titleOrigin = titleOrigin
        self.archivedAt = archivedAt
        self.purpose = purpose
        self.visibility = visibility
        self.pinnedAt = pinnedAt
        self.editorOwnership = editorOwnership
    }
}

public extension ConversationRecord {
    /// Durable pin presence. Pinning is presentation metadata on the SAME
    /// durable row, so it survives relaunch/reopen and every ordinary edit.
    var isPinned: Bool { pinnedAt != nil }
    /// Aligned with the iOS ordinary-list contract: only ordinary, normally
    /// visible, unowned, unarchived rows belong to the ordinary chat list.
    var isVisibleInOrdinaryList: Bool {
        purpose == .ordinary && visibility == .normal && archivedAt == nil
            && editorOwnership == nil
    }
}

/// A persisted message with its ordered typed content parts.
public struct PersistedMessage: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var role: String
    public var content: String
    public var createdAt: Date
    public var parts: [MessagePart]
    public var runID: UUID?

    public init(
        id: UUID,
        conversationID: UUID,
        role: String,
        content: String,
        createdAt: Date,
        parts: [MessagePart] = [],
        runID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.parts = parts
        self.runID = runID
    }
}

/// Stable keyset cursor for long conversation timelines. UUID is the
/// deterministic tie-breaker when several events share a timestamp.
public struct ConversationMessageCursor: Sendable, Codable, Hashable, Comparable {
    public var createdAt: Date
    public var messageID: UUID

    public init(createdAt: Date, messageID: UUID) {
        self.createdAt = createdAt
        self.messageID = messageID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.createdAt, lhs.messageID.uuidString) < (rhs.createdAt, rhs.messageID.uuidString)
    }
}

public struct ConversationMessagePage: Sendable, Hashable {
    /// Chronological rows for direct insertion into the UI timeline.
    public var messages: [PersistedMessage]
    public var earlierCursor: ConversationMessageCursor?
    public var hasEarlier: Bool

    public init(
        messages: [PersistedMessage],
        earlierCursor: ConversationMessageCursor?,
        hasEarlier: Bool
    ) {
        self.messages = messages
        self.earlierCursor = earlierCursor
        self.hasEarlier = hasEarlier
    }
}

/// Durable conversation, message, content-part and attachment access.
/// Deterministic ordering throughout; writes are cancellation-safe because
/// GRDB serialises writers.
public protocol ConversationStore: Sendable {
    func saveConversation(_ conversation: ConversationRecord) async throws
    /// Claims native ownership without changing an existing different owner.
    func claimEditorOwnership(id: UUID, owner: ConversationEditorOwnership) async throws
    func editorConversations(owner: ConversationEditorOwnership) async throws -> [ConversationRecord]
    func editorConversations(kind: ConversationEditorOwnership.Kind, containerID: UUID) async throws -> [ConversationRecord]
    func conversations() async throws -> [ConversationRecord]
    func conversations(includeArchived: Bool) async throws -> [ConversationRecord]
    func conversation(id: UUID) async throws -> ConversationRecord?
    func renameConversation(id: UUID, title: String) async throws
    @discardableResult
    func setAutomaticTitle(id: UUID, title: String) async throws -> Bool
    func deleteConversation(id: UUID) async throws
    /// Atomically removes the conversation row ONLY when no durable resource
    /// references it. The verification and the DELETE run inside ONE writer
    /// transaction, so a resource can never be written between a successful
    /// "empty" read and the removal.
    ///
    /// The temporary-chat in-place conversion uses this: a blank ordinary
    /// chat that already owns a workspace (with real user files),
    /// attachments, runs, queued inputs, durable jobs or saved settings must
    /// NEVER lose that ownership to a mode toggle. A conversation that
    /// exists but owns anything, and one that does not exist, both return
    /// `false` — only a verified-empty row is removed (`true`).
    @discardableResult
    func deleteConversationIfVerifiedEmpty(id: UUID) async throws -> Bool
    func setArchived(id: UUID, archived: Bool) async throws
    /// Durable sidebar pin (schema v50). Writes ONLY the `pinned_at` column —
    /// never `updated_at` — so pinning an old chat does not fake activity and
    /// unpinning restores the plain recency ordering. A missing row and a
    /// non-ordinary (Notes/temporary) row are ACTIONABLE errors, never a
    /// silent zero-row UPDATE reported as success.
    func setPinned(id: UUID, pinnedAt: Date?) async throws

    func appendMessage(_ message: PersistedMessage) async throws
    /// Export the portable v1 device-history bytes of one ordinary
    /// conversation. Durable SQLite implements the fixed iOS donor
    /// semantics; stores without durable history refuse typed.
    func deviceHistory(conversationID: UUID) async throws -> DeviceConversationHistory
    /// Import verified portable bytes. `hasLiveRun` is re-proven INSIDE the
    /// same writer transaction before any message write; a throwing probe
    /// fails the whole transaction closed.
    func importDeviceHistory(
        _ history: DeviceConversationHistory,
        hasLiveRun: @escaping @Sendable (Database) throws -> Bool
    ) async throws -> DeviceConversationImport
    func messages(conversationID: UUID) async throws -> [PersistedMessage]
    /// Fast first-screen page in chronological order. Full history remains
    /// available through `messages(conversationID:)` and is hydrated later.
    func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage]
    func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage
    /// Bounded single-row read used by reveal/find and compatibility checks.
    func message(id: UUID, conversationID: UUID) async throws -> PersistedMessage?
    func parts(messageID: UUID) async throws -> [MessagePart]

    func saveAttachment(_ attachment: AttachmentRef) async throws
    func attachment(id: UUID) async throws -> AttachmentRef?
    func attachments(conversationID: UUID) async throws -> [AttachmentRef]
}

public extension ConversationStore {
    /// Stores without durable editor history (for example the RAM-only
    /// ephemeral stores) refuse ownership reads instead of approximating.
    func editorConversations(kind: ConversationEditorOwnership.Kind, containerID: UUID) async throws -> [ConversationRecord] {
        throw FloeError.storageCorrupted("Durable editor history is unavailable for this store")
    }

    /// Stores without durable device history (RAM-only ephemeral stores)
    /// refuse export/import typed instead of approximating.
    func deviceHistory(conversationID: UUID) async throws -> DeviceConversationHistory {
        throw FloeError.invalidConfiguration("This conversation store does not support device history")
    }
    func importDeviceHistory(
        _ history: DeviceConversationHistory,
        hasLiveRun: @escaping @Sendable (Database) throws -> Bool
    ) async throws -> DeviceConversationImport {
        throw FloeError.invalidConfiguration("This conversation store does not support device history")
    }
    func editorConversations(owner: ConversationEditorOwnership) async throws -> [ConversationRecord] {
        throw FloeError.storageCorrupted("Durable editor history is unavailable for this store")
    }
    func claimEditorOwnership(id: UUID, owner: ConversationEditorOwnership) async throws {
        throw FloeError.storageCorrupted("Durable editor ownership is unavailable for this store")
    }

    /// Compatibility for non-SQLite stores; durable SQLite uses one owned row.
    func message(id: UUID, conversationID: UUID) async throws -> PersistedMessage? {
        var cursor: ConversationMessageCursor?
        repeat {
            try Task.checkCancellation()
            let page = try await messagePage(conversationID: conversationID, before: cursor, limit: 100)
            if let found = page.messages.first(where: { $0.id == id && $0.conversationID == conversationID }) { return found }
            guard page.hasEarlier, let next = page.earlierCursor, next != cursor else { return nil }
            cursor = next
        } while true
    }

    func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        guard !includeArchived else {
            throw FloeError.invalidConfiguration("This conversation store does not support archives")
        }
        return try await conversations()
    }

    func setArchived(id: UUID, archived: Bool) async throws {
        throw FloeError.invalidConfiguration("This conversation store does not support archives")
    }

    /// Stores without a durable conversations row (for example the RAM-only
    /// temporary-chat store) refuse pinning instead of silently persisting:
    /// a temporary chat must be Kept (promoted) before it can be pinned.
    func setPinned(id: UUID, pinnedAt: Date?) async throws {
        throw FloeError.invalidConfiguration("This conversation store does not support pinning")
    }

    func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        Array(try await messages(conversationID: conversationID).suffix(max(1, limit)))
    }

    func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        let ordered = try await messages(conversationID: conversationID).sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        let eligible = cursor.map { cursor in
            ordered.filter {
                ($0.createdAt, $0.id.uuidString) < (cursor.createdAt, cursor.messageID.uuidString)
            }
        } ?? ordered
        let bounded = max(1, limit)
        let page = Array(eligible.suffix(bounded))
        return ConversationMessagePage(
            messages: page,
            earlierCursor: page.first.map {
                ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
            },
            hasEarlier: eligible.count > page.count
        )
    }
}

/// SQLite/GRDB implementation of `ConversationStore`.
public actor SQLiteConversationStore: ConversationStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveConversation(_ conversation: ConversationRecord) async throws {
        try await database.writer { db in
            try Self.writeConversation(conversation, in: db)
        }
    }

    /// The FIRST INSERT carries every presentation field (`title_origin`,
    /// `archived_at`, `visibility`, `pinned_at`, ownership) so a supplied new
    /// record round-trips its public state — aligned with the fixed iOS
    /// writeConversation (7897f9c1). The ON CONFLICT update deliberately
    /// touches ONLY title and updated_at: later saves may carry stale
    /// presentation state, so title origin, archive, pin and ownership stay
    /// owned by their dedicated setters after insertion.
    private static func writeConversation(_ conversation: ConversationRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO conversations (id, title, created_at, updated_at, purpose, visibility, pinned_at, archived_at, title_origin)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                conversation.id.uuidString,
                conversation.title,
                PersistenceCodec.encode(conversation.createdAt),
                PersistenceCodec.encode(conversation.updatedAt),
                conversation.purpose.rawValue,
                conversation.visibility.rawValue,
                conversation.pinnedAt.map { PersistenceCodec.encode($0) },
                conversation.archivedAt.map { PersistenceCodec.encode($0) },
                conversation.titleOrigin.rawValue,
            ]
        )
        if let owner = conversation.editorOwnership {
            // Row and ownership commit in this SAME writer transaction: there
            // is never a committed ordinary row awaiting an ownership write.
            try claimEditorOwnership(id: conversation.id, owner: owner, db: db)
        }
    }

    public func editorConversations(kind: ConversationEditorOwnership.Kind, containerID: UUID) async throws -> [ConversationRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversations WHERE editor_owner_kind=? AND editor_container_id=? ORDER BY updated_at DESC,id",
                arguments: [kind.rawValue, containerID.uuidString]).map { try Self.conversation(from: $0) }
        }
    }

    public func editorConversations(owner: ConversationEditorOwnership) async throws -> [ConversationRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversations WHERE editor_owner_kind=? AND editor_document_id=? AND editor_container_id=? ORDER BY updated_at DESC,id",
                arguments: [owner.kind.rawValue, owner.documentID.uuidString, owner.containerID.uuidString])
                .map { try Self.conversation(from: $0) }
        }
    }

    public func claimEditorOwnership(id: UUID, owner: ConversationEditorOwnership) async throws {
        try await database.writer { db in
            try Self.claimEditorOwnership(id: id, owner: owner, db: db)
        }
    }

    private static func claimEditorOwnership(id: UUID, owner: ConversationEditorOwnership, db: Database) throws {
        guard owner.kind != .file || owner.documentID == owner.containerID else {
            throw FloeError.validationFailed("Invalid file assistant ownership")
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?",
                                        arguments: [id.uuidString]) else {
            throw FloeError.notFound("conversation")
        }
        guard row["purpose"] as String? == "ordinary", row["visibility"] as String? == "normal" else {
            throw FloeError.validationFailed("This conversation belongs to another feature")
        }
        if let existing = try editorOwnership(from: row) {
            guard existing == owner else { throw FloeError.validationFailed("Editor ownership changed") }
            return
        }
        try db.execute(sql: "UPDATE conversations SET editor_owner_kind=?, editor_document_id=?, editor_container_id=? WHERE id=?",
            arguments: [owner.kind.rawValue, owner.documentID.uuidString, owner.containerID.uuidString, id.uuidString])
    }

    public func conversations() async throws -> [ConversationRecord] {
        try await conversations(includeArchived: false)
    }

    public func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        try await database.reader { db in
            // Aligned with the iOS ordinary-list contract (7897f9c1): only
            // ordinary, normally visible, unowned rows enter the list —
            // visibility/editor-owned metadata (schema v55) is filtered here,
            // never by flattening the rows. Pinned rows first within their
            // group, most recent pin first (schema v50); everything else
            // keeps the established `updated_at DESC, id` recency order.
            // Archived rows are only included when explicitly requested, and
            // keep their pin.
            try Row.fetchAll(
                db,
                sql: includeArchived
                    ? "SELECT * FROM conversations WHERE purpose = 'ordinary' AND visibility = 'normal' AND editor_owner_kind IS NULL AND editor_document_id IS NULL AND editor_container_id IS NULL ORDER BY (pinned_at IS NULL), pinned_at DESC, updated_at DESC, id"
                    : "SELECT * FROM conversations WHERE purpose = 'ordinary' AND visibility = 'normal' AND editor_owner_kind IS NULL AND editor_document_id IS NULL AND editor_container_id IS NULL AND archived_at IS NULL ORDER BY (pinned_at IS NULL), pinned_at DESC, updated_at DESC, id"
            ).map(Self.conversation(from:))
        }
    }

    public func conversation(id: UUID) async throws -> ConversationRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.conversation(from: row)
        }
    }

    public func renameConversation(id: UUID, title: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ?, title_origin = 'manual', updated_at = ? WHERE id = ?",
                arguments: [title, PersistenceCodec.encode(Date()), id.uuidString]
            )
        }
    }

    @discardableResult
    public func setAutomaticTitle(id: UUID, title: String) async throws -> Bool {
        try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET title = ?, title_origin = 'automatic', updated_at = ?
                    WHERE id = ? AND title_origin = 'autoPending'
                    """,
                arguments: [title, PersistenceCodec.encode(Date()), id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Deletes the conversation and, in the SAME writer transaction, every
    /// lifecycle row the conversation owns (child transcripts, run
    /// relations, run dependencies and its background-job records). Spooled
    /// full-output artifacts are removed only AFTER the transaction commits,
    /// so a rollback never destroys evidence. Calls must have cancelled the
    /// conversation's own live work first; this method never cancels another
    /// consumer's work.
    public func deleteConversation(id: UUID) async throws {
        let spoolPaths = try await database.writer { db -> [String] in
            let paths = try RunLifecycleRetention.deleteOwnedRecords(db: db, conversationID: id)
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id.uuidString])
            return paths
        }
        RunLifecycleRetention.removeSpoolArtifacts(spoolPaths)
    }

    /// One transaction: verify the target row is a plain blank ordinary
    /// conversation that owns no durable resource, then remove it. Every
    /// conversation-scoped table that can hold user-visible state is probed,
    /// including tables that reference the conversation WITHOUT a foreign
    /// key (`checkpoints`) and owner-based rows (`media_generation_jobs`).
    /// The per-conversation `task_policies` row is written by a real run
    /// launch or an explicit policy change, so its presence is itself a
    /// saved setting and refuses the removal.
    ///
    /// The conversation's OWN metadata is part of the contract: a Notes
    /// assistant (`purpose = 'notes'`), a manually named chat, an automatic
    /// title, an archived task, a hidden (`visibility != 'normal'`) row, an
    /// editor-owned row, or a pinned row must never be deleted and restored
    /// as a blank ordinary row. Only `purpose = 'ordinary'` + `visibility =
    /// 'normal'` + no editor ownership + empty title + `title_origin =
    /// 'autoPending'` + not archived + not pinned (and no child resource) is
    /// eligible.
    ///
    /// A hit, ineligible metadata or a missing row returns `false`: the
    /// caller must treat the conversation as owning durable state (or as
    /// absent) and must not remove anything. The row removal below can
    /// therefore never fire the `queue_private_task_cleanup` trigger for an
    /// owned private workspace.
    public func deleteConversationIfVerifiedEmpty(id: UUID) async throws -> Bool {
        try await database.writer { db in
            let conversationID = id.uuidString
            // The target row must exist and be a blank ordinary conversation.
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, title_origin, purpose, visibility, archived_at, pinned_at,
                           editor_owner_kind, editor_document_id, editor_container_id
                    FROM conversations WHERE id = ?
                    """,
                arguments: [conversationID]
            ) else { return false }
            let title = row["title"] as String? ?? ""
            let titleOrigin = row["title_origin"] as String? ?? "autoPending"
            let purpose = row["purpose"] as String? ?? "ordinary"
            let archivedAt = row["archived_at"] as String?
            // A durable pin is explicit user metadata: converting a pinned
            // blank row in place would silently erase it, so such a row is
            // ineligible for the verified-empty removal.
            let pinnedAt = row["pinned_at"] as String?
            guard purpose == "ordinary",
                  (row["visibility"] as String? ?? "normal") == "normal",
                  row["editor_owner_kind"] as String? == nil,
                  row["editor_document_id"] as String? == nil,
                  row["editor_container_id"] as String? == nil,
                  title.isEmpty,
                  titleOrigin == "autoPending",
                  archivedAt == nil,
                  pinnedAt == nil
            else { return false }
            // (table, predicate) — every conversation-scoped durable table.
            let probes: [(table: String, predicate: String)] = [
                ("messages", "conversation_id = ?"),
                ("attachments", "conversation_id = ?"),
                ("runs", "conversation_id = ?"),
                ("checkpoints", "conversation_id = ?"),
                ("pending_user_inputs", "conversation_id = ?"),
                ("workspace_conversations", "conversation_id = ?"),
                ("conversation_workspace_ownership", "conversation_id = ?"),
                ("task_policies", "conversation_id = ?"),
                ("plan_drafts", "conversation_id = ?"),
                ("conversation_goals", "conversation_id = ?"),
                ("task_checklist_revisions", "conversation_id = ?"),
                ("memory_entries", "conversation_id = ?"),
                ("memory_candidates", "conversation_id = ?"),
                ("canvas_run_contexts", "conversation_id = ?"),
                ("credential_records", "conversation_id = ?"),
                ("background_jobs", "conversation_id = ?"),
                ("conversation_discovery", "conversation_id = ?"),
                ("media_generation_jobs", "owner_kind = 'conversation' AND owner_id = ?"),
                // Lifecycle tables from schema v46: a conversation with
                // delegated children or outstanding dependencies is NOT
                // "verified empty" and must never be removed by the
                // temporary-chat in-place conversion.
                ("child_runs", "conversation_id = ?"),
                ("run_dependencies", "conversation_id = ?"),
            ]
            for probe in probes {
                let exists = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM \(probe.table) WHERE \(probe.predicate)
                        )
                        """,
                    arguments: [conversationID]
                ) ?? 0
                if exists != 0 { return false }
            }
            try db.execute(
                sql: "DELETE FROM conversations WHERE id = ?",
                arguments: [conversationID]
            )
            return db.changesCount > 0
        }
    }

    public func setArchived(id: UUID, archived: Bool) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE conversations SET archived_at = ?, updated_at = ? WHERE id = ?",
                arguments: [
                    archived ? PersistenceCodec.encode(Date()) : nil,
                    PersistenceCodec.encode(Date()),
                    id.uuidString
                ]
            )
        }
    }

    public func setPinned(id: UUID, pinnedAt: Date?) async throws {
        try await database.writer { db in
            // One transaction: the eligibility read and the write commit
            // together, so a missing or non-ordinary row is an ACTIONABLE
            // error, never a zero-row UPDATE reported as success. Pins
            // persist only on ordinary, normally visible, unowned
            // conversations — the iOS eligibility contract — and a RAM-only
            // temporary chat never has a durable row at all (its ephemeral
            // store also rejects `setPinned` through the protocol default).
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT purpose, visibility, editor_owner_kind, editor_document_id, editor_container_id FROM conversations WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                throw FloeError.notFound("conversation \(id.uuidString)")
            }
            guard (row["purpose"] as String?) == ConversationPurpose.ordinary.rawValue,
                  (row["visibility"] as String?) == ConversationVisibility.normal.rawValue,
                  (row["editor_owner_kind"] as String?) == nil,
                  (row["editor_document_id"] as String?) == nil,
                  (row["editor_container_id"] as String?) == nil
            else {
                throw FloeError.validationFailed("Only ordinary conversations can be pinned")
            }
            try db.execute(
                sql: "UPDATE conversations SET pinned_at = ? WHERE id = ?",
                arguments: [pinnedAt.map { PersistenceCodec.encode($0) }, id.uuidString]
            )
        }
    }

    public func appendMessage(_ message: PersistedMessage) async throws {
        try await database.writer { db in
            if let existing = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id=?",
                arguments: [message.id.uuidString]), existing["role"] as String == "user" {
                let parts = try Self.fetchParts(messageID: message.id, db: db)
                // Historical user decisions are not editable text drafts.
                // Protect the native metadata even if it is unreadable: a
                // generic edit must not strip the tag and bypass Plan CAS.
                // (Semantics aligned with the unchanged iOS data model:
                // iOS-originated confirmed-plan records stay immutable here.)
                if parts.contains(where: { $0.metadata["floe.plan.confirmation.v1"] != nil }) {
                    guard message.conversationID.uuidString == existing["conversation_id"] as String,
                          message.role == "user", message.content == existing["content"] as String,
                          message.runID?.uuidString == existing["run_id"] as String?,
                          message.parts == parts else {
                        throw FloeError.validationFailed(FloeL10n.isChinese
                            ? "已确认的计划记录不可编辑。请在计划模式中修订并重新确认。"
                            : "A confirmed plan record cannot be edited. Revise and confirm a plan in Plan mode.")
                    }
                    return // exact idempotent write; keep the original row
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at, run_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content
                    """,
                arguments: [
                    message.id.uuidString,
                    message.conversationID.uuidString,
                    message.role,
                    message.content,
                    PersistenceCodec.encode(message.createdAt),
                    message.runID?.uuidString
                ]
            )
            for part in message.parts {
                try Self.insertPart(part, db: db)
            }
            // Touch the conversation so list ordering reflects activity.
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [PersistenceCodec.encode(Date()), message.conversationID.uuidString]
            )
        }
    }

    public func messages(conversationID: UUID) async throws -> [PersistedMessage] {
        try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid",
                arguments: [conversationID.uuidString]
            )
            let messageIDs = try rows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            return try rows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
        }
    }

    /// Export a single committed task from a consistent database read. Local
    /// permissions, attachments, and live run state stay with their owner.
    /// Android mirror of the fixed iOS `deviceHistory` (0d2c31722): the same
    /// ordinary-list eligibility, the same user/assistant text-only
    /// projection, the same message/part identifiers and ordering.
    public func deviceHistory(conversationID: UUID) async throws -> DeviceConversationHistory {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?",
                                             arguments: [conversationID.uuidString]) else {
                throw DeviceConversationHistoryError.conversationUnavailable
            }
            let conversation = try Self.conversation(from: row)
            guard conversation.isVisibleInOrdinaryList else {
                throw DeviceConversationHistoryError.conversationUnavailable
            }
            let bodyBytes = try Int.fetchOne(db, sql: """
                SELECT coalesce(sum(length(CAST(content AS BLOB))), 0)
                FROM messages WHERE conversation_id = ? AND role IN ('user', 'assistant')
                """, arguments: [conversationID.uuidString]) ?? 0
            guard bodyBytes <= DeviceConversationHistory.maximumBytes else { throw DeviceConversationHistoryError.sizeLimit }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM messages WHERE conversation_id = ? AND role IN ('user', 'assistant')
                ORDER BY created_at, rowid LIMIT ?
                """, arguments: [conversationID.uuidString, DeviceConversationHistory.maximumMessages + 1])
            guard rows.count <= DeviceConversationHistory.maximumMessages else {
                throw DeviceConversationHistoryError.sizeLimit
            }
            let ids = try rows.map(Self.messageID(from:))
            let parts = try Self.fetchParts(messageIDs: ids, db: db)
            let messages = try zip(rows, ids).map { row, id in
                try Self.portableDeviceMessage(row, id: id, parts: parts[id, default: []])
            }
            return DeviceConversationHistory(id: conversationID, title: SecretRedactor.redact(conversation.title),
                createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, messages: messages)
        }
    }

    /// Inserts only new history, using the usual native workspace ownership.
    /// A differing existing message aborts the whole import. It cannot be
    /// interpreted as an edit, delete, approval, or request to run the task.
    /// Android mirror of the fixed iOS `importDeviceHistory` (0d2c31722):
    /// one writer transaction, idempotent append-if-absent on the unchanged
    /// message/part UUIDs, conflict abort BEFORE any mutation of that
    /// message, and genuine new-row workspace ownership.
    public func importDeviceHistory(_ history: DeviceConversationHistory) async throws -> DeviceConversationImport {
        try await importDeviceHistory(history, hasLiveRun: { _ in false })
    }

    /// Narrow additive seam over the fixed iOS donor behaviour: the
    /// active-run decision is RE-PROVEN inside this SAME writer transaction,
    /// after conversation eligibility and BEFORE any message write. The
    /// closure reads the caller's own durable tables through the passed
    /// `Database`, so an import and a fresh run admission commit serially
    /// (GRDB serialises writers) and a run that committed `preparing` first
    /// is visible here. A throwing closure fails the WHOLE transaction
    /// closed — never a partial import.
    public func importDeviceHistory(
        _ history: DeviceConversationHistory,
        hasLiveRun: @escaping @Sendable (Database) throws -> Bool
    ) async throws -> DeviceConversationImport {
        try history.validate()
        return try await database.writer { db in
            let conversationID = history.id.uuidString
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [conversationID])
            if let existing {
                let conversation = try Self.conversation(from: existing)
                guard conversation.purpose == .ordinary, conversation.visibility == .normal,
                      conversation.editorOwnership == nil else {
                    throw DeviceConversationHistoryError.conversationUnavailable
                }
            } else {
                try Self.writeConversation(.init(id: history.id, title: history.title, createdAt: history.createdAt,
                    updatedAt: history.updatedAt, titleOrigin: .manual), in: db)
                _ = try SQLiteWorkspaceStore.ensureWorkspace(conversationID: history.id, title: history.title, db: db)
            }
            // Re-prove the active-run decision INSIDE this writer
            // transaction, after eligibility and BEFORE any message write:
            // import and fresh run admission now commit serially (GRDB
            // serialises writers), and a run that committed `preparing`
            // first is visible here. A throwing probe fails the WHOLE
            // transaction closed — never a partial import.
            guard try hasLiveRun(db) == false else { throw DeviceConversationHistoryError.busy }
            var added = 0
            for message in history.messages {
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?",
                                              arguments: [message.id.uuidString]) {
                    let parts = try Self.fetchParts(messageID: message.id, db: db)
                    let current = try Self.portableDeviceMessage(row, id: message.id, parts: parts)
                    guard (row["conversation_id"] as String) == conversationID,
                          current == message else {
                        throw DeviceConversationHistoryError.messageConflict(message.id)
                    }
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [message.id.uuidString, conversationID, message.role, message.content,
                                      PersistenceCodec.encode(message.createdAt)])
                for part in message.parts {
                    try Self.insertPart(.init(id: part.id, messageID: message.id, partIndex: part.index,
                        kind: .text, text: part.text, createdAt: part.createdAt), db: db)
                }
                added += 1
            }
            if added > 0 {
                let updatedAt = PersistenceCodec.encode(history.updatedAt)
                try db.execute(sql: "UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                               arguments: [updatedAt, conversationID])
            }
            return DeviceConversationImport(conversationID: history.id, addedMessages: added,
                                            createdConversation: existing == nil)
        }
    }

    /// The user/assistant text-only projection of one stored message. Native
    /// attachments, tool calls, permissions and runtime state never enter
    /// the portable shape. Android mirror of the fixed iOS helper
    /// (0d2c31722); text is redacted with the shared FloeCore rule exactly
    /// like the Apple store.
    private static func portableDeviceMessage(_ row: Row, id: UUID, parts: [MessagePart]) throws -> DeviceConversationHistory.Message {
        guard UUID(uuidString: row["conversation_id"]) != nil else {
            throw DeviceConversationHistoryError.invalidHistory
        }
        let safeParts: [DeviceConversationHistory.TextPart] = parts.compactMap {
            guard $0.kind == .text, let text = $0.text else { return nil }
            return .init(id: $0.id, index: $0.partIndex, text: SecretRedactor.redact(text), createdAt: $0.createdAt)
        }
        return .init(id: id, role: row["role"], content: SecretRedactor.redact(row["content"]),
                     createdAt: try PersistenceCodec.decodeDate(row["created_at"]), parts: safeParts)
    }

    public func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        // The thread UI grows this window in bounded increments while the
        // user explicitly asks for older history. Capping this method at 500
        // made the UI believe another page had loaded while returning the
        // same rows forever, and orphaned the corresponding historical tool
        // events from the timeline.
        let bounded = min(10_000, max(1, limit))
        return try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM (
                        SELECT messages.*, rowid AS stable_order FROM messages
                        WHERE conversation_id = ?
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT ?
                    ) ORDER BY created_at, stable_order
                    """,
                arguments: [conversationID.uuidString, bounded]
            )
            let messageIDs = try rows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            return try rows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
        }
    }

    public func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        let bounded = min(500, max(1, limit))
        return try await database.reader { db in
            let predicate: String
            var arguments: StatementArguments = [conversationID.uuidString]
            if let cursor {
                predicate = """
                    AND (created_at < ? OR (created_at = ? AND id < ?))
                    """
                let date = PersistenceCodec.encode(cursor.createdAt)
                arguments += [date, date, cursor.messageID.uuidString]
            } else {
                predicate = ""
            }
            arguments += [bounded + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ? \(predicate)
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: arguments
            )
            let hasEarlier = rows.count > bounded
            let pageRows = Array(rows.prefix(bounded).reversed())
            let messageIDs = try pageRows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            let messages = try pageRows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
            return ConversationMessagePage(
                messages: messages,
                earlierCursor: messages.first.map {
                    ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
                },
                hasEarlier: hasEarlier
            )
        }
    }

    /// Bounded, chronological window containing one exact message plus a
    /// few of its neighbours. Used by the in-thread find bar to reveal a
    /// durable hit outside the currently loaded page; never the whole
    /// conversation. Parts are hydrated so the window renders exactly like a
    /// normal page read. The target row is always included when it belongs to
    /// the conversation.
    public func messageWindow(
        conversationID: UUID,
        around messageID: UUID,
        before: Int,
        after: Int
    ) async throws -> ConversationMessagePage {
        let olderLimit = min(200, max(1, before))
        let newerLimit = min(20, max(0, after))
        return try await database.reader { db in
            guard let target = try Row.fetchOne(
                db,
                sql: "SELECT created_at FROM messages WHERE id = ? AND conversation_id = ?",
                arguments: [messageID.uuidString, conversationID.uuidString]
            ), let createdAtRaw: String = target["created_at"] else {
                throw FloeError.notFound("messageNotFound")
            }
            let older = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ?
                      AND (created_at < ? OR (created_at = ? AND id <= ?))
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [
                    conversationID.uuidString, createdAtRaw, createdAtRaw,
                    messageID.uuidString, olderLimit + 1,
                ]
            )
            let newer = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ?
                      AND (created_at > ? OR (created_at = ? AND id > ?))
                    ORDER BY created_at ASC, id ASC
                    LIMIT ?
                    """,
                arguments: [
                    conversationID.uuidString, createdAtRaw, createdAtRaw,
                    messageID.uuidString, newerLimit,
                ]
            )
            let rows = Array(older.reversed()) + newer
            let messageIDs = try rows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            let messages = try rows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
            return ConversationMessagePage(
                messages: messages,
                earlierCursor: messages.first.map {
                    ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
                },
                hasEarlier: older.count > olderLimit
            )
        }
    }

    public func message(id: UUID, conversationID: UUID) async throws -> PersistedMessage? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ? AND conversation_id = ? LIMIT 1",
                                            arguments: [id.uuidString, conversationID.uuidString]) else { return nil }
            return PersistedMessage(id: id, conversationID: conversationID, role: row["role"], content: row["content"],
                createdAt: try PersistenceCodec.decodeDate(row["created_at"]), parts: try Self.fetchParts(messageID: id, db: db),
                runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:)))
        }
    }

    public func parts(messageID: UUID) async throws -> [MessagePart] {
        try await database.reader { db in
            try Self.fetchParts(messageID: messageID, db: db)
        }
    }

    public func saveAttachment(_ attachment: AttachmentRef) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO attachments (
                        id, conversation_id, message_id, kind, display_name, uti,
                        byte_count, sha256, storage, url_bookmark, relative_path, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        message_id = excluded.message_id,
                        display_name = excluded.display_name,
                        byte_count = excluded.byte_count,
                        sha256 = excluded.sha256,
                        storage = excluded.storage,
                        url_bookmark = excluded.url_bookmark,
                        relative_path = excluded.relative_path
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
    }

    public func attachment(id: UUID) async throws -> AttachmentRef? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM attachments WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.attachment(from: row)
        }
    }

    public func attachments(conversationID: UUID) async throws -> [AttachmentRef] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE conversation_id = ? ORDER BY created_at, id",
                arguments: [conversationID.uuidString]
            ).map(Self.attachment(from:))
        }
    }

    // MARK: - RB-7 attachment staging additive seams (narrow, pure additions)
    //
    // Consumed by FloeAndroidCore's staging lane through the typed
    // `AttachmentCommittingStore` port. Verification closures run INSIDE this
    // store's own writer transaction immediately before the effect — the same
    // reviewed pattern the RB3 conversation-deletion seam recorded. The SQL
    // below is the ORIGINAL attachment column set (identical to
    // saveAttachment); no schema, no second store and no other call site is
    // touched. Publication is Main's serialized symlink -> reviewed regular
    // mirror step; this file is never written through the overlay symlink.

    /// Insert the EXACT staged conversation-level attachment row when
    /// `verification` passes in the same transaction. The original
    /// `saveAttachment` upsert semantics are preserved for verified
    /// replay; a differing durable row must be refused by the caller's
    /// verification closure before reaching this INSERT.
    public func insertAttachmentRowGuarded(
        _ attachment: AttachmentRef,
        verification: @escaping @Sendable (Database) throws -> Void
    ) async throws {
        try await database.writer { db in
            try verification(db)
            try db.execute(
                sql: """
                    INSERT INTO attachments (
                        id, conversation_id, message_id, kind, display_name, uti,
                        byte_count, sha256, storage, url_bookmark, relative_path, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        message_id = excluded.message_id,
                        display_name = excluded.display_name,
                        byte_count = excluded.byte_count,
                        sha256 = excluded.sha256,
                        storage = excluded.storage,
                        url_bookmark = excluded.url_bookmark,
                        relative_path = excluded.relative_path
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
    }

    /// Delete the EXACT attachment row only when `verification` passes in
    /// the same writer transaction. Returns true only if the DELETE
    /// removed the row.
    public func deleteAttachmentRowGuarded(
        id: UUID,
        verification: @escaping @Sendable (Database) throws -> Void
    ) async throws -> Bool {
        try await database.writer { db in
            try verification(db)
            try db.execute(sql: "DELETE FROM attachments WHERE id = ?",
                           arguments: [id.uuidString])
            return db.changesCount == 1
        }
    }

    /// Bounded single-row raw read for digest/CAS token computation. The
    /// projection runs inside this store's reader transaction; the store
    /// never learns a digest grammar (the caller owns the token).
    public func readAttachmentRow<T: Sendable>(
        id: UUID,
        projection: @escaping @Sendable (Row?) throws -> T
    ) async throws -> T {
        try await database.reader { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM attachments WHERE id = ?",
                arguments: [id.uuidString])
            return try projection(row)
        }
    }

    // MARK: - Row mapping

    private static func editorOwnership(from row: Row) throws -> ConversationEditorOwnership? {
        let kind = row["editor_owner_kind"] as String?
        let document = row["editor_document_id"] as String?
        let container = row["editor_container_id"] as String?
        if kind == nil && document == nil && container == nil { return nil }
        guard let kind, let parsedKind = ConversationEditorOwnership.Kind(rawValue: kind),
              let document, let documentID = UUID(uuidString: document),
              let container, let containerID = UUID(uuidString: container) else {
            throw FloeError.storageCorrupted("Invalid editor conversation ownership")
        }
        return .init(kind: parsedKind, documentID: documentID, containerID: containerID)
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
            archivedAt: (row["archived_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) },
            purpose: ConversationPurpose(rawValue: row["purpose"]) ?? .ordinary,
            visibility: ConversationVisibility(rawValue: row["visibility"] as String? ?? "normal")
                ?? .normal,
            pinnedAt: (row["pinned_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) },
            editorOwnership: try editorOwnership(from: row)
        )
    }

    private static func messageID(from row: Row) throws -> UUID {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid message identifier")
        }
        return id
    }

    private static func insertPart(_ part: MessagePart, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO message_parts (
                    id, message_id, part_index, kind, text, attachment_id,
                    metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id, part_index) DO UPDATE SET
                    kind = excluded.kind,
                    text = excluded.text,
                    attachment_id = excluded.attachment_id,
                    metadata_json = excluded.metadata_json
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

    private static func fetchParts(messageID: UUID, db: Database) throws -> [MessagePart] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM message_parts WHERE message_id = ? ORDER BY part_index",
            arguments: [messageID.uuidString]
        )
        return try rows.map { row in
            try part(from: row, messageID: messageID)
        }
    }

    /// Hydrates a message window with a bounded number of SQL statements.
    /// SQLite's bind limit varies by build, so large histories are chunked
    /// instead of falling back to one query per message.
    private static func fetchParts(
        messageIDs: [UUID],
        db: Database
    ) throws -> [UUID: [MessagePart]] {
        guard !messageIDs.isEmpty else { return [:] }
        var result: [UUID: [MessagePart]] = [:]
        for chunkStart in stride(from: 0, to: messageIDs.count, by: 400) {
            let chunk = Array(messageIDs[chunkStart..<min(chunkStart + 400, messageIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM message_parts
                    WHERE message_id IN (\(placeholders))
                    ORDER BY message_id, part_index
                    """,
                arguments: StatementArguments(chunk.map(\.uuidString))
            )
            for row in rows {
                guard let messageID = UUID(uuidString: row["message_id"]) else {
                    throw FloeError.storageCorrupted("Invalid message part owner")
                }
                result[messageID, default: []].append(try part(from: row, messageID: messageID))
            }
        }
        return result
    }

    private static func part(from row: Row, messageID: UUID) throws -> MessagePart {
            guard
                let id = UUID(uuidString: row["id"]),
                let kind = MessagePart.Kind(rawValue: row["kind"])
            else {
                throw FloeError.storageCorrupted("Invalid message part")
            }
            let attachmentID: UUID? = (row["attachment_id"] as String?).flatMap(UUID.init(uuidString:))
            return MessagePart(
                id: id,
                messageID: messageID,
                partIndex: row["part_index"],
                kind: kind,
                text: row["text"],
                attachmentID: attachmentID,
                metadata: try PersistenceCodec.jsonDictionary(row["metadata_json"]),
                createdAt: try PersistenceCodec.decodeDate(row["created_at"])
            )
    }

    private static func attachment(from row: Row) throws -> AttachmentRef {
        guard
            let id = UUID(uuidString: row["id"]),
            let kind = AttachmentRef.Kind(rawValue: row["kind"]),
            let storage = AttachmentRef.Storage(rawValue: row["storage"])
        else {
            throw FloeError.storageCorrupted("Invalid attachment record")
        }
        let conversationID: UUID? = (row["conversation_id"] as String?).flatMap(UUID.init(uuidString:))
        let messageID: UUID? = (row["message_id"] as String?).flatMap(UUID.init(uuidString:))
        return AttachmentRef(
            id: id,
            conversationID: conversationID,
            messageID: messageID,
            kind: kind,
            displayName: row["display_name"],
            uti: row["uti"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            storage: storage,
            urlBookmark: row["url_bookmark"],
            relativePath: row["relative_path"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"])
        )
    }

    // >>> RB3-CH-R1 ADDITIVE BEGIN
    /// Narrow ADDITIVE expected-row deletion seam for the RB3 conversation
    /// domain (Main review CH-R1, 2026-10-19). The original
    /// `deleteConversation(id:)` above is unchanged and remains the default
    /// path for every existing caller.
    ///
    /// This overload runs ALL of the following inside ONE
    /// `DatabaseManager.writer` transaction:
    /// 1. read the CURRENT raw `conversations` row;
    /// 2. call `expectedRow` with that exact row so the caller performs its
    ///    full raw-row + purpose CAS (a missing row is passed as nil);
    /// 3. call `beforeDelete` (the exact original memory-preservation SQL)
    ///    with the SAME `Database` handle;
    /// 4. run the ORIGINAL `RunLifecycleRetention.deleteOwnedRecords` and
    ///    `DELETE FROM conversations` exactly as `deleteConversation(id:)`.
    ///
    /// A throw from step 2 rolls back before step 3, so a stale refusal
    /// never reclassifies memory. Spool artifacts are removed only AFTER the
    /// transaction commits, exactly like the original method. No table,
    /// column, index, trigger or schema is added; this is a source-level
    /// additive overload only.
    public func deleteConversation(
        id: UUID,
        expectedRow: @escaping @Sendable (Row?) throws -> Void,
        beforeDelete: (@Sendable (Database) throws -> Void)? = nil
    ) async throws {
        let spoolPaths = try await database.writer { db -> [String] in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [id.uuidString]
            )
            try expectedRow(row)
            if let beforeDelete {
                try beforeDelete(db)
            }
            let paths = try RunLifecycleRetention.deleteOwnedRecords(db: db,
                                                                     conversationID: id)
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?",
                           arguments: [id.uuidString])
            return paths
        }
        RunLifecycleRetention.removeSpoolArtifacts(spoolPaths)
    }
    // <<< RB3-CH-R1 ADDITIVE END
}

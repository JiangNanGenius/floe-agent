// FloePersistence — Conversation / message / content-part / attachment store.
// See docs/ALPHA_DAILY_PLAN.md (Persistence v3). Secret-free by construction.

import Foundation
import Crypto
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
    /// Version 2 adds restorable user-attachment metadata and a display-only
    /// tool-result projection; version 1 remains the pre-upgrade shape.
    public func deviceHistory(conversationID: UUID) async throws -> DeviceConversationHistory {
        try await deviceHistory(conversationID: conversationID, version: 1)
    }

    public func deviceHistory(conversationID: UUID, version: Int) async throws -> DeviceConversationHistory {
        let requested = try Self.boundDeviceHistoryVersion(version)
        return try await database.reader { db in
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
            let context = try Self.deviceExportContext(messageRows: rows, ids: ids, parts: parts, db: db,
                                                       version: requested)
            let messages = try zip(rows, ids).map { row, id in
                try Self.portableDeviceMessage(row, id: id, parts: parts[id, default: []], context: context)
            }
            return DeviceConversationHistory(id: conversationID, title: SecretRedactor.redact(conversation.title),
                createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, messages: messages,
                attachments: context.attachmentList, version: requested)
        }
    }

    /// Reads one page ordered by committed changes in this conversation.
    /// The first read pins an upper bound so new activity cannot extend a
    /// transfer indefinitely. Nothing in this cursor depends on wall time.
    public func deviceHistoryPage(
        conversationID: UUID, after: String?, through: Int64?, version: Int = 1
    ) async throws -> DeviceConversationHistoryPage {
        let requested = try Self.boundDeviceHistoryVersion(version)
        return try await database.reader { db in
            let id = conversationID.uuidString
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
                throw DeviceConversationHistoryError.conversationUnavailable
            }
            let conversation = try Self.conversation(from: row)
            guard conversation.isVisibleInOrdinaryList else {
                throw DeviceConversationHistoryError.conversationUnavailable
            }
            let sequence = try Row.fetchOne(db, sql: """
                SELECT generation, sequence FROM device_history_sequences WHERE conversation_id = ?
                """, arguments: [id])
            let generation: String = sequence?["generation"] ?? ""
            let current: Int64 = sequence?["sequence"] ?? 0
            let upperBound = through ?? current
            var lowerBound: Int64 = 0
            if let after {
                let fields = after.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[0] == generation,
                      let position = Int64(fields[1]), position > 0,
                      let anchor = UUID(uuidString: String(fields[2])),
                      try String.fetchOne(db, sql: """
                          SELECT message_id FROM device_history_order WHERE conversation_id = ? AND sequence = ?
                          """, arguments: [id, position]) == anchor.uuidString else {
                    throw DeviceConversationHistoryError.cursorExpired
                }
                lowerBound = position
            }
            guard upperBound >= lowerBound, upperBound <= current else {
                throw DeviceConversationHistoryError.cursorExpired
            }

            let pageLimit = 128
            let candidates = try Row.fetchAll(db, sql: """
                SELECT h.sequence, m.id, length(CAST(m.content AS BLOB)) + COALESCE((
                    SELECT sum(length(CAST(p.text AS BLOB)) + 128)
                    FROM message_parts AS p WHERE p.message_id = m.id AND p.kind = 'text'
                ), 0) + CASE WHEN ? = 2 THEN COALESCE((
                    SELECT count(*) * 256
                    FROM message_parts AS p WHERE p.message_id = m.id AND p.kind IN ('image', 'file')
                ), 0) + COALESCE((
                    SELECT count(*) * 640
                    FROM run_events AS e WHERE e.run_id = m.run_id AND e.kind = 'toolResult'
                ), 0) ELSE 0 END AS bytes
                FROM device_history_order AS h JOIN messages AS m ON m.id = h.message_id
                WHERE h.conversation_id = ? AND h.sequence > ? AND h.sequence <= ?
                ORDER BY h.sequence LIMIT ?
                """, arguments: [requested, id, lowerBound, upperBound, pageLimit + 1])
            // Account for JSON escaping before materializing bodies. A single
            // large message may use the full archive bound of the prior wire.
            let textBudget = Int64(2 * 1_024 * 1_024 / 6)
            var budget = textBudget
            var count = 0
            for candidate in candidates.prefix(pageLimit) {
                let bytes: Int64 = candidate["bytes"]
                if count > 0, budget < bytes + 256 { break }
                guard bytes <= DeviceConversationHistory.maximumBytes else {
                    throw DeviceConversationHistoryError.sizeLimit
                }
                budget -= bytes + 256
                count += 1
            }
            let chosen = candidates.prefix(count)
            let ids = try chosen.map(Self.messageID(from:))
            let parts = try Self.fetchParts(messageIDs: ids, db: db)
            let lastPosition: Int64 = chosen.last?["sequence"] ?? lowerBound
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.* FROM device_history_order AS h JOIN messages AS m ON m.id = h.message_id
                WHERE h.conversation_id = ? AND h.sequence > ? AND h.sequence <= ? ORDER BY h.sequence
                """, arguments: [id, lowerBound, lastPosition])
            let context = try Self.deviceExportContext(messageRows: rows, ids: ids, parts: parts, db: db,
                                                       version: requested)
            let messages = try zip(rows, ids).map { row, id in
                try Self.portableDeviceMessage(row, id: id, parts: parts[id, default: []], context: context)
            }
            let history = DeviceConversationHistory(
                id: conversationID, title: SecretRedactor.redact(conversation.title), createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt, messages: messages,
                attachments: context.attachmentList, version: requested
            )
            let nextCursor = chosen.last.map { row in
                let position: Int64 = row["sequence"]
                let anchor: String = row["id"]
                return "\(generation):\(position):\(anchor)"
            } ?? after
            return try DeviceConversationHistoryPage(archive: history.encoded(), nextCursor: nextCursor,
                                                      through: upperBound, hasMore: count < candidates.count)
        }
    }

    public func deviceHistoryCursor(from peerID: String, conversationID: UUID) async throws -> String? {
        guard !peerID.isEmpty, peerID.utf8.count <= 128 else { throw DeviceConversationHistoryError.invalidHistory }
        return try await database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT cursor FROM device_history_receive_cursors WHERE peer_id = ? AND conversation_id = ?
                """, arguments: [peerID, conversationID.uuidString])
        }
    }

    /// Inserts only new history, using the usual native workspace ownership.
    /// A differing existing message aborts the page and its cursor commit. It cannot be
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
        try await importDeviceHistory(history, sourcePeerID: nil, nextCursor: nil, hasLiveRun: hasLiveRun)
    }

    public func importDeviceHistory(
        _ history: DeviceConversationHistory, sourcePeerID: String?, nextCursor: String?,
        hasLiveRun: @escaping @Sendable (Database) throws -> Bool
    ) async throws -> DeviceConversationImport {
        try history.validate()
        guard sourcePeerID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              nextCursor.map({ sourcePeerID != nil && !$0.isEmpty && $0.utf8.count <= 160 }) ?? true else {
            throw DeviceConversationHistoryError.invalidHistory
        }
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
            // The writer transaction proves the run is still idle before admission.
            guard try hasLiveRun(db) == false else { throw DeviceConversationHistoryError.busy }
            let attachments = Dictionary(uniqueKeysWithValues: history.attachments.map { ($0.id, $0) })
            let timestamps = PersistenceCodec.fractionalDateFormatter()
            var added = 0
            for message in history.messages {
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?",
                                              arguments: [message.id.uuidString]) {
                    let storedParts = try Self.fetchParts(messageID: message.id, db: db)
                    let current = try Self.portableDeviceV1Message(row, id: message.id, parts: storedParts,
                                                                  timestamps: timestamps)
                    // Conflict detection stays on the portable text projection
                    // so a v1 import followed by a v2 re-send merges instead of
                    // conflicting; only real content edits abort the page.
                    guard (row["conversation_id"] as String) == conversationID,
                          current == (try Self.deviceV1Projection(message, timestamps: timestamps)) else {
                        throw DeviceConversationHistoryError.messageConflict(message.id)
                    }
                    if history.version >= 2 {
                        try Self.recordImportedAttachments(for: message, records: attachments, conversationID: history.id, db: db)
                        try Self.mergeImportedParts(message, history: history, storedParts: storedParts, db: db)
                    }
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [message.id.uuidString, conversationID, message.role, message.content,
                                      timestamps.string(from: message.createdAt)])
                try Self.recordImportedAttachments(for: message, records: attachments, conversationID: history.id, db: db)
                for part in message.parts {
                    guard let devicePart = try Self.importedDevicePart(part, history: history,
                                                                       messageID: message.id, db: db) else {
                        continue
                    }
                    try Self.insertPart(devicePart, db: db)
                }
                added += 1
            }
            if added > 0 {
                let updatedAt = timestamps.string(from: history.updatedAt)
                try db.execute(sql: "UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                               arguments: [updatedAt, conversationID])
            }
            if let sourcePeerID {
                if let nextCursor {
                    try db.execute(sql: """
                        INSERT INTO device_history_receive_cursors (peer_id, conversation_id, cursor)
                        VALUES (?, ?, ?) ON CONFLICT(peer_id, conversation_id) DO UPDATE SET cursor = excluded.cursor
                        """, arguments: [sourcePeerID, conversationID, nextCursor])
                } else {
                    try db.execute(sql: """
                        DELETE FROM device_history_receive_cursors WHERE peer_id = ? AND conversation_id = ?
                        """, arguments: [sourcePeerID, conversationID])
                }
            }
            return DeviceConversationImport(conversationID: history.id, addedMessages: added,
                                            createdConversation: existing == nil)
        }
    }

    /// Everything a versioned export needs beyond the message rows: the
    /// restorable attachment records and the per-message tool projections.
    private struct DeviceExportContext {
        let version: Int
        /// Restorable attachments keyed by id.
        let attachments: [UUID: AttachmentRef]
        /// Display-only tool parts keyed by target message id.
        let toolResults: [UUID: [DeviceConversationHistory.Part]]
        let attachmentList: [DeviceConversationHistory.Attachment]
    }

    private static func boundDeviceHistoryVersion(_ version: Int) throws -> Int {
        guard version == 1 || version == 2 else { throw DeviceConversationHistoryError.unsupportedVersion }
        return version
    }

    private static func deviceExportContext(
        messageRows: [Row], ids: [UUID], parts: [UUID: [MessagePart]], db: Database, version: Int
    ) throws -> DeviceExportContext {
        guard version >= 2 else {
            return DeviceExportContext(version: version, attachments: [:], toolResults: [:], attachmentList: [])
        }
        var owners: [UUID: UUID] = [:]
        for (row, id) in zip(messageRows, ids) where (row["role"] as String) == "user" {
            for part in parts[id, default: []] where part.kind == .image || part.kind == .file {
                if let attachmentID = part.attachmentID { owners[attachmentID] = id }
            }
        }
        let restorable = try restorableDeviceAttachments(ids: Array(owners.keys), db: db).filter {
            $0.value.messageID == owners[$0.key]
        }
        let attachmentList = restorable.values
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map {
                DeviceConversationHistory.Attachment(
                    id: $0.id, kind: $0.kind.rawValue,
                    displayName: truncatingUTF8(SecretRedactor.redact($0.displayName), to: 256),
                    uti: truncatingUTF8($0.uti, to: 128), byteCount: $0.byteCount,
                    sha256: $0.sha256, createdAt: $0.createdAt)
            }
        let toolResults = try deviceToolResults(messageRows: messageRows, db: db)
        return DeviceExportContext(version: version, attachments: restorable,
                                   toolResults: toolResults, attachmentList: attachmentList)
    }

    /// Only app-owned, digest-tagged attachment bytes can be restored on the
    /// peer. Security-scoped bookmarks and missing/oversized payloads stay
    /// local and are reported as not fully restorable.
    private static func restorableDeviceAttachments(ids: [UUID], db: Database) throws -> [UUID: AttachmentRef] {
        var candidates: [AttachmentRef] = []
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            guard !chunk.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM attachments WHERE id IN (\(placeholders))",
                                        arguments: StatementArguments(chunk.map(\.uuidString)))
            for row in rows {
                let ref = try attachment(from: row)
                guard ref.storage == .applicationSupport, ref.relativePath != nil, !ref.displayName.isEmpty,
                      DeviceConversationHistory.isValidDigest(ref.sha256),
                      (0...DeviceConversationHistory.maximumRestorableAttachmentBytesPerItem).contains(ref.byteCount) else { continue }
                candidates.append(ref)
            }
        }
        var result: [UUID: AttachmentRef] = [:]
        var total: Int64 = 0
        for ref in candidates.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            guard result.count < DeviceConversationHistory.maximumRestorableAttachments,
                  total + Int64(ref.byteCount) <= DeviceConversationHistory.maximumRestorableAttachmentBytes else { break }
            result[ref.id] = ref
            total += Int64(ref.byteCount)
        }
        return result
    }

    /// Projects persisted tool-result run events into display-only history
    /// parts. The payload is the redacted string map persisted by the run
    /// service; only tool name, status, and a bounded summary cross the
    /// wire — never arguments, full output, or replayable identifiers.
    private static func deviceToolResults(
        messageRows: [Row], db: Database
    ) throws -> [UUID: [DeviceConversationHistory.Part]] {
        var lastMessageByRun: [UUID: UUID] = [:]
        for row in messageRows {
            guard let id = try? Self.messageID(from: row),
                  let runID = (row["run_id"] as String?).flatMap(UUID.init(uuidString:)) else { continue }
            lastMessageByRun[runID] = id
        }
        var result: [UUID: [DeviceConversationHistory.Part]] = [:]
        for (runID, messageID) in lastMessageByRun {
            let rows = try Row.fetchAll(db, sql: """
                SELECT sequence, payload_json, created_at FROM run_events
                WHERE run_id = ? AND kind = 'toolResult' ORDER BY sequence LIMIT ?
                """, arguments: [runID.uuidString, DeviceConversationHistory.maximumToolResultsPerMessage])
            var parts: [DeviceConversationHistory.Part] = []
            for row in rows {
                guard let payload = try? PersistenceCodec.jsonDictionary(row["payload_json"]),
                      let tool = payload["tool"], !tool.isEmpty else { continue }
                let summary = truncatingUTF8(SecretRedactor.redact(payload["summary"] ?? ""),
                                             to: DeviceConversationHistory.maximumToolResultSummaryBytes)
                guard !summary.isEmpty else { continue }
                let createdAt = (try? PersistenceCodec.decodeDate(row["created_at"])) ?? Date()
                let sequence: Int = row["sequence"]
                parts.append(DeviceConversationHistory.Part(
                    id: deterministicDevicePartID(messageID: messageID, tag: "tool", sequence: sequence),
                    index: 0, kind: .tool, text: summary,
                    toolName: truncatingUTF8(tool, to: 256),
                    toolStatus: payload["status"].map { truncatingUTF8($0, to: 32) },
                    createdAt: createdAt))
            }
            if !parts.isEmpty { result[messageID] = parts }
        }
        return result
    }

    /// Stable part identifiers let retries and re-imports deduplicate on the
    /// same rows instead of minting fresh UUIDs per export.
    static func deterministicDevicePartID(messageID: UUID, tag: String, sequence: Int) -> UUID {
        var hash = SHA256()
        hash.update(data: Data("floe-device-part\0\(tag)\0\(messageID.uuidString)\0\(sequence)".utf8))
        let digest = hash.finalize()
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func truncatingUTF8(_ value: String, to maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var prefix = value.utf8.prefix(maxBytes)
        while let last = prefix.last, last >= 128, String(prefix) == nil { prefix = prefix.dropLast() }
        return String(prefix) ?? ""
    }

    private static func portableDeviceMessage(
        _ row: Row, id: UUID, parts: [MessagePart], context: DeviceExportContext
    ) throws -> DeviceConversationHistory.Message {
        guard UUID(uuidString: row["conversation_id"]) != nil else {
            throw DeviceConversationHistoryError.invalidHistory
        }
        var safeParts: [DeviceConversationHistory.Part] = parts.compactMap {
            guard $0.kind == .text, $0.metadata["deviceHistory.tool"] == nil, let text = $0.text else { return nil }
            return .init(id: $0.id, index: $0.partIndex, kind: .text,
                         text: SecretRedactor.redact(text), createdAt: $0.createdAt)
        }
        if context.version >= 2 {
            let role: String = row["role"]
            for part in parts {
                switch part.kind {
                case .image, .file:
                    guard role == "user", let attachmentID = part.attachmentID,
                          context.attachments[attachmentID]?.messageID == id else { break }
                    safeParts.append(.init(id: part.id, index: part.partIndex, kind: .attachment,
                                           attachmentID: attachmentID, createdAt: part.createdAt))
                case .text:
                    if let tool = part.metadata["deviceHistory.tool"], let summary = part.text {
                        safeParts.append(.init(id: part.id, index: part.partIndex, kind: .tool, text: summary,
                            toolName: tool, toolStatus: part.metadata["deviceHistory.toolStatus"], createdAt: part.createdAt))
                    }
                default:
                    break
                }
            }
            if let tools = context.toolResults[id] {
                var nextIndex = (safeParts.map(\.index).max() ?? -1) + 1
                for tool in tools {
                    safeParts.append(.init(id: tool.id, index: nextIndex, kind: .tool, text: tool.text,
                                           toolName: tool.toolName, toolStatus: tool.toolStatus,
                                           createdAt: tool.createdAt))
                    nextIndex += 1
                }
            }
        }
        return .init(id: id, role: row["role"], content: SecretRedactor.redact(row["content"]),
                     createdAt: try PersistenceCodec.decodeDate(row["created_at"]), parts: safeParts)
    }

    /// The conflict-detection projection: text parts only. Stable across
    /// archive versions so a v1 import and a later v2 re-send of the same
    /// message compare equal and merge.
    private static func portableDeviceV1Message(
        _ row: Row, id: UUID, parts: [MessagePart], timestamps: ISO8601DateFormatter
    ) throws -> DeviceConversationHistory.Message {
        guard UUID(uuidString: row["conversation_id"]) != nil else {
            throw DeviceConversationHistoryError.invalidHistory
        }
        let safeParts: [DeviceConversationHistory.Part] = parts.compactMap {
            guard $0.kind == .text, $0.metadata["deviceHistory.tool"] == nil, let text = $0.text else { return nil }
            return .init(id: $0.id, index: $0.partIndex, kind: .text,
                         text: SecretRedactor.redact(text), createdAt: $0.createdAt)
        }
        return .init(id: id, role: row["role"], content: SecretRedactor.redact(row["content"]),
                     createdAt: try PersistenceCodec.decodeDate(row["created_at"], fractional: timestamps),
                     parts: safeParts)
    }

    private static func deviceV1Projection(
        _ message: DeviceConversationHistory.Message, timestamps: ISO8601DateFormatter
    ) throws -> DeviceConversationHistory.Message {
        // Compare at the precision retained by SQLite on the first import.
        func storedDate(_ date: Date) throws -> Date {
            try PersistenceCodec.decodeDate(timestamps.string(from: date), fractional: timestamps)
        }
        let textParts = try message.parts.filter { $0.kind == .text }.sorted { $0.index < $1.index }.map {
            try DeviceConversationHistory.Part(id: $0.id, index: $0.index, kind: .text,
                                               text: $0.text, createdAt: storedDate($0.createdAt))
        }
        return try .init(id: message.id, role: message.role, content: message.content,
                         createdAt: storedDate(message.createdAt), parts: textParts)
    }

    /// Binds an imported part to the native message_parts row. Attachment
    /// parts are only bound when the bytes already exist locally (re-import
    /// after a successful restore); otherwise the restore phase binds them
    /// after verifying the transferred bytes, so no dangling link appears.
    private static func importedDevicePart(
        _ part: DeviceConversationHistory.Part, history: DeviceConversationHistory,
        messageID: UUID, db: Database
    ) throws -> MessagePart? {
        switch part.kind {
        case .text:
            return .init(id: part.id, messageID: messageID, partIndex: part.index, kind: .text,
                         text: part.text, createdAt: part.createdAt)
        case .tool:
            var metadata = ["deviceHistory.tool": part.toolName ?? ""]
            if let status = part.toolStatus { metadata["deviceHistory.toolStatus"] = status }
            return .init(id: part.id, messageID: messageID, partIndex: part.index, kind: .text,
                         text: part.text, metadata: metadata, createdAt: part.createdAt)
        case .attachment:
            guard let attachmentID = part.attachmentID,
                  let record = history.attachments.first(where: { $0.id == attachmentID }),
                  try attachmentRestored(id: attachmentID, db: db) else { return nil }
            let kind: MessagePart.Kind = record.kind == "image" ? .image : .file
            return .init(id: part.id, messageID: messageID, partIndex: part.index, kind: kind,
                         attachmentID: attachmentID, metadata: ["name": record.displayName],
                         createdAt: part.createdAt)
        }
    }

    /// Merges v2-only parts into an already-imported message without touching
    /// existing rows. Idempotent by part id and by attachment id.
    private static func mergeImportedParts(
        _ message: DeviceConversationHistory.Message, history: DeviceConversationHistory,
        storedParts: [MessagePart], db: Database
    ) throws {
        var storedIDs = Set(storedParts.map(\.id))
        var storedAttachmentIDs = Set(storedParts.compactMap(\.attachmentID))
        var changed = false
        for part in message.parts where part.kind != .text && storedIDs.insert(part.id).inserted {
            if let attachmentID = part.attachmentID, !storedAttachmentIDs.insert(attachmentID).inserted {
                continue
            }
            guard let devicePart = try importedDevicePart(part, history: history,
                messageID: message.id, db: db) else { continue }
            try insertPartIfAbsent(devicePart, db: db)
            changed = changed || db.changesCount > 0
        }
        if changed { try V68DeviceHistoryPaging.recordProjectionChange(messageID: message.id.uuidString, db: db) }
    }

    private static func attachmentRestored(id: UUID, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT storage, relative_path FROM attachments WHERE id = ?",
                                         arguments: [id.uuidString]) else { return false }
        let storage: String = row["storage"]
        let path: String? = row["relative_path"]
        return storage == "applicationSupport" && path != nil
    }

    private static func recordImportedAttachments(for message: DeviceConversationHistory.Message,
        records: [UUID: DeviceConversationHistory.Attachment], conversationID: UUID, db: Database
    ) throws {
        for part in message.parts where part.kind == .attachment {
            guard let id = part.attachmentID, let info = records[id] else {
                throw DeviceConversationHistoryError.invalidHistory
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM attachments WHERE id = ?", arguments: [id.uuidString]) {
                let local = try attachment(from: row)
                guard local.conversationID == conversationID, local.messageID == message.id,
                      local.kind.rawValue == info.kind, local.byteCount == info.byteCount,
                      local.sha256.isEmpty || local.sha256 == info.sha256 else {
                    throw DeviceConversationHistoryError.messageConflict(message.id)
                }
                continue
            }
            try db.execute(sql: """
                INSERT INTO attachments (
                    id, conversation_id, message_id, kind, display_name, uti,
                    byte_count, sha256, storage, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'none', ?)
                """, arguments: [id.uuidString, conversationID.uuidString, message.id.uuidString,
                    info.kind, info.displayName, info.uti, info.byteCount, info.sha256,
                    PersistenceCodec.encode(info.createdAt)])
        }
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

    /// Only attachments originating in a user message of this exact task are
    /// candidates for sending or retrying a deferred import.
    public func deviceHistoryUserAttachments(conversationID: UUID, storage: AttachmentRef.Storage) async throws -> [AttachmentRef] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT a.* FROM attachments AS a JOIN messages AS m ON m.id = a.message_id
                WHERE a.conversation_id = ? AND m.conversation_id = a.conversation_id
                  AND m.role = 'user' AND a.storage = ? AND a.byte_count BETWEEN 0 AND ?
                ORDER BY a.created_at, a.id LIMIT ?
                """, arguments: [conversationID.uuidString, storage.rawValue,
                    DeviceConversationHistory.maximumRestorableAttachmentBytesPerItem,
                    DeviceConversationHistory.maximumRestorableAttachments]).map(Self.attachment(from:))
        }
    }

    public func deviceHistoryUserAttachment(conversationID: UUID, id: UUID) async throws -> AttachmentRef? {
        try await database.reader { db in
            try Row.fetchOne(db, sql: """
                SELECT a.* FROM attachments AS a JOIN messages AS m ON m.id = a.message_id
                WHERE a.id = ? AND a.conversation_id = ? AND m.conversation_id = a.conversation_id AND m.role = 'user'
                """, arguments: [id.uuidString, conversationID.uuidString]).map(Self.attachment(from:))
        }
    }

    public func noteDeviceAttachmentDigest(_ digest: String, for previous: AttachmentRef) async throws {
        guard DeviceConversationHistory.isValidDigest(digest), let owner = previous.conversationID,
              let message = previous.messageID, let relative = previous.relativePath else { return }
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE attachments SET sha256 = ? WHERE id = ? AND conversation_id = ?
                  AND message_id = ? AND relative_path = ? AND storage = 'applicationSupport'
                  AND byte_count = ? AND sha256 = ''
                """, arguments: [digest, previous.id.uuidString, owner.uuidString, message.uuidString,
                    relative, previous.byteCount])
            if db.changesCount > 0 {
                try V68DeviceHistoryPaging.recordProjectionChange(messageID: message.uuidString, db: db)
            }
        }
    }

    /// Commits the already verified local file and its visible message part
    /// together. A retry can reuse the verified file and the native part.
    public func restoreDeviceHistoryAttachment(conversationID: UUID, attachmentID: UUID, messageID: UUID,
                                               digest: String, relativePath: String,
                                               guardCurrent: @escaping @Sendable (Database) throws -> Bool) async throws -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard DeviceConversationHistory.isValidDigest(digest), components.count == 2,
              components[0] == attachmentID.uuidString, !components[1].isEmpty,
              components[1] != ".", components[1] != ".." else { return false }
        return try await database.writer { db in
            guard try guardCurrent(db) else { return false }
            guard let conversation = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?",
                    arguments: [conversationID.uuidString]),
                  try Self.conversation(from: conversation).isVisibleInOrdinaryList else { return false }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.* FROM attachments AS a JOIN messages AS m ON m.id = a.message_id
                WHERE a.id = ? AND a.message_id = ? AND a.conversation_id = ?
                  AND m.conversation_id = a.conversation_id AND m.role = 'user'
                """, arguments: [attachmentID.uuidString, messageID.uuidString, conversationID.uuidString]) else { return false }
            let info = try Self.attachment(from: row)
            guard info.sha256 == digest else { return false }
            if info.storage == .applicationSupport { return info.relativePath == relativePath }
            guard info.storage == .none else { return false }
            try db.execute(sql: "UPDATE attachments SET storage = 'applicationSupport', relative_path = ? WHERE id = ?",
                           arguments: [relativePath, attachmentID.uuidString])
            let index = try Int.fetchOne(db, sql: "SELECT coalesce(max(part_index), -1) + 1 FROM message_parts WHERE message_id = ?",
                                         arguments: [messageID.uuidString]) ?? 0
            let id = Self.deterministicDevicePartID(messageID: messageID, tag: attachmentID.uuidString, sequence: 0)
            try Self.insertPart(.init(id: id, messageID: messageID, partIndex: index,
                kind: info.kind == .image ? .image : .file, attachmentID: attachmentID,
                metadata: ["name": info.displayName], createdAt: info.createdAt), db: db)
            try V68DeviceHistoryPaging.recordProjectionChange(messageID: messageID.uuidString, db: db)
            return true
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

    /// Import merging never rewrites an existing part row: the first import
    /// and the attachment restore own their (message, index) slots.
    private static func insertPartIfAbsent(_ part: MessagePart, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO message_parts (
                    id, message_id, part_index, kind, text, attachment_id,
                    metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id, part_index) DO NOTHING
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

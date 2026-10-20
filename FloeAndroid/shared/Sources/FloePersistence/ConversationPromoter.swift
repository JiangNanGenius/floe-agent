// FloePersistence — atomic promotion of a temporary conversation snapshot.
//
// One GRDB writer transaction commits the entire frozen snapshot
// (conversation, messages/parts, attachments, runs, events, usage, errors).
// Either every row lands — including the FTS index via the schema's
// ai/ad/au triggers — or the transaction rolls back and zero content is
// durable. There is deliberately no compensating-delete path here: partial
// visibility is impossible by construction, and WAL rollback leaves no
// committed content behind.
//
// Insert order follows the REAL migrated schema's foreign keys:
//   conversations ← runs (messages.run_id, events/usage/errors.run_id)
//   conversations ← messages (parts.message_id)
//   messages ← attachments (attachments.message_id)
//   messages + attachments ← message_parts (parts FK both)
// The previous messages-before-runs order violated messages.run_id's FK for
// any stream that tagged messages with their run.
//
// Before anything is written, the snapshot itself is validated: ordinary-only
// target, one owning conversation for every row, parts owned by their
// message, events/usage/errors bound to a run inside the snapshot, and no
// id-level conflict with rows already durable under a DIFFERENT owner — a
// malformed or injected snapshot can never rewrite another conversation's
// history. Validation failures throw before any mutation, so the transaction
// commits everything or nothing.

import Foundation
import GRDB
import FloeCore
import FloeModels

// MARK: - Promotion commit fence (RB5 narrow additive hook — Android-owned
// mirror addition; the published original offers no commit fence at all)

/// Owner-controlled linearization point for ONE promotion writer
/// transaction versus the temporary session's actual discard.
///
/// THE BOUNDARY IS THE REAL SQLITE COMMIT CALLBACK, not the closure return:
/// `PromotionCommitBoundaryObserver` is registered on the SAME writer
/// connection for exactly this transaction, and GRDB invokes
/// `databaseWillCommit()` from SQLite's `sqlite3_commit_hook` DURING the
/// COMMIT statement (pinned GRDB TransactionObserver.swift:229-244 — "During
/// the statement execution, SQLite tells the broker that the transaction is
/// about to be committed through sqlite3_commit_hook... If the observer
/// throws an error, the broker asks SQLite to rollback the transaction").
/// Therefore a discard that lands AFTER the writer closure has returned (and
/// after any in-body boolean check) but BEFORE the actual COMMIT still
/// refuses the COMMIT: the whole transaction rolls back with ZERO durable
/// rows. Only a fence flip that lands AFTER the callback has already allowed
/// the commit (the in-flight fsync window) keeps durable rows — the honest
/// "genuinely committed durable rows survive" truth.
///
/// Contract (all three synchronous, lock-only, never an await, never I/O):
/// * `allowsCommit()` — advisory early/inside-body consultations (cheap
///   refusal; NOT the linearization point).
/// * `beginFinalCommit()` — the AUTHORITATIVE consultation, made by the
///   commit-boundary observer inside `databaseWillCommit`. Returning false
///   refuses the COMMIT (full rollback, zero rows/FTS); returning true
///   registers the commit as in flight (from that instant a flip resolves as
///   the true commit-winner window).
/// * `finishFinalCommit(committed:)` — called by the promoter AFTER the
///   writer await has actually resolved: `true` only when the real GRDB
///   transaction COMMITTED, `false` on any throw (including the
///   commit-hook refusal or a SQL/COMMIT failure). It resolves a registered
///   attempt to the truth the database observed, and is otherwise a no-op
///   (idempotent; never fabricates an outcome for an attempt that never
///   started).
///
/// `commitBoundaryRefused` lets the promoter translate a hook refusal back
/// into the typed `PromotionCommitRefused` regardless of how the SQLite
/// abort error is wrapped by the driver.
public protocol PromotionCommitFence: Sendable {
    func allowsCommit() -> Bool
    func beginFinalCommit() -> Bool
    func finishFinalCommit(committed: Bool)
    var commitBoundaryRefused: Bool { get }
}

public extension PromotionCommitFence {
    /// A minimal conformer keeps the advisory body-boundary semantics (every
    /// real call site implements all members with the commit observer).
    func beginFinalCommit() -> Bool { allowsCommit() }
    func finishFinalCommit(committed: Bool) {}
    var commitBoundaryRefused: Bool { false }
}

/// Typed commit-time refusal. Distinct from `ValidationError` (snapshot
/// refused before mutation) and from a SQLite error, so callers can report
/// "fence refused, zero durable rows" honestly. Carries no content.
public enum PromotionCommitRefused: Error, Sendable, Equatable {
    case refused
}

/// Registered on the SAME writer connection for exactly ONE promotion
/// transaction with `.nextTransaction` extent: GRDB retains it strongly for
/// this transaction (TransactionObservation.swift:983-985) and retires the
/// observation at the transaction end (databaseDidEndTransaction filters
/// non-observing entries). `databaseWillCommit()` is the real pre-COMMIT
/// callback; throwing refuses the COMMIT. No manual connection surgery is
/// needed — pooled connections never carry the fence into a later
/// transaction, and there is no double-removal hazard.
/// TEST-ONLY trusted same-writer seam (internal; NEVER set by production
/// code): runs inside `databaseWillCommit`, AFTER the owner fence allowed
/// the commit, and may throw to force a REAL same-connection transaction
/// failure at the actual commit — used to prove that an unfenced failure
/// keeps the RAM session retryable while a fenced one stays refused.
enum PromotionCommitBoundaryTestHooks {
    nonisolated(unsafe) static var afterBoundaryAllowForTesting:
        (@Sendable () throws -> Void)?
}

final class PromotionCommitBoundaryObserver: TransactionObserver, @unchecked Sendable {
    private let fence: any PromotionCommitFence

    init(fence: any PromotionCommitFence) {
        self.fence = fence
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}

    /// Called from SQLite's `sqlite3_commit_hook` during the actual COMMIT.
    func databaseWillCommit() throws {
        guard fence.beginFinalCommit() else {
            throw PromotionCommitRefused.refused
        }
        // Trusted test seam (nil in production): a REAL same-connection
        // failure after the boundary was allowed must resolve as a failed
        // commit (rollback), never a phantom success.
        try PromotionCommitBoundaryTestHooks.afterBoundaryAllowForTesting?()
    }

    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

public actor ConversationPromoter {
    /// Frozen source of truth for one promotion. Built from the ephemeral
    /// stores' buffered snapshot while their gateway holds late appends in
    /// RAM; the caller completes the gateway afterwards so subsequent
    /// appends forward in original order.
    public struct Snapshot: Sendable {
        /// The conversation record with `purpose == .ordinary` and the
        /// promotion title already applied.
        public var conversation: ConversationRecord
        public var messages: [PersistedMessage]
        public var attachments: [AttachmentRef]
        public var runs: [RunRecord]
        /// Flat, run-tagged events in original append order. Sequences are
        /// preserved exactly; each run is new to the durable store, so the
        /// per-run monotonic counter starts at the snapshot values.
        public var events: [RunEventRecord]
        public var usage: [RunUsageRecord]
        public var errors: [RunErrorRecord]
        /// Queued / steer-pending running inputs frozen at the promotion
        /// watermark. Promoted inside the SAME transaction so "Keep as a
        /// saved chat" can never report success while the user's pending
        /// messages exist only in RAM.
        public var inputs: [PendingUserInput]

        public init(
            conversation: ConversationRecord,
            messages: [PersistedMessage],
            attachments: [AttachmentRef],
            runs: [RunRecord],
            events: [RunEventRecord],
            usage: [RunUsageRecord],
            errors: [RunErrorRecord],
            inputs: [PendingUserInput] = []
        ) {
            self.conversation = conversation
            self.messages = messages
            self.attachments = attachments
            self.runs = runs
            self.events = events
            self.usage = usage
            self.errors = errors
            self.inputs = inputs
        }
    }

    /// Integrity failure detected before any durable write. Distinct from a
    /// commit-time SQLite error so callers can report "snapshot refused" vs
    /// "transaction rolled back" honestly.
    public enum ValidationError: Error, Sendable, CustomStringConvertible {
        case targetNotOrdinary(UUID)
        case foreignMessageOwner(UUID)
        case foreignRunOwner(UUID)
        case foreignAttachmentOwner(UUID)
        case partNotOwnedByMessage(UUID)
        case eventRunOutsideSnapshot(UUID)
        case usageRunOutsideSnapshot(UUID)
        case errorRunOutsideSnapshot(UUID)
        case messageConflict(UUID)
        case partConflict(UUID)
        case attachmentConflict(UUID)
        case runConflict(UUID)
        case eventConflict(UUID)
        case inputConflict(UUID)

        public var description: String {
            switch self {
            case .targetNotOrdinary(let id): "Promotion target \(id.uuidString) is not an ordinary conversation"
            case .foreignMessageOwner(let id): "Snapshot message \(id.uuidString) belongs to a different conversation"
            case .foreignRunOwner(let id): "Snapshot run \(id.uuidString) belongs to a different conversation"
            case .foreignAttachmentOwner(let id): "Snapshot attachment \(id.uuidString) belongs to a different conversation"
            case .partNotOwnedByMessage(let id): "Snapshot part \(id.uuidString) is not owned by its message"
            case .eventRunOutsideSnapshot(let id): "Snapshot event \(id.uuidString) targets a run outside the snapshot"
            case .usageRunOutsideSnapshot(let id): "Snapshot usage \(id.uuidString) targets a run outside the snapshot"
            case .errorRunOutsideSnapshot(let id): "Snapshot error \(id.uuidString) targets a run outside the snapshot"
            case .messageConflict(let id): "Message \(id.uuidString) already exists under a different owner"
            case .partConflict(let id): "Message part \(id.uuidString) already exists under a different owner"
            case .attachmentConflict(let id): "Attachment \(id.uuidString) already exists under a different owner"
            case .runConflict(let id): "Run \(id.uuidString) already exists under a different owner"
            case .eventConflict(let id): "Run event \(id.uuidString) already exists under a different owner"
            case .inputConflict(let id): "Pending input \(id.uuidString) already exists under a different owner"
            }
        }
    }

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Validates the snapshot against itself and against rows already
    /// durable. Runs SELECTs only: by the time the first INSERT executes,
    /// every identity is known-good, so a throw here mutates nothing.
    static func validate(_ snapshot: Snapshot, db: Database) throws {
        let conversation = snapshot.conversation
        guard conversation.purpose == .ordinary else {
            throw ValidationError.targetNotOrdinary(conversation.id)
        }
        let target = conversation.id
        for message in snapshot.messages where message.conversationID != target {
            throw ValidationError.foreignMessageOwner(message.id)
        }
        for run in snapshot.runs where run.conversationID != target {
            throw ValidationError.foreignRunOwner(run.id)
        }
        for attachment in snapshot.attachments {
            if let owner = attachment.conversationID, owner != target {
                throw ValidationError.foreignAttachmentOwner(attachment.id)
            }
        }
        let runIDs = Set(snapshot.runs.map(\.id))
        for message in snapshot.messages {
            for part in message.parts where part.messageID != message.id {
                throw ValidationError.partNotOwnedByMessage(part.id)
            }
        }
        for event in snapshot.events where !runIDs.contains(event.runID) {
            throw ValidationError.eventRunOutsideSnapshot(event.id)
        }
        for record in snapshot.usage where !runIDs.contains(record.runID) {
            throw ValidationError.usageRunOutsideSnapshot(record.id)
        }
        for record in snapshot.errors where !runIDs.contains(record.runID) {
            throw ValidationError.errorRunOutsideSnapshot(record.id)
        }
        for input in snapshot.inputs where input.conversationID != target {
            throw ValidationError.inputConflict(input.id)
        }

        // Cross-owner conflict rejection. Promotion is the first durable
        // write of these ids (toggle-on-empty removed the placeholder row),
        // so any row already present under a DIFFERENT owner means the
        // snapshot was corrupted or injected — fail closed before writing.
        // Same-owner repeats are the idempotent retry and stay legal.
        let targetKey = target.uuidString
        try rejectForeignRows(
            table: "messages", ids: snapshot.messages.map(\.id.uuidString),
            ownerColumn: "conversation_id", ownerKey: targetKey,
            conflict: ValidationError.messageConflict, db: db)
        let partIDs = snapshot.messages.flatMap { $0.parts.map(\.id.uuidString) }
        try rejectForeignRows(
            table: "message_parts", ids: partIDs,
            ownerColumn: "message_id",
            ownerKeys: Set(snapshot.messages.map(\.id.uuidString)),
            conflict: ValidationError.partConflict, db: db)
        try rejectForeignRows(
            table: "attachments", ids: snapshot.attachments.map(\.id.uuidString),
            ownerColumn: "conversation_id", ownerKey: targetKey,
            conflict: ValidationError.attachmentConflict, db: db)
        try rejectForeignRows(
            table: "runs", ids: snapshot.runs.map(\.id.uuidString),
            ownerColumn: "conversation_id", ownerKey: targetKey,
            conflict: ValidationError.runConflict, db: db)
        try rejectForeignRows(
            table: "run_events", ids: snapshot.events.map(\.id.uuidString),
            ownerColumn: "run_id",
            ownerKeys: Set(snapshot.runs.map(\.id.uuidString)),
            conflict: ValidationError.eventConflict, db: db)
        try rejectForeignRows(
            table: "pending_user_inputs", ids: snapshot.inputs.map(\.id.uuidString),
            ownerColumn: "conversation_id", ownerKey: targetKey,
            conflict: ValidationError.inputConflict, db: db)
    }

    /// Every existing row whose id is in `ids` must be owned by the expected
    /// owner; a row owned by anyone else is a cross-conversation conflict.
    private static func rejectForeignRows(
        table: String,
        ids: [String],
        ownerColumn: String,
        ownerKey: String,
        conflict: (UUID) -> ValidationError,
        db: Database
    ) throws {
        try rejectForeignRows(
            table: table, ids: ids, ownerColumn: ownerColumn,
            ownerKeys: [ownerKey], conflict: conflict, db: db)
    }

    private static func rejectForeignRows(
        table: String,
        ids: [String],
        ownerColumn: String,
        ownerKeys: Set<String>,
        conflict: (UUID) -> ValidationError,
        db: Database
    ) throws {
        for chunk in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[chunk..<min(chunk + 400, ids.count)])
            let placeholders = slice.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, \(ownerColumn) AS owner FROM \(table) WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice)
            )
            for row in rows {
                let owner = row["owner"] as String?
                if owner == nil || !ownerKeys.contains(owner!) {
                    throw conflict(UUID(uuidString: row["id"] as String) ?? UUID())
                }
            }
        }
    }

    /// Commits the snapshot as one unit. Any failure — validation, foreign
    /// key, unique constraint — rolls the whole transaction back: no
    /// conversation row, no message, no FTS entry, no run event.
    ///
    /// Existing entry point: byte-compatible semantics, no fence (every
    /// current caller keeps the original behavior unchanged).
    public func promote(_ snapshot: Snapshot) async throws {
        try await promote(snapshot, commitFence: nil)
    }

    /// One-unit commit under an optional owner-controlled commit fence.
    /// The fence's THREE consultations bracket the ACTUAL transaction
    /// commit (see `PromotionCommitFence`), so a discard is linearized
    /// against the real COMMIT, not against a caller-side boolean or the
    /// body return. `nil` reproduces the original transaction exactly.
    public func promote(_ snapshot: Snapshot,
                        commitFence: (any PromotionCommitFence)?) async throws {
        guard let commitFence else {
            try await commit(snapshot)
            return
        }
        do {
            try await commit(snapshot, commitFence: commitFence)
        } catch {
            // Resolve a started attempt to the truth (the writer threw: the
            // COMMIT never completed). No attempt in flight ⇒ no-op.
            commitFence.finishFinalCommit(committed: false)
            // Normalize the SQLite commit-hook abort into the typed refusal
            // so callers can report "fence refused, zero durable rows".
            if commitFence.commitBoundaryRefused {
                throw PromotionCommitRefused.refused
            }
            throw error
        }
        // The writer await returned normally: ONLY now is the COMMIT a fact.
        commitFence.finishFinalCommit(committed: true)
    }

    private func commit(_ snapshot: Snapshot,
                        commitFence: (any PromotionCommitFence)? = nil) async throws {
        try await database.writer { db in
            // Advisory early consultation: a discard that landed before any
            // write refuses everything cheaply (the AUTHORITATIVE boundary
            // is the commit-hook observer registered below).
            if let commitFence, !commitFence.allowsCommit() {
                throw PromotionCommitRefused.refused
            }
            // The REAL commit-boundary seam: registered on THIS writer
            // connection for exactly this transaction. GRDB calls
            // `databaseWillCommit()` from sqlite3_commit_hook DURING the
            // COMMIT statement; throwing there rolls the whole transaction
            // back (zero durable rows) — this is what linearizes a discard
            // against the actual COMMIT rather than the closure return.
            //
            // `.nextTransaction` (NOT `.observerLifetime`): GRDB holds the
            // observer STRONGLY for this transaction and releases it in
            // databaseDidCommit()/databaseDidRollback() (TransactionObserver
            // .swift:978-988; `.observerLifetime` keeps only a WEAK reference
            // and ARC could drop the authoritative fence before COMMIT).
            if let commitFence {
                db.add(transactionObserver: PromotionCommitBoundaryObserver(fence: commitFence),
                       extent: .nextTransaction)
            }
            try Self.validate(snapshot, db: db)
            let conversation = snapshot.conversation
            let targetKey = conversation.id.uuidString

            // 1. Conversation.
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at, purpose, title_origin)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    targetKey,
                    conversation.title,
                    PersistenceCodec.encode(conversation.createdAt),
                    PersistenceCodec.encode(conversation.updatedAt),
                    conversation.purpose.rawValue,
                    // The promoted title's origin rides the same atomic
                    // transaction: a manual rename stays manual (the ordinary
                    // auto-title will never overwrite it) and an un-titled
                    // promotion stays autoPending for exactly one post-Keep
                    // ordinary title generation.
                    conversation.titleOrigin.rawValue
                ]
            )

            // A saved ordinary chat must be discoverable in the existing
            // history/sidebar projection. Keep any existing project ownership;
            // otherwise create the canonical private-task workspace atomically.
            _ = try SQLiteWorkspaceStore.ensureWorkspace(
                conversationID: conversation.id, title: conversation.title, db: db)

            // 2. Runs before messages: messages.run_id references runs(id),
            // and every event/usage/error references its run.
            for run in snapshot.runs {
                try db.execute(
                    sql: """
                        INSERT INTO runs (
                            id, conversation_id, state, goal, started_at, ended_at, goal_id,
                            provider_id, model_id, provider_name_snapshot, model_name_snapshot,
                            conversation_mode
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            state = excluded.state,
                            goal = excluded.goal,
                            ended_at = excluded.ended_at
                        """,
                    arguments: [
                        run.id.uuidString,
                        run.conversationID.uuidString,
                        run.state,
                        run.goal,
                        PersistenceCodec.encode(run.startedAt),
                        run.endedAt.map(PersistenceCodec.encode),
                        run.goalID?.uuidString,
                        run.providerID?.uuidString,
                        run.modelID?.uuidString,
                        run.providerName,
                        run.modelName,
                        run.conversationMode
                    ]
                )
            }

            // 3. Message rows only — parts come after attachments so both
            // sides of their foreign keys are present.
            for message in snapshot.messages {
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
            }

            // 4. Attachments (their message rows now exist).
            for attachment in snapshot.attachments {
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

            // 5. Message parts (both parents exist).
            for message in snapshot.messages {
                for part in message.parts {
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
            }

            // 6. Run events, usage and errors. ON CONFLICT keeps a repeated
            // promotion of the same snapshot a semantic no-op (idempotent
            // retry), never a duplicate or an error.
            for event in snapshot.events {
                try db.execute(
                    sql: """
                        INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            sequence = excluded.sequence,
                            kind = excluded.kind,
                            payload_json = excluded.payload_json
                        """,
                    arguments: [
                        event.id.uuidString,
                        event.runID.uuidString,
                        event.sequence,
                        event.kind.rawValue,
                        event.payloadJSON,
                        PersistenceCodec.encode(event.createdAt)
                    ]
                )
            }

            for record in snapshot.usage {
                try db.execute(
                    sql: """
                        INSERT INTO run_usage (
                            id, run_id, input_tokens, output_tokens, cost_estimate, recorded_at,
                            cache_read_tokens, cache_write_tokens, reasoning_tokens, is_estimated,
                            total_duration_ms, time_to_first_token_ms, tokens_per_second
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            input_tokens = excluded.input_tokens,
                            output_tokens = excluded.output_tokens,
                            cost_estimate = excluded.cost_estimate,
                            cache_read_tokens = excluded.cache_read_tokens,
                            cache_write_tokens = excluded.cache_write_tokens,
                            reasoning_tokens = excluded.reasoning_tokens,
                            is_estimated = excluded.is_estimated,
                            total_duration_ms = excluded.total_duration_ms,
                            time_to_first_token_ms = excluded.time_to_first_token_ms,
                            tokens_per_second = excluded.tokens_per_second
                        """,
                    arguments: [
                        record.id.uuidString,
                        record.runID.uuidString,
                        record.inputTokens,
                        record.outputTokens,
                        record.costEstimate,
                        PersistenceCodec.encode(record.recordedAt),
                        record.cacheReadTokens,
                        record.cacheWriteTokens,
                        record.reasoningTokens,
                        record.isEstimated,
                        record.totalDurationMs,
                        record.timeToFirstTokenMs,
                        record.tokensPerSecond
                    ]
                )
            }

            for error in snapshot.errors {
                try db.execute(
                    sql: """
                        INSERT INTO run_errors (id, run_id, kind, message, http_status, recoverable, recorded_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            kind = excluded.kind,
                            message = excluded.message,
                            http_status = excluded.http_status,
                            recoverable = excluded.recoverable
                        """,
                    arguments: [
                        error.id.uuidString,
                        error.runID.uuidString,
                        error.kind,
                        error.message,
                        error.httpStatus,
                        error.recoverable,
                        PersistenceCodec.encode(error.recordedAt)
                    ]
                )
            }

            // 7. Queued / steer-pending running inputs. The conversation and
            // every referenced run already exist, so the queue's foreign
            // keys are satisfied inside the same transaction. ON CONFLICT
            // keeps a resumed/repeated promotion idempotent and mirrors the
            // exact watermark state (positions, targets, statuses).
            for input in snapshot.inputs {
                let attachments = try String(
                    decoding: JSONEncoder().encode(input.attachments), as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT INTO pending_user_inputs (
                            id, conversation_id, target_run_id, content, mode, status, position,
                            attachments_json, selected_model_id, workspace_id, execution_mode,
                            consumed_run_id, created_at, updated_at, consumed_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            target_run_id = excluded.target_run_id,
                            content = excluded.content,
                            mode = excluded.mode,
                            status = excluded.status,
                            position = excluded.position,
                            attachments_json = excluded.attachments_json,
                            selected_model_id = excluded.selected_model_id,
                            workspace_id = excluded.workspace_id,
                            execution_mode = excluded.execution_mode,
                            consumed_run_id = excluded.consumed_run_id,
                            updated_at = excluded.updated_at,
                            consumed_at = excluded.consumed_at
                        """,
                    arguments: [
                        input.id.uuidString,
                        input.conversationID.uuidString,
                        input.targetRunID?.uuidString,
                        input.content,
                        input.mode.rawValue,
                        input.status.rawValue,
                        input.position,
                        attachments,
                        input.selectedModelID?.uuidString,
                        input.workspaceID?.uuidString,
                        input.executionMode,
                        input.consumedRunID?.uuidString,
                        PersistenceCodec.encode(input.createdAt),
                        PersistenceCodec.encode(input.updatedAt),
                        input.consumedAt.map(PersistenceCodec.encode)
                    ]
                )
            }

            // Activity touch, once.
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [PersistenceCodec.encode(Date()), targetKey]
            )

            // Advisory final consultation (NOT the boundary): cheap refusal
            // of a discard that already landed mid-body. The authoritative
            // decision is made by the commit-hook observer DURING the real
            // COMMIT — a flip landing after this line but before the
            // COMMIT still rolls the whole transaction back (zero rows).
            if let commitFence, !commitFence.allowsCommit() {
                throw PromotionCommitRefused.refused
            }
        }
    }
}

// FloeAgentRuntime — canonical SQLite run checkpoint store.
//
// `AppEnvironment.checkpointStore` is the runtime recovery authority. Its
// rows live in the same `checkpoints` table that
// `TaskExecutionBindingStore.commit` rewrites inside one SQLite writer
// transaction, so an environment migration and the recovery pin it changes
// become durable together: after commit, a load can never observe the
// pre-migration execution binding.
//
// The filesystem store remains the read-only legacy path. Legacy files are
// never rewritten or deleted, so they stay available as a rollback input and
// as evidence of the exact pre-upgrade bytes. A legacy checkpoint is imported
// at most once, only when the saved run exists, belongs to the checkpoint's
// conversation, and its non-nil pin still matches the run's trusted binding.
// Once a canonical row exists it always wins, so an in-flight legacy load can
// never replace a newer concurrent write.

import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

public actor SQLiteRunCheckpointStore: CheckpointStore {
    private let database: DatabaseManager
    private let legacyDirectory: URL?
    private let logger = FloeLogger(category: .runtime)

    /// `legacyDirectory` is read-only. Nil disables legacy read-through (for
    /// example an environment with no pre-upgrade checkpoint directory).
    public init(database: DatabaseManager, legacyDirectory: URL?) {
        self.database = database
        self.legacyDirectory = legacyDirectory
    }

    // MARK: - CheckpointStore

    /// Persists the canonical checkpoint for `checkpoint.runID`.
    ///
    /// The run identity check, the current `runs.execution_binding_json` read
    /// and the upsert share one SQLite writer transaction. A runtime that
    /// still holds an old environment generation is therefore rejected
    /// instead of overwriting a post-migration recovery point. Canonical
    /// writes must agree with the run: both sides unpinned, or the same
    /// identity/generation/target. A nil checkpoint pin under a trusted run
    /// pin is a late callback from an old environment and is rejected too.
    /// Only the legacy read-through import may adopt a nil legacy pin.
    public func save(_ checkpoint: AgentCheckpoint) async throws {
        let encoded = try checkpoint.encoded()
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT conversation_id, execution_binding_json FROM runs WHERE id = ?",
                arguments: [checkpoint.runID.uuidString]
            ) else {
                throw FloeError.notFound("Task run")
            }
            guard let runConversationID = UUID(uuidString: row["conversation_id"] as String),
                  runConversationID == checkpoint.conversationID else {
                throw FloeError.validationFailed("The checkpoint does not belong to this task")
            }
            let trusted = try Self.decodeBinding(row["execution_binding_json"] as String?)
            try Self.requireCanonicalPin(checkpoint.executionBinding, matches: trusted)
            let now = Self.encodeTimestamp(Date())
            try db.execute(
                sql: """
                    INSERT INTO checkpoints (run_id, conversation_id, format_version, state, body_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO UPDATE SET
                        conversation_id = excluded.conversation_id,
                        format_version = excluded.format_version,
                        state = excluded.state,
                        body_json = excluded.body_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    checkpoint.runID.uuidString,
                    checkpoint.conversationID.uuidString,
                    checkpoint.formatVersion,
                    checkpoint.state.name,
                    encoded,
                    now,
                    now,
                ]
            )
        }
        logger.info(
            "checkpointSaved run=\(checkpoint.runID.uuidString) bytes=\(encoded.count) replayPairs=\(checkpoint.replayedToolPairs?.count ?? 0) state=\(checkpoint.state.name) store=sqlite"
        )
    }

    /// Returns the canonical row first. Only when no row exists does it read
    /// the legacy file and (when safe) import it. Import decisions are
    /// re-evaluated inside the import writer transaction against the current
    /// run binding, so a migration commit that wins the race can never be
    /// overwritten with a stale file.
    public func load(runID: UUID) async throws -> AgentCheckpoint? {
        let initial = try await database.reader { db in
            try Self.readRunAndCanonical(db, runID: runID)
        }
        guard let run = initial.run else { return nil }
        if let canonical = initial.canonical {
            return try Self.validatedCanonical(
                canonical,
                runID: runID,
                runConversationID: run.conversationID,
                trusted: run.binding
            )
        }
        guard let legacyDirectory else { return nil }
        let url = legacyDirectory.appendingPathComponent("\(runID.uuidString).checkpoint.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let legacyData = try Data(floeContentsOf: url)
        let legacy: AgentCheckpoint
        do {
            legacy = try AgentCheckpoint.decoded(from: legacyData)
        } catch let error as FloeError {
            throw error
        } catch {
            throw FloeError.storageCorrupted("The task recovery point is unreadable")
        }
        guard legacy.runID == runID else {
            throw FloeError.storageCorrupted("The task recovery point belongs to another run")
        }
        guard legacy.conversationID == run.conversationID else {
            throw FloeError.validationFailed("The checkpoint does not belong to this task")
        }

        let result = try await database.writer { db -> LegacyImportResult in
            guard let currentRun = try Self.readRun(db, runID: runID) else {
                // The run was deleted while the file was being read. Never
                // create an orphan checkpoint row.
                return LegacyImportResult(checkpoint: nil, imported: false)
            }
            guard currentRun.conversationID == legacy.conversationID else {
                throw FloeError.validationFailed("The checkpoint does not belong to this task")
            }
            // A canonical row written while the file was being read always
            // wins. Return it as-is; the file must not replace it.
            if let canonical = try Self.readCanonical(db, runID: runID) {
                return LegacyImportResult(
                    checkpoint: try Self.validatedCanonical(
                        canonical,
                        runID: runID,
                        runConversationID: currentRun.conversationID,
                        trusted: currentRun.binding
                    ),
                    imported: false
                )
            }
            let body: Data
            if let pin = legacy.executionBinding {
                // A checkpoint written under a previous environment can only
                // be imported while the run still carries that exact identity,
                // generation and target. After a migration commit this fails
                // honestly rather than resurrecting the old environment.
                guard Self.bindingMatches(pin, currentRun.binding) else {
                    throw FloeError.validationFailed(
                        "The saved task environment is unavailable or has changed; reconnect before continuing"
                    )
                }
                body = legacyData
            } else if let trusted = currentRun.binding {
                // Initial upgrade: a legacy checkpoint has no pin. Adopt the
                // run's trusted binding so the canonical row is complete.
                var adopted = legacy
                adopted.executionBinding = trusted
                body = try adopted.encoded()
            } else {
                body = legacyData
            }
            let now = Self.encodeTimestamp(Date())
            try db.execute(
                sql: """
                    INSERT INTO checkpoints (run_id, conversation_id, format_version, state, body_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO NOTHING
                    """,
                arguments: [
                    runID.uuidString,
                    legacy.conversationID.uuidString,
                    legacy.formatVersion,
                    legacy.state.name,
                    body,
                    now,
                    now,
                ]
            )
            let inserted = db.changesCount == 1
            // Return the row that is ACTUALLY stored. If another writer won
            // between the read above and this transaction, that row is the
            // authority; a legacy load never overwrites it.
            guard let canonical = try Self.readCanonical(db, runID: runID) else {
                throw FloeError.storageCorrupted("The task recovery point was not saved")
            }
            return LegacyImportResult(
                checkpoint: try Self.validatedCanonical(
                    canonical,
                    runID: runID,
                    runConversationID: currentRun.conversationID,
                    trusted: currentRun.binding
                ),
                imported: inserted
            )
        }
        if result.imported {
            logger.info("checkpointImported run=\(runID.uuidString) bytes=\(legacyData.count)")
        }
        return result.checkpoint
    }

    // MARK: - Row reads

    private struct RunState: Sendable {
        var conversationID: UUID
        var binding: TaskExecutionBinding?
    }

    private struct CanonicalState: Sendable {
        var storedConversationID: String
        var bodyJSON: String
    }

    private struct RunAndCanonical: Sendable {
        var run: RunState?
        var canonical: CanonicalState?
    }

    private struct LegacyImportResult: Sendable {
        var checkpoint: AgentCheckpoint?
        var imported: Bool
    }

    private static func readRunAndCanonical(_ db: Database, runID: UUID) throws -> RunAndCanonical {
        RunAndCanonical(
            run: try readRun(db, runID: runID),
            canonical: try readCanonical(db, runID: runID)
        )
    }

    private static func readRun(_ db: Database, runID: UUID) throws -> RunState? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT conversation_id, execution_binding_json FROM runs WHERE id = ?",
            arguments: [runID.uuidString]
        ) else { return nil }
        guard let conversationID = UUID(uuidString: row["conversation_id"] as String) else {
            throw FloeError.storageCorrupted("The task run is unreadable")
        }
        return RunState(
            conversationID: conversationID,
            binding: try decodeBinding(row["execution_binding_json"] as String?)
        )
    }

    private static func readCanonical(_ db: Database, runID: UUID) throws -> CanonicalState? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT conversation_id, body_json FROM checkpoints WHERE run_id = ?",
            arguments: [runID.uuidString]
        ) else { return nil }
        return CanonicalState(
            storedConversationID: row["conversation_id"] as String,
            bodyJSON: row["body_json"] as String
        )
    }

    // MARK: - Validation

    /// Canonical rows are trusted storage, but their embedded identity and
    /// pin are still checked against the run row. Canonical rows never adopt
    /// a missing pin: a nil body pin under a trusted run pin can only be a
    /// stale late write, so it fails closed. Adoption belongs exclusively to
    /// the explicit legacy read-through import below.
    private static func validatedCanonical(
        _ canonical: CanonicalState,
        runID: UUID,
        runConversationID: UUID,
        trusted: TaskExecutionBinding?
    ) throws -> AgentCheckpoint {
        let checkpoint: AgentCheckpoint
        do {
            checkpoint = try AgentCheckpoint.decoded(from: Data(canonical.bodyJSON.utf8))
        } catch let error as FloeError {
            throw error
        } catch {
            throw FloeError.storageCorrupted("The task recovery point is unreadable")
        }
        guard checkpoint.runID == runID else {
            throw FloeError.storageCorrupted("The task recovery point belongs to another run")
        }
        guard checkpoint.conversationID == runConversationID,
              UUID(uuidString: canonical.storedConversationID) == runConversationID else {
            throw FloeError.validationFailed("The checkpoint does not belong to this task")
        }
        try requireCanonicalPin(checkpoint.executionBinding, matches: trusted)
        return checkpoint
    }

    /// A canonical checkpoint and its run must agree: both unpinned, or the
    /// same environment identity, generation and target. `updatedAt` is not
    /// part of that agreement.
    private static func requireCanonicalPin(
        _ candidate: TaskExecutionBinding?,
        matches trusted: TaskExecutionBinding?
    ) throws {
        if let candidate {
            guard bindingMatches(candidate, trusted) else {
                throw FloeError.validationFailed(
                    "The saved task environment is unavailable or has changed; reconnect before continuing"
                )
            }
        } else {
            guard trusted == nil else {
                throw FloeError.validationFailed(
                    "The saved task environment is unavailable or has changed; reconnect before continuing"
                )
            }
        }
    }

    /// The binding identity that resume must compare. `updatedAt` is
    /// presentation metadata and is deliberately ignored so a legacy file
    /// written a moment before the trusted row is not rejected solely for its
    /// timestamp.
    private static func bindingMatches(
        _ candidate: TaskExecutionBinding,
        _ trusted: TaskExecutionBinding?
    ) -> Bool {
        guard let trusted else { return false }
        return candidate.conversationID == trusted.conversationID
            && candidate.generation == trusted.generation
            && candidate.target == trusted.target
    }

    private static func decodeBinding(_ json: String?) throws -> TaskExecutionBinding? {
        guard let json else { return nil }
        do {
            return try TaskExecutionBinding.decoded(json)
        } catch {
            throw FloeError.storageCorrupted("The task execution binding is unreadable")
        }
    }

    /// Same ISO-8601 shape as `PersistenceCodec` in FloePersistence, which is
    /// module-internal. These columns are part of the shared schema, so the
    /// text form must stay identical.
    private static func encodeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

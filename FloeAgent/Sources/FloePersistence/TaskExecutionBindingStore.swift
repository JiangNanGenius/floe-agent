import Foundation
import GRDB
import FloeCore
import FloeModels

/// The only commit point for task environment changes. Preparation never changes this row.
///
/// Contract:
///  * `bindInitial` is first-writer-wins; later defaults never replace a task pin.
///  * `pinRun` fills a run's NULL pin once and refuses a conflicting retry.
///  * Every migration write is CAS on `revision`; a stale writer cannot change
///    the identity or regress a committed migration.
///  * `commit` performs the binding switch, exact pre-migration checkpoint
///    snapshots, resumable run pins and checkpoint pins in the same SQLite
///    writer transaction. Any failure rolls all of it back.
///  * `requestCancellation` durably records a user stop before volatile work is
///    cancelled; `commit` refuses once that flag is set.
///  * `finish` records the terminal migration and its timeline notification once.
public struct TaskExecutionBindingStore: Sendable {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    /// Runs in these states can still be resumed or retried. Historical
    /// completed/cancelled runs keep the environment they actually ran in.
    private static let rebindableRunFilter = "state NOT IN ('completed','cancelled')"

    public func binding(conversationID: UUID) async throws -> TaskExecutionBinding? {
        try await database.reader { db in
            try Self.decode(TaskExecutionBinding.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_execution_bindings WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]))
        }
    }

    /// First writer wins. A later default or project setting never changes an existing task.
    public func bindInitial(_ proposed: TaskExecutionBinding) async throws -> TaskExecutionBinding {
        guard proposed.generation > 0, proposed.generation < Int64.max else {
            throw FloeError.validationFailed("The execution binding generation is invalid")
        }
        return try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO task_execution_bindings(conversation_id,generation,body_json)
                VALUES(?,?,?) ON CONFLICT(conversation_id) DO NOTHING
                """, arguments: [proposed.conversationID.uuidString, proposed.generation, try Self.encode(proposed)])
            guard let saved = try Self.decode(TaskExecutionBinding.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_execution_bindings WHERE conversation_id = ?",
                arguments: [proposed.conversationID.uuidString])) else {
                throw FloeError.storageCorrupted("Execution binding was not saved")
            }
            return saved
        }
    }

    /// Bind before the first executable tool. Resume must reuse these exact facts.
    public func pinRun(runID: UUID, binding: TaskExecutionBinding) async throws {
        guard binding.generation > 0 else {
            throw FloeError.validationFailed("The execution binding generation is invalid")
        }
        try await database.writer { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT conversation_id,execution_binding_json FROM runs WHERE id = ?",
                                            arguments: [runID.uuidString]),
                  row["conversation_id"] as String == binding.conversationID.uuidString else {
                throw FloeError.notFound("Task run")
            }
            if let old = try Self.decode(TaskExecutionBinding.self, row["execution_binding_json"] as String?) {
                guard old == binding else { throw FloeError.validationFailed("This run is bound to another execution environment") }
            } else {
                try db.execute(sql: "UPDATE runs SET execution_binding_json = ? WHERE id = ? AND execution_binding_json IS NULL",
                               arguments: [try Self.encode(binding), runID.uuidString])
                guard db.changesCount == 1 else {
                    throw FloeError.validationFailed("This run is bound to another execution environment")
                }
            }
        }
    }

    public func activeMigration(conversationID: UUID) async throws -> TaskEnvironmentMigration? {
        try await database.reader { db in
            try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_environment_migrations WHERE conversation_id = ? AND phase NOT IN ('completed','cancelled')",
                arguments: [conversationID.uuidString]))
        }
    }

    public func begin(_ migration: TaskEnvironmentMigration) async throws {
        guard migration.phase == .checking,
              migration.revision == 1,
              migration.cancellationRequested != true, migration.preparationOutcomeUnknown != true,
              migration.manifestDigest == nil,
              migration.dependencyReceiptDigest == nil,
              migration.skillDigests == nil,
              migration.preparedFileCount == 0,
              migration.preparedBytes == 0,
              migration.failure == nil else {
            throw FloeError.validationFailed("A new migration must start in its initial state")
        }
        try await database.writer { db in
            let current = try Self.decode(TaskExecutionBinding.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_execution_bindings WHERE conversation_id = ?",
                arguments: [migration.source.conversationID.uuidString]))
            guard current == migration.source else { throw FloeError.validationFailed("The task environment changed; check it again") }
            let active = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM task_environment_migrations
                WHERE conversation_id = ? AND phase NOT IN ('completed','cancelled')
                """, arguments: [migration.source.conversationID.uuidString]) ?? 0
            guard active == 0 else { throw FloeError.validationFailed("Another environment change is already in progress") }
            try db.execute(sql: "INSERT INTO task_environment_migrations(id,conversation_id,phase,revision,body_json,updated_at) VALUES(?,?,?,?,?,?)",
                           arguments: [migration.id.uuidString, migration.source.conversationID.uuidString,
                                       migration.phase.rawValue, migration.revision, try Self.encode(migration),
                                       PersistenceCodec.encode(migration.updatedAt)])
        }
    }

    @discardableResult
    public func update(_ value: TaskEnvironmentMigration, expectedRevision: Int64) async throws -> TaskEnvironmentMigration {
        guard expectedRevision > 0, expectedRevision < Int64.max,
              value.revision == expectedRevision else {
            throw FloeError.validationFailed("The migration changed; refresh its status")
        }
        return try await database.writer { db in
            guard let previous = try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_environment_migrations WHERE id=?", arguments: [value.id.uuidString])),
                  previous.source == value.source, previous.target == value.target else {
                throw FloeError.validationFailed("The migration identity or commit state changed")
            }
            // Only `commit` may produce `.committed`; only `finish` may
            // produce `.completed`. A migration that has already committed may
            // still persist a post-commit reconnect failure while remaining
            // committed; it can never regress to a preparation phase.
            guard !previous.phase.isTerminal else {
                throw FloeError.validationFailed("The migration identity or commit state changed")
            }
            if previous.phase == .committed {
                guard value.phase == .committed, expectedRevision < Int64.max - 1 else {
                    throw FloeError.validationFailed("The migration identity or commit state changed")
                }
            } else {
                guard value.phase != .committed, value.phase != .completed else {
                    throw FloeError.validationFailed("The migration identity or commit state changed")
                }
            }
            var next = value
            next.id = previous.id
            next.source = previous.source
            next.target = previous.target
            next.createdAt = previous.createdAt
            if previous.phase == .committed {
                // A committed switch may only record a post-commit failure
                // notice. Its verified evidence and accepted contract stay
                // byte-for-byte what `commit` wrote.
                next.manifestDigest = previous.manifestDigest
                next.dependencyReceiptDigest = previous.dependencyReceiptDigest
                next.skillDigests = previous.skillDigests
                next.preparedFileCount = previous.preparedFileCount
                next.preparedBytes = previous.preparedBytes
                next.acceptedCapabilityLosses = previous.acceptedCapabilityLosses
                next.requiredSkillIDs = previous.requiredSkillIDs
            }
            // A user stop is durable once recorded; a stale caller cannot clear it.
            if previous.cancellationRequested == true || value.cancellationRequested == true {
                next.cancellationRequested = true
            } else {
                next.cancellationRequested = previous.cancellationRequested
            }
            next.preparationOutcomeUnknown = previous.preparationOutcomeUnknown == true || value.preparationOutcomeUnknown == true
                ? true : previous.preparationOutcomeUnknown
            next.revision = expectedRevision + 1
            next.updatedAt = Date()
            if next.phase == .verified {
                guard Self.isSHA256Digest(next.manifestDigest),
                      Self.isSHA256Digest(next.dependencyReceiptDigest) else {
                    throw FloeError.validationFailed("The target has not been verified")
                }
            }
            try db.execute(sql: """
                UPDATE task_environment_migrations
                SET phase=?,revision=?,body_json=?,updated_at=?
                WHERE id=? AND revision=? AND phase NOT IN ('completed','cancelled')
                """, arguments: [next.phase.rawValue, next.revision, try Self.encode(next),
                                  PersistenceCodec.encode(next.updatedAt), next.id.uuidString, expectedRevision])
            guard db.changesCount == 1 else { throw FloeError.validationFailed("The migration changed; refresh its status") }
            return next
        }
    }

    /// A transport close does not prove that native target preparation ended.
    /// Only the migration targeting this exact environment may own this flag.
    public func recordPreparationOutcomeUnknown(conversationID: UUID, targetEnvironmentID: String) async throws {
        try await database.writer { db in
            guard var value = try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_environment_migrations WHERE conversation_id=? AND phase NOT IN ('completed','cancelled','committed')",
                arguments: [conversationID.uuidString])), value.target.environmentID == targetEnvironmentID else { return }
            if value.preparationOutcomeUnknown == true { return }
            guard value.revision < Int64.max else { throw FloeError.validationFailed("The migration cannot record another state change") }
            value.preparationOutcomeUnknown = true; value.revision += 1; value.updatedAt = Date()
            try db.execute(sql: "UPDATE task_environment_migrations SET revision=?,body_json=?,updated_at=? WHERE id=?",
                arguments: [value.revision, try Self.encode(value), PersistenceCodec.encode(value.updatedAt), value.id.uuidString])
        }
    }

    /// Durably records an explicit user stop. The volatile cancellation token
    /// may die with the process; this flag must not. A committed migration is
    /// returned unchanged (the switch already happened), and terminal rows are
    /// not active so the caller receives nil.
    public func requestCancellation(conversationID: UUID) async throws -> TaskEnvironmentMigration? {
        try await database.writer { db in
            guard let saved = try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: """
                    SELECT body_json FROM task_environment_migrations
                    WHERE conversation_id = ? AND phase NOT IN ('completed','cancelled')
                    """, arguments: [conversationID.uuidString])) else {
                return nil
            }
            if saved.phase.isCommitted || saved.cancellationRequested == true { return saved }
            guard saved.revision < Int64.max else {
                throw FloeError.validationFailed("The migration cannot record another state change")
            }
            var next = saved
            next.cancellationRequested = true
            next.revision = saved.revision + 1
            next.updatedAt = Date()
            try db.execute(sql: """
                UPDATE task_environment_migrations
                SET revision=?,body_json=?,updated_at=?
                WHERE id=? AND revision=? AND phase NOT IN ('completed','cancelled','committed')
                """, arguments: [next.revision, try Self.encode(next), PersistenceCodec.encode(next.updatedAt),
                                  next.id.uuidString, saved.revision])
            guard db.changesCount == 1 else { throw FloeError.validationFailed("The migration changed; refresh its status") }
            return next
        }
    }

    /// One SQLite transaction commits both the binding and its receipt. The staged target is already verified.
    public func commit(_ value: TaskEnvironmentMigration) async throws -> TaskEnvironmentMigration {
        try await database.writer { db in
            guard var saved = try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_environment_migrations WHERE id=?", arguments: [value.id.uuidString])) else {
                throw FloeError.notFound("Migration")
            }
            if saved.phase.isCommitted { return saved }
            guard saved.phase == .verified, saved.revision == value.revision, saved.preparationOutcomeUnknown != true,
                  Self.isSHA256Digest(saved.manifestDigest),
                  Self.isSHA256Digest(saved.dependencyReceiptDigest) else {
                throw FloeError.validationFailed("The target has not been verified")
            }
            guard saved.cancellationRequested != true else {
                throw FloeError.validationFailed("Cancellation was requested; nothing was switched")
            }
            // Leave one revision for `finish`; never trap on Int64 overflow.
            guard saved.revision < Int64.max - 1,
                  saved.source.generation > 0,
                  saved.source.generation < Int64.max else {
                throw FloeError.validationFailed("The migration can no longer advance")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id,rewritten_digest FROM skills WHERE status='enabled'")
            let actualSkills = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as String, row["rewritten_digest"] as String)
            })
            guard let expectedSkills = saved.skillDigests, expectedSkills == actualSkills else {
                throw FloeError.validationFailed("Installed skills changed during preparation; check them again")
            }
            let current = try Self.decode(TaskExecutionBinding.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_execution_bindings WHERE conversation_id=?",
                arguments: [saved.source.conversationID.uuidString]))
            guard current == saved.source else { throw FloeError.validationFailed("The source environment changed; nothing was switched") }
            let binding = TaskExecutionBinding(conversationID: saved.source.conversationID, target: saved.target,
                                               generation: saved.source.generation + 1)
            let bindingJSON = try Self.encode(binding)
            try db.execute(sql: "UPDATE task_execution_bindings SET generation=?,body_json=? WHERE conversation_id=? AND generation=?",
                           arguments: [binding.generation, bindingJSON, binding.conversationID.uuidString, saved.source.generation])
            guard db.changesCount == 1 else { throw FloeError.validationFailed("The source environment changed") }
            // Current owners have been joined by the coordinator. Historical completed
            // and cancelled runs keep their original identity.
            try db.execute(sql: "UPDATE runs SET execution_binding_json=? WHERE conversation_id=? AND \(Self.rebindableRunFilter)",
                           arguments: [bindingJSON, binding.conversationID.uuidString])
            // Checkpoints are JSON envelopes owned by the same DB transaction. Preserve every other value.
            for row in try Row.fetchAll(db, sql: """
                SELECT c.run_id,c.body_json FROM checkpoints c JOIN runs r ON r.id=c.run_id
                WHERE r.conversation_id=? AND r.\(Self.rebindableRunFilter)
                """, arguments: [binding.conversationID.uuidString]) {
                let body: String = row["body_json"]
                // Keep the exact pre-migration recovery body as evidence in
                // the same transaction. A retry cannot overwrite the first
                // captured snapshot; a failed commit rolls this row back too.
                try db.execute(sql: """
                    INSERT INTO task_environment_migration_checkpoints(migration_id,run_id,body_json)
                    VALUES(?,?,?) ON CONFLICT(migration_id,run_id) DO NOTHING
                    """, arguments: [saved.id.uuidString, row["run_id"] as String, body])
                let parsed: Any
                do { parsed = try JSONSerialization.jsonObject(with: Data(body.utf8)) }
                catch { throw FloeError.storageCorrupted("The task recovery point is unreadable") }
                guard var object = parsed as? [String: Any] else {
                    throw FloeError.storageCorrupted("The task recovery point is unreadable")
                }
                let pin: Any
                do { pin = try JSONSerialization.jsonObject(with: Data(bindingJSON.utf8)) }
                catch { throw FloeError.storageCorrupted("The execution binding is unreadable") }
                object["executionBinding"] = pin
                let updated = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
                try db.execute(sql: "UPDATE checkpoints SET body_json=? WHERE run_id=?", arguments: [updated, row["run_id"] as String])
            }
            saved.phase = .committed; saved.revision += 1; saved.updatedAt = Date(); saved.failure = nil
            try db.execute(sql: "UPDATE task_environment_migrations SET phase=?,revision=?,body_json=?,updated_at=? WHERE id=?",
                           arguments: [saved.phase.rawValue, saved.revision, try Self.encode(saved),
                                       PersistenceCodec.encode(saved.updatedAt), saved.id.uuidString])
            return saved
        }
    }

    /// The completion notice and terminal receipt cannot be separated by process death.
    public func finish(_ value: TaskEnvironmentMigration, notice: String) async throws -> TaskEnvironmentMigration {
        try await database.writer { db in
            guard var saved = try Self.decode(TaskEnvironmentMigration.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_environment_migrations WHERE id=?", arguments: [value.id.uuidString])) else {
                throw FloeError.notFound("Migration")
            }
            if saved.phase == .completed { return saved }
            guard saved.phase == .committed, saved.revision == value.revision,
                  saved.revision < Int64.max else {
                throw FloeError.validationFailed("The migration has not committed")
            }
            guard saved.source.generation < Int64.max else {
                throw FloeError.validationFailed("The migration can no longer advance")
            }
            let current = try Self.decode(TaskExecutionBinding.self, String.fetchOne(db,
                sql: "SELECT body_json FROM task_execution_bindings WHERE conversation_id=?",
                arguments: [saved.source.conversationID.uuidString]))
            guard current?.target == saved.target,
                  current?.generation == saved.source.generation + 1 else {
                throw FloeError.validationFailed("The committed environment no longer matches this migration")
            }
            saved.phase = .completed; saved.failure = nil; saved.revision += 1; saved.updatedAt = Date()
            try db.execute(sql: "UPDATE task_environment_migrations SET phase=?,revision=?,body_json=?,updated_at=? WHERE id=?",
                           arguments: [saved.phase.rawValue, saved.revision, try Self.encode(saved),
                                       PersistenceCodec.encode(saved.updatedAt), saved.id.uuidString])
            // The migration id is the exact-once timeline identity. A retry after
            // commit (or a second concurrent finish) cannot create a second notice.
            if let existing = try Row.fetchOne(db, sql: "SELECT conversation_id,content FROM messages WHERE id=?",
                                               arguments: [saved.id.uuidString]) {
                guard existing["conversation_id"] as String == saved.source.conversationID.uuidString,
                      existing["content"] as String == notice else {
                    throw FloeError.validationFailed("The migration notice conflicts with an existing message")
                }
            } else {
                try db.execute(sql: "INSERT INTO messages(id,conversation_id,role,content,created_at,run_id) VALUES(?,?,'assistant',?,?,NULL)",
                               arguments: [saved.id.uuidString, saved.source.conversationID.uuidString, notice,
                                           PersistenceCodec.encode(saved.updatedAt)])
            }
            try db.execute(sql: "UPDATE conversations SET updated_at=? WHERE id=?",
                           arguments: [PersistenceCodec.encode(saved.updatedAt), saved.source.conversationID.uuidString])
            return saved
        }
    }

    private static func isSHA256Digest(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: String?) throws -> T? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try value.map { try decoder.decode(type, from: Data($0.utf8)) }
    }
}

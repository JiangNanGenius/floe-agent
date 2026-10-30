// FloePersistenceTests — v58 task execution binding and migration ledger.
//
// These tests exercise the real migrated SQLite schema and the public store /
// RunStore APIs. They cover the contracts the App depends on:
//  * first-writer-wins task pins and immutable run pins;
//  * precommit cancellation is durable and cannot be overwritten by a stale
//    writer; a committed switch cannot be "cancelled";
//  * begin/update are CAS on revision and cannot mint a committed/completed
//    phase outside `commit`/`finish`;
//  * commit requires verified manifest + dependency receipts and an unchanged
//    enabled-Skill digest inventory;
//  * binding generation, resumable run pins, checkpoint pins and the migration
//    receipt commit in one SQLite transaction (a malformed checkpoint rolls
//    every earlier write back);
//  * terminal finish inserts its timeline notice exactly once;
//  * Int64 revision/generation overflow fails closed instead of trapping.

import Foundation
import GRDB
import FloeCore
import FloeModels
import Testing
@testable import FloePersistence

@Suite("v58 task execution binding store")
struct TaskExecutionBindingStoreTests: Sendable {
    private static let baseDate = Date(timeIntervalSince1970: 1_761_400_000)

    // MARK: - Fixtures

    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeTarget(_ environmentID: String = "remote-a", root: String? = nil) -> TaskExecutionTarget {
        TaskExecutionTarget(
            environmentID: environmentID,
            backend: .remoteSSH,
            remoteHostID: UUID(),
            remoteRootPath: root ?? "/home/floe/.floe/tasks/\(environmentID)",
            operatingSystem: "linux",
            architecture: "arm64",
            runtimeGeneration: "boot-1"
        )
    }

    private func makeBinding(_ conversationID: UUID, target: TaskExecutionTarget,
                             generation: Int64 = 1) -> TaskExecutionBinding {
        TaskExecutionBinding(conversationID: conversationID, target: target,
                             generation: generation, updatedAt: Self.baseDate)
    }

    private func insertConversation(_ database: DatabaseManager, id: UUID) async throws {
        let now = iso(Self.baseDate)
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO conversations(id,title,created_at,updated_at) VALUES(?,'Task',?,?)",
                           arguments: [id.uuidString, now, now])
        }
    }

    private func insertBinding(_ database: DatabaseManager, _ binding: TaskExecutionBinding) async throws {
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO task_execution_bindings(conversation_id,generation,body_json) VALUES(?,?,?)",
                           arguments: [binding.conversationID.uuidString, binding.generation, try binding.encoded()])
        }
    }

    private func insertRun(_ database: DatabaseManager, id: UUID, conversationID: UUID,
                           state: String, binding: TaskExecutionBinding?) async throws {
        let json = try binding.map { try $0.encoded() }
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO runs(id,conversation_id,state,goal,started_at,ended_at,execution_binding_json)
                VALUES(?,?,?,?,?,NULL,?)
                """, arguments: [id.uuidString, conversationID.uuidString, state, "Task", iso(Self.baseDate), json])
        }
    }

    private func insertCheckpoint(_ database: DatabaseManager, runID: UUID, conversationID: UUID,
                                  body: String) async throws {
        let now = iso(Self.baseDate)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO checkpoints(run_id,conversation_id,format_version,state,body_json,created_at,updated_at)
                VALUES(?,?,1,'checkpointed',?,?,?)
                """, arguments: [runID.uuidString, conversationID.uuidString, body, now, now])
        }
    }

    private func insertSkill(_ database: DatabaseManager, id: String, digest: String) async throws {
        let now = iso(Self.baseDate)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO skills(id,name,version,status,skill_markdown,manifest_json,rewritten_digest,created_at,updated_at)
                VALUES(?,?,'1.0','enabled','','{}',?,?,?)
                """, arguments: [id, id, digest, now, now])
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decodeMigration(_ json: String) throws -> TaskEnvironmentMigration {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TaskEnvironmentMigration.self, from: Data(json.utf8))
    }

    private func rawMigration(_ database: DatabaseManager, id: UUID) async throws -> TaskEnvironmentMigration? {
        try await database.reader { db in
            guard let body = try String.fetchOne(db, sql: "SELECT body_json FROM task_environment_migrations WHERE id=?",
                                                arguments: [id.uuidString]) else { return nil }
            return try decodeMigration(body)
        }
    }

    private func setMigrationRevision(_ database: DatabaseManager, _ migration: TaskEnvironmentMigration,
                                      revision: Int64) async throws {
        var copy = migration
        copy.revision = revision
        let body = try encode(copy)
        let id = copy.id.uuidString
        try await database.writer { db in
            try db.execute(sql: "UPDATE task_environment_migrations SET revision=?,body_json=? WHERE id=?",
                           arguments: [revision, body, id])
        }
    }

    private func checkpointBinding(_ body: String) throws -> TaskExecutionBinding? {
        guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let pin = object["executionBinding"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: pin)
        return try TaskExecutionBinding.decoded(String(decoding: data, as: UTF8.self))
    }

    private func checkpointPayload(_ body: String) throws -> [String: Any]? {
        guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        return object["payload"] as? [String: Any]
    }

    private struct MessageSnapshot: Sendable {
        var id: String
        var conversationID: String
        var role: String
        var content: String
        var createdAt: String
        var runID: String?
    }

    private func messageRows(_ database: DatabaseManager, conversationID: UUID) async throws -> [MessageSnapshot] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT id,conversation_id,role,content,created_at,run_id
                FROM messages WHERE conversation_id=? ORDER BY created_at,id
                """, arguments: [conversationID.uuidString]).map { row in
                MessageSnapshot(
                    id: row["id"] as String,
                    conversationID: row["conversation_id"] as String,
                    role: row["role"] as String,
                    content: row["content"] as String,
                    createdAt: row["created_at"] as String,
                    runID: row["run_id"] as String?
                )
            }
        }
    }

    private func migrationCheckpointSnapshots(_ database: DatabaseManager,
                                              migrationID: UUID) async throws -> [UUID: String] {
        try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT run_id,body_json FROM task_environment_migration_checkpoints
                WHERE migration_id=?
                """, arguments: [migrationID.uuidString])
            var result: [UUID: String] = [:]
            for row in rows {
                guard let runID = UUID(uuidString: row["run_id"]) else {
                    throw FloeError.storageCorrupted("Invalid migration checkpoint snapshot")
                }
                result[runID] = row["body_json"]
            }
            return result
        }
    }

    private func prepareVerifiedMigration(
        _ database: DatabaseManager,
        conversationID: UUID,
        source: TaskExecutionBinding,
        target: TaskExecutionTarget,
        skillDigests: [String: String]?
    ) async throws -> (TaskExecutionBindingStore, TaskEnvironmentMigration) {
        let store = TaskExecutionBindingStore(database: database)
        var migration = TaskEnvironmentMigration(source: source, target: target)
        try await store.begin(migration)
        migration.phase = .verified
        migration.manifestDigest = String(repeating: "a", count: 64)
        migration.dependencyReceiptDigest = String(repeating: "b", count: 64)
        migration.skillDigests = skillDigests
        migration.preparedFileCount = 2
        migration.preparedBytes = 12
        migration = try await store.update(migration, expectedRevision: migration.revision)
        return (store, migration)
    }

    // MARK: - First writer / run pin

    @Test("bindInitial is first-writer-wins and a later default never replaces the task pin")
    func firstWriterWins() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let targetA = makeTarget("remote-a")
        let targetB = makeTarget("remote-b")

        let first = try await store.bindInitial(makeBinding(conversation, target: targetA))
        #expect(first.target == targetA)
        #expect(first.generation == 1)

        let later = try await store.bindInitial(makeBinding(conversation, target: targetB))
        #expect(later == first)
        #expect(later.target == targetA)
        #expect(try await store.binding(conversationID: conversation)?.target == targetA)
    }

    @Test("pinRun fills NULL exactly once, is idempotent, and refuses a conflicting or foreign run")
    func runPinIsImmutable() async throws {
        let database = try await makeDatabase()
        let conversation = UUID(), otherConversation = UUID()
        try await insertConversation(database, id: conversation)
        try await insertConversation(database, id: otherConversation)
        let store = TaskExecutionBindingStore(database: database)
        let binding = makeBinding(conversation, target: makeTarget("remote-a"))
        let otherBinding = makeBinding(conversation, target: makeTarget("remote-b"))
        let runID = UUID(), foreignRunID = UUID()
        try await insertRun(database, id: runID, conversationID: conversation, state: "running", binding: nil)
        try await insertRun(database, id: foreignRunID, conversationID: otherConversation, state: "running", binding: nil)

        try await store.pinRun(runID: runID, binding: binding)
        try await store.pinRun(runID: runID, binding: binding)
        let runStore = SQLiteRunStore(database: database)
        #expect(try await runStore.run(id: runID)?.executionBinding == binding)

        await #expect(throws: FloeError.self) {
            try await store.pinRun(runID: runID, binding: otherBinding)
        }
        #expect(try await runStore.run(id: runID)?.executionBinding == binding)

        await #expect(throws: FloeError.self) {
            try await store.pinRun(runID: foreignRunID, binding: binding)
        }
        await #expect(throws: FloeError.self) {
            try await store.pinRun(runID: UUID(), binding: binding)
        }
    }

    @Test("bindInitial refuses an overflowing generation instead of later trapping")
    func bindRejectsOverflowGeneration() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let overflow = makeBinding(conversation, target: makeTarget(), generation: Int64.max)
        await #expect(throws: FloeError.self) {
            _ = try await store.bindInitial(overflow)
        }
        #expect(try await store.binding(conversationID: conversation) == nil)
    }

    // MARK: - Ledger CAS

    @Test("begin is source-CAS, at most one active ledger, and new ledgers must be initial")
    func beginCASAndUniqueness() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let first = TaskEnvironmentMigration(source: source, target: makeTarget("remote-b"))
        try await store.begin(first)
        #expect(try await store.activeMigration(conversationID: conversation)?.id == first.id)

        let second = TaskEnvironmentMigration(source: source, target: makeTarget("remote-c"))
        await #expect(throws: FloeError.self) {
            try await store.begin(second)
        }
        #expect(try await store.activeMigration(conversationID: conversation)?.id == first.id)

        let missingConversation = UUID()
        try await insertConversation(database, id: missingConversation)
        await #expect(throws: FloeError.self) {
            try await store.begin(TaskEnvironmentMigration(
                source: makeBinding(missingConversation, target: makeTarget("remote-x")),
                target: makeTarget("remote-y")))
        }

        var committedStart = TaskEnvironmentMigration(source: source, target: makeTarget("remote-d"))
        committedStart.phase = .committed
        await #expect(throws: FloeError.self) {
            try await store.begin(committedStart)
        }
    }

    @Test("update is revision-CAS, cannot change identity, and cannot mint committed/completed phases")
    func updateCASAndIdentity() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        var migration = TaskEnvironmentMigration(source: source, target: makeTarget("remote-b"))
        try await store.begin(migration)
        // Compare against the actual durable timestamp, not a Date's extra
        // sub-millisecond precision lost by the JSON milliseconds round trip.
        migration = try #require(try await store.activeMigration(conversationID: conversation))


        var waiting = migration
        waiting.phase = .waiting
        waiting = try await store.update(waiting, expectedRevision: waiting.revision)
        #expect(waiting.revision == 2)
        #expect(try await store.activeMigration(conversationID: conversation)?.phase == .waiting)

        // A stale object at the old revision cannot overwrite the newer row.
        var stale = migration
        stale.phase = .preparing
        await #expect(throws: FloeError.self) {
            _ = try await store.update(stale, expectedRevision: stale.revision)
        }
        #expect(try await store.activeMigration(conversationID: conversation)?.phase == .waiting)

        var changedTarget = waiting
        changedTarget.phase = .preparing
        changedTarget.target = makeTarget("remote-c")
        await #expect(throws: FloeError.self) {
            _ = try await store.update(changedTarget, expectedRevision: waiting.revision)
        }

        var changedSource = waiting
        changedSource.phase = .preparing
        changedSource.source.generation = 99
        await #expect(throws: FloeError.self) {
            _ = try await store.update(changedSource, expectedRevision: waiting.revision)
        }

        var bypassCommit = waiting
        bypassCommit.phase = .committed
        await #expect(throws: FloeError.self) {
            _ = try await store.update(bypassCommit, expectedRevision: waiting.revision)
        }
        var bypassFinish = waiting
        bypassFinish.phase = .completed
        await #expect(throws: FloeError.self) {
            _ = try await store.update(bypassFinish, expectedRevision: waiting.revision)
        }

        var renamed = waiting
        renamed.phase = .preparing
        renamed.createdAt = Self.baseDate.addingTimeInterval(999)
        let saved = try await store.update(renamed, expectedRevision: waiting.revision)
        #expect(saved.createdAt == migration.createdAt)
        #expect(saved.revision == 3)
        #expect(try await store.activeMigration(conversationID: conversation)?.createdAt == migration.createdAt)
    }

    @Test("requestCancellation is durable, idempotent, sticky, and cannot cancel a committed switch")
    func cancellationIsDurable() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        var migration = TaskEnvironmentMigration(source: source, target: makeTarget("remote-b"))
        try await store.begin(migration)
        migration.phase = .verified
        migration.manifestDigest = String(repeating: "a", count: 64)
        migration.dependencyReceiptDigest = String(repeating: "b", count: 64)
        migration.skillDigests = [:]
        migration = try await store.update(migration, expectedRevision: migration.revision)

        let cancelled = try await store.requestCancellation(conversationID: conversation)
        #expect(cancelled?.cancellationRequested == true)
        #expect(cancelled?.revision == 3)

        // A new store instance reads the same durable stop.
        let reopened = TaskExecutionBindingStore(database: database)
        let readBack = try await reopened.activeMigration(conversationID: conversation)
        #expect(readBack?.cancellationRequested == true)
        #expect(readBack?.revision == 3)

        let again = try await reopened.requestCancellation(conversationID: conversation)
        #expect(again?.revision == 3)
        #expect(again?.cancellationRequested == true)

        let durableStop = try #require(readBack)
        // Cancellation wins before the commit transaction, even though the
        // staged evidence is otherwise complete.
        await #expect(throws: FloeError.self) {
            _ = try await reopened.commit(durableStop)
        }
        #expect(try await store.binding(conversationID: conversation)?.generation == 1)

        // A stale caller that never saw the flag cannot clear it.
        var stale = durableStop
        stale.cancellationRequested = nil
        stale.phase = .waiting
        let preserved = try await reopened.update(stale, expectedRevision: stale.revision)
        #expect(preserved.cancellationRequested == true)
        #expect(preserved.revision == 4)

        // The service records the terminal cancellation after cleanup; that
        // row is no longer active, and a new migration may begin.
        var cancelledState = preserved
        cancelledState.phase = .cancelled
        let markedCancelled = try await reopened.update(cancelledState, expectedRevision: preserved.revision)
        #expect(markedCancelled.phase == .cancelled)
        #expect(try await reopened.activeMigration(conversationID: conversation) == nil)
        let another = TaskEnvironmentMigration(source: source, target: makeTarget("remote-e"))
        try await reopened.begin(another)
        #expect(try await reopened.activeMigration(conversationID: conversation)?.id == another.id)

        // A committed migration is returned unchanged and is never marked cancelled.
        let freshConversation = UUID()
        try await insertConversation(database, id: freshConversation)
        let freshSource = try await store.bindInitial(makeBinding(freshConversation, target: makeTarget("remote-c")))
        let (freshStore, verified) = try await prepareVerifiedMigration(
            database, conversationID: freshConversation, source: freshSource,
            target: makeTarget("remote-d"), skillDigests: [:])
        let committed = try await freshStore.commit(verified)
        let committedCancel = try await freshStore.requestCancellation(conversationID: freshConversation)
        #expect(committedCancel?.phase == .committed)
        #expect(committedCancel?.cancellationRequested != true)
        #expect(committedCancel?.revision == committed.revision)
        let completed = try await freshStore.finish(committed, notice: "Moved")
        #expect(completed.phase == .completed)
        #expect(try await freshStore.requestCancellation(conversationID: freshConversation) == nil)
    }

    // MARK: - Commit transaction

    @Test("commit switches the binding, resumable run pins, checkpoints and receipt atomically")
    func commitIsOneTransaction() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let skillID = "skill-a", skillDigest = String(repeating: "c", count: 64)
        try await insertSkill(database, id: skillID, digest: skillDigest)

        let states = [("running", true), ("checkpointed", true), ("failed", true),
                      ("interrupted", true), ("completed", false), ("cancelled", false)]
        var runs: [(String, UUID, Bool)] = []
        var originalBodies: [UUID: String] = [:]
        for (state, rebindable) in states {
            let runID = UUID()
            try await insertRun(database, id: runID, conversationID: conversation, state: state, binding: source)
            let body = """
                {"runID":"\(runID.uuidString)","executionBinding":\(try source.encoded()),"payload":{"value":7},"note":"keep"}
                """
            try await insertCheckpoint(database, runID: runID, conversationID: conversation, body: body)
            originalBodies[runID] = body
            runs.append((state, runID, rebindable))
        }

        let (store2, verified) = try await prepareVerifiedMigration(
            database, conversationID: conversation, source: source,
            target: makeTarget("remote-b"), skillDigests: [skillID: skillDigest])
        let committed = try await store2.commit(verified)
        #expect(committed.phase == .committed)
        #expect(committed.revision == 3)

        let binding = try await store2.binding(conversationID: conversation)
        #expect(binding?.target.environmentID == "remote-b")
        #expect(binding?.generation == 2)

        let runStore = SQLiteRunStore(database: database)
        for (state, runID, rebindable) in runs {
            let run = try await runStore.run(id: runID)
            if rebindable {
                #expect(run?.executionBinding?.target.environmentID == "remote-b")
                #expect(run?.executionBinding?.generation == 2)
                let body = try #require(try await runStore.checkpointBody(runID: runID))
                let checkpointPin = try checkpointBinding(body)
                #expect(checkpointPin?.target.environmentID == "remote-b")
                let payload = try checkpointPayload(body)
                #expect((payload?["value"] as? Int) == 7)
                let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
                #expect(object["note"] as? String == "keep")
            } else {
                #expect(run?.executionBinding == source)
                let body = try #require(try await runStore.checkpointBody(runID: runID))
                #expect(try checkpointBinding(body) == source)
            }
        }

        // The exact pre-migration recovery body is retained for every
        // resumable run in the same transaction; completed/cancelled runs are
        // not rewritten and therefore have no snapshot.
        let snapshots = try await migrationCheckpointSnapshots(database, migrationID: committed.id)
        #expect(snapshots.count == runs.filter { $0.2 }.count)
        for (_, runID, rebindable) in runs {
            if rebindable {
                #expect(snapshots[runID] == originalBodies[runID])
            } else {
                #expect(snapshots[runID] == nil)
            }
        }

        // Idempotent second commit does not advance the generation again.
        let again = try await store2.commit(verified)
        #expect(again.phase == .committed)
        #expect(again.revision == committed.revision)
        #expect(try await store2.binding(conversationID: conversation)?.generation == 2)
    }

    @Test("a malformed checkpoint rolls the earlier binding/run writes back")
    func malformedCheckpointRollsBack() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let runID = UUID()
        try await insertRun(database, id: runID, conversationID: conversation, state: "running", binding: source)
        try await insertCheckpoint(database, runID: runID, conversationID: conversation, body: "[1,2]")
        let (store2, verified) = try await prepareVerifiedMigration(
            database, conversationID: conversation, source: source,
            target: makeTarget("remote-b"), skillDigests: [:])

        do {
            _ = try await store2.commit(verified)
            Issue.record("commit must fail when a resumable checkpoint is not a JSON object")
        } catch let error as FloeError {
            guard case .storageCorrupted = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }

        #expect(try await store2.binding(conversationID: conversation)?.generation == 1)
        #expect(try await SQLiteRunStore(database: database).run(id: runID)?.executionBinding == source)
        #expect(try await SQLiteRunStore(database: database).checkpointBody(runID: runID) == "[1,2]")
        #expect(try await migrationCheckpointSnapshots(database, migrationID: verified.id).isEmpty)
        let row = try await rawMigration(database, id: verified.id)
        #expect(row?.phase == .verified)
        #expect(row?.revision == verified.revision)
    }

    @Test("commit requires verified manifest/dependency evidence and the exact enabled-Skill inventory")
    func commitRequiresEvidenceAndSkillCAS() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let runID = UUID()
        try await insertRun(database, id: runID, conversationID: conversation, state: "running", binding: source)
        let skillID = "skill-cas", originalDigest = String(repeating: "d", count: 64)
        let changedDigest = String(repeating: "e", count: 64)
        try await insertSkill(database, id: skillID, digest: originalDigest)

        // A verified phase without proof is rejected at the ledger boundary.
        var migration = TaskEnvironmentMigration(source: source, target: makeTarget("remote-b"))
        try await store.begin(migration)
        var unverified = migration
        unverified.phase = .verified
        await #expect(throws: FloeError.self) {
            _ = try await store.update(unverified, expectedRevision: unverified.revision)
        }
        var preparing = migration
        preparing.phase = .verifying
        preparing = try await store.update(preparing, expectedRevision: preparing.revision)
        await #expect(throws: FloeError.self) {
            _ = try await store.commit(preparing)
        }

        // A verified phase without the enabled-Skill inventory is incomplete.
        preparing.phase = .verified
        preparing.manifestDigest = String(repeating: "a", count: 64)
        preparing.dependencyReceiptDigest = String(repeating: "b", count: 64)
        preparing.skillDigests = nil
        preparing = try await store.update(preparing, expectedRevision: preparing.revision)
        await #expect(throws: FloeError.self) {
            _ = try await store.commit(preparing)
        }

        // Skill inventory CAS: changing an enabled digest after verification
        // must abort before the binding is switched.
        preparing.skillDigests = [skillID: originalDigest]
        preparing = try await store.update(preparing, expectedRevision: preparing.revision)
        try await database.writer { db in
            try db.execute(sql: "UPDATE skills SET rewritten_digest=? WHERE id=?", arguments: [changedDigest, skillID])
        }
        await #expect(throws: FloeError.self) {
            _ = try await store.commit(preparing)
        }
        #expect(try await store.binding(conversationID: conversation)?.generation == 1)
        #expect(try await SQLiteRunStore(database: database).run(id: runID)?.executionBinding == source)

        try await database.writer { db in
            try db.execute(sql: "UPDATE skills SET rewritten_digest=? WHERE id=?", arguments: [originalDigest, skillID])
        }
        let committed = try await store.commit(preparing)
        #expect(committed.phase == .committed)
        #expect(try await store.binding(conversationID: conversation)?.generation == 2)
    }

    @Test("generation overflow and revision overflow fail closed without a binding switch")
    func overflowFailsClosed() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let overflowSource = makeBinding(conversation, target: makeTarget("remote-a"), generation: Int64.max)
        try await insertBinding(database, overflowSource)
        var migration = TaskEnvironmentMigration(source: overflowSource, target: makeTarget("remote-b"))
        try await store.begin(migration)
        migration.phase = .verified
        migration.manifestDigest = String(repeating: "a", count: 64)
        migration.dependencyReceiptDigest = String(repeating: "b", count: 64)
        migration.skillDigests = [:]
        migration = try await store.update(migration, expectedRevision: migration.revision)
        await #expect(throws: FloeError.self) {
            _ = try await store.commit(migration)
        }
        #expect(try await store.binding(conversationID: conversation)?.generation == Int64.max)

        let otherConversation = UUID()
        try await insertConversation(database, id: otherConversation)
        let otherSource = try await store.bindInitial(makeBinding(otherConversation, target: makeTarget("remote-c")))
        let other = TaskEnvironmentMigration(source: otherSource, target: makeTarget("remote-d"))
        try await store.begin(other)
        try await setMigrationRevision(database, other, revision: Int64.max)
        let overflowRow = try await rawMigration(database, id: other.id)
        let overflow = try #require(overflowRow)
        await #expect(throws: FloeError.self) {
            _ = try await store.update(overflow, expectedRevision: Int64.max)
        }
        await #expect(throws: FloeError.self) {
            _ = try await store.requestCancellation(conversationID: otherConversation)
        }
        #expect(try await rawMigration(database, id: other.id)?.revision == Int64.max)
    }

    @Test("a post-commit reconnect failure stays committed and can still finish")
    func postCommitFailureStaysCommitted() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let (migrationStore, verified) = try await prepareVerifiedMigration(
            database, conversationID: conversation, source: source,
            target: makeTarget("remote-b"), skillDigests: [:])
        let committed = try await migrationStore.commit(verified)

        var retry = committed
        retry.failure = "The target connection dropped after the switch."
        retry.manifestDigest = String(repeating: "f", count: 64)
        retry.acceptedCapabilityLosses = ["not-reviewed"]
        retry.requiredSkillIDs = ["not-installed"]
        let saved = try await migrationStore.update(retry, expectedRevision: committed.revision)
        #expect(saved.phase == .committed)
        #expect(saved.failure == "The target connection dropped after the switch.")
        #expect(saved.revision == committed.revision + 1)
        #expect(saved.manifestDigest == committed.manifestDigest)
        #expect(saved.acceptedCapabilityLosses == committed.acceptedCapabilityLosses)
        #expect(saved.requiredSkillIDs == committed.requiredSkillIDs)
        #expect(try await migrationStore.binding(conversationID: conversation)?.generation == 2)

        var regress = saved
        regress.phase = .verified
        await #expect(throws: FloeError.self) {
            _ = try await migrationStore.update(regress, expectedRevision: saved.revision)
        }
        var prematureFinish = saved
        prematureFinish.phase = .completed
        await #expect(throws: FloeError.self) {
            _ = try await migrationStore.update(prematureFinish, expectedRevision: saved.revision)
        }

        let completed = try await migrationStore.finish(saved, notice: "Moved after reconnect")
        #expect(completed.phase == .completed)
        #expect(completed.failure == nil)
        #expect(completed.revision == saved.revision + 1)
        #expect(try await messageRows(database, conversationID: conversation).count == 1)
    }

    @Test("optional migration contract fields survive the generic ledger encoding")
    func optionalMigrationFieldsSurvive() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        var migration = TaskEnvironmentMigration(source: source, target: makeTarget("remote-b"))
        migration.acceptedCapabilityLosses = ["browser.remote", "mcp.external"]
        migration.requiredSkillIDs = ["skill-z", "skill-a"]
        try await store.begin(migration)
        migration.phase = .verified
        migration.manifestDigest = String(repeating: "a", count: 64)
        migration.dependencyReceiptDigest = String(repeating: "b", count: 64)
        migration.skillDigests = [:]
        migration = try await store.update(migration, expectedRevision: migration.revision)
        let committed = try await store.commit(migration)
        #expect(committed.acceptedCapabilityLosses == ["browser.remote", "mcp.external"])
        #expect(committed.requiredSkillIDs == ["skill-z", "skill-a"])
        let completed = try await store.finish(committed, notice: "Moved")
        let persisted = try #require(try await rawMigration(database, id: completed.id))
        #expect(persisted.acceptedCapabilityLosses == ["browser.remote", "mcp.external"])
        #expect(persisted.requiredSkillIDs == ["skill-z", "skill-a"])
    }

    // MARK: - Terminal finish

    @Test("finish records one exact-once timeline notice and rejects a changed committed binding")
    func finishIsExactOnce() async throws {
        let database = try await makeDatabase()
        let conversation = UUID()
        try await insertConversation(database, id: conversation)
        let store = TaskExecutionBindingStore(database: database)
        let source = try await store.bindInitial(makeBinding(conversation, target: makeTarget("remote-a")))
        let (store2, verified) = try await prepareVerifiedMigration(
            database, conversationID: conversation, source: source,
            target: makeTarget("remote-b"), skillDigests: [:])
        let committed = try await store2.commit(verified)

        await #expect(throws: FloeError.self) {
            _ = try await store2.finish(verified, notice: "Too early")
        }
        #expect(try await messageRows(database, conversationID: conversation).isEmpty)

        let notice = "Moved to the remote computer."
        let completed = try await store2.finish(committed, notice: notice)
        #expect(completed.phase == .completed)
        #expect(completed.revision == 4)
        let rows = try await messageRows(database, conversationID: conversation)
        #expect(rows.count == 1)
        let message = try #require(rows.first)
        #expect(message.id == committed.id.uuidString)
        #expect(message.conversationID == conversation.uuidString)
        #expect(message.role == "assistant")
        #expect(message.content == notice)
        #expect(message.runID == nil)
        let conversationUpdatedAt: String? = try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM conversations WHERE id=?",
                                arguments: [conversation.uuidString])
        }
        #expect(conversationUpdatedAt == message.createdAt)

        let again = try await store2.finish(completed, notice: "A second notice")
        #expect(again.phase == .completed)
        #expect(try await messageRows(database, conversationID: conversation).count == 1)

        // If the canonical binding no longer matches the committed target,
        // posting a success notice would be a lie.
        let otherConversation = UUID()
        try await insertConversation(database, id: otherConversation)
        let otherSource = try await store2.bindInitial(makeBinding(otherConversation, target: makeTarget("remote-c")))
        let (otherStore, otherVerified) = try await prepareVerifiedMigration(
            database, conversationID: otherConversation, source: otherSource,
            target: makeTarget("remote-d"), skillDigests: [:])
        let otherCommitted = try await otherStore.commit(otherVerified)
        try await database.writer { db in
            let replacement = try encode(TaskExecutionBinding(
                conversationID: otherConversation, target: makeTarget("remote-z"),
                generation: 9, updatedAt: Self.baseDate))
            try db.execute(sql: "UPDATE task_execution_bindings SET generation=?,body_json=? WHERE conversation_id=?",
                           arguments: [9, replacement, otherConversation.uuidString])
        }
        await #expect(throws: FloeError.self) {
            _ = try await otherStore.finish(otherCommitted, notice: "Should not post")
        }
        #expect(try await messageRows(database, conversationID: otherConversation).isEmpty)
    }
}

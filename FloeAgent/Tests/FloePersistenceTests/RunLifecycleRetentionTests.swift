// FloePersistenceTests — retention for the v46 lifecycle tables.
//
// Deleting a conversation removes exactly the lifecycle rows it owns (child
// transcripts/relations, dependencies, job records) in the same transaction,
// and spooled output artifacts only after the commit and only inside the
// canonical spool root. A different conversation's records — including work
// in a shared environment — must survive untouched.

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.RunLifecycleRetention")
struct RunLifecycleRetentionTests {

    private func database() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func insertConversation(
        _ db: DatabaseManager,
        id: UUID,
        title: String = "Task",
        titleOrigin: String = "autoPending"
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, title_origin, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, title, titleOrigin, now, now])
        }
    }

    @discardableResult
    private func seedLifecycle(
        _ db: DatabaseManager,
        conversationID: UUID,
        suffix: String
    ) async throws -> (childRunID: UUID, jobID: UUID) {
        let parentRun = UUID()
        let childRun = UUID()
        let jobID = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'goal-\(suffix)', ?)
                """, arguments: [parentRun.uuidString, conversationID.uuidString, now])
            try db.execute(sql: """
                INSERT INTO child_runs (
                    id, parent_run_id, root_run_id, conversation_id, child_index,
                    kind, task_summary, state, iteration_count, started_at, updated_at
                ) VALUES (?, ?, ?, ?, 1, 'explore', 'child-\(suffix)', 'running', 2, ?, ?)
                """, arguments: [childRun.uuidString, parentRun.uuidString,
                                 conversationID.uuidString, conversationID.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO child_run_entries (
                    id, child_run_id, sequence, kind, payload_json, created_at
                ) VALUES (?, ?, 1, 'toolResult', '{"tool":"web.fetch"}', ?)
                """, arguments: [UUID().uuidString, childRun.uuidString, now])
            try db.execute(sql: """
                INSERT INTO run_relations (
                    parent_run_id, child_run_id, child_index, task_summary,
                    created_at, root_run_id, conversation_id, state, updated_at,
                    delegate_call_id
                ) VALUES (?, ?, 1, 'child-\(suffix)', ?, ?, ?, 'running', ?, 'call-\(suffix)')
                """, arguments: [parentRun.uuidString, childRun.uuidString, now,
                                 conversationID.uuidString, conversationID.uuidString, now])
            try db.execute(sql: """
                INSERT INTO run_dependencies (
                    job_id, run_id, conversation_id, kind, state, created_at
                ) VALUES (?, ?, ?, 'job', 'pending', ?)
                """, arguments: [jobID.uuidString, parentRun.uuidString,
                                 conversationID.uuidString, now])
            try db.execute(sql: """
                INSERT INTO background_jobs (
                    id, conversation_id, run_id, kind, target_tool, payload_json,
                    state, created_at, updated_at
                ) VALUES (?, ?, ?, 'tool', 'exec.localPython', ?, 'completed', ?, ?)
                """, arguments: [jobID.uuidString, conversationID.uuidString,
                                 parentRun.uuidString, Data("{}".utf8), now, now])
        }
        return (childRun, jobID)
    }

    private func count(_ db: DatabaseManager, table: String, where clause: String, _ id: UUID) async throws -> Int {
        try await db.reader { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(clause) = ?",
                arguments: [id.uuidString]) ?? -1
        }
    }

    @Test("Deleting a conversation removes its owned lifecycle rows and keeps other owners' rows")
    func deleteConversationPurgesOwnedLifecycle() async throws {
        let db = try await database()
        let doomed = UUID()
        let survivor = UUID()
        try await insertConversation(db, id: doomed)
        try await insertConversation(db, id: survivor)
        let owned = try await seedLifecycle(db, conversationID: doomed, suffix: "owned")
        let kept = try await seedLifecycle(db, conversationID: survivor, suffix: "shared-vm-other-owner")

        try await SQLiteConversationStore(database: db).deleteConversation(id: doomed)

        #expect(try await count(db, table: "child_runs", where: "conversation_id", doomed) == 0)
        #expect(try await count(db, table: "run_relations", where: "conversation_id", doomed) == 0)
        #expect(try await count(db, table: "run_dependencies", where: "conversation_id", doomed) == 0)
        #expect(try await count(db, table: "background_jobs", where: "conversation_id", doomed) == 0)
        #expect(try await db.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM child_run_entries WHERE child_run_id = ?",
                             arguments: [owned.childRunID.uuidString]) ?? -1
        } == 0)

        // The other conversation's child, relation, dependency and job all
        // survive — including a shared-environment job owned elsewhere.
        #expect(try await count(db, table: "child_runs", where: "conversation_id", survivor) == 1)
        #expect(try await count(db, table: "run_relations", where: "conversation_id", survivor) == 1)
        #expect(try await count(db, table: "run_dependencies", where: "conversation_id", survivor) == 1)
        #expect(try await count(db, table: "background_jobs", where: "conversation_id", survivor) == 1)
        #expect(try await db.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM child_run_entries WHERE child_run_id = ?",
                             arguments: [kept.childRunID.uuidString]) ?? -1
        } == 1)
    }

    @Test("An interrupted child is removed with its parent and kept for other conversations")
    func interruptedChildRetention() async throws {
        let db = try await database()
        let doomed = UUID()
        let survivor = UUID()
        try await insertConversation(db, id: doomed)
        try await insertConversation(db, id: survivor)
        let owned = try await seedLifecycle(db, conversationID: doomed, suffix: "interrupted")
        let kept = try await seedLifecycle(db, conversationID: survivor, suffix: "interrupted-shared")
        let childStore = SQLiteChildRunStore(database: db)
        try await childStore.transition(id: owned.childRunID, state: .running, iterationCount: 3, endedAt: nil)
        try await childStore.transition(id: kept.childRunID, state: .running, iterationCount: 4, endedAt: nil)
        #expect(try await childStore.reconcileInterruptedOnLaunch() == 2)
        #expect(try await childStore.child(id: kept.childRunID)?.state == .interrupted)

        try await SQLiteConversationStore(database: db).deleteConversation(id: doomed)
        #expect(try await childStore.child(id: owned.childRunID) == nil)
        #expect(try await childStore.child(id: kept.childRunID)?.state == .interrupted)
        #expect(try await childStore.children(conversationID: survivor).count == 1)
    }

    @Test("Spool cleanup removes only UUID-named artifacts inside the canonical root")
    func spoolCleanupIsConfined() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let owned = root.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("job output".utf8).write(to: owned)
        let notNamedByJob = root.appendingPathComponent("user-export.txt")
        try Data("user export".utf8).write(to: notNamedByJob)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-outside-\(UUID().uuidString).txt")
        try Data("result".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let nested = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("nested".utf8).write(to: nestedFile)

        RunLifecycleRetention.removeSpoolArtifacts(
            [owned.path, notNamedByJob.path, outside.path, nestedFile.path],
            root: root)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: notNamedByJob.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: nestedFile.path))
    }

    @Test("Verified-empty deletion refuses a conversation that owns lifecycle rows")
    func verifiedEmptyRefusesLifecycleOwners() async throws {
        let db = try await database()
        let store = SQLiteConversationStore(database: db)
        let withChild = UUID()
        try await insertConversation(db, id: withChild, title: "", titleOrigin: "autoPending")
        try await seedLifecycle(db, conversationID: withChild, suffix: "nonempty")
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: withChild) == false)
        #expect(try await store.conversation(id: withChild) != nil)

        let blank = UUID()
        try await insertConversation(db, id: blank, title: "", titleOrigin: "autoPending")
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: blank) == true)
        #expect(try await store.conversation(id: blank) == nil)
    }
}

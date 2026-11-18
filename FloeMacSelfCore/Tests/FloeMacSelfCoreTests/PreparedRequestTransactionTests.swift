// SPDX-License-Identifier: MPL-2.0
// Isolated, synthetic DB; never accesses the host or any provider.
import Foundation
import GRDB
import Testing
import FloePersistence
@testable import FloeMacSelfCore

private struct PreparedRollback: Error {}
private struct PreparedFixture: Sendable {
    let database: DatabaseManager
    let databaseURL: URL?
    let scope: FloeMacSelfRequestJournalScope
    let admission: FloeMacSelfAdmissionStore
    let principal: FloeMacSelfRequestJournalPrincipal
    let requestID = UUID()
    func prepare(_ db: Database, goal: String = " \n你好 fixture  ") throws -> FloeMacSelfPreparedRequestResult {
        try FloeMacSelfPreparedRequest.prepare(db: db, requestID: requestID, scope: scope, principal: principal, goal: goal)
    }
}
private func withPreparedFixture(persistent: Bool = false, _ body: (PreparedFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-prepared-request-\(UUID().uuidString)", isDirectory: true)
    let databaseURL: URL?
    if persistent {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        databaseURL = directory.appendingPathComponent("fixture.sqlite")
    } else { databaseURL = nil }
    defer { if persistent { try? FileManager.default.removeItem(at: directory) } }
    let database = try databaseURL.map { try DatabaseManager(path: $0) } ?? DatabaseManager.inMemory()
    try await database.migrate()
    let conversationID = UUID(), now = Date()
    try await SQLiteConversationStore(database: database).saveConversationWithCanonicalWorkspace(
        ConversationRecord(id: conversationID, title: "synthetic", createdAt: now, updatedAt: now))
    let workspaceID = try await database.reader { db -> UUID in
        guard let value = try String.fetchOne(db, sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id=?", arguments: [conversationID.uuidString]),
              let id = UUID(uuidString: value) else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
        return id
    }
    let owner = FloeMacSelfHostIdentity(hostInstanceID: UUID(), processIdentifier: 4242, displayName: "synthetic")
    let principal = FloeMacSelfRequestJournalPrincipal(hostInstanceID: owner.hostInstanceID, processIdentifier: owner.processIdentifier)
    let admission = FloeMacSelfAdmissionStore(database: database, authorityLock: nil)
    try await database.writer { db in
        try FloeMacSelfAdmissionStore.installSchema(in: db)
        try FloeMacSelfRequestJournal.installSchema(in: db)
        try FloeMacSelfPreparedRequest.installSchema(in: db)
    }
    let runID = UUID()
    let admitted = try await admission.admit(conversationID: conversationID, runID: runID, owner: owner)
    #expect(admitted.phase == .admitting)
    let scope = FloeMacSelfRequestJournalScope(taskID: UUID(), workspaceID: workspaceID,
        conversationID: conversationID, runID: runID, runGeneration: admitted.epoch, operation: .startRun)
    try await body(.init(database: database, databaseURL: databaseURL, scope: scope, admission: admission, principal: principal))
    try await database.close()
}
private func preparedCounts(_ db: Database, _ f: PreparedFixture) throws -> [Int] {
    try [
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal WHERE request_id=?", arguments: [f.requestID.uuidString]) ?? -1,
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM floe_mac_self_prepared_request WHERE request_id=?", arguments: [f.requestID.uuidString]) ?? -1,
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE id=?", arguments: [f.scope.runID.uuidString]) ?? -1,
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE run_id=?", arguments: [f.scope.runID.uuidString]) ?? -1
    ]
}
private actor PreparedRaceBarrier {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 2 {
                let ready = waiters
                waiters.removeAll()
                for waiter in ready { waiter.resume() }
            }
        }
    }
}
private enum PreparedRaceOutcome: Sendable, Equatable {
    case recorded(UUID)
    case replayed(UUID)
    case constraint
    case unexpected(String)
}
@Suite("Prepared request transaction")
struct PreparedRequestTransactionTests {
    @Test("Real prepare binds canonical bytes and exact replay never creates another run")
    func replayAndContent() async throws {
        try await withPreparedFixture { f in
            let a = try await f.database.writer { try f.prepare($0) }
            #expect(try await f.admission.record(conversationID: f.scope.conversationID)?.phase == .admitting)
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            #expect(try await f.admission.record(conversationID: f.scope.conversationID)?.phase == .prepared)
            let b = try await f.database.writer { try f.prepare($0, goal: "你好 fixture") }
            #expect(!a.replayed && b.replayed && a.journalID == b.journalID && a.userMessageID == b.userMessageID)
            try await f.database.reader { db in
                #expect((try? preparedCounts(db, f)) == [1,1,1,1])
                #expect((try? Data.fetchOne(db, sql: "SELECT CAST(content AS BLOB) FROM messages WHERE id=?", arguments: [a.userMessageID.uuidString])) == Data("你好 fixture".utf8))
            }
            try await f.database.writer { db in
                #expect(throws: FloeMacSelfRequestJournalError.self) { _ = try f.prepare(db, goal: "changed") }
                try db.execute(sql: "UPDATE messages SET content='changed' WHERE id=?", arguments: [a.userMessageID.uuidString])
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) { _ = try f.prepare(db) }
            }
        }
    }
    @Test("NUL, mismatched workspace and admission owner fail without rows")
    func refusals() async throws {
        try await withPreparedFixture { f in
            try await f.database.writer { db in
                #expect(throws: FloeMacSelfPreparedRequestError.invalidInput) { _ = try f.prepare(db, goal: "a\0b") }
                let bad = FloeMacSelfRequestJournalScope(taskID: f.scope.taskID, workspaceID: UUID(), conversationID: f.scope.conversationID, runID: f.scope.runID, runGeneration: 1, operation: .startRun)
                #expect(throws: (any Error).self) { _ = try FloeMacSelfPreparedRequest.prepare(db: db, requestID: f.requestID, scope: bad, principal: f.principal, goal: "fixture") }
                let principal = FloeMacSelfRequestJournalPrincipal(hostInstanceID: UUID(), processIdentifier: 4242)
                #expect(throws: FloeMacSelfPreparedRequestError.admissionMismatch) { _ = try FloeMacSelfPreparedRequest.prepare(db: db, requestID: f.requestID, scope: f.scope, principal: principal, goal: "fixture") }
                #expect((try? preparedCounts(db, f)) == [0,0,0,0])
            }
        }
    }
    @Test("Prepare failure and binding failure roll back even when caller catches")
    func innerRollback() async throws {
        try await withPreparedFixture { f in
            for table in ["run_events", "floe_mac_self_prepared_request"] {
                try await f.database.writer { db in
                    try db.execute(sql: "CREATE TRIGGER reject_fixture BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
                    #expect(throws: (any Error).self) { _ = try f.prepare(db) }
                    #expect((try? preparedCounts(db, f)) == [0,0,0,0])
                    try db.execute(sql: "DROP TRIGGER reject_fixture")
                }
            }
        }
    }
    @Test("Outer and caller savepoint rollback discard all provisional facts")
    func outerAndSavepoint() async throws {
        try await withPreparedFixture { f in
            do {
                try await f.database.writer { db in _ = try f.prepare(db); throw PreparedRollback() }
                Issue.record("outer rollback was not thrown")
            } catch is PreparedRollback {}
            let provisional = try await f.database.writer { db in
                #expect((try? preparedCounts(db, f)) == [0,0,0,0])
                try db.execute(sql: "SAVEPOINT fixture_caller")
                let value = try f.prepare(db)
                try db.execute(sql: "ROLLBACK TO SAVEPOINT fixture_caller")
                try db.execute(sql: "RELEASE SAVEPOINT fixture_caller")
                return value
            }
            #expect(!provisional.replayed)
            try await f.database.reader { db in #expect((try? preparedCounts(db, f)) == [0,0,0,0]) }
        }
    }
    @Test("Reusing a request with changed task, workspace, run, epoch or owner conflicts")
    func identityConflicts() async throws {
        try await withPreparedFixture { f in
            _ = try await f.database.writer { try f.prepare($0) }
            try await f.database.writer { db in
                let s = f.scope
                let changed: [FloeMacSelfRequestJournalScope] = [
                    .init(taskID: UUID(), workspaceID: s.workspaceID, conversationID: s.conversationID, runID: s.runID, runGeneration: 1, operation: .startRun),
                    .init(taskID: s.taskID, workspaceID: UUID(), conversationID: s.conversationID, runID: s.runID, runGeneration: 1, operation: .startRun),
                    .init(taskID: s.taskID, workspaceID: s.workspaceID, conversationID: s.conversationID, runID: UUID(), runGeneration: 1, operation: .startRun),
                    .init(taskID: s.taskID, workspaceID: s.workspaceID, conversationID: s.conversationID, runID: s.runID, runGeneration: 2, operation: .startRun)
                ]
                for scope in changed {
                    #expect(throws: FloeMacSelfRequestJournalError.self) {
                        _ = try FloeMacSelfPreparedRequest.prepare(db: db, requestID: f.requestID, scope: scope, principal: f.principal, goal: "你好 fixture")
                    }
                }
                let changedOwner = FloeMacSelfRequestJournalPrincipal(hostInstanceID: f.principal.hostInstanceID, processIdentifier: 4243)
                #expect(throws: FloeMacSelfRequestJournalError.self) {
                    _ = try FloeMacSelfPreparedRequest.prepare(db: db, requestID: f.requestID, scope: s, principal: changedOwner, goal: "你好 fixture")
                }
                #expect((try? preparedCounts(db, f)) == [1,1,1,1])
            }
        }
    }
    @Test("Changed text metadata or an added attachment cannot replay as the original input")
    func changedPartMetadata() async throws {
        try await withPreparedFixture { f in
            let result = try await f.database.writer { try f.prepare($0) }
            try await f.database.writer { db in
                try db.execute(sql: "INSERT INTO attachments (id,conversation_id,message_id,kind,created_at) VALUES (?,?,?,'document','2026-01-01T00:00:00Z')", arguments: [UUID().uuidString, f.scope.conversationID.uuidString, result.userMessageID.uuidString])
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) { _ = try f.prepare(db) }
                try db.execute(sql: "DELETE FROM attachments WHERE message_id=?", arguments: [result.userMessageID.uuidString])
                try db.execute(sql: "UPDATE message_parts SET metadata_json=? WHERE message_id=?", arguments: ["{\"floe.plan.confirmation.v1\":\"fake\"}", result.userMessageID.uuidString])
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) { _ = try f.prepare(db) }
                #expect((try? preparedCounts(db, f)) == [1,1,1,1])
            }
        }
    }
    @Test("A first prepare in prepared phase is refused without creating facts")
    func preparedPhaseRefused() async throws {
        try await withPreparedFixture { f in
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                #expect(throws: FloeMacSelfPreparedRequestError.admissionMismatch) { _ = try f.prepare(db) }
                #expect((try? preparedCounts(db, f)) == [0,0,0,0])
            }
        }
    }
    @Test("A durable stop refuses a new reservation and prepare")
    func stoppedAdmission() async throws {
        try await withPreparedFixture { f in
            try await f.database.writer { db in
                try db.execute(sql: "UPDATE floe_mac_self_admission SET stop_requested_at=2 WHERE conversation_id=?", arguments: [f.scope.conversationID.uuidString])
                #expect(throws: FloeMacSelfRequestJournalError.admissionPhaseRefused("stop_requested")) { _ = try f.prepare(db) }
                #expect((try? preparedCounts(db, f)) == [0,0,0,0])
            }
        }
    }
    @Test("After durable stop, epoch or owner change replay is historical and cannot claim dispatch")
    func stoppedOrStaleReplay() async throws {
        for variant in 0..<3 {
            try await withPreparedFixture { f in
                let first = try await f.database.writer { try f.prepare($0) }
                try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
                if variant == 1 {
                    // Synthetic epoch mutation tests the stale fence; it does not model a legal recovery transition.
                    try await f.database.writer { db in
                        try db.execute(sql: "UPDATE floe_mac_self_admission SET epoch=epoch+1 WHERE conversation_id=?", arguments: [f.scope.conversationID.uuidString])
                    }
                } else if variant == 2 {
                    try await f.database.writer { db in
                        try db.execute(sql: "UPDATE floe_mac_self_admission SET owner_host_id=? WHERE conversation_id=?", arguments: [UUID().uuidString, f.scope.conversationID.uuidString])
                    }
                } else {
                    let stop = try await f.admission.recordStopIntent(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
                    #expect(stop == 1)
                }
                try await f.database.writer { db in
                    let replay = try f.prepare(db)
                    #expect(replay.replayed && replay.userMessageID == first.userMessageID)
                    let record = try #require(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID))
                    #expect(record.phase == .accepted)
                    #expect(throws: FloeMacSelfRequestJournalError.admissionPhaseRefused("dispatch_claim_refused")) {
                        _ = try FloeMacSelfRequestJournal.commitStartDispatch(db: db, requestID: f.requestID, scope: f.scope, principal: f.principal, fingerprint: record.fingerprint)
                    }
                    #expect((try? preparedCounts(db, f)) == [1,1,1,1])
                    #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
                }
            }
        }
    }
    @Test("Changed durable role, goal, part or workspace ownership refuses replay")
    func changedDurableFields() async throws {
        try await withPreparedFixture { f in
            let first = try await f.database.writer { try f.prepare($0) }
            try await f.database.writer { db in
                let mutations: [(String, StatementArguments)] = [
                    ("UPDATE messages SET role='assistant' WHERE id=?", [first.userMessageID.uuidString]),
                    ("UPDATE runs SET goal='changed' WHERE id=?", [f.scope.runID.uuidString]),
                    ("UPDATE message_parts SET text='changed' WHERE message_id=?", [first.userMessageID.uuidString]),
                    ("DELETE FROM conversation_workspace_ownership WHERE conversation_id=?", [f.scope.conversationID.uuidString]),
                    ("INSERT INTO message_parts (id,message_id,part_index,kind,text,metadata_json,created_at) SELECT ?,message_id,1,'text',text,metadata_json,created_at FROM message_parts WHERE message_id=?", [UUID().uuidString, first.userMessageID.uuidString])
                ]
                for (sql, args) in mutations {
                    try db.execute(sql: "SAVEPOINT fixture_mutation")
                    try db.execute(sql: sql, arguments: args)
                    #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) { _ = try f.prepare(db) }
                    try db.execute(sql: "ROLLBACK TO SAVEPOINT fixture_mutation")
                    try db.execute(sql: "RELEASE SAVEPOINT fixture_mutation")
                }
                #expect(try f.prepare(db).replayed)
            }
        }
    }
    @Test("Two SQLite connections serialize the same or competing request")
    func twoConnectionRace() async throws {
        for sameRequest in [true, false] {
            try await withPreparedFixture(persistent: true) { f in
                let path = try #require(f.databaseURL?.path)
                var config = Configuration(); config.busyMode = .timeout(5)
                let one = try DatabaseQueue(path: path, configuration: config)
                let two = try DatabaseQueue(path: path, configuration: config)
                let competing = sameRequest ? f.requestID : UUID()
                let barrier = PreparedRaceBarrier()
                let outcomes = await withTaskGroup(of: PreparedRaceOutcome.self, returning: [PreparedRaceOutcome].self) { group in
                    for (queue, id) in [(one, f.requestID), (two, competing)] {
                        group.addTask {
                            await barrier.arrive()
                            do {
                                let result = try await queue.write { db in
                                    try FloeMacSelfPreparedRequest.prepare(db: db, requestID: id, scope: f.scope, principal: f.principal, goal: "你好 fixture")
                                }
                                return result.replayed ? .replayed(result.userMessageID) : .recorded(result.userMessageID)
                            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                                return .constraint
                            } catch { return .unexpected(String(describing: error)) }
                        }
                    }
                    var values: [PreparedRaceOutcome] = []; for await value in group { values.append(value) }; return values
                }
                let recorded = outcomes.compactMap { value -> UUID? in if case .recorded(let id) = value { return id }; return nil }
                let replays = outcomes.compactMap { value -> UUID? in if case .replayed(let id) = value { return id }; return nil }
                #expect(recorded.count == 1)
                if sameRequest {
                    #expect(replays == recorded)
                } else {
                    #expect(outcomes.contains(.constraint))
                    #expect(replays.isEmpty)
                }
                try await f.database.reader { db in
                    #expect((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal")) == 1)
                    #expect((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM floe_mac_self_prepared_request")) == 1)
                    #expect((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs WHERE id=?", arguments: [f.scope.runID.uuidString])) == 1)
                    #expect((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE run_id=?", arguments: [f.scope.runID.uuidString])) == 1)
                }
                try one.close(); try two.close()
            }
        }
    }
    @Test("An existing reservation without a binding fails closed")
    func incompleteReservation() async throws {
        try await withPreparedFixture { f in
            try await f.database.writer { db in
                _ = try FloeMacSelfRequestJournal.reserve(db: db, requestID: f.requestID, scope: f.scope, principal: f.principal, payload: Data("你好 fixture".utf8))
                #expect(throws: FloeMacSelfPreparedRequestError.missingBinding) { _ = try f.prepare(db) }
                #expect((try? preparedCounts(db, f)) == [1,0,0,0])
            }
        }
    }

    @Test("Bound dispatch checks the durable prepared message and a replay cannot claim again")
    func boundDispatchAndReplay() async throws {
        try await withPreparedFixture { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                #expect(throws: FloeMacSelfPreparedRequestError.missingBinding) {
                    _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                        scope: f.scope, principal: f.principal, userMessageID: UUID(), goal: "你好 fixture")
                }
                #expect(throws: FloeMacSelfRequestJournalError.self) {
                    _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                        scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "other")
                }
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
                let first = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: " \n你好 fixture ")
                let replay = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                #expect(first.recorded && !replay.recorded)
                #expect(first.record.journalID == replay.record.journalID && first.record.phase == .dispatchMayHaveStarted)
            }
        }
    }

    @Test("Bound dispatch refuses missing requests, stale owners and durable stop")
    func boundDispatchRefusals() async throws {
        for variant in 0..<3 {
            try await withPreparedFixture { f in
                let prepared = try await f.database.writer { try f.prepare($0) }
                try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
                if variant == 2 {
                    _ = try await f.admission.recordStopIntent(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
                }
                try await f.database.writer { db in
                    let id = variant == 0 ? UUID() : f.requestID
                    let principal = variant == 1 ? FloeMacSelfRequestJournalPrincipal(hostInstanceID: UUID(), processIdentifier: 4242) : f.principal
                    #expect(throws: (any Error).self) {
                        _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: id,
                            scope: f.scope, principal: principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                    }
                    #expect((try? FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase) == .accepted)
                    #expect((try? preparedCounts(db, f)) == [1,1,1,1])
                }
            }
        }
    }

    @Test("CAS trigger changing prepared input rolls back the entire bound dispatch")
    func boundDispatchTriggerRollback() async throws {
        try await withPreparedFixture { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                try db.execute(sql: """
                    CREATE TRIGGER corrupt_bound_fixture AFTER UPDATE OF phase ON floe_mac_self_admission
                    WHEN NEW.phase='starting' BEGIN
                      UPDATE messages SET content='changed' WHERE run_id=NEW.run_id;
                    END
                    """)
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) {
                    _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                        scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                }
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
                #expect(try String.fetchOne(db, sql: "SELECT phase FROM floe_mac_self_admission WHERE conversation_id=?", arguments: [f.scope.conversationID.uuidString]) == "prepared")
                #expect(try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id=?", arguments: [prepared.userMessageID.uuidString]) == "你好 fixture")
                try db.execute(sql: "DROP TRIGGER corrupt_bound_fixture")
            }
        }
    }

    @Test("Bound dispatch is provisional under caller savepoint and serialized across connections")
    func boundDispatchRollbackAndRace() async throws {
        try await withPreparedFixture(persistent: true) { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                try db.execute(sql: "SAVEPOINT caller_fixture")
                let provisional = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                #expect(provisional.recorded)
                try db.execute(sql: "ROLLBACK TO SAVEPOINT caller_fixture")
                try db.execute(sql: "RELEASE SAVEPOINT caller_fixture")
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
            }
            let path = try #require(f.databaseURL?.path)
            var config = Configuration(); config.busyMode = .timeout(5)
            let one = try DatabaseQueue(path: path, configuration: config)
            let two = try DatabaseQueue(path: path, configuration: config)
            let barrier = PreparedRaceBarrier()
            let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
                for queue in [one, two] {
                    group.addTask {
                        await barrier.arrive()
                        do {
                            let claim = try await queue.write { db in
                                try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                            }
                            return claim.recorded ? "recorded" : "replayed"
                        } catch { return "error: \(error)" }
                    }
                }
                var values: [String] = []; for await value in group { values.append(value) }; return values
            }
            #expect(outcomes.sorted() == ["recorded", "replayed"])
            try one.close(); try two.close()
        }
    }

    @Test("First bound dispatch refuses a run that is no longer preparing or has ended")
    func boundDispatchRequiresStartableRun() async throws {
        try await withPreparedFixture { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                let variants: [(String, String?)] = [
                    ("completed", nil), ("failed", nil), ("running", nil),
                    ("unknown", nil), ("preparing", "2026-01-01T00:00:00Z")
                ]
                for (state, endedAt) in variants {
                    try db.execute(sql: "SAVEPOINT fixture_invalid_run")
                    try db.execute(sql: "UPDATE runs SET state=?,ended_at=? WHERE id=?",
                                   arguments: [state, endedAt, f.scope.runID.uuidString])
                    #expect(throws: FloeMacSelfPreparedRequestError.runNotStartable) {
                        _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                            scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                    }
                    #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
                    #expect(try String.fetchOne(db, sql: "SELECT phase FROM floe_mac_self_admission WHERE conversation_id=?", arguments: [f.scope.conversationID.uuidString]) == "prepared")
                    try db.execute(sql: "ROLLBACK TO SAVEPOINT fixture_invalid_run")
                    try db.execute(sql: "RELEASE SAVEPOINT fixture_invalid_run")
                }
            }
        }
    }

    @Test("CAS trigger ending or advancing the run rolls both dispatch transitions back")
    func boundDispatchEndedTriggerRollback() async throws {
        try await withPreparedFixture { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                for update in ["state='completed'", "ended_at='2026-01-01T00:00:00Z'", "state='completed',ended_at='2026-01-01T00:00:00Z'"] {
                    try db.execute(sql: """
                        CREATE TRIGGER end_run_fixture AFTER UPDATE OF phase ON floe_mac_self_admission
                        WHEN NEW.phase='starting' BEGIN
                          UPDATE runs SET \(update) WHERE id=NEW.run_id;
                        END
                        """)
                    #expect(throws: FloeMacSelfPreparedRequestError.runNotStartable) {
                        _ = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                            scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                    }
                    #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)?.phase == .accepted)
                    #expect(try String.fetchOne(db, sql: "SELECT phase FROM floe_mac_self_admission WHERE conversation_id=?", arguments: [f.scope.conversationID.uuidString]) == "prepared")
                    let fetched = try Row.fetchOne(db, sql: "SELECT state,ended_at FROM runs WHERE id=?", arguments: [f.scope.runID.uuidString])
                    let run = try #require(fetched)
                    #expect((run["state"] as String) == "preparing" && (run["ended_at"] as String?) == nil)
                    try db.execute(sql: "DROP TRIGGER end_run_fixture")
                }
            }
        }
    }

    @Test("A terminal historical replay remains read-only and never claims dispatch")
    func boundDispatchTerminalReplayIsReadOnly() async throws {
        try await withPreparedFixture { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID, runID: f.scope.runID, epoch: f.scope.runGeneration)
            try await f.database.writer { db in
                let first = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                #expect(first.recorded)
                try db.execute(sql: "UPDATE runs SET state='completed',ended_at='2026-01-01T00:00:00Z' WHERE id=?", arguments: [f.scope.runID.uuidString])
                try db.execute(sql: "CREATE TRIGGER refuse_replay_journal BEFORE UPDATE ON floe_mac_self_request_journal BEGIN SELECT RAISE(ABORT, 'replay wrote journal'); END")
                try db.execute(sql: "CREATE TRIGGER refuse_replay_admission BEFORE UPDATE ON floe_mac_self_admission BEGIN SELECT RAISE(ABORT, 'replay wrote admission'); END")
                let replay = try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: prepared.userMessageID, goal: "你好 fixture")
                #expect(!replay.recorded && replay.record.journalID == first.record.journalID)
                try db.execute(sql: "DROP TRIGGER refuse_replay_journal")
                try db.execute(sql: "DROP TRIGGER refuse_replay_admission")
            }
        }
    }

    @Test("Bound terminal reconciliation verifies persisted input and terminal proof without writes")
    func readBoundStartTerminal() async throws {
        try await withPreparedFixture(persistent: true) { f in
            let prepared = try await f.database.writer { try f.prepare($0) }
            let messageID = prepared.userMessageID
            let read: @Sendable (Database) throws -> FloeMacSelfTerminalReceipt = { db in
                try FloeMacSelfPreparedRequest.readBoundStartTerminal(
                    db: db, requestID: f.requestID, scope: f.scope, principal: f.principal,
                    userMessageID: messageID, goal: " \n你好 fixture ")
            }

            try await f.database.reader { db in
                #expect(throws: FloeMacSelfPreparedRequestError.dispatchNotRecorded) {
                    _ = try read(db)
                }
            }
            try await f.admission.markPrepared(conversationID: f.scope.conversationID,
                runID: f.scope.runID, epoch: f.scope.runGeneration)
            let dispatch = try await f.database.writer { db in
                try FloeMacSelfPreparedRequest.claimBoundStart(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, userMessageID: messageID, goal: "你好 fixture")
            }
            #expect(dispatch.recorded)

            let runs = SQLiteRunStore(database: f.database)
            try await runs.updateRunState(id: f.scope.runID, state: "completed", endedAt: Date())
            #expect(try await f.database.reader(read).confirmed == false)
            let assistantID = UUID()
            try await SQLiteConversationStore(database: f.database).appendMessage(PersistedMessage(
                id: assistantID, conversationID: f.scope.conversationID, role: "assistant",
                content: "synthetic assistant answer", createdAt: Date(), parts: [], runID: f.scope.runID))
            let marker = try JSONSerialization.data(withJSONObject: [
                "stopReason": "endTurn", "finalMessageID": assistantID.uuidString
            ])
            let event = try await runs.appendEvent(runID: f.scope.runID, kind: .terminal,
                payloadJSON: String(decoding: marker, as: UTF8.self))
            try await f.database.reader { db in
                let receipt = try read(db)
                #expect(receipt.confirmed && receipt.outcome == .completed)
                #expect(receipt.terminalEventSequence == event.sequence && receipt.finalMessageID == assistantID)
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID) == dispatch.record)
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) {
                    _ = try FloeMacSelfPreparedRequest.readBoundStartTerminal(
                        db: db, requestID: f.requestID, scope: f.scope, principal: f.principal,
                        userMessageID: messageID, goal: "a different request")
                }
            }
            try await f.database.writer { db in
                let unknown = try FloeMacSelfRequestJournal.markUnknown(db: db, requestID: f.requestID,
                    scope: f.scope, principal: f.principal, fingerprint: dispatch.record.fingerprint,
                    reason: .dispatchOutcomeUnknown)
                #expect(unknown.changed)
            }
            try await f.database.reader { db in
                let receipt = try read(db)
                let record = try FloeMacSelfRequestJournal.record(db: db, requestID: f.requestID)
                #expect(receipt.confirmed)
                #expect(record?.phase == .unknown)
            }
            try await f.database.writer { db in
                try db.execute(sql: "UPDATE message_parts SET text='changed' WHERE message_id=?",
                    arguments: [messageID.uuidString])
            }
            try await f.database.reader { db in
                #expect(throws: FloeMacSelfPreparedRequestError.corruptedBinding) {
                    _ = try read(db)
                }
            }
        }
    }
}

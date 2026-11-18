// SPDX-License-Identifier: MPL-2.0
// Isolated same-connection admission/journal transaction tests. No runtime,
// provider, host authorization, Keychain or user database is involved.
import Foundation
import GRDB
import Testing
@testable import FloeMacSelfCore

private struct AtomicOuterRollback: Error {}

private struct AtomicFixture: Sendable {
    let conversation = UUID()
    let run = UUID()
    let task = UUID()
    let workspace = UUID()
    let host = UUID()
    let pid: Int32 = 4242
    var scope: FloeMacSelfRequestJournalScope {
        .init(taskID: task, workspaceID: workspace, conversationID: conversation,
              runID: run, runGeneration: 1, operation: .startRun)
    }
    var principal: FloeMacSelfRequestJournalPrincipal {
        .init(hostInstanceID: host, processIdentifier: pid)
    }
    func install(_ db: Database) throws {
        try FloeMacSelfAdmissionStore.installSchema(in: db)
        try FloeMacSelfRequestJournal.installSchema(in: db)
        try db.execute(sql: """
            INSERT INTO main.floe_mac_self_admission
              (conversation_id,run_id,phase,epoch,admitted_at,updated_at,
               owner_host_id,owner_pid,stop_requested_at,stop_epoch)
            VALUES (?,?,'prepared',1,1,1,?,?,NULL,0)
            """, arguments: [conversation.uuidString, run.uuidString, host.uuidString, Int(pid)])
    }
    func reserve(_ db: Database, id: UUID, principal: FloeMacSelfRequestJournalPrincipal? = nil) throws -> FloeMacSelfRequestJournalPayloadFingerprint {
        try FloeMacSelfRequestJournal.reserve(db: db, requestID: id, scope: scope,
            principal: principal ?? self.principal, payload: Data("fixture".utf8)).record.fingerprint
    }
    func claim(_ db: Database, id: UUID, fingerprint: FloeMacSelfRequestJournalPayloadFingerprint,
               principal: FloeMacSelfRequestJournalPrincipal? = nil) throws -> FloeMacSelfRequestJournalDispatchReservation {
        try FloeMacSelfRequestJournal.commitStartDispatch(db: db, requestID: id, scope: scope,
            principal: principal ?? self.principal, fingerprint: fingerprint)
    }
    func phase(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT phase FROM main.floe_mac_self_admission WHERE conversation_id = ?",
                            arguments: [conversation.uuidString])
    }
}

@Suite("Request admission atomic dispatch")
struct AtomicDispatchTests {
    @Test("Exact replay records once and changed identity cannot claim")
    func replayAndIdentity() throws {
        let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
        try db.write { db in
            try f.install(db)
            let fingerprint = try f.reserve(db, id: request)
            let first = try f.claim(db, id: request, fingerprint: fingerprint)
            #expect(first.recorded)
            #expect(first.record.phase == .dispatchMayHaveStarted)
            let replay = try f.claim(db, id: request, fingerprint: fingerprint)
            #expect(!replay.recorded)
            #expect(replay.record.journalID == first.record.journalID)
            #expect(replay.record.dispatchRecordedAt == first.record.dispatchRecordedAt)
            let changed = FloeMacSelfRequestJournalPrincipal(hostInstanceID: UUID(), processIdentifier: f.pid)
            #expect(throws: FloeMacSelfRequestJournalError.identityConflict(requestID: request, field: "principal_host_id")) {
                _ = try f.claim(db, id: request, fingerprint: fingerprint, principal: changed)
            }
            let restarted = FloeMacSelfRequestJournalPrincipal(hostInstanceID: f.host, processIdentifier: f.pid + 1)
            #expect(throws: FloeMacSelfRequestJournalError.identityConflict(requestID: request, field: "principal_pid")) {
                _ = try f.claim(db, id: request, fingerprint: fingerprint, principal: restarted)
            }
            #expect(try f.phase(db) == "starting")
        }
    }

    @Test("A mismatched owner or durable stop refuses both transitions")
    func ownerAndStop() throws {
        for stopped in [false, true] {
            let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
            try db.write { db in
                try f.install(db)
                let principal = stopped ? f.principal : FloeMacSelfRequestJournalPrincipal(hostInstanceID: UUID(), processIdentifier: f.pid + 1)
                let fingerprint = try f.reserve(db, id: request, principal: principal)
                if stopped { try db.execute(sql: "UPDATE main.floe_mac_self_admission SET stop_requested_at=2 WHERE conversation_id=?", arguments: [f.conversation.uuidString]) }
                #expect(throws: FloeMacSelfRequestJournalError.admissionPhaseRefused("dispatch_claim_refused")) {
                    _ = try f.claim(db, id: request, fingerprint: fingerprint, principal: principal)
                }
                #expect(try f.phase(db) == "prepared")
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: request)?.phase == .accepted)
            }
        }
    }

    @Test("Failure between the two updates rolls back even if caller catches it")
    func innerSavepointRollback() throws {
        let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
        try db.write { db in
            try f.install(db)
            let fingerprint = try f.reserve(db, id: request)
            try db.execute(sql: """
                CREATE TRIGGER atomic_fixture_fail BEFORE UPDATE OF phase ON floe_mac_self_request_journal
                WHEN NEW.phase = 'dispatchMayHaveStarted' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                """)
            do { _ = try f.claim(db, id: request, fingerprint: fingerprint); Issue.record("injected failure was ignored") }
            catch { /* Intentionally caught: the outer transaction will commit. */ }
            #expect(try f.phase(db) == "prepared")
            #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: request)?.phase == .accepted)
        }
        try db.read { db in
            let phase = try f.phase(db)
            let journal = try FloeMacSelfRequestJournal.record(db: db, requestID: request)
            #expect(phase == "prepared")
            #expect(journal?.phase == .accepted)
        }
    }

    @Test("An outer rollback discards both provisional transitions")
    func outerRollback() throws {
        let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
        let fingerprint = try db.write { db in
            try f.install(db)
            return try f.reserve(db, id: request)
        }
        do {
            try db.write { db in
                #expect(try f.claim(db, id: request, fingerprint: fingerprint).recorded)
                throw AtomicOuterRollback()
            }
            Issue.record("outer rollback was not raised")
        } catch is AtomicOuterRollback { }
        try db.read { db in
            let phase = try f.phase(db)
            let journal = try FloeMacSelfRequestJournal.record(db: db, requestID: request)
            #expect(phase == "prepared")
            #expect(journal?.phase == .accepted)
        }
        let committed = try db.write { try f.claim($0, id: request, fingerprint: fingerprint) }
        #expect(committed.recorded)
    }

    @Test("A caller savepoint can discard a returned claim while its writer succeeds")
    func callerSavepointRollback() throws {
        let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
        let fingerprint = try db.write { db in
            try f.install(db)
            return try f.reserve(db, id: request)
        }
        let provisional = try db.write { db in
            try db.execute(sql: "SAVEPOINT caller")
            let result = try f.claim(db, id: request, fingerprint: fingerprint)
            try db.execute(sql: "ROLLBACK TO SAVEPOINT caller")
            try db.execute(sql: "RELEASE SAVEPOINT caller")
            return result
        }
        #expect(provisional.recorded)
        try db.read { db in
            let phase = try f.phase(db)
            let journal = try FloeMacSelfRequestJournal.record(db: db, requestID: request)
            #expect(phase == "prepared")
            #expect(journal?.phase == .accepted)
        }
        // A successful enclosing writer is not proof of dispatch intent.
    }

    @Test("An admission trigger that undoes the CAS rolls back both writes")
    func admissionAfterUpdateTrigger() throws {
        let db = try DatabaseQueue(), f = AtomicFixture(), request = UUID()
        try db.write { db in
            try f.install(db)
            let fingerprint = try f.reserve(db, id: request)
            try db.execute(sql: """
                CREATE TRIGGER fixture_revert_admission AFTER UPDATE OF phase ON floe_mac_self_admission
                WHEN NEW.phase = 'starting' BEGIN
                  UPDATE floe_mac_self_admission SET phase = 'prepared' WHERE conversation_id = NEW.conversation_id;
                END
                """)
            #expect(throws: FloeMacSelfRequestJournalError.corrupted("request_journal_admission_after_dispatch")) {
                _ = try f.claim(db, id: request, fingerprint: fingerprint)
            }
            #expect(try f.phase(db) == "prepared")
            #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: request)?.phase == .accepted)
        }
        try db.read { db in
            let phase = try f.phase(db)
            let journal = try FloeMacSelfRequestJournal.record(db: db, requestID: request)
            #expect(phase == "prepared")
            #expect(journal?.phase == .accepted)
        }
    }

    @Test("Two connections and two requests produce only one admitted claim")
    func concurrentDistinctRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-atomic-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        var config = Configuration(); config.busyMode = .timeout(3)
        let one = try DatabaseQueue(path: path, configuration: config)
        let two = try DatabaseQueue(path: path, configuration: config)
        let f = AtomicFixture(), a = UUID(), b = UUID()
        let fingerprints = try await one.write { db in
            try f.install(db)
            return try (f.reserve(db, id: a), f.reserve(db, id: b))
        }
        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for (queue, id, fingerprint) in [(one, a, fingerprints.0), (two, b, fingerprints.1)] {
                group.addTask {
                    do { return try queue.write { try f.claim($0, id: id, fingerprint: fingerprint).recorded } ? "recorded" : "replayed" }
                    catch FloeMacSelfRequestJournalError.admissionPhaseRefused("dispatch_claim_refused") { return "refused" }
                    catch { return "unexpected" }
                }
            }
            var values: [String] = []; for await value in group { values.append(value) }; return values
        }
        #expect(outcomes.sorted() == ["recorded", "refused"])
        try await one.read { db in
            let phase = try f.phase(db)
            #expect(phase == "starting")
            let phases = try [a, b].map { try FloeMacSelfRequestJournal.record(db: db, requestID: $0)?.phase }
            #expect(phases.filter { $0 == .dispatchMayHaveStarted }.count == 1)
            #expect(phases.filter { $0 == .accepted }.count == 1)
        }
        try one.close(); try two.close()
    }

    @Test("Two connections replay one request without a second claim")
    func concurrentSameRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-atomic-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        var config = Configuration(); config.busyMode = .timeout(3)
        let one = try DatabaseQueue(path: path, configuration: config)
        let two = try DatabaseQueue(path: path, configuration: config)
        let f = AtomicFixture(), request = UUID()
        let fingerprint = try await one.write { db in try f.install(db); return try f.reserve(db, id: request) }
        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for queue in [one, two] {
                group.addTask {
                    do { return try queue.write { try f.claim($0, id: request, fingerprint: fingerprint).recorded } ? "recorded" : "replayed" }
                    catch { return "unexpected" }
                }
            }
            var values: [String] = []; for await value in group { values.append(value) }; return values
        }
        #expect(outcomes.sorted() == ["recorded", "replayed"])
        try await one.read { db in
            let phase = try f.phase(db)
            let journal = try FloeMacSelfRequestJournal.record(db: db, requestID: request)
            #expect(phase == "starting")
            #expect(journal?.phase == .dispatchMayHaveStarted)
        }
        try one.close(); try two.close()
    }
}

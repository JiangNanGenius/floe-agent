// SPDX-License-Identifier: MPL-2.0
//
// Synthetic SQLite regression tests for the durable request identity journal.
//
// These tests use only fresh 0700 temporary directories and a synthetic
// database. They do not touch a user database, Keychain, provider, network,
// App, simulator or the shared native build resource. The tests are
// source-only until the coordinator runs the SwiftPM target; the production
// authority gate remains closed and no runtime call site exists.
//
// The atomic acceptance/dispatch tests use a test-only raw SQL update to
// simulate the future admission same-connection helper. They prove the
// journal's writes join the caller's transaction; they do not prove the
// current `FloeMacSelfAdmissionStore` API co-commits with the journal. That
// helper does not exist yet and remains a documented integration gap.

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

// MARK: - Fixture

private struct RequestJournalFixture {
    let root: URL
    let databaseURL: URL
    let database: DatabaseManager
    let launch: SQLiteRunLaunchStore
    let admission: FloeMacSelfAdmissionStore
    let workspaces: SQLiteWorkspaceStore
    let conversations: SQLiteConversationStore
    let runs: SQLiteRunStore
}

private struct RequestJournalTestRollback: Error {}

private func makeRequestJournalRoot(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "floe-mac-request-journal-\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

private func makeRequestJournalDatabase(
    at databaseURL: URL
) async throws -> DatabaseManager {
    let database = try DatabaseManager(path: databaseURL)
    try await database.migrate()
    try await database.writer { db in
        try FloeMacSelfAdmissionStore.installSchema(in: db)
        try FloeMacSelfRequestJournal.installSchema(in: db)
    }
    return database
}

private func makeRequestJournalFixture(
    prefix: String
) async throws -> RequestJournalFixture {
    let root = try makeRequestJournalRoot(prefix: prefix)
    let databaseURL = root.appendingPathComponent("request-journal.sqlite")
    do {
        let database = try await makeRequestJournalDatabase(at: databaseURL)
        return RequestJournalFixture(
            root: root,
            databaseURL: databaseURL,
            database: database,
            launch: SQLiteRunLaunchStore(database: database),
            admission: FloeMacSelfAdmissionStore(
                database: database,
                authorityLock: nil
            ),
            workspaces: SQLiteWorkspaceStore(database: database),
            conversations: SQLiteConversationStore(database: database),
            runs: SQLiteRunStore(database: database)
        )
    } catch {
        Issue.record("Request-journal fixture retained at \(root.path): \(error)")
        throw error
    }
}

private func withRequestJournalFixture(
    prefix: String,
    _ body: (RequestJournalFixture) async throws -> Void
) async throws {
    let fixture = try await makeRequestJournalFixture(prefix: prefix)
    do {
        try await body(fixture)
    } catch {
        try? await fixture.database.close()
        Issue.record(
            "Request-journal fixture retained at \(fixture.root.path): \(error)"
        )
        throw error
    }
    try await fixture.database.close()
    try? FileManager.default.removeItem(at: fixture.root)
}

private func requestJournalError(
    _ operation: () async throws -> Void
) async -> FloeMacSelfRequestJournalError? {
    do {
        try await operation()
        return nil
    } catch let error as FloeMacSelfRequestJournalError {
        return error
    } catch {
        return nil
    }
}

private func requestJournalIsTerminalNotProven(
    _ error: FloeMacSelfRequestJournalError?
) -> Bool {
    guard let error else { return false }
    if case .terminalNotProven = error { return true }
    return false
}

private func requestJournalScope(
    operation: FloeMacSelfRequestJournalOperation = .startRun,
    taskID: UUID = UUID(),
    workspaceID: UUID,
    conversationID: UUID,
    runID: UUID,
    generation: Int = 1
) -> FloeMacSelfRequestJournalScope {
    FloeMacSelfRequestJournalScope(
        taskID: taskID,
        workspaceID: workspaceID,
        conversationID: conversationID,
        runID: runID,
        runGeneration: generation,
        operation: operation
    )
}

private func requestJournalPrincipal(
    hostID: UUID = UUID(),
    pid: Int32 = 4242
) -> FloeMacSelfRequestJournalPrincipal {
    FloeMacSelfRequestJournalPrincipal(
        hostInstanceID: hostID,
        processIdentifier: pid
    )
}

private func requestJournalOwner() -> FloeMacSelfHostIdentity {
    FloeMacSelfHostIdentity(
        processIdentifier: 4242,
        displayName: "RequestJournalFixture"
    )
}

private func requestJournalAdmit(
    _ fixture: RequestJournalFixture,
    conversationID: UUID,
    runID: UUID
) async throws -> FloeMacSelfAdmissionRecord {
    try await fixture.admission.admit(
        conversationID: conversationID,
        runID: runID,
        owner: requestJournalOwner()
    )
}

private func requestJournalPrepare(
    _ fixture: RequestJournalFixture,
    conversationID: UUID,
    runID: UUID,
    workspaceID: UUID,
    goal: String = "Synthetic journal goal"
) async throws -> PreparedRun {
    try await fixture.workspaces.saveWorkspace(WorkspaceRecord(
        id: workspaceID,
        name: "Request journal workspace",
        rootBookmark: Data(),
        kind: .project
    ))
    return try await fixture.launch.prepare(RunLaunchRequest(
        newConversationID: conversationID,
        conversationTitle: "Request journal",
        runID: runID,
        goal: goal,
        workspaceID: workspaceID,
        conversationMode: "chat",
        startedAt: Date()
    ))
}

private func requestJournalAppendCompletedTerminal(
    _ fixture: RequestJournalFixture,
    conversationID: UUID,
    runID: UUID
) async throws -> UUID {
    let assistantID = UUID()
    try await fixture.conversations.appendMessage(PersistedMessage(
        id: assistantID,
        conversationID: conversationID,
        role: "assistant",
        content: "Synthetic journal answer",
        createdAt: Date(),
        parts: [],
        runID: runID
    ))
    try await fixture.runs.updateRunState(
        id: runID,
        state: "completed",
        endedAt: Date()
    )
    _ = try await fixture.runs.appendEvent(
        runID: runID,
        kind: .terminal,
        payloadJSON: #"{"stopReason":"endTurn","finalMessageID":"\#(assistantID.uuidString)"}"#
    )
    return assistantID
}

private func requestJournalAppendFailedTerminal(
    _ fixture: RequestJournalFixture,
    runID: UUID
) async throws {
    try await fixture.runs.updateRunState(
        id: runID,
        state: "failed",
        endedAt: Date()
    )
    _ = try await fixture.runs.appendEvent(
        runID: runID,
        kind: .status,
        payloadJSON: #"{"state":"failed","reason":"synthetic_journal"}"#
    )
}

private func requestJournalReadPhase(
    _ fixture: RequestJournalFixture,
    requestID: UUID
) async throws -> FloeMacSelfRequestJournalPhase? {
    try await fixture.database.reader { db in
        try FloeMacSelfRequestJournal.record(db: db, requestID: requestID)?.phase
    }
}

private func requestJournalReadAdmissionPhase(
    _ fixture: RequestJournalFixture,
    conversationID: UUID
) async throws -> String? {
    try await fixture.database.reader { db in
        try String.fetchOne(
            db,
            sql: """
                SELECT phase FROM floe_mac_self_admission
                WHERE conversation_id = ?
                """,
            arguments: [conversationID.uuidString]
        )
    }
}

/// Test-only simulation of the future admission same-connection helper. It
/// writes the admission row through the caller's `Database` so both writes
/// share one transaction; it is not the production admission API.
private func requestJournalInsertAdmissionRow(
    db: Database,
    conversationID: UUID,
    runID: UUID,
    epoch: Int,
    phase: String,
    stopRequestedAt: Double? = nil
) throws {
    let now = Date().timeIntervalSince1970
    try db.execute(
        sql: """
            INSERT INTO floe_mac_self_admission (
                conversation_id, run_id, phase, epoch, admitted_at, updated_at,
                owner_host_id, owner_pid, stop_requested_at, stop_epoch,
                previous_run_id, previous_phase, detail
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL, NULL)
            """,
        arguments: [
            conversationID.uuidString,
            runID.uuidString,
            phase,
            epoch,
            now,
            now,
            UUID().uuidString,
            4242,
            stopRequestedAt
        ]
    )
}

/// Test-only simulation of the future admission same-connection dispatch
/// helper's admission CAS.
private func requestJournalUpdateAdmissionPhase(
    db: Database,
    conversationID: UUID,
    runID: UUID,
    from: String,
    to: String
) throws {
    try db.execute(
        sql: """
            UPDATE floe_mac_self_admission
            SET phase = ?, updated_at = ?
            WHERE conversation_id = ? AND run_id = ? AND phase = ?
            """,
        arguments: [
            to,
            Date().timeIntervalSince1970,
            conversationID.uuidString,
            runID.uuidString,
            from
        ]
    )
    guard db.changesCount == 1 else {
        throw FloeMacSelfRequestJournalError.admissionPhaseRefused(from)
    }
}

private func requestJournalInsertSyntheticTerminalRow(
    db: Database,
    scope: FloeMacSelfRequestJournalScope,
    principal: FloeMacSelfRequestJournalPrincipal
) throws {
    let now = Date().timeIntervalSince1970
    try db.execute(
        sql: """
            INSERT INTO floe_mac_self_request_journal (
                request_id, journal_id, protocol_version, operation, task_id,
                workspace_id, conversation_id, run_id, run_generation,
                principal_host_id, principal_pid, payload_fingerprint,
                payload_byte_count, phase, accepted_at, updated_at,
                dispatch_recorded_at, terminal_recorded_at, terminal_outcome,
                terminal_run_state, terminal_event_sequence, unknown_reason
            ) VALUES (?, ?, 1, 'run.start', ?, ?, ?, ?, 1, ?, ?, ?, 0,
                      'terminalConfirmed', ?, ?, NULL, ?, 'completed',
                      'completed', 1, NULL)
            """,
        arguments: [
            UUID().uuidString,
            UUID().uuidString,
            scope.taskID.uuidString,
            scope.workspaceID.uuidString,
            scope.conversationID.uuidString,
            UUID().uuidString,
            principal.hostInstanceID.uuidString,
            Int(principal.processIdentifier),
            String(repeating: "a", count: 64),
            now,
            now,
            now
        ]
    )
}

// MARK: - Tests

@Suite("Mac self-core request identity journal")
struct RequestJournalTests {

    // Fail-closed coverage for the interim source-only implementation. The
    // earlier positive integration tests below are intentionally retained as
    // pending expectations; they cannot pass until real admission and terminal
    // binding are implemented.
    @Test("Schema installation refuses autocommit and leaves no objects")
    func schemaInstallRequiresTransaction() throws {
        let queue = try DatabaseQueue()
        try queue.writeWithoutTransaction { db in
            do {
                try FloeMacSelfRequestJournal.installSchema(in: db)
                Issue.record("schema unexpectedly installed outside a transaction")
            } catch {
                #expect(error as? FloeMacSelfRequestJournalError == .notInsideTransaction)
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name LIKE 'floe_mac_self_%'")
            #expect(count == 0)
        }
    }

    @Test("A future schema version is refused before any journal DDL")
    func futureSchemaDoesNotCreateObjects() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE floe_mac_self_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO floe_mac_self_metadata VALUES ('request_journal_schema_version', '2')")
        }
        do {
            try queue.write { db in
                try FloeMacSelfRequestJournal.installSchema(in: db)
            }
            Issue.record("future schema unexpectedly accepted")
        } catch {
            #expect(error as? FloeMacSelfRequestJournalError == .schemaUnsupported("request_journal_version"))
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name LIKE 'floe_mac_self_request_journal%'")
            #expect(count == 0)
        }
    }

    @Test("Column-compatible tables lacking PK, UNIQUE or CHECK are refused")
    func malformedJournalSchemaIsRejected() throws {
        let replacements = [
            ("request_id TEXT PRIMARY KEY NOT NULL", "request_id TEXT NOT NULL"),
            // This is a legal SQLite type, not PRIMARY KEY / NOT NULL.
            // Deleting all whitespace from schema SQL would hide the change.
            ("request_id TEXT PRIMARY KEY NOT NULL", "request_id TEXTPRIMARYKEYNOTNULL"),
            ("journal_id TEXT NOT NULL UNIQUE", "journal_id TEXT NOT NULL"),
            ("CHECK (", "/* removed CHECK */ ("),
        ]
        for (old, replacement) in replacements {
            let queue = try DatabaseQueue()
            try queue.write { db in
                try FloeMacSelfRequestJournal.installSchema(in: db)
                let storedSQL = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE name = 'floe_mac_self_request_journal'")
                let sql = try #require(storedSQL)
                #expect(sql.contains(old))
                try db.execute(sql: "DROP TABLE floe_mac_self_request_journal")
                // The CHECK case is represented by a syntactically valid
                // replacement of the full constraint, not a harmless comment.
                let malformed: String
                if old == "CHECK (" {
                    let start = try #require(sql.range(of: " CHECK ("))
                    let end = try #require(sql.range(of: "),", range: start.lowerBound..<sql.endIndex))
                    malformed = sql.replacingCharacters(in: start.lowerBound..<end.upperBound, with: ",")
                } else {
                    malformed = sql.replacingOccurrences(of: old, with: replacement)
                }
                #expect(malformed != sql)
                try db.execute(sql: malformed)
                try db.execute(sql: "CREATE INDEX floe_mac_self_request_journal_conversation ON floe_mac_self_request_journal (conversation_id, phase)")
                if replacement == "request_id TEXTPRIMARYKEYNOTNULL" {
                    let infoRow = try Row.fetchOne(db, sql: "SELECT type, \"notnull\", pk FROM pragma_table_info('floe_mac_self_request_journal') WHERE name = 'request_id'")
                    let info = try #require(infoRow)
                    let type: String = info["type"]
                    let notNull: Int = info["notnull"]
                    let primaryKey: Int = info["pk"]
                    #expect(type == "TEXTPRIMARYKEYNOTNULL")
                    #expect(notNull == 0)
                    #expect(primaryKey == 0)
                }
            }
            do {
                try queue.write { db in try FloeMacSelfRequestJournal.installSchema(in: db) }
                Issue.record("malformed schema unexpectedly accepted")
            } catch {
                #expect(error as? FloeMacSelfRequestJournalError == .schemaUnsupported("request_journal_schema"))
            }
        }
    }

    @Test("Mixed-case trigger targets on metadata and journal are refused")
    func mixedCaseTriggersAreRejected() throws {
        for target in ["FLOE_MAC_SELF_METADATA", "Floe_Mac_Self_Request_Journal"] {
            for prefix in ["", "TEMP "] {
                let queue = try DatabaseQueue()
                try queue.write { db in
                    try FloeMacSelfRequestJournal.installSchema(in: db)
                    // Both names and prefixes are fixed test constants.
                    try db.execute(sql: "CREATE \(prefix)TRIGGER hidden AFTER INSERT ON main.\(target) BEGIN SELECT 1; END")
                }
                do {
                    try queue.write { db in try FloeMacSelfRequestJournal.installSchema(in: db) }
                    Issue.record("mixed-case trigger unexpectedly accepted for \(target)")
                } catch {
                    #expect(error as? FloeMacSelfRequestJournalError == .schemaUnsupported("request_journal_trigger"))
                }
            }
        }
    }

    @Test("Bootstrap creates main schema even with temporary name shadows")
    func tempShadowsCannotRedirectBootstrap() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TEMP TABLE floe_mac_self_metadata (key TEXT, value TEXT)")
            try db.execute(sql: "CREATE TEMP TABLE floe_mac_self_request_journal (request_id TEXT)")
            try FloeMacSelfRequestJournal.installSchema(in: db)
            let mainVersion = try String.fetchOne(db, sql: "SELECT value FROM main.floe_mac_self_metadata WHERE key = 'request_journal_schema_version'")
            let tempCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM temp.floe_mac_self_metadata")
            let mainTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.sqlite_schema WHERE type = 'table' AND name = 'floe_mac_self_request_journal'")
            #expect(mainVersion == "1")
            #expect(tempCount == 0)
            #expect(mainTable == 1)
        }
    }

    @Test("Temporary shadow tables never supply admission or journal storage")
    func tempShadowsCannotRedirectJournal() throws {
        let queue = try DatabaseQueue()
        let conversation = UUID()
        let realRun = UUID()
        let shadowRun = UUID()
        let scope = requestJournalScope(workspaceID: UUID(), conversationID: conversation, runID: shadowRun)
        let principal = requestJournalPrincipal()
        let request = UUID()
        try queue.write { db in
            try FloeMacSelfAdmissionStore.installSchema(in: db)
            try FloeMacSelfRequestJournal.installSchema(in: db)
            try requestJournalInsertAdmissionRow(db: db, conversationID: conversation, runID: realRun, epoch: 1, phase: "prepared")
            try db.execute(sql: "CREATE TEMP TABLE floe_mac_self_metadata (key TEXT, value TEXT)")
            try db.execute(sql: "INSERT INTO temp.floe_mac_self_metadata VALUES ('request_journal_schema_version', '999')")
            try db.execute(sql: "CREATE TEMP TABLE floe_mac_self_request_journal (request_id TEXT)")
            try db.execute(sql: "CREATE TEMP TABLE floe_mac_self_admission (conversation_id TEXT, run_id TEXT, epoch INTEGER, phase TEXT, stop_requested_at REAL)")
            try db.execute(sql: "INSERT INTO temp.floe_mac_self_admission VALUES (?, ?, 1, 'prepared', NULL)", arguments: [conversation.uuidString, shadowRun.uuidString])
            // Only main metadata and main schema should be consulted.
            try FloeMacSelfRequestJournal.installSchema(in: db)
            do {
                _ = try FloeMacSelfRequestJournal.reserve(db: db, requestID: request, scope: scope, principal: principal, payload: Data("fixture".utf8))
                Issue.record("temporary admission unexpectedly accepted")
            } catch {
                #expect(error as? FloeMacSelfRequestJournalError == .admissionScopeMismatch(conversation))
            }
            try db.execute(sql: "UPDATE main.floe_mac_self_admission SET run_id = ? WHERE conversation_id = ?", arguments: [shadowRun.uuidString, conversation.uuidString])
            let accepted = try FloeMacSelfRequestJournal.reserve(db: db, requestID: request, scope: scope, principal: principal, payload: Data("fixture".utf8))
            _ = try FloeMacSelfRequestJournal.markUnknown(db: db, requestID: request, scope: scope, principal: principal, fingerprint: accepted.record.fingerprint, reason: .recoveryReconciliationRequired)
            #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: request)?.phase == .unknown)
            #expect(try FloeMacSelfRequestJournal.records(db: db, conversationID: conversation, limit: 10).count == 1)
            let realCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.floe_mac_self_request_journal")
            let tempCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM temp.floe_mac_self_request_journal")
            #expect(realCount == 1)
            #expect(tempCount == 0)
        }
    }

    @Test("Unsupported protocol and unbound terminal rows fail closed")
    func corruptAndFutureRowsAreRejected() throws {
        let queue = try DatabaseQueue()
        let conversation = UUID()
        let scope = requestJournalScope(workspaceID: UUID(), conversationID: conversation, runID: UUID())
        let principal = requestJournalPrincipal()
        try queue.write { db in
            try FloeMacSelfRequestJournal.installSchema(in: db)
            try requestJournalInsertSyntheticTerminalRow(db: db, scope: scope, principal: principal)
            try db.execute(sql: "UPDATE floe_mac_self_request_journal SET protocol_version = 2")
        }
        try queue.read { db in
            do {
                _ = try FloeMacSelfRequestJournal.records(db: db, conversationID: conversation, limit: 10)
                Issue.record("future protocol unexpectedly accepted")
            } catch {
                #expect(error as? FloeMacSelfRequestJournalError == .corrupted("request_journal_protocol"))
            }
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE floe_mac_self_request_journal SET protocol_version = 1, terminal_outcome = 'unknown', terminal_run_state = 'failed'")
        }
        try queue.read { db in
            do {
                _ = try FloeMacSelfRequestJournal.records(db: db, conversationID: conversation, limit: 10)
                Issue.record("unbound terminal unexpectedly accepted")
            } catch {
                #expect(error as? FloeMacSelfRequestJournalError == .corrupted("request_journal_terminal_unbound"))
            }
        }
    }

    @Test("Two request IDs cannot obtain dispatch or terminal authority")
    func multipleRequestsCannotClaimDispatchOrTerminal() throws {
        let queue = try DatabaseQueue()
        let conversation = UUID()
        let run = UUID()
        let scope = requestJournalScope(workspaceID: UUID(), conversationID: conversation, runID: run)
        let principal = requestJournalPrincipal()
        let requests = [UUID(), UUID()]
        try queue.write { db in
            try FloeMacSelfAdmissionStore.installSchema(in: db)
            try FloeMacSelfRequestJournal.installSchema(in: db)
            try requestJournalInsertAdmissionRow(db: db, conversationID: conversation, runID: run, epoch: 1, phase: "prepared")
            for request in requests {
                let accepted = try FloeMacSelfRequestJournal.reserve(db: db, requestID: request, scope: scope, principal: principal, payload: Data("fixture".utf8))
                do {
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(db: db, requestID: request, scope: scope, principal: principal, fingerprint: accepted.record.fingerprint)
                    Issue.record("dispatch unexpectedly authorized")
                } catch {
                    #expect(error as? FloeMacSelfRequestJournalError == .notImplemented("atomic_admission_dispatch"))
                }
                do {
                    _ = try FloeMacSelfRequestJournal.recordTerminal(db: db, requestID: request, scope: scope, principal: principal, fingerprint: accepted.record.fingerprint, expectedUserMessageID: UUID())
                    Issue.record("terminal unexpectedly confirmed")
                } catch {
                    #expect(error as? FloeMacSelfRequestJournalError == .notImplemented("request_terminal_binding"))
                }
                #expect(try FloeMacSelfRequestJournal.record(db: db, requestID: request)?.phase == .accepted)
            }
        }
    }
    @Test("Schema install is idempotent and rejects a future version")
    func schemaInstallIsIdempotentAndVersioned() async throws {
        try await withRequestJournalFixture(prefix: "schema") { fixture in
            #expect(!FloeMacSelfRequestJournal.productionWiringAvailable)
            try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.installSchema(in: db)
            }
            try await fixture.database.writer { db in
                try db.execute(
                    sql: """
                        UPDATE floe_mac_self_metadata SET value = '2'
                        WHERE key = 'request_journal_schema_version'
                        """
                )
            }
            let error = await requestJournalError {
                try await fixture.database.writer { db in
                    try FloeMacSelfRequestJournal.installSchema(in: db)
                }
            }
            #expect(
                error == .schemaUnsupported("request_journal_version")
            )
        }
    }

    @Test("Journal writes require the caller's active transaction")
    func reserveRequiresCallerTransaction() async throws {
        let root = try makeRequestJournalRoot(prefix: "tx-guard")
        let databaseURL = root.appendingPathComponent("journal.sqlite")
        let database = try await makeRequestJournalDatabase(at: databaseURL)
        let admission = FloeMacSelfAdmissionStore(
            database: database,
            authorityLock: nil
        )
        let conversationID = UUID()
        let runID = UUID()
        _ = try await admission.admit(
            conversationID: conversationID,
            runID: runID,
            owner: requestJournalOwner()
        )
        try await database.close()

        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            let scope = requestJournalScope(
                workspaceID: UUID(),
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("transaction guard payload".utf8)

            do {
                try await queue.writeWithoutTransaction { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: payload
                    )
                    Issue.record(
                        "reserve must refuse a connection outside a transaction"
                    )
                }
            } catch let error as FloeMacSelfRequestJournalError {
                #expect(error == .notInsideTransaction)
            }

            let countAfterRefusal = try await queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                ) ?? -1
            }
            #expect(countAfterRefusal == 0)

            let reservation = try await queue.write { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(reservation.disposition == .recorded)
            try queue.close()
            try? FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Request-journal fixture retained at \(root.path): \(error)")
            throw error
        }
    }

    @Test("Reserve replays the exact identity and rejects changed identity")
    func reserveReplaysAndRejectsChangedIdentity() async throws {
        try await withRequestJournalFixture(prefix: "identity") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            let taskID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                taskID: taskID,
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("same logical goal".utf8)

            let first = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(first.disposition == .recorded)
            #expect(first.record.phase == .accepted)
            #expect(first.record.state == .accepted)
            #expect(!first.record.isTerminalProven)
            #expect(!first.record.mayExecuteAgainAutomatically)

            let replay = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(replay.disposition == .replayed)
            #expect(replay.record.journalID == first.record.journalID)
            #expect(replay.record.acceptedAt == first.record.acceptedAt)

            let rowCount = try await fixture.database.reader { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                ) ?? -1
            }
            #expect(rowCount == 1)

            let changedPayload = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: Data("different payload".utf8)
                    )
                }
            }
            #expect(
                changedPayload == .identityConflict(
                    requestID: requestID,
                    field: "payload"
                )
            )

            let changedRun = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: requestJournalScope(
                            taskID: taskID,
                            workspaceID: workspaceID,
                            conversationID: conversationID,
                            runID: UUID()
                        ),
                        principal: principal,
                        payload: payload
                    )
                }
            }
            #expect(
                changedRun == .identityConflict(
                    requestID: requestID,
                    field: "run_id"
                )
            )

            let changedGeneration = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: requestJournalScope(
                            taskID: taskID,
                            workspaceID: workspaceID,
                            conversationID: conversationID,
                            runID: runID,
                            generation: 2
                        ),
                        principal: principal,
                        payload: payload
                    )
                }
            }
            #expect(
                changedGeneration == .identityConflict(
                    requestID: requestID,
                    field: "run_generation"
                )
            )

            let changedPrincipal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: requestJournalPrincipal(
                            hostID: principal.hostInstanceID,
                            pid: principal.processIdentifier + 1
                        ),
                        payload: payload
                    )
                }
            }
            #expect(
                changedPrincipal == .identityConflict(
                    requestID: requestID,
                    field: "principal_pid"
                )
            )

            let changedOperation = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: requestJournalScope(
                            operation: .cancelRun,
                            taskID: taskID,
                            workspaceID: workspaceID,
                            conversationID: conversationID,
                            runID: runID
                        ),
                        principal: principal,
                        payload: payload
                    )
                }
            }
            #expect(
                changedOperation == .identityConflict(
                    requestID: requestID,
                    field: "operation"
                )
            )

            let unchanged = try #require(
                try await fixture.database.reader { db in
                    try FloeMacSelfRequestJournal.record(
                        db: db,
                        requestID: requestID
                    )
                }
            )
            #expect(unchanged.journalID == first.record.journalID)
            #expect(unchanged.phase == .accepted)
            #expect(unchanged.fingerprint == first.record.fingerprint)
        }
    }

    @Test("Concurrent identical reservations commit exactly one row")
    func concurrentIdenticalReservationsCommitOneRow() async throws {
        try await withRequestJournalFixture(prefix: "race") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: UUID(),
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("concurrent identical request".utf8)
            let database = fixture.database

            let results = try await withThrowingTaskGroup(
                of: FloeMacSelfRequestJournalReservation.self
            ) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await database.writer { db in
                            try FloeMacSelfRequestJournal.reserve(
                                db: db,
                                requestID: requestID,
                                protocolVersion: 1,
                                scope: scope,
                                principal: principal,
                                payload: payload
                            )
                        }
                    }
                }
                var values: [FloeMacSelfRequestJournalReservation] = []
                for try await value in group {
                    values.append(value)
                }
                return values
            }

            #expect(results.count == 2)
            #expect(results.filter { $0.disposition == .recorded }.count == 1)
            #expect(results.filter { $0.disposition == .replayed }.count == 1)
            #expect(Set(results.map(\.record.journalID)).count == 1)

            let rowCount = try await fixture.database.reader { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                ) ?? -1
            }
            #expect(rowCount == 1)
        }
    }

    @Test("Acceptance and an admission insert roll back in the same transaction")
    func acceptanceAndAdmissionRollBackTogether() async throws {
        try await withRequestJournalFixture(prefix: "accept-tx") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let scope = requestJournalScope(
                workspaceID: UUID(),
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("atomic acceptance".utf8)

            do {
                try await fixture.database.writer { db in
                    try requestJournalInsertAdmissionRow(
                        db: db,
                        conversationID: conversationID,
                        runID: runID,
                        epoch: 1,
                        phase: "admitting"
                    )
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: payload
                    )
                    throw RequestJournalTestRollback()
                }
            } catch is RequestJournalTestRollback {
                // Expected: the caller aborted the whole transaction.
            }

            let countsAfterRollback = try await fixture.database.reader { db in
                (
                    admission: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_admission"
                    ) ?? -1,
                    journal: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                    ) ?? -1
                )
            }
            #expect(countsAfterRollback.admission == 0)
            #expect(countsAfterRollback.journal == 0)

            let committed = try await fixture.database.writer { db in
                try requestJournalInsertAdmissionRow(
                    db: db,
                    conversationID: conversationID,
                    runID: runID,
                    epoch: 1,
                    phase: "admitting"
                )
                return try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(committed.disposition == .recorded)

            let countsAfterCommit = try await fixture.database.reader { db in
                (
                    admission: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_admission"
                    ) ?? -1,
                    journal: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                    ) ?? -1
                )
            }
            #expect(countsAfterCommit.admission == 1)
            #expect(countsAfterCommit.journal == 1)
        }
    }

    @Test("Dispatch and an admission CAS roll back together and are not terminal")
    func dispatchAndAdmissionRollBackTogether() async throws {
        try await withRequestJournalFixture(prefix: "dispatch-tx") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("atomic dispatch".utf8)
            let prepared = try await requestJournalPrepare(
                fixture,
                conversationID: conversationID,
                runID: runID,
                workspaceID: workspaceID
            )
            try await fixture.admission.markPrepared(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )
            let accepted = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            let fingerprint = accepted.record.fingerprint

            do {
                try await fixture.database.writer { db in
                    try requestJournalUpdateAdmissionPhase(
                        db: db,
                        conversationID: conversationID,
                        runID: runID,
                        from: "prepared",
                        to: "starting"
                    )
                    let reservation = try FloeMacSelfRequestJournal
                        .recordDispatchIntent(
                            db: db,
                            requestID: requestID,
                            protocolVersion: 1,
                            scope: scope,
                            principal: principal,
                            fingerprint: fingerprint
                        )
                    #expect(reservation.recorded)
                    throw RequestJournalTestRollback()
                }
            } catch is RequestJournalTestRollback {
                // Expected: both the admission CAS and the journal CAS abort.
            }

            #expect(
                try await requestJournalReadAdmissionPhase(
                    fixture,
                    conversationID: conversationID
                ) == "prepared"
            )
            #expect(
                try await requestJournalReadPhase(
                    fixture,
                    requestID: requestID
                ) == .accepted
            )

            let committedDispatch = try await fixture.database.writer { db in
                try requestJournalUpdateAdmissionPhase(
                    db: db,
                    conversationID: conversationID,
                    runID: runID,
                    from: "prepared",
                    to: "starting"
                )
                return try FloeMacSelfRequestJournal.recordDispatchIntent(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint
                )
            }
            #expect(committedDispatch.recorded)
            #expect(
                committedDispatch.record.phase == .dispatchMayHaveStarted
            )
            #expect(
                committedDispatch.record.state == .dispatchMayHaveStarted
            )
            #expect(!committedDispatch.record.isTerminalProven)

            let replayDispatch = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordDispatchIntent(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint
                )
            }
            #expect(!replayDispatch.recorded)
            #expect(
                replayDispatch.record.dispatchRecordedAt
                    == committedDispatch.record.dispatchRecordedAt
            )

            let unprovenTerminal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordTerminal(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint,
                        expectedUserMessageID: prepared.userMessage.id
                    )
                }
            }
            #expect(requestJournalIsTerminalNotProven(unprovenTerminal))
            #expect(
                try await requestJournalReadPhase(
                    fixture,
                    requestID: requestID
                ) == .dispatchMayHaveStarted
            )

            let unknown = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.markUnknown(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    reason: .dispatchOutcomeUnknown
                )
            }
            #expect(unknown.changed)
            #expect(unknown.record.phase == .unknown)
            #expect(
                unknown.record.state
                    == .unknown(reason: .dispatchOutcomeUnknown)
            )

            let illegal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint
                    )
                }
            }
            #expect(
                illegal == .illegalTransition(
                    from: "unknown",
                    to: "dispatchMayHaveStarted"
                )
            )

            let cancelScope = requestJournalScope(
                operation: .cancelRun,
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let cancelRequestID = UUID()
            let cancelReservation = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: cancelRequestID,
                    protocolVersion: 1,
                    scope: cancelScope,
                    principal: principal,
                    payload: Data("cancel request".utf8)
                )
            }
            let unsupported = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(
                        db: db,
                        requestID: cancelRequestID,
                        protocolVersion: 1,
                        scope: cancelScope,
                        principal: principal,
                        fingerprint: cancelReservation.record.fingerprint
                    )
                }
            }
            #expect(unsupported == .unsupportedOperation("run.cancel"))
        }
    }

    @Test("Terminal requires the strict durable probe and is immutable")
    func terminalRequiresStrictDurableProofAndIsImmutable() async throws {
        try await withRequestJournalFixture(prefix: "terminal") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("terminal request".utf8)
            let prepared = try await requestJournalPrepare(
                fixture,
                conversationID: conversationID,
                runID: runID,
                workspaceID: workspaceID
            )
            try await fixture.admission.markPrepared(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )
            let accepted = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            let fingerprint = accepted.record.fingerprint
            _ = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordDispatchIntent(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint
                )
            }
            _ = try await fixture.admission.requestDispatch(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )
            _ = try await requestJournalAppendCompletedTerminal(
                fixture,
                conversationID: conversationID,
                runID: runID
            )

            let wrongLaunchMessage = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordTerminal(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint,
                        expectedUserMessageID: UUID()
                    )
                }
            }
            #expect(requestJournalIsTerminalNotProven(wrongLaunchMessage))
            #expect(
                try await requestJournalReadPhase(
                    fixture,
                    requestID: requestID
                ) == .dispatchMayHaveStarted
            )

            let confirmed = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordTerminal(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    expectedUserMessageID: prepared.userMessage.id
                )
            }
            #expect(confirmed.newlyConfirmed)
            #expect(confirmed.record.phase == .terminalConfirmed)
            #expect(confirmed.record.isTerminalProven)
            #expect(confirmed.record.terminalOutcome == .completed)
            #expect(confirmed.record.terminalRunState == "completed")
            #expect(confirmed.record.terminalEventSequence != nil)

            let replay = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordTerminal(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    expectedUserMessageID: prepared.userMessage.id
                )
            }
            #expect(!replay.newlyConfirmed)
            #expect(replay.record.journalID == confirmed.record.journalID)

            let dispatchAfterTerminal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint
                    )
                }
            }
            #expect(
                dispatchAfterTerminal == .illegalTransition(
                    from: "terminalConfirmed",
                    to: "dispatchMayHaveStarted"
                )
            )

            let unknownAfterTerminal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.markUnknown(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint,
                        reason: .hostClosedUnconfirmed
                    )
                }
            }
            #expect(
                unknownAfterTerminal == .illegalTransition(
                    from: "terminalConfirmed",
                    to: "unknown"
                )
            )
        }
    }

    @Test("Unknown blocks re-execution and a later strict proof can confirm it")
    func unknownBlocksReexecutionAndLateProofCanConfirm() async throws {
        try await withRequestJournalFixture(prefix: "unknown") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("unknown request".utf8)
            let prepared = try await requestJournalPrepare(
                fixture,
                conversationID: conversationID,
                runID: runID,
                workspaceID: workspaceID
            )
            try await fixture.admission.markPrepared(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )
            let accepted = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            let fingerprint = accepted.record.fingerprint
            _ = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordDispatchIntent(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint
                )
            }
            _ = try await fixture.admission.requestDispatch(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )

            // A terminal-looking run row without a terminal event is not
            // proof. The probe must refuse to confirm it.
            try await fixture.runs.updateRunState(
                id: runID,
                state: "completed",
                endedAt: Date()
            )
            let terminalLooking = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordTerminal(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint,
                        expectedUserMessageID: prepared.userMessage.id
                    )
                }
            }
            #expect(requestJournalIsTerminalNotProven(terminalLooking))

            let firstUnknown = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.markUnknown(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    reason: .runtimeEndedWithoutProof
                )
            }
            #expect(firstUnknown.changed)
            #expect(
                firstUnknown.record.state
                    == .unknown(reason: .runtimeEndedWithoutProof)
            )

            let secondUnknown = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.markUnknown(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    reason: .hostClosedUnconfirmed
                )
            }
            #expect(!secondUnknown.changed)
            #expect(
                secondUnknown.record.state
                    == .unknown(reason: .runtimeEndedWithoutProof)
            )

            let replayed = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(replayed.disposition == .replayed)
            #expect(
                replayed.record.state
                    == .unknown(reason: .runtimeEndedWithoutProof)
            )
            #expect(!replayed.record.mayExecuteAgainAutomatically)

            let illegal = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint
                    )
                }
            }
            #expect(
                illegal == .illegalTransition(
                    from: "unknown",
                    to: "dispatchMayHaveStarted"
                )
            )

            // A later strict proof may still confirm the exact run; it never
            // re-executes the request.
            try await requestJournalAppendFailedTerminal(
                fixture,
                runID: runID
            )
            let lateProof = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordTerminal(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    expectedUserMessageID: prepared.userMessage.id
                )
            }
            #expect(lateProof.newlyConfirmed)
            #expect(lateProof.record.terminalOutcome == .failed)
            #expect(lateProof.record.isTerminalProven)
        }
    }

    @Test("Reopening the database preserves unresolved facts")
    func reopenPreservesUnresolvedFacts() async throws {
        let fixture = try await makeRequestJournalFixture(prefix: "reopen")
        var activeDatabase: DatabaseManager? = fixture.database
        do {
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("reopen request".utf8)
            _ = try await requestJournalPrepare(
                fixture,
                conversationID: conversationID,
                runID: runID,
                workspaceID: workspaceID
            )
            try await fixture.admission.markPrepared(
                conversationID: conversationID,
                runID: runID,
                epoch: 1
            )
            let accepted = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            let fingerprint = accepted.record.fingerprint
            _ = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.recordDispatchIntent(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint
                )
            }
            _ = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.markUnknown(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    fingerprint: fingerprint,
                    reason: .recoveryReconciliationRequired
                )
            }

            try await fixture.database.close()
            activeDatabase = nil

            let reopened = try DatabaseManager(path: fixture.databaseURL)
            activeDatabase = reopened
            try await reopened.migrate()
            let restored = try #require(
                try await reopened.reader { db in
                    try FloeMacSelfRequestJournal.record(
                        db: db,
                        requestID: requestID
                    )
                }
            )
            #expect(restored.phase == .unknown)
            #expect(
                restored.state
                    == .unknown(reason: .recoveryReconciliationRequired)
            )
            #expect(!restored.mayExecuteAgainAutomatically)

            let replay = try await reopened.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(replay.disposition == .replayed)
            #expect(replay.record.phase == .unknown)

            let illegal = await requestJournalError {
                try await reopened.writer { db in
                    _ = try FloeMacSelfRequestJournal.recordDispatchIntent(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        fingerprint: fingerprint
                    )
                }
            }
            #expect(
                illegal == .illegalTransition(
                    from: "unknown",
                    to: "dispatchMayHaveStarted"
                )
            )

            try await reopened.close()
            activeDatabase = nil
            try? FileManager.default.removeItem(at: fixture.root)
        } catch {
            if let activeDatabase {
                try? await activeDatabase.close()
            }
            Issue.record(
                "Request-journal fixture retained at \(fixture.root.path): \(error)"
            )
            throw error
        }
    }

    @Test("A prepare outside the journal transaction leaves an orphan run and blocks a new admission")
    func prepareOutsideJournalTransactionBlocksNewAdmission() async throws {
        try await withRequestJournalFixture(prefix: "prepare-gap") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalPrepare(
                fixture,
                conversationID: conversationID,
                runID: runID,
                workspaceID: workspaceID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()
            let payload = Data("prepare gap request".utf8)

            do {
                try await fixture.database.writer { db in
                    try requestJournalInsertAdmissionRow(
                        db: db,
                        conversationID: conversationID,
                        runID: runID,
                        epoch: 1,
                        phase: "admitting"
                    )
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: payload
                    )
                    throw RequestJournalTestRollback()
                }
            } catch is RequestJournalTestRollback {
                // The simulate-helper transaction aborted.
            }

            let state = try await fixture.database.reader { db in
                (
                    runExists: try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM runs WHERE id = ?)",
                        arguments: [runID.uuidString]
                    ) ?? false,
                    admissionCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_admission"
                    ) ?? -1,
                    journalCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM floe_mac_self_request_journal"
                    ) ?? -1
                )
            }
            #expect(state.runExists)
            #expect(state.admissionCount == 0)
            #expect(state.journalCount == 0)

            // The existing admission layer refuses a new attempt while the
            // prepared run is non-terminal, even though no journal row exists.
            // The journal cannot repair a prepare that committed outside its
            // own transaction; explicit host reconciliation is required.
            let blocked = await selfCoreError {
                _ = try await fixture.admission.admit(
                    conversationID: conversationID,
                    runID: UUID(),
                    owner: requestJournalOwner()
                )
            }
            #expect(blocked == .admissionUnknown(conversationID))
        }
    }

    @Test("Payload, row and query bounds are enforced without storing plaintext")
    func boundsAndNoPlaintextStorage() async throws {
        try await withRequestJournalFixture(prefix: "bounds") { fixture in
            let conversationID = UUID()
            let runID = UUID()
            let workspaceID = UUID()
            _ = try await requestJournalAdmit(
                fixture,
                conversationID: conversationID,
                runID: runID
            )
            let scope = requestJournalScope(
                workspaceID: workspaceID,
                conversationID: conversationID,
                runID: runID
            )
            let principal = requestJournalPrincipal()
            let requestID = UUID()

            let oversized = Data(
                repeating: 0x41,
                count: FloeMacSelfRequestJournal.maximumPayloadBytes + 1
            )
            let tooLarge = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: requestID,
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: oversized
                    )
                }
            }
            #expect(tooLarge == .payloadTooLarge(oversized.count))

            let sentinelGoal = "SECRET-GOAL-SENTINEL"
            let sentinelCredential = "Bearer sk-live-SENTINEL"
            let payload = Data(
                "\(sentinelGoal)|\(sentinelCredential)".utf8
            )
            let reservation = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: requestID,
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: payload
                )
            }
            #expect(reservation.record.fingerprint.hex.count == 64)
            #expect(
                reservation.record.fingerprint.hex
                    == reservation.record.fingerprint.hex.lowercased()
            )
            #expect(reservation.record.fingerprint.byteCount == payload.count)

            let rawTexts = try await fixture.database.reader { db -> [String] in
                let row = try #require(try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM floe_mac_self_request_journal
                        WHERE request_id = ?
                        """,
                    arguments: [requestID.uuidString]
                ))
                return row.columnNames.compactMap { column -> String? in
                    let value: DatabaseValue = row[column]
                    guard !value.isNull else { return nil }
                    return String.fromDatabaseValue(value)
                }
            }
            let storedSentinel = rawTexts.contains { $0.contains("SENTINEL") }
            let storedGoal = rawTexts.contains { $0.contains(sentinelGoal) }
            let storedCredential = rawTexts.contains {
                $0.contains(sentinelCredential)
            }
            #expect(!storedSentinel)
            #expect(!storedGoal)
            #expect(!storedCredential)

            let zeroLimit = await requestJournalError {
                try await fixture.database.reader { db in
                    _ = try FloeMacSelfRequestJournal.records(
                        db: db,
                        conversationID: conversationID,
                        limit: 0
                    )
                }
            }
            #expect(zeroLimit == .invalidQuery("limit"))

            let tooMany = await requestJournalError {
                try await fixture.database.reader { db in
                    _ = try FloeMacSelfRequestJournal.records(
                        db: db,
                        conversationID: conversationID,
                        limit: FloeMacSelfRequestJournal.maximumRecordsPerQuery + 1
                    )
                }
            }
            #expect(tooMany == .invalidQuery("limit"))

            // Fill the per-conversation bound, then prove a new reservation
            // fails closed instead of pruning a recorded fact.
            let remaining = FloeMacSelfRequestJournal.maximumRowsPerConversation - 2
            try await fixture.database.writer { db in
                for _ in 0..<remaining {
                    try requestJournalInsertSyntheticTerminalRow(
                        db: db,
                        scope: scope,
                        principal: principal
                    )
                }
            }
            let atCapacity = try await fixture.database.writer { db in
                try FloeMacSelfRequestJournal.reserve(
                    db: db,
                    requestID: UUID(),
                    protocolVersion: 1,
                    scope: scope,
                    principal: principal,
                    payload: Data("row-cap fill".utf8)
                )
            }
            #expect(atCapacity.disposition == .recorded)

            let overCapacity = await requestJournalError {
                try await fixture.database.writer { db in
                    _ = try FloeMacSelfRequestJournal.reserve(
                        db: db,
                        requestID: UUID(),
                        protocolVersion: 1,
                        scope: scope,
                        principal: principal,
                        payload: Data("row-cap overflow".utf8)
                    )
                }
            }
            #expect(
                overCapacity
                    == .capacityExceeded(conversationID)
            )

            let finalCount = try await fixture.database.reader { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM floe_mac_self_request_journal
                        WHERE conversation_id = ?
                        """,
                    arguments: [conversationID.uuidString]
                ) ?? -1
            }
            #expect(
                finalCount
                    == FloeMacSelfRequestJournal.maximumRowsPerConversation
            )
        }
    }
}

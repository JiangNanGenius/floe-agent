// SPDX-License-Identifier: MPL-2.0
//
// Host-adapter integration for the verified authority provenance. These tests
// exercise the public host contract directly: the host prepares a private
// database location, captures provenance, constructs the runtime, and a real
// task runs to a durably confirmed terminal. Every root is a unique 0700
// temporary directory; no user database, Keychain item or workspace is touched.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
@testable import FloePersistence
import FloeAgentRuntime
import GRDB
@testable import FloeMacSelfCore

@Suite("Mac self-core host provenance adapter")
struct HostAdapterIntegrationTests {

    @Test("Opening a 1.10.7 database preserves the original conversation and message")
    func migrateMacHistoryFromVersion63() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("previous.sqlite")
            let conversationID = UUID()
            let messageID = UUID()
            try Self.seedVersion63(databaseURL, conversationID: conversationID, messageID: messageID)
            let runtime = try FloeMacSelfRuntime(
                databaseURL: databaseURL, owner: .init(displayName: "MigrationFixture"),
                provenance: try makeHostProvenance(databaseURL: databaseURL)
            )
            let receipt = try await runtime.bootstrap()
            #expect(receipt.schemaVersion == 68)
            let messages = try await runtime.conversationMessages(conversationID: conversationID)
            #expect(messages.map(\.id) == [messageID])
            #expect(messages.first?.content == "Saved before the update.")
            _ = try await runtime.shutdown(cancelActive: false)
        }
    }

    @Test("Both released v66 session stores retain messages and converge on the shared schema", arguments: [false, true])
    func migrateBothVersion66Shapes(ipad: Bool) async throws {
        try await withSelfCoreTempDirectory { root in
            let file = root.appendingPathComponent("session.sqlite")
            let conversationID = UUID()
            let messageID = UUID()
            let runID = UUID()
            let eventID = UUID()
            let grantID = UUID()
            let candidateID = UUID()
            try Self.seedVersion63(file, conversationID: conversationID, messageID: messageID)
            let old = try DatabaseQueue(path: file.path)
            var migrator = DatabaseMigrator()
            DatabaseManager.registerMigrations(into: &migrator)
            try migrator.migrate(old, upTo: ipad ? "v65" : "v66")
            if ipad {
                try await old.write { db in
                    try db.execute(sql: """
                        ALTER TABLE memory_candidates ADD COLUMN origin_conversation_id TEXT;
                        ALTER TABLE memory_candidates ADD COLUMN origin_workspace_id TEXT;
                        INSERT INTO grdb_migrations (identifier) VALUES ('v66');
                        PRAGMA user_version = 66;
                        """)
                }
            }
            try await old.write { db in
                let date = PersistenceCodec.encode(Date())
                try db.execute(sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at, ended_at)
                    VALUES (?, ?, 'completed', 'Existing goal', ?, ?)
                    """, arguments: [runID.uuidString, conversationID.uuidString, date, date])
                try db.execute(sql: """
                    INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                    VALUES (?, ?, 1, 'approval', '{"decision":"allowOnce"}', ?)
                    """, arguments: [eventID.uuidString, runID.uuidString, date])
                if ipad {
                    try db.execute(sql: """
                        INSERT INTO approval_grants (id, tool_name, paths_json, policy_name, decided_at)
                        VALUES (?, 'workspace.read', '["report.txt"]', 'human', ?)
                        """, arguments: [grantID.uuidString, date])
                } else {
                    try db.execute(sql: """
                        INSERT INTO approval_grants (id, tool_name, paths_json, policy_name, decided_at,
                            conversation_id, authorization_identity)
                        VALUES (?, 'workspace.read', '["report.txt"]', 'human', ?, ?, 'fixture-authority')
                        """, arguments: [grantID.uuidString, date, conversationID.uuidString])
                }
                let evidence = "[{\"messageID\":\"\(messageID.uuidString)\"}]"
                try db.execute(sql: """
                    INSERT INTO memory_candidates (id, scope, content, confidence, stability, importance,
                        sensitivity, origin, evidence_json, status, created_at, updated_at)
                    VALUES (?, 'user', 'Existing preference', 1., 1., 1., 'normal', 'derived', ?, 'pending', ?, ?)
                    """, arguments: [candidateID.uuidString, evidence, date, date])
                if ipad {
                    try db.execute(sql: "UPDATE memory_candidates SET origin_conversation_id = ? WHERE id = ?",
                                   arguments: [conversationID.uuidString, candidateID.uuidString])
                }
            }
            try old.close()

            let runtime = try FloeMacSelfRuntime(databaseURL: file, owner: .init(displayName: "ParityFixture"),
                                                  provenance: try makeHostProvenance(databaseURL: file))
            #expect(try await runtime.bootstrap().schemaVersion == 68)
            let messages = try await runtime.conversationMessages(conversationID: conversationID)
            #expect(messages.first?.id == messageID)
            #expect(messages.first?.content == "Saved before the update.")
            let output = root.appendingPathComponent("conversation.jsonl")
            try await runtime.exportStructuredConversation(conversationID: conversationID, to: output)
            let rows = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map { line in
                try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            #expect(rows.first?["format"] as? String == "floe.task.jsonl")
            #expect(rows.first?["version"] as? Int == 1)
            #expect(rows.first(where: { $0["type"] as? String == "message" })?["id"] as? String == messageID.uuidString)
            let savedEvent = rows.first { $0["type"] as? String == "event" }
            #expect(savedEvent?["id"] as? String == eventID.uuidString)
            #expect(savedEvent?["kind"] as? String == "approval")
            #expect((savedEvent?["payload"] as? [String: String])?["decision"] == "allowOnce")
            #expect(rows.last?["type"] as? String == "exportComplete")
            _ = try await runtime.shutdown(cancelActive: false)

            let reopened = try DatabaseQueue(path: file.path)
            let both = try await reopened.read { db in
                let grants = Set(try db.columns(in: "approval_grants").map(\.name))
                let memory = Set(try db.columns(in: "memory_candidates").map(\.name))
                let grant = try Row.fetchOne(db, sql: """
                    SELECT paths_json, conversation_id, authorization_identity FROM approval_grants WHERE id = ?
                    """, arguments: [grantID.uuidString])
                let paths: String? = grant?["paths_json"]
                let owner: String? = grant?["conversation_id"]
                let identity: String? = grant?["authorization_identity"]
                let origin = try String.fetchOne(db, sql: """
                    SELECT origin_conversation_id FROM memory_candidates WHERE id = ?
                    """, arguments: [candidateID.uuidString])
                return grants.isSuperset(of: ["conversation_id", "authorization_identity"]) &&
                    memory.isSuperset(of: ["origin_conversation_id", "origin_workspace_id"]) &&
                    paths == "[\"report.txt\"]" &&
                    owner == (ipad ? nil : conversationID.uuidString) &&
                    identity == (ipad ? nil : "fixture-authority") &&
                    origin == conversationID.uuidString
            }
            #expect(both)
            try reopened.close()
        }
    }

    private static func seedVersion63(_ url: URL, conversationID: UUID, messageID: UUID) throws {
        let database = try DatabaseQueue(path: url.path)
        var migrations = DatabaseMigrator()
        DatabaseManager.registerMigrations(into: &migrations)
        try migrations.migrate(database, upTo: "v63_linux_cache_cleanup_tasks")
        try database.write { db in
            let date = PersistenceCodec.encode(Date())
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'Existing task', ?, ?)
                """, arguments: [conversationID.uuidString, date, date])
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES (?, ?, 'user', 'Saved before the update.', ?)
                """, arguments: [messageID.uuidString, conversationID.uuidString, date])
        }
        try database.close()
    }

    @Test("Different unchecked authority domains do not prove a global exclusive lock")
    func uncheckedDomainsDoNotEstablishGlobalExclusivity() async throws {
        try await withSelfCoreTempDirectory { root in
            let firstDirectory = root.appendingPathComponent("first-lock", isDirectory: true)
            let secondDirectory = root.appendingPathComponent("second-lock", isDirectory: true)
            for directory in [firstDirectory, secondDirectory] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let database = root.appendingPathComponent("shared.sqlite")
            let firstProvenance = try makeHostProvenance(databaseURL: database, lockDirectory: firstDirectory)
            let secondProvenance = try makeHostProvenance(databaseURL: database, lockDirectory: secondDirectory)
            let owner = FloeMacSelfHostIdentity(displayName: "AuthorityDomainFixture")
            let first = try FloeMacSelfAuthorityLock(provenance: firstProvenance, owner: owner)
            let second = try FloeMacSelfAuthorityLock(provenance: secondProvenance, owner: owner)
            #expect(first.lockURL != second.lockURL)
            try first.verifyHeld()
            try second.verifyHeld()
            second.release()
            first.release()
        }
    }

    @Test("A fixed authority domain rejects a different lock directory and replaced database")
    func fixedAuthorityDomainRejectsDrift() async throws {
        try await withSelfCoreTempDirectory { root in
            let lockA = root.appendingPathComponent("locks-a", isDirectory: true)
            let lockB = root.appendingPathComponent("locks-b", isDirectory: true)
            for directory in [lockA, lockB] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let url = root.appendingPathComponent("domain.sqlite")
            let first = try makeHostProvenance(databaseURL: url, lockDirectory: lockA)
            let second = try makeHostProvenance(databaseURL: url, lockDirectory: lockB)
            let domain = FloeMacSelfAuthorityDomain(
                lockDirectoryPath: first.lockDirectoryPath,
                lockDirectoryIdentity: first.lockDirectoryIdentity
            )
            try domain.validate(first)
            let alternate = await selfCoreError { try domain.validate(second) }
            #expect(alternate == .hostProvenanceUnavailable("authority_domain_mismatch"))

            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("original.sqlite"))
            try Data("replacement".utf8).write(to: url)
            let replacement = await selfCoreError { try domain.validate(first) }
            #expect(replacement == .hostProvenanceUnavailable("database_replaced"))
        }
    }

    @Test("Future schemas and unknown migrations are rejected before bootstrap writes")
    func unsupportedSchemaCannotBootstrap() async throws {
        for futureVersion in [true, false] {
            try await withSelfCoreTempDirectory { root in
                let url = root.appendingPathComponent("future.sqlite")
                let seeded = try DatabaseManager(path: url)
                try await seeded.migrate()
                try await seeded.writer { db in
                    if futureVersion {
                        try db.execute(sql: "PRAGMA user_version = 999")
                    } else {
                        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('future_migration')")
                    }
                }
                try await seeded.close()
                let runtime = try FloeMacSelfRuntime(
                    databaseURL: url,
                    owner: FloeMacSelfHostIdentity(displayName: "SchemaFixture"),
                    provenance: try makeHostProvenance(databaseURL: url)
                )
                let error = await selfCoreError { _ = try await runtime.bootstrap() }
                if futureVersion {
                    #expect(error == .schemaMismatch(expected: 68, actual: 999))
                } else {
                    #expect(error == .authoritySchemaUnsupported("unknown_migration"))
                }
                #expect(try await runtime.shutdown(cancelActive: false).databaseClosed)
                let reopened = try DatabaseManager(path: url)
                let observed = try await reopened.reader { db in
                    let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
                    let future = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'future_migration'")
                    let admission = try db.tableExists("floe_mac_self_admission")
                    return (version, future, admission)
                }
                #expect(observed.0 == (futureVersion ? 999 : 68))
                #expect(observed.1 == (futureVersion ? 0 : 1))
                #expect(!observed.2)
                try await reopened.close()
            }
        }
    }

    @Test("Self-declared workspace labels cannot authorize tool execution")
    func unleasedWorkspaceCannotStartTools() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Unleased workspace")
            let (provider, adapter) = fixture.makeProvider(scripts: [])
            let unleased = fixture.root.appendingPathComponent("unleased-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: unleased, withIntermediateDirectories: false)
            let (tools, executor, _) = try fixture.makeToolBinding(workspaceID: workspaceID, boundaryRoot: unleased)
            let conversationID = UUID()
            let request = FloeMacSelfSessionRequest(
                newConversationID: conversationID,
                workspaceID: workspaceID,
                goal: "The host has not acquired a task-root lease"
            )
            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: provider, tools: tools)
            }
            #expect(error == .invalidTaskBoundary(
                "the boundary root does not match the persisted workspace root"
            ))
            #expect(adapter.requests.isEmpty)
            #expect(executor.executedCalls.isEmpty)
            #expect(try await fixture.runtime.admissionRecord(conversationID: conversationID) == nil)
        }
    }

    @Test("Host provenance initializes the runtime and a genuine chat task runs to a confirmed durable terminal")
    func genuineTaskRunsThroughHostProvenance() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("host.sqlite")
            let owner = FloeMacSelfHostIdentity(displayName: "HostAdapterFixture")
            let provenance = try makeHostProvenance(databaseURL: databaseURL)
            let runtime = try FloeMacSelfRuntime(
                databaseURL: databaseURL,
                owner: owner,
                provenance: provenance
            )
            let bootstrap = try await runtime.bootstrap()
            // The upstream constant can lag registered migrations; the receipt
            // reports the version the transactional migrator actually reached.
            #expect(bootstrap.schemaVersion >= DatabaseManager.currentSchemaVersion)

            let (binding, adapter) = SelfCoreFixture.makeProviderBinding(scripts: [[
                .textDelta(.init(text: "Host adapter answer.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let request = FloeMacSelfSessionRequest(
                goal: "Run one genuine chat task through the host adapter",
                mode: .chat,
                context: FloeMacSelfRunContext(workspaceName: "HostAdapter")
            )
            let handle = try await runtime.startSession(request, provider: binding)

            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(terminal.durableRunState == "completed")
            #expect(terminal.finalMessageVerified)
            #expect(adapter.requests.count == 1)

            let run = try #require(try await runtime.runRecord(runID: handle.identity.runID))
            #expect(run.state == "completed")
            #expect(run.conversationID == handle.identity.conversationID)

            let messages = try await runtime.conversationMessages(
                conversationID: handle.identity.conversationID
            )
            #expect(messages.contains { $0.id == handle.identity.userMessageID })
            #expect(messages.contains { $0.role == "assistant" })

            let admission = try #require(
                try await runtime.admissionRecord(conversationID: handle.identity.conversationID)
            )
            #expect(admission.phase == .settledConfirmed)
            #expect(try await runtime.unresolvedAdmissions().isEmpty)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
            let shutdown = try await runtime.shutdown(cancelActive: false)
            #expect(shutdown.databaseClosed)
            #expect(shutdown.retainedAdmissionConversationIDs.isEmpty)
        }
    }

    @Test("A runtime constructed without provenance stays fail-closed and creates nothing")
    func runtimeWithoutProvenanceFailsClosed() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("closed.sqlite")
            let before = try AuthorityPrimitiveChecks.snapshot(root)
            let owner = FloeMacSelfHostIdentity(displayName: "GateFixture")

            do {
                _ = try FloeMacSelfRuntime(databaseURL: databaseURL, owner: owner)
                Issue.record("The runtime without provenance must stay closed")
            } catch let error as FloeMacSelfCoreError {
                #expect(error == .authorityLockUnsafe("host_provenance_missing"))
            } catch {
                Issue.record("Unexpected runtime gate error: \(error)")
            }

            let after = try AuthorityPrimitiveChecks.snapshot(root)
            #expect(after == before)
        }
    }

    @Test("Provenance that does not match the database URL fails before any open")
    func provenanceURLMismatchFailsClosed() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("mismatch.sqlite")
            _ = try makeHostProvenance(databaseURL: databaseURL)
            let owner = FloeMacSelfHostIdentity(displayName: "MismatchFixture")

            // Capture against a different file name; the runtime must reject the
            // inconsistent pair before the primitive opens anything.
            let otherURL = root.appendingPathComponent("other.sqlite")
            let foreignProvenance = try makeHostProvenance(databaseURL: otherURL)
            do {
                _ = try FloeMacSelfRuntime(
                    databaseURL: databaseURL,
                    owner: owner,
                    provenance: foreignProvenance
                )
                Issue.record("Mismatched provenance must fail closed")
            } catch let error as FloeMacSelfCoreError {
                #expect(error == .hostProvenanceUnavailable("provenance_does_not_match_database_url"))
            } catch {
                Issue.record("Unexpected mismatch error: \(error)")
            }
        }
    }

    @Test("A replaced database file fails closed against captured provenance")
    func replacedDatabaseIdentityFailsClosed() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("replaced.sqlite")
            let provenance = try makeHostProvenance(databaseURL: databaseURL)
            let owner = FloeMacSelfHostIdentity(displayName: "ReplacementFixture")

            // The host replaces the database file after capturing: the captured
            // identity no longer binds and acquisition must refuse before any
            // lock file for the stale identity is created. Recreate the file
            // (remove + write) so the inode genuinely changes.
            try FileManager.default.removeItem(at: databaseURL)
            try Data("SQLite format 3\u{0}replaced".utf8).write(to: databaseURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            do {
                _ = try FloeMacSelfRuntime(
                    databaseURL: databaseURL,
                    owner: owner,
                    provenance: provenance
                )
                Issue.record("A replaced database identity must fail closed")
            } catch let error as FloeMacSelfCoreError {
                #expect(error == .authorityLockUnsafe("unsafe_database"))
            } catch {
                Issue.record("Unexpected replacement error: \(error)")
            }
        }
    }

    @Test("A second runtime on a database held by a live runtime fails closed with authorityLocked")
    func concurrentRuntimeOnHeldDatabaseFailsClosed() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("held.sqlite")
            let provenance = try makeHostProvenance(databaseURL: databaseURL)
            let first = try FloeMacSelfRuntime(
                databaseURL: databaseURL,
                owner: FloeMacSelfHostIdentity(displayName: "FirstFixture"),
                provenance: provenance
            )
            _ = try await first.bootstrap()

            let secondError = await selfCoreError {
                _ = try FloeMacSelfRuntime(
                    databaseURL: databaseURL,
                    owner: FloeMacSelfHostIdentity(displayName: "SecondFixture"),
                    provenance: provenance
                )
            }
            #expect(secondError == .authorityLocked)

            let shutdown = try await first.shutdown(cancelActive: false)
            #expect(shutdown.databaseClosed)
        }
    }
}

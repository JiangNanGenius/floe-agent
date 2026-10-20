// SPDX-License-Identifier: MPL-2.0
// Actual Home producer (FacadeConversationDomain.create) -> ordinary wire
// run.start -> original engine/store. Synthetic external stream/key only;
// no seeding run is permitted before the first-send assertion.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
@testable import FloeAndroidCore

private final class ActivationReadGate: AndroidSecretGateway, @unchecked Sendable {
    let source: TestSecretGateway
    let gate = RunGateBox()
    init(_ source: TestSecretGateway) { self.source = source }
    func read(reference: String) async throws -> Data? {
        await gate.waitThroughCancellation()
        return try await source.read(reference: reference)
    }
    func write(reference: String, value: Data) async throws {
        try await source.write(reference: reference, value: value)
    }
    func delete(reference: String) async throws { try await source.delete(reference: reference) }
}

final class RuntimeFacadeEmptyHeaderActivationTests: XCTestCase {
    private var fixture: RunDomainFixture!
    override func setUp() async throws { fixture = try await RunDomainFixture.make() }
    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    private func header() async throws -> ConversationCreateReply {
        let context = ConversationFacadeContext(hostEpoch: fixture.epoch)
        let content = FacadeConversationContentAuthority(
            publisher: MemoryContentPublisher(), database: fixture.database,
            conversationStore: fixture.conversationStore, context: context)
        // Exact PUBLIC production initializer: no default-project binding.
        let producer = FacadeConversationDomain(
            database: fixture.database, conversationStore: fixture.conversationStore,
            runStore: fixture.runStore, runningInputStore: fixture.inputStore,
            workspaceStore: fixture.workspaceStore, intelligenceStore: fixture.intelligence,
            content: content, context: context, lifecycle: nil,
            credentialDrain: nil, workspaceCleaning: nil)
        return try await producer.create(payload: .object(["title": .string("First send")]))
    }

    private func counts(_ database: DatabaseManager? = nil) async throws -> [Int] {
        let database = database ?? fixture.database
        return try await database.reader { db in
            try ["workspaces", "conversation_workspace_ownership", "task_policies",
                 "runs", "messages", "attachments"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
            }
        }
    }

    private func send(_ id: UUID, domain: FacadeRunDomain,
                      revision: String? = nil) async throws -> RunDomainReply {
        let version: String
        if let revision { version = revision }
        else { version = try await fixture.revision(conversationID: id) }
        let correlation = "activate-" + UUID().uuidString
        return await domain.start(envelope: fixture.launchEnvelope(
            conversationID: id, payload: fixture.startPayload(goal: "hello"),
            revisionVersion: version, correlation: correlation),
            receipt: "op:v1:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            correlation: correlation)
    }

    private func acceptedRun(_ reply: RunDomainReply) throws -> UUID {
        guard case .mutationAccepted(let detail) = reply.outcome,
              let id = detail["runID"].flatMap(UUID.init(uuidString:)) else {
            XCTFail("Expected real accepted run, got \(reply.outcome)")
            throw FloeError.internalError("expected accepted run")
        }
        return id
    }

    private func owner(_ id: UUID, database: DatabaseManager? = nil) async throws -> String? {
        let database = database ?? fixture.database
        return try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT workspace_id FROM conversation_workspace_ownership WHERE conversation_id = ?",
                                arguments: [id.uuidString])
        }
    }

    func testActualCreateFirstAndSecondWireSendReuseCanonicalWorkspaceAndColdRead() async throws {
        let created = try await header()
        let before = try await counts()
        XCTAssertEqual(before, [0, 0, 0, 0, 0, 0], "Actual create must remain a header-only producer")
        let domain = fixture.makeDomain()
        let firstReply = try await send(created.conversationID, domain: domain, revision: created.revision)
        let first = try acceptedRun(firstReply)
        let terminal1 = await waitDurableTerminal(fixture: fixture, runID: first)
        XCTAssertEqual(terminal1, "completed")
        let canonical = try await owner(created.conversationID)
        XCTAssertNotNil(canonical)
        let secondReply = try await send(created.conversationID, domain: domain)
        let second = try acceptedRun(secondReply)
        let terminal2 = await waitDurableTerminal(fixture: fixture, runID: second)
        XCTAssertEqual(terminal2, "completed")
        let after = try await counts()
        XCTAssertEqual(Array(after.prefix(4)), [1, 1, 1, 2])
        let secondOwner = try await owner(created.conversationID)
        XCTAssertEqual(secondOwner, canonical)
        let kind = try await fixture.database.reader { db in
            try String.fetchOne(db, sql: "SELECT kind FROM workspaces WHERE id = ?", arguments: [canonical])
        }
        XCTAssertEqual(kind, "privateTask")
        // Fresh connection/actors, read from the actual database path. This
        // is durable re-open evidence, not a process-death UI assertion.
        let reopened = try DatabaseManager(path: fixture.root.appendingPathComponent("floe.sqlite"))
        let coldOwner = try await owner(created.conversationID, database: reopened)
        let messages = try await SQLiteConversationStore(database: reopened).messages(conversationID: created.conversationID)
        XCTAssertEqual(coldOwner, canonical)
        XCTAssertTrue(messages.contains { $0.role == "assistant" && $0.content.contains("fixture answer") })
        try await reopened.close()
    }

    func testDefaultStoreStillRefusesHeaderAndOptInKeepsCreatedConversationFalse() async throws {
        let created = try await header()
        let original = RunLaunchRequest(conversationID: created.conversationID, goal: "original")
        do {
            _ = try await fixture.launchStore.prepare(original)
            XCTFail("Original default must still refuse ownerless existing headers")
        } catch let error as FloeError {
            XCTAssertEqual(error, .storageCorrupted("Conversation has no canonical workspace"))
        }
        let refusedCounts = try await counts()
        XCTAssertEqual(refusedCounts, [0, 0, 0, 0, 0, 0])
        var trusted = original
        trusted.activatesEmptyOrdinaryHeader = true
        let prepared = try await fixture.launchStore.prepare(trusted)
        XCTAssertEqual(prepared.conversation.id, created.conversationID)
        XCTAssertFalse(prepared.createdConversation)
        XCTAssertEqual(prepared.workspace.kind, .privateTask)
    }

    func testNonemptyOrphanMessageNeverGetsRebound() async throws {
        let created = try await header()
        try await fixture.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: created.conversationID, role: "user", content: "existing history", createdAt: Date()))
        let baseline = try await counts()
        let reply = try await send(created.conversationID, domain: fixture.makeDomain())
        guard case .rejected = reply.outcome else { return XCTFail("Used orphan must refuse") }
        let after = try await counts()
        XCTAssertEqual(after, baseline)
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testOrphanWithRunPolicyOrCommittedAttachmentCannotActivate() async throws {
        for evidence in ["run", "policy", "attachment"] {
            let created = try await header()
            let id = created.conversationID
            try await fixture.database.writer { db in
                switch evidence {
                case "run":
                    try db.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'completed', 'history', ?)",
                                   arguments: [UUID().uuidString, id.uuidString, ConversationWireDate.encode(Date())])
                case "policy":
                    try db.execute(sql: "INSERT INTO task_policies (conversation_id, approval_mode, recovery_policy, notification_policy, updated_at) VALUES (?, 'ask', 'safePoint', 'stages', ?)",
                                   arguments: [id.uuidString, ConversationWireDate.encode(Date())])
                default:
                    try db.execute(sql: "INSERT INTO attachments (id, conversation_id, kind, created_at) VALUES (?, ?, 'document', ?)",
                                   arguments: [UUID().uuidString, id.uuidString, ConversationWireDate.encode(Date())])
                }
            }
            let baseline = try await counts()
            let reply = try await send(id, domain: fixture.makeDomain())
            guard case .rejected = reply.outcome else { return XCTFail("\(evidence) orphan must refuse") }
            let after = try await counts()
            XCTAssertEqual(after, baseline, evidence)
        }
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testArchivedAndNotesEmptyHeadersRefuse() async throws {
        for purpose in ["archived", "notes"] {
            let created = try await header()
            let id = created.conversationID
            try await fixture.database.writer { db in
                if purpose == "archived" {
                    try db.execute(sql: "UPDATE conversations SET archived_at = ? WHERE id = ?",
                                   arguments: [ConversationWireDate.encode(Date()), id.uuidString])
                } else {
                    try db.execute(sql: "UPDATE conversations SET purpose = ? WHERE id = ?",
                                   arguments: [purpose, id.uuidString])
                }
            }
            let baseline = try await counts()
            // Exercise the store's raw eligibility too: no decoded default
            // or malformed archived timestamp may confer ordinary authority.
            var request = RunLaunchRequest(conversationID: id, goal: "must refuse")
            request.activatesEmptyOrdinaryHeader = true
            do { _ = try await fixture.launchStore.prepare(request); XCTFail(purpose) }
            catch { /* Expected refusal, asserted with exact no-effect below. */ }
            let reply = try await send(id, domain: fixture.makeDomain())
            guard case .rejected = reply.outcome else { return XCTFail(purpose) }
            let after = try await counts()
            XCTAssertEqual(after, baseline, purpose)
        }
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testDeletedForeignAndStaleRevisionRefuseBeforeActivation() async throws {
        let created = try await header()
        let id = created.conversationID
        let domain = fixture.makeDomain()
        try await fixture.conversationStore.renameConversation(id: id, title: "changed")
        let baseline = try await counts()
        let stale = try await send(id, domain: domain, revision: created.revision)
        guard case .rejected(let error) = stale.outcome else { return XCTFail("stale accepted") }
        XCTAssertEqual(error.code, .staleRevision)
        let foreign = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: UUID(), payload: fixture.startPayload(goal: "foreign"),
            revisionVersion: created.revision, correlation: "foreign"),
            receipt: "op:v1:" + String(repeating: "d", count: 32), correlation: "foreign")
        guard case .rejected(let absent) = foreign.outcome else { return XCTFail("foreign accepted") }
        XCTAssertEqual(absent.code, .notFound)
        try await fixture.conversationStore.deleteConversation(id: id)
        let deleted = try await send(id, domain: domain, revision: created.revision)
        guard case .rejected(let missing) = deleted.outcome else { return XCTFail("deleted accepted") }
        XCTAssertEqual(missing.code, .notFound)
        let after = try await counts()
        XCTAssertEqual(after, baseline)
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testFaultAfterWorkspaceAndPolicyRollsEntireFirstActivationBack() async throws {
        let created = try await header()
        try await fixture.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER activation_failure BEFORE INSERT ON runs BEGIN SELECT RAISE(ABORT, 'synthetic launch fault'); END")
        }
        let baseline = try await counts()
        let reply = try await send(created.conversationID, domain: fixture.makeDomain())
        guard case .rejected(let error) = reply.outcome else { return XCTFail("fault accepted") }
        XCTAssertEqual(error.phase, .launchPrepare)
        let after = try await counts()
        XCTAssertEqual(after, baseline, "Same writer must roll workspace and policy back with run failure")
        XCTAssertEqual(fixture.adapter.requestCount, 0)
        try await fixture.database.writer { db in try db.execute(sql: "DROP TRIGGER activation_failure") }
        let retryReply = try await send(created.conversationID, domain: fixture.makeDomain())
        let retry = try acceptedRun(retryReply)
        let terminal = await waitDurableTerminal(fixture: fixture, runID: retry)
        XCTAssertEqual(terminal, "completed")
    }

    func testMetadataChangedDuringCredentialAwaitRefusesInsideWriter() async throws {
        let created = try await header()
        let gateway = ActivationReadGate(fixture.gateway)
        SecretGatewayRegistry.shared.register(gateway)
        let domain = fixture.makeDomain()
        let envelope = fixture.launchEnvelope(
            conversationID: created.conversationID, payload: fixture.startPayload(goal: "awaiting credential"),
            revisionVersion: created.revision, correlation: "await-credential")
        let launch = Task {
            await domain.start(envelope: envelope,
                receipt: "op:v1:" + String(repeating: "e", count: 32), correlation: "await-credential")
        }
        defer { gateway.gate.release() }
        let entered = await pollFor { gateway.gate.isWaiting }
        guard entered else { return XCTFail("Actual credential read did not enter") }
        try await fixture.database.writer { db in
            // Deliberately preserve updated_at: full raw-row CAS, not a
            // timestamp approximation, must catch this write.
            try db.execute(sql: "UPDATE conversations SET title = 'concurrent edit' WHERE id = ?",
                           arguments: [created.conversationID.uuidString])
        }
        gateway.gate.release()
        let reply = await launch.value
        guard case .rejected(let error) = reply.outcome else { return XCTFail("stale race accepted") }
        XCTAssertEqual(error.code, .staleRevision)
        XCTAssertEqual(error.reason, .revisionMismatch)
        XCTAssertEqual(error.phase, .launchPrepare)
        let after = try await counts()
        XCTAssertEqual(after, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testFenceDuringActualCredentialAwaitLeavesHeaderUnactivated() async throws {
        let created = try await header()
        let gateway = ActivationReadGate(fixture.gateway)
        SecretGatewayRegistry.shared.register(gateway)
        let domain = fixture.makeDomain()
        let envelope = fixture.launchEnvelope(
            conversationID: created.conversationID, payload: fixture.startPayload(goal: "awaiting credential"),
            revisionVersion: created.revision, correlation: "await-credential")
        let launch = Task {
            await domain.start(envelope: envelope,
                receipt: "op:v1:" + String(repeating: "e", count: 32), correlation: "await-credential")
        }
        defer { gateway.gate.release() }
        let entered = await pollFor { gateway.gate.isWaiting }
        guard entered else { return XCTFail("Actual credential read did not enter") }
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: created.conversationID, epoch: fixture.epoch, operationID: UUID())
        gateway.gate.release()
        let reply = await launch.value
        guard case .rejected(let error) = reply.outcome else { return XCTFail("Fenced launch committed") }
        XCTAssertEqual(error.code, .sessionFenced)
        let after = try await counts()
        XCTAssertEqual(after, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(fixture.adapter.requestCount, 0)
        let released = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(released, .released)
    }

    func testConcurrentFirstWireSendDuringCredentialAwaitCreatesExactlyOneRun() async throws {
        let created = try await header()
        let gateway = ActivationReadGate(fixture.gateway)
        SecretGatewayRegistry.shared.register(gateway)
        let domain = fixture.makeDomain()
        let envelope = fixture.launchEnvelope(
            conversationID: created.conversationID, payload: fixture.startPayload(goal: "first send"),
            revisionVersion: created.revision, correlation: "first-admitting")
        let first = Task {
            await domain.start(envelope: envelope,
                receipt: "op:v1:" + String(repeating: "a", count: 32), correlation: "first-admitting")
        }
        defer { gateway.gate.release() }
        let entered = await pollFor { gateway.gate.isWaiting }
        guard entered else { return XCTFail("Actual first admission did not reach the credential await") }
        // Both calls have the SAME original raw-row revision. The first is
        // genuinely admitting (not a fabricated service state or clock
        // increment); the second must not create another workspace/run.
        let duplicate = try await send(created.conversationID, domain: domain, revision: created.revision)
        guard case .rejected(let error) = duplicate.outcome else { return XCTFail("Concurrent admission accepted") }
        XCTAssertEqual(error, RunDomainError(.duplicateInFlight, .launchAlreadyInFlight))
        let during = try await counts()
        XCTAssertEqual(during, [0, 0, 0, 0, 0, 0])
        gateway.gate.release()
        let firstReply = await first.value
        let runID = try acceptedRun(firstReply)
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        let after = try await counts()
        XCTAssertEqual(Array(after.prefix(4)), [1, 1, 1, 1])
        let userCount = try await fixture.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ? AND role = 'user'",
                             arguments: [created.conversationID.uuidString])
        }
        XCTAssertEqual(userCount, 1)
        XCTAssertEqual(fixture.adapter.requestCount, 1)
    }

    func testMissingSameWriterCapabilityFailsClosedBeforeAnyLaunch() async throws {
        let created = try await header()
        var components = fixture.components()
        components.durable = RunPersistenceBundle(
            identity: .ordinary, conversations: fixture.conversationStore,
            runs: fixture.runStore, runningInputs: fixture.inputStore,
            launches: FailingLaunchStore(), childRuns: fixture.childStore,
            intelligence: fixture.intelligence)
        let reply = try await send(created.conversationID, domain: fixture.makeCustomDomain(components))
        guard case .rejected(let error) = reply.outcome else { return XCTFail("Missing capability accepted") }
        XCTAssertEqual(error, RunDomainError(.persistenceUnavailable, .storeReadFailed))
        let after = try await counts()
        XCTAssertEqual(after, [0, 0, 0, 0, 0, 0])
    }

    func testOriginalNewConversationPreparationStillCreatesHeaderWorkspaceAndPolicy() async throws {
        let prepared = try await fixture.launchStore.prepare(RunLaunchRequest(goal: "new original task"))
        XCTAssertTrue(prepared.createdConversation)
        XCTAssertEqual(prepared.workspace.kind, .privateTask)
        let after = try await counts()
        XCTAssertEqual(after, [1, 1, 1, 1, 1, 0])
    }


    func testOriginalSQLiteSchemaRejectsTemporaryAndUnknownPurposes() async throws {
        let created = try await header()
        for purpose in ["temporary", "unknown-purpose"] {
            do {
                try await fixture.database.writer { db in
                    try db.execute(sql: "UPDATE conversations SET purpose = ? WHERE id = ?",
                                   arguments: [purpose, created.conversationID.uuidString])
                }
                XCTFail("The original purpose constraint must reject \(purpose)")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        let after = try await counts()
        XCTAssertEqual(after, [0, 0, 0, 0, 0, 0])
    }

}

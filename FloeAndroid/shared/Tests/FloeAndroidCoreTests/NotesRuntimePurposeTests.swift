// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose runtime — purpose/identity regressions.
//
// Proves the ADDITIVE Notes execution identity never weakens an ordinary
// privacy/proof rule:
//   * the durable purpose of a Notes row is `notes` and the ordinary proof
//     answers exactly like absence;
//   * the same-writer row verifier accepts ONLY the expected purpose;
//   * the Notes bundle keeps the SAME store instances and drops the
//     intelligence/discovery/checklist/child graph;
//   * the ordinary wire launch still refuses a notes conversation before any
//     durable effect.
import XCTest
import Foundation
import GRDB
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class NotesRuntimePurposeTests: XCTestCase {
    private var fixture: RunDomainFixture?

    override func tearDown() async throws {
        if let fixture {
            await RunDomainFacade.beginGenerationRetirement(epoch: fixture.epoch)
            await fixture.tearDown()
        }
        fixture = nil
        SecretGatewayRegistry.shared.unregister()
        await RunDomainFacade.uninstall()
        try await super.tearDown()
    }

    private func makeFixture() async throws -> RunDomainFixture {
        let value = try await RunDomainFixture.make()
        fixture = value
        return value
    }

    // MARK: - Identity vocabulary

    func testNotesIdentityMapsToTheDurableNotesPurpose() {
        XCTAssertEqual(RunExecutionIdentity.notes.conversationPurpose, .notes)
        XCTAssertEqual(RunExecutionIdentity.notes.launchRowPurpose, "notes")
        XCTAssertEqual(RunExecutionIdentity.ordinary.launchRowPurpose, "ordinary")
        XCTAssertEqual(RunExecutionIdentity.temporary.launchRowPurpose, "temporary")
    }

    func testNotesBundleReusesTheSameStoresAndClosesGoalDiscoveryChecklistAndChildren() async throws {
        let fixture = try await makeFixture()
        let notes = RunPersistenceBundle.notesBundle(from: fixture.components().durable)
        XCTAssertEqual(notes.identity, .notes)
        // SAME original store instances: no second database or cluster.
        XCTAssertTrue((notes.conversations as AnyObject) === fixture.conversationStore)
        XCTAssertTrue((notes.runs as AnyObject) === fixture.runStore)
        XCTAssertTrue((notes.runningInputs as AnyObject) === fixture.inputStore)
        XCTAssertTrue((notes.launches as AnyObject) === fixture.launchStore)
        // Chat-only: no goal/plan intelligence, discovery projection, ordinary
        // checklist or durable child graph.
        XCTAssertNil(notes.intelligence)
        XCTAssertNil(notes.discovery)
        XCTAssertNil(notes.taskChecklist)
        XCTAssertNil(notes.childRuns)
    }

    // MARK: - Purpose reader

    func testPurposeReaderSeparatesOrdinaryNotesAndMissingRows() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.makeOrdinaryConversation()
        let notes = try await seedNote(conversationID: UUID(), fixture: fixture)
        let reader = G02ConversationRevisionReader(database: fixture.database)

        let ordinaryPurpose = try await reader.purpose(of: ordinary)
        let notesPurpose = try await reader.purpose(of: notes)
        let missingPurpose = try await reader.purpose(of: UUID())
        XCTAssertEqual(ordinaryPurpose, .ordinary)
        XCTAssertEqual(notesPurpose, .notes)
        XCTAssertNil(missingPurpose)

        // The ordinary proof answers exactly like absence for a notes row.
        let ordinaryRowIsOrdinary = try await reader.ordinaryExists(conversationID: ordinary)
        let notesRowIsOrdinary = try await reader.ordinaryExists(conversationID: notes)
        let missingIsOrdinary = try await reader.ordinaryExists(conversationID: UUID())
        XCTAssertTrue(ordinaryRowIsOrdinary)
        XCTAssertFalse(notesRowIsOrdinary)
        XCTAssertFalse(missingIsOrdinary)
    }

    // MARK: - Same-writer purpose guard

    func testSameWriterGuardAcceptsOnlyTheExpectedPurpose() async throws {
        let fixture = try await makeFixture()
        let notes = try await seedNote(conversationID: UUID(), fixture: fixture)
        let digest = try await G02ConversationRevisionReader(database: fixture.database)
            .digest(conversationID: notes) ?? ""
        XCTAssertFalse(digest.isEmpty)

        try await fixture.database.writer { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [notes.uuidString]) else {
                return XCTFail("notes row missing")
            }
            // Correct expected purpose + exact digest: admissible.
            XCTAssertNoThrow(try FacadeRunDomain.verifyExistingLaunchRow(
                db: db, row: row, conversationID: notes,
                expectedRevision: digest, expectedPurpose: "notes"))
            // The ordinary entry keeps its exact purpose check: a notes row is
            // indistinguishable from absence.
            XCTAssertThrowsError(try FacadeRunDomain.verifyExistingLaunchRow(
                db: db, row: row, conversationID: notes,
                expectedRevision: digest)) { error in
                guard let refusal = error as? RunDomainError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(refusal.code, .notFound)
                XCTAssertEqual(refusal.reason, .conversationMissing)
            }
            // A stale digest stays a stale revision under the right purpose.
            XCTAssertThrowsError(try FacadeRunDomain.verifyExistingLaunchRow(
                db: db, row: row, conversationID: notes,
                expectedRevision: "0" + digest,
                expectedPurpose: "notes")) { error in
                guard let refusal = error as? RunDomainError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(refusal.code, .staleRevision)
                XCTAssertEqual(refusal.reason, .revisionMismatch)
            }
        }
    }

    // MARK: - Ordinary wire privacy

    func testOrdinaryWireLaunchRefusesANotesConversationBeforeAnyEffect() async throws {
        let fixture = try await makeFixture()
        let notes = try await seedNote(conversationID: UUID(), fixture: fixture)
        var components = fixture.components()
        components.conversationRevisions = NotesRuntimeTestRevisionReader(database: fixture.database)
        components.notesRuntime = NotesAssistantDomain.shared
        RunDomainFacade.install(components: components, registry: RuntimeDomainRegistry())
        guard let (domain, _) = RunDomainFacade.current(epoch: fixture.epoch) else {
            return XCTFail("run domain not installed")
        }
        try await seedWorkspace(conversationID: notes, fixture: fixture)
        let runsBefore = try await fixture.runStore.runs(conversationID: notes).count

        let envelope = RunCommandEnvelope(object: [
            "owner": ["taskID": notes.uuidString],
            "payload": [
                "goal": "ordinary launch must not enter a notes thread",
                "mode": "chat",
                "providerID": fixture.providerID.uuidString,
                "modelID": fixture.modelID.uuidString,
            ],
        ])
        let reply = await domain.start(envelope: envelope, receipt: "notes-privacy",
                                       correlation: "notes-privacy")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("ordinary wire admitted a notes conversation")
        }
        XCTAssertEqual(error.code, .notFound)
        XCTAssertEqual(error.reason, .conversationMissing)
        let runsAfter = try await fixture.runStore.runs(conversationID: notes).count
        XCTAssertEqual(runsBefore, runsAfter, "a refused launch must not create a run row")
        let row = try await fixture.conversationStore.conversation(id: notes)
        XCTAssertEqual(row?.purpose, .notes, "the row must never be retagged")
    }

    // MARK: - Helpers

    private func seedNote(conversationID: UUID,
                          fixture: RunDomainFixture) async throws -> UUID {
        try await fixture.conversationStore.saveConversation(ConversationRecord(
            id: conversationID,
            title: "Notes assistant",
            createdAt: Date(),
            updatedAt: Date(),
            purpose: .notes))
        return conversationID
    }

    private func seedWorkspace(conversationID: UUID,
                               fixture: RunDomainFixture) async throws {
        _ = try await fixture.workspaceStore.ensureWorkspace(
            conversationID: conversationID, title: "Notes assistant")
    }
}

/// Revision reader used by the Notes tests: the production reader PLUS the
/// additive purpose read (the shared test double predates that requirement).
struct NotesRuntimeTestRevisionReader: RunConversationRevisionReading {
    let database: DatabaseManager

    func digest(conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try ConversationRowRevision.digest(db: db, conversationID: conversationID)
        }
    }

    func ordinaryExists(conversationID: UUID) async throws -> Bool {
        try await purpose(of: conversationID) == .ordinary
    }

    func purpose(of conversationID: UUID) async throws -> ConversationPurpose? {
        try await database.reader { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT purpose FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]) else { return nil }
            return ConversationPurpose(rawValue: raw)
        }
    }
}

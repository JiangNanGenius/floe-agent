// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes runtime — durable open/transcript/root-stop regressions.
//
// These exercise the REAL stores and the REAL notes authority on a temporary
// root: the durable `purpose = notes` row, the idempotent open/partial retry,
// the paged transcript projection and the honest root-stop drain report.
//
// The document→conversation mapping is read through the REAL closed
// `assistant.thread` projection (NotesEngineAssistantThreadProjection over the
// one NotesStore); the tests therefore exercise the production path, including
// the partial-open and foreign-owner refusals.
import XCTest
import Foundation
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class NotesRuntimeLifecycleTests: XCTestCase {
    private var fixture: RunDomainFixture?
    private var notesRoot: String?

    override func tearDown() async throws {
        if let fixture {
            await RunDomainFacade.beginGenerationRetirement(epoch: fixture.epoch)
            await NotesAssistantDomain.shared.unbind(epoch: fixture.epoch)
            await NotesDomainService.shared.retire(epoch: fixture.epoch)
            await fixture.tearDown()
        }
        fixture = nil
        if let notesRoot { try? FileManager.default.removeItem(atPath: notesRoot) }
        notesRoot = nil
        SecretGatewayRegistry.shared.unregister()
        await RunDomainFacade.uninstall()
        try await super.tearDown()
    }

    // MARK: - Harness

    private func makeFixture() async throws -> RunDomainFixture {
        let value = try await RunDomainFixture.make()
        fixture = value
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-g06-notes-runtime-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        notesRoot = root.standardizedFileURL.path
        NotesDomainService.shared.bindForTesting(epoch: value.epoch, root: root)
        await NotesAssistantDomain.shared.bind(epoch: value.epoch)
        var components = value.components()
        components.conversationRevisions = NotesRuntimeTestRevisionReader(
            database: value.database)
        components.notesRuntime = NotesAssistantDomain.shared
        RunDomainFacade.install(components: components, registry: RuntimeDomainRegistry())
        return value
    }

    private func call(_ action: String, _ json: String) async throws -> [String: Any] {
        let epoch = try XCTUnwrap(fixture?.epoch)
        let value = try JSONDecoder().decode(NotesJSONValue.self, from: Data(json.utf8))
        let data = try await NotesAssistantDomain.shared.handle(
            epoch: epoch, requestID: UUID().uuidString, action: action, payload: value)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func seedDocument(_ fixture: RunDomainFixture) async throws -> UUID {
        let command = try await NotesDomainService.shared.handle(
            epoch: fixture.epoch,
            requestID: "seed-\(UUID().uuidString)",
            action: "document.saveMessage",
            payload: .object(["text": .string("Seed note body"),
                              "title": .string("Seed")]))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: command) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let document = try XCTUnwrap(object["document"] as? [String: Any])
        return try XCTUnwrap((document["id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    // MARK: - Open

    func testOpenCreatesADurableNotesRowWorkspaceAndBinding() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(opened["ok"] as? Bool, true, "\(opened)")
        XCTAssertEqual(opened["created"] as? Bool, true)
        let conversationID = try XCTUnwrap(
            (opened["conversationID"] as? String).flatMap(UUID.init(uuidString:)))

        let row = try await fixture.conversationStore.conversation(id: conversationID)
        XCTAssertEqual(row?.purpose, .notes, "the FIRST durable row is already purpose=notes")
        let workspace = try await fixture.workspaceStore.ensureWorkspace(
            conversationID: conversationID, title: "Seed")
        XCTAssertFalse(workspace.name.isEmpty)

        // The native assistant thread/grant is the real one, not a test row.
        let grants = try await NotesAuthority(epoch: fixture.epoch)
            .grants(conversationID: conversationID)
        XCTAssertEqual(grants[document], true)

        // Reopen reads the REAL assistant_threads row and reuses it.
        let reopened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(reopened["ok"] as? Bool, true)
        XCTAssertEqual(reopened["created"] as? Bool, false)
        XCTAssertEqual(reopened["conversationID"] as? String, conversationID.uuidString)
        let all = try await fixture.conversationStore.conversations()
        XCTAssertEqual(all.filter { $0.purpose == .notes }.count, 0,
                       "normal listings stay ordinary-only")
    }

    func testOpenRetriesAPartialTwoDatabaseOutcomeWithTheSameIdentity() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        let halfBound = UUID()
        // Simulate a crash after the Notes thread committed but before the main
        // row: the REAL `assistant_threads` mapping already names the id.
        _ = try await NotesDomainService.shared.handle(
            epoch: fixture.epoch,
            requestID: "half-bind",
            action: "assistant.bind",
            payload: .object([
                "conversationID": .string(halfBound.uuidString),
                "documentID": .string(document.uuidString),
                "canEdit": .boolean(true),
            ]))
        let absentRow = try await fixture.conversationStore.conversation(id: halfBound)
        XCTAssertNil(absentRow)

        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(opened["ok"] as? Bool, true, "\(opened)")
        XCTAssertEqual(opened["conversationID"] as? String, halfBound.uuidString,
                       "the retry must reuse the bound identity")
        XCTAssertEqual(opened["created"] as? Bool, true)
        let row = try await fixture.conversationStore.conversation(id: halfBound)
        XCTAssertEqual(row?.purpose, .notes)
        // The binding still points at this exact conversation.
        let grants = try await NotesAuthority(epoch: fixture.epoch)
            .grants(conversationID: halfBound)
        XCTAssertEqual(grants[document], true)
    }

    func testOpenNeverRetagsAnOrdinaryRow() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        let ordinary = try await fixture.makeOrdinaryConversation()
        // The REAL durable thread mapping names an ORDINARY row: it must be
        // refused, never rewritten into a Notes thread.
        _ = try await NotesDomainService.shared.handle(
            epoch: fixture.epoch,
            requestID: "foreign-bind",
            action: "assistant.bind",
            payload: .object([
                "conversationID": .string(ordinary.uuidString),
                "documentID": .string(document.uuidString),
                "canEdit": .boolean(true),
            ]))

        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(opened["ok"] as? Bool, false)
        XCTAssertEqual(opened["error"] as? String, NotesAssistantRefusal.Code.bindingRefused.rawValue)
        XCTAssertEqual(opened["reason"] as? String, "purposeNotNotes")
        let row = try await fixture.conversationStore.conversation(id: ordinary)
        XCTAssertEqual(row?.purpose, .ordinary)
    }

    func testOpenRefusesWhenTheNotesAuthorityIsNotBoundForThisEpoch() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        // Retire the exact-epoch Notes authority: the composer must refuse
        // instead of inventing a mapping or a second thread.
        await NotesDomainService.shared.retire(epoch: fixture.epoch)

        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(opened["ok"] as? Bool, false)
        XCTAssertEqual(opened["error"] as? String,
                       NotesAssistantRefusal.Code.authority.rawValue)
        let rows = try await fixture.conversationStore.conversations()
        XCTAssertTrue(rows.isEmpty, "no conversation may be invented before the mapping is readable")
    }

    // MARK: - Transcript

    func testTranscriptRestoresRolesAndDurableRunOutcomes() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        let conversationID = try XCTUnwrap(
            (opened["conversationID"] as? String).flatMap(UUID.init(uuidString:)))

        let completedRun = UUID()
        let cancelledRun = UUID()
        try await fixture.runStore.saveRun(RunRecord(
            id: completedRun, conversationID: conversationID, state: "completed",
            goal: "turn", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_010)))
        try await fixture.runStore.appendEvent(
            runID: completedRun, kind: .terminal,
            payloadJSON: #"{"stopReason":"endTurn"}"#)
        try await fixture.runStore.saveRun(RunRecord(
            id: cancelledRun, conversationID: conversationID, state: "completed",
            goal: "turn", startedAt: Date(timeIntervalSince1970: 1_790_000_020),
            endedAt: Date(timeIntervalSince1970: 1_790_000_030)))
        try await fixture.runStore.appendEvent(
            runID: cancelledRun, kind: .terminal,
            payloadJSON: #"{"stopReason":"cancelled"}"#)

        try await fixture.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user", content: "Hello",
            createdAt: Date(timeIntervalSince1970: 1_790_000_001), runID: completedRun))
        try await fixture.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant", content: "Hi",
            createdAt: Date(timeIntervalSince1970: 1_790_000_002), runID: completedRun))
        try await fixture.conversationStore.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant", content: "Stopped",
            createdAt: Date(timeIntervalSince1970: 1_790_000_021), runID: cancelledRun))

        let page = try await call(NotesAssistantActions.transcript, """
        {"conversationID":"\(conversationID.uuidString)","limit":10}
        """)
        XCTAssertEqual(page["ok"] as? Bool, true, "\(page)")
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["role"] as? String },
                       ["user", "assistant", "assistant"])
        XCTAssertEqual(entries.map { $0["text"] as? String }, ["Hello", "Hi", "Stopped"])
        XCTAssertEqual(entries[0]["outcome"] as? String, "COMPLETED")
        XCTAssertEqual(entries[1]["outcome"] as? String, "COMPLETED")
        XCTAssertEqual(entries[2]["outcome"] as? String, "CANCELLED")
        XCTAssertFalse(page["hasOlder"] as? Bool ?? true)

        // Opaque pagination: the newest page is bounded and reports older rows;
        // the cursor then addresses exactly the remaining older row.
        let newest = try await call(NotesAssistantActions.transcript, """
        {"conversationID":"\(conversationID.uuidString)","limit":2}
        """)
        let newestEntries = try XCTUnwrap(newest["entries"] as? [[String: Any]])
        XCTAssertEqual(newestEntries.map { $0["text"] as? String }, ["Hi", "Stopped"])
        XCTAssertEqual(newest["hasOlder"] as? Bool, true)
        let cursor = try XCTUnwrap(newest["olderCursor"] as? String)
        let older = try await call(NotesAssistantActions.transcript, """
        {"conversationID":"\(conversationID.uuidString)","limit":2,
         "olderCursor":"\(cursor)"}
        """)
        let olderEntries = try XCTUnwrap(older["entries"] as? [[String: Any]])
        XCTAssertEqual(olderEntries.map { $0["text"] as? String }, ["Hello"])
        XCTAssertEqual(older["hasOlder"] as? Bool, false)
    }

    func testTranscriptRefusesANonNotesConversation() async throws {
        let fixture = try await makeFixture()
        let ordinary = try await fixture.makeOrdinaryConversation()
        let page = try await call(NotesAssistantActions.transcript, """
        {"conversationID":"\(ordinary.uuidString)","limit":10}
        """)
        XCTAssertEqual(page["ok"] as? Bool, false)
        XCTAssertEqual(page["error"] as? String,
                       NotesAssistantRefusal.Code.conversationMissing.rawValue)
        XCTAssertEqual(page["reason"] as? String, "conversationNotNotes")
    }

    // MARK: - Root stop

    func testRootStopWithNoOwnedWorkDrainsAndReArms() async throws {
        let fixture = try await makeFixture()
        let stop = try await call(NotesAssistantActions.prepareRootStop, """
        {"epoch":\(fixture.epoch)}
        """)
        XCTAssertEqual(stop["ok"] as? Bool, true, "\(stop)")
        XCTAssertEqual(stop["canRetire"] as? Bool, true)
        XCTAssertEqual(stop["fenced"] as? Bool, true)
        XCTAssertEqual(stop["reason"] as? String, "drained")
        XCTAssertEqual((stop["pendingRunIDs"] as? [String])?.count, 0)

        // Fenced admission refuses a new open/start.
        let document = UUID()
        let blocked = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(blocked["error"] as? String, NotesAssistantRefusal.Code.busy.rawValue)

        let abort = try await call(NotesAssistantActions.abortRootStop, """
        {"epoch":\(fixture.epoch)}
        """)
        XCTAssertEqual(abort["ok"] as? Bool, true)
        XCTAssertEqual(abort["rearmed"] as? Bool, true)
        XCTAssertEqual(abort["fenced"] as? Bool, false)
    }

    func testAbortRefusesAnOlderEpochAndKeepsTheNewerFence() async throws {
        let fixture = try await makeFixture()
        _ = try await call(NotesAssistantActions.prepareRootStop, """
        {"epoch":\(fixture.epoch)}
        """)
        let stale = try await call(NotesAssistantActions.abortRootStop, """
        {"epoch":\(fixture.epoch - 1)}
        """)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, NotesAssistantRefusal.Code.staleRevision.rawValue)
        let status = try await call(NotesAssistantActions.status, "{}")
        XCTAssertEqual(status["availability"] as? String, "unavailable")
        XCTAssertEqual(status["reason"] as? String, "rootStopping")
    }

    // MARK: - Status

    func testStatusIsReadyOnlyWithARealConfiguredRoute() async throws {
        let fixture = try await makeFixture()
        let status = try await call(NotesAssistantActions.status, "{}")
        XCTAssertEqual(status["ok"] as? Bool, true, "\(status)")
        XCTAssertEqual(status["availability"] as? String, "ready")
        XCTAssertEqual(status["modelLabel"] as? String, "Fixture Model")
    }

    func testStatusReportsNotConfiguredWithoutADefaultModel() async throws {
        let fixture = try await makeFixture()
        var preferences = try await fixture.modelStore.preferences()
        preferences.defaultAgentModelID = nil
        try await fixture.modelStore.savePreferences(preferences)
        let status = try await call(NotesAssistantActions.status, "{}")
        XCTAssertEqual(status["availability"] as? String, "notConfigured")
        XCTAssertEqual(status["reason"] as? String, "modelUnavailable")
    }
}

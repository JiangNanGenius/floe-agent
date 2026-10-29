// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes assistant — canonical run.snapshot read over a REAL Notes run.
//
// The App-side stream adapter reads the same `run.snapshot` the ordinary
// conversation surface uses. This test proves the native contract it relies
// on: a Notes-owned run answers its own canonical page (durable state +
// terminal flag) and a foreign conversation can never read that run. It uses
// the REAL `FacadeRunDomain`, stores, model configuration and Notes authority.
import XCTest
import Foundation
import FloeModels
import FloePersistence
import FloeNotes
@testable import FloeAndroidCore

final class NotesRuntimeStreamTests: XCTestCase {
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
            .appendingPathComponent("floe-g06-notes-stream-\(UUID().uuidString)",
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

    // MARK: - Canonical snapshot

    func testRunSnapshotAnswersANotesConversationAndRefusesAForeignOne() async throws {
        let fixture = try await makeFixture()
        let document = try await seedDocument(fixture)
        let opened = try await call(NotesAssistantActions.open, """
        {"documentID":"\(document.uuidString)","title":"Seed"}
        """)
        XCTAssertEqual(opened["ok"] as? Bool, true, "\(opened)")
        let notesConversation = try XCTUnwrap(
            (opened["conversationID"] as? String).flatMap(UUID.init(uuidString:)))
        let domain = try XCTUnwrap(RunDomainFacade.current(epoch: fixture.epoch)?.0)

        // A real durable run row in the SAME store the Notes start path writes.
        // The App stream adapter reads its canonical page through the ordinary
        // taskExecution `run.snapshot` command (no Notes-only wire action).
        let notesRunID = UUID()
        try await fixture.runStore.saveRun(RunRecord(
            id: notesRunID,
            conversationID: notesConversation,
            state: "completed",
            goal: "Summarise the note",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_005),
            conversationMode: "chat"))
        let row = try await fixture.conversationStore.conversation(id: notesConversation)
        XCTAssertEqual(row?.purpose, .notes)

        let envelope = fixture.executionEnvelope(
            command: "run.snapshot", conversationID: notesConversation, runID: notesRunID,
            payload: nil, correlation: "notes-snapshot-1")
        let reply = await domain.snapshot(envelope: envelope)
        guard case .completedPage(let page, _) = reply.outcome else {
            return XCTFail("expected a canonical snapshot page, got \(reply.outcome)")
        }
        guard case .object(let object) = page.object else {
            return XCTFail("snapshot page must be an object")
        }
        if case .string(let pageRunID)? = object["runID"] {
            XCTAssertEqual(UUID(uuidString: pageRunID), notesRunID)
        } else {
            XCTFail("snapshot must carry runID")
        }
        XCTAssertEqual(object["isTerminal"], .boolean(true))
        XCTAssertEqual(object["durableState"], .string("completed"))
        if case .string(let pageConversation)? = object["conversationID"] {
            XCTAssertEqual(UUID(uuidString: pageConversation), notesConversation)
        } else {
            XCTFail("snapshot must carry the conversation identity")
        }

        // A foreign conversation cannot address this run through the canonical
        // read (the run's own conversation identity is checked natively).
        let foreignConversation = try await fixture.makeOrdinaryConversation()
        let foreign = fixture.executionEnvelope(
            command: "run.snapshot", conversationID: foreignConversation,
            runID: notesRunID, payload: nil, correlation: "notes-snapshot-foreign")
        let refused = await domain.snapshot(envelope: foreign)
        guard case .rejected(let error) = refused.outcome else {
            return XCTFail("a foreign conversation must be refused")
        }
        XCTAssertEqual(error.code, .notFound)
        XCTAssertEqual(error.reason, .runMissing)
    }
}


/// Pure native validation of the App's real editor focus. It proves the exact
/// revision/page/node/element checks and that selection is data only: it never
/// adds a readable/editable document or mints a grant.
final class NotesRunFocusResolverTests: XCTestCase {
    func testFocusIsValidatedAgainstTheExactDocumentAndGrantsNothing() throws {
        let element = NoteElement(kind: .text, text: "Hello")
        let page = NotePage(elements: [element])
        var document = NoteDocument(title: "Doc")
        document.revision = 4
        document.pages = [page]
        let unknownResource = UUID()
        let focus = NotesRunFocus(
            pageID: page.id, pageNumber: 1, selectedElementIDs: [element.id],
            selectedText: "Hello", attachmentResourceIDs: [unknownResource])

        let resolved = try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 4, focus: focus)
        XCTAssertEqual(resolved.focus.pageID, page.id)
        XCTAssertEqual(resolved.focus.pageNumber, 1)
        XCTAssertEqual(resolved.focus.selectedElementIDs, [element.id])
        XCTAssertTrue(resolved.focus.attachmentResourceIDs.isEmpty,
                      "an unreferenced resource is never a new context/grant")
        let text = try XCTUnwrap(resolved.contextText)
        XCTAssertTrue(text.contains(element.id.uuidString))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("document revision: 4"))
        XCTAssertTrue(text.contains("grants nothing"))

        let staleRevision = NotesRunFocus(
            pageID: page.id, selectedElementIDs: [element.id])
        XCTAssertThrowsError(try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 3, focus: staleRevision)) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.code, .staleRevision)
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason,
                           "documentRevisionMismatch")
        }

        var stalePage = staleRevision
        stalePage.pageID = UUID()
        XCTAssertThrowsError(try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 4, focus: stalePage)) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason, "pageMismatch")
        }

        var staleElement = staleRevision
        staleElement.selectedElementIDs = [UUID()]
        XCTAssertThrowsError(try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 4, focus: staleElement)) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason,
                           "selectionMismatch")
        }

        let selectionWithoutPage = NotesRunFocus(selectedElementIDs: [element.id])
        XCTAssertThrowsError(try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 4,
            focus: selectionWithoutPage)) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason,
                           "selectionWithoutPage")
        }
    }

    func testMindMapNodeAndBoundedTextAreResolvedWithoutSplittingAScalar() throws {
        var document = NoteDocument(kind: .mindMap, title: "Map")
        document.revision = 2
        let node = document.nodes[0]
        let longText = String(repeating: "é", count: 10_000)
        let focus = NotesRunFocus(
            nodeID: node.id, selectedText: longText,
            attachmentResourceIDs: document.resourceIDs.sorted { $0.uuidString < $1.uuidString })
        let resolved = try NotesRunFocusResolver.resolve(
            document: document, documentRevision: 2, focus: focus)
        XCTAssertEqual(resolved.focus.nodeID, node.id)
        let text = try XCTUnwrap(resolved.focus.selectedText)
        XCTAssertLessThanOrEqual(text.utf8.count, NotesRunFocusResolver.maxSelectedTextBytes)
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0xFFFD },
                       "byte truncation must not create a replacement scalar")
        let context = try XCTUnwrap(resolved.contextText)
        XCTAssertTrue(context.contains(node.id.uuidString))
        XCTAssertTrue(context.contains("Map"))
    }
}

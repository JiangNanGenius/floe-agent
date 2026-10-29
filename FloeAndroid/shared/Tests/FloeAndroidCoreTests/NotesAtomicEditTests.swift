import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeNotes

/// G06 staged whole-plan edit batches.
///
/// These run the real NotesEngine + real GRDB/SQLite NotesStore. A plan whose
/// serialized `[NoteEdit]` array is larger than the 64 KiB bridge request is
/// uploaded in bounded chunks, then must commit as ONE document revision, ONE
/// history/undo entry and ONE durable edit receipt. A failure anywhere in the
/// plan must leave the document, history, receipts and earlier bytes intact.
final class NotesAtomicEditTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func payload(_ json: String) throws -> NotesJSONValue {
        try NotesWire.decode(NotesJSONValue.self, from: Data(json.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func responseDocument(_ data: Data) throws -> NoteDocument {
        let value = try object(data)
        let encoded = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value["document"]))
        return try NotesWire.decode(NoteDocument.self, from: encoded)
    }

    @discardableResult
    private func request(_ engine: NotesEngine, _ action: String, _ json: String,
                         id: String = UUID().uuidString) async throws -> [String: Any] {
        try object(try await engine.perform(requestID: id, action: action,
                                            payload: try payload(json)))
    }

    private func createNote(_ engine: NotesEngine, title: String) async throws -> NoteDocument {
        let id = UUID()
        _ = try await request(engine, "document.create", """
        {"documentID":"\(id.uuidString)","kind":"notebook","title":"\(title)"}
        """)
        let read = try await request(engine, "document.get",
                                     #"{"documentID":"\#(id.uuidString)"}"#)
        return try responseDocument(try JSONSerialization.data(withJSONObject: read))
    }

    private func readDocument(_ engine: NotesEngine, _ id: UUID) async throws -> NoteDocument {
        let read = try await request(engine, "document.get",
                                     #"{"documentID":"\#(id.uuidString)"}"#)
        return try responseDocument(try JSONSerialization.data(withJSONObject: read))
    }

    private func grant(_ engine: NotesEngine, conversation: UUID, document: UUID,
                       canEdit: Bool) async throws {
        _ = try await request(engine, "assistant.grantAccess", """
        {"conversationID":"\(conversation.uuidString)","documentID":"\(document.uuidString)",
         "canEdit":\(canEdit)}
        """)
    }

    private func revoke(_ engine: NotesEngine, conversation: UUID, document: UUID) async throws {
        _ = try await request(engine, "assistant.revokeAccess", """
        {"conversationID":"\(conversation.uuidString)","documentID":"\(document.uuidString)"}
        """)
    }

    private func importResource(_ engine: NotesEngine, bytes: Data, fileName: String,
                                mediaType: String) async throws -> UUID {
        let begin = try await request(engine, "resource.importBegin", """
        {"fileName":"\(fileName)","mediaType":"\(mediaType)","byteCount":\(bytes.count)}
        """)
        let stageID = try XCTUnwrap(begin["stageID"] as? String)
        _ = try await request(engine, "resource.importAppend", """
        {"stageID":"\(stageID)","dataBase64":"\(bytes.base64EncodedString())"}
        """)
        let committed = try await request(engine, "resource.importCommit",
                                          #"{"stageID":"\#(stageID)"}"#)
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(committed["resourceID"] as? String)))
    }

    private func element(_ pageID: UUID, text: String, y: Double = 40,
                         markdown: Bool = false) -> [String: Any] {
        [
            "action": "upsertElement",
            "pageID": pageID.uuidString,
            "element": [
                "id": UUID().uuidString,
                "kind": "text",
                "frame": ["x": 40.0, "y": y, "width": 688.0, "height": 240.0],
                "text": text,
                "color": "#202020",
                "fontSize": 18.0,
                "isAIGenerated": false,
                "textFormat": markdown ? "markdown" : NSNull(),
            ],
        ]
    }

    private func page(_ index: Int) -> [String: Any] {
        [
            "action": "insertPage",
            "index": index,
            "page": [
                "id": UUID().uuidString,
                "width": 768.0,
                "height": 1024.0,
                "paper": "plain",
                "elements": [],
                "isBookmarked": false,
            ],
        ]
    }

    private func body(_ edits: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: edits, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func beginStage(_ engine: NotesEngine, documentID: UUID, expectedRevision: Int,
                            bytes: Data, title: String = "Large edit",
                            requestID: String? = nil, baseRevision: Int? = nil,
                            conversationID: UUID? = nil) async throws -> String {
        var json = """
        {"documentID":"\(documentID.uuidString)","expectedRevision":\(expectedRevision),
         "byteCount":\(bytes.count),"title":"\(title)"
        """
        if let requestID { json += ",\"requestID\":\"\(requestID)\"" }
        if let baseRevision { json += ",\"baseRevision\":\(baseRevision)" }
        if let conversationID { json += ",\"conversationID\":\"\(conversationID.uuidString)\"" }
        json += "}"
        let response = try await request(engine, "batch.stageBegin", json)
        XCTAssertEqual((response["totalBytes"] as? Int).map { Int64($0) }, Int64(bytes.count))
        return try XCTUnwrap(response["stageID"] as? String)
    }

    private func appendAll(_ engine: NotesEngine, stageID: String, bytes: Data) async throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 44_000, bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            let json = """
            {"stageID":"\(stageID)","offset":\(offset),"dataBase64":"\(chunk.base64EncodedString())"}
            """
            // The real bridge bound is 65,536 bytes including its envelope;
            // keep the staged append comfortably inside it.
            XCTAssertLessThan(json.utf8.count, 60_000)
            _ = try await request(engine, "batch.stageAppend", json)
            offset = end
        }
    }

    private func commitStage(_ engine: NotesEngine, stageID: String) async throws -> NoteDocument {
        let response = try await request(engine, "batch.stageCommit",
                                         #"{"stageID":"\#(stageID)"}"#)
        return try responseDocument(try JSONSerialization.data(withJSONObject: response))
    }

    private func apply(_ engine: NotesEngine, documentID: UUID, expectedRevision: Int,
                       edits: String, requestID: String = UUID().uuidString,
                       conversationID: UUID? = nil) async throws -> NoteDocument {
        var json = """
        {"documentID":"\(documentID.uuidString)","expectedRevision":\(expectedRevision),
         "title":"Small edit","requestID":"\(requestID)","edits":\(edits)
        """
        if let conversationID { json += ",\"conversationID\":\"\(conversationID.uuidString)\"" }
        json += "}"
        let response = try await request(engine, "document.apply", json)
        return try responseDocument(try JSONSerialization.data(withJSONObject: response))
    }

    private func canUndo(_ engine: NotesEngine, _ documentID: UUID) async throws -> Bool {
        let response = try await request(engine, "document.history",
                                         #"{"documentID":"\#(documentID.uuidString)"}"#)
        return response["canUndo"] as? Bool ?? false
    }

    private func stagedFiles(_ engine: NotesEngine) async throws -> [String] {
        let root = await engine.incomingRoot
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".editbatch-") }
    }

    // MARK: - One revision / one undo for a large page-aware plan

    func testLargeMultiPagePlanCommitsOnceAndUndoesOnce() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Import source")
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let text = "开头🙂 emoji 保持完整 — " + String(repeating: "内容", count: 10_000)
        let markdown = "# Heading\n\n" + String(repeating: "Para 段落\n", count: 2_000)

        var edits: [[String: Any]] = [
            ["action": "rename", "text": "Imported notebook"],
            page(1),
            page(2),
        ]
        edits.append(element(pageOne, text: text, y: 40))
        edits.append(element(pageOne, text: markdown, y: 320, markdown: true))
        edits.append(element(pageOne, text: "third block", y: 640))
        // Elements on the two pages created by the same batch.
        for inserted in edits.compactMap({ $0["page"] as? [String: Any] }) {
            let pageID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(inserted["id"] as? String)))
            edits.append(element(pageID, text: String(repeating: "page text 页面 ", count: 1_500)))
            edits.append(element(pageID, text: "tail 🙂", y: 320))
        }
        let serialized = try body(edits)
        let bytes = Data(serialized.utf8)
        XCTAssertGreaterThan(bytes.count, 65_536,
                             "the plan must exceed the 64 KiB bridge request bound")

        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           title: "Import text",
                                           requestID: "receipt-large-1")
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        let committed = try await commitStage(engine, stageID: stageID)

        XCTAssertEqual(committed.id, document.id)
        XCTAssertEqual(committed.revision, document.revision + 1, "one revision for the whole plan")
        XCTAssertEqual(committed.title, "Imported notebook")
        XCTAssertEqual(committed.pages.count, 3, "both inserted pages are present")
        XCTAssertEqual(committed.pages[0].elements.count, 3)
        XCTAssertEqual(committed.pages[0].elements[0].text, text, "exact Unicode text survives")
        XCTAssertTrue(committed.pages[0].elements[1].isMarkdown)
        XCTAssertEqual(committed.pages[1].elements.count, 2)
        XCTAssertEqual(committed.pages[2].elements.count, 2)
        let reread = try await readDocument(engine, document.id)
        XCTAssertEqual(reread.revision, committed.revision)

        // One undo reverts the entire user intent, not one element/page.
        let undone = try await request(engine, "document.undo", """
        {"documentID":"\(document.id.uuidString)","expectedRevision":\(committed.revision)}
        """)
        let restored = try responseDocument(try JSONSerialization.data(withJSONObject: undone))
        XCTAssertEqual(restored.revision, committed.revision + 1)
        XCTAssertEqual(restored.title, "Import source")
        XCTAssertEqual(restored.pages.count, 1)
        XCTAssertTrue(restored.pages[0].elements.isEmpty)

        await engine.retire()
    }

    // MARK: - Whole-plan failure semantics

    func testInvalidLastEditRollsBackTheWholePlan() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Atomic rollback")
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let edits: [[String: Any]] = [
            ["action": "rename", "text": "Should not persist"],
            page(1),
            element(pageOne, text: String(repeating: "valid prefix ", count: 2_000)),
            element(UUID(), text: "missing page", y: 20),
        ]
        let bytes = Data(try body(edits).utf8)
        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           requestID: "receipt-invalid-last")
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        do {
            _ = try await commitStage(engine, stageID: stageID)
            XCTFail("an edit against a missing page must fail the whole plan")
        } catch NoteError.notFound {
            // expected
        }
        let unchanged = try await readDocument(engine, document.id)
        XCTAssertEqual(unchanged.revision, document.revision)
        XCTAssertEqual(unchanged.title, "Atomic rollback")
        XCTAssertEqual(unchanged.pages.count, 1)
        XCTAssertTrue(unchanged.pages[0].elements.isEmpty)
        let history = try await canUndo(engine, document.id)
        XCTAssertFalse(history)
        _ = try await request(engine, "batch.stageAbort",
                              #"{"stageID":"\#(stageID)"}"#)
        await engine.retire()
    }

    func testStaleRevisionRefusesWithNoEarlierWrites() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Stale base")
        let afterFirst = try await apply(engine, documentID: document.id,
                                         expectedRevision: document.revision,
                                         edits: #"[{"action":"rename","text":"First rename"}]"#)
        XCTAssertEqual(afterFirst.revision, 2)

        let pageOne = try XCTUnwrap(afterFirst.pages.first?.id)
        let edits: [[String: Any]] = [
            ["action": "rename", "text": "Stale should fail"],
            element(pageOne, text: String(repeating: "stale plan ", count: 2_000)),
        ]
        let bytes = Data(try body(edits).utf8)
        // The whole plan is valid, but the declared revision is stale.
        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           requestID: "receipt-stale")
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        do {
            _ = try await commitStage(engine, stageID: stageID)
            XCTFail("a stale expected revision must conflict")
        } catch NoteError.conflict {
            // expected
        }
        let unchanged = try await readDocument(engine, document.id)
        XCTAssertEqual(unchanged.revision, 2)
        XCTAssertEqual(unchanged.title, "First rename")
        XCTAssertTrue(unchanged.pages[0].elements.isEmpty)
        await engine.retire()
    }

    func testRevokedConversationRefusesAtCommitWithNoWrites() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let document = try await createNote(engine, title: "Revocation")
        try await grant(engine, conversation: conversation, document: document.id, canEdit: true)
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let edits: [[String: Any]] = [
            ["action": "rename", "text": "Assistant edit"],
            element(pageOne, text: String(repeating: "revoked ", count: 2_000)),
        ]
        let bytes = Data(try body(edits).utf8)
        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           requestID: "receipt-revoked",
                                           conversationID: conversation)
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        // Revocation lands after staging but before commit; the commit must
        // re-check authority inside the store transaction.
        try await revoke(engine, conversation: conversation, document: document.id)
        do {
            _ = try await commitStage(engine, stageID: stageID)
            XCTFail("a revoked grant must refuse the staged commit")
        } catch NoteError.invalidOperation {
            // expected
        }
        let unchanged = try await readDocument(engine, document.id)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertEqual(unchanged.title, "Revocation")
        XCTAssertTrue(unchanged.pages[0].elements.isEmpty)
        let revokedHistory = try await canUndo(engine, document.id)
        XCTAssertFalse(revokedHistory)
        await engine.retire()
    }

    func testCrossNoteResourceRefusedByStagedCommit() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let target = try await createNote(engine, title: "Target")
        let other = try await createNote(engine, title: "Other")
        let targetPage = try XCTUnwrap(target.pages.first?.id)
        let otherPage = try XCTUnwrap(other.pages.first?.id)
        let foreign = try await importResource(engine, bytes: Data("foreign bytes".utf8),
                                               fileName: "foreign.png", mediaType: "image/png")
        _ = try await apply(engine, documentID: other.id, expectedRevision: other.revision, edits: """
        [{"action":"upsertElement","pageID":"\(otherPage.uuidString)",
          "element":{"id":"\(UUID().uuidString)","kind":"image",
                     "frame":{"x":10,"y":10,"width":120,"height":80},
                     "text":"","resourceID":"\(foreign.uuidString)",
                     "color":"#202020","fontSize":20,"isAIGenerated":false}}]
        """)
        try await grant(engine, conversation: conversation, document: target.id, canEdit: true)
        let imageEdits: [[String: Any]] = [
            ["action": "upsertElement", "pageID": targetPage.uuidString,
             "element": ["id": UUID().uuidString, "kind": "image",
                         "frame": ["x": 10.0, "y": 10.0, "width": 120.0, "height": 80.0],
                         "text": "", "resourceID": foreign.uuidString,
                         "color": "#202020", "fontSize": 20.0, "isAIGenerated": false]],
            element(targetPage, text: String(repeating: "other note resource ", count: 1_500), y: 40),
        ]
        let bytes = Data(try body(imageEdits).utf8)
        let stageID = try await beginStage(engine, documentID: target.id,
                                           expectedRevision: target.revision, bytes: bytes,
                                           requestID: "receipt-cross-note",
                                           conversationID: conversation)
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        do {
            _ = try await commitStage(engine, stageID: stageID)
            XCTFail("a resource referenced only by another note must be refused")
        } catch NoteError.invalidOperation(let reason) {
            XCTAssertEqual(reason, "resourceAccessDenied")
        }
        let unchanged = try await readDocument(engine, target.id)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertTrue(unchanged.pages[0].elements.isEmpty)
        let targetHistory = try await canUndo(engine, target.id)
        XCTAssertFalse(targetHistory)
        await engine.retire()
    }

    // MARK: - Staging bounds and exact offsets

    func testIncompleteOffsetAndOversizeRejectionsKeepTheStageRecoverable() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Offsets")
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let edits: [[String: Any]] = [element(pageOne, text: "incomplete then complete")]
        let bytes = Data(try body(edits).utf8)

        // Oversize declaration is refused before any staging file is created.
        do {
            _ = try await beginStage(engine, documentID: document.id,
                                     expectedRevision: document.revision,
                                     bytes: Data(repeating: 0x20,
                                                 count: Int(NotesEngine.maximumStagedEditBatchBytes) + 1))
            XCTFail("a batch above the staged bound must be a typed requestTooLarge")
        } catch NotesDomainError.requestTooLarge {
            // expected
        }

        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           requestID: "receipt-offset")
        let first = bytes.prefix(4)
        _ = try await request(engine, "batch.stageAppend", """
        {"stageID":"\(stageID)","offset":0,"dataBase64":"\(Data(first).base64EncodedString())"}
        """)
        // An inexact offset is refused and does not move the stage.
        do {
            _ = try await request(engine, "batch.stageAppend", """
            {"stageID":"\(stageID)","offset":0,"dataBase64":"\(Data([0x41]).base64EncodedString())"}
            """)
            XCTFail("a repeated offset must not duplicate bytes")
        } catch NotesDomainError.invalidPayload(let reason) {
            XCTAssertEqual(reason, "stageOffsetMismatch")
        }
        // An oversize chunk is refused.
        do {
            _ = try await request(engine, "batch.stageAppend", """
            {"stageID":"\(stageID)","offset":4,"dataBase64":"\(Data(repeating: 0x41, count: 44_001).base64EncodedString())"}
            """)
            XCTFail("a chunk above the bridge chunk bound must be refused")
        } catch NotesDomainError.requestTooLarge {
            // expected
        }
        // Commit before the declared byte count is a typed refusal; the stage
        // stays appendable so the upload can finish instead of becoming a
        // partial save.
        do {
            _ = try await commitStage(engine, stageID: stageID)
            XCTFail("an incomplete stage must not commit")
        } catch NotesDomainError.invalidPayload(let reason) {
            XCTAssertEqual(reason, "incompleteEditBatch")
        }
        let rest = bytes.dropFirst(4)
        _ = try await request(engine, "batch.stageAppend", """
        {"stageID":"\(stageID)","offset":4,"dataBase64":"\(Data(rest).base64EncodedString())"}
        """)
        let committed = try await commitStage(engine, stageID: stageID)
        XCTAssertEqual(committed.revision, 2)
        XCTAssertEqual(committed.pages[0].elements.count, 1)
        XCTAssertEqual(committed.pages[0].elements.first?.text, "incomplete then complete")
        await engine.retire()
    }

    // MARK: - Receipt idempotency

    func testRepeatedAndRestagedCommitReturnsTheSameReceiptWithoutDoubleEdit() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Receipt")
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let edits: [[String: Any]] = [
            ["action": "rename", "text": "Receipt applied"],
            element(pageOne, text: String(repeating: "receipt ", count: 2_000)),
        ]
        let bytes = Data(try body(edits).utf8)
        let stageID = try await beginStage(engine, documentID: document.id,
                                           expectedRevision: document.revision, bytes: bytes,
                                           requestID: "receipt-idempotent-1")
        try await appendAll(engine, stageID: stageID, bytes: bytes)
        let first = try await commitStage(engine, stageID: stageID)
        XCTAssertEqual(first.revision, 2)

        // Same live stage, replayed commit: exact same document, no revision.
        let replay = try await commitStage(engine, stageID: stageID)
        XCTAssertEqual(replay.revision, 2)
        XCTAssertEqual(replay.title, "Receipt applied")

        // Native restarted / stage expired after an uncertain dispatch: the
        // same bytes and the same receipt are staged again. The store receipt
        // de-duplicates the already-committed intent.
        let restaged = try await beginStage(engine, documentID: document.id,
                                            expectedRevision: document.revision, bytes: bytes,
                                            requestID: "receipt-idempotent-1")
        try await appendAll(engine, stageID: restaged, bytes: bytes)
        let reconciled = try await commitStage(engine, stageID: restaged)
        XCTAssertEqual(reconciled.revision, 2)
        XCTAssertEqual(reconciled.title, "Receipt applied")
        XCTAssertEqual(reconciled.pages[0].elements.count, 1)

        // Exactly one history row: one undo restores the pre-batch document.
        let undone = try await request(engine, "document.undo", """
        {"documentID":"\(document.id.uuidString)","expectedRevision":2}
        """)
        let restored = try responseDocument(try JSONSerialization.data(withJSONObject: undone))
        XCTAssertEqual(restored.revision, 3)
        XCTAssertEqual(restored.title, "Receipt")
        XCTAssertTrue(restored.pages[0].elements.isEmpty)
        await engine.retire()
    }

    // MARK: - Staging ownership cleanup

    func testAbortAndRetireCleanOnlyOwnedStaging() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let document = try await createNote(engine, title: "Cleanup")
        let pageOne = try XCTUnwrap(document.pages.first?.id)
        let bytes = Data(try body([element(pageOne, text: "cleanup")]).utf8)

        let first = try await beginStage(engine, documentID: document.id,
                                         expectedRevision: document.revision, bytes: bytes,
                                         requestID: "receipt-cleanup-1")
        let firstFiles = try await stagedFiles(engine)
        XCTAssertEqual(firstFiles.count, 1)
        try await request(engine, "batch.stageAbort", #"{"stageID":"\#(first)"}"#)
        let afterAbort = try await stagedFiles(engine)
        XCTAssertTrue(afterAbort.isEmpty)

        _ = try await beginStage(engine, documentID: document.id,
                                 expectedRevision: document.revision, bytes: bytes,
                                 requestID: "receipt-cleanup-2")
        _ = try await beginStage(engine, documentID: document.id,
                                 expectedRevision: document.revision, bytes: bytes,
                                 requestID: "receipt-cleanup-3")
        let twoFiles = try await stagedFiles(engine)
        XCTAssertEqual(twoFiles.count, 2)
        await engine.retire()
        let afterRetire = try await stagedFiles(engine)
        XCTAssertTrue(afterRetire.isEmpty)
        let open = await engine.isOpen()
        XCTAssertFalse(open)
    }
}

/// Registration seam for the staged edit-batch actions.
///
/// `NotesDomainService.actions` is the v4 whitelist (Main-owned). These checks
/// prove the real `BridgeV4` command path and `NotesDomainService.handle`
/// accept the four action names instead of returning `unsupportedAction`,
/// without binding a process-wide epoch (the refusal is the expected
/// `staleGeneration`/`notesNotBound` for an unbound epoch).
final class NotesAtomicBatchRegistrationTests: XCTestCase {
    private let stagedActions = [
        "batch.stageBegin", "batch.stageAppend", "batch.stageCommit", "batch.stageAbort",
    ]

    func testV4HandshakeAndServiceWhitelistAdvertiseTheStagedActions() throws {
        let handshake = BridgeV4.handshake()
        let advertised = try XCTUnwrap(handshake["actions"] as? [String])
        for action in stagedActions {
            XCTAssertTrue(advertised.contains(action), "handshake missing \(action)")
            XCTAssertTrue(NotesDomainService.actions.contains(action),
                          "service whitelist missing \(action)")
        }
    }

    func testV4CommandReachesServiceForEveryStagedAction() throws {
        for (index, action) in stagedActions.enumerated() {
            let data = Data("""
            {"version":4,"requestID":"reg-\(index)","operation":"command","epoch":9999,
             "action":"\(action)","payload":{"stageID":"missing-stage","offset":0,"dataBase64":"QQ=="}}
            """.utf8)
            let response = BridgeV4.handle(requestData: data, fallbackRequestID: "reg-\(index)")
            XCTAssertEqual(response["ok"] as? Bool, false)
            // The action passed the v4 whitelist and reached the live service;
            // an unbound epoch is the expected refusal, not an unknown action.
            XCTAssertNotEqual(response["error"] as? String, "unsupportedAction",
                              "\(action) is not registered")
        }
        let bogus = BridgeV4.handle(requestData: Data("""
        {"version":4,"requestID":"reg-bogus","operation":"command","epoch":9999,
         "action":"batch.stageBogus","payload":{}}
        """.utf8), fallbackRequestID: "reg-bogus")
        XCTAssertEqual(bogus["error"] as? String, "unsupportedAction")
    }

    func testServiceHandleRefusesUnboundEpochAfterAcceptingTheActionName() async throws {
        for action in stagedActions {
            do {
                _ = try await NotesDomainService.shared.handle(
                    epoch: 9_999, requestID: "reg-service-\(action)",
                    action: action, payload: try NotesWire.decode(
                        NotesJSONValue.self,
                        from: Data(#"{"stageID":"missing-stage"}"#.utf8)))
                XCTFail("an unbound epoch must not execute \(action)")
            } catch let error as NotesDomainError {
                XCTAssertEqual(error, .staleGeneration,
                               "\(action) should pass the action whitelist and fail binding, got \(error)")
            }
        }
        do {
            _ = try await NotesDomainService.shared.handle(
                epoch: 9_999, requestID: "reg-service-bogus", action: "batch.stageBogus",
                payload: NotesJSONValue.object([:]))
            XCTFail("an unknown action must be refused")
        } catch let error as NotesDomainError {
            guard case .unsupportedAction = error else {
                return XCTFail("expected unsupportedAction, got \(error)")
            }
        }
    }
}

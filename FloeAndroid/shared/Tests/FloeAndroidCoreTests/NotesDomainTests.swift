import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeNotes

final class NotesDomainTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-foundation-\(UUID().uuidString)", isDirectory: true)
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
        let object = try object(data)
        let value = try XCTUnwrap(object["document"])
        let encoded = try JSONSerialization.data(withJSONObject: value)
        return try NotesWire.decode(NoteDocument.self, from: encoded)
    }

    private func createNotebook(_ engine: NotesEngine, title: String) async throws -> (UUID, UUID) {
        let notebook = try await engine.perform(
            requestID: "nb-\(UUID().uuidString)", action: "notebook.create",
            payload: try payload(#"{"title":"\#(title)"}"#))
        let notebookResponse = try object(notebook)
        let notebookValue = try XCTUnwrap(notebookResponse["notebook"] as? [String: Any])
        let bookID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(notebookValue["id"] as? String)))
        let documentID = UUID()
        let doc = try await engine.perform(
            requestID: "doc-\(UUID().uuidString)", action: "document.create",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","kind":"notebook",
             "notebookID":"\(bookID.uuidString)","title":"\(title) note"}
            """))
        XCTAssertEqual(try responseDocument(doc).id, documentID)
        return (bookID, documentID)
    }

    func testPersistenceRevisionAndRebase() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "Life")
        let first = try await engine.perform(
            requestID: "read-1", action: "document.get",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#))
        let original = try responseDocument(first)
        XCTAssertEqual(original.revision, 1)

        let pageID = try XCTUnwrap(original.pages.first?.id)
        let elementID = UUID().uuidString
        let updated = try await engine.perform(
            requestID: "edit-1", action: "document.apply",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","expectedRevision":1,
             "title":"Rename","requestID":"receipt-1",
             "edits":[
               {"action":"rename","text":"Renamed notebook"},
               {"action":"upsertElement","pageID":"\(pageID.uuidString)",
                "element":{"id":"\(elementID)","kind":"text","frame":{"x":10,"y":20,"width":300,"height":80},
                           "text":"Hello 手记","color":"#202020","fontSize":18,"isAIGenerated":false}}
             ]}
            """))
        let edited = try responseDocument(updated)
        XCTAssertEqual(edited.revision, 2)
        XCTAssertEqual(edited.title, "Renamed notebook")
        XCTAssertEqual(edited.pages.first?.elements.count, 1)
        XCTAssertEqual(edited.pages.first?.elements.first?.text, "Hello 手记")

        await engine.retire()
        let reopened = try NotesEngine(root: root)
        let again = try responseDocument(try await reopened.perform(
            requestID: "read-2", action: "document.get",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#)))
        XCTAssertEqual(again.revision, 2)
        XCTAssertEqual(again.title, "Renamed notebook")
        XCTAssertEqual(again.pages.first?.elements.first?.text, "Hello 手记")
        await reopened.retire()
    }

    func testStaleRevisionConflictsAndReceiptReplays() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "Conflict")
        let payloadText = """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Edit",
         "requestID":"stable-receipt","edits":[{"action":"rename","text":"First"}]}
        """
        let first = try responseDocument(try await engine.perform(
            requestID: "outer-1", action: "document.apply", payload: try payload(payloadText)))
        XCTAssertEqual(first.revision, 2)

        // Same payload receipt is an idempotent replay, not a second revision.
        let replay = try responseDocument(try await engine.perform(
            requestID: "outer-2", action: "document.apply", payload: try payload(payloadText)))
        XCTAssertEqual(replay.revision, 2)

        do {
            _ = try await engine.perform(
                requestID: "outer-3", action: "document.apply",
                payload: try payload("""
                {"documentID":"\(documentID.uuidString)","expectedRevision":1,
                 "title":"Stale","edits":[{"action":"rename","text":"Stale"}]}
                """))
            XCTFail("stale revision must not commit")
        } catch NoteError.conflict {
            // expected
        } catch {
            XCTFail("expected NoteError.conflict, got \(error)")
        }
        await engine.retire()
    }

    func testTrashRestoreAndSearchAreDocumentScoped() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, firstID) = try await createNotebook(engine, title: "Searchable 手记")
        let (_, secondID) = try await createNotebook(engine, title: "Other")

        var found = try object(try await engine.perform(
            requestID: "s1", action: "search.query",
            payload: try payload(#"{"query":"手记","limit":50}"#)))
        let documents = try XCTUnwrap(found["documents"] as? [[String: Any]])
        XCTAssertTrue(documents.contains { ($0["id"] as? String) == firstID.uuidString })
        XCTAssertFalse(documents.contains { ($0["id"] as? String) == secondID.uuidString })

        let trashed = try responseDocument(try await engine.perform(
            requestID: "t1", action: "document.setTrashed",
            payload: try payload(#"{"documentID":"\#(firstID.uuidString)","expectedRevision":1,"trashed":true}"#)))
        XCTAssertNotNil(trashed.deletedAt)
        found = try object(try await engine.perform(
            requestID: "s2", action: "search.query",
            payload: try payload(#"{"query":"手记","limit":50}"#)))
        XCTAssertTrue((found["documents"] as? [[String: Any]])?.isEmpty == true)

        let restored = try responseDocument(try await engine.perform(
            requestID: "t2", action: "document.setTrashed",
            payload: try payload(#"{"documentID":"\#(firstID.uuidString)","expectedRevision":2,"trashed":false}"#)))
        XCTAssertNil(restored.deletedAt)
        await engine.retire()
    }

    func testResourceImportIsContentAddressedAndBounded() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let bytes = Data((0..<1_000).map { UInt8($0 % 251) })
        let beginObject = try object(try await engine.perform(
            requestID: "rb", action: "resource.importBegin",
            payload: try payload("""
            {"fileName":"pixel.png","mediaType":"image/png","byteCount":\(bytes.count)}
            """)))
        let stage = try XCTUnwrap(beginObject["stageID"] as? String)
        let chunk = bytes.prefix(400)
        _ = try await engine.perform(
            requestID: "ra1", action: "resource.importAppend",
            payload: try payload("""
            {"stageID":"\(stage)","dataBase64":"\(chunk.base64EncodedString())"}
            """))
        _ = try await engine.perform(
            requestID: "ra2", action: "resource.importAppend",
            payload: try payload("""
            {"stageID":"\(stage)","dataBase64":"\(bytes.dropFirst(400).base64EncodedString())"}
            """))
        let committed = try object(try await engine.perform(
            requestID: "rc", action: "resource.importCommit",
            payload: try payload(#"{"stageID":"\#(stage)"}"#)))
        let resourceID = try XCTUnwrap(committed["resourceID"] as? String)
        let hash = try XCTUnwrap(committed["sha256"] as? String)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(committed["byteCount"] as? Int, bytes.count)

        let read = try object(try await engine.perform(
            requestID: "rr", action: "resource.read",
            payload: try payload(#"{"resourceID":"\#(resourceID)","offset":0,"maxBytes":600}"#)))
        let first = try XCTUnwrap(read["dataBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: first), Data(bytes.prefix(600)))
        XCTAssertEqual(read["eof"] as? Bool, false)
        let second = try object(try await engine.perform(
            requestID: "rr2", action: "resource.read",
            payload: try payload(#"{"resourceID":"\#(resourceID)","offset":600,"maxBytes":600}"#)))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(second["dataBase64"] as? String)),
                       Data(bytes.dropFirst(600)))
        XCTAssertEqual(second["eof"] as? Bool, true)

        // Same bytes produce the same content-addressed resource.
        let dedupeBegin = try object(try await engine.perform(
            requestID: "rb2", action: "resource.importBegin",
            payload: try payload("""
            {"fileName":"same.png","mediaType":"image/png","byteCount":\(bytes.count)}
            """)))
        let dedupeStage = try XCTUnwrap(dedupeBegin["stageID"] as? String)
        _ = try await engine.perform(
            requestID: "ra3", action: "resource.importAppend",
            payload: try payload("""
            {"stageID":"\(dedupeStage)","dataBase64":"\(bytes.base64EncodedString())"}
            """))
        let deduped = try object(try await engine.perform(
            requestID: "rc2", action: "resource.importCommit",
            payload: try payload(#"{"stageID":"\#(dedupeStage)"}"#)))
        XCTAssertEqual(deduped["resourceID"] as? String, resourceID)
        await engine.retire()
    }

    func testArchiveImportCreatesIndependentDocumentsAndExcludesGrants() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (_, documentID) = try await createNotebook(engine, title: "Archive source")
        try await engine.perform(
            requestID: "g1", action: "assistant.grantAccess",
            payload: try payload("""
            {"conversationID":"\(conversation.uuidString)","documentID":"\(documentID.uuidString)","canEdit":true}
            """))

        let export = try object(try await engine.perform(
            requestID: "x1", action: "archive.export",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)","expectedRevision":1}"#)))
        let handle = try XCTUnwrap(export["handle"] as? String)
        let total = try XCTUnwrap(export["byteCount"] as? Int)
        var archive = Data()
        var offset = 0
        while offset < total {
            let chunk = try object(try await engine.perform(
                requestID: "xr-\(offset)", action: "archive.exportRead",
                payload: try payload("""
                {"handle":"\(handle)","offset":\(offset),"maxBytes":40000}
                """)))
            let data = try XCTUnwrap(chunk["dataBase64"] as? String)
            archive.append(try XCTUnwrap(Data(base64Encoded: data)))
            offset = try XCTUnwrap(chunk["nextOffset"] as? Int)
        }
        _ = try await engine.perform(
            requestID: "xc", action: "archive.exportClose",
            payload: try payload(#"{"handle":"\#(handle)"}"#))

        let importBegin = try object(try await engine.perform(
            requestID: "ib", action: "archive.importBegin",
            payload: try payload("""
            {"byteCount":\(archive.count)}
            """)))
        let importStage = try XCTUnwrap(importBegin["stageID"] as? String)
        var sendOffset = 0
        while sendOffset < archive.count {
            let end = min(archive.count, sendOffset + 40_000)
            let chunk = archive.subdata(in: sendOffset..<end)
            _ = try await engine.perform(
                requestID: "ia-\(sendOffset)", action: "archive.importAppend",
                payload: try payload("""
                {"stageID":"\(importStage)","dataBase64":"\(chunk.base64EncodedString())"}
                """))
            sendOffset = end
        }
        let imported = try object(try await engine.perform(
            requestID: "ic", action: "archive.importCommit",
            payload: try payload(#"{"stageID":"\#(importStage)"}"#)))
        let importedDocuments = try XCTUnwrap(imported["documents"] as? [[String: Any]])
        XCTAssertEqual(importedDocuments.count, 1)
        let importedID = try XCTUnwrap(importedDocuments[0]["id"] as? String)
        XCTAssertNotEqual(importedID, documentID.uuidString)

        let grants = try object(try await engine.perform(
            requestID: "g2", action: "assistant.grants",
            payload: try payload("""
            {"conversationID":"\(conversation.uuidString)"}
            """)))
        let grantMap = try XCTUnwrap(grants["grants"] as? [String: Bool])
        XCTAssertEqual(grantMap[documentID.uuidString], true)
        XCTAssertNil(grantMap[importedID])
        await engine.retire()
    }

    func testSaveMessageDoesNotCreateAGrantOrConversation() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let saved = try responseDocument(try await engine.perform(
            requestID: "m1", action: "document.saveMessage",
            payload: try payload(#"{"text":"An explicit saved answer","title":"Saved answer"}"#)))
        XCTAssertEqual(saved.kind, .notebook)
        XCTAssertEqual(saved.pages.first?.elements.first?.text, "An explicit saved answer")
        let grants = try object(try await engine.perform(
            requestID: "g", action: "assistant.grants",
            payload: try payload(#"{"conversationID":"\#(UUID().uuidString)"}"#)))
        XCTAssertTrue((grants["grants"] as? [String: Bool])?.isEmpty == true)
        await engine.retire()
    }

    func testPollCursorResyncNeverLeadsTheService() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        _ = try await createNotebook(engine, title: "Events")
        let first = try object(try await engine.perform(
            requestID: "p1", action: "poll",
            payload: try payload(#"{"cursor":0,"limit":128}"#)))
        XCTAssertEqual(first["resyncRequired"] as? Bool, false)
        XCTAssertFalse((first["events"] as? [[String: Any]])?.isEmpty ?? true)

        let ahead = try object(try await engine.perform(
            requestID: "p2", action: "poll",
            payload: try payload(#"{"cursor":9999,"limit":128}"#)))
        XCTAssertEqual(ahead["resyncRequired"] as? Bool, true)
        let sequence = try XCTUnwrap(ahead["sequence"] as? Int)
        let cursor = try XCTUnwrap(ahead["cursor"] as? Int)
        XCTAssertLessThanOrEqual(cursor, sequence)
        await engine.retire()
    }

    func testStagedLargeTextCommitsAsOneUndoableRevision() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "Paste")
        let current = try responseDocument(try await engine.perform(
            requestID: "read-p", action: "document.get",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#)))
        let pageID = try XCTUnwrap(current.pages.first?.id)
        let text = String(repeating: "很长的一段粘贴文本 / a long pasted line\n", count: 4_000)
        let bytes = Data(text.utf8)
        let begin = try object(try await engine.perform(
            requestID: "tb", action: "text.stageBegin",
            payload: try payload("""
            {"mode":"appendBlock","documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
             "expectedRevision":1,"title":"Paste","byteCount":\(bytes.count)}
            """)))
        let stage = try XCTUnwrap(begin["stageID"] as? String)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 40_000)
            let chunk = bytes.subdata(in: offset..<end)
            _ = try await engine.perform(
                requestID: "ta-\(offset)", action: "text.stageAppend",
                payload: try payload("""
                {"stageID":"\(stage)","dataBase64":"\(chunk.base64EncodedString())"}
                """))
            offset = end
        }
        let committed = try responseDocument(try await engine.perform(
            requestID: "tc", action: "text.stageCommit",
            payload: try payload(#"{"stageID":"\#(stage)"}"#)))
        XCTAssertEqual(committed.revision, 2)
        XCTAssertEqual(committed.pages.first?.elements.first?.text, text)
        let undo = try responseDocument(try await engine.perform(
            requestID: "tu", action: "document.undo",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","expectedRevision":2}
            """)))
        XCTAssertEqual(undo.revision, 3)
        XCTAssertTrue(undo.pages.first?.elements.isEmpty ?? false)
        await engine.retire()
    }

    func testStagedTextRefusesIncompleteCommitAndRetainsBytes() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "Incomplete")
        let current = try responseDocument(try await engine.perform(
            requestID: "read-i", action: "document.get",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#)))
        let pageID = try XCTUnwrap(current.pages.first?.id)
        let bytes = Data(repeating: 0x41, count: 120)
        let begin = try object(try await engine.perform(
            requestID: "ib", action: "text.stageBegin",
            payload: try payload("""
            {"mode":"appendBlock","documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
             "expectedRevision":1,"byteCount":120}
            """)))
        let stage = try XCTUnwrap(begin["stageID"] as? String)
        _ = try await engine.perform(
            requestID: "ia", action: "text.stageAppend",
            payload: try payload("""
            {"stageID":"\(stage)","dataBase64":"\(bytes.prefix(50).base64EncodedString())"}
            """))
        do {
            _ = try await engine.perform(
                requestID: "ic", action: "text.stageCommit",
                payload: try payload(#"{"stageID":"\#(stage)"}"#))
            XCTFail("incomplete staged text must not commit")
        } catch NotesDomainError.invalidPayload {
            // expected
        } catch {
            XCTFail("expected invalidPayload, got \(error)")
        }
        _ = try await engine.perform(
            requestID: "ia2", action: "text.stageAppend",
            payload: try payload("""
            {"stageID":"\(stage)","dataBase64":"\(bytes.dropFirst(50).base64EncodedString())"}
            """))
        let committed = try responseDocument(try await engine.perform(
            requestID: "ic2", action: "text.stageCommit",
            payload: try payload(#"{"stageID":"\#(stage)"}"#)))
        XCTAssertEqual(committed.revision, 2)
        XCTAssertEqual(committed.pages.first?.elements.first?.text.count, 120)
        await engine.retire()
    }

    func testPageOCRStateUsesTheNativeVisualIndexIdentity() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "OCR")
        let document = try responseDocument(try await engine.perform(
            requestID: "ocr-read", action: "document.get",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#)))
        let page = try XCTUnwrap(document.pages.first)
        let state = try object(try await engine.perform(
            requestID: "ocr-state", action: "document.pageOCRState",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","pageID":"\(page.id.uuidString)"}
            """)))
        XCTAssertEqual(state["visualIndexKey"] as? String, page.visualIndexKey)
        XCTAssertEqual(state["current"] as? Bool, false)
        XCTAssertNil(state["ocrSourceKey"])
        await engine.retire()
    }

    func testLibrarySummaryAndCoverSwapKeepIndependentVersions() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, documentID) = try await createNotebook(engine, title: "Cover")
        let summary = try object(try await engine.perform(
            requestID: "ls", action: "library.summary", payload: nil))
        let counts = try XCTUnwrap(summary["counts"] as? [String: Any])
        XCTAssertEqual(counts["documents"] as? Int, 1)
        XCTAssertEqual(counts["notebooks"] as? Int, 1)
        XCTAssertEqual((summary["recent"] as? [[String: Any]])?.count, 1)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
        let begin = try object(try await engine.perform(
            requestID: "cb", action: "resource.importBegin",
            payload: try payload("""
            {"fileName":"cover.png","mediaType":"image/png","byteCount":\(bytes.count)}
            """)))
        let stage = try XCTUnwrap(begin["stageID"] as? String)
        _ = try await engine.perform(
            requestID: "ca", action: "resource.importAppend",
            payload: try payload("""
            {"stageID":"\(stage)","dataBase64":"\(bytes.base64EncodedString())"}
            """))
        let resource = try object(try await engine.perform(
            requestID: "cc", action: "resource.importCommit",
            payload: try payload(#"{"stageID":"\#(stage)"}"#)))
        let resourceID = try XCTUnwrap(resource["resourceID"] as? String)
        let covered = try responseDocument(try await engine.perform(
            requestID: "cv1", action: "document.coverApply",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","expectedRevision":1,
             "expectedCoverRevision":0,"command":"useResource","resourceID":"\(resourceID)"}
            """)))
        XCTAssertEqual(covered.revision, 1)
        XCTAssertEqual(covered.coverResourceID?.uuidString, resourceID)
        let cover = try object(try await engine.perform(
            requestID: "cr", action: "document.coverRead",
            payload: try payload(#"{"documentID":"\#(documentID.uuidString)"}"#)))
        XCTAssertEqual(cover["coverMode"] as? String, "custom")
        XCTAssertEqual(cover["coverResourceID"] as? String, resourceID)
        XCTAssertEqual(cover["coverRevision"] as? Int, 1)
        let restored = try responseDocument(try await engine.perform(
            requestID: "cv2", action: "document.coverApply",
            payload: try payload("""
            {"documentID":"\(documentID.uuidString)","expectedRevision":1,
             "expectedCoverRevision":1,"command":"restoreAutomatic"}
            """)))
        XCTAssertNil(restored.coverResourceID)
        await engine.retire()
    }

    func testNotebookDeletionRefusesPopulatedAndDeletesEmpty() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (occupiedID, _) = try await createNotebook(engine, title: "Occupied")
        do {
            _ = try await engine.perform(
                requestID: "nd1", action: "notebook.delete",
                payload: try payload(#"{"notebookID":"\#(occupiedID.uuidString)"}"#))
            XCTFail("a populated notebook must not be deleted")
        } catch NoteError.invalidOperation {
            // expected
        }
        let empty = try object(try await engine.perform(
            requestID: "nb-empty", action: "notebook.create",
            payload: try payload(#"{"title":"Empty"}"#)))
        let emptyValue = try XCTUnwrap(empty["notebook"] as? [String: Any])
        let emptyID = try XCTUnwrap(emptyValue["id"] as? String)
        _ = try await engine.perform(
            requestID: "nd2", action: "notebook.delete",
            payload: try payload("""
            {"notebookID":"\(emptyID)"}
            """))
        let list = try object(try await engine.perform(
            requestID: "nl", action: "notebook.list", payload: nil))
        let notebooks = try XCTUnwrap(list["notebooks"] as? [[String: Any]])
        XCTAssertFalse(notebooks.contains { ($0["id"] as? String) == emptyID })
        XCTAssertTrue(notebooks.contains { ($0["id"] as? String) == occupiedID.uuidString })
        await engine.retire()
    }

    func testDuplicateDocumentIsIndependentAndIdempotent() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (_, sourceID) = try await createNotebook(engine, title: "Copy source")
        let newID = UUID()
        let first = try responseDocument(try await engine.perform(
            requestID: "d1", action: "document.duplicate",
            payload: try payload("""
            {"documentID":"\(sourceID.uuidString)","newDocumentID":"\(newID.uuidString)","title":"Copy"}
            """)))
        XCTAssertEqual(first.id, newID)
        XCTAssertEqual(first.revision, 1)
        XCTAssertNotEqual(first.id, sourceID)
        let replay = try responseDocument(try await engine.perform(
            requestID: "d2", action: "document.duplicate",
            payload: try payload("""
            {"documentID":"\(sourceID.uuidString)","newDocumentID":"\(newID.uuidString)","title":"Copy"}
            """)))
        XCTAssertEqual(replay.id, newID)
        XCTAssertEqual(replay.revision, 1)
        await engine.retire()
    }
}

final class NotesBridgeV4Tests: XCTestCase {
    func testHandshakeAdvertisesTheExactNotesSchema() throws {
        let handshake = BridgeV4.handshake()
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["version"] as? Int, 4)
        XCTAssertEqual(handshake["schema"] as? String, "floe.notes/4")
        let actions = try XCTUnwrap(handshake["actions"] as? [String])
        XCTAssertTrue(actions.contains("document.apply"))
        XCTAssertTrue(actions.contains("resource.importCommit"))
        XCTAssertTrue(actions.contains("archive.importCommit"))
        XCTAssertFalse(actions.contains("exec.shell"))
        XCTAssertEqual(handshake["chatAuthorities"] as? Bool, false)
    }

    func testCommandWithoutARequestIDAndOversizeRequestFailClosed() throws {
        let data = Data(#"{"version":4,"operation":"command","epoch":1,"action":"document.get"}"#.utf8)
        let missing = BridgeV4.handle(requestData: data, fallbackRequestID: nil)
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["error"] as? String, "invalidRequest")

        let oversized = BridgeV4.handle(requestData: Data(repeating: 0x7b, count: 65_537),
                                        fallbackRequestID: "x")
        XCTAssertEqual(oversized["ok"] as? Bool, false)
        XCTAssertEqual(oversized["error"] as? String, "requestTooLarge")
    }

    func testUnknownActionAndVersionAreRefused() throws {
        let unknown = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"x","operation":"command","epoch":1,"action":"exec.shell"}"#.utf8),
            fallbackRequestID: "x")
        XCTAssertEqual(unknown["error"] as? String, "unsupportedAction")

        let wrongVersion = BridgeV4.handle(
            requestData: Data(#"{"version":3,"requestID":"x","operation":"handshake"}"#.utf8),
            fallbackRequestID: "x")
        XCTAssertEqual(wrongVersion["error"] as? String, "invalidRequest")
    }

    /// The App adapter and the published `floe.notes/4` contract address the
    /// five closed operations with the `notes.` prefix. The host-test
    /// spellings remain accepted, but an App `notes.*` request must never
    /// die in the operation switch (the Alpha15 device failure).
    func testDocumentedPrefixedOperationsReachTheClosedSwitch() throws {
        let handshake = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p1","operation":"notes.handshake"}"#.utf8),
            fallbackRequestID: "p1")
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["schema"] as? String, "floe.notes/4")

        let status = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p2","operation":"notes.status"}"#.utf8),
            fallbackRequestID: "p2")
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual(status["protocol"] as? Int, 4)

        // No accepted runtime exists in this unit host. The request must get
        // past the operation vocabulary and receive the live-root refusal.
        let bind = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p3","operation":"notes.bind","epoch":9000000001}"#.utf8),
            fallbackRequestID: "p3")
        XCTAssertEqual(bind["ok"] as? Bool, false)
        XCTAssertEqual(bind["error"] as? String, "runtimeUnavailable")

        let command = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p4","operation":"notes.command","epoch":9000000001,"action":"library.summary"}"#.utf8),
            fallbackRequestID: "p4")
        XCTAssertEqual(command["ok"] as? Bool, false)
        XCTAssertEqual(command["error"] as? String, "staleGeneration")

        let poll = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p5","operation":"notes.poll","epoch":9000000001}"#.utf8),
            fallbackRequestID: "p5")
        XCTAssertEqual(poll["ok"] as? Bool, false)
        XCTAssertEqual(poll["error"] as? String, "staleGeneration")

        // The prefix does not widen the closed vocabulary.
        let unknown = BridgeV4.handle(
            requestData: Data(#"{"version":4,"requestID":"p6","operation":"notes.exec","epoch":9000000001}"#.utf8),
            fallbackRequestID: "p6")
        XCTAssertEqual(unknown["error"] as? String, "unsupportedOperation")
    }
}

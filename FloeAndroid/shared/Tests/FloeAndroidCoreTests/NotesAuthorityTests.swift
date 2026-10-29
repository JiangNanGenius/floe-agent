import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeNotes

/// G06 C5 authority regressions. These run the real NotesEngine/NotesStore,
/// real proposal/outbox file stores and the real note model; there is no fake
/// document database and no second proposal store.
final class NotesAuthorityTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-authority-\(UUID().uuidString)", isDirectory: true)
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

    private func request(_ engine: NotesEngine, _ action: String,
                         _ json: String, id: String = UUID().uuidString) async throws -> [String: Any] {
        try object(try await engine.perform(requestID: id, action: action,
                                            payload: try payload(json)))
    }

    private func createNote(_ engine: NotesEngine, title: String) async throws -> (UUID, NoteDocument) {
        let id = UUID()
        _ = try await request(engine, "document.create", """
        {"documentID":"\(id.uuidString)","kind":"notebook","title":"\(title)"}
        """)
        let document = try await request(engine, "document.get", """
        {"documentID":"\(id.uuidString)"}
        """)
        return (id, try responseDocument(try JSONSerialization.data(withJSONObject: document)))
    }

    private func readDocument(_ engine: NotesEngine, _ id: UUID) async throws -> NoteDocument {
        let value = try await request(engine, "document.get",
                                      #"{"documentID":"\#(id.uuidString)"}"#)
        return try responseDocument(try JSONSerialization.data(withJSONObject: value))
    }

    private func grant(_ engine: NotesEngine, conversation: UUID, document: UUID,
                       canEdit: Bool) async throws {
        _ = try await request(engine, "assistant.grantAccess", """
        {"conversationID":"\(conversation.uuidString)","documentID":"\(document.uuidString)",
         "canEdit":\(canEdit)}
        """)
    }

    private func importResource(_ engine: NotesEngine, bytes: Data, fileName: String,
                                mediaType: String, conversation: UUID? = nil,
                                document: UUID? = nil) async throws -> UUID {
        var begin = """
        {"fileName":"\(fileName)","mediaType":"\(mediaType)","byteCount":\(bytes.count)
        """
        if let conversation, let document {
            begin += """
            ,"conversationID":"\(conversation.uuidString)","documentID":"\(document.uuidString)"
            """
        }
        begin += "}"
        let stage = try await request(engine, "resource.importBegin", begin)
        let stageID = try XCTUnwrap(stage["stageID"] as? String)
        _ = try await request(engine, "resource.importAppend", """
        {"stageID":"\(stageID)","dataBase64":"\(bytes.base64EncodedString())"}
        """)
        let committed = try await request(engine, "resource.importCommit",
                                          #"{"stageID":"\#(stageID)"}"#)
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(committed["resourceID"] as? String)))
    }

    private func issueGrant(_ engine: NotesEngine, proposal: UUID, document: UUID) async throws -> String {
        let value = try await request(engine, "proposal.issueGrant", """
        {"proposalID":"\(proposal.uuidString)","documentID":"\(document.uuidString)"}
        """)
        let grant = try XCTUnwrap(value["grant"] as? [String: Any])
        return try XCTUnwrap(grant["grantID"] as? String)
    }

    private func proposalNotes(_ root: URL) -> NoteProposalStore {
        NoteProposalStore(root: root.appendingPathComponent("Proposals", isDirectory: true))
    }

    private func decisionOutbox(_ root: URL) -> NoteProposalOutbox {
        NoteProposalOutbox(root: root.appendingPathComponent("ProposalOutbox", isDirectory: true))
    }

    private func imageEdit(pageID: UUID, elementID: UUID, resourceID: UUID) -> String {
        """
        [{"action":"upsertElement","pageID":"\(pageID.uuidString)",
          "element":{"id":"\(elementID.uuidString)","kind":"image",
                     "frame":{"x":10,"y":10,"width":120,"height":80},
                     "text":"","resourceID":"\(resourceID.uuidString)",
                     "color":"#202020","fontSize":20,"isAIGenerated":true}}]
        """
    }

    // MARK: - Proposals

    func testProposalPreviewCreateGrantApplyAndOutboxAck() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let environment = "env-c5"
        let (documentID, document) = try await createNote(engine, title: "Proposal note")
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let elementID = UUID()
        try await grant(engine, conversation: conversation, document: documentID, canEdit: true)
        let edits = """
        [{"action":"rename","text":"Proposed title"},
         {"action":"upsertElement","pageID":"\(pageID.uuidString)",
          "element":{"id":"\(elementID.uuidString)","kind":"text",
                     "frame":{"x":20,"y":20,"width":300,"height":80},
                     "text":"Proposed body","color":"#202020","fontSize":18,
                     "isAIGenerated":true}}]
        """
        let createPayload = """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,
         "title":"Proposal title","edits":\(edits),
         "conversationID":"\(conversation.uuidString)","environmentID":"\(environment)"}
        """
        let preview = try await request(engine, "proposal.preview", createPayload)
        let previewValue = try XCTUnwrap(preview["preview"] as? [String: Any])
        XCTAssertEqual(previewValue["baseRevision"] as? Int, 1)
        XCTAssertEqual(previewValue["editCount"] as? Int, 2)
        XCTAssertEqual((previewValue["baseSHA256"] as? String)?.count, 64)
        let previewRevision = try await readDocument(engine, documentID).revision
        XCTAssertEqual(previewRevision, 1,
                       "preview must not persist or mutate the document")
        let pendingAfterPreview = try await request(engine, "proposal.list", """
        {"documentID":"\(documentID.uuidString)"}
        """)
        XCTAssertEqual((pendingAfterPreview["proposals"] as? [[String: Any]])?.count, 0)

        let created = try await request(engine, "proposal.create", createPayload)
        let proposalValue = try XCTUnwrap(created["proposal"] as? [String: Any])
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposalValue["id"] as? String)))
        XCTAssertEqual(proposalValue["status"] as? String, "pending")
        XCTAssertEqual(proposalValue["originConversationID"] as? String, conversation.uuidString)
        XCTAssertEqual(proposalValue["environmentID"] as? String, environment)
        let createdRevision = try await readDocument(engine, documentID).revision
        XCTAssertEqual(createdRevision, 1)

        let visible = try await request(engine, "proposal.list", """
        {"documentID":"\(documentID.uuidString)","conversationID":"\(conversation.uuidString)",
         "environmentID":"\(environment)"}
        """)
        XCTAssertEqual((visible["proposals"] as? [[String: Any]])?.count, 1)
        let foreign = try await request(engine, "proposal.list", """
        {"documentID":"\(documentID.uuidString)","conversationID":"\(UUID().uuidString)",
         "environmentID":"\(environment)"}
        """)
        XCTAssertEqual((foreign["proposals"] as? [[String: Any]])?.count, 0)

        do {
            _ = try await request(engine, "proposal.get", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "conversationID":"\(UUID().uuidString)","environmentID":"\(environment)"}
            """)
            XCTFail("a foreign task must not read another task's proposal")
        } catch NoteError.notFound {
            // expected
        }

        let grantID = try await issueGrant(engine, proposal: proposalID, document: documentID)
        let applyID = NoteProposalService.applyRequestID(proposalID: proposalID)
        do {
            _ = try await request(engine, "proposal.apply", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "grantID":"\(grantID)","requestID":"unrelated-edit-receipt",
             "conversationID":"\(conversation.uuidString)","environmentID":"\(environment)"}
            """)
            XCTFail("an arbitrary receipt id must not masquerade as this proposal's apply")
        } catch NotesDomainError.invalidPayload(let reason) {
            XCTAssertEqual(reason, "proposalRequestIDMismatch")
        }
        let applyPayload = """
        {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
         "grantID":"\(grantID)","requestID":"\(applyID)",
         "conversationID":"\(conversation.uuidString)","environmentID":"\(environment)"}
        """
        let applied = try await request(engine, "proposal.apply", applyPayload)
        let appliedDocument = try responseDocument(try JSONSerialization.data(withJSONObject: applied))
        XCTAssertEqual(appliedDocument.revision, 2)
        XCTAssertEqual(appliedDocument.title, "Proposed title")
        XCTAssertEqual(appliedDocument.pages.first?.elements.last?.text, "Proposed body")
        let result = try XCTUnwrap(applied["result"] as? [String: Any])
        XCTAssertEqual(result["replayed"] as? Bool, false)

        // Transport retry with the consumed grant and the same receipt.
        let replay = try await request(engine, "proposal.apply", applyPayload)
        let replayDocument = try responseDocument(try JSONSerialization.data(withJSONObject: replay))
        XCTAssertEqual(replayDocument.revision, 2)
        XCTAssertEqual((replay["result"] as? [String: Any])?["replayed"] as? Bool, true)

        let outbox = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)","limit":10}
        """)
        let decisions = try XCTUnwrap(outbox["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.count, 1)
        let decision = decisions[0]
        XCTAssertEqual(decision["decision"] as? String, "accepted")
        XCTAssertEqual(decision["revision"] as? Int, 2)
        XCTAssertEqual(decision["ready"] as? Bool, true)
        let intentID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(decision["intentID"] as? String)))
        let eventID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(decision["eventID"] as? String)))

        do {
            _ = try await request(engine, "proposal.outboxAck", """
            {"intentID":"\(intentID.uuidString)","eventID":"\(UUID().uuidString)"}
            """)
            XCTFail("a mismatched event id must not acknowledge the intent")
        } catch NotesDomainError.invalidPayload(let reason) {
            XCTAssertEqual(reason, "eventMismatch")
        }
        let ack = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(intentID.uuidString)","eventID":"\(eventID.uuidString)"}
        """)
        XCTAssertEqual((ack["ack"] as? [String: Any])?["alreadyDelivered"] as? Bool, false)
        let again = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(intentID.uuidString)","eventID":"\(eventID.uuidString)"}
        """)
        XCTAssertEqual((again["ack"] as? [String: Any])?["alreadyDelivered"] as? Bool, true)
        let empty = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((empty["decisions"] as? [[String: Any]])?.count, 0)
        await engine.retire()
    }

    func testReissuingProposalGrantInvalidatesTheOlderGrant() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (documentID, _) = try await createNote(engine, title: "Grant replacement")
        try await grant(engine, conversation: conversation, document: documentID, canEdit: true)
        let created = try await request(engine, "proposal.create", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Once",
         "edits":[{"action":"rename","text":"Applied once"}],
         "conversationID":"\(conversation.uuidString)"}
        """)
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            (created["proposal"] as? [String: Any])?["id"] as? String)))
        let firstGrant = try await issueGrant(engine, proposal: proposalID, document: documentID)
        let secondGrant = try await issueGrant(engine, proposal: proposalID, document: documentID)
        XCTAssertNotEqual(firstGrant, secondGrant)

        do {
            _ = try await request(engine, "proposal.apply", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "grantID":"\(firstGrant)","conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("the replaced grant must not apply")
        } catch NoteError.invalidOperation {
            // expected
        }
        let unchanged = try await readDocument(engine, documentID)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertEqual(unchanged.title, "Grant replacement")

        let applied = try await request(engine, "proposal.apply", """
        {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
         "grantID":"\(secondGrant)","conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual(try responseDocument(try JSONSerialization.data(withJSONObject: applied)).revision, 2)
        await engine.retire()
    }

    func testRejectDecisionIsDurableIdempotentAndAcknowledged() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (documentID, _) = try await createNote(engine, title: "Reject proposal")
        try await grant(engine, conversation: conversation, document: documentID, canEdit: true)
        let created = try await request(engine, "proposal.create", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Reject me",
         "edits":[{"action":"rename","text":"Never"}],
         "conversationID":"\(conversation.uuidString)"}
        """)
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            (created["proposal"] as? [String: Any])?["id"] as? String)))

        do {
            _ = try await request(engine, "proposal.resolve", """
            {"proposalID":"\(proposalID.uuidString)","decision":"accepted",
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("acceptance cannot be recorded through resolve")
        } catch NotesDomainError.invalidPayload {
            // expected
        }
        let rejected = try await request(engine, "proposal.resolve", """
        {"proposalID":"\(proposalID.uuidString)","decision":"rejected",
         "conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((rejected["proposal"] as? [String: Any])?["status"] as? String, "resolved")
        XCTAssertEqual((rejected["proposal"] as? [String: Any])?["resolvedDecision"] as? String, "rejected")
        let repeated = try await request(engine, "proposal.resolve", """
        {"proposalID":"\(proposalID.uuidString)","decision":"rejected",
         "conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((repeated["proposal"] as? [String: Any])?["resolvedDecision"] as? String, "rejected")
        do {
            _ = try await request(engine, "proposal.resolve", """
            {"proposalID":"\(proposalID.uuidString)","decision":"invalidated",
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a different terminal decision must conflict")
        } catch NoteError.conflict {
            // expected
        }
        do {
            _ = try await issueGrant(engine, proposal: proposalID, document: documentID)
            XCTFail("a resolved proposal must not receive a new apply grant")
        } catch NoteError.invalidOperation {
            // expected
        }

        let outbox = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        let decision = try XCTUnwrap((outbox["decisions"] as? [[String: Any]])?.first)
        XCTAssertEqual(decision["decision"] as? String, "rejected")
        XCTAssertEqual(decision["ready"] as? Bool, true)
        let ack = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(try XCTUnwrap(decision["intentID"] as? String))",
         "eventID":"\(try XCTUnwrap(decision["eventID"] as? String))"}
        """)
        XCTAssertEqual((ack["ack"] as? [String: Any])?["decision"] as? String, "rejected")
        do {
            _ = try await request(engine, "proposal.get", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a delivered rejection removes the resolved proposal file")
        } catch NoteError.notFound {
            // expected
        }
        let empty = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((empty["decisions"] as? [[String: Any]])?.count, 0)
        await engine.retire()
    }

    func testRevokedGrantBlocksApplyAndOwnedImportCommit() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (documentID, initialDocument) = try await createNote(engine, title: "Revocation")
        let revokedPage = try XCTUnwrap(initialDocument.pages.first)
        try await grant(engine, conversation: conversation, document: documentID, canEdit: true)
        let created = try await request(engine, "proposal.create", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Revoked",
         "edits":[{"action":"rename","text":"Never committed"}],
         "conversationID":"\(conversation.uuidString)"}
        """)
        let proposal = try XCTUnwrap(created["proposal"] as? [String: Any])
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
        let grantID = try await issueGrant(engine, proposal: proposalID, document: documentID)

        // Begin an owned import while the grant is live, then revoke before commit.
        let bytes = Data("revoked attachment".utf8)
        let begin = try await request(engine, "resource.importBegin", """
        {"fileName":"revoked.txt","mediaType":"text/plain","byteCount":\(bytes.count),
         "conversationID":"\(conversation.uuidString)","documentID":"\(documentID.uuidString)"}
        """)
        let stageID = try XCTUnwrap(begin["stageID"] as? String)
        _ = try await request(engine, "resource.importAppend", """
        {"stageID":"\(stageID)","dataBase64":"\(bytes.base64EncodedString())"}
        """)

        _ = try await request(engine, "assistant.revokeAccess", """
        {"conversationID":"\(conversation.uuidString)","documentID":"\(documentID.uuidString)"}
        """)

        do {
            _ = try await request(engine, "resource.importCommit", #"{"stageID":"\#(stageID)"}"#)
            XCTFail("a revoked conversation must not commit an owned import")
        } catch NoteError.invalidOperation {
            // expected
        }
        _ = try await request(engine, "resource.importAbort", #"{"stageID":"\#(stageID)"}"#)

        do {
            _ = try await request(engine, "proposal.apply", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "grantID":"\(grantID)","conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a revoked conversation must not apply a proposal")
        } catch NoteError.invalidOperation {
            // expected
        }
        do {
            _ = try await request(engine, "document.apply", """
            {"documentID":"\(documentID.uuidString)","expectedRevision":1,
             "conversationID":"\(conversation.uuidString)",
             "edits":[{"action":"rename","text":"Late"}]}
            """)
            XCTFail("direct assistant edits must be blocked after revocation")
        } catch NoteError.invalidOperation {
            // expected
        }
        do {
            _ = try await request(engine, "document.cachePageOCR", """
            {"documentID":"\(documentID.uuidString)","pageID":"\(revokedPage.id.uuidString)",
             "sourceKey":"\(revokedPage.visualIndexKey)","text":"late OCR",
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a revoked conversation must not write the search cache")
        } catch NoteError.invalidOperation {
            // expected
        }
        let unchanged = try await readDocument(engine, documentID)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertEqual(unchanged.title, "Revocation")

        // No acceptance was committed, so no decision intent exists.
        let outbox = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((outbox["decisions"] as? [[String: Any]])?.count, 0)
        await engine.retire()
    }

    func testAssistantCrossDocumentResourceIsDeniedButOwnedImportIsAllowed() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (targetID, target) = try await createNote(engine, title: "Target note")
        let (otherID, other) = try await createNote(engine, title: "Other note")
        let otherPage = try XCTUnwrap(other.pages.first?.id)
        let targetPage = try XCTUnwrap(target.pages.first?.id)
        let foreignResource = try await importResource(
            engine, bytes: Data("other note attachment".utf8),
            fileName: "other.png", mediaType: "image/png")
        // Attach the resource to the other note through the human/UI path.
        _ = try await request(engine, "document.apply", """
        {"documentID":"\(otherID.uuidString)","expectedRevision":1,"title":"Attach",
         "edits":\(imageEdit(pageID: otherPage, elementID: UUID(), resourceID: foreignResource))}
        """)

        try await grant(engine, conversation: conversation, document: targetID, canEdit: true)
        let denied = """
        {"documentID":"\(targetID.uuidString)","expectedRevision":1,"title":"Cross-doc",
         "edits":\(imageEdit(pageID: targetPage, elementID: UUID(), resourceID: foreignResource)),
         "conversationID":"\(conversation.uuidString)"}
        """
        do {
            _ = try await request(engine, "proposal.preview", denied)
            XCTFail("a known resource from another note must be refused")
        } catch NoteError.invalidOperation(let reason) {
            XCTAssertEqual(reason, "resourceAccessDenied")
        }
        do {
            _ = try await request(engine, "document.apply", """
            {"documentID":"\(targetID.uuidString)","expectedRevision":1,"title":"Cross-doc",
             "edits":\(imageEdit(pageID: targetPage, elementID: UUID(), resourceID: foreignResource)),
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("the write transaction must also refuse the cross-document resource")
        } catch NoteError.invalidOperation(let reason) {
            XCTAssertEqual(reason, "resourceAccessDenied")
        }
        let targetRevision = try await readDocument(engine, targetID).revision
        XCTAssertEqual(targetRevision, 1)
        let pending = try await request(engine, "proposal.list", """
        {"documentID":"\(targetID.uuidString)"}
        """)
        XCTAssertEqual((pending["proposals"] as? [[String: Any]])?.count, 0)

        // A resource imported by this exact conversation/document is allowed.
        let ownedBytes = Data("fresh owned attachment".utf8)
        let owned = try await importResource(
            engine, bytes: ownedBytes,
            fileName: "owned.png", mediaType: "image/png",
            conversation: conversation, document: targetID)

        // UI reads stay unscoped; assistant reads require a readable document
        // reference or this conversation's owned import.
        let foreignBytes = Data("other note attachment".utf8)
        let uiRead = try await request(engine, "resource.read", """
        {"resourceID":"\(foreignResource.uuidString)","offset":0,"maxBytes":100}
        """)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(uiRead["dataBase64"] as? String)),
                       foreignBytes)
        let ownedRead = try await request(engine, "resource.read", """
        {"resourceID":"\(owned.uuidString)","offset":0,"maxBytes":100,
         "conversationID":"\(conversation.uuidString)","documentID":"\(targetID.uuidString)"}
        """)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(ownedRead["dataBase64"] as? String)),
                       ownedBytes)
        do {
            _ = try await request(engine, "resource.read", """
            {"resourceID":"\(foreignResource.uuidString)","offset":0,"maxBytes":100,
             "conversationID":"\(conversation.uuidString)","documentID":"\(targetID.uuidString)"}
            """)
            XCTFail("a resource referenced only by another note must not be read")
        } catch NoteError.invalidOperation(let reason) {
            XCTAssertEqual(reason, "resourceAccessDenied")
        }
        do {
            _ = try await request(engine, "resource.read", """
            {"resourceID":"\(foreignResource.uuidString)","offset":0,"maxBytes":100,
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a foreign resource must not be readable through a bare conversation")
        } catch NoteError.invalidOperation(let reason) {
            XCTAssertEqual(reason, "resourceAccessDenied")
        }
        do {
            _ = try await request(engine, "resource.read", """
            {"resourceID":"\(foreignResource.uuidString)","offset":0,"maxBytes":100,
             "conversationID":"\(conversation.uuidString)","documentID":"\(otherID.uuidString)"}
            """)
            XCTFail("reading through an unauthorized document must fail")
        } catch NoteError.invalidOperation {
            // expected
        }

        let created = try await request(engine, "proposal.create", """
        {"documentID":"\(targetID.uuidString)","expectedRevision":1,"title":"Owned",
         "edits":\(imageEdit(pageID: targetPage, elementID: UUID(), resourceID: owned)),
         "conversationID":"\(conversation.uuidString)"}
        """)
        let proposal = try XCTUnwrap(created["proposal"] as? [String: Any])
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(proposal["id"] as? String)))
        let grantID = try await issueGrant(engine, proposal: proposalID, document: targetID)
        let applied = try await request(engine, "proposal.apply", """
        {"proposalID":"\(proposalID.uuidString)","documentID":"\(targetID.uuidString)",
         "grantID":"\(grantID)","conversationID":"\(conversation.uuidString)"}
        """)
        let updated = try responseDocument(try JSONSerialization.data(withJSONObject: applied))
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.pages.first?.elements.last?.resourceID, owned)
        await engine.retire()
    }

    // MARK: - Index cache

    func testStalePageOCRAndOfficeTextNeverOverwriteNewerContent() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let (documentID, document) = try await createNote(engine, title: "OCR note")
        let pageID = try XCTUnwrap(document.pages.first?.id)
        let firstKey = try XCTUnwrap(document.pages.first?.visualIndexKey)

        let applied = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(firstKey)","text":"积分公式"}
        """)
        let appliedReceipt = try XCTUnwrap(applied["cache"] as? [String: Any])
        XCTAssertEqual(appliedReceipt["status"] as? String, "applied")
        XCTAssertEqual(appliedReceipt["indexed"] as? Bool, true)
        let ocrRevision = try await readDocument(engine, documentID).revision
        XCTAssertEqual(ocrRevision, 1)
        let searchable = try await request(engine, "search.query", #"{"query":"积分"}"#)
        XCTAssertEqual((searchable["documents"] as? [[String: Any]])?.count, 1)

        let unchanged = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(firstKey)","text":"积分公式"}
        """)
        XCTAssertEqual((unchanged["cache"] as? [String: Any])?["status"] as? String, "unchanged")

        _ = try await request(engine, "document.apply", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Annotate",
         "edits":[{"action":"upsertElement","pageID":"\(pageID.uuidString)",
                   "element":{"id":"\(UUID().uuidString)","kind":"text",
                              "frame":{"x":30,"y":30,"width":200,"height":60},
                              "text":"新的批注","color":"#202020","fontSize":18,
                              "isAIGenerated":false}}]}
        """)
        let edited = try await readDocument(engine, documentID)
        XCTAssertEqual(edited.revision, 2)
        let secondKey = try XCTUnwrap(edited.pages.first?.visualIndexKey)
        XCTAssertNotEqual(firstKey, secondKey)

        let stale = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(firstKey)","text":"迟到的识别"}
        """)
        let staleReceipt = try XCTUnwrap(stale["cache"] as? [String: Any])
        XCTAssertEqual(staleReceipt["status"] as? String, "stale")
        XCTAssertEqual(staleReceipt["reason"] as? String, "sourceChanged")
        XCTAssertEqual(staleReceipt["currentKey"] as? String, secondKey)
        XCTAssertEqual(staleReceipt["retryable"] as? Bool, false)
        let noLate = try await request(engine, "search.query", #"{"query":"迟到"}"#)
        XCTAssertEqual((noLate["documents"] as? [[String: Any]])?.count, 0)

        let fenced = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(secondKey)","text":"版本不符","expectedRevision":1}
        """)
        XCTAssertEqual((fenced["cache"] as? [String: Any])?["status"] as? String, "stale")
        XCTAssertEqual((fenced["cache"] as? [String: Any])?["reason"] as? String, "revisionMismatch")

        let current = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(secondKey)","text":"新的识别"}
        """)
        XCTAssertEqual((current["cache"] as? [String: Any])?["status"] as? String, "applied")
        let fresh = try await request(engine, "search.query", #"{"query":"新的"}"#)
        XCTAssertEqual((fresh["documents"] as? [[String: Any]])?.count, 1)

        // A stored provider error is an applied, retryable cache state.
        let providerError = try await request(engine, "document.cachePageOCR", """
        {"documentID":"\(documentID.uuidString)","pageID":"\(pageID.uuidString)",
         "sourceKey":"\(secondKey)","text":null,"error":"vision offline"}
        """)
        let errorReceipt = try XCTUnwrap(providerError["cache"] as? [String: Any])
        XCTAssertEqual(errorReceipt["status"] as? String, "applied")
        XCTAssertEqual(errorReceipt["retryable"] as? Bool, true)
        XCTAssertEqual(errorReceipt["indexed"] as? Bool, false)
        XCTAssertEqual(errorReceipt["error"] as? String, "vision offline")

        // Office text follows the exact immutable resource.
        let firstBytes = Data("office one".utf8)
        let firstResource = try await importResource(
            engine, bytes: firstBytes, fileName: "one.docx",
            mediaType: "application/octet-stream")
        let createdOffice = try await request(engine, "document.create", """
        {"documentID":"\(UUID().uuidString)","kind":"office","title":"Office cache",
         "resourceID":"\(firstResource.uuidString)","fileName":"one.docx"}
        """)
        let office = try responseDocument(try JSONSerialization.data(withJSONObject: createdOffice))
        let officeState = try await request(engine, "document.officeTextState",
                                           #"{"documentID":"\#(office.id.uuidString)"}"#)
        XCTAssertEqual((officeState["state"] as? [String: Any])?["current"] as? Bool, false)
        XCTAssertEqual((officeState["state"] as? [String: Any])?["retryable"] as? Bool, true)

        let officeApplied = try await request(engine, "document.cacheOfficeText", """
        {"documentID":"\(office.id.uuidString)","sourceResourceID":"\(firstResource.uuidString)",
         "text":"边际成本"}
        """)
        XCTAssertEqual((officeApplied["cache"] as? [String: Any])?["status"] as? String, "applied")
        let officeRevision = try await readDocument(engine, office.id).revision
        XCTAssertEqual(officeRevision, 1)
        let marginalCount = try await searchCount(engine, "边际")
        XCTAssertEqual(marginalCount, 1)

        let secondResource = try await importResource(
            engine, bytes: Data("office two".utf8), fileName: "two.docx",
            mediaType: "application/octet-stream")
        _ = try await request(engine, "document.apply", """
        {"documentID":"\(office.id.uuidString)","expectedRevision":1,"title":"Replace",
         "edits":[{"action":"replaceOfficeResource","resourceID":"\(secondResource.uuidString)"}]}
        """)
        let replaced = try await readDocument(engine, office.id)
        XCTAssertEqual(replaced.revision, 2)
        let staleMarginalCount = try await searchCount(engine, "边际")
        XCTAssertEqual(staleMarginalCount, 0)

        let officeStale = try await request(engine, "document.cacheOfficeText", """
        {"documentID":"\(office.id.uuidString)","sourceResourceID":"\(firstResource.uuidString)",
         "text":"迟到的提取"}
        """)
        let officeStaleValue = try XCTUnwrap(officeStale["cache"] as? [String: Any])
        XCTAssertEqual(officeStaleValue["status"] as? String, "stale")
        XCTAssertEqual(officeStaleValue["reason"] as? String, "sourceChanged")
        let lateOfficeCount = try await searchCount(engine, "迟到")
        XCTAssertEqual(lateOfficeCount, 0)
        let unchangedOffice = try await readDocument(engine, office.id)
        XCTAssertEqual(unchangedOffice.officeTextResourceID, firstResource)
        XCTAssertEqual(unchangedOffice.officeResourceID, secondResource)

        let officeCurrent = try await request(engine, "document.cacheOfficeText", """
        {"documentID":"\(office.id.uuidString)","sourceResourceID":"\(secondResource.uuidString)",
         "text":"新内容"}
        """)
        XCTAssertEqual((officeCurrent["cache"] as? [String: Any])?["status"] as? String, "applied")
        let freshOfficeCount = try await searchCount(engine, "新内容")
        XCTAssertEqual(freshOfficeCount, 1)
        let finalState = try await request(engine, "document.officeTextState",
                                           #"{"documentID":"\#(office.id.uuidString)"}"#)
        XCTAssertEqual((finalState["state"] as? [String: Any])?["current"] as? Bool, true)
        await engine.retire()
    }

    private func searchCount(_ engine: NotesEngine, _ query: String) async throws -> Int {
        let value = try await request(engine, "search.query",
                                      #"{"query":"\#(query)","limit":50}"#)
        return (value["documents"] as? [[String: Any]])?.count ?? -1
    }

    // MARK: - Conflict reviews

    func testConflictReviewsRetainBothVersionsAndResolveAtomically() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (currentID, _) = try await createNote(engine, title: "Mine")
        let (copyID, _) = try await createNote(engine, title: "Mine copy")
        let reviewPayload = """
        {"documentID":"\(currentID.uuidString)","expectedRevision":1,
         "copyDocumentID":"\(copyID.uuidString)","expectedCopyRevision":1,
         "title":"Conflict","edits":[{"action":"rename","text":"Human title"}]}
        """
        let saved = try await request(engine, "document.saveConflictReview", reviewPayload)
        let summary = try XCTUnwrap(saved["review"] as? [String: Any])
        let reviewID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(summary["id"] as? String)))
        XCTAssertEqual(summary["editCount"] as? Int, 1)

        do {
            _ = try await request(engine, "document.saveConflictReview", """
            {"documentID":"\(currentID.uuidString)","expectedRevision":9,
             "copyDocumentID":"\(copyID.uuidString)","expectedCopyRevision":1,
             "title":"Conflict","edits":[{"action":"rename","text":"Human title"}]}
            """)
            XCTFail("a stale current revision must not be stored")
        } catch NoteError.conflict {
            // expected
        }

        do {
            _ = try await request(engine, "document.apply", """
            {"documentID":"\(currentID.uuidString)","expectedRevision":1,
             "edits":[{"action":"rename","text":"Human title"}],
             "resolvingConflictID":"\(reviewID.uuidString)"}
            """)
            XCTFail("partial conflict resolution must be refused")
        } catch NotesDomainError.invalidPayload(let reason) {
            XCTAssertEqual(reason, "conflictResolutionIncomplete")
        }

        let listed = try await request(engine, "document.conflictReviews", "{}")
        XCTAssertEqual((listed["reviews"] as? [[String: Any]])?.count, 1)
        let full = try await request(engine, "document.conflictReview", """
        {"reviewID":"\(reviewID.uuidString)"}
        """)
        let fullReview = try XCTUnwrap(full["review"] as? [String: Any])
        XCTAssertEqual((fullReview["edits"] as? [[String: Any]])?.first?["action"] as? String, "rename")

        let resolved = try await request(engine, "document.apply", """
        {"documentID":"\(currentID.uuidString)","expectedRevision":1,
         "title":"Conflict","edits":[{"action":"rename","text":"Human title"}],
         "resolvingConflictID":"\(reviewID.uuidString)",
         "reviewedCopyID":"\(copyID.uuidString)","reviewedCopyRevision":1}
        """)
        let resolvedDocument = try responseDocument(try JSONSerialization.data(withJSONObject: resolved))
        XCTAssertEqual(resolvedDocument.revision, 2)
        XCTAssertEqual(resolvedDocument.title, "Human title")
        let reviewed = try await request(engine, "document.conflictReviews", "{}")
        XCTAssertEqual(reviewed["total"] as? Int, 0)
        let retainedCopy = try await readDocument(engine, copyID)
        XCTAssertEqual(retainedCopy.revision, 1)
        XCTAssertEqual(retainedCopy.title, "Mine copy")

        // A second review can be retained without overwriting anything.
        _ = try await request(engine, "document.saveConflictReview", """
        {"documentID":"\(currentID.uuidString)","expectedRevision":2,
         "copyDocumentID":"\(copyID.uuidString)","expectedCopyRevision":1,
         "title":"Keep both","edits":[{"action":"rename","text":"Later"}]}
        """)
        let keep = try await request(engine, "document.conflictReviews", "{}")
        let keepReview = try XCTUnwrap((keep["reviews"] as? [[String: Any]])?.first)
        let keepID = try XCTUnwrap(keepReview["id"] as? String)
        _ = try await request(engine, "document.keepBothConflictVersions",
                              #"{"reviewID":"\#(keepID)"}"#)
        let afterKeep = try await request(engine, "document.conflictReviews", "{}")
        XCTAssertEqual(afterKeep["total"] as? Int, 0)
        let keptCurrent = try await readDocument(engine, currentID)
        let keptCopy = try await readDocument(engine, copyID)
        XCTAssertEqual(keptCurrent.revision, 2)
        XCTAssertEqual(keptCopy.revision, 1)

        // Conversation-scoped access needs read on both documents and edit on
        // the current one before it may create or drop a review.
        let scopedSave = try await request(engine, "document.saveConflictReview", """
        {"documentID":"\(currentID.uuidString)","expectedRevision":2,
         "copyDocumentID":"\(copyID.uuidString)","expectedCopyRevision":1,
         "title":"Scoped","edits":[{"action":"rename","text":"Scoped"}]}
        """)
        let scopedID = try XCTUnwrap(
            (scopedSave["review"] as? [String: Any])?["id"] as? String)
        try await grant(engine, conversation: conversation, document: currentID, canEdit: false)
        do {
            _ = try await request(engine, "document.saveConflictReview", """
            {"reviewID":"\(scopedID)","documentID":"\(currentID.uuidString)",
             "expectedRevision":2,"copyDocumentID":"\(copyID.uuidString)",
             "expectedCopyRevision":1,"title":"Scoped",
             "edits":[{"action":"rename","text":"Scoped"}],
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("a read-only conversation must not create a review")
        } catch NoteError.invalidOperation {
            // expected
        }
        let hidden = try await request(engine, "document.conflictReviews", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((hidden["reviews"] as? [[String: Any]])?.count, 0)

        try await grant(engine, conversation: conversation, document: currentID, canEdit: true)
        do {
            _ = try await request(engine, "document.saveConflictReview", """
            {"reviewID":"\(scopedID)","documentID":"\(currentID.uuidString)",
             "expectedRevision":2,"copyDocumentID":"\(copyID.uuidString)",
             "expectedCopyRevision":1,"title":"Scoped",
             "edits":[{"action":"rename","text":"Scoped"}],
             "conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("an unreadable copy must not be retained through a review row")
        } catch NoteError.invalidOperation {
            // expected
        }
        try await grant(engine, conversation: conversation, document: copyID, canEdit: false)
        let scopedCommitted = try await request(engine, "document.saveConflictReview", """
        {"reviewID":"\(scopedID)","documentID":"\(currentID.uuidString)",
         "expectedRevision":2,"copyDocumentID":"\(copyID.uuidString)",
         "expectedCopyRevision":1,"title":"Scoped",
         "edits":[{"action":"rename","text":"Scoped"}],
         "conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((scopedCommitted["review"] as? [String: Any])?["id"] as? String, scopedID)
        let visible = try await request(engine, "document.conflictReviews", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertEqual((visible["reviews"] as? [[String: Any]])?.count, 1)
        let fullScoped = try await request(engine, "document.conflictReview", """
        {"reviewID":"\(scopedID)","conversationID":"\(conversation.uuidString)"}
        """)
        XCTAssertNotNil(fullScoped["review"] as? [String: Any])

        // Read access to both documents is not enough to drop the review:
        // current edit authority is required and is rechecked per call.
        try await grant(engine, conversation: conversation, document: currentID, canEdit: false)
        do {
            _ = try await request(engine, "document.keepBothConflictVersions", """
            {"reviewID":"\(scopedID)","conversationID":"\(conversation.uuidString)"}
            """)
            XCTFail("read-only access must not drop a conflict review")
        } catch NoteError.invalidOperation {
            // expected
        }
        try await grant(engine, conversation: conversation, document: currentID, canEdit: true)
        _ = try await request(engine, "document.keepBothConflictVersions", """
        {"reviewID":"\(scopedID)","conversationID":"\(conversation.uuidString)"}
        """)
        let cleared = try await request(engine, "document.conflictReviews", "{}")
        XCTAssertEqual(cleared["total"] as? Int, 0)
        let finalCurrent = try await readDocument(engine, currentID)
        let finalCopy = try await readDocument(engine, copyID)
        XCTAssertEqual(finalCurrent.revision, 2)
        XCTAssertEqual(finalCopy.revision, 1)
        await engine.retire()
    }

    // MARK: - Outbox repair

    func testOutboxRepairsCommittedAndUncommittedAcceptancesExactlyOnce() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let proposals = proposalNotes(root)
        let outbox = decisionOutbox(root)

        // Case A: the edit committed, but the process died before finalization.
        let (committedID, committedDocument) = try await createNote(engine, title: "Committed")
        let committedPage = try XCTUnwrap(committedDocument.pages.first?.id)
        try await grant(engine, conversation: conversation, document: committedID, canEdit: true)
        let committedCreate = try await request(engine, "proposal.create", """
        {"documentID":"\(committedID.uuidString)","expectedRevision":1,"title":"Crash A",
         "edits":[{"action":"upsertElement","pageID":"\(committedPage.uuidString)",
                   "element":{"id":"\(UUID().uuidString)","kind":"text",
                              "frame":{"x":10,"y":10,"width":200,"height":60},
                              "text":"Recovered A","color":"#202020","fontSize":18,
                              "isAIGenerated":true}}],
         "conversationID":"\(conversation.uuidString)","environmentID":"env-a"}
        """)
        let committedProposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            (committedCreate["proposal"] as? [String: Any])?["id"] as? String)))
        let loadedCommitted = await proposals.load(committedProposalID)
        let committedProposal = try XCTUnwrap(loadedCommitted)
        let stableA = NoteProposalService.applyRequestID(proposalID: committedProposalID)
        _ = try await request(engine, "document.apply", """
        {"documentID":"\(committedID.uuidString)","expectedRevision":1,"title":"Crash A",
         "requestID":"\(stableA)","conversationID":"\(conversation.uuidString)",
         "edits":\(NotesEditWireJSON.encode(committedProposal.edits))}
        """)
        let committedRevision = try await readDocument(engine, committedID).revision
        XCTAssertEqual(committedRevision, 2)
        try await outbox.save(NoteProposalDecisionIntent(
            proposal: committedProposal, decision: .accepted, revision: nil,
            phase: .committing, operationID: stableA))

        let preparedA = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)","limit":10}
        """)
        let decisionA = try XCTUnwrap((preparedA["decisions"] as? [[String: Any]])?.first)
        XCTAssertEqual(decisionA["decision"] as? String, "accepted")
        XCTAssertEqual(decisionA["revision"] as? Int, 2)
        XCTAssertEqual(decisionA["ready"] as? Bool, true)
        let repairedRevision = try await readDocument(engine, committedID).revision
        XCTAssertEqual(repairedRevision, 2,
                       "receipt repair must not re-apply the edit")
        let ackA = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(try XCTUnwrap(decisionA["intentID"] as? String))",
         "eventID":"\(try XCTUnwrap(decisionA["eventID"] as? String))"}
        """)
        XCTAssertEqual((ackA["ack"] as? [String: Any])?["alreadyDelivered"] as? Bool, false)

        // Case B: the intent is durable but the commit never happened. Recovery
        // revalidates the origin grant, re-applies once and finalizes.
        let (pendingID, _) = try await createNote(engine, title: "Uncommitted")
        try await grant(engine, conversation: conversation, document: pendingID, canEdit: true)
        let pendingCreate = try await request(engine, "proposal.create", """
        {"documentID":"\(pendingID.uuidString)","expectedRevision":1,"title":"Crash B",
         "edits":[{"action":"rename","text":"Recovered B"}],
         "conversationID":"\(conversation.uuidString)","environmentID":"env-a"}
        """)
        let pendingProposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            (pendingCreate["proposal"] as? [String: Any])?["id"] as? String)))
        let loadedPending = await proposals.load(pendingProposalID)
        let pendingProposal = try XCTUnwrap(loadedPending)
        let stableB = NoteProposalService.applyRequestID(proposalID: pendingProposalID)
        try await outbox.save(NoteProposalDecisionIntent(
            proposal: pendingProposal, decision: .accepted, revision: nil,
            phase: .committing, operationID: stableB))

        let preparedB = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)","limit":10}
        """)
        let decisionB = try XCTUnwrap((preparedB["decisions"] as? [[String: Any]])?.first)
        XCTAssertEqual(decisionB["decision"] as? String, "accepted")
        XCTAssertEqual(decisionB["revision"] as? Int, 2)
        let recoveredB = try await readDocument(engine, pendingID)
        XCTAssertEqual(recoveredB.revision, 2)
        XCTAssertEqual(recoveredB.title, "Recovered B")
        _ = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(try XCTUnwrap(decisionB["intentID"] as? String))",
         "eventID":"\(try XCTUnwrap(decisionB["eventID"] as? String))"}
        """)
        await engine.retire()
    }

    func testStaleAcceptanceRecordsDurableInvalidation() async throws {
        let root = try makeRoot()
        let engine = try NotesEngine(root: root)
        let conversation = UUID()
        let (documentID, document) = try await createNote(engine, title: "Stale proposal")
        let pageID = try XCTUnwrap(document.pages.first?.id)
        try await grant(engine, conversation: conversation, document: documentID, canEdit: true)
        let created = try await request(engine, "proposal.create", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,"title":"Stale",
         "edits":[{"action":"upsertElement","pageID":"\(pageID.uuidString)",
                   "element":{"id":"\(UUID().uuidString)","kind":"text",
                              "frame":{"x":10,"y":10,"width":200,"height":60},
                              "text":"Never","color":"#202020","fontSize":18,
                              "isAIGenerated":true}}],
         "conversationID":"\(conversation.uuidString)","environmentID":"env-a"}
        """)
        let proposalID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
            (created["proposal"] as? [String: Any])?["id"] as? String)))
        let grantID = try await issueGrant(engine, proposal: proposalID, document: documentID)
        _ = try await request(engine, "document.apply", """
        {"documentID":"\(documentID.uuidString)","expectedRevision":1,
         "edits":[{"action":"rename","text":"External edit"}]}
        """)

        do {
            _ = try await request(engine, "proposal.apply", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "grantID":"\(grantID)","conversationID":"\(conversation.uuidString)",
             "environmentID":"env-a"}
            """)
            XCTFail("a stale acceptance must fail closed")
        } catch NoteError.conflict {
            // expected
        }
        let unchanged = try await readDocument(engine, documentID)
        XCTAssertEqual(unchanged.revision, 2)
        XCTAssertEqual(unchanged.title, "External edit")

        let outbox = try await request(engine, "proposal.outbox", """
        {"conversationID":"\(conversation.uuidString)"}
        """)
        let decision = try XCTUnwrap((outbox["decisions"] as? [[String: Any]])?.first)
        XCTAssertEqual(decision["decision"] as? String, "invalidated")
        XCTAssertEqual(decision["ready"] as? Bool, true)
        _ = try await request(engine, "proposal.outboxAck", """
        {"intentID":"\(try XCTUnwrap(decision["intentID"] as? String))",
         "eventID":"\(try XCTUnwrap(decision["eventID"] as? String))"}
        """)
        do {
            _ = try await request(engine, "proposal.get", """
            {"proposalID":"\(proposalID.uuidString)","documentID":"\(documentID.uuidString)",
             "conversationID":"\(conversation.uuidString)","environmentID":"env-a"}
            """)
            XCTFail("a delivered invalidation removes the resolved proposal file")
        } catch NoteError.notFound {
            // expected
        }
        await engine.retire()
    }

    func testBridgeHandshakeAdvertisesAuthorityActionsWithoutExecutionAuthorities() throws {
        let actions = try XCTUnwrap(BridgeV4.handshake()["actions"] as? [String])
        for action in ["proposal.preview", "proposal.create", "proposal.apply",
                       "proposal.resolve", "proposal.outbox", "proposal.outboxAck",
                       "document.cachePageOCR", "document.cacheOfficeText",
                       "document.conflictReviews", "document.saveConflictReview",
                       "document.keepBothConflictVersions"] {
            XCTAssertTrue(actions.contains(action), "missing \(action)")
        }
        XCTAssertFalse(actions.contains("exec.shell"))
        XCTAssertFalse(actions.contains("provider.request"))
        XCTAssertFalse(actions.contains("agent.run"))
    }
}

/// Test-only flat edit JSON for replaying a stored proposal through the public
/// document.apply action. This mirrors exactly what the Android codec sends;
/// it is not a second native encoding.
private enum NotesEditWireJSON {
    static func encode(_ edits: [NoteEdit]) -> String {
        let values: [[String: Any]] = edits.map { edit in
            switch edit {
            case .rename(let text):
                return ["action": "rename", "text": text]
            case .favorite(let value):
                return ["action": "favorite", "isFavorite": value]
            case .tags(let tags):
                return ["action": "tags", "tags": tags]
            case .upsertElement(let pageID, let element):
                var value: [String: Any] = [
                    "id": element.id.uuidString,
                    "kind": element.kind.rawValue,
                    "frame": ["x": element.frame.x, "y": element.frame.y,
                              "width": element.frame.width, "height": element.frame.height],
                    "text": element.text,
                    "color": element.color,
                    "fontSize": element.fontSize,
                    "isAIGenerated": element.isAIGenerated,
                ]
                if let resourceID = element.resourceID {
                    value["resourceID"] = resourceID.uuidString
                } else {
                    value["resourceID"] = NSNull()
                }
                return ["action": "upsertElement", "pageID": pageID.uuidString,
                        "element": value]
            default:
                return ["action": "unsupportedTestEdit"]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: values)
        return String(decoding: data, as: UTF8.self)
    }
}

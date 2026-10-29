// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes runtime — tool surface + trusted review policy regressions.
//
// Everything here is deterministic and file-free: the closed tool authority,
// the exact main-run boundary, the bounded UTF-8 reader, the literal search
// offsets, and — most importantly — the trusted review/commit policy that
// decides whether a model-created proposal may be committed by the domain.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidCore

final class NotesRuntimeTests: XCTestCase {
    private let conversationID = UUID()
    private let runID = UUID()
    private let documentID = UUID()
    private let otherDocumentID = UUID()

    override func tearDown() async throws {
        try await super.tearDown()
    }

    private func authority(editable: Bool = true,
                           mayCommit: Bool = true) -> NotesToolAuthority {
        NotesToolAuthority(
            epoch: 42,
            conversationID: conversationID,
            runID: runID,
            documentID: documentID,
            readableDocumentIDs: [documentID, otherDocumentID],
            editableDocumentIDs: editable ? [documentID] : [],
            mayCommitRoutineEdits: mayCommit,
            environmentID: nil)
    }

    private func context(conversation: UUID? = nil,
                         run: UUID? = nil,
                         child: ChildExecutionHandoff? = nil) -> ToolContext {
        ToolContext(
            runID: run ?? runID,
            cancellation: CancellationToken(),
            conversationID: conversation ?? conversationID,
            childExecution: child)
    }

    /// Minimal handoff used ONLY to prove the main-run boundary: a delegated
    /// child can never reach a Notes document tool.
    private func delegatedChildHandoff() -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: ChildExecutionIdentity(
                parentRunID: runID,
                rootTaskID: conversationID,
                delegateCallID: "call-1"),
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, _ in
                    ToolResult(callID: call.id, status: .denied,
                               outputSummary: "not used", outputDigest: "")
                }),
            peers: PeerCollaborationHandle(
                register: { _ in },
                unregister: {},
                drain: { [] },
                peers: { _ in [] },
                send: { _, _, _ in SubagentPeerSendReceipt(accepted: false) }))
    }

    // MARK: - Closed tool set

    func testClosedToolSetIsExact() {
        XCTAssertEqual(NotesAssistantToolNames.all,
                       ["notes.read", "notes.search", "notes.edit"])
        XCTAssertEqual(NotesAssistantToolNames.closed.count, 3)
        XCTAssertTrue(NotesAssistantToolNames.closed.contains(NotesReadTool.name))
        XCTAssertTrue(NotesAssistantToolNames.closed.contains(NotesSearchTool.name))
        XCTAssertTrue(NotesAssistantToolNames.closed.contains(NotesEditTool.name))
    }

    func testToolMetadataDeclaresMainRunBoundaryAndEffects() {
        XCTAssertEqual(NotesReadTool.executionBoundary, .mainRunOnly)
        XCTAssertEqual(NotesSearchTool.executionBoundary, .mainRunOnly)
        XCTAssertEqual(NotesEditTool.executionBoundary, .mainRunOnly)
        XCTAssertFalse(NotesReadTool.isSideEffecting)
        XCTAssertFalse(NotesSearchTool.isSideEffecting)
        XCTAssertTrue(NotesEditTool.isSideEffecting)
        XCTAssertEqual(NotesReadTool.toolEffect, .readOnly)
        XCTAssertEqual(NotesEditTool.toolEffect, .mutating)
        XCTAssertTrue(NotesReadTool.riskLabels.contains(.readsFiles))
        XCTAssertTrue(NotesEditTool.riskLabels.contains(.writesFiles))
    }

    // MARK: - Main-run boundary

    func testAuthorityRefusesForeignConversationRunAndDelegatedChild() throws {
        let subject = authority()
        XCTAssertNoThrow(try subject.verifyMainRun(context()))

        XCTAssertThrowsError(try subject.verifyMainRun(context(conversation: UUID()))) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.code, .notAuthorized)
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason, "foreignConversation")
        }
        XCTAssertThrowsError(try subject.verifyMainRun(context(run: UUID()))) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason, "foreignRun")
        }
        XCTAssertThrowsError(try subject.verifyMainRun(
            context(child: delegatedChildHandoff()))) { error in
            XCTAssertEqual((error as? NotesAssistantRefusal)?.reason, "delegatedChild")
        }
    }

    // MARK: - Bounded reading

    func testUTF8SliceNeverSplitsAScalarAndContinuesExactly() {
        let text = "A😀B漢C"
        let bytes = Array(text.utf8)
        XCTAssertEqual(bytes.count, 1 + 4 + 1 + 3 + 1)

        let first = NotesToolPayload.utf8Slice(text, offset: 0, limit: 2)
        // 2 bytes would end inside the emoji: the slice backs off to "A".
        XCTAssertEqual(first.text, "A")
        XCTAssertEqual(first.totalBytes, bytes.count)
        XCTAssertEqual(first.nextOffset, 1)

        let second = NotesToolPayload.utf8Slice(text, offset: 1, limit: 4)
        XCTAssertEqual(second.text, "😀")
        XCTAssertEqual(second.nextOffset, 5)

        let rest = NotesToolPayload.utf8Slice(text, offset: 5, limit: 100)
        XCTAssertEqual(rest.text, "B漢C")
        XCTAssertNil(rest.nextOffset)

        // An offset landing inside a scalar advances to the next boundary
        // instead of emitting replacement characters.
        let inside = NotesToolPayload.utf8Slice(text, offset: 2, limit: 2)
        XCTAssertEqual(inside.text, "B")
        XCTAssertEqual(inside.nextOffset, 6)
        let emptyEnd = NotesToolPayload.utf8Slice(text, offset: bytes.count + 10, limit: 4)
        XCTAssertEqual(emptyEnd.text, "")
        XCTAssertNil(emptyEnd.nextOffset)
        XCTAssertEqual(emptyEnd.totalBytes, bytes.count)
    }

    func testSearchSnippetsReportExactByteOffsetsAndStayBounded() throws {
        let text = "Intro line\nSecond mention here\nThird MENTION again\n" + String(repeating: "x", count: 400)
        let hits = NotesSearchTool.snippets(in: text, query: "mention", limit: 10)
        XCTAssertEqual(hits.count, 2, "case-insensitive literal matching")
        let bytes = Array(text.utf8)
        for hit in hits {
            XCTAssertTrue(hit.snippet.lowercased().contains("mention"))
            XCTAssertLessThanOrEqual(hit.snippet.utf8.count, 300)
            // The reported offset really addresses the match.
            let slice = Array(bytes[hit.offset..<min(bytes.count, hit.offset + 7)])
            XCTAssertEqual(String(decoding: slice, as: UTF8.self).lowercased(), "mention")
        }
        XCTAssertEqual(hits.first?.offset, "Intro line\nSecond ".utf8.count)
    }

    // MARK: - Edit family policy

    func testRoutineEditFamilyIsClosedAndNonDestructive() {
        XCTAssertTrue(NotesProposalEditFamily(actions: ["rename"], count: 1).isRoutine)
        XCTAssertTrue(NotesProposalEditFamily(
            actions: ["textSource", "upsertElement", "tags"], count: 3).isRoutine)
        for destructive in ["deletePage", "deleteElements", "deleteBranch",
                            "replaceOfficeResource", "replaceMindMap",
                            "moveToNotebook", "linkMindMap"] {
            XCTAssertFalse(NotesProposalEditFamily(
                actions: ["rename", destructive], count: 2).isRoutine,
                "\(destructive) must require the editor's accept control")
        }
        XCTAssertFalse(NotesProposalEditFamily(actions: [], count: 0).isRoutine)
    }

    // MARK: - Trusted review policy

    private func facts(status: String = "pending",
                       source: String? = "call-1",
                       baseRevision: Int = 4,
                       baseSHA: String = "hash-a",
                       editCount: Int = 1,
                       thread: UUID? = nil,
                       canEdit: Bool = true,
                       runConversation: UUID? = nil,
                       runLive: Bool = true) -> NotesProposalReviewFacts {
        NotesProposalReviewFacts(
            proposalID: UUID(),
            documentID: documentID,
            proposalStatus: status,
            proposalSourceRequestID: source,
            proposalBaseRevision: baseRevision,
            proposalBaseSHA256: baseSHA,
            proposalEditCount: editCount,
            threadConversationID: thread ?? conversationID,
            liveCanEdit: canEdit,
            runConversationID: runConversation ?? conversationID,
            runIsLive: runLive)
    }

    private func review(_ facts: NotesProposalReviewFacts,
                        family: NotesProposalEditFamily = .init(actions: ["rename"], count: 1),
                        revision: Int = 4,
                        fingerprint: String = "hash-a") -> NotesReviewOutcome? {
        NotesProposalReviewPolicy.refusal(
            facts,
            conversationID: conversationID,
            documentID: documentID,
            runID: runID,
            toolCallID: "call-1",
            family: family,
            currentRevision: revision,
            currentFingerprint: fingerprint)
    }

    func testReviewPolicyAdmitsOnlyAFullyProvenRoutineProposal() {
        XCTAssertNil(review(facts()))
    }

    func testReviewPolicyRefusesEachMissingProofWithoutAWrite() {
        let cases: [(NotesProposalReviewFacts, NotesProposalEditFamily, Int, String, String)] = [
            (facts(status: "applied"), .init(actions: ["rename"], count: 1), 4, "hash-a", "proposalNotPending"),
            (facts(status: "resolved"), .init(actions: ["rename"], count: 1), 4, "hash-a", "proposalNotPending"),
            (facts(thread: UUID()), .init(actions: ["rename"], count: 1), 4, "hash-a", "threadOwnerMismatch"),
            (facts(canEdit: false), .init(actions: ["rename"], count: 1), 4, "hash-a", "editingNotAuthorized"),
            (facts(runLive: false), .init(actions: ["rename"], count: 1), 4, "hash-a", "runNotLive"),
            (facts(runConversation: UUID()), .init(actions: ["rename"], count: 1), 4, "hash-a", "runNotLive"),
            (facts(source: nil), .init(actions: ["rename"], count: 1), 4, "hash-a", "sourceRequestMismatch"),
            (facts(source: "call-2"), .init(actions: ["rename"], count: 1), 4, "hash-a", "sourceRequestMismatch"),
            (facts(editCount: 2), .init(actions: ["rename"], count: 1), 4, "hash-a", "editCountMismatch"),
            (facts(), .init(actions: ["deletePage"], count: 1), 4, "hash-a", "reviewPolicyRequiresUser"),
        ]
        for (facts, family, revision, fingerprint, expected) in cases {
            guard case .pending(let reason)? = review(facts, family: family,
                                                      revision: revision,
                                                      fingerprint: fingerprint) else {
                return XCTFail("expected pending \(expected)")
            }
            XCTAssertEqual(reason, expected)
        }
    }

    func testReviewPolicyReportsConflictOnAChangedBaseline() {
        guard case .conflict(let reason)? = review(facts(), revision: 5) else {
            return XCTFail("revision change must be a conflict")
        }
        XCTAssertEqual(reason, "revisionOrSourceChanged")

        guard case .conflict(let reason)? = review(facts(), fingerprint: "hash-b") else {
            return XCTFail("fingerprint change must be a conflict")
        }
        XCTAssertEqual(reason, "revisionOrSourceChanged")

        // Revision matches but the proposal was authored against another base.
        guard case .conflict? = review(facts(baseRevision: 3)) else {
            return XCTFail("base revision mismatch must be a conflict")
        }
    }

    // MARK: - Transcript DTO

    func testTranscriptCursorRoundTripsAndRejectsGarbage() throws {
        let cursor = ConversationMessageCursor(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000.123),
            messageID: UUID())
        let raw = NotesTranscriptPage.cursor(cursor)
        let parsed = try XCTUnwrap(try NotesTranscriptPage.parseCursor(raw))
        XCTAssertEqual(parsed.messageID, cursor.messageID)
        XCTAssertEqual(parsed.createdAt.timeIntervalSince1970,
                       cursor.createdAt.timeIntervalSince1970,
                       accuracy: 0.01)
        XCTAssertNil(try NotesTranscriptPage.parseCursor(nil))
        XCTAssertNil(try NotesTranscriptPage.parseCursor(""))
        XCTAssertThrowsError(try NotesTranscriptPage.parseCursor("not-a-cursor"))
        XCTAssertThrowsError(try NotesTranscriptPage.parseCursor("123|not-a-uuid"))
    }

    func testRunOutcomeMappingUsesOnlyDurableVocabulary() {
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "completed",
                                                       stopReason: "endTurn"), "COMPLETED")
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "completed",
                                                       stopReason: "cancelled"), "CANCELLED")
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "failed", stopReason: nil), "FAILED")
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "checkpointed", stopReason: nil),
                       "CHECKPOINTED")
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "interrupted", stopReason: nil),
                       "INTERRUPTED")
        XCTAssertEqual(NotesAssistantDomain.runOutcome(state: "streamingModel", stopReason: nil),
                       "ACTIVE")
        XCTAssertNil(NotesAssistantDomain.runOutcome(state: nil, stopReason: "cancelled"),
                     "an absent run row is never guessed into an outcome")
    }
}

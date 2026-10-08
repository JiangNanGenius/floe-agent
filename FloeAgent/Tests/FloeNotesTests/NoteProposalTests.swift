// FloeNotesTests — durable propose/preview/apply contract (Build265).
import Foundation
import Testing
@testable import FloeNotes

@Suite("Notes proposal contract")
struct NoteProposalTests {
    private func makeStore(_ label: String) throws -> (NotesStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(label)-\(UUID().uuidString)", isDirectory: true)
        return (try NotesStore(root: root), root)
    }

    private func proposalRoot(_ root: URL) -> URL { root.appendingPathComponent("Proposals", isDirectory: true) }
    private func outboxRoot(_ root: URL) -> URL { root.appendingPathComponent("Outbox", isDirectory: true) }

    private func configuredDocument() async throws -> (NotesStore, URL, NoteDocument, UUID) {
        let (store, root) = try makeStore("proposal")
        var document = NoteDocument(title: "提案文档")
        document.pages[0].elements = [NoteElement(frame: .init(x: 20, y: 20, width: 300, height: 80), text: "旧内容")]
        let created = try await store.create(document)
        return (store, root, created, created.pages[0].id)
    }

    @Test("propose validates against an in-memory copy and binds revision + fingerprint")
    func proposeBindsRevisionAndFingerprint() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposals = NoteProposalStore(root: proposalRoot(root))
        let edited = NoteElement(frame: .init(x: 20, y: 20, width: 300, height: 80), text: "新内容")
        let proposal = try await NoteProposalService.propose(
            document: document, title: "更新文字", edits: [.upsertElement(pageID: pageID, element: edited)],
            sourceRequestID: "run:call", store: proposals)

        #expect(proposal.documentID == document.id)
        #expect(proposal.baseRevision == document.revision)
        #expect(proposal.baseSHA256 == NoteDocumentFingerprint.sha256(of: document))
        #expect(proposal.baseSHA256.count == 64)
        #expect(proposal.summary.contains("修改"))
        #expect(proposal.sourceRequestID == "run:call")
        #expect(!proposal.isApplied)
        // Persisted and readable before any apply.
        let reloaded = await NoteProposalStore(root: proposalRoot(root)).load(proposal.id)
        #expect(reloaded == proposal)
        // The store document is untouched by proposing.
        let untouched = try await store.document(document.id)
        #expect(untouched.revision == document.revision)
        #expect(untouched.pages[0].elements[0].text == "旧内容")
    }

    @Test("propose rejects edits that do not apply cleanly")
    func proposeRejectsInvalidEdits() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = store
        let proposals = NoteProposalStore(root: proposalRoot(root))
        await expectError("an unknown element cannot be deleted") {
            _ = try await NoteProposalService.propose(document: document, title: "删除",
                edits: [.deleteElements(pageID: pageID, ids: [UUID()])], store: proposals)
        }
        await expectError("an empty batch is not a proposal") {
            _ = try await NoteProposalService.propose(document: document, title: "空", edits: [], store: proposals)
        }
        await expectError("an empty title fails document validation") {
            _ = try await NoteProposalService.propose(document: document, title: "改名", edits: [.rename(" ")], store: proposals)
        }
        let persisted = await proposals.all()
        #expect(persisted.isEmpty, "a rejected proposal is never persisted")
    }

    @Test("summary describes the human-visible difference")
    func summaryDescribesChanges() throws {
        var before = NoteDocument(title: "旧标题")
        let element = NoteElement(frame: .init(x: 0, y: 0, width: 200, height: 60), text: "旧文字")
        before.pages[0].elements = [element]
        var after = before
        after.title = "新标题"
        after.pages[0].elements = [
            NoteElement(id: element.id, frame: element.frame, text: "新文字"),
            NoteElement(frame: .init(x: 0, y: 80, width: 200, height: 60), text: "新增段落")
        ]
        let summary = NoteProposalSummary.describe(before: before, after: after)
        #expect(summary.contains("旧标题"))
        #expect(summary.contains("新标题"))
        #expect(summary.contains("新增 1"))
        #expect(summary.contains("修改 1"))
        #expect(NoteProposalSummary.describe(before: before, after: before) == "没有可见变化")
    }

    @Test("fingerprint is canonical across decode/encode round trips")
    func fingerprintIsCanonical() throws {
        var document = NoteDocument(title: "指纹")
        document.tags = ["b", "a"]
        document.nodes = []
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: data)
        #expect(NoteDocumentFingerprint.sha256(of: document) == NoteDocumentFingerprint.sha256(of: decoded))
        var changed = decoded
        changed.tags = ["a", "b", "c"]
        #expect(NoteDocumentFingerprint.sha256(of: changed) != NoteDocumentFingerprint.sha256(of: decoded))
    }

    @Test("grant is single-use, expiring and bound to proposal/document/revision/fingerprint")
    func grantLifecycle() async throws {
        let proposal = NoteProposal(documentID: UUID(), baseRevision: 3, baseSHA256: String(repeating: "a", count: 64),
                                    title: "t", edits: [.rename("x")], summary: "s", createdAt: Date(timeIntervalSince1970: 0))
        let grants = NoteProposalGrantStore(timeToLive: 60, idProvider: { "grant-1" })
        let now = Date(timeIntervalSince1970: 1_000)
        let grantID = await grants.issueGrant(proposal: proposal, now: now)
        #expect(grantID == "grant-1")

        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 4, sha256: proposal.baseSHA256, now: now) == .revisionMismatch(expected: 3, actual: 4))
        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: UUID(),
                                     revision: 3, sha256: proposal.baseSHA256, now: now) == .documentMismatch)
        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 3, sha256: String(repeating: "b", count: 64), now: now)
            == .shaMismatch(expected: proposal.baseSHA256, actual: String(repeating: "b", count: 64)))
        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 3, sha256: proposal.baseSHA256, now: now) == .authorized)
        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 3, sha256: proposal.baseSHA256, now: now) == .alreadyConsumed)
        #expect(await grants.consume(grantID: "missing", proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 3, sha256: proposal.baseSHA256, now: now) == .unknownGrant)

        let expiring = await grants.issueGrant(proposal: proposal, now: now)
        #expect(await grants.consume(grantID: expiring, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 3, sha256: proposal.baseSHA256, now: now.addingTimeInterval(61)) == .expired)
    }

    @Test("reservation can be released on failure and committed on success")
    func reservationLifecycle() async throws {
        let proposal = NoteProposal(documentID: UUID(), baseRevision: 1, baseSHA256: String(repeating: "c", count: 64),
                                    title: "t", edits: [.rename("x")], summary: "s")
        let grants = NoteProposalGrantStore(idProvider: { "grant-2" })
        let grantID = await grants.issueGrant(proposal: proposal)
        #expect(await grants.reserve(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 1, sha256: proposal.baseSHA256) == .reserved)
        #expect(await grants.reserve(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 1, sha256: proposal.baseSHA256) == .alreadyReserved)
        await grants.releaseReservation(grantID: grantID)
        #expect(await grants.reserve(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 1, sha256: proposal.baseSHA256) == .reserved)
        #expect(await grants.commitReservation(grantID: grantID))
        #expect(await grants.consume(grantID: grantID, proposalID: proposal.id, documentID: proposal.documentID,
                                     revision: 1, sha256: proposal.baseSHA256) == .alreadyConsumed)
    }

    @Test("pending proposals are durable and corrupt files cannot hide valid ones")
    func storeDurability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let documentID = UUID()
        let first = NoteProposal(documentID: documentID, baseRevision: 1, baseSHA256: String(repeating: "d", count: 64),
                                 title: "一", edits: [.rename("一")], summary: "s1", createdAt: Date(timeIntervalSince1970: 10))
        let second = NoteProposal(documentID: documentID, baseRevision: 1, baseSHA256: String(repeating: "d", count: 64),
                                  title: "二", edits: [.rename("二")], summary: "s2", createdAt: Date(timeIntervalSince1970: 20))
        let store = NoteProposalStore(root: root)
        try await store.save(second)
        try await store.save(first)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("\(UUID().uuidString).json"))

        let reopened = NoteProposalStore(root: root)
        let pending = await reopened.pending(documentID: documentID)
        #expect(pending.map(\.id) == [first.id, second.id])
        let loaded = await reopened.load(first.id)
        #expect(loaded == first)
        try await reopened.remove(first.id)
        let remaining = await reopened.pending(documentID: documentID)
        #expect(remaining.map(\.id) == [second.id])
    }

    @Test("apply commits once, records the applied revision, and a retry returns the receipt")
    func applyIsIdempotent() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposals = NoteProposalStore(root: proposalRoot(root))
        let outbox = NoteProposalOutbox(root: outboxRoot(root))
        let grants = NoteProposalGrantStore(idProvider: { "apply-grant" })
        var edited = document.pages[0].elements[0]
        edited.text = "已应用"
        let proposal = try await NoteProposalService.propose(
            document: document, title: "应用", edits: [.upsertElement(pageID: pageID, element: edited)], store: proposals)
        let grantID = await grants.issueGrant(proposal: proposal)

        let applied = try await NoteProposalService.apply(proposalID: proposal.id, grantID: grantID,
                                                          store: store, proposals: proposals, outbox: outbox, grants: grants)
        #expect(applied.revision == document.revision + 1)
        let reloaded = try await store.document(document.id)
        #expect(reloaded.pages[0].elements[0].text == "已应用")
        #expect(await proposals.pending(documentID: document.id).isEmpty)
        let record = try #require(await proposals.load(proposal.id))
        #expect(record.isApplied)
        #expect(record.appliedRevision == applied.revision)

        // Transport retry with the consumed grant and the same proposal returns
        // the receipt instead of failing or applying twice.
        let retried = try await NoteProposalService.apply(proposalID: proposal.id, grantID: grantID,
                                                          store: store, proposals: proposals, outbox: outbox, grants: grants)
        #expect(retried.revision == applied.revision)
        let afterRetryRevision = try await store.document(document.id).revision
        #expect(afterRetryRevision == applied.revision)

        // The origin-less (UI-authored) proposal can be resolved; it persists
        // no runtime intent because there is nobody to notify.
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .rejected,
                                                  proposals: proposals, outbox: outbox)
        let resolved = try #require(await proposals.load(proposal.id))
        #expect(resolved.resolvedDecision == .rejected)
        let intentCount = await outbox.pendingDecisions().count
        #expect(intentCount == 0, "origin-less proposals persist no intent")
    }

    @Test("apply fails closed on a stale revision, stale fingerprint, missing or expired grant")
    func applyFailsClosed() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposals = NoteProposalStore(root: proposalRoot(root))
        let outbox = NoteProposalOutbox(root: outboxRoot(root))
        let grants = NoteProposalGrantStore(idProvider: { "fail-grant" })
        let edited = NoteElement(frame: .init(x: 20, y: 20, width: 300, height: 80), text: "更新")
        let proposal = try await NoteProposalService.propose(
            document: document, title: "更新", edits: [.upsertElement(pageID: pageID, element: edited)], store: proposals)
        let grantID = await grants.issueGrant(proposal: proposal)

        // Missing grant first: nothing is consumed.
        await expectError("an unknown grant is not authority") {
            _ = try await NoteProposalService.apply(proposalID: proposal.id, grantID: "missing",
                                                    store: store, proposals: proposals, outbox: outbox, grants: grants)
        }
        // Advance the document behind the proposal's back.
        _ = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                        title: "外部修改", edits: [.rename("外部修改")]))
        await expectError("a stale revision conflicts") {
            _ = try await NoteProposalService.apply(proposalID: proposal.id, grantID: grantID,
                                                    store: store, proposals: proposals, outbox: outbox, grants: grants)
        }
        let after = try await store.document(document.id)
        #expect(after.title == "外部修改")
        let stillPending = await proposals.pending(documentID: document.id)
        #expect(stillPending.count == 1, "a failed apply keeps the proposal pending")

        // A proposal with a wrong fingerprint at the right revision fails too.
        let tampered = NoteProposal(id: UUID(), documentID: after.id, baseRevision: after.revision,
                                    baseSHA256: String(repeating: "0", count: 64), title: "篡改",
                                    edits: [.rename("篡改")], summary: "s", createdAt: Date())
        try await proposals.save(tampered)
        let tamperedGrant = await grants.issueGrant(proposal: tampered)
        await expectError("a fingerprint mismatch conflicts") {
            _ = try await NoteProposalService.apply(proposalID: tampered.id, grantID: tamperedGrant,
                                                    store: store, proposals: proposals, outbox: outbox, grants: grants)
        }

        // Expired grant fails even when revision + fingerprint match.
        let expiring = NoteProposalGrantStore(timeToLive: 60, idProvider: { "expired-grant" })
        let fresh = try await NoteProposalService.propose(
            document: after, title: "过期", edits: [.rename("过期")], store: proposals)
        let now = Date()
        let expiredGrant = await expiring.issueGrant(proposal: fresh, now: now)
        await expectError("an expired grant fails closed") {
            _ = try await NoteProposalService.apply(proposalID: fresh.id, grantID: expiredGrant,
                                                    store: store, proposals: proposals, outbox: outbox, grants: expiring,
                                                    now: now.addingTimeInterval(61))
        }
        let finalTitle = try await store.document(after.id).title
        #expect(finalTitle == "外部修改")
    }

    @Test("apply requires an editing grant when a conversation is supplied")
    func applyRequiresEditingConversation() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposals = NoteProposalStore(root: proposalRoot(root))
        let outbox = NoteProposalOutbox(root: outboxRoot(root))
        let grants = NoteProposalGrantStore(idProvider: { "conv-grant" })
        let conversation = UUID()
        let proposal = try await NoteProposalService.propose(
            document: document, title: "授权",
            edits: [.upsertElement(pageID: pageID, element: NoteElement(text: "越权"))],
            origin: NoteProposalOrigin(conversationID: conversation),
            store: proposals)
        let grantID = await grants.issueGrant(proposal: proposal)
        try await store.grantAccess(conversationID: conversation, documentID: document.id, canEdit: false)

        await expectError("a read-only conversation cannot apply") {
            _ = try await NoteProposalService.apply(proposalID: proposal.id, grantID: grantID,
                                                    store: store, proposals: proposals, outbox: outbox, grants: grants,
                                                    authorizedConversationID: conversation)
        }
        let unchangedRevision = try await store.document(document.id).revision
        #expect(unchangedRevision == document.revision)
    }

    // MARK: - Build265 follow-up: origin ownership, decisions, invalidation

    @Test("tool visibility and apply are limited to the exact originating task")
    func originGatesToolVisibilityAndApply() async throws {
        let (store, root, document, pageID) = try await configuredDocument()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposals = NoteProposalStore(root: proposalRoot(root))
        let outbox = NoteProposalOutbox(root: outboxRoot(root))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env-a")
        let foreignConversation = UUID()
        var edited = document.pages[0].elements[0]
        edited.text = "新内容"
        let proposal = try await NoteProposalService.propose(
            document: document, title: "来源", edits: [.upsertElement(pageID: pageID, element: edited)],
            origin: origin, store: proposals)
        #expect(proposal.origin == origin)

        // A same-document read grant alone never reveals another task's proposal.
        let visible = await NoteProposalService.toolVisibleProposal(
            proposalID: proposal.id, conversationID: origin.conversationID,
            environmentID: "env-a", store: proposals)
        #expect(visible?.id == proposal.id)
        let wrongConversation = await NoteProposalService.toolVisibleProposal(
            proposalID: proposal.id, conversationID: foreignConversation,
            environmentID: "env-a", store: proposals)
        #expect(wrongConversation == nil)
        let nilEnvironment = await NoteProposalService.toolVisibleProposal(
            proposalID: proposal.id, conversationID: origin.conversationID,
            environmentID: nil, store: proposals)
        #expect(nilEnvironment == nil)
        let wrongEnvironment = await NoteProposalService.toolVisibleProposal(
            proposalID: proposal.id, conversationID: origin.conversationID,
            environmentID: "env-b", store: proposals)
        #expect(wrongEnvironment == nil)

        let grants = NoteProposalGrantStore(idProvider: { "origin-grant" })
        let grantID = await grants.issueGrant(proposal: proposal)
        await expectError("a foreign conversation cannot apply") {
            _ = try await NoteProposalService.apply(
                proposalID: proposal.id, grantID: grantID, store: store, proposals: proposals,
                outbox: outbox, grants: grants,
                authorizedConversationID: foreignConversation, expectedEnvironmentID: "env-a")
        }
        await expectError("an environment mismatch cannot apply") {
            _ = try await NoteProposalService.apply(
                proposalID: proposal.id, grantID: grantID, store: store, proposals: proposals,
                outbox: outbox, grants: grants,
                authorizedConversationID: origin.conversationID, expectedEnvironmentID: "env-b")
        }
        let unchanged = try await store.document(document.id)
        #expect(unchanged.revision == document.revision)
        #expect(unchanged.pages[0].elements[0].text == "旧内容")

        // The originating task, with its edit grant, applies normally.
        let expiringGrant = NoteProposalGrantStore(idProvider: { "origin-grant-2" })
        let finalGrant = await expiringGrant.issueGrant(proposal: proposal)
        try await store.grantAccess(conversationID: origin.conversationID, documentID: document.id, canEdit: true)
        _ = try await NoteProposalService.apply(
            proposalID: proposal.id, grantID: finalGrant, store: store, proposals: proposals,
            outbox: outbox, grants: expiringGrant,
            authorizedConversationID: origin.conversationID, expectedEnvironmentID: "env-a")
        let applied = try await store.document(document.id)
        #expect(applied.revision == document.revision + 1)
        #expect(applied.pages[0].elements[0].text == "新内容")
    }

    @Test("decision events are origin-scoped, structured and replay-stable")
    func decisionEventsAreOriginScoped() throws {
        // UI-authored proposal: no origin, no event, no notification.
        let uiProposal = NoteProposal(documentID: UUID(), baseRevision: 1,
                                      baseSHA256: String(repeating: "a", count: 64), title: "UI",
                                      edits: [.rename("x")], summary: "SECRET-MODEL-TEXT")
        #expect(NoteProposalDecisions.event(for: uiProposal, decision: .rejected) == nil)

        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = NoteProposal(documentID: UUID(), baseRevision: 3,
                                    baseSHA256: String(repeating: "b", count: 64), title: "tool",
                                    origin: origin, edits: [.rename("x")], summary: "SECRET-MODEL-TEXT")
        let accepted = try #require(NoteProposalDecisions.event(for: proposal, decision: .accepted, revision: 7))
        #expect(accepted.conversationID == origin.conversationID, "only the origin conversation is notified")
        #expect(accepted.proposalID == proposal.id)
        #expect(accepted.revision == 7)
        #expect(accepted.id == NoteProposalDecisions.eventID(
            conversationID: origin.conversationID, proposalID: proposal.id, decision: .accepted))
        #expect(accepted.content.contains("accepted"))
        #expect(accepted.content.contains(proposal.id.uuidString))
        #expect(!accepted.content.contains("SECRET-MODEL-TEXT"),
                "the structured event never repeats model-authored proposal text")

        // Replay yields the identical stable id + content (idempotent upsert).
        let replay = try #require(NoteProposalDecisions.event(for: proposal, decision: .accepted, revision: 7))
        #expect(replay == accepted)
        let rejected = try #require(NoteProposalDecisions.event(for: proposal, decision: .rejected))
        let invalidated = try #require(NoteProposalDecisions.event(for: proposal, decision: .invalidated))
        #expect(Set([accepted.id, rejected.id, invalidated.id]).count == 3,
                "each terminal decision is a distinct durable event")
        #expect(invalidated.content.contains("invalidated"))
    }

    @Test("resolve writes the durable intent before resolving the proposal")
    func resolvePersistsIntentBeforeState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-invalidate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteProposalStore(root: root.appendingPathComponent("Proposals", isDirectory: true))
        let outbox = NoteProposalOutbox(root: root.appendingPathComponent("Outbox", isDirectory: true))
        let origin = NoteProposalOrigin(conversationID: UUID(), environmentID: "env")
        let proposal = NoteProposal(documentID: UUID(), baseRevision: 2,
                                    baseSHA256: String(repeating: "c", count: 64), title: "过期",
                                    origin: origin, edits: [.rename("x")], summary: "s")
        try await store.save(proposal)

        let resolved = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .invalidated,
                                                             proposals: store, outbox: outbox)
        #expect(resolved?.origin == origin)
        #expect(resolved?.resolvedDecision == .invalidated)
        let intents = await outbox.pendingDecisions()
        #expect(intents.count == 1)
        #expect(intents[0].conversationID == origin.conversationID)
        #expect(intents[0].decision == .invalidated)
        // A retried resolve reuses the same stable intent instead of adding one.
        _ = try await NoteProposalService.resolve(proposalID: proposal.id, decision: .invalidated,
                                                  proposals: store, outbox: outbox)
        let afterRetry = await outbox.pendingDecisions()
        #expect(afterRetry.count == 1)
    }

    @Test("fingerprint claims are limited to document JSON; resource bytes are CAS-pinned separately")
    func fingerprintClaimsMatchImplementation() throws {
        var document = NoteDocument(title: "指纹范围")
        document.pages[0].elements = [NoteElement(text: "文字")]
        let original = NoteDocumentFingerprint.sha256(of: document)
        #expect(original == NoteDocumentFingerprint.sha256(of: document))
        var changedText = document
        changedText.pages[0].elements[0].text = "文字2"
        #expect(NoteDocumentFingerprint.sha256(of: changedText) != original, "document content is covered")
        var changedResource = document
        changedResource.pages[0].drawingResourceID = UUID()
        #expect(NoteDocumentFingerprint.sha256(of: changedResource) != original,
                "content-addressed resource IDs are part of the document JSON")

        let proposeDetail = try #require(NoteCapabilityMatrix.capabilities.first { $0.id == "propose" }?.detail)
        #expect(proposeDetail.contains("JSON"))
        #expect(proposeDetail.contains("CAS-pinned"))
        #expect(!proposeDetail.contains("pins the exact resource bytes"))
        let applyDetail = try #require(NoteCapabilityMatrix.capabilities.first { $0.id == "applyProposal" }?.detail)
        #expect(applyDetail.contains("JSON fingerprint"))
        #expect(applyDetail.contains("origin"))
    }

    private func expectError(_ message: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected an error: \(message)")
        } catch {}
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeNotes
@testable import FloeApp

private enum LeaveQualificationError: Error { case deadline }
@MainActor private final class LeaveFacts {
    var current = true
    var outstanding: Set<UUID> = []
    var stops: [DocumentAssistantLeaveSnapshot] = []
    var preferences: [DocumentAssistantLeavePolicy] = []
    var result: Bool?
}

@Suite("RQ25 actual navigation intent and owned stop", .serialized)
@MainActor
struct DocumentAssistantLeaveTests {
    private func snapshot(run: UUID = UUID()) -> DocumentAssistantLeaveSnapshot {
        .init(documentID: UUID(), conversationID: UUID(), title: "Fixture", invocationIDs: [run], preparationIDs: [])
    }
    private func until(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < end else { throw LeaveQualificationError.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func request(_ coordinator: DocumentAssistantLeaveCoordinator, facts: LeaveFacts,
                         snapshot: DocumentAssistantLeaveSnapshot,
                         reason: DocumentAssistantNavigationReason = .leaveDocument,
                         policy: DocumentAssistantLeavePolicy = .ask) -> Task<Void, Never> {
        Task { @MainActor in
            facts.result = await coordinator.requestLeave(snapshot: snapshot, reason: reason, policy: policy,
                isStillCurrent: { facts.current },
                requestStop: { facts.stops.append($0) },
                hasOutstandingWork: { !facts.outstanding.isDisjoint(with: $0.invocationIDs.union($0.preparationIDs)) },
                remember: { facts.preferences.append($0) })
        }
    }

    @Test("Unknown saved preference asks; only actual leave and close-tab are decisions")
    func restoredPolicyAndNavigationMeaning() {
        #expect(DocumentAssistantLeavePolicy.restored(nil) == .ask)
        #expect(DocumentAssistantLeavePolicy.restored("unknown") == .ask)
        for reason in DocumentAssistantNavigationReason.allCases {
            #expect(reason.requiresLeaveDecision == (reason == .leaveDocument || reason == .closeTab))
        }
    }

    @Test("Switching tabs, collapsing, temporary covers and background never stop or prompt")
    func nonNavigationPresentationDoesNotStop() async {
        for reason in [DocumentAssistantNavigationReason.switchDocumentTab, .collapseAssistant, .temporaryCover, .appBackground] {
            let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
            let allowed = await coordinator.requestLeave(snapshot: snapshot(), reason: reason, policy: .stopCurrentWork,
                isStillCurrent: { true }, requestStop: { facts.stops.append($0) }, hasOutstandingWork: { _ in true },
                remember: { facts.preferences.append($0) })
            #expect(allowed)
            #expect(coordinator.prompt == nil)
            #expect(facts.stops.isEmpty)
        }
    }

    @Test("An idle assistant leaves without presenting an unnecessary question")
    func idleHasNoQuestion() async {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let idle = DocumentAssistantLeaveSnapshot(documentID: UUID(), conversationID: UUID(), title: "Idle", invocationIDs: [], preparationIDs: [])
        let allowed = await coordinator.requestLeave(snapshot: idle, reason: .leaveDocument, policy: .ask,
            isStillCurrent: { true }, requestStop: { facts.stops.append($0) }, hasOutstandingWork: { _ in false }, remember: { _ in })
        #expect(allowed)
        #expect(coordinator.prompt == nil)
        #expect(facts.stops.isEmpty)
    }

    @Test("Continue keeps work and remembers only the explicit chosen policy")
    func continueRemembersWithoutStopping() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let task = request(coordinator, facts: facts, snapshot: snapshot())
        defer { task.cancel() }
        try await until { coordinator.prompt != nil }
        coordinator.choose(requestID: coordinator.prompt!.id, .continueInBackground, remember: true)
        try await until { facts.result != nil }
        #expect(facts.result == true)
        #expect(facts.stops.isEmpty)
        #expect(facts.preferences == [.continueInBackground])
    }

    @Test("Cancel navigation keeps the document and changes neither tasks nor remembered preference")
    func cancelNavigationIsNotTaskCancellation() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let task = request(coordinator, facts: facts, snapshot: snapshot(), reason: .closeTab)
        defer { task.cancel() }
        try await until { coordinator.prompt != nil }
        coordinator.choose(requestID: coordinator.prompt!.id, .cancelNavigation, remember: true)
        try await until { facts.result != nil }
        #expect(facts.result == false)
        #expect(facts.stops.isEmpty)
        #expect(facts.preferences.isEmpty)
    }

    @Test("Stop waits for the captured work to really settle and leaves another run alone")
    func stopHasRealOwnedSettlement() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(stopDeadline: .seconds(1)), facts = LeaveFacts()
        let own = UUID(), other = UUID()
        facts.outstanding = [own, other]
        let task = request(coordinator, facts: facts, snapshot: snapshot(run: own), policy: .stopCurrentWork)
        defer { task.cancel() }
        try await until { coordinator.isStopping }
        #expect(facts.result == nil)
        #expect(facts.stops.count == 1)
        #expect(facts.stops[0].invocationIDs == [own])
        facts.outstanding.remove(own)
        try await until { facts.result != nil }
        #expect(facts.result == true)
        #expect(facts.outstanding == [other])
    }

    @Test("A stop deadline keeps navigation blocked, never reports task failure or remembers a failed stop")
    func stopDeadlineIsNotFalseSuccess() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(stopDeadline: .milliseconds(20)), facts = LeaveFacts()
        let run = UUID(); facts.outstanding = [run]
        let task = request(coordinator, facts: facts, snapshot: snapshot(run: run))
        defer { task.cancel() }
        try await until { coordinator.prompt != nil }
        coordinator.choose(requestID: coordinator.prompt!.id, .stopCurrentWork, remember: true)
        try await until { facts.result != nil }
        #expect(facts.result == false)
        #expect(coordinator.failure == .stillStopping)
        #expect(facts.preferences.isEmpty)
        #expect(facts.outstanding == [run])
    }

    @Test("A stale document choice cannot stop its old task or navigate the replacement document")
    func staleOwnerCannotApplyChoice() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let task = request(coordinator, facts: facts, snapshot: snapshot())
        defer { task.cancel() }
        try await until { coordinator.prompt != nil }
        facts.current = false
        coordinator.choose(requestID: coordinator.prompt!.id, .stopCurrentWork, remember: true)
        try await until { facts.result != nil }
        #expect(facts.result == false)
        #expect(facts.stops.isEmpty)
        #expect(facts.preferences.isEmpty)
    }

    @Test("A repeated navigation request cannot replace the already visible decision")
    func duplicateBackDoesNotReplacePrompt() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let task = request(coordinator, facts: facts, snapshot: snapshot())
        defer { task.cancel() }
        try await until { coordinator.prompt != nil }
        let id = coordinator.prompt!.id
        let second = await coordinator.requestLeave(snapshot: snapshot(), reason: .leaveDocument, policy: .ask,
            isStillCurrent: { true }, requestStop: { _ in Issue.record("Second request stopped work") },
            hasOutstandingWork: { _ in false }, remember: { _ in })
        #expect(!second)
        #expect(coordinator.prompt?.id == id)
        coordinator.choose(requestID: id, .continueInBackground)
        try await until { facts.result != nil }
        #expect(facts.result == true)
    }

    @Test("Cancelling a pending navigation resumes its waiter without stopping the assistant")
    func cancelledWaiterDoesNotStopWork() async throws {
        let coordinator = DocumentAssistantLeaveCoordinator(), facts = LeaveFacts()
        let task = request(coordinator, facts: facts, snapshot: snapshot())
        try await until { coordinator.prompt != nil }
        task.cancel()
        try await until { facts.result != nil }
        #expect(facts.result == false)
        #expect(facts.stops.isEmpty)
        #expect(coordinator.prompt == nil)
        #expect(coordinator.failure == nil)
    }
}

@Suite("RQ25 preparation handoff, replacement ownership and Office leave proof", .serialized)
@MainActor
struct DocumentAssistantLeaveOwnershipTests {
    @Test("Stopping one document's pending launch retains its barrier and spares another launch")
    func preparingStopIsScopedAndDoesNotDisappearEarly() {
        let first = UUID(), other = UUID()
        var preparation = DocumentAssistantPreparationOwnership()
        let ownID = preparation.begin(conversationID: first)
        let otherID = preparation.begin(conversationID: other)
        let frozen = preparation.identities(conversationID: first)
        preparation.cancel(frozen)
        #expect(!preparation.mayExecute(ownID))
        #expect(preparation.mayExecute(otherID))
        #expect(preparation.hasOutstanding(frozen))
        preparation.finish(ownID)
        #expect(!preparation.hasOutstanding(frozen))
        #expect(preparation.identities(conversationID: other) == [otherID])
    }

    @Test("A launch captured before runtime registration is still stopped after its handoff")
    func frozenPreparationReachesOnlyItsInvocation() throws {
        let conversation = UUID(), run = UUID(), newRun = UUID()
        var preparation = DocumentAssistantPreparationOwnership()
        let workID = preparation.begin(conversationID: conversation)
        let frozen = preparation.identities(conversationID: conversation)
        var invocations = ConversationRunInvocationOwnership()
        let claimed = invocations.claim(run, conversationID: conversation, generation: workID)
        let own = try #require(claimed)
        let otherClaim = invocations.claim(newRun, conversationID: conversation)
        let other = try #require(otherClaim)
        preparation.finish(workID)
        #expect(!preparation.hasOutstanding(frozen))
        let targets = invocations.tokens(matching: frozen)
        #expect(targets == [own])
        for token in targets { invocations.cancel(token.runID) }
        #expect(!invocations.mayExecute(own))
        #expect(invocations.hasOwner(run))
        #expect(invocations.mayExecute(other))
    }

    @Test("A late stop snapshot cannot cancel the replacement generation of the same run")
    func oldStopDoesNotCancelNewTurn() throws {
        var invocations = ConversationRunInvocationOwnership()
        let conversation = UUID(), run = UUID()
        let claim = invocations.claim(run, conversationID: conversation)
        let old = try #require(claim)
        let frozen = invocations.identities(conversationID: conversation)
        invocations.finish(old)
        let replacement = invocations.claim(run, conversationID: conversation)
        let current = try #require(replacement)
        #expect(invocations.tokens(matching: frozen).isEmpty)
        let oldFinish = invocations.finish(old)
        #expect(!oldFinish)
        #expect(invocations.mayExecute(current))
    }

    @Test("An Office approval is consumable once and cannot cross document or navigation generation")
    func officeApprovalIsOneShotAndScoped() {
        var approvals = DocumentAssistantNavigationApprovals()
        let document = UUID(), generation = UUID()
        let approval = approvals.issue(documentID: document, generation: generation)
        let wrongDocument = approvals.consume(approval, documentID: UUID(), generation: generation)
        let wrongGeneration = approvals.consume(approval, documentID: document, generation: UUID())
        let accepted = approvals.consume(approval, documentID: document, generation: generation)
        let duplicate = approvals.consume(approval, documentID: document, generation: generation)
        #expect(!wrongDocument && !wrongGeneration && accepted && !duplicate)
    }

    @Test("A failed Office close's old approval cannot replace a fresh navigation decision")
    func replacedAndInvalidatedApprovalCannotEscape() {
        var approvals = DocumentAssistantNavigationApprovals()
        let document = UUID(), generation = UUID()
        let old = approvals.issue(documentID: document, generation: generation)
        let current = approvals.issue(documentID: document, generation: generation)
        let stale = approvals.consume(old, documentID: document, generation: generation)
        #expect(!stale)
        approvals.invalidate()
        let invalidated = approvals.consume(current, documentID: document, generation: generation)
        #expect(!invalidated)
    }
}


@Suite("RQ25 actual Notes navigation and native Office approval", .serialized)
@MainActor
struct NextRoundNotesAssistantNavigationTests {
    private func workspace() async throws -> (NotesSession, URL, NoteDocument, NoteDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rq25-notes-" + UUID().uuidString, isDirectory: true)
        let store = try NotesStore(root: root)
        let first = try await store.create(NoteDocument(title: "First"))
        let second = try await store.create(NoteDocument(title: "Second"))
        let session = NotesSession()
        await session.open(using: store)
        return (session, root, first, second)
    }

    @Test("Tab switching never asks; actual Back can be cancelled before selection changes")
    func switchKeepsWorkAndBackOwnsDecision() async throws {
        let (session, root, first, second) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = await session.select(first)
        #expect(opened)
        var requests: [(UUID, DocumentAssistantNavigationReason)] = []
        session.assistantLeaveGuard = { id, reason in requests.append((id, reason)); return false }
        let switched = await session.select(second)
        #expect(switched && session.document?.id == second.id)
        #expect(requests.isEmpty)
        let left = await session.select(nil)
        #expect(!left && session.document?.id == second.id)
        #expect(requests.count == 1 && requests.first?.0 == second.id && requests.first?.1 == .leaveDocument)
    }

    @Test("Closing either the selected or an inactive tab asks for that tab and respects cancellation")
    func tabCloseIsNotOrdinaryTabSwitch() async throws {
        let (session, root, first, second) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await session.select(first)
        _ = await session.select(second)
        var requests: [UUID] = []
        session.assistantLeaveGuard = { id, reason in
            #expect(reason == .closeTab)
            requests.append(id)
            return false
        }
        await session.closeTab(first.id)
        #expect(session.tabs.documentIDs.contains(first.id) && session.document?.id == second.id)
        await session.closeTab(second.id)
        #expect(session.tabs.documentIDs.contains(second.id) && session.document?.id == second.id)
        #expect(requests == [first.id, second.id])
        #expect(!session.isSwitchingDocument)
    }

    @Test("Office asks before teardown, then its exact one-shot approval avoids a second question")
    func nativeOfficeApprovalClosesOnlyOriginalSelection() async throws {
        let (session, root, first, _) = try await workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await session.select(first)
        var questions = 0
        session.assistantLeaveGuard = { _, reason in
            #expect(reason == .leaveDocument)
            questions += 1
            return true
        }
        let prepared = await session.prepareAssistantLeave(documentID: first.id)
        let approval = try #require(prepared)
        #expect(questions == 1 && session.document?.id == first.id)
        let left = await session.select(nil, assistantApproval: approval)
        #expect(left && session.document == nil && questions == 1)
        _ = await session.select(first)
        let secondLeave = await session.select(nil, assistantApproval: approval)
        #expect(secondLeave && questions == 2)
    }
}
#endif

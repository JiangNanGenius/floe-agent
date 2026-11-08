import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAgentRuntime

private actor ContinuingQuestionEvents {
    private var deliveries: [UserQuestionAnswerDelivery] = []
    func record(_ event: UserQuestionEvent) {
        if case .answerAvailable(let delivery) = event { deliveries.append(delivery) }
    }
    func all() -> [UserQuestionAnswerDelivery] { deliveries }
}

private actor ContinuingDeadlineEmissionGate {
    private var held = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseFirstExpiry(_ event: UserQuestionEvent) async {
        guard case .settled(let snapshot) = event,
              snapshot.questions.contains(where: { $0.answerSource == .deadlineDefault }),
              snapshot.pendingQuestionIDs.count == 2 else { return }
        held = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func isHeld() -> Bool { held }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

@Suite("Nonblocking defaults on the actual coordinator and SQLite store")
struct UserQuestionContinuingDeadlineTests {
    private func fixture() async throws -> (DatabaseManager, UUID, UUID, UserQuestionStore) {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversation = UUID(), run = UUID(), date = Date()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: conversation,
            title: "Owned continuing deadline", createdAt: date, updatedAt: date))
        try await SQLiteRunStore(database: database).saveRun(.init(id: run, conversationID: conversation,
            state: "running", goal: "Continue independent work", startedAt: date))
        return (database, conversation, run, UserQuestionStore(database: database))
    }
    private func request() -> UserQuestionRequest {
        .init(waitPolicy: .optionalContinue, questions: [.init(question: "Which layout?",
            options: [.init(id: "a", label: "Compact"), .init(id: "b", label: "Wide")],
            fallback: .init(selectedOptionIDs: ["a"]))])
    }
    private func published(_ store: UserQuestionStore, _ id: String) async throws -> UserQuestionWaitingSnapshot {
        for _ in 0..<100 {
            if let snapshot = try await store.snapshot(requestID: id) { return snapshot }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw UserQuestionError.notFound
    }
    private func expired(_ store: UserQuestionStore, _ id: String) async throws -> UserQuestionWaitingSnapshot {
        let limit = Date().addingTimeInterval(8)
        while Date() < limit {
            if let value = try await store.snapshot(requestID: id), value.isFullySettled { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw UserQuestionError.notFound
    }

    @Test func continuesImmediatelyThenTheExistingTimerPublishesADurableDefault() async throws {
        let (database, conversation, run, store) = try await fixture(), events = ContinuingQuestionEvents()
        let coordinator = UserQuestionCoordinator(store: store, eventHandler: { await events.record($0) },
            defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        let raw = request(); try UserAskTool(coordinator: coordinator).validate(raw)
        let receipt = try await coordinator.ask(raw, runID: run, conversationID: conversation,
            toolCallID: "continue_then_expire", cancellation: CancellationToken(), temporaryReadOnly: false)
        // Pending proves ask returned before expiry; no elapsed-time heuristic.
        #expect(receipt.status == .pending && receipt.answers.isEmpty)
        let pending = try await published(store, receipt.requestID), question = try #require(pending.currentQuestion)
        #expect(!pending.hasBlockingPending && question.deadlineAt?.timeIntervalSince(question.createdAt) == 5)
        let settled = try await expired(store, receipt.requestID)
        #expect(settled.questions[0].status == .expired && settled.questions[0].answerSource == .deadlineDefault)
        #expect(settled.questions[0].revision == question.revision + 1)
        let first = try #require(try await coordinator.pendingDeliveries(conversationID: conversation).first)
        let restarted = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let readback = try #require(try await restarted.pendingDeliveries(conversationID: conversation).first)
        #expect(first.id == readback.id && readback.answers[0].source == .deadlineDefault)
        #expect(readback.text.contains("NOT a human answer or authorization"))
        // The service event follows the SQLite commit. Allow that awaited handler
        // to finish before inspecting its actual receipt.
        for _ in 0..<100 {
            if !(await events.all()).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await events.all().contains(where: { $0.id == first.id }))
        try await restarted.acknowledgeDeliveries(questionIDs: first.answers.map(\.questionID))
        #expect(try await coordinator.pendingDeliveries(conversationID: conversation).isEmpty)
        let late = try await coordinator.submitHumanAnswer(target: pending.target(for: question), answer: .init(selectedOptionIDs: ["b"]))
        #expect(!late.accepted && late.alreadySettled && late.answer?.source == .deadlineDefault)
    }

    @Test func restoringAnAlreadyDueQuestionUsesItsFrozenDeadlineAndTheExistingDeliveryQueue() async throws {
        let (database, conversation, run, store) = try await fixture()
        var original: UserQuestionCoordinator? = UserQuestionCoordinator(store: store,
            defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        let receipt = try await original!.ask(request(), runID: run, conversationID: conversation,
            toolCallID: "restore_due", cancellation: CancellationToken(), temporaryReadOnly: false)
        let before = try await published(store, receipt.requestID), question = try #require(before.currentQuestion)
        let deadline = try #require(question.deadlineAt)
        weak var retired = original; original = nil
        #expect(retired == nil)
        // The coordinator's existing clock seam represents elapsed downtime;
        // no timer, expiry store, migration or runner is replaced.
        let reopened = UserQuestionStore(database: database)
        let restored = UserQuestionCoordinator(store: reopened, now: { deadline.addingTimeInterval(1) },
            defaultSettings: { .init(optionalTimeoutSeconds: 60) })
        #expect(try await restored.pendingSnapshot(conversationID: conversation) == nil)
        let after = try #require(try await reopened.snapshot(requestID: receipt.requestID))
        #expect(after.questions[0].deadlineAt == deadline && after.questions[0].fallback == question.fallback)
        #expect(after.requestDigest == before.requestDigest && after.questions[0].answerSource == .deadlineDefault)
        let delivery = try #require(try await restored.pendingDeliveries(conversationID: conversation).first)
        #expect(delivery.answers[0].source == .deadlineDefault)
        #expect(try await restored.pendingDeliveries(conversationID: UUID()).isEmpty)
    }

    @Test func restoringAFutureDeadlineRearmsTheOriginalServiceTimer() async throws {
        let (database, conversation, run, store) = try await fixture()
        var original: UserQuestionCoordinator? = UserQuestionCoordinator(store: store,
            defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        let receipt = try await original!.ask(request(), runID: run, conversationID: conversation,
            toolCallID: "restore_future", cancellation: CancellationToken(), temporaryReadOnly: false)
        let before = try await published(store, receipt.requestID), question = try #require(before.currentQuestion)
        weak var retired = original; original = nil; #expect(retired == nil)
        let reopened = UserQuestionStore(database: database)
        let restored = UserQuestionCoordinator(store: reopened, defaultSettings: { .init(optionalTimeoutSeconds: 30) })
        let pending = try #require(try await restored.pendingSnapshot(conversationID: conversation))
        #expect(pending.questions[0].deadlineAt == question.deadlineAt && pending.questions[0].fallback == question.fallback)
        let settled = try await expired(reopened, receipt.requestID)
        #expect(settled.questions[0].answerSource == .deadlineDefault)
        #expect(try await restored.pendingDeliveries(conversationID: conversation).count == 1)
    }

    @Test func aRealHumanAnswerWinsCASAndCannotBeOverwrittenByALaterDeadline() async throws {
        let (_, conversation, run, store) = try await fixture()
        let coordinator = UserQuestionCoordinator(store: store, defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        let receipt = try await coordinator.ask(request(), runID: run, conversationID: conversation,
            toolCallID: "human_wins", cancellation: CancellationToken(), temporaryReadOnly: false)
        let pending = try await published(store, receipt.requestID), question = try #require(pending.currentQuestion)
        let oldTarget = pending.target(for: question)
        let draft = try await coordinator.saveDraft(target: oldTarget, draft: .init(selectedOptionIDs: ["b"]))
        // Draft edits preserve the card's settlement CAS token. Exercise an
        // actual revision mismatch instead of treating a saved draft as stale.
        #expect(draft.saved && draft.revision == oldTarget.expectedRevision)
        var mismatchedTarget = oldTarget
        mismatchedTarget.expectedRevision += 1
        do {
            _ = try await coordinator.submitHumanAnswer(target: mismatchedTarget, answer: .init(selectedOptionIDs: ["b"]))
            Issue.record("A revision-mismatched card must not settle the question")
        } catch let error as UserQuestionError { #expect(error == .staleRevision(current: draft.revision)) }
        let fresh = try #require(try await store.snapshot(requestID: receipt.requestID))
        let current = try #require(fresh.currentQuestion)
        let human = try await coordinator.submitHumanAnswer(target: fresh.target(for: current), answer: .init(selectedOptionIDs: ["b"]))
        #expect(human.accepted && human.answer?.source == .human)
        // A settled card is idempotent: the store returns the original answer
        // with a rejection receipt, even when its old CAS token is submitted.
        let duplicate = try await coordinator.submitHumanAnswer(target: oldTarget, answer: .init(selectedOptionIDs: ["a"]))
        #expect(!duplicate.accepted && duplicate.alreadySettled)
        #expect(duplicate.revision == human.revision)
        #expect(duplicate.answer?.source == .human && duplicate.answer?.selectedOptionIDs == ["b"])
        let deadline = try #require(question.deadlineAt)
        let later = try #require(try await store.expire(requestID: receipt.requestID, now: deadline.addingTimeInterval(1)))
        #expect(later.questions[0].answerSource == .human && later.questions[0].answer?.selectedOptionIDs == ["b"])
        let delivery = try #require(try await coordinator.pendingDeliveries(conversationID: conversation).first)
        #expect(delivery.answers[0].source == .human && delivery.text.contains("The user answered"))
    }

    @Test func aHumanAnswerDuringExpiryDeliveryCannotInvalidateALaterDeadline() async throws {
        let (_, conversation, run, store) = try await fixture(), gate = ContinuingDeadlineEmissionGate()
        let coordinator = UserQuestionCoordinator(store: store, eventHandler: { await gate.pauseFirstExpiry($0) },
            defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        defer { Task { await gate.open() } }
        var raw = request()
        raw.questions.append(.init(id: "human", question: "Independent choice?", options: [.init(id: "h", label: "Human")]))
        raw.questions.append(.init(id: "later", question: "Later default?", options: [.init(id: "d", label: "Default")],
            timeoutSeconds: 10, fallback: .init(selectedOptionIDs: ["d"])))
        let receipt = try await coordinator.ask(raw, runID: run, conversationID: conversation,
            toolCallID: "expiry_reentrancy", cancellation: CancellationToken(), temporaryReadOnly: false)
        let limit = Date().addingTimeInterval(8)
        while !(await gate.isHeld()), Date() < limit { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(await gate.isHeld())
        let partial = try #require(try await store.snapshot(requestID: receipt.requestID))
        let human = partial.questions[1]
        let answer = try await coordinator.submitHumanAnswer(target: partial.target(for: human), answer: .init(selectedOptionIDs: ["h"]))
        #expect(answer.accepted && answer.answer?.source == .human)
        await gate.open()
        let settled = try await expired(store, receipt.requestID)
        #expect(settled.questions[0].answerSource == .deadlineDefault)
        #expect(settled.questions[1].answerSource == .human)
        #expect(settled.questions[2].answerSource == .deadlineDefault)
        #expect(settled.questions[2].answer?.selectedOptionIDs == ["d"])
    }

    @Test func aMixedRequiredQuestionStillBlocksWhenTheOptionalDefaultExpires() async throws {
        let (_, conversation, run, store) = try await fixture()
        let coordinator = UserQuestionCoordinator(store: store, defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        var raw = request(); raw.questions.append(.init(id: "major", question: "Choose the major direction",
            options: [.init(id: "yes", label: "Proceed")], waitPolicy: .required))
        let mixed = raw
        let token = CancellationToken(); defer { token.cancel() }
        let id = UserQuestionCoordinator.requestID(runID: run, toolCallID: "mixed_blocking")
        let waiting = Task { try await coordinator.ask(mixed, runID: run, conversationID: conversation,
            toolCallID: "mixed_blocking", cancellation: token, temporaryReadOnly: false) }
        let pending = try await published(store, id)
        #expect(pending.hasBlockingPending && pending.questions[1].deadlineAt == nil && pending.questions[1].fallback == nil)
        let optionalDeadline = try #require(pending.questions[0].deadlineAt)
        let partial = try #require(try await store.expire(requestID: id, now: optionalDeadline))
        #expect(partial.hasBlockingPending && partial.questions[0].answerSource == .deadlineDefault)
        #expect(try await coordinator.pendingDeliveries(conversationID: conversation).isEmpty)
        let major = partial.questions[1]
        _ = try await coordinator.submitHumanAnswer(target: partial.target(for: major), answer: .init(selectedOptionIDs: ["yes"]))
        let result = try await waiting.value
        #expect(result.answers.first(where: { $0.questionID == major.questionID })?.source == .human)
        #expect(result.answers.first(where: { $0.questionID == partial.questions[0].questionID })?.source == .deadlineDefault)
        #expect(result.humanAnsweredQuestionIDs == [major.questionID])
    }

    @Test func cancellingOrPurgingTemporaryQuestionsPreventsDefaultResurrection() async throws {
        let (database, conversation, run, store) = try await fixture(), events = ContinuingQuestionEvents()
        let coordinator = UserQuestionCoordinator(store: store, eventHandler: { await events.record($0) },
            defaultSettings: { .init(optionalTimeoutSeconds: 5) })
        let permanent = try await coordinator.ask(request(), runID: run, conversationID: conversation,
            toolCallID: "cancel_timed", cancellation: CancellationToken(), temporaryReadOnly: false)
        let snapshot = try await published(store, permanent.requestID), deadline = try #require(snapshot.earliestPendingDeadline)
        try await coordinator.cancelRequest(requestID: permanent.requestID)
        let cancelled = try #require(try await store.expire(requestID: permanent.requestID, now: deadline.addingTimeInterval(1)))
        #expect(cancelled.questions[0].status == .cancelled && cancelled.questions[0].answer == nil)
        let temporary = try await coordinator.ask(request(), runID: run, conversationID: conversation,
            toolCallID: "temporary_continue", cancellation: CancellationToken(), temporaryReadOnly: true)
        let ephemeral = try await published(store, temporary.requestID)
        #expect(ephemeral.isEphemeral && ephemeral.earliestPendingDeadline != nil)
        #expect(try await UserQuestionStore(database: database).snapshot(requestID: temporary.requestID) == nil)
        await coordinator.purgeEphemeral(runID: run)
        #expect(try await store.expire(requestID: temporary.requestID, now: deadline.addingTimeInterval(60)) == nil)
        #expect(try await coordinator.pendingDeliveries(conversationID: conversation).isEmpty)
        #expect(await events.all().isEmpty)
    }
}

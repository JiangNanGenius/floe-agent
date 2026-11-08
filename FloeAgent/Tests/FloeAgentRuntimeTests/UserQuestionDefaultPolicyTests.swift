import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAgentRuntime

private actor QuestionDefaultPreference {
    var value = UserQuestionDefaults()
    func snapshot() -> UserQuestionDefaults { value }
    func set(_ seconds: Int) { value = .init(optionalTimeoutSeconds: seconds) }
}

@Suite("Question defaults on the actual durable coordinator")
struct UserQuestionDefaultPolicyTests {
    private func fixture() async throws -> (DatabaseManager, UUID, UUID, UserQuestionStore) {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let conversation = UUID(), run = UUID(), date = Date()
        try await SQLiteConversationStore(database: database).saveConversation(.init(id: conversation, title: "Owned question defaults", createdAt: date, updatedAt: date))
        try await SQLiteRunStore(database: database).saveRun(.init(id: run, conversationID: conversation, state: "running", goal: "Ask", startedAt: date))
        return (database, conversation, run, UserQuestionStore(database: database))
    }
    private func request(_ policy: UserQuestionWaitPolicy = .optionalDeadline, fallback: Bool = true) -> UserQuestionRequest {
        .init(waitPolicy: policy, questions: [.init(question: "Which layout?", options: [.init(id: "a", label: "Compact"), .init(id: "b", label: "Wide")], fallback: fallback ? .init(selectedOptionIDs: ["a"]) : nil)])
    }
    private func published(_ store: UserQuestionStore, _ id: String) async throws -> UserQuestionWaitingSnapshot {
        for _ in 0..<100 {
            if let value = try await store.snapshot(requestID: id) { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw UserQuestionError.notFound
    }
    @Test func realUserAskValidationAndPublicationUseTheConfiguredFifteenSecondDefault() async throws {
        let (_, conversation, run, store) = try await fixture(), preference = QuestionDefaultPreference()
        let coordinator = UserQuestionCoordinator(store: store, defaultSettings: { await preference.snapshot() })
        let raw = request(); try UserAskTool(coordinator: coordinator).validate(raw)
        let id = UserQuestionCoordinator.requestID(runID: run, toolCallID: "default15")
        let waiting = Task { try await coordinator.ask(raw, runID: run, conversationID: conversation, toolCallID: "default15", cancellation: CancellationToken(), temporaryReadOnly: false) }
        let snapshot = try await published(store, id), question = try #require(snapshot.currentQuestion)
        #expect(question.deadlineAt?.timeIntervalSince(question.createdAt) == 15)
        #expect(UserQuestionFallbackPresentation(question: question)?.components == ["Compact"])
        #expect(question.answerSource == nil && snapshot.hasBlockingPending)
        try await coordinator.cancelRequest(requestID: id); _ = try await waiting.value
    }
    @Test func preferenceChangeAndReplayNeverRewriteAnAlreadyPublishedDeadline() async throws {
        let (database, conversation, run, store) = try await fixture(), preference = QuestionDefaultPreference()
        let coordinator = UserQuestionCoordinator(store: store, defaultSettings: { await preference.snapshot() }), raw = request()
        let id = UserQuestionCoordinator.requestID(runID: run, toolCallID: "frozen_default")
        let waiting = Task { try await coordinator.ask(raw, runID: run, conversationID: conversation, toolCallID: "frozen_default", cancellation: CancellationToken(), temporaryReadOnly: false) }
        let before = try await published(store, id), question = try #require(before.currentQuestion)
        await preference.set(60)
        #expect(try await store.snapshot(requestID: id)?.questions[0].deadlineAt == question.deadlineAt)
        try await coordinator.cancelRequest(requestID: id); _ = try await waiting.value
        let reopened = UserQuestionStore(database: database)
        let restarted = UserQuestionCoordinator(store: reopened, defaultSettings: { await preference.snapshot() })
        _ = try await restarted.ask(raw, runID: run, conversationID: conversation, toolCallID: "frozen_default", cancellation: CancellationToken(), temporaryReadOnly: false)
        let replay = try #require(await reopened.snapshot(requestID: id))
        #expect(replay.requestDigest == before.requestDigest && replay.questions[0].deadlineAt == question.deadlineAt)
        #expect(replay.questions[0].fallback == question.fallback)
        let nextID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "next_default")
        let next = Task { try await restarted.ask(raw, runID: run, conversationID: conversation, toolCallID: "next_default", cancellation: CancellationToken(), temporaryReadOnly: false) }
        let newer = try #require(try await published(reopened, nextID).currentQuestion)
        #expect(newer.deadlineAt?.timeIntervalSince(newer.createdAt) == 60)
        try await restarted.cancelRequest(requestID: nextID); _ = try await next.value
    }
    @Test func requiredNeverHasATimerAndLegacyOptionalContinueStillReturnsImmediately() async throws {
        let (_, conversation, run, store) = try await fixture(), coordinator = UserQuestionCoordinator(store: store)
        let requiredID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "major_required")
        let waiting = Task { try await coordinator.ask(request(.required, fallback: false), runID: run, conversationID: conversation, toolCallID: "major_required", cancellation: CancellationToken(), temporaryReadOnly: false) }
        let required = try await published(store, requiredID), question = try #require(required.currentQuestion)
        #expect(required.hasBlockingPending && question.deadlineAt == nil && question.fallback == nil)
        try await coordinator.cancelRequest(requestID: requiredID); _ = try await waiting.value
        let receipt = try await coordinator.ask(request(.optionalContinue, fallback: false), runID: run, conversationID: conversation, toolCallID: "independent", cancellation: CancellationToken(), temporaryReadOnly: false)
        #expect(receipt.status == .pending && receipt.pendingQuestionIDs.count == 1)
        let optionalID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "independent")
        #expect(try await store.snapshot(requestID: optionalID)?.earliestPendingDeadline == nil)
        try await coordinator.cancelRequest(requestID: optionalID)
    }
    @Test func defaultExpiryHasDurableNonHumanProvenanceAndLateHumanAnswerCannotReplaceIt() async throws {
        let (_, conversation, run, store) = try await fixture(), coordinator = UserQuestionCoordinator(store: store)
        let id = UserQuestionCoordinator.requestID(runID: run, toolCallID: "expiry_default")
        let waiting = Task { try await coordinator.ask(request(), runID: run, conversationID: conversation, toolCallID: "expiry_default", cancellation: CancellationToken(), temporaryReadOnly: false) }
        let pending = try await published(store, id), question = try #require(pending.currentQuestion)
        let deadline = try #require(question.deadlineAt)
        let expired = try #require(await store.expire(requestID: id, now: deadline))
        #expect(expired.questions[0].answerSource == .deadlineDefault && expired.questions[0].status == .expired)
        let late = try await coordinator.submitHumanAnswer(target: pending.target(for: question), answer: .init(selectedOptionIDs: ["b"]))
        #expect(!late.accepted && late.alreadySettled)
        let receipt = try await waiting.value
        #expect(receipt.answers.first?.source == .deadlineDefault && receipt.humanAnsweredQuestionIDs.isEmpty)
        #expect(try await store.snapshot(requestID: id)?.questions[0].answer?.selectedOptionIDs == ["a"])
    }
    @Test func temporaryDefaultQuestionsRemainRAMOnly() async throws {
        let (database, conversation, run, store) = try await fixture(), coordinator = UserQuestionCoordinator(store: store)
        let id = UserQuestionCoordinator.requestID(runID: run, toolCallID: "temporary_default")
        let waiting = Task { try await coordinator.ask(request(), runID: run, conversationID: conversation, toolCallID: "temporary_default", cancellation: CancellationToken(), temporaryReadOnly: true) }
        let value = try await published(store, id)
        #expect(value.isEphemeral && value.currentQuestion?.deadlineAt != nil)
        #expect(try await UserQuestionStore(database: database).snapshot(requestID: id) == nil)
        try await coordinator.cancelRequest(requestID: id); _ = try await waiting.value
    }
}

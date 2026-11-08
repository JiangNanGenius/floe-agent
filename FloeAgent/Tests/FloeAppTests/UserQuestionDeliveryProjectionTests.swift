import Foundation
import Testing
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeTools
import FloeSecurity
import GRDB
@testable import FloeApp

@Suite("Optional question delivery identity")
@MainActor
struct UserQuestionDeliveryProjectionTests {
    @Test("Custom answer and note fields remain distinct in per-question delivery and old records decode")
    func customAnswerDeliveryProjection() throws {
        let request = UserQuestionWaitingSnapshot(requestID: "custom-request", requestDigest: "digest",
            conversationID: UUID(), runID: UUID(), toolCallID: "custom-call", waitPolicy: .optionalContinue,
            state: .settled, questions: [], createdAt: Date(), updatedAt: Date(), isEphemeral: false)
        let answer = UserQuestionAnswerRecord(questionID: "custom-question", question: "Which?",
            selectedOptionIDs: [], selectedOptionLabels: [], freeText: "The reason", customText: "My answer",
            source: .human, answeredAt: Date())
        let delivery = UserQuestionAnswerDelivery(requestID: request.requestID, conversationID: request.conversationID,
            runID: request.runID, answers: [answer], createdAt: Date(), text: "aggregate")
        let projected = try #require(try AppUserQuestionIntegration.individualAnswers(delivery, request: request).first)
        let reopened = try JSONDecoder().decode(UserQuestionAnswerDelivery.self, from: JSONEncoder().encode(projected))
        #expect(reopened.answers[0].customText == "My answer")
        #expect(reopened.answers[0].freeText == "The reason")
        #expect(reopened.text.contains("custom answer: My answer"))
        #expect(reopened.text.contains("note: The reason"))
        #expect(!reopened.text.contains("note: My answer"))
        #expect(try AppUserQuestionIntegration.inputID(for: reopened) == AppUserQuestionIntegration.inputID(for: projected))
    }

    @Test("Custom notification dispatch persists through the real coordinator and SQLite CAS exactly once")
    func customNotificationUsesRealCAS() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID(), run = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            .init(id: conversation, title: "Custom question", createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: database).saveRun(
            .init(id: run, conversationID: conversation, state: "running", goal: "Question", startedAt: Date()))
        let coordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        _ = try await coordinator.ask(.init(waitPolicy: .optionalContinue, questions: [
            .init(question: "Which?", options: [.init(id: "a", label: "A")], allowsFreeText: false)
        ]), runID: run, conversationID: conversation, toolCallID: "custom-notification",
            cancellation: CancellationToken(), temporaryReadOnly: false)
        let snapshot = try #require(try await coordinator.pendingSnapshot(conversationID: conversation))
        let question = try #require(snapshot.currentQuestion)
        let payload = try #require(UserQuestionNotificationPayload(requestID: snapshot.requestID,
            questionID: question.questionID, conversationID: conversation, runID: run, revision: question.revision))
        let completion = CustomAnswerCompletionProbe()
        #expect(UserQuestionNotificationBridge.dispatch(.init(payload: payload, action: .customText("My answer")),
            answering: coordinator, completion: { completion.finish() }))
        for _ in 0..<200 {
            if completion.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completion.count == 1)
        let saved = try #require(try await UserQuestionStore(database: database).snapshot(requestID: snapshot.requestID))
        #expect(saved.questions[0].answer?.customText == "My answer")
        #expect(saved.questions[0].answer?.freeText == nil)
        #expect(saved.questions[0].revision == question.revision + 1)
        let duplicate = try await coordinator.submitNotificationAnswer(requestID: payload.requestID,
            questionID: payload.questionID, conversationID: conversation, runID: run,
            expectedRevision: payload.revision, answer: .init(customText: "Different late answer"))
        #expect(!duplicate.accepted)
        #expect(duplicate.answer?.customText == "My answer")
    }

    @Test("Actual temporary question normalization redacts custom and note fields without durable credentials")
    func temporaryCustomCredentialNormalization() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = ConversationCenter(environment: environment)
        let conversation = try await center.startTemporarySession()
        let session = try #require(center.temporarySession)
        let run = UUID()
        try await session.runStore.saveRun(.init(id: run, conversationID: conversation, state: "running",
                                                 goal: "Synthetic question", startedAt: Date()))
        let question = try #require(try UserQuestionRequest(questions: [
            .init(question: "Which credential?", answerSensitivity: .credential,
                  options: [.init(id: "a", label: "A")], allowsFreeText: true)
        ]).makeQuestions(requestID: "uq_custom_ingress", conversationID: conversation, runID: run,
                         toolCallID: "custom-ingress", createdAt: Date()).first)
        let answer = UserQuestionAnswer(freeText: "QUESTION_NOTE_EPHEMERAL_42", customText: "QUESTION_CUSTOM_EPHEMERAL_43")
        let safe = try await center.normalizeQuestionAnswer(answer, question: question, ephemeral: true)
        let noteID = try #require(safe.freeText.flatMap { ModelUserInputProjection.credentialIDs(in: $0).first })
        let customID = try #require(safe.customText.flatMap { ModelUserInputProjection.credentialIDs(in: $0).first })
        #expect(noteID != customID)
        let serialized = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)
        #expect(!serialized.contains("QUESTION_NOTE_EPHEMERAL_42"))
        #expect(!serialized.contains("QUESTION_CUSTOM_EPHEMERAL_43"))
        let credentials = try await environment.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credential_records") ?? 0
        }
        #expect(credentials == 0)
        _ = await center.endTemporaryChat(expectedConversationID: conversation, expectedIncarnation: session.incarnation)
        await #expect(throws: (any Error).self) {
            try await center.normalizeQuestionAnswer(answer, question: question, ephemeral: true)
        }
    }
    @Test("An answer retains its queue identity when another answer arrives during an awaited write")
    func laterAnswerDoesNotDuplicateEarlierAnswer() throws {
        let request = UserQuestionWaitingSnapshot(requestID: "request", requestDigest: "digest",
            conversationID: UUID(), runID: UUID(), toolCallID: "call", waitPolicy: .optionalContinue,
            state: .settled, questions: [], createdAt: Date(), updatedAt: Date(), isEphemeral: false)
        let first = UserQuestionAnswerRecord(questionID: "request:first", question: "City?",
            selectedOptionIDs: [], selectedOptionLabels: [], freeText: "上海",
            source: .human, answeredAt: Date())
        let second = UserQuestionAnswerRecord(questionID: "request:second", question: "Day?",
            selectedOptionIDs: [], selectedOptionLabels: [], freeText: "明天",
            source: .human, answeredAt: Date())
        func delivery(_ answers: [UserQuestionAnswerRecord]) -> UserQuestionAnswerDelivery {
            UserQuestionAnswerDelivery(requestID: request.requestID,
                conversationID: request.conversationID, runID: request.runID,
                answers: answers, createdAt: Date(), text: "unused aggregate")
        }
        let beforeWrite = try AppUserQuestionIntegration.individualAnswers(delivery([first]), request: request)
        let duringWrite = try AppUserQuestionIntegration.individualAnswers(delivery([first, second]), request: request)
        #expect(beforeWrite.count == 1)
        #expect(duringWrite.count == 2)
        #expect(try AppUserQuestionIntegration.inputID(for: beforeWrite[0])
            == AppUserQuestionIntegration.inputID(for: duringWrite[0]))
        let identities = try Set((beforeWrite + duringWrite).map { try AppUserQuestionIntegration.inputID(for: $0) })
        #expect(identities.count == 2)
        #expect(duringWrite[0].text.contains("上海"))
        #expect(!duringWrite[0].text.contains("明天"))
        #expect(duringWrite[1].text.contains("明天"))
    }
}

private final class CustomAnswerCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func finish() { lock.withLock { value += 1 } }
}

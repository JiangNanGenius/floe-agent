import Foundation
import Testing
import FloeModels
@testable import FloeApp

private final class QuestionCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completions = 0
    var count: Int { lock.withLock { completions } }
    func finish() { lock.withLock { completions += 1 } }
}

private actor QuestionNotificationWriter: UserQuestionNotificationAnswering {
    private(set) var started = false
    private(set) var persisted = false
    private(set) var receivedText: String?
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func commit() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func submitNotificationAnswer(
        requestID: String, questionID: String, conversationID: UUID, runID: UUID,
        expectedRevision: Int, answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        started = true
        receivedText = answer.freeText
        if !released { await withCheckedContinuation { continuation = $0 } }
        persisted = true
        return UserQuestionAnswerReceipt(
            target: UserQuestionAnswerTarget(requestID: requestID, questionID: questionID,
                conversationID: conversationID, runID: runID, expectedRevision: expectedRevision),
            status: .answered, revision: expectedRevision + 1, accepted: true, alreadySettled: false,
            answer: UserQuestionAnswerRecord(questionID: questionID, question: "City?",
                selectedOptionIDs: answer.selectedOptionIDs, selectedOptionLabels: [],
                freeText: answer.freeText, source: .human, answeredAt: Date()),
            requestState: .settled
        )
    }
}

/// Exercises the actual dispatcher used immediately after native response
/// parsing. It does not fabricate private UNNotificationResponse objects or
/// claim delivery through the operating system's notification UI.
@Suite("Question notification persistence boundary")
@MainActor
struct UserQuestionNotificationIntegrationTests {
    private func payload() throws -> UserQuestionNotificationPayload {
        try #require(UserQuestionNotificationPayload(requestID: "question-notification-test",
            questionID: "question-notification-test:city", conversationID: UUID(), runID: UUID(), revision: 1))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("An inline answer waits for persistence, completes once, and never requires navigation")
    func answerCompletesAfterCommit() async throws {
        let writer = QuestionNotificationWriter()
        let completion = QuestionCompletionProbe()
        var opened = false
        let response = UserQuestionNotificationResponse(payload: try payload(), action: .text("上海"))
        let handled = UserQuestionNotificationBridge.dispatch(response, answering: writer,
            onOpen: { _ in opened = true }, completion: { completion.finish() })
        #expect(handled)
        #expect(await waitUntil { await writer.started })
        #expect(completion.count == 0)
        #expect(opened == false)
        #expect(await writer.persisted == false)
        await writer.commit()
        #expect(await waitUntil { completion.count == 1 })
        #expect(await writer.persisted)
        #expect(await writer.receivedText == "上海")
        #expect(completion.count == 1)
        #expect(opened == false)
    }

    @Test("A default tap opens the original task without submitting any answer")
    func openIsNotAnAnswer() async throws {
        let writer = QuestionNotificationWriter()
        let completion = QuestionCompletionProbe()
        let target = try payload()
        var opened: UserQuestionNotificationPayload?
        let handled = UserQuestionNotificationBridge.dispatch(
            UserQuestionNotificationResponse(payload: target, action: .open), answering: writer,
            onOpen: { opened = $0 }, completion: { completion.finish() })
        #expect(handled)
        #expect(await waitUntil { completion.count == 1 })
        #expect(opened == target)
        #expect(await writer.started == false)
        #expect(completion.count == 1)
    }
}

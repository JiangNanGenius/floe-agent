import Foundation
import Testing
import FloeModels
@testable import FloeApp

@Suite("Optional question delivery identity")
@MainActor
struct UserQuestionDeliveryProjectionTests {
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

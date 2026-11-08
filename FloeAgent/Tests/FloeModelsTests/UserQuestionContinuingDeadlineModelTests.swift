import Foundation
import Testing
import FloeCore
@testable import FloeModels

@Suite("Nonblocking optional deadline model contract")
struct UserQuestionContinuingDeadlineModelTests {
    private func request() -> UserQuestionRequest {
        .init(waitPolicy: .optionalContinue, questions: [.init(question: "Which layout?",
            options: [.init(id: "a", label: "Compact"), .init(id: "b", label: "Wide")],
            fallback: .init(selectedOptionIDs: ["a"]))])
    }
    private func questions(_ request: UserQuestionRequest) throws -> [UserQuestion] {
        try request.makeQuestions(requestID: "uq_continuing", conversationID: UUID(), runID: UUID(),
            toolCallID: "continuing", createdAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func snapshot(_ questions: [UserQuestion], state: UserQuestionRequestState = .awaitingOptional) throws -> UserQuestionWaitingSnapshot {
        let first = try #require(questions.first)
        return .init(requestID: first.requestID, requestDigest: "fixture", conversationID: first.conversationID,
            runID: first.runID, toolCallID: first.toolCallID, waitPolicy: .optionalContinue, state: state,
            questions: questions, createdAt: first.createdAt, updatedAt: first.updatedAt, isEphemeral: false)
    }
    private func expired(_ question: UserQuestion) throws -> UserQuestion {
        var result = question
        let fallback = try #require(question.fallback)
        result.answer = try UserQuestionAnswer(selectedOptionIDs: fallback.selectedOptionIDs,
            freeText: fallback.freeText).validated(for: question, partial: false)
        result.status = .expired; result.answerSource = .deadlineDefault
        result.answeredAt = question.deadlineAt; result.revision += 1
        return result
    }

    @Test func declaredDefaultGetsFifteenSecondsWithoutBlockingOrPreAnswering() throws {
        let raw = request(), prepared = try raw.resolvingDefaults(.init())
        let question = try #require(questions(prepared).first)
        #expect(raw.questions[0].timeoutSeconds == nil && prepared.questions[0].timeoutSeconds == 15)
        #expect(question.deadlineAt?.timeIntervalSince(question.createdAt) == 15)
        #expect(question.hasPendingOptionalDeadline && !question.blocksCurrentWork)
        #expect(question.answer == nil && question.answerSource == nil)
        #expect(UserQuestionFallbackPresentation(question: question)?.components == ["Compact"])
        let waiting = try snapshot([question]), receipt = UserQuestionFormatting.toolReceipt(for: waiting)
        #expect(!waiting.hasBlockingPending && receipt.status == .pending)
        #expect(receipt.answers.isEmpty && receipt.humanAnsweredQuestionIDs.isEmpty && receipt.defaultedQuestionIDs.isEmpty)
    }

    @Test func oldOptionalContinuePayloadRoundTripsUntimedAndTimeoutAloneIsRejected() throws {
        let json = #"{"waitPolicy":"optionalContinue","questions":[{"question":"Which?","options":[{"id":"a","label":"A"}]}]}"#
        let old = try JSONDecoder().decode(UserQuestionRequest.self, from: Data(json.utf8))
        let decoded = try JSONDecoder().decode(UserQuestionRequest.self, from: JSONEncoder().encode(old))
        let prepared = try decoded.resolvingDefaults(.init(optionalTimeoutSeconds: 30))
        #expect(prepared == old)
        let question = try #require(questions(prepared).first)
        #expect(question.deadlineAt == nil && !question.hasPendingOptionalDeadline)
        var invalid = old; invalid.timeoutSeconds = 5
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.timeoutSeconds = nil; invalid.questions[0].timeoutSeconds = 5
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func requiredQuestionNeverBecomesADeadlineEvenInMixedRequests() throws {
        var raw = request()
        raw.questions.append(.init(question: "Choose the major direction", waitPolicy: .required))
        let materialized = try questions(raw.resolvingDefaults(.init()))
        #expect(materialized[0].deadlineAt != nil && materialized[1].deadlineAt == nil)
        #expect(try snapshot(materialized, state: .awaitingAnswer).hasBlockingPending)
        var forged = materialized[1]; forged.deadlineAt = materialized[0].deadlineAt
        #expect(!forged.hasPendingOptionalDeadline)
        var required = raw; required.questions[1].fallback = .init(freeText: "Approve")
        #expect(throws: (any Error).self) { try required.resolvingDefaults(.init()).validate() }
    }

    @Test func explicitIntervalWinsAndCredentialNeverGetsAnImplicitNonblockingDefault() throws {
        var raw = request(); raw.timeoutSeconds = 30; raw.questions[0].timeoutSeconds = 5
        let question = try #require(questions(raw.resolvingDefaults(.init(optionalTimeoutSeconds: 60))).first)
        #expect(question.deadlineAt?.timeIntervalSince(question.createdAt) == 5)
        raw.questions[0].answerSensitivity = .credential
        #expect(throws: (any Error).self) { try raw.resolvingDefaults(.init()).validate() }
        raw.timeoutSeconds = nil; raw.questions[0].timeoutSeconds = nil
        #expect(try raw.resolvingDefaults(.init()) == raw)
        #expect(throws: (any Error).self) { try raw.validate() }
    }

    @Test func aTimedFallbackMustBeACompleteAnswerAtPublication() throws {
        for policy in [UserQuestionWaitPolicy.optionalContinue, .optionalDeadline] {
            var raw = request(); raw.waitPolicy = policy
            raw.questions[0].fallback?.freeText = "Use default spacing"
            #expect(throws: (any Error).self) { try raw.resolvingDefaults(.init()).validate() }
            raw.questions[0].allowsFreeText = true
            let valid = try #require(questions(raw.resolvingDefaults(.init())).first)
            let applied = try expired(valid)
            #expect(applied.answer?.freeText == "Use default spacing" && applied.answerSource == .deadlineDefault)
            raw.questions[0].fallback?.freeText = String(repeating: "x", count: 1_001)
            #expect(throws: (any Error).self) { try raw.resolvingDefaults(.init()).validate() }
        }
    }

    @Test func onlyAnExactUndeliveredDefaultCanEnterTheOptionalAnswerQueue() throws {
        let question = try #require(questions(request().resolvingDefaults(.init())).first)
        var settled = try expired(question)
        #expect(settled.hasUndeliveredOptionalAnswer && !settled.hasPendingOptionalDeadline)
        settled.answer = .init(selectedOptionIDs: ["b"])
        #expect(!settled.hasUndeliveredOptionalAnswer)
        settled = try expired(question); settled.answerSource = .human
        #expect(!settled.hasUndeliveredOptionalAnswer)
        settled = try expired(question); settled.deliveredAt = settled.answeredAt
        #expect(!settled.hasUndeliveredOptionalAnswer)
        settled = try expired(question); settled.waitPolicy = .required
        #expect(!settled.hasUndeliveredOptionalAnswer)
    }

    @Test func aHumanAnswerKeepsItsOwnProvenanceAndOptionalDelivery() throws {
        var question = try #require(questions(request().resolvingDefaults(.init())).first)
        question.status = .answered; question.answerSource = .human
        question.answer = .init(selectedOptionIDs: ["b"]); question.answeredAt = question.createdAt
        #expect(question.hasUndeliveredOptionalAnswer && !question.hasPendingOptionalDeadline)
        let record = try #require(question.answerRecord())
        let text = UserQuestionFormatting.deliveryText(request: try snapshot([question], state: .settled), answers: [record])
        #expect(text.contains("The user answered") && !text.contains("declared deadline default"))
        question.deliveredAt = question.createdAt
        #expect(!question.hasUndeliveredOptionalAnswer)
    }

    @Test func earliestDeadlineIgnoresSettledRequiredAndLegacyUntimedQuestions() throws {
        var raw = request(); raw.timeoutSeconds = 10
        raw.questions.append(.init(question: "Later?", options: [.init(id: "x", label: "X")],
            timeoutSeconds: 20, fallback: .init(selectedOptionIDs: ["x"])))
        raw.questions.append(.init(question: "Untimed?"))
        var materialized = try questions(raw)
        #expect(try snapshot(materialized).earliestPendingDeadline == materialized[0].deadlineAt)
        materialized[0] = try expired(materialized[0])
        #expect(try snapshot(materialized).earliestPendingDeadline == materialized[1].deadlineAt)
        materialized[1].waitPolicy = .required
        #expect(try snapshot(materialized).earliestPendingDeadline == nil)
    }

    @Test func aDefaultReceiptAndDeliveryNeverClaimAHumanAnswerOrAuthority() throws {
        let question = try expired(try #require(questions(request().resolvingDefaults(.init())).first))
        let settled = try snapshot([question], state: .settled)
        let receipt = UserQuestionFormatting.toolReceipt(for: settled)
        // Existing receipts classify an expired question carrying a fallback
        // answer as mixed. Keep that contract and inspect provenance directly.
        #expect(receipt.status == .mixed && receipt.humanAnsweredQuestionIDs.isEmpty)
        #expect(receipt.expiredQuestionIDs == [question.questionID])
        #expect(receipt.defaultedQuestionIDs == [question.questionID] && receipt.answers[0].source == .deadlineDefault)
        let text = UserQuestionFormatting.deliveryText(request: settled, answers: receipt.answers)
        #expect(text.contains("NOT a human answer or authorization") && !text.contains("The user answered"))
        #expect(text.contains("declared deadline default"))
    }
}

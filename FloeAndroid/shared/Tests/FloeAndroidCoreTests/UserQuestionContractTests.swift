// SPDX-License-Identifier: MPL-2.0
//
// G07.3A user-question contract tests (pure models).
//
// These pin the exact identity/provenance rules the Android host relies on:
// one request has 1...3 questions, a single-select answer is complete only
// with exactly one valid option, free text is bounded, a deadline default is
// never reported as a human answer, and the notify nonce binds the exact
// request digest/question/revision generation.
import XCTest
import FloeCore
import FloeModels
@testable import FloeAgentRuntime
@testable import FloeAndroidCore

final class UserQuestionContractTests: XCTestCase {

    private func request(
        policy: UserQuestionWaitPolicy = .required,
        timeout: Int? = nil,
        questions: [UserQuestionDraft]
    ) throws -> UserQuestionRequest {
        try UserQuestionRequest(waitPolicy: policy, timeoutSeconds: timeout, questions: questions)
    }

    func testRequestRejectsEmptyAndOverlongSets() {
        XCTAssertThrowsError(try request(questions: []))
        let tooMany = (0..<4).map {
            UserQuestionDraft(question: "Question \($0)")
        }
        XCTAssertThrowsError(try request(questions: tooMany))
        XCTAssertNoThrow(try request(questions: [
            UserQuestionDraft(question: "Only one"),
        ]))
    }

    func testTimeoutOnlyAllowedForExplicitDeadline() {
        XCTAssertThrowsError(try request(
            timeout: 60,
            questions: [UserQuestionDraft(question: "Required")]))
        XCTAssertThrowsError(try request(
            policy: .optionalContinue,
            timeout: 60,
            questions: [UserQuestionDraft(question: "Optional")]))
        XCTAssertNoThrow(try request(
            policy: .optionalDeadline,
            timeout: 60,
            questions: [UserQuestionDraft(question: "Deadline")]))
    }

    func testAnswerValidationIsSingleSelectExact() throws {
        let question = try XCTUnwrap(
            try request(questions: [
                UserQuestionDraft(
                    question: "Pick one",
                    options: [
                        UserQuestionOption(id: "a", label: "A"),
                        UserQuestionOption(id: "b", label: "B"),
                    ])
            ]).makeQuestions(
                requestID: "uq_test", conversationID: UUID(),
                runID: UUID(), toolCallID: "call", createdAt: Date()
            ).first)
        XCTAssertThrowsError(try UserQuestionAnswer(selectedOptionIDs: [])
            .validated(for: question, partial: false))
        XCTAssertThrowsError(try UserQuestionAnswer(selectedOptionIDs: ["a", "b"])
            .validated(for: question, partial: false))
        XCTAssertThrowsError(try UserQuestionAnswer(selectedOptionIDs: ["unknown"])
            .validated(for: question, partial: false))
        XCTAssertNoThrow(try UserQuestionAnswer(selectedOptionIDs: ["a"])
            .validated(for: question, partial: false))
    }

    func testTextOnlyQuestionAcceptsBoundedFreeText() throws {
        let question = try XCTUnwrap(
            try request(questions: [
                UserQuestionDraft(question: "Explain", options: []),
            ]).makeQuestions(
                requestID: "uq_text", conversationID: UUID(),
                runID: UUID(), toolCallID: "call", createdAt: Date()
            ).first)
        XCTAssertTrue(question.isTextOnly)
        XCTAssertThrowsError(try UserQuestionAnswer(freeText: "  ")
            .validated(for: question, partial: false))
        XCTAssertNoThrow(try UserQuestionAnswer(freeText: "because")
            .validated(for: question, partial: false))
        XCTAssertThrowsError(try UserQuestionAnswer(
            freeText: String(repeating: "x", count: 1_001))
            .validated(for: question, partial: false))
    }

    func testDeadlineDefaultIsNeverAHumanAnswer() {
        let snapshot = UserQuestionWaitingSnapshot(
            requestID: "uq_deadline",
            requestDigest: String(repeating: "a", count: 64),
            conversationID: UUID(),
            runID: UUID(),
            toolCallID: "call",
            waitPolicy: .optionalDeadline,
            state: .settled,
            questions: [
                UserQuestion(
                    questionID: "uq_deadline.q1",
                    requestID: "uq_deadline",
                    conversationID: UUID(),
                    runID: UUID(),
                    toolCallID: "call",
                    ordinal: 0,
                    localID: "q1",
                    text: "Continue?",
                    options: [],
                    selectionMode: .single,
                    allowsFreeText: true,
                    waitPolicy: .optionalDeadline,
                    deadlineAt: Date(),
                    fallback: UserQuestionFallback(freeText: "default"),
                    status: .expired,
                    revision: 2,
                    answer: UserQuestionAnswer(freeText: "default"),
                    answerSource: .deadlineDefault,
                    createdAt: Date(),
                    updatedAt: Date(),
                    answeredAt: Date()
                )
            ],
            createdAt: Date(),
            updatedAt: Date(),
            isEphemeral: false
        )
        let receipt = UserQuestionFormatting.toolReceipt(for: snapshot)
        XCTAssertEqual(receipt.status, .mixed)
        XCTAssertEqual(receipt.defaultedQuestionIDs, ["uq_deadline.q1"])
        XCTAssertTrue(receipt.humanAnsweredQuestionIDs.isEmpty)
        XCTAssertTrue(receipt.message.contains("NOT a human answer"))
    }

    func testAnswerNonceBindsExactGeneration() {
        let base = UserQuestionHostWire.answerNonce(
            requestID: "uq_a", questionID: "uq_a.q1", revision: 1,
            requestDigest: String(repeating: "a", count: 64))
        XCTAssertEqual(base.count, 64)
        XCTAssertNotEqual(base, UserQuestionHostWire.answerNonce(
            requestID: "uq_a", questionID: "uq_a.q1", revision: 2,
            requestDigest: String(repeating: "a", count: 64)))
        XCTAssertNotEqual(base, UserQuestionHostWire.answerNonce(
            requestID: "uq_a", questionID: "uq_a.q1", revision: 1,
            requestDigest: String(repeating: "b", count: 64)))
    }

    func testToolIsMainRunOnlyAndGrantsNoAuthority() {
        XCTAssertEqual(UserAskTool.name, "user.ask")
        XCTAssertTrue(UserAskTool.riskLabels.isEmpty)
        XCTAssertFalse(UserAskTool.isSideEffecting)
        XCTAssertEqual(UserAskTool.executionBoundary, .mainRunOnly)
        XCTAssertEqual(UserAskTool.toolEffect, .internalState)
    }
}

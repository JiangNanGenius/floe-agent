// SPDX-License-Identifier: MPL-2.0
//
// G07.3A UserQuestionStore semantics (RAM/ephemeral path).
//
// The durable path shares the same settlement/expiry/cancel helpers; these
// tests pin the once-only CAS, the real provenance of declared deadline
// defaults, and the stale-revision refusal that notification/in-app double
// taps rely on. No provider, network or UI is involved.
import XCTest
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class UserQuestionStoreTests: XCTestCase {

    private var database: DatabaseManager!
    private var store: UserQuestionStore!
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-uq-\(UUID().uuidString).db")
        database = try DatabaseManager(path: url)
        try await database.migrate()
        store = UserQuestionStore(database: database)
    }

    override func tearDown() async throws {
        try? await database.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func registration(
        id: String = "uq_test",
        policy: UserQuestionWaitPolicy = .required,
        timeout: Int? = nil,
        isEphemeral: Bool = true,
        createdAt: Date = Date()
    ) throws -> UserQuestionRegistration {
        let draft = UserQuestionDraft(
            id: "q1",
            question: "Proceed?",
            options: [
                UserQuestionOption(id: "yes", label: "Yes"),
                UserQuestionOption(id: "no", label: "No"),
            ],
            selection: .single,
            waitPolicy: policy,
            timeoutSeconds: timeout,
            fallback: policy == .optionalDeadline
                ? UserQuestionFallback(selectedOptionIDs: ["yes"])
                : nil
        )
        let request = try UserQuestionRequest(
            waitPolicy: policy, timeoutSeconds: timeout, questions: [draft])
        let questions = try request.makeQuestions(
            requestID: id,
            conversationID: UUID(),
            runID: UUID(),
            toolCallID: "call-\(id)",
            createdAt: createdAt)
        return UserQuestionRegistration(
            requestID: id,
            requestDigest: String(repeating: "a", count: 64),
            conversationID: questions[0].conversationID,
            runID: questions[0].runID,
            toolCallID: "call-\(id)",
            waitPolicy: policy,
            questions: questions,
            createdAt: createdAt,
            isEphemeral: isEphemeral)
    }

    func testRegistrationAndAnswerIsExactOnce() async throws {
        let registration = try registration()
        let snapshot = try await store.register(registration)
        XCTAssertEqual(snapshot.state, .awaitingAnswer)
        let question = try XCTUnwrap(snapshot.currentQuestion)
        let target = snapshot.target(for: question)

        let accepted = try await store.submitHumanAnswer(
            target: target,
            answer: UserQuestionAnswer(selectedOptionIDs: ["yes"]),
            now: Date())
        XCTAssertTrue(accepted.accepted)
        XCTAssertFalse(accepted.alreadySettled)
        XCTAssertEqual(accepted.status, .answered)
        XCTAssertEqual(accepted.answer?.selectedOptionLabels, ["Yes"])

        let duplicate = try await store.submitHumanAnswer(
            target: target,
            answer: UserQuestionAnswer(selectedOptionIDs: ["no"]),
            now: Date())
        XCTAssertFalse(duplicate.accepted)
        XCTAssertTrue(duplicate.alreadySettled)
        XCTAssertEqual(duplicate.answer?.selectedOptionIDs, ["yes"])
    }

    func testStaleRevisionIsRefused() async throws {
        let registration = try registration()
        let snapshot = try await store.register(registration)
        let question = try XCTUnwrap(snapshot.currentQuestion)
        var target = snapshot.target(for: question)
        target.expectedRevision = question.revision + 1
        do {
            _ = try await store.submitHumanAnswer(
                target: target,
                answer: UserQuestionAnswer(selectedOptionIDs: ["yes"]),
                now: Date())
            XCTFail("stale revision must not settle")
        } catch let error as UserQuestionError {
            guard case .staleRevision(let current) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(current, question.revision)
        }
    }

    func testCancelProducesNoAnswerAndLateAnswerIsAlreadySettled() async throws {
        let registration = try registration()
        let snapshot = try await store.register(registration)
        let question = try XCTUnwrap(snapshot.currentQuestion)
        let cancelled = try await store.cancel(requestID: registration.requestID, now: Date())
        XCTAssertEqual(cancelled?.state, .cancelled)
        let late = try await store.submitHumanAnswer(
            target: snapshot.target(for: question),
            answer: UserQuestionAnswer(selectedOptionIDs: ["yes"]),
            now: Date())
        XCTAssertFalse(late.accepted)
        XCTAssertTrue(late.alreadySettled)
        XCTAssertEqual(late.status, .cancelled)
        XCTAssertNil(late.answer)
    }

    func testDeclaredDeadlineDefaultIsNotHuman() async throws {
        let created = Date().addingTimeInterval(-10)
        let registration = try registration(
            policy: .optionalDeadline, timeout: 5, createdAt: created)
        _ = try await store.register(registration)
        let expired = try await store.expire(
            requestID: registration.requestID, now: Date())
        let question = try XCTUnwrap(expired?.questions.first)
        XCTAssertEqual(question.status, .expired)
        XCTAssertEqual(question.answerSource, .deadlineDefault)
        XCTAssertFalse(question.isHumanAnswered)
        XCTAssertEqual(question.answer?.selectedOptionIDs, ["yes"])
    }

    func testDeadlineWithoutFallbackHasNoAnswerRecord() async throws {
        let created = Date().addingTimeInterval(-10)
        let draft = UserQuestionDraft(
            question: "Continue?",
            waitPolicy: .optionalDeadline,
            timeoutSeconds: 5,
            fallback: nil)
        let request = try UserQuestionRequest(
            waitPolicy: .optionalDeadline, timeoutSeconds: 5, questions: [draft])
        let conversationID = UUID()
        let runID = UUID()
        let questions = try request.makeQuestions(
            requestID: "uq_expired", conversationID: conversationID,
            runID: runID, toolCallID: "call", createdAt: created)
        _ = try await store.register(UserQuestionRegistration(
            requestID: "uq_expired",
            requestDigest: String(repeating: "b", count: 64),
            conversationID: conversationID,
            runID: runID,
            toolCallID: "call",
            waitPolicy: .optionalDeadline,
            questions: questions,
            createdAt: created,
            isEphemeral: true))
        let expired = try await store.expire(requestID: "uq_expired", now: Date())
        let question = try XCTUnwrap(expired?.questions.first)
        XCTAssertEqual(question.status, .expired)
        XCTAssertEqual(question.answerSource, .expired)
        XCTAssertNil(question.answer)
        XCTAssertNil(question.answerRecord())
    }

    func testPurgeEphemeralRemovesRAMRows() async throws {
        let registration = try registration()
        _ = try await store.register(registration)
        await store.purgeEphemeral(runID: registration.runID)
        let snapshot = try await store.snapshot(requestID: registration.requestID)
        XCTAssertNil(snapshot)
    }
}

import Foundation
import Testing
import FloeCore
@testable import FloeModels

@Suite("User question configurable default policy")
struct UserQuestionDefaultsTests {
    private func choice(policy: UserQuestionWaitPolicy = .optionalDeadline, fallback: Bool = true, sensitivity: UserQuestionAnswerSensitivity = .ordinary) -> UserQuestionRequest {
        .init(waitPolicy: policy, questions: [.init(question: "Which layout?", answerSensitivity: sensitivity,
            options: [.init(id: "compact", label: "Compact"), .init(id: "wide", label: "Wide")],
            fallback: fallback ? .init(selectedOptionIDs: ["compact"]) : nil)])
    }
    private func materialize(_ request: UserQuestionRequest) throws -> [UserQuestion] {
        try request.makeQuestions(requestID: "uq_defaults", conversationID: UUID(), runID: UUID(), toolCallID: "call_defaults", createdAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    @Test func ordinaryDeclaredFallbackUsesFifteenSecondsAndKeepsRawRequestUnchanged() throws {
        let raw = choice(), prepared = try raw.resolvingDefaults(.init())
        try prepared.validate()
        let question = try #require(materialize(prepared).first)
        #expect(raw.questions[0].timeoutSeconds == nil && raw.timeoutSeconds == nil)
        #expect(prepared.questions[0].timeoutSeconds == 15)
        #expect(question.deadlineAt?.timeIntervalSince(question.createdAt) == 15)
        #expect(question.answer == nil && question.answerSource == nil)
    }
    @Test func requiredAndLegacyOptionalContinueAreNeverSilentlyChanged() throws {
        for policy in [UserQuestionWaitPolicy.required, .optionalContinue] {
            let raw = choice(policy: policy, fallback: false)
            let prepared = try raw.resolvingDefaults(.init(optionalTimeoutSeconds: 60))
            #expect(raw == prepared)
            let question = try #require(materialize(prepared).first)
            #expect(question.deadlineAt == nil && question.fallback == nil)
            #expect(question.waitPolicy == policy)
        }
        #expect(throws: (any Error).self) { try choice(policy: .required).resolvingDefaults(.init()).validate() }
    }
    @Test func explicitIntervalsOverrideThePreferenceWithoutCoercion() throws {
        var raw = choice(); raw.timeoutSeconds = 60; raw.questions[0].timeoutSeconds = 10
        let prepared = try raw.resolvingDefaults(.init(optionalTimeoutSeconds: 30))
        #expect(prepared == raw)
        #expect(try materialize(prepared)[0].deadlineAt?.timeIntervalSince(materialize(prepared)[0].createdAt) == 10)
        raw.questions[0].timeoutSeconds = nil
        #expect(try raw.resolvingDefaults(.init()).questions[0].effectiveTimeoutSeconds(default: raw.timeoutSeconds) == 60)
    }
    @Test func mixedRequiredAndOptionalQuestionsOnlyMaterializeTheOptionalDeadline() throws {
        var raw = choice(); raw.waitPolicy = .required; raw.questions[0].waitPolicy = .optionalDeadline
        raw.questions.append(.init(question: "Confirm the major direction", waitPolicy: .required))
        let questions = try materialize(raw.resolvingDefaults(.init()))
        #expect(questions[0].deadlineAt != nil && questions[1].deadlineAt == nil)
        #expect(questions[1].waitPolicy == .required && questions[1].fallback == nil)
    }
    @Test func missingFallbackOrCredentialNeverGetsAnImplicitDeadline() throws {
        for raw in [choice(fallback: false), choice(sensitivity: .credential)] {
            let prepared = try raw.resolvingDefaults(.init())
            #expect(prepared == raw)
            #expect(throws: (any Error).self) { try prepared.validate() }
        }
    }
    @Test func configuredPreferencePersistsAndMalformedValuesDoNotBecomeATimer() throws {
        let suite = "FloeQuestionDefaults-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        #expect(UserQuestionDefaults.load(from: defaults).optionalTimeoutSeconds == 15)
        try UserQuestionDefaults(optionalTimeoutSeconds: 30).save(to: defaults)
        #expect(UserQuestionDefaults.load(from: try #require(UserDefaults(suiteName: suite))).optionalTimeoutSeconds == 30)
        #expect(throws: (any Error).self) { try UserQuestionDefaults(optionalTimeoutSeconds: 4).save(to: defaults) }
        #expect(UserQuestionDefaults.load(from: defaults).optionalTimeoutSeconds == 30)
        defaults.set(Data(#"{"optionalTimeoutSeconds":15.5}"#.utf8), forKey: UserQuestionDefaults.settingsKey)
        #expect(UserQuestionDefaults.load(from: defaults).optionalTimeoutSeconds == 15)
    }
    @Test func theExistingDeadlineRangeIsKeptExactly() throws {
        for value in [5, 15, 86_400] { #expect(try UserQuestionDefaults(optionalTimeoutSeconds: value).validated().optionalTimeoutSeconds == value) }
        for value in [0, 4, 86_401] { #expect(throws: (any Error).self) { try UserQuestionDefaults(optionalTimeoutSeconds: value).validated() } }
    }
    @Test func fallbackIsVisibleBeforeExpiryWithoutSelectingOrAnsweringForThePerson() throws {
        var request = choice(); request.questions[0].fallback?.freeText = "Keep the default spacing"
        let question = try #require(materialize(request.resolvingDefaults(.init())).first)
        let preview = try #require(UserQuestionFallbackPresentation(question: question))
        #expect(preview.components == ["Compact", "Keep the default spacing"] && !preview.isSensitive)
        #expect(question.answer == nil && question.answerSource == nil && question.status == .pending)
    }
    @Test func sensitiveDeclaredFallbackHasNoReadableValueInThePresentation() throws {
        var request = choice(sensitivity: .credential); request.timeoutSeconds = 5
        let question = try #require(materialize(request).first)
        let preview = try #require(UserQuestionFallbackPresentation(question: question))
        #expect(preview.isSensitive && preview.components.isEmpty)
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeModels
@testable import FloeApp

@Suite("FloeApp.UserQuestionCard")
@MainActor
struct UserQuestionCardTests {

    private func snapshot(
        _ drafts: [UserQuestionDraft],
        policy: UserQuestionWaitPolicy = .required
    ) throws -> UserQuestionWaitingSnapshot {
        let request = UserQuestionRequest(waitPolicy: policy, questions: drafts)
        try request.validate()
        let requestID = "uq_card_test"
        let conversationID = UUID()
        let runID = UUID()
        let questions = try request.makeQuestions(
            requestID: requestID,
            conversationID: conversationID,
            runID: runID,
            toolCallID: "call_card",
            createdAt: Date()
        )
        return UserQuestionWaitingSnapshot(
            requestID: requestID,
            requestDigest: "digest",
            conversationID: conversationID,
            runID: runID,
            toolCallID: "call_card",
            waitPolicy: policy,
            state: .awaitingAnswer,
            questions: questions,
            createdAt: Date(),
            updatedAt: Date(),
            isEphemeral: false
        )
    }

    @Test("Single-select replaces, multi-select toggles and the current answer validates")
    func selectionModes() throws {
        let single = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "Pick one",
                options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")],
                selection: .single
            )
        ]))
        single.toggleOption("a")
        single.toggleOption("b")
        #expect(single.selectedOptionIDs == ["b"])
        #expect(single.canContinue)

        let multiple = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "Pick many",
                options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")],
                selection: .multiple
            )
        ]))
        multiple.toggleOption("a")
        multiple.toggleOption("b")
        #expect(multiple.selectedOptionIDs == ["a", "b"])
        multiple.toggleOption("a")
        #expect(multiple.selectedOptionIDs == ["b"])
    }

    @Test("Text-only questions need text; optional notes stay secondary")
    func textAndOptionalNotes() throws {
        let textOnly = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "What should I name it?")
        ]))
        #expect(textOnly.isTextQuestion)
        #expect(!textOnly.canContinue)
        textOnly.setFreeText("Floe")
        #expect(textOnly.canContinue)
        #expect(textOnly.currentAnswer?.freeText == "Floe")

        let withNote = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "Which?",
                options: [.init(id: "a", label: "A")],
                allowsFreeText: true
            )
        ]))
        withNote.toggleOption("a")
        #expect(withNote.canContinue)
        #expect(!withNote.isNoteRevealed)
        withNote.revealNote()
        withNote.setFreeText("because")
        #expect(withNote.currentAnswer?.freeText == "because")
        withNote.hideNote()
        #expect(withNote.freeText.isEmpty)
        #expect(withNote.canContinue)
    }

    @Test("One question is shown at a time and drafts survive navigation")
    func oneAtATimeAndDraftSurvival() throws {
        var persisted: [(String, String?)] = []
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "First",
                options: [.init(id: "a", label: "A")],
                selection: .single
            ),
            .init(question: "Second")
        ]))
        model.onDraftChanged = { target, answer in
            persisted.append((target.questionID, answer.freeText))
        }
        #expect(model.index == 0)
        #expect(model.questionCount == 2)
        model.toggleOption("a")
        model.advance()
        #expect(model.index == 1)
        #expect(model.currentQuestion?.text == "Second")
        #expect(model.selectedOptionIDs.isEmpty)
        model.setFreeText("second answer")
        model.goBack()
        #expect(model.index == 0)
        #expect(model.selectedOptionIDs == ["a"])
        #expect(!persisted.isEmpty)
    }

    @Test("A non-last Continue produces a submit action for that question, never a local advance")
    func nonLastContinueSubmitsCurrentQuestion() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "First", options: [.init(id: "a", label: "A")], selection: .single),
            .init(question: "Second", options: [.init(id: "b", label: "B")], selection: .single),
        ]))
        #expect(model.continueAction() == nil)
        model.toggleOption("a")
        let action = try #require(model.continueAction())
        guard case .submit(let target, let answer) = action else {
            Issue.record("Continue must submit the current question")
            return
        }
        #expect(target.questionID == model.questions[0].questionID)
        #expect(answer.selectedOptionIDs == ["a"])
        #expect(model.index == 0)
        #expect(!model.isLastQuestion)
        // It is a complete answer, so CAS/refresh can move the host to the
        // next pending question; the card never silently skips this one.
        #expect(answer.isComplete(for: model.questions[0]))
    }

    @Test("Each Continue is a complete answer; settled questions are skipped by Back")
    func multiQuestionAnswersAreSubmittedIndividually() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "First",
                options: [.init(id: "a", label: "A")],
                selection: .single
            ),
            .init(
                question: "Second",
                options: [.init(id: "b", label: "B")],
                selection: .single
            ),
        ]))
        // A non-last question is not satisfied by an empty draft; Continue
        // submits it as a complete CAS answer, not an intermediate skip.
        #expect(!model.canContinue)
        model.toggleOption("a")
        #expect(model.canContinue)
        model.markSubmissionSucceeded()
        model.advanceAfterAcceptedAnswer()
        #expect(model.index == 1)
        #expect(model.isLastQuestion)
        // Back cannot return to the already-accepted first question.
        model.goBack()
        #expect(model.index == 1)
        model.toggleOption("b")
        #expect(model.canContinue)
        model.markSubmissionSucceeded()
        #expect(model.isCurrentSettled)
    }

    @Test("Dictation appends to the existing note and never starts a second recognizer")
    func dictationAppendsText() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "Tell me more")
        ]))
        model.applyDictatedText(" first phrase ")
        model.applyDictatedText("second phrase")
        #expect(model.freeText == "first phrase second phrase")
        #expect(model.isNoteRevealed)
        #expect(model.canContinue)
    }

    @Test("Notification payload is identifier-only and temporary questions are never payloads")
    func notificationPayloadIsIdentifierOnly() throws {
        let conversation = UUID()
        let run = UUID()
        let payload = try #require(UserQuestionNotificationPayload(
            requestID: "uq_request",
            questionID: "uq_request.q1",
            conversationID: conversation,
            runID: run,
            revision: 3
        ))
        let userInfo = payload.userInfo
        let root = try #require(userInfo[UserQuestionNotificationPayload.rootKey] as? [String: Any])
        #expect(root["request"] as? String == "uq_request")
        #expect(root["question"] as? String == "uq_request.q1")
        #expect(root["conversation"] as? String == conversation.uuidString)
        #expect(root["run"] as? String == run.uuidString)
        #expect(root["revision"] as? Int == 3)
        #expect(root["ephemeral"] as? Bool == false)
        #expect(Set(root.keys) == ["request", "question", "conversation", "run", "revision", "ephemeral"])
        #expect(UserQuestionNotificationPayload(userInfo: userInfo) == payload)

        var ephemeral = root
        ephemeral["ephemeral"] = true
        #expect(UserQuestionNotificationPayload(
            userInfo: [UserQuestionNotificationPayload.rootKey: ephemeral]
        ) == nil)
    }

    @Test("Custom single answer is independent of note permission, exclusive and never complete while blank")
    func customSingleAnswerIsExclusive() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "Choose", options: [.init(id: "a", label: "A")], allowsFreeText: false)
        ]))
        model.toggleOption("a")
        #expect(model.canContinue)
        model.selectCustomAnswer()
        #expect(model.isCustomSelected)
        #expect(model.selectedOptionIDs.isEmpty)
        #expect(model.currentAnswer?.customText == "")
        #expect(!model.canContinue)
        model.setCustomText("  My own answer  ")
        #expect(model.canContinue)
        #expect(model.currentAnswer?.customText == "My own answer")
        #expect(model.currentAnswer?.freeText == nil)
        model.toggleOption("a")
        #expect(!model.isCustomSelected)
        #expect(model.currentAnswer?.customText == nil)
        #expect(model.currentAnswer?.selectedOptionIDs == ["a"])
    }

    @Test("Multiple choices coexist with custom text but a selected empty custom answer remains incomplete")
    func customMultipleAnswerCoexists() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "Choose many", options: [.init(id: "a", label: "A")],
                  selection: .multiple, allowsFreeText: false)
        ]))
        model.toggleOption("a")
        model.setCustomText("Another choice")
        #expect(model.canContinue)
        #expect(model.currentAnswer?.selectedOptionIDs == ["a"])
        #expect(model.currentAnswer?.customText == "Another choice")
        model.setCustomText("   ")
        #expect(!model.canContinue)
        model.selectCustomAnswer()
        #expect(model.currentAnswer?.customText == nil)
        #expect(model.canContinue)
    }

    @Test("Custom answers and notes survive navigation and reconstruct from the persisted typed draft")
    func customDraftSurvivesNavigationAndReopen() throws {
        var state = try snapshot([
            .init(question: "First", options: [.init(id: "a", label: "A")], allowsFreeText: true),
            .init(question: "Second")
        ])
        let model = UserQuestionCardModel(snapshot: state)
        model.setCustomText("My choice")
        model.revealNote()
        model.setFreeText("Why I chose it")
        state.questions[0].draftAnswer = model.currentAnswer
        model.advance()
        model.setFreeText("Second answer")
        model.goBack()
        #expect(model.isCustomSelected)
        #expect(model.customText == "My choice")
        #expect(model.freeText == "Why I chose it")
        let restored = UserQuestionCardModel(snapshot: try JSONDecoder().decode(
            UserQuestionWaitingSnapshot.self, from: JSONEncoder().encode(state)))
        #expect(restored.currentAnswer?.customText == "My choice")
        #expect(restored.currentAnswer?.freeText == "Why I chose it")
        #expect(restored.canContinue)
        restored.setCustomText("")
        state.questions[0].draftAnswer = try restored.currentAnswer?.validated(for: state.questions[0], partial: true)
        let blank = UserQuestionCardModel(snapshot: state)
        #expect(blank.isCustomSelected)
        #expect(!blank.canContinue)
    }

    @Test("Reused dictation targets custom answers and notes separately and ignores a previous field")
    func customDictationKeepsNoteSeparate() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(question: "Which?", options: [.init(id: "a", label: "A")], allowsFreeText: true)
        ]))
        #expect(model.dictationField == .customText)
        model.applyDictatedText("My spoken answer")
        #expect(model.customText == "My spoken answer")
        #expect(model.freeText.isEmpty)
        model.revealNote()
        model.setDictatedText("late previous transcript", field: .customText)
        #expect(model.customText == "My spoken answer")
        model.applyDictatedText("A separate note")
        #expect(model.freeText == "A separate note")
        #expect(model.currentAnswer?.customText == "My spoken answer")
        #expect(model.canContinue)
    }

    @Test("A deadline question keeps its explicit deadline visible in the model")
    func deadlineMetadataIsPreserved() throws {
        let model = UserQuestionCardModel(snapshot: try snapshot([
            .init(
                question: "Time-boxed",
                options: [.init(id: "a", label: "A")],
                waitPolicy: .optionalDeadline,
                timeoutSeconds: 30
            )
        ], policy: .optionalDeadline))
        #expect(model.currentQuestion?.waitPolicy == .optionalDeadline)
        #expect(model.currentQuestion?.deadlineAt != nil)
    }
}
#endif

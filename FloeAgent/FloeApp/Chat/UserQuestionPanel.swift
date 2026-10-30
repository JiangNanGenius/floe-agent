#if canImport(UIKit)
import SwiftUI
import FloeModels

@MainActor
struct UserQuestionPanel: View {
    @ObservedObject var questions: AppUserQuestionIntegration
    let conversationID: UUID
    var maximumHeight: CGFloat? = nil

    var body: some View {
        Group {
            if let snapshot = questions.pending[conversationID] {
                ScrollView {
                    UserQuestionCardSurface(snapshot: snapshot, questions: questions)
                        .id(snapshot.requestID + ":" + snapshot.questions.map { String($0.revision) }.joined(separator: ":"))
                }
                .frame(maxHeight: maximumHeight)
            }
        }
        .task(id: conversationID) { await questions.restore(conversationID: conversationID) }
    }
}

@MainActor
private struct UserQuestionCardSurface: View {
    @ObservedObject var questions: AppUserQuestionIntegration
    @StateObject private var model: UserQuestionCardModel
    @EnvironmentObject private var voiceInput: VoiceInputController
    @Environment(\.continuousVoiceActive) private var continuousVoiceActive
    @State private var dictationBase = ""
    @State private var voiceTarget: String?
    @State private var preparation: Task<Void, Never>?

    init(snapshot: UserQuestionWaitingSnapshot, questions: AppUserQuestionIntegration) {
        self.questions = questions
        _model = StateObject(wrappedValue: UserQuestionCardModel(snapshot: snapshot))
    }

    var body: some View {
        UserQuestionCardView(
            model: model,
            onSubmit: { target, answer in
                stopDictation()
                model.markSubmitting()
                Task { @MainActor in
                    if await questions.center.submit(target: target, answer: answer) {
                        model.markSubmissionSucceeded()
                    } else {
                        model.markSubmissionFailed(String(localized: questions.center.errorMessage == nil
                            ? "user_question.card.answer_changed" : "user_question.card.retry_save"))
                    }
                }
            },
            onCancel: { _ in
                stopDictation()
                Task {
                    do { try await questions.coordinator.cancelRequest(requestID: model.snapshot.requestID) }
                    catch { model.markSubmissionFailed(String(localized: "user_question.card.retry_save")) }
                }
            },
            onRequestDictation: continuousVoiceActive ? nil : { target in beginDictation(target) }
        )
        .onAppear {
            model.onDraftChanged = { target, answer in
                Task { await questions.center.saveDraft(target: target, answer: answer) }
            }
        }
        .onChange(of: voiceInput.transcript) { _, text in
            guard let current = model.currentTarget,
                  questions.dictationQuestionID == current.questionID else { return }
            // Recognizers replace cumulative partials; never append each
            // partial to the previous partial or to the ordinary composer.
            model.setFreeText(dictationBase + (dictationBase.isEmpty || text.isEmpty ? "" : " ") + text)
        }
        .onChange(of: model.index) { _, _ in stopDictation() }
        .onDisappear {
            model.persistCurrentDraft()
            stopDictation()
        }
    }

    private func beginDictation(_ target: UserQuestionAnswerTarget) {
        if questions.dictationQuestionID == target.questionID,
           voiceInput.state.hasSession || voiceInput.state == .requestingPermission {
            voiceInput.stop()
            model.persistCurrentDraft()
            return
        }
        preparation?.cancel()
        questions.dictationQuestionID = target.questionID
        voiceTarget = target.questionID
        dictationBase = model.freeText
        preparation = Task { @MainActor in
            await voiceInput.stopAndWait()
            guard !Task.isCancelled, questions.dictationQuestionID == target.questionID,
                  model.currentTarget?.questionID == target.questionID else { return }
            voiceInput.requestStart()
        }
    }

    private func stopDictation() {
        preparation?.cancel()
        preparation = nil
        guard let voiceTarget, questions.dictationQuestionID == voiceTarget else { return }
        voiceInput.stop()
        questions.dictationQuestionID = nil
        self.voiceTarget = nil
    }
}
#endif

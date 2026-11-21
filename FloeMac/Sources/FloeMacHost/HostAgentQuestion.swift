// SPDX-License-Identifier: MPL-2.0
//
// Host projection of one durable user question plus the Mac workbench card.
//
// The card itself is the existing iPad `UserQuestionCardView` (shared,
// AppKit-guarded, added to the unified target by the coordinator); this
// file only binds it to the Mac workspace:
//   * `HostAgentQuestion` is the small Equatable projection the workspace
//     keeps per live run (durable snapshot + owner/run identities);
//   * `HostAgentQuestionCardView` owns one `UserQuestionCardModel` and
//     forwards submit/cancel to the workspace. Settled-answer history in
//     the transcript is coordinator-owned and lives outside this card.
// No answer, draft or receipt is stored here; the durable coordinator is the
// only writer.

import Foundation
import FloeModels
import FloeAgentRuntime
import FloeMacSelfCore
#if FLOE_UNIFIED_MAC
import SwiftUI
#endif

/// UI-shaped state for one live question card. Equatable so the workspace
/// can publish it without identity churn.
struct HostAgentQuestion: Equatable {
    let conversationID: UUID
    let runID: UUID
    let snapshot: UserQuestionWaitingSnapshot

    var requestID: String { snapshot.requestID }
    /// The question the card currently shows, if still pending.
    var currentQuestion: UserQuestion? { snapshot.currentQuestion }
    /// True when the model asked for a credential: the card must tell the
    /// person to keep credentials in Settings instead of typing them here.
    var isCredentialQuestion: Bool {
        currentQuestion?.answerSensitivity == .credential
    }
    /// Stable key for the pending card: any durable change (next question,
    /// external settle, cancel/expiry, revision bump) gets a fresh card.
    var cardIdentity: String {
        let current = currentQuestion.map { "\($0.questionID).\($0.revision)" } ?? "settled"
        return requestID + ":" + current
    }
}

/// The pending question card for the visible run.
#if FLOE_UNIFIED_MAC
struct HostAgentQuestionCardView: View {
    let question: HostAgentQuestion
    /// Recovery copy for a restored card (no live run); nil for live cards.
    let note: String?
    let submit: (UserQuestionAnswerTarget, UserQuestionAnswer) async -> Bool
    let cancel: (String) async -> Void
    let draftChanged: ((UserQuestionAnswerTarget, UserQuestionAnswer) -> Void)?

    @StateObject private var model: UserQuestionCardModel

    init(
        question: HostAgentQuestion,
        note: String? = nil,
        submit: @escaping (UserQuestionAnswerTarget, UserQuestionAnswer) async -> Bool,
        cancel: @escaping (String) async -> Void,
        draftChanged: ((UserQuestionAnswerTarget, UserQuestionAnswer) -> Void)? = nil
    ) {
        self.question = question
        self.note = note
        self.submit = submit
        self.cancel = cancel
        self.draftChanged = draftChanged
        _model = StateObject(wrappedValue: UserQuestionCardModel(snapshot: question.snapshot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if question.isCredentialQuestion {
                credentialGuidance
            }
            UserQuestionCardView(
                model: model,
                onSubmit: { target, answer in
                    model.markSubmitting()
                    Task {
                        let accepted = await submit(target, answer)
                        if accepted {
                            model.markSubmissionSucceeded()
                            model.advanceAfterAcceptedAnswer()
                        } else {
                            model.markSubmissionFailed(submissionFailureText)
                        }
                    }
                },
                onCancel: { target in
                    Task { await cancel(target.requestID) }
                },
                onRequestDictation: nil
            )
            .onAppear {
                if let draftChanged { model.onDraftChanged = draftChanged }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("user_question.restored.note")
            }
        }
    }

    private var credentialGuidance: some View {
        Label(String(localized: "mac.question.credentials.settings"),
              systemImage: "key.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("user_question.credentials.settings")
    }

    private var submissionFailureText: String {
        question.isCredentialQuestion
            ? String(localized: "mac.question.credentials.retry")
            : String(localized: "user_question.card.submit_failed")
    }
}
#endif

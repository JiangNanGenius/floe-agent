// FloeApp — inline user-question card.
//
// This is a question surface, not an approval card. It renders exactly one
// question at a time, keeps each question's draft while the person moves
// between them, and never sends a chat message or settles tool state itself.
// The owning center/runtime accepts the answer once through the durable
// coordinator; the card only produces a typed target + answer.
//
// Voice reuse: the card takes a dictation callback supplied by the primary
// agent. The existing ThreadComposer VoiceInputController remains the only
// recognizer; this view never starts its own ASR. On a transcript the primary
// calls `model.applyDictatedText(_:)`.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Combine
import FloeModels
import FloeCore

@MainActor
public final class UserQuestionCardModel: ObservableObject {
    public let snapshot: UserQuestionWaitingSnapshot

    @Published public private(set) var index: Int
    @Published public private(set) var selectedOptionIDs: Set<String>
    @Published public private(set) var freeText: String
    @Published public private(set) var isNoteRevealed: Bool
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var submissionError: String?

    /// Called when the card moves between questions, disappears or explicitly
    /// saves. The center may debounce the durable write; the card itself does
    /// not touch storage.
    public var onDraftChanged: ((UserQuestionAnswerTarget, UserQuestionAnswer) -> Void)?

    private struct Draft: Sendable {
        var selectedOptionIDs: Set<String>
        var freeText: String
        var isNoteRevealed: Bool
    }

    private var drafts: [String: Draft] = [:]
    /// Questions already accepted by the host. Local navigation skips them,
    /// so Back never offers a settled answer for a second CAS submit.
    private var settledQuestionIDs: Set<String> = []

    public init(snapshot: UserQuestionWaitingSnapshot, startingAt index: Int? = nil) {
        self.snapshot = snapshot
        let firstPending = snapshot.questions.firstIndex(where: \.isPending) ?? 0
        let initial = min(max(0, index ?? firstPending), max(0, snapshot.questions.count - 1))
        self.index = initial
        let question = snapshot.questions.indices.contains(initial) ? snapshot.questions[initial] : nil
        let draft = question.flatMap { $0.draftAnswer }
        self.selectedOptionIDs = Set(draft?.selectedOptionIDs ?? [])
        self.freeText = draft?.freeText ?? ""
        self.isNoteRevealed = !(draft?.freeText ?? "").isEmpty
        if let question {
            drafts[question.questionID] = Draft(
                selectedOptionIDs: Set(draft?.selectedOptionIDs ?? []),
                freeText: draft?.freeText ?? "",
                isNoteRevealed: !(draft?.freeText ?? "").isEmpty
            )
        }
        settledQuestionIDs = Set(snapshot.questions.filter { $0.status.isSettled }.map(\.questionID))
    }

    public var questions: [UserQuestion] { snapshot.questions }
    public var questionCount: Int { snapshot.questions.count }
    public var currentQuestion: UserQuestion? {
        snapshot.questions.indices.contains(index) ? snapshot.questions[index] : nil
    }
    public var currentTarget: UserQuestionAnswerTarget? {
        currentQuestion.map(snapshot.target(for:))
    }
    /// True when no unsettled question follows the current one. A host
    /// refresh may include already-answered questions before the next pending
    /// one; those never turn the business-last question into a "Continue".
    public var isLastQuestion: Bool { nextUnsettledIndex(after: index) == nil }
    public var isCurrentSettled: Bool {
        currentQuestion.map { settledQuestionIDs.contains($0.questionID) } ?? false
    }
    public var progress: (current: Int, total: Int) { (index + 1, max(1, questionCount)) }

    public var currentAnswer: UserQuestionAnswer? {
        guard currentQuestion != nil else { return nil }
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserQuestionAnswer(
            selectedOptionIDs: selectedOptionIDs.sorted(),
            freeText: text.isEmpty ? nil : text
        )
    }

    /// The exact action a Continue/Submit tap must take. It is always a
    /// submission for the current question, never a local skip/advance.
    public func continueAction() -> UserQuestionCardAction? {
        guard canContinue, let target = currentTarget, let answer = currentAnswer else { return nil }
        return .submit(target, answer)
    }

    public var canContinue: Bool {
        guard !isSubmitting, !isCurrentSettled, let question = currentQuestion else { return false }
        guard let answer = currentAnswer else { return false }
        if answer.isEmpty { return false }
        // Continue now submits the CURRENT question; every question must be
        // a complete answer, not an intermediate draft.
        return (try? answer.validated(for: question, partial: false)) != nil
    }

    public var isTextQuestion: Bool { currentQuestion?.isTextOnly == true }

    /// Single-select replaces; multi-select toggles. No option can be selected
    /// twice, and a text-only question never shows options.
    public func toggleOption(_ optionID: String) {
        guard let question = currentQuestion, !question.isTextOnly else { return }
        if question.selectionMode == .single {
            selectedOptionIDs = [optionID]
        } else if selectedOptionIDs.contains(optionID) {
            selectedOptionIDs.remove(optionID)
        } else {
            selectedOptionIDs.insert(optionID)
        }
        persistCurrentDraft()
    }

    public func isSelected(_ optionID: String) -> Bool {
        selectedOptionIDs.contains(optionID)
    }

    public func setFreeText(_ text: String) {
        freeText = String(text.prefix(UserQuestionRequest.maximumFreeTextCharacters))
        if !freeText.isEmpty { isNoteRevealed = true }
    }

    public func revealNote() {
        isNoteRevealed = true
    }

    public func hideNote() {
        isNoteRevealed = false
        freeText = ""
        persistCurrentDraft()
    }

    public func applyDictatedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        freeText = existing.isEmpty ? trimmed : existing + " " + trimmed
        freeText = String(freeText.prefix(UserQuestionRequest.maximumFreeTextCharacters))
        isNoteRevealed = true
        persistCurrentDraft()
    }

    /// Persists the current card state without settling the question.
    public func persistCurrentDraft() {
        guard let target = currentTarget, let answer = currentAnswer else { return }
        guard let question = currentQuestion else { return }
        guard (try? answer.validated(for: question, partial: true)) != nil else { return }
        drafts[question.questionID] = Draft(
            selectedOptionIDs: selectedOptionIDs,
            freeText: freeText,
            isNoteRevealed: isNoteRevealed
        )
        onDraftChanged?(target, answer)
    }

    /// Moves to the next pending question, carrying the draft forward. The
    /// caller (center) is responsible for accepting the answer when the last
    /// question is submitted; this method never settles anything itself.
    public func advance() {
        guard let next = nextUnsettledIndex(after: index) else { return }
        persistCurrentDraft()
        index = next
        loadCurrentDraft()
    }

    /// Called by the card after the host accepted the current answer through
    /// the CAS coordinator. It never persists a draft for a settled question
    /// and never lets Back return to it.
    public func advanceAfterAcceptedAnswer() {
        if let question = currentQuestion {
            settledQuestionIDs.insert(question.questionID)
            drafts.removeValue(forKey: question.questionID)
        }
        guard let next = nextUnsettledIndex(after: index) else { return }
        index = next
        loadCurrentDraft()
    }

    public func goBack() {
        guard index > 0 else { return }
        var candidate = index - 1
        while candidate >= 0 {
            if let question = snapshot.questions.indices.contains(candidate) ? snapshot.questions[candidate] : nil,
               !settledQuestionIDs.contains(question.questionID) {
                persistCurrentDraft()
                index = candidate
                loadCurrentDraft()
                return
            }
            candidate -= 1
        }
    }

    private func nextUnsettledIndex(after current: Int) -> Int? {
        guard current + 1 < snapshot.questions.count else { return nil }
        for candidate in (current + 1)..<snapshot.questions.count {
            let question = snapshot.questions[candidate]
            if !settledQuestionIDs.contains(question.questionID) { return candidate }
        }
        return nil
    }

    public func markSubmitting() {
        isSubmitting = true
        submissionError = nil
    }

    public func markSubmissionSucceeded() {
        isSubmitting = false
        submissionError = nil
        if let question = currentQuestion {
            drafts.removeValue(forKey: question.questionID)
            settledQuestionIDs.insert(question.questionID)
        }
    }

    public func markSubmissionFailed(_ message: String) {
        isSubmitting = false
        submissionError = message
    }

    /// Replaces the draft for a question that was answered elsewhere (voice
    /// or notification) without creating a second answer.
    public func markAnswered(questionID: String) {
        drafts.removeValue(forKey: questionID)
    }

    private func loadCurrentDraft() {
        guard let question = currentQuestion else { return }
        let draft = drafts[question.questionID] ?? question.draftAnswer.map {
            Draft(
                selectedOptionIDs: Set($0.selectedOptionIDs),
                freeText: $0.freeText ?? "",
                isNoteRevealed: !($0.freeText ?? "").isEmpty
            )
        }
        selectedOptionIDs = draft?.selectedOptionIDs ?? []
        freeText = draft?.freeText ?? ""
        isNoteRevealed = draft?.isNoteRevealed ?? false
    }
}

/// The single action a Continue/Submit tap produces: a complete answer for
/// the CURRENT question, sent through the host's CAS coordinator. It never
/// advances locally, so an earlier draft cannot remain pending.
public enum UserQuestionCardAction: Equatable, Sendable {
    case submit(UserQuestionAnswerTarget, UserQuestionAnswer)
}

public struct UserQuestionCardView: View {
    @ObservedObject private var model: UserQuestionCardModel
    private let onSubmit: (UserQuestionAnswerTarget, UserQuestionAnswer) -> Void
    private let onCancel: (UserQuestionAnswerTarget) -> Void
    private let onRequestDictation: ((UserQuestionAnswerTarget) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: UserQuestionCardModel,
        onSubmit: @escaping (UserQuestionAnswerTarget, UserQuestionAnswer) -> Void,
        onCancel: @escaping (UserQuestionAnswerTarget) -> Void,
        onRequestDictation: ((UserQuestionAnswerTarget) -> Void)? = nil
    ) {
        self.model = model
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onRequestDictation = onRequestDictation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let question = model.currentQuestion {
                Text(question.text)
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if question.isTextOnly == false {
                    optionList(question)
                }
                freeTextArea(question)
                if let deadline = question.deadlineAt {
                    DeadlineCaption(deadline: deadline)
                }
                if let error = model.submissionError {
                    Text(error)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
                footer(question)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(FloeTheme.pending.opacity(0.55), lineWidth: 1)
        }
        .animation(FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: model.index)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user_question.card")
        .accessibilityLabel(Text("user_question.card.title"))
        .onDisappear { model.persistCurrentDraft() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("user_question.card.title")
                .font(FloeTheme.Typography.section)
            Spacer()
            if model.questionCount > 1 {
                Text("user_question.card.progress \(model.progress.current) \(model.progress.total)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func optionList(_ question: UserQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(question.options) { option in
                Button {
                    model.toggleOption(option.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectionSymbol(for: option.id, question: question))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(model.isSelected(option.id) ? FloeTheme.primary : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                                .font(FloeTheme.Typography.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if let detail = option.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        model.isSelected(option.id)
                            ? FloeTheme.primary.opacity(0.12)
                            : FloeTheme.readingSurface,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("user_question.option.\(option.id)")
                .accessibilityAddTraits(model.isSelected(option.id) ? .isSelected : [])
            }
        }
    }

    private func selectionSymbol(for optionID: String, question: UserQuestion) -> String {
        let selected = model.isSelected(optionID)
        if question.selectionMode == .multiple {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    @ViewBuilder
    private func freeTextArea(_ question: UserQuestion) -> some View {
        if question.isTextOnly {
            noteField(question: question)
        } else if question.allowsFreeText {
            if model.isNoteRevealed {
                noteField(question: question)
            } else {
                Button {
                    model.revealNote()
                } label: {
                    Label("user_question.card.add_note", systemImage: "text.bubble")
                        .font(FloeTheme.Typography.metadata.weight(.semibold))
                        .foregroundStyle(FloeTheme.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func noteField(question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("user_question.card.note")
                    .font(FloeTheme.Typography.metadata.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if question.isTextOnly == false {
                    Button("user_question.card.remove_note") {
                        model.hideNote()
                    }
                    .font(FloeTheme.Typography.metadata)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            TextField("user_question.card.note_placeholder", text: Binding(
                get: { model.freeText },
                set: { model.setFreeText($0) }
            ), axis: .vertical)
            .font(FloeTheme.Typography.body)
            .lineLimit(2...5)
            .padding(9)
            .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("user_question.note")
        }
    }

    private func submitCurrentAnswer() {
        // Every Continue/Submit tap is a complete CAS submission for the
        // CURRENT question. The host refreshes the snapshot and presents the
        // next pending question; the card never advances an unsubmitted
        // draft past its answer.
        guard let action = model.continueAction() else { return }
        switch action {
        case .submit(let target, let answer):
            model.markSubmitting()
            onSubmit(target, answer)
        }
    }

    private func footer(_ question: UserQuestion) -> some View {
        HStack(spacing: 10) {
            Button("user_question.card.cancel", role: .cancel) {
                if let target = model.currentTarget { onCancel(target) }
            }
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .accessibilityIdentifier("user_question.cancel")

            Spacer()

            if let onRequestDictation, let target = model.currentTarget,
               question.isTextOnly || question.allowsFreeText {
                Button {
                    onRequestDictation(target)
                } label: {
                    Image(systemName: "mic")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FloeTheme.primary)
                .accessibilityLabel(Text("user_question.card.dictate"))
                .accessibilityIdentifier("user_question.dictate")
            }

            if model.index > 0 {
                Button("user_question.card.back") {
                    model.goBack()
                }
                .buttonStyle(.plain)
                .font(FloeTheme.Typography.metadata.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Button(model.isLastQuestion ? "user_question.card.submit" : "user_question.card.continue") {
                submitCurrentAnswer()
            }
            .font(FloeTheme.Typography.metadata.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .disabled(!model.canContinue || model.isSubmitting)
            .accessibilityIdentifier("user_question.continue")
        }
    }
}

private struct DeadlineCaption: View {
    let deadline: Date

    var body: some View {
        Label {
            Text("user_question.card.deadline \(deadline.formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: "timer")
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("user_question.deadline")
    }
}
#endif

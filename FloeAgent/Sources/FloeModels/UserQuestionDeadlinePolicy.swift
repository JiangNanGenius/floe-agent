import Foundation

extension UserQuestion {
    /// Only explicitly optional policies can own a persisted deadline.
    /// Legacy optionalContinue with no fallback remains untimed.
    public var hasPendingOptionalDeadline: Bool {
        guard isPending, deadlineAt != nil else { return false }
        switch waitPolicy {
        case .required: return false
        case .optionalDeadline: return true
        case .optionalContinue: return fallback != nil && answerSensitivity == .ordinary
        }
    }

    /// The existing next-turn delivery queue may carry a human answer or the
    /// exact declared fallback. Expiry is never reclassified as a human answer.
    public var hasUndeliveredOptionalAnswer: Bool {
        guard waitPolicy == .optionalContinue, deliveredAt == nil, answer != nil else { return false }
        if status == .answered && answerSource == .human { return true }
        guard status == .expired, answerSource == .deadlineDefault,
              answerSensitivity == .ordinary, let fallback else { return false }
        let expected = try? UserQuestionAnswer(selectedOptionIDs: fallback.selectedOptionIDs,
            freeText: fallback.freeText).validated(for: self, partial: false)
        return expected != nil && answer == expected
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// Exact-run user-question commands. The UI echoes the conversation and run
// identities it observed plus the durable request/question identities and the
// card's expected CAS revision. The session validates owner/run against its
// immutable identity and the durable store re-validates request/question/run
// binding plus the optimistic-concurrency revision before any answer settles.

import Foundation
import FloeModels

/// One human answer to one pending question. `answer` is the normalized
/// person-authored value only; it grants no tool or approval authority.
public struct FloeMacSelfQuestionAnswerCommand: Sendable, Hashable {
    /// Owning conversation (task). Must match the admitted session.
    public let conversationID: UUID
    /// Exact admitted run. Must match the admitted session.
    public let runID: UUID
    /// Durable question request id (`uq_…`).
    public let requestID: String
    /// Durable question id (`<requestID>.<localID>`).
    public let questionID: String
    /// Revision the UI observed. The store applies it as a CAS check.
    public let expectedRevision: Int
    public let answer: UserQuestionAnswer

    public init(
        conversationID: UUID,
        runID: UUID,
        requestID: String,
        questionID: String,
        expectedRevision: Int,
        answer: UserQuestionAnswer
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.requestID = requestID
        self.questionID = questionID
        self.expectedRevision = expectedRevision
        self.answer = answer
    }

    /// Builds the exact durable target the store settles.
    public var target: UserQuestionAnswerTarget {
        UserQuestionAnswerTarget(
            requestID: requestID,
            questionID: questionID,
            conversationID: conversationID,
            runID: runID,
            expectedRevision: expectedRevision
        )
    }
}

public enum FloeMacSelfQuestionRejection: String, Sendable, Hashable, CaseIterable {
    case conversationMismatch
    case runMismatch
    case toolsDisabled
    case sessionEnded
    case staleQuestion
    case invalidAnswer
}

public enum FloeMacSelfQuestionResolution: Sendable, Hashable {
    /// The durable store accepted this exact answer; the receipt carries the
    /// settled question state.
    case accepted(UserQuestionAnswerReceipt)
    /// The question no longer blocks (already settled by an earlier tap, a
    /// cancel, an expiry or a terminal fence). The original receipt is
    /// returned when available so the UI can refresh without re-answering.
    case notPending(UserQuestionAnswerReceipt?)
    case rejected(FloeMacSelfQuestionRejection)
}

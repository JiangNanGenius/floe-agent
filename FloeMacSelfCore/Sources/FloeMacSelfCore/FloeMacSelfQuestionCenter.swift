// SPDX-License-Identifier: MPL-2.0
//
// FloeMacSelfQuestionCenter — the one Mac owner of the existing durable
// user-question store and wait coordinator.
//
// The center adds no second persistence model and no second wait semantics:
// `UserQuestionStore` (SQLite through the host database) remains the only
// writer and `UserQuestionCoordinator` remains the only owner of the
// ask/wait/resume boundary. The center only:
//   * binds both to the host-owned DatabaseManager for the runtime's
//     lifetime;
//   * fans coordinator events out to registered projections (the runtime's
//     live-wait projection and the host UI), preserving order;
//   * exposes reads, the human-answer surface, per-request cancel and the
//     passive restore used when the host re-opens a conversation.
//
// No provider socket, audio unit or UI object is owned here.

import Foundation
import FloeCore
import FloeSecurity
import FloeModels
import FloePersistence
import FloeAgentRuntime

public actor FloeMacSelfQuestionCenter {
    /// The one durable question store, bound to the host database.
    public let store: UserQuestionStore
    /// The one wait coordinator. Also the runtime recovery seam
    /// (`UserQuestionRuntimeRecovery`) wired into every session.
    public let coordinator: UserQuestionCoordinator

    private let events: QuestionEvents

    init(database: DatabaseManager) {
        let store = UserQuestionStore(database: database)
        let events = QuestionEvents()
        self.store = store
        self.events = events
        self.coordinator = UserQuestionCoordinator(store: store, eventHandler: { event in
            await events.publish(event)
        }, answerNormalizer: { answer, question, _ in
            for text in [answer.customText, answer.freeText].compactMap({ $0 }) where !text.isEmpty {
                guard question.answerSensitivity != .credential, SecretIngressScanner.scan(text).captures.isEmpty else {
                    throw UserQuestionError.invalidRequest("Use credential settings for secrets.")
                }
            }
            return answer
        })
    }

    @discardableResult
    public func subscribeEvents(
        _ handler: @escaping @Sendable (UserQuestionEvent) async -> Void
    ) async -> UUID {
        await events.subscribe(handler)
    }

    public func unsubscribeEvents(_ token: UUID) async {
        await events.unsubscribe(token)
    }

    // MARK: - Reads (durable truth only)

    /// The pending question currently blocking or optionally waiting for this
    /// conversation, if any. Re-arming persisted deadlines is the existing
    /// coordinator behavior; no new scheduling lives here.
    public func pendingSnapshot(conversationID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        try await coordinator.pendingSnapshot(conversationID: conversationID)
    }

    /// Truthful pending question for one exact run (restart/UI recovery).
    public func pendingSnapshot(runID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        try await coordinator.pendingSnapshot(runID: runID)
    }

    public func snapshots(
        conversationID: UUID,
        includeSettled: Bool = false
    ) async throws -> [UserQuestionWaitingSnapshot] {
        try await coordinator.snapshots(conversationID: conversationID, includeSettled: includeSettled)
    }

    /// Durable read-only peek of optionalContinue answers awaiting delivery.
    public func pendingDeliveries(conversationID: UUID) async throws -> [UserQuestionAnswerDelivery] {
        try await coordinator.pendingDeliveries(conversationID: conversationID)
    }

    // MARK: - Human answer surface

    /// Settles one question through the store's CAS transaction. A stale
    /// revision, a duplicate tap, a settled question or a question owned by
    /// another run/task never overwrites durable state; the store returns the
    /// canonical receipt/error.
    public func submitHumanAnswer(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        try await coordinator.submitHumanAnswer(target: target, answer: answer)
    }

    /// Persists card progress without settling (note/selection edits).
    @discardableResult
    public func saveDraft(
        target: UserQuestionAnswerTarget,
        draft: UserQuestionAnswer
    ) async throws -> UserQuestionDraftReceipt {
        try await coordinator.saveDraft(target: target, draft: draft)
    }

    /// Explicitly cancels one question request. Pending questions become
    /// cancelled with no answer body; a required wait returns a cancelled
    /// tool receipt to the parked run.
    public func cancelRequest(requestID: String) async throws {
        try await coordinator.cancelRequest(requestID: requestID)
    }

    // MARK: - Passive restore

    /// Re-emits the current pending snapshot for a re-opened conversation so
    /// the card reappears without resuming any run. This is the whole
    /// "passive restored transcript" behavior: the question stays in the
    /// durable store and is projected again; no provider call and no runtime
    /// resume is triggered here.
    public func restore(conversationID: UUID) async {
        guard let snapshot = try? await coordinator.pendingSnapshot(conversationID: conversationID) else {
            return
        }
        guard snapshot.currentQuestion != nil else { return }
        await events.publish(.presented(snapshot))
    }
}

/// Delivers each event to the runtime and host in their registration order.
private actor QuestionEvents {
    typealias Handler = @Sendable (UserQuestionEvent) async -> Void
    private var subscribers: [(UUID, Handler)] = []

    func subscribe(_ handler: @escaping Handler) -> UUID {
        let token = UUID()
        subscribers.append((token, handler))
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeAll { $0.0 == token }
    }

    func publish(_ event: UserQuestionEvent) async {
        for (_, handler) in subscribers { await handler(event) }
    }
}

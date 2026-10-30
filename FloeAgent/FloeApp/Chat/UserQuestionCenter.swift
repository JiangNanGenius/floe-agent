// FloeApp — owner of the inline question card's live state.
//
// The center is a thin main-actor projection over the runtime coordinator.
// It never stores answers itself: every submit/draft/cancel goes through
// `UserQuestionAnswering`, whose CAS receipt is the authority. It also owns
// the notification presentation policy: temporary questions never schedule a
// notification, and a denied notification permission never blocks the
// foreground card.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine
import FloeCore
import FloeModels
import FloeAgentRuntime

@MainActor
public final class UserQuestionCenter: ObservableObject {
    @Published public private(set) var activeSnapshot: UserQuestionWaitingSnapshot?
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var errorMessage: String?

    /// App composition supplies the concrete coordinator (durable or
    /// RAM-backed for a temporary conversation).
    public var answering: (any UserQuestionAnswering)?
    public var notificationBridge: UserQuestionNotificationBridge?
    /// Existing settings/permission decision. The default is deliberately
    /// false: notifications are opt-in, never assumed.
    public var canPresentNotifications: () -> Bool = { false }
    /// Existing deep-link/navigation owner. The bridge calls this only for
    /// an explicit open, never for an inline answer.
    public var onOpenNotification: ((UserQuestionNotificationPayload) -> Void)?
    /// Advisory signal: a previously optional answer arrived. The primary
    /// must call `pendingDeliveries(conversationID:)` at the next safe
    /// provider turn, commit with the stable delivery id, then explicitly
    /// acknowledge the exact questions.
    public var onAnswerAvailable: ((UserQuestionAnswerDelivery) -> Void)?

    private var scheduledNotificationQuestionID: String?
    private var scheduledNotificationRequestID: String?

    public init() {}

    // MARK: - Event intake

    public func handle(_ event: UserQuestionEvent) {
        switch event {
        case .presented(let snapshot):
            present(snapshot)
        case .settled(let snapshot):
            if snapshot.currentQuestion != nil {
                present(snapshot)
            } else if activeSnapshot?.requestID == snapshot.requestID {
                activeSnapshot = nil
                scheduledNotificationQuestionID = nil
                scheduledNotificationRequestID = nil
            }
        case .answerAvailable(let delivery):
            onAnswerAvailable?(delivery)
        }
    }

    public func present(_ snapshot: UserQuestionWaitingSnapshot) {
        activeSnapshot = snapshot
        errorMessage = nil
        scheduleNotificationIfAllowed(snapshot)
    }

    /// Restores a pending question after an ordinary restart. The durable
    /// store is the source; the card and notification are projections.
    public func presentPending(conversationID: UUID) async {
        guard let answering else { return }
        do {
            if let snapshot = try await answering.pendingSnapshot(conversationID: conversationID) {
                present(snapshot)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Answers

    /// Submits exactly one question answer. The card remains visible until the
    /// coordinator's receipt says the CAS accepted it; a duplicate tap is
    /// rejected by the store, never turned into a second settlement.
    @discardableResult
    public func submit(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async -> Bool {
        guard let answering, !isSubmitting else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let receipt = try await answering.submitHumanAnswer(target: target, answer: answer)
            guard receipt.accepted else {
                // Already settled by another surface (notification or voice).
                // There is nothing for this card to resubmit; refresh and let
                // it advance/dismiss instead of showing a dead-end error.
                await refresh(conversationID: target.conversationID)
                return receipt.alreadySettled
            }
            await refresh(conversationID: target.conversationID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func saveDraft(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async {
        guard let answering else { return }
        do {
            _ = try await answering.saveDraft(target: target, draft: answer)
        } catch UserQuestionError.staleRevision {
            // Another surface answered/changed this question. Refresh rather
            // than writing a stale draft over the newer state.
            await refresh(conversationID: target.conversationID)
        } catch {
            // Draft persistence is not allowed to block the card; the next
            // answer still CAS-validates against the store.
        }
    }

    public func cancelActive() async {
        guard let answering, let requestID = activeSnapshot?.requestID else { return }
        do {
            try await answering.cancelRequest(requestID: requestID)
        } catch {
            errorMessage = error.localizedDescription
        }
        activeSnapshot = nil
        scheduledNotificationQuestionID = nil
        scheduledNotificationRequestID = nil
    }

    /// Durable read-only peek for optionalContinue answers. The answer stays
    /// recoverable across relaunch until `acknowledgeDeliveries` is called
    /// AFTER the primary has committed it to the existing durable input queue
    /// using the stable delivery id. The `.answerAvailable` event is only a
    /// wake signal, never the sole copy of the data.
    public func pendingDeliveries(conversationID: UUID) async -> [UserQuestionAnswerDelivery] {
        guard let answering else { return [] }
        do {
            return try await answering.pendingDeliveries(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Acknowledge the exact questions after the caller's durable queue commit
    /// succeeded. Idempotent; a crash before this call simply leaves the same
    /// stable delivery available for the queue's own deduplication.
    public func acknowledgeDeliveries(questionIDs: [String]) async {
        guard let answering else { return }
        do {
            try await answering.acknowledgeDeliveries(questionIDs: questionIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Notification

    public func openNotification(_ payload: UserQuestionNotificationPayload) {
        onOpenNotification?(payload)
    }

    private func refresh(conversationID: UUID) async {
        guard let answering else { return }
        do {
            if let snapshot = try await answering.pendingSnapshot(conversationID: conversationID) {
                present(snapshot)
            } else if activeSnapshot?.conversationID == conversationID {
                activeSnapshot = nil
                scheduledNotificationQuestionID = nil
                scheduledNotificationRequestID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleNotificationIfAllowed(_ snapshot: UserQuestionWaitingSnapshot) {
        guard !snapshot.isEphemeral,
              canPresentNotifications(),
              let question = snapshot.currentQuestion,
              let bridge = notificationBridge else { return }
        // Re-scheduling the same unanswered question would replace its system
        // notification; do it only when the request/question identity changed.
        guard scheduledNotificationQuestionID != question.questionID
            || scheduledNotificationRequestID != snapshot.requestID else { return }
        scheduledNotificationQuestionID = question.questionID
        scheduledNotificationRequestID = snapshot.requestID
        Task {
            await bridge.present(snapshot: snapshot, question: question, canPresentAlert: true)
        }
    }
}
#endif

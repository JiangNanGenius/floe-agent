// FloeApp — notification response bridge for task-bound user questions.
//
// This is a feature-specific adapter, not a second notification router and
// not a second answer store. It registers a category for the current
// question, accepts an authenticated text or option response, persists the
// answer through the ONE UserQuestionNotificationAnswering seam, and only then
// calls the system completion handler. It never waits for a model response
// and never requires a mounted foreground conversation for an inline answer.
//
// Payload policy: userInfo carries identifiers only (request, question,
// conversation, run, revision). Question text and answers are never placed in
// the payload. Temporary questions are RAM-only and are never scheduled.

#if canImport(UIKit)
import Foundation
import UIKit
import UserNotifications
import FloeCore
import FloeModels

/// Bounded, identifier-only notification payload.
public struct UserQuestionNotificationPayload: Sendable, Hashable {
    public static let rootKey = "floe.userQuestion"
    public static let ephemeralKey = "ephemeral"

    public var requestID: String
    public var questionID: String
    public var conversationID: UUID
    public var runID: UUID
    public var revision: Int

    public init?(
        requestID: String,
        questionID: String,
        conversationID: UUID,
        runID: UUID,
        revision: Int
    ) {
        guard (1...128).contains(requestID.count),
              (1...160).contains(questionID.count),
              revision > 0, revision <= 1_000_000 else { return nil }
        self.requestID = requestID
        self.questionID = questionID
        self.conversationID = conversationID
        self.runID = runID
        self.revision = revision
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let root = userInfo[Self.rootKey] as? [String: Any] else { return nil }
        if root[Self.ephemeralKey] as? Bool == true { return nil }
        guard let request = root["request"] as? String,
              let question = root["question"] as? String,
              let conversation = root["conversation"] as? String,
              let run = root["run"] as? String,
              let revision = root["revision"] as? Int,
              let conversationID = UUID(uuidString: conversation),
              let runID = UUID(uuidString: run) else { return nil }
        self.init(
            requestID: request,
            questionID: question,
            conversationID: conversationID,
            runID: runID,
            revision: revision
        )
    }

    /// Identifier-only payload. Never add question text, option labels or an
    /// answer body here.
    public var userInfo: [AnyHashable: Any] {
        [
            Self.rootKey: [
                "request": requestID,
                "question": questionID,
                "conversation": conversationID.uuidString,
                "run": runID.uuidString,
                "revision": revision,
                Self.ephemeralKey: false,
            ],
        ]
    }

    public var notificationIdentifier: String {
        "uq." + String(FloeDigest.sha256Hex(Data("\(requestID)\u{1f}\(questionID)".utf8)).prefix(32))
    }

    public var categoryIdentifier: String {
        "uq.category." + String(FloeDigest.sha256Hex(Data(questionID.utf8)).prefix(24))
    }
}

/// Exactly-once delivery of the system completion handler. A second attempt
/// is refused and only identifier-free diagnostics are recorded.
private final class UserQuestionNotificationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func finish() {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        guard let handler else { return }
        handler()
    }
}

// UserNotifications returns immutable category/action snapshots. This narrow
// value wrapper only transfers that read-only Foundation collection; mutable
// notification content and response objects never cross this boundary.
private struct UserQuestionNotificationCategories: @unchecked Sendable {
    let values: Set<UNNotificationCategory>
}

public enum UserQuestionNotificationAction: Sendable, Equatable {
    case text(String)
    case option(String)
    case open
    case dismiss
}

public struct UserQuestionNotificationResponse: Sendable, Equatable {
    public var payload: UserQuestionNotificationPayload
    public var action: UserQuestionNotificationAction

    public init(payload: UserQuestionNotificationPayload, action: UserQuestionNotificationAction) {
        self.payload = payload
        self.action = action
    }
}

@MainActor
public final class UserQuestionNotificationBridge {
    public nonisolated static let textActionIdentifier = "uq.answer.text"
    public nonisolated static let optionActionPrefix = "uq.answer.option."

    private let center: UNUserNotificationCenter
    private var registeredCategories: [String: UNNotificationCategory] = [:]
    private var retiredCategoryIDs: Set<String> = []
    private var presentations: [String: (generation: UUID, payload: UserQuestionNotificationPayload)] = [:]
    private let logger = FloeLogger(category: .app)

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Registers a category for exactly the current question. Returning to a
    /// later question installs its own category; old categories are retained
    /// only while the system still has their notification, so the set stays
    /// bounded by the questions actually presented.
    public func present(
        snapshot: UserQuestionWaitingSnapshot,
        question: UserQuestion,
        canPresentAlert: Bool
    ) async {
        guard canPresentAlert, !snapshot.isEphemeral, question.isPending else { return }
        guard let payload = UserQuestionNotificationPayload(
            requestID: snapshot.requestID,
            questionID: question.questionID,
            conversationID: snapshot.conversationID,
            runID: snapshot.runID,
            revision: question.revision
        ) else { return }

        let generation = UUID()
        if let previous = presentations[snapshot.requestID]?.payload,
           previous.questionID != question.questionID {
            center.removeDeliveredNotifications(withIdentifiers: [previous.notificationIdentifier])
            center.removePendingNotificationRequests(withIdentifiers: [previous.notificationIdentifier])
            registeredCategories[previous.categoryIdentifier] = nil
            retiredCategoryIDs.insert(previous.categoryIdentifier)
        }
        presentations[snapshot.requestID] = (generation, payload)

        let category = makeCategory(for: question, payload: payload)
        registeredCategories[category.identifier] = category
        let existing: UserQuestionNotificationCategories = await withCheckedContinuation { continuation in
            center.getNotificationCategories { categories in
                continuation.resume(returning: UserQuestionNotificationCategories(values: categories))
            }
        }
        guard presentations[snapshot.requestID]?.generation == generation else { return }
        // Several conversations may register questions across the await.
        // Merge the current owned categories, not an earlier single category.
        center.setNotificationCategories(Set(existing.values.filter {
            !retiredCategoryIDs.contains($0.identifier)
        }).union(registeredCategories.values))
        retiredCategoryIDs.removeAll()

        let content = UNMutableNotificationContent()
        content.title = FloeL10n.l("user_question.notification.title")
        content.body = question.text
        content.sound = .default
        content.categoryIdentifier = category.identifier
        content.threadIdentifier = "uq.\(snapshot.conversationID.uuidString)"
        content.userInfo = payload.userInfo

        let request = UNNotificationRequest(
            identifier: payload.notificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            if presentations[snapshot.requestID]?.generation != generation,
               presentations[snapshot.requestID]?.payload.questionID != question.questionID {
                center.removeDeliveredNotifications(withIdentifiers: [payload.notificationIdentifier])
                center.removePendingNotificationRequests(withIdentifiers: [payload.notificationIdentifier])
            }
        } catch {
            // Identifier-only diagnostic; never log the question or answer.
            logger.warning(
                "userQuestionNotificationFailed request=\(payload.requestID) question=\(payload.questionID)"
            )
        }
    }

    public func withdraw(_ snapshot: UserQuestionWaitingSnapshot) {
        presentations[snapshot.requestID] = nil
        let payloads = snapshot.questions.compactMap {
            UserQuestionNotificationPayload(requestID: snapshot.requestID,
                questionID: $0.questionID, conversationID: snapshot.conversationID,
                runID: snapshot.runID, revision: $0.revision)
        }
        let identifiers = payloads.flatMap { [$0.notificationIdentifier, $0.notificationIdentifier + ".reply-error"] }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for payload in payloads {
            registeredCategories[payload.categoryIdentifier] = nil
            retiredCategoryIDs.insert(payload.categoryIdentifier)
        }
    }

    private func makeCategory(
        for question: UserQuestion,
        payload: UserQuestionNotificationPayload
    ) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []
        // One action per option is only meaningful for single-select. A
        // multi-select question opens the inline card so the person can make
        // the full selection; it never pretends one tapped option is a
        // complete multi-select answer.
        if question.selectionMode == .single, question.options.count <= 4 {
            for option in question.options {
                actions.append(UNNotificationAction(
                    identifier: Self.optionActionPrefix + option.id,
                    title: option.label,
                    options: [.authenticationRequired]
                ))
            }
        }
        // A text response is a complete answer only for a text-only
        // question. For an option question, typing a note without selecting
        // an option is incomplete; the notification opens the inline card
        // instead of sending a guaranteed-invalid answer.
        if question.isTextOnly {
            actions.append(UNTextInputNotificationAction(
                identifier: Self.textActionIdentifier,
                title: FloeL10n.l("user_question.notification.answer"),
                options: [.authenticationRequired],
                textInputButtonTitle: FloeL10n.l("user_question.notification.send"),
                textInputPlaceholder: FloeL10n.l("user_question.notification.placeholder")
            ))
        }
        return UNNotificationCategory(
            identifier: payload.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }

    /// Handle a response that belongs to this feature. Returns false without
    /// touching the completion handler when the payload is not ours, so the
    /// app's existing notification router keeps ownership of every other
    /// route. When it returns true, this method owns the completion handler
    /// and calls it exactly once after persistence (or immediately for
    /// open/dismiss).
    @discardableResult
    public nonisolated static func handle(
        response: UNNotificationResponse,
        answering: any UserQuestionNotificationAnswering,
        onOpen: (@MainActor @Sendable (UserQuestionNotificationPayload) -> Void)? = nil,
        completion: @escaping () -> Void
    ) -> Bool {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = UserQuestionNotificationPayload(userInfo: userInfo) else {
            return false
        }
        let actionIdentifier = response.actionIdentifier
        let action: UserQuestionNotificationAction
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            action = .open
        } else if actionIdentifier == UNNotificationDismissActionIdentifier {
            action = .dismiss
        } else if actionIdentifier.hasPrefix(optionActionPrefix) {
            action = .option(String(actionIdentifier.dropFirst(optionActionPrefix.count)))
        } else if actionIdentifier == textActionIdentifier {
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            action = .text(String(text.prefix(UserQuestionRequest.maximumFreeTextCharacters)))
        } else {
            action = .open
        }

        return dispatch(
            UserQuestionNotificationResponse(payload: payload, action: action),
            answering: answering, onOpen: onOpen, completion: completion
        )
    }

    /// The native delegate and deterministic tests share this exact typed
    /// dispatch. No notification object or Any-valued dictionary crosses an
    /// actor boundary; completion still waits only for answer persistence.
    @discardableResult
    public nonisolated static func dispatch(
        _ response: UserQuestionNotificationResponse,
        answering: any UserQuestionNotificationAnswering,
        onOpen: (@MainActor @Sendable (UserQuestionNotificationPayload) -> Void)? = nil,
        completion: @escaping () -> Void
    ) -> Bool {
        let payload = response.payload
        let action = response.action
        let notificationCompletion = UserQuestionNotificationCompletion(completion)
        switch action {
        case .open:
            Task { @MainActor in
                onOpen?(payload)
                notificationCompletion.finish()
            }
            return true
        case .dismiss:
            Task { @MainActor in notificationCompletion.finish() }
            return true
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Task { @MainActor in notificationCompletion.finish() }
                return true
            }
            let answer = UserQuestionAnswer(freeText: trimmed)
            Task {
                do {
                    _ = try await answering.submitNotificationAnswer(
                        requestID: payload.requestID,
                        questionID: payload.questionID,
                        conversationID: payload.conversationID,
                        runID: payload.runID,
                        expectedRevision: payload.revision,
                        answer: answer
                    )
                } catch {
                    // The store rejects a stale/foreign request. Do not log
                    // answer text; identifiers alone are enough for triage.
                    FloeLogger(category: .app).warning(
                        "userQuestionNotificationAnswerRejected request=\(payload.requestID) question=\(payload.questionID)"
                    )
                    await reportAnswerFailure(error, payload: payload)
                }
                await MainActor.run { notificationCompletion.finish() }
            }
            return true
        case .option(let optionID):
            guard !optionID.isEmpty, optionID.count <= 64 else {
                Task { @MainActor in notificationCompletion.finish() }
                return true
            }
            let answer = UserQuestionAnswer(selectedOptionIDs: [optionID])
            Task {
                do {
                    _ = try await answering.submitNotificationAnswer(
                        requestID: payload.requestID,
                        questionID: payload.questionID,
                        conversationID: payload.conversationID,
                        runID: payload.runID,
                        expectedRevision: payload.revision,
                        answer: answer
                    )
                } catch {
                    FloeLogger(category: .app).warning(
                        "userQuestionNotificationAnswerRejected request=\(payload.requestID) question=\(payload.questionID)"
                    )
                    await reportAnswerFailure(error, payload: payload)
                }
                await MainActor.run { notificationCompletion.finish() }
            }
            return true
        }
    }

    @MainActor
    private static func reportAnswerFailure(_ error: any Error, payload: UserQuestionNotificationPayload) async {
        if let questionError = error as? UserQuestionError {
            switch questionError {
            case .notFound, .runMismatch, .staleRevision, .requestCancelled:
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [payload.notificationIdentifier])
                return
            default: break
            }
        }
        // A reply which failed to persist must not disappear silently. No
        // answer or credential is copied into this notice; tapping opens the
        // same question through the existing typed navigation route.
        let content = UNMutableNotificationContent()
        content.title = FloeL10n.l("user_question.notification.retry_title")
        content.body = FloeL10n.l("user_question.notification.retry_body")
        content.userInfo = payload.userInfo
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: payload.notificationIdentifier + ".reply-error",
            content: content, trigger: nil))
    }
}
#endif

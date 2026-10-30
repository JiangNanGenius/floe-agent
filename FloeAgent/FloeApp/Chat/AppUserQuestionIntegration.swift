#if canImport(UIKit)
import Foundation
import Combine
import UIKit
import UserNotifications
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

/// App composition only: persistence and answer validation stay in the
/// existing runtime coordinator, navigation stays in AppRouter, and audio
/// remains owned by the shared input service.
@MainActor
final class AppUserQuestionIntegration: ObservableObject, UserQuestionNotificationAnswering {
    private weak var environment: AppEnvironment?
    let center = UserQuestionCenter()
    private let store: UserQuestionStore
    let notificationBridge = UserQuestionNotificationBridge()
    lazy var coordinator = UserQuestionCoordinator(store: store, eventHandler: { [weak self] event in
        await self?.receive(event)
    })
    private var backgroundObserver: AnyCancellable?
    private var observedConversations: Set<UUID> = []
    @Published private(set) var pending: [UUID: UserQuestionWaitingSnapshot] = [:]
    @Published var dictationQuestionID: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = UserQuestionStore(database: environment.database)
        center.answering = coordinator
        // Notifications are checked per task below, including authorization
        // and foreground state. The view projection does not grant them.
        center.canPresentNotifications = { false }
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.presentBackgroundQuestions() }
            }
    }

    private func receive(_ event: UserQuestionEvent) async {
        switch event {
        case .presented(let snapshot), .settled(let snapshot):
            if snapshot.isEphemeral {
                guard let session = environment?.conversationCenter.temporarySession,
                      session.conversation.id == snapshot.conversationID,
                      (try? await session.runStore.run(id: snapshot.runID)) != nil,
                      environment?.conversationCenter.temporarySession?.incarnation == session.incarnation else { return }
            }
            center.handle(event)
            observedConversations.insert(snapshot.conversationID)
            pending[snapshot.conversationID] = snapshot.currentQuestion == nil ? nil : snapshot
            if let service = environment?.conversationCenter.service(for: snapshot.runID) {
                if !snapshot.pendingBlockingQuestionIDs.isEmpty {
                    await service.setUserQuestionWait(snapshot)
                } else if await service.snapshot().pendingUserQuestion?.requestID == snapshot.requestID {
                    await service.setUserQuestionWait(nil)
                }
            }
            await postIfAllowed(snapshot)
        case .answerAvailable(let delivery):
            center.handle(event)
            await deliverAnswers(conversationID: delivery.conversationID)
        }
    }

    func discardTemporary(conversationID: UUID, runIDs: Set<UUID>) async {
        if let snapshot = pending[conversationID], snapshot.isEphemeral,
           runIDs.contains(snapshot.runID) { pending[conversationID] = nil }
        for runID in runIDs { await coordinator.purgeEphemeral(runID: runID) }
    }

    func restore(conversationID: UUID) async {
        observedConversations.insert(conversationID)
        if let snapshot = try? await coordinator.pendingSnapshot(conversationID: conversationID) {
            await receive(.presented(snapshot))
        } else {
            pending[conversationID] = nil
        }
        await deliverAnswers(conversationID: conversationID)
    }

    func answerSpokenText(_ text: String, conversationID: UUID) async throws -> Bool {
        guard let snapshot = try await coordinator.pendingSnapshot(conversationID: conversationID),
              let question = snapshot.currentQuestion else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Speech uses the same CAS answer path as taps. If it exactly names
        // an offered choice, select that choice; otherwise keep it as text
        // only when this question permits a written answer.
        let matching = question.options.filter {
            $0.label.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
        let answer: UserQuestionAnswer
        if matching.count == 1 {
            answer = UserQuestionAnswer(selectedOptionIDs: [matching[0].id])
        } else if question.isTextOnly || question.allowsFreeText {
            answer = UserQuestionAnswer(freeText: trimmed)
        } else {
            return false
        }
        let receipt = try await coordinator.submitHumanAnswer(target: snapshot.target(for: question), answer: answer)
        return receipt.accepted
    }

    private func deliverAnswers(conversationID: UUID) async {
        guard let environment else { return }
        do {
            for delivery in try await coordinator.pendingDeliveries(conversationID: conversationID) {
                guard let snapshot = try await store.snapshot(requestID: delivery.requestID) else { continue }
                // A later answer can arrive while the first queue write is
                // awaited. Identity must therefore be per question, never
                // the changing set of currently unacknowledged answers.
                for single in try Self.individualAnswers(delivery, request: snapshot) {
                    try await environment.conversationCenter.enqueueQuestionAnswer(single)
                    try await coordinator.acknowledgeDeliveries(questionIDs: single.answers.map(\.questionID))
                }
            }
        } catch {
            // The durable source is still unacknowledged. Restore or the next
            // answer event retries it; no answer body enters diagnostics.
            FloeLogger(category: .app).warning("userQuestionDeliveryDeferred conversation=\(conversationID)")
        }
    }

    static func individualAnswers(
        _ delivery: UserQuestionAnswerDelivery, request: UserQuestionWaitingSnapshot
    ) throws -> [UserQuestionAnswerDelivery] {
        guard delivery.requestID == request.requestID,
              delivery.conversationID == request.conversationID,
              delivery.runID == request.runID else { throw UserQuestionError.runMismatch }
        return delivery.answers.map { answer in
            UserQuestionAnswerDelivery(requestID: delivery.requestID,
                conversationID: delivery.conversationID, runID: delivery.runID,
                answers: [answer], createdAt: delivery.createdAt,
                text: UserQuestionFormatting.deliveryText(request: request, answers: [answer]))
        }
    }

    static func inputID(for delivery: UserQuestionAnswerDelivery) throws -> UUID {
        guard delivery.answers.count == 1 else {
            throw FloeError.validationFailed("Question answers require a stable per-question delivery identity")
        }
        let identity = delivery.requestID + ":" + delivery.answers[0].questionID
        let hex = Array(FloeDigest.sha256Hex(Data(identity.utf8)).prefix(32))
        let raw = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                   String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let id = UUID(uuidString: raw) else { throw UserQuestionError.invalidRequest("Invalid delivery identity") }
        return id
    }

    private func presentBackgroundQuestions() async {
        for id in observedConversations {
            guard let snapshots = try? await coordinator.snapshots(conversationID: id) else { continue }
            for snapshot in snapshots { await postIfAllowed(snapshot) }
        }
    }

    private func postIfAllowed(_ snapshot: UserQuestionWaitingSnapshot) async {
        guard !snapshot.isEphemeral, let environment else { return }
        if snapshot.currentQuestion == nil {
            notificationBridge.withdraw(snapshot)
            return
        }
        guard UIApplication.shared.applicationState == .background,
              let policy = try? await SQLiteWorkspaceStore(database: environment.database)
                .taskPolicy(conversationID: snapshot.conversationID),
              policy.notificationPolicy.shouldNotifyActionRequired,
              await BackgroundRunCoordinator.currentNotificationAuthorization().canPresentAlert,
              let fresh = try? await coordinator.pendingSnapshot(conversationID: snapshot.conversationID),
              fresh.requestID == snapshot.requestID, let question = fresh.currentQuestion,
              UIApplication.shared.applicationState == .background else { return }
        await notificationBridge.present(snapshot: fresh, question: question, canPresentAlert: true)
    }

    // The bridge calls this Sendable requirement from a nonisolated task.
    // Pinning the witness to the main actor keeps the storage admission
    // fence, bootstrap join and AppEnvironment reads on the actor that owns
    // them; the async call still crosses back with the persisted receipt.
    @MainActor
    func submitNotificationAnswer(
        requestID: String, questionID: String, conversationID: UUID, runID: UUID,
        expectedRevision: Int, answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        guard let environment else { throw CancellationError() }
        let lease = try StorageSuspensionCoordinator.shared.beginNotificationResponseOperation()
        defer { lease.finish() }
        // Inline replies need durable storage, not an active scene or a
        // mounted chat. Join the existing single-flight bootstrap.
        await environment.bootstrap()
        try lease.check()
        guard environment.persistenceReady, !environment.isEphemeral else {
            throw FloeError.validationFailed(String(localized: "user_question.error.open_to_retry"))
        }
        return try await coordinator.submitNotificationAnswer(
            requestID: requestID, questionID: questionID, conversationID: conversationID,
            runID: runID, expectedRevision: expectedRevision, answer: answer
        )
    }
}
#endif

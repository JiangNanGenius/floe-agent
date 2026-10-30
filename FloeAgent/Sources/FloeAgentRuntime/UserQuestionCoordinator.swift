// FloeAgentRuntime — user-question wait lifecycle.
//
// This coordinator is the single owner of the "ask, wait, resume" boundary.
// It registers the durable question set, emits a typed presentation event,
// parks only on the questions whose policy actually blocks, and accepts an
// answer exactly once through the store's CAS transaction. A required wait
// has no model-chosen default and no fixed timeout. optionalContinue returns
// a pending receipt so the run can keep doing independent work; its answer is
// delivered on a later safe turn. optionalDeadline expires only after the
// explicit interval and reports `deadlineDefault` provenance, never a human
// answer.
//
// No provider socket, microphone, audio unit or GPU worker is owned by this
// wait. The provider turn that requested the question has already completed;
// the coordinator only holds an async continuation until the store changes.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

/// UI/app-facing answer seam. The inline card, the notification bridge and
/// any future voice binding call the same methods, so there is one settlement
/// path and one receipt even when two surfaces race.
public protocol UserQuestionAnswering: Sendable {
    func submitHumanAnswer(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt

    func saveDraft(
        target: UserQuestionAnswerTarget,
        draft: UserQuestionAnswer
    ) async throws -> UserQuestionDraftReceipt

    func cancelRequest(requestID: String) async throws

    func pendingSnapshot(conversationID: UUID) async throws -> UserQuestionWaitingSnapshot?

    func pendingSnapshot(runID: UUID) async throws -> UserQuestionWaitingSnapshot?

    /// Durable, read-only peek. Calling it twice returns the same stable
    /// delivery identities until an explicit acknowledgement. The answer is
    /// never lost if the caller dies before committing it to a durable input
    /// queue.
    func pendingDeliveries(conversationID: UUID) async throws -> [UserQuestionAnswerDelivery]

    /// Explicit acknowledgement after the caller has committed the delivery
    /// to its durable input queue (with `UserQuestionAnswerDelivery.id` as
    /// the deterministic idempotency key). Idempotent.
    func acknowledgeDeliveries(questionIDs: [String]) async throws

    /// Notification response entry. Implementations must revalidate the
    /// request/question against the claimed conversation and run before
    /// settling.
    func submitNotificationAnswer(
        requestID: String,
        questionID: String,
        conversationID: UUID,
        runID: UUID,
        expectedRevision: Int,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt
}

/// Runtime recovery seam. A checkpoint may contain a dispatched user.ask call
/// whose answer never reached the process. The runtime asks this seam for a
/// real result backed by the durable question store instead of synthesizing a
/// generic "unknown outcome" failure. It only returns nil when no question
/// request was ever registered, in which case the ordinary recovery policy
/// remains authoritative.
public protocol UserQuestionRuntimeRecovery: Sendable {
    func recoverInterruptedQuestion(
        runID: UUID,
        conversationID: UUID,
        call: ToolCall
    ) async -> ToolResult?

    func waitingQuestionRequestIDs(runID: UUID) async -> [String]

    /// Terminal/cancel fence. Pending questions become cancelled and their
    /// late answers receive an already-settled receipt.
    func cancelPendingQuestions(runID: UUID) async
}

public actor UserQuestionCoordinator: UserQuestionAnswering, UserQuestionRuntimeRecovery, UserQuestionNotificationAnswering {

    private let store: UserQuestionStore
    private let eventHandler: (@Sendable (UserQuestionEvent) async -> Void)?
    private let now: @Sendable () -> Date

    /// One parked execution per request. The continuation is resumed by the
    /// next accepted answer, expiry, cancel or terminal fence.
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    /// Monotonic-ish generation guard closes the actor-reentrancy gap between
    /// reading a snapshot and installing its continuation.
    private var generations: [String: Int] = [:]
    private var deadlineTasks: [String: Task<Void, Never>] = [:]
    private var cancellationTasks: [String: Task<Void, Never>] = [:]
    /// Requests whose tool receipt already returned with optionalContinue
    /// work still pending. Only these may later emit the next-turn delivery
    /// event; a required answer belongs in its still-open tool result.
    private var returnedRequestIDs: Set<String> = []

    public init(
        store: UserQuestionStore,
        eventHandler: (@Sendable (UserQuestionEvent) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.eventHandler = eventHandler
        self.now = now
    }

    // MARK: - Tool entry point

    /// Registers and waits according to the request's explicit policy. The
    /// returned receipt is the model-visible tool result; it is built from
    /// persisted state only.
    public func ask(
        _ request: UserQuestionRequest,
        runID: UUID,
        conversationID: UUID,
        toolCallID: String,
        cancellation: CancellationToken,
        temporaryReadOnly: Bool
    ) async throws -> UserQuestionToolReceipt {
        guard !toolCallID.isEmpty else { throw UserQuestionError.missingToolCallID }
        try request.validate()
        let createdAt = now()
        let requestID = Self.requestID(runID: runID, toolCallID: toolCallID)
        let digest = try Self.digest(request)
        let questions = try request.makeQuestions(
            requestID: requestID,
            conversationID: conversationID,
            runID: runID,
            toolCallID: toolCallID,
            createdAt: createdAt
        )
        let registration = UserQuestionRegistration(
            requestID: requestID,
            requestDigest: digest,
            conversationID: conversationID,
            runID: runID,
            toolCallID: toolCallID,
            waitPolicy: request.waitPolicy,
            questions: questions,
            createdAt: createdAt,
            isEphemeral: temporaryReadOnly
        )
        let snapshot = try await store.register(registration)
        guard snapshot.requestDigest == digest else {
            throw UserQuestionError.requestConflict
        }
        if snapshot.state == .awaitingAnswer || snapshot.state == .awaitingOptional {
            await emit(.presented(snapshot))
        }
        return try await wait(
            requestID: requestID,
            cancellation: cancellation,
            presentInitial: false
        )
    }

    // MARK: - Answer surface

    public func submitHumanAnswer(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        try await settleHuman(target: target, answer: answer)
    }

    public func saveDraft(
        target: UserQuestionAnswerTarget,
        draft: UserQuestionAnswer
    ) async throws -> UserQuestionDraftReceipt {
        try await store.saveDraft(target: target, draft: draft, now: now())
    }

    /// Notification-specific entry. The bridge can only target identifiers
    /// decoded from its own payload; the coordinator still revalidates that
    /// the request belongs to the claimed conversation/run before accepting.
    public func submitNotificationAnswer(
        requestID: String,
        questionID: String,
        conversationID: UUID,
        runID: UUID,
        expectedRevision: Int,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        guard let snapshot = try await store.snapshot(requestID: requestID) else {
            throw UserQuestionError.notFound
        }
        guard snapshot.conversationID == conversationID,
              snapshot.runID == runID,
              snapshot.questions.contains(where: { $0.questionID == questionID }) else {
            throw UserQuestionError.runMismatch
        }
        return try await settleHuman(
            target: UserQuestionAnswerTarget(
                requestID: requestID,
                questionID: questionID,
                conversationID: conversationID,
                runID: runID,
                expectedRevision: expectedRevision
            ),
            answer: answer
        )
    }

    private func settleHuman(
        target: UserQuestionAnswerTarget,
        answer: UserQuestionAnswer
    ) async throws -> UserQuestionAnswerReceipt {
        let receipt = try await store.submitHumanAnswer(
            target: target,
            answer: answer,
            now: now()
        )
        guard receipt.accepted else { return receipt }
        guard let snapshot = try await store.snapshot(requestID: target.requestID) else {
            return receipt
        }
        await emit(.settled(snapshot))
        signal(target.requestID)
        cleanupWaitTasks(for: target.requestID)
        if returnedRequestIDs.contains(target.requestID),
           !snapshot.hasBlockingPending,
           let record = receipt.answer {
            if snapshot.isFullySettled { returnedRequestIDs.remove(target.requestID) }
            let delivery = UserQuestionAnswerDelivery(
                requestID: snapshot.requestID,
                conversationID: snapshot.conversationID,
                runID: snapshot.runID,
                answers: [record],
                createdAt: now(),
                deliveredAt: nil,
                text: UserQuestionFormatting.deliveryText(request: snapshot, answers: [record])
            )
            await emit(.answerAvailable(delivery))
        }
        return receipt
    }

    // MARK: - Cancel / expiry

    public func cancelRequest(requestID: String) async throws {
        guard let snapshot = try await store.cancel(requestID: requestID, now: now()) else {
            return
        }
        await emit(.settled(snapshot))
        signal(requestID)
        cleanupWaitTasks(for: requestID)
        returnedRequestIDs.remove(requestID)
    }

    public func cancelPending(runID: UUID) async throws {
        let snapshots = try await store.cancelPending(runID: runID, now: now())
        for snapshot in snapshots {
            await emit(.settled(snapshot))
            signal(snapshot.requestID)
            cleanupWaitTasks(for: snapshot.requestID)
            returnedRequestIDs.remove(snapshot.requestID)
        }
    }

    public func cancelPending(conversationID: UUID) async throws {
        let snapshots = try await store.cancelPending(conversationID: conversationID, now: now())
        for snapshot in snapshots {
            await emit(.settled(snapshot))
            signal(snapshot.requestID)
            cleanupWaitTasks(for: snapshot.requestID)
            returnedRequestIDs.remove(snapshot.requestID)
        }
    }

    /// Exact-incarnation purge. Capture the old temp run ids BEFORE any
    /// await that may recreate the session, then purge each id here. Never
    /// use a conversation-wide purge for old-incarnation cleanup.
    public func purgeEphemeral(runID: UUID) async {
        // Wake any parked answer wait before removing its durable record, so
        // discarding an old temporary incarnation cannot leave a tool task
        // suspended on a question that no longer exists.
        try? await cancelPending(runID: runID)
        await store.purgeEphemeral(runID: runID)
    }

    /// True task-deletion purge for every temporary question in a
    /// conversation. Not an old-incarnation cleanup hook.
    public func purgeEphemeral(conversationID: UUID) async {
        try? await cancelPending(conversationID: conversationID)
        await store.purgeEphemeral(conversationID: conversationID)
    }

    private func expireDue(requestID: String) async {
        guard let snapshot = try? await store.expire(requestID: requestID, now: now()) else { return }
        await emit(.settled(snapshot))
        signal(requestID)
        cleanupWaitTasks(for: requestID)
    }

    // MARK: - Queries / delivery

    public func pendingSnapshot(conversationID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        try await store.pendingSnapshot(conversationID: conversationID)
    }

    /// Truthful pending question for one exact run, used by recovery/UI to
    /// present the same question after a restart. It never creates a request.
    public func pendingSnapshot(runID: UUID) async throws -> UserQuestionWaitingSnapshot? {
        try await store.latestPendingSnapshot(runID: runID)
    }

    public func snapshots(
        conversationID: UUID,
        includeSettled: Bool = false
    ) async throws -> [UserQuestionWaitingSnapshot] {
        try await store.snapshots(conversationID: conversationID, includeSettled: includeSettled)
    }

    /// Durable read-only peek for optionalContinue answers. The delivery id
    /// is stable (`requestID` + question ids) and remains available across
    /// relaunch until the caller explicitly acknowledges it after committing
    /// the text to its own durable input queue.
    public func pendingDeliveries(conversationID: UUID) async throws -> [UserQuestionAnswerDelivery] {
        try await store.undeliveredAnswers(conversationID: conversationID)
    }

    /// Marks the exact delivered questions acknowledged. Callers MUST commit
    /// the answer to their durable input queue first and use the stable
    /// delivery id for deduplication; this call is the final receipt, not the
    /// only copy of the answer.
    public func acknowledgeDeliveries(questionIDs: [String]) async throws {
        try await store.markDelivered(questionIDs: questionIDs, at: now())
    }

    public func waitingQuestionRequestIDs(runID: UUID) async -> [String] {
        (try? await store.waitingRequestIDs(runID: runID)) ?? []
    }

    public func cancelPendingQuestions(runID: UUID) async {
        try? await cancelPending(runID: runID)
    }

    // MARK: - Restart recovery

    /// Reconstructs a real tool result from the durable question store. This
    /// is called by AgentRuntime while repairing an interrupted provider
    /// tool pair. If a required question is still pending, the resume parks
    /// here until it is answered or fenced; no provider request is in flight
    /// during that wait.
    public func recoverInterruptedQuestion(
        runID: UUID,
        conversationID: UUID,
        call: ToolCall
    ) async -> ToolResult? {
        guard call.toolName == UserAskTool.name else { return nil }
        let snapshot: UserQuestionWaitingSnapshot?
        do {
            snapshot = try await store.snapshot(runID: runID, toolCallID: call.id)
        } catch {
            return nil
        }
        guard let snapshot, snapshot.conversationID == conversationID else { return nil }
        if snapshot.state == .awaitingAnswer || snapshot.state == .awaitingOptional {
            await emit(.presented(snapshot))
        }
        let receipt: UserQuestionToolReceipt
        do {
            receipt = try await wait(
                requestID: snapshot.requestID,
                cancellation: CancellationToken(),
                presentInitial: false
            )
        } catch {
            return nil
        }
        if receipt.status == .pending {
            returnedRequestIDs.insert(snapshot.requestID)
        }
        return Self.toolResult(callID: call.id, receipt: receipt)
    }

    // MARK: - Wait loop

    private func wait(
        requestID: String,
        cancellation: CancellationToken,
        presentInitial: Bool
    ) async throws -> UserQuestionToolReceipt {
        if presentInitial,
           let snapshot = try await store.snapshot(requestID: requestID) {
            await emit(.presented(snapshot))
        }
        await startDeadlineTask(requestID: requestID)
        startCancellationTask(requestID: requestID, cancellation: cancellation)
        defer { cleanupWaitTasks(for: requestID) }

        while true {
            // Expiry/cancel/settlement may have retired the timers. Re-arm
            // them at each turn; the guards make this a no-op while live.
            await startDeadlineTask(requestID: requestID)
            startCancellationTask(requestID: requestID, cancellation: cancellation)
            if cancellation.isCancelled {
                _ = try? await store.cancel(requestID: requestID, now: now())
                if let snapshot = try await store.snapshot(requestID: requestID) {
                    await emit(.settled(snapshot))
                }
                signal(requestID)
                guard let snapshot = try await store.snapshot(requestID: requestID) else {
                    throw UserQuestionError.notFound
                }
                return UserQuestionFormatting.toolReceipt(for: snapshot)
            }
            let generation = generations[requestID, default: 0]
            guard let snapshot = try await store.snapshot(requestID: requestID) else {
                throw UserQuestionError.notFound
            }
            // A signal may have landed while the store read was in flight;
            // re-read the generation and fall through to another turn rather
            // than sleeping past a real change.
            if generations[requestID, default: 0] != generation { continue }
            if !snapshot.hasBlockingPending {
                if snapshot.state == .awaitingOptional { returnedRequestIDs.insert(requestID) }
                return UserQuestionFormatting.toolReceipt(for: snapshot)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // No await between the generation check above and this
                // install, so the only way a signal can be missed is if it
                // happened before the check; the loop then sees it.
                if generations[requestID, default: 0] != generation {
                    continuation.resume()
                } else {
                    waiters[requestID] = continuation
                }
            }
        }
    }

    private func signal(_ requestID: String) {
        generations[requestID, default: 0] += 1
        waiters.removeValue(forKey: requestID)?.resume()
    }

    private func startDeadlineTask(requestID: String) async {
        guard deadlineTasks[requestID] == nil else { return }
        let snapshot: UserQuestionWaitingSnapshot?
        do {
            snapshot = try await store.snapshot(requestID: requestID)
        } catch {
            return
        }
        guard let deadline = snapshot?.earliestPendingDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
        deadlineTasks[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expireDue(requestID: requestID)
        }
    }

    private func startCancellationTask(requestID: String, cancellation: CancellationToken) {
        guard cancellationTasks[requestID] == nil else { return }
        cancellationTasks[requestID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if cancellation.isCancelled {
                    try? await self?.cancelRequest(requestID: requestID)
                    return
                }
            }
        }
    }

    private func cleanupWaitTasks(for requestID: String) {
        deadlineTasks.removeValue(forKey: requestID)?.cancel()
        cancellationTasks.removeValue(forKey: requestID)?.cancel()
    }

    // MARK: - Helpers

    private func emit(_ event: UserQuestionEvent) async {
        await eventHandler?(event)
    }

    nonisolated static func requestID(runID: UUID, toolCallID: String) -> String {
        let material = "user.ask\u{1f}\(runID.uuidString)\u{1f}\(toolCallID)"
        let digest = FloeDigest.sha256Hex(Data(material.utf8))
        return "uq_" + String(digest.prefix(32))
    }

    nonisolated static func digest(_ request: UserQuestionRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return FloeDigest.sha256Hex(try encoder.encode(request))
    }

    nonisolated static func toolResult(
        callID: String,
        receipt: UserQuestionToolReceipt,
        maximumSummaryCharacters: Int = 262_144
    ) -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(receipt)) ?? Data()
        let summary = String(decoding: data, as: UTF8.self)
        let status: ToolResult.Status = receipt.status == .cancelled ? .cancelled : .ok
        return ToolResult(
            callID: callID,
            status: status,
            outputSummary: summary,
            outputDigest: FloeDigest.sha256Hex(data),
            maximumSummaryCharacters: maximumSummaryCharacters
        )
    }
}

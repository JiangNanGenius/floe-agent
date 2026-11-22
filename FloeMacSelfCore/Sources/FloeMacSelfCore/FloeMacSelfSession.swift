// SPDX-License-Identifier: MPL-2.0
//
// One Mac session = one durably admitted run. This actor owns the existing
// `ConversationRunService` instance, forwards its real events, validates
// exact-run approval commands, and performs lifecycle fencing. It never
// reimplements the agent loop, approval policy or persistence model.
//
// All terminal claims are read back through `FloeMacSelfDurableRunProbe`.
// A live event, a merely terminal-looking run row, a start failure or an
// unmatched terminal never releases the process claim or the durable
// admission.

import Foundation
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

actor FloeMacSelfSession {
    nonisolated let identity: FloeMacSelfSessionIdentity
    nonisolated let channel: FloeMacSelfSessionEventChannel

    private let service: ConversationRunService
    private let conversationStore: any ConversationStore
    private let launchStatusPayloads: [String]
    private let checkpointResume: (checkpoint: AgentCheckpoint, previousAdmission: FloeMacSelfAdmissionRecord)?
    private let runStore: any RunStore
    private let checkpointStore: any CheckpointStore
    private let admissions: FloeMacSelfAdmissionStore
    private let admissionEpoch: Int
    private let claims: FloeMacSelfConversationClaims
    private let fence: FloeMacSelfRunFence
    private let goal: String
    private let toolsEnabled: Bool
    private let boundary: FloeMacSelfTaskBoundary?
    /// The one durable pending-input store the runtime consumes. Running
    /// steers persist their row here exactly like the iPad composition.
    private let runningInputStore: any RunningInputStore
    /// The bound provider's model id, persisted on steer rows so a recovered
    /// queued follow-up relaunches with the user's original model choice.
    private let steerModelID: UUID?
    private let steerSupportsImages: Bool
    /// Exact durable attachments the prepared user turn must still carry when
    /// the run is re-checked immediately before dispatch.
    private let preparedAttachments: [AttachmentRef]
    /// Point-in-time re-check of the committed user turn immediately before
    /// dispatch. The runtime constructs the exact verifier for the launch
    /// kind (ordinary prepared input vs. accepted-plan confirmation message).
    private let verifyPreparedInput: @Sendable (PersistedMessage) throws -> Void
    /// Re-reads the durable workspace row and re-proves the persisted root
    /// still equals the admitted boundary root. Nil for tool-free sessions.
    private let verifyWorkspaceLease: (@Sendable () async throws -> Void)?
    /// The one durable question owner this session answers through. Nil only
    /// for plan sessions (questions never enter the plan ceiling).
    private let questionCenter: FloeMacSelfQuestionCenter?
    /// True when this session's executor can dispatch `user.ask` (project
    /// tool sessions and question-only standalone chats).
    private let questionAnsweringEnabled: Bool
    private let beforeInputRecheck: (@Sendable () async -> Void)?
    private let beforeServiceStart: (@Sendable () async -> Void)?
    private let afterCancellationAttempt: (@Sendable () async -> Void)?
    private let terminalObserver = FloeMacSelfTerminalObserver()

    private var phase: FloeMacSelfSessionPhase = .launched
    private var launched = false
    private var runFinished = false
    private var startFailure: FloeMacSelfFailure?
    private var terminalReceipt: FloeMacSelfTerminalReceipt?
    private var lastSnapshot: ConversationRunService.Snapshot?
    private var runTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var closeTask: Task<FloeMacSelfCloseReceipt, Error>?
    private var cancelDriver: Task<Void, Never>?
    private var cancellationAttempt: Task<Void, Never>?
    private var tornDown = false

    init(
        identity: FloeMacSelfSessionIdentity,
        service: ConversationRunService,
        conversationStore: any ConversationStore,
        runStore: any RunStore,
        checkpointStore: any CheckpointStore,
        admissions: FloeMacSelfAdmissionStore,
        admissionEpoch: Int,
        claims: FloeMacSelfConversationClaims,
        fence: FloeMacSelfRunFence,
        goal: String,
        toolsEnabled: Bool,
        boundary: FloeMacSelfTaskBoundary?,
        preparedAttachments: [AttachmentRef],
        runningInputStore: any RunningInputStore,
        steerModelID: UUID?,
        steerSupportsImages: Bool = false,
        verifyPreparedInput: @escaping @Sendable (PersistedMessage) throws -> Void,
        verifyWorkspaceLease: (@Sendable () async throws -> Void)? = nil,
        questionCenter: FloeMacSelfQuestionCenter? = nil,
        questionAnsweringEnabled: Bool = false,
        launchStatusPayloads: [String] = [],
        checkpointResume: (AgentCheckpoint, FloeMacSelfAdmissionRecord)? = nil,
        eventBufferLimit: Int,
        beforeInputRecheck: (@Sendable () async -> Void)? = nil,
        beforeServiceStart: (@Sendable () async -> Void)? = nil,
        afterCancellationAttempt: (@Sendable () async -> Void)? = nil
    ) {
        self.identity = identity
        self.service = service
        self.conversationStore = conversationStore
        self.launchStatusPayloads = launchStatusPayloads
        self.checkpointResume = checkpointResume
        self.runStore = runStore
        self.checkpointStore = checkpointStore
        self.admissions = admissions
        self.admissionEpoch = admissionEpoch
        self.claims = claims
        self.fence = fence
        self.goal = goal
        self.toolsEnabled = toolsEnabled
        self.boundary = boundary
        self.preparedAttachments = preparedAttachments
        self.runningInputStore = runningInputStore
        self.steerModelID = steerModelID
        self.steerSupportsImages = steerSupportsImages
        self.verifyPreparedInput = verifyPreparedInput
        self.verifyWorkspaceLease = verifyWorkspaceLease
        self.questionCenter = questionCenter
        self.questionAnsweringEnabled = questionAnsweringEnabled
        self.beforeInputRecheck = beforeInputRecheck
        self.beforeServiceStart = beforeServiceStart
        self.afterCancellationAttempt = afterCancellationAttempt
        self.channel = FloeMacSelfSessionEventChannel(bufferLimit: eventBufferLimit)
    }

    // MARK: - Start

    func launch() {
        guard !launched, !tornDown else { return }
        launched = true
        channel.yield(.prepared(identity))

        // Subscribe before starting so the projection does not miss the first
        // runtime transition. The stream itself has no replay.
        let stream = service.events()
        let eventChannel = channel
        let observer = terminalObserver
        forwardTask = Task { [eventChannel, observer] in
            for await event in stream {
                // Yield first: the observer then proves the terminal event is
                // already in every subscriber's buffer before the durable
                // `.ended` receipt is appended.
                eventChannel.yield(.harness(event))
                if case .terminal(let terminal) = event {
                    observer.record(terminal)
                }
            }
        }

        runTask = Task { [weak self] in
            await self?.runStart()
        }
    }

    private func runStart() async {
        guard !tornDown else { return }
        if phase == .launched {
            phase = .running
        }

        // No durable dispatch intent and no runtime start may happen after a
        // stop. `prepareDispatch` is a short synchronous fence check.
        guard fence.prepareDispatch() else {
            await settleBeforeDispatch(reason: "stoppedBeforeDispatch")
            return
        }

        let dispatchAdmission: FloeMacSelfDispatchAdmission
        do {
            dispatchAdmission = try await admissions.requestDispatch(
                conversationID: identity.conversationID,
                runID: identity.runID,
                epoch: admissionEpoch
            )
        } catch {
            // If the durable dispatch intent cannot be written, no runtime
            // start is allowed. A stop that raced this write is also covered
            // by the fence check below.
            await settleBeforeDispatch(reason: "dispatchAdmissionUnavailable")
            return
        }
        switch dispatchAdmission {
        case .stopped:
            await settleBeforeDispatch(reason: "stoppedBeforeDispatch")
            return
        case .conflict:
            await settleBeforeDispatch(reason: "dispatchAdmissionConflict")
            return
        case .admitted:
            break
        }

        // Re-read the exact durable user turn before starting the runtime.
        // This is a point-in-time check; it does not establish a cross-process
        // ownership lock or a request-journal/prepare transaction binding.
        await beforeInputRecheck?()
        do {
            guard let saved = try await conversationStore.message(
                id: identity.userMessageID, conversationID: identity.conversationID) else {
                throw FloeMacSelfCoreError.preparedIdentityMismatch("durable user input is unavailable")
            }
            try verifyPreparedInput(saved)
        } catch {
            await settleBeforeDispatch(reason: "preparedInputMismatch")
            return
        }

        // The exact workspace lease must still hold against durable storage
        // immediately before dispatch: a bookmark swapped after admission
        // fails closed here, while the no-dispatch proof is still available.
        if let verifyWorkspaceLease {
            do {
                try await verifyWorkspaceLease()
            } catch {
                await settleBeforeDispatch(reason: "workspaceLeaseMismatch")
                return
            }
        }

        // A stop can arrive while the durable write is awaited. Do not call
        // the runtime in that case. The durable row says "starting" but the
        // in-process fence proves `commitDispatch` never ran.
        guard !fence.isStopRequested else {
            await settleBeforeDispatch(reason: "stoppedBeforeDispatch")
            return
        }
        guard fence.commitDispatch() else {
            await settleBeforeDispatch(reason: "stoppedBeforeDispatch")
            return
        }

        await beforeServiceStart?()
        do {
            // A proven no-dispatch cancellation requires the untouched preparing
            // record. Add runtime metadata only after the dispatch claim commits.
            for payload in launchStatusPayloads {
                _ = try await runStore.appendEvent(runID: identity.runID, kind: .status, payloadJSON: payload)
            }
            if let checkpointResume {
                // The previous activation may already have a terminal row. A
                // new dispatch must prove a newer terminal event to settle.
                _ = try await runStore.appendEvent(runID: identity.runID, kind: .status,
                                                   payloadJSON: #"{"kind":"resumingCheckpoint"}"#)
                try await service.resumePrepared(from: checkpointResume.checkpoint)
            } else {
                try await service.startPrepared(goal: goal, userMessageID: identity.userMessageID)
            }
            await finishRun(failure: nil)
        } catch {
            await finishRun(failure: FloeMacSelfFailure.from(error))
        }
    }

    /// Settles a run that this process proved never dispatched. This is the
    /// only place the composition writes a terminal run state itself: it
    /// verifies the durable run is still `preparing` with only `preparing`
    /// status rows and no assistant/tool/usage/terminal record.
    private func settleBeforeDispatch(reason: String) async {
        guard !runFinished, !tornDown else { return }
        _ = fence.beginSettlement()
        if let checkpointResume {
            let released = (try? await admissions.releaseCheckpointResume(previous: checkpointResume.previousAdmission,
                                                                          epoch: admissionEpoch)) != nil
            let original = try? await runStore.run(id: identity.runID)
            let receipt = FloeMacSelfTerminalReceipt(runID: identity.runID, conversationID: identity.conversationID,
                outcome: .interrupted, durableRunState: original?.state ?? "unknown", durableEndedAt: original?.endedAt,
                terminalEventSequence: nil,
                confirmed: false, unconfirmedReason: released ? "resumeNotDispatched" : "resumeReservationUnconfirmed",
                finalMessageID: nil, finalMessageVerified: false)
            terminalReceipt = receipt
            runFinished = true
            phase = .startFailed
            fence.settle(confirmed: false)
            forwardTask?.cancel()
            forwardTask = nil
            channel.yield(.ended(receipt))
            channel.finish()
            return
        }
        let failure = FloeMacSelfFailure(
            code: "stoppedBeforeDispatch",
            message: "The Mac run was stopped before dispatch."
        )
        do {
            let receipt = try await admissions.abandonBeforeDispatch(
                conversationID: identity.conversationID,
                runID: identity.runID,
                epoch: admissionEpoch,
                reason: reason,
                dispatchCommitted: false
            )
            terminalReceipt = receipt
            runFinished = true
            startFailure = failure
            if receipt.confirmed {
                claims.release(conversationID: identity.conversationID, runID: identity.runID)
            }
            phase = receipt.confirmed ? .ended : .startFailed
            fence.settle(confirmed: receipt.confirmed)
            if receipt.confirmed {
                channel.yield(.ended(receipt))
            } else {
                channel.yield(.startFailed(failure))
            }
        } catch {
            // The run may have been committed; no-dispatch could not be
            // proven/recorded. Preserve the run and the durable admission as
            // unknown; do not release either.
            let unknown = FloeMacSelfTerminalReceipt(
                runID: identity.runID,
                conversationID: identity.conversationID,
                outcome: .unknown,
                durableRunState: "unknown",
                durableEndedAt: nil,
                terminalEventSequence: nil,
                confirmed: false,
                unconfirmedReason: "preDispatchAbandonFailed",
                finalMessageID: nil,
                finalMessageVerified: false
            )
            terminalReceipt = unknown
            runFinished = true
            startFailure = failure
            phase = .startFailed
            fence.settle(confirmed: false)
            _ = try? await admissions.markSettled(
                conversationID: identity.conversationID,
                runID: identity.runID,
                epoch: admissionEpoch,
                confirmed: false,
                detail: "preDispatchAbandonFailed"
            )
            channel.yield(.startFailed(failure))
        }
        forwardTask?.cancel()
        forwardTask = nil
        channel.finish()
    }

    // MARK: - Live view

    func snapshot() async -> ConversationRunService.Snapshot? {
        guard !tornDown else { return lastSnapshot }
        let snapshot = await service.snapshot()
        lastSnapshot = snapshot
        return snapshot
    }

    func phaseValue() -> FloeMacSelfSessionPhase {
        phase
    }

    func isTornDown() -> Bool {
        tornDown
    }

    func hasFinished() -> Bool {
        runFinished
    }

    func summary() async -> FloeMacSelfSessionSummary {
        let live = await self.snapshot()
        return FloeMacSelfSessionSummary(
            identity: identity,
            phase: phase,
            stateName: live?.stateName ?? "unknown",
            isWaitingForApproval: live?.pendingApproval != nil,
            isTerminal: live?.isTerminal ?? false,
            lastFailure: startFailure
        )
    }

    func currentTerminalReceipt() -> FloeMacSelfTerminalReceipt? {
        terminalReceipt
    }

    // MARK: - Approval

    func updateApprovalPolicy(_ policy: any ApprovalPolicy) async -> Bool {
        guard toolsEnabled, !runFinished, !tornDown, !fence.isStopRequested else { return false }
        await service.updateApprovalPolicy(policy)
        return true
    }

    func resolveApproval(_ command: FloeMacSelfApprovalCommand) async -> FloeMacSelfApprovalResolution {
        guard !tornDown else { return .rejected(.sessionEnded) }
        guard command.conversationID == identity.conversationID else {
            return .rejected(.conversationMismatch)
        }
        guard command.runID == identity.runID else { return .rejected(.runMismatch) }
        guard command.workspaceID == identity.workspaceID else {
            return .rejected(.workspaceMismatch)
        }
        guard toolsEnabled else { return .rejected(.toolsDisabled) }
        guard !runFinished else { return .rejected(.sessionEnded) }
        guard let token = fence.beginApprovalDecision() else {
            // Stop/settlement already won; a late card must not be accepted.
            return .rejected(.sessionEnded)
        }

        let snapshot = await service.snapshot()
        lastSnapshot = snapshot
        guard fence.validateApprovalDecision(token), !runFinished, !tornDown else {
            return .rejected(.sessionEnded)
        }
        guard let pending = snapshot.pendingApproval else {
            return .rejected(.noPendingApproval)
        }
        if let requestedAt = command.requestedAt, pending.requestedAt != requestedAt {
            return .notPending
        }
        guard pending.toolCall.id == command.callID else {
            return .rejected(.callMismatch)
        }
        guard pending.toolCall.toolName == command.toolName else {
            return .rejected(.toolMismatch)
        }
        guard let boundary, case .nativeHost = boundary.ownership else {
            return .rejected(.scopeNotOwned)
        }
        guard case .local = pending.toolCall.scope else {
            return .rejected(.scopeNotOwned)
        }
        if case .allow(let scope, _) = command.decision {
            guard scope.toolName == pending.toolCall.toolName else {
                return .rejected(.toolMismatch)
            }
        }
        if case .escalateToHuman = command.decision {
            // The policy already escalated; a UI command must resolve the
            // card, not re-enter escalation.
            return .rejected(.notAccepted)
        }
        // No suspension between this final fence check and forwarding the
        // decision. A stop that was recorded during the snapshot await has
        // already changed the stop epoch and invalidates the token.
        guard fence.validateApprovalDecision(token), !runFinished, !tornDown else {
            return .rejected(.sessionEnded)
        }

        let accepted = await service.resolveApproval(command.decision, for: command.callID)
        return accepted ? .accepted : .notPending
    }

    // MARK: - Running steer (iPad-style user guidance)

    /// Classifies one durable steer row already bound to this input id. A
    /// replayed id must never re-submit: consumed/steerPending rows answer
    /// from durable truth, cancelled rows stay unaccepted, and only
    /// queued/promoting rows may continue toward the runtime.
    private enum SteerRowDecision: Sendable {
        case answer(Bool)
        case proceed
    }

    private func classifySteerRow(
        _ existing: PendingUserInput,
        trimmedText: String
    ) throws -> SteerRowDecision {
        guard existing.conversationID == identity.conversationID else {
            throw FloeMacSelfCoreError.invalidRequest(
                "steer input identity is already bound to another conversation"
            )
        }
        guard existing.content == trimmedText else {
            throw FloeMacSelfCoreError.invalidRequest(
                "steer input identity is already bound to different content"
            )
        }
        switch existing.status {
        case .consumed:
            // Idempotent replay of guidance this exact run already ate.
            return .answer(existing.consumedRunID == identity.runID)
        case .steerPending:
            // Already accepted by this exact run; the runtime owns the rest.
            return .answer(existing.targetRunID == identity.runID)
        case .cancelled:
            return .answer(false)
        case .queued, .promoting:
            return .proceed
        }
    }

    /// Submits user text guidance to this exact live run. Returns true exactly
    /// when the runtime accepted the guidance; the durable pending row then
    /// mirrors the iPad lifecycle (queued -> promoting -> steerPending, and
    /// `consumed` once the runtime copies it into model context; on a
    /// confirmed terminal the row is restored to `queued` so the host can
    /// recover it). Returns false — leaving the text recoverable — when the
    /// target is stale, stopped, ended, or the runtime rejected it. Throws
    /// only for invalid input or unavailable persistence.
    ///
    /// `executionMode` is persisted on the row for host queue recovery; the
    /// host supplies the run mode raw value so chat never becomes `agent`,
    /// and nil falls back to this session's conversation mode.
    func steer(
        text: String,
        inputID: UUID,
        executionMode: String? = nil
    ) async throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeMacSelfCoreError.invalidRequest("steer text must not be empty")
        }
        guard !trimmed.utf8.contains(0) else {
            throw FloeMacSelfCoreError.invalidRequest("steer text must not contain NUL")
        }
        guard trimmed.utf8.count <= FloeMacSelfRequestValidator.maximumGoalBytes else {
            throw FloeMacSelfCoreError.invalidRequest("steer text exceeds the bounded message size")
        }
        let resolvedExecutionMode: String
        if let executionMode {
            let mode = executionMode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mode.isEmpty, !mode.utf8.contains(0), mode.utf8.count <= 64 else {
                throw FloeMacSelfCoreError.invalidRequest("steer execution mode is invalid")
            }
            resolvedExecutionMode = mode
        } else {
            resolvedExecutionMode = identity.conversationMode.rawValue
        }
        guard !tornDown, !runFinished, !fence.isStopRequested else { return false }
        // Serialize against stop/settlement exactly like an approval decision:
        // a stop recorded during any await below invalidates the token.
        guard let token = fence.beginSteerDecision() else { return false }

        // Replaying the same input id must never duplicate a durable row.
        let existing: PendingUserInput?
        do {
            existing = try await runningInputStore.input(id: inputID)
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        if let existing {
            switch try classifySteerRow(existing, trimmedText: trimmed) {
            case .answer(let value):
                return value
            case .proceed:
                break
            }
        } else {
            do {
                _ = try await runningInputStore.enqueue(PendingUserInput(
                    id: inputID,
                    conversationID: identity.conversationID,
                    content: trimmed,
                    mode: .queue,
                    status: .queued,
                    selectedModelID: steerModelID,
                    workspaceID: identity.workspaceID,
                    executionMode: resolvedExecutionMode
                ))
            } catch {
                throw FloeMacSelfCoreError.persistenceUnavailable(
                    FloeMacSelfErrorIdentity.render(error)
                )
            }
        }

        // Mirror the iPad promotion before touching the runtime. A nil result
        // means the row lost its queued state concurrently: re-read it and
        // answer from durable truth instead of risking a double submission.
        let promoted: PendingUserInput
        do {
            if let row = try await runningInputStore.beginSteerPromotion(
                id: inputID, expectedRunID: identity.runID
            ) {
                promoted = row
            } else {
                guard let reread = try await runningInputStore.input(id: inputID) else {
                    // The row vanished between read and promotion; refuse
                    // rather than steer without a durable pending row.
                    return false
                }
                switch try classifySteerRow(reread, trimmedText: trimmed) {
                case .answer(let value):
                    return value
                case .proceed:
                    // A queued row that cannot be promoted is an inconsistent
                    // race; refuse the submission without touching the runtime.
                    return false
                }
            }
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }

        let attachments = promoted.attachments
        var images: [ConversationImagePart] = []
        var attachmentText: [String] = []
        if !attachments.isEmpty {
            guard promoted.conversationID == identity.conversationID, promoted.targetRunID == identity.runID,
                  promoted.workspaceID == identity.workspaceID, promoted.selectedModelID == steerModelID,
                  promoted.content == trimmed, attachments.count <= FloeMacSelfRequestValidator.maximumAttachments,
                  attachments.allSatisfy({ $0.storage == .securityScopedBookmark }) else {
                try await runningInputStore.restoreQueued(id: inputID)
                return false
            }
            let supportsImages = steerSupportsImages
            do {
                (images, attachmentText) = try await Task.detached(priority: .userInitiated) {
                    try FloeMacSelfRuntime.guidanceAttachments(attachments, supportsImages: supportsImages)
                }.value
            } catch {
                try await runningInputStore.restoreQueued(id: inputID)
                return false
            }
        }

        // No suspension between this final check and the runtime hand-off.
        guard !Task.isCancelled, fence.validateSteerDecision(token), !runFinished, !tornDown else {
            try? await runningInputStore.restoreQueued(id: inputID)
            return false
        }
        let acceptance = await service.steer(
            RuntimeSteerInput(id: inputID, content: trimmed, images: images, attachments: attachments,
                              createdAt: promoted.createdAt, attachmentText: attachmentText),
            expectedRunID: identity.runID
        )
        switch acceptance {
        case .accepted, .alreadyAccepted:
            // A failed intermediate write only loses the steerPending snapshot;
            // consumption (or crash recovery) still resolves the row, and the
            // runtime already owns the guidance, so this stays accepted.
            try? await runningInputStore.markSteerAccepted(id: inputID, runID: identity.runID)
            return true
        case .rejected:
            // Unaccepted: keep the text recoverable exactly like the iPad
            // restoreQueued path; nothing enters the transcript.
            try? await runningInputStore.restoreQueued(id: inputID)
            return false
        }
    }

    // MARK: - Queue guidance withdrawal (host demote hook)

    /// Withdraws one accepted-but-unconsumed guidance row from this exact run
    /// so the host can demote it back to the ordinary message queue. This is
    /// the Mac mirror of the iPad `ConversationCenter.withdrawPendingGuidance`
    /// boundary and it fails closed everywhere: it returns true only when the
    /// row is durably `queued` again. False means the row was already consumed
    /// (the runtime won the race and owns the text), already changed status,
    /// bound to another run/conversation, or this session is finished — in
    /// every false case the durable row keeps its honest status, nothing is
    /// removed from model context, and the unsent content is never lost.
    func withdrawSteerForQueueDemotion(id: UUID) async -> Bool {
        guard !tornDown, !runFinished else { return false }
        // Durable validation first: only a steerPending row bound to this
        // exact run may migrate back. A consumed row stays consumed; the
        // queue demote must never disguise a sent message as a queued one.
        guard let row = try? await runningInputStore.input(id: id),
              row.conversationID == identity.conversationID,
              row.status == .steerPending,
              row.targetRunID == identity.runID else { return false }
        // Atomically withdraw only guidance not yet copied into model
        // context; a false result means consumption won the race.
        guard await service.withdrawSteer(id: id) else { return false }
        // Preserve the original content/metadata as an ordinary queued row.
        // restoreQueued keeps goal rows' target run binding and the original
        // model/workspace/execution mode, so a later startNextQueued relaunch
        // is identical to a never-steered row. If this write fails the row
        // stays steerPending but the runtime no longer holds it; the
        // confirmed-terminal sweep requeues it, so report the honest status.
        try? await runningInputStore.restoreQueued(id: id)
        let final = try? await runningInputStore.input(id: id)
        return final?.status == .queued
    }

    // MARK: - Cancellation and termination

    func cancelAndWait(timeout: TimeInterval) async -> FloeMacSelfCancelReceipt {
        let requestedAt = Date()
        // Immediate process-local stop intent. The durable write below is
        // attempted before any wait; a failure keeps the admission unknown.
        _ = fence.recordStopIntent()

        if runFinished {
            return FloeMacSelfCancelReceipt(
                runID: identity.runID,
                requestedAt: requestedAt,
                status: terminalReceipt?.confirmed == true ? .alreadyTerminal : .terminalUnconfirmed,
                terminal: terminalReceipt
            )
        }
        guard !tornDown else {
            return FloeMacSelfCancelReceipt(
                runID: identity.runID,
                requestedAt: requestedAt,
                status: .terminalUnconfirmed,
                terminal: terminalReceipt
            )
        }
        if phase == .launched || phase == .running {
            phase = .cancelling
        }

        _ = try? await admissions.recordStopIntent(
            conversationID: identity.conversationID,
            runID: identity.runID,
            epoch: admissionEpoch
        )
        if runFinished {
            return FloeMacSelfCancelReceipt(
                runID: identity.runID,
                requestedAt: requestedAt,
                status: terminalReceipt?.confirmed == true ? .alreadyTerminal : .terminalUnconfirmed,
                terminal: terminalReceipt
            )
        }

        if !fence.dispatchHasStarted {
            // The run task may not have observed the stop yet. Give it a
            // bounded chance to record the proven no-dispatch settlement.
            let settled = await waitForRunFinished(timeout: min(2, max(0.5, timeout)))
            if settled, let receipt = terminalReceipt {
                return FloeMacSelfCancelReceipt(
                    runID: identity.runID,
                    requestedAt: requestedAt,
                    status: receipt.confirmed ? .stopped : .terminalUnconfirmed,
                    terminal: receipt
                )
            }
            return FloeMacSelfCancelReceipt(
                runID: identity.runID,
                requestedAt: requestedAt,
                status: .runtimeNotStarted,
                terminal: terminalReceipt
            )
        }

        // Dispatch may have begun. The runtime owns the real cancellation;
        // do not hold this actor across it. A timeout means UNKNOWN, never
        // "not started" or "cancelled".
        // Dispatch is marked immediately before `startPrepared`, but that
        // method may still be seeding context while the underlying runtime is
        // idle. A one-shot cancel in this window is ignored by the runtime and
        // would let the later start run indefinitely. Keep driving the real
        // runtime's idempotent cancellation until the supervisor finishes;
        // an unresponsive runtime remains honestly unconfirmed.
        if cancelDriver == nil {
            cancelDriver = Task { [weak self] in
                await self?.driveCancellationUntilFinished()
            }
        }
        let finished = await waitForRunFinished(timeout: max(1, timeout))
        if finished, let receipt = terminalReceipt {
            return FloeMacSelfCancelReceipt(
                runID: identity.runID,
                requestedAt: requestedAt,
                status: receipt.confirmed ? .stopped : .terminalUnconfirmed,
                terminal: receipt
            )
        }
        return FloeMacSelfCancelReceipt(
            runID: identity.runID,
            requestedAt: requestedAt,
            status: .dispatchUnknown,
            terminal: terminalReceipt
        )
    }

    /// The stream supervisor can return while cancellation is still joining
    /// children and saving the parent's checkpoint. Both paths await that
    /// same write before treating the terminal receipt as final.
    private func cancelServiceAndJoin() async {
        if let cancellationAttempt {
            await cancellationAttempt.value
            return
        }
        let attempt = Task { [service] in await service.cancel() }
        cancellationAttempt = attempt
        await attempt.value
        cancellationAttempt = nil
    }

    private func driveCancellationUntilFinished() async {
        while !runFinished && !tornDown && !Task.isCancelled {
            await cancelServiceAndJoin()
            await afterCancellationAttempt?()
            guard !runFinished && !tornDown && !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    func waitForTerminal(timeout: TimeInterval) async -> FloeMacSelfTerminalReceipt? {
        if !runFinished {
            _ = await waitForRunFinished(timeout: timeout)
        }
        return runFinished ? terminalReceipt : nil
    }

    func close(allowUnconfirmed: Bool) async throws -> FloeMacSelfCloseReceipt {
        if let closeTask {
            return try await closeTask.value
        }
        if tornDown {
            return makeCloseReceipt()
        }
        let task = Task { try await self.performClose(allowUnconfirmed: allowUnconfirmed) }
        closeTask = task
        do {
            let receipt = try await task.value
            closeTask = nil
            return receipt
        } catch {
            closeTask = nil
            throw error
        }
    }

    private func performClose(allowUnconfirmed: Bool) async throws -> FloeMacSelfCloseReceipt {
        guard !tornDown else { return makeCloseReceipt() }
        guard runFinished else {
            throw FloeMacSelfCoreError.sessionNotFinished(identity.runID)
        }
        let confirmed = terminalReceipt?.confirmed == true
        // A start failure or an unmatched terminal is not a confirmed close.
        // Releasing process resources requires an explicit unconfirmed opt-in.
        if !confirmed && !allowUnconfirmed {
            throw FloeMacSelfCoreError.terminalNotConfirmed(identity.runID)
        }
        tornDown = true
        phase = .tornDown
        cancelDriver?.cancel()
        cancelDriver = nil
        forwardTask?.cancel()
        forwardTask = nil
        fence.markTornDown()
        channel.finish()
        claims.release(conversationID: identity.conversationID, runID: identity.runID)
        if !confirmed {
            // Process resources only: the durable admission phase/timestamp
            // are preserved for host reconciliation.
            _ = try? await admissions.markProcessReleased(
                conversationID: identity.conversationID,
                runID: identity.runID,
                epoch: admissionEpoch
            )
        }
        return makeCloseReceipt()
    }

    private func makeCloseReceipt() -> FloeMacSelfCloseReceipt {
        let confirmed = terminalReceipt?.confirmed == true
        return FloeMacSelfCloseReceipt(
            runID: identity.runID,
            conversationID: identity.conversationID,
            terminalConfirmed: confirmed,
            durableRunState: terminalReceipt?.durableRunState,
            preservedUnconfirmedRun: !confirmed,
            durableAdmissionRetained: !confirmed
        )
    }

    // MARK: - Durable reads

    func durableRun() async throws -> RunRecord? {
        try await requireLive()
        do {
            return try await runStore.run(id: identity.runID)
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(FloeMacSelfErrorIdentity.render(error))
        }
    }

    func durableMessages(limit: Int) async throws -> [PersistedMessage] {
        try await requireLive()
        let bounded = min(500, max(1, limit))
        do {
            let messages = try await conversationStore.messages(conversationID: identity.conversationID)
            // Exact-run view: prior turns are available through the runtime's
            // conversation archive, not as this session's own messages.
            let runMessages = messages.filter { $0.runID == identity.runID }
            return Array(runMessages.suffix(bounded))
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(FloeMacSelfErrorIdentity.render(error))
        }
    }

    func durableEvents(afterSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        try await requireLive()
        let bounded = min(500, max(1, limit))
        do {
            return try await runStore.events(
                runID: identity.runID,
                afterSequence: max(0, afterSequence),
                limit: bounded
            )
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(FloeMacSelfErrorIdentity.render(error))
        }
    }

    func recoveryPoint() async throws -> AgentCheckpoint? {
        try await requireLive()
        do {
            return try await checkpointStore.load(runID: identity.runID)
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(FloeMacSelfErrorIdentity.render(error))
        }
    }

    private func requireLive() async throws {
        guard !tornDown else {
            throw FloeMacSelfCoreError.sessionTornDown(identity.runID)
        }
        let snapshot = await service.snapshot()
        lastSnapshot = snapshot
    }

    // MARK: - Supervisor completion

    private func finishRun(failure: FloeMacSelfFailure?) async {
        guard !runFinished else { return }
        startFailure = failure
        _ = fence.beginSettlement()
        if fence.isStopRequested && fence.dispatchHasStarted { await cancelServiceAndJoin() }
        lastSnapshot = await service.snapshot()

        let receipt = await probeTerminalWithBoundedRetry(timeout: 1.5)
        terminalReceipt = receipt

        // Same-session recovery, exactly like the iPad restoreQueued contract:
        // once the terminal is strictly confirmed, running guidance this run
        // never consumed returns to the durable queue bound to this
        // conversation (Goal rows keep their original run id) so the host can
        // offer it again. An unconfirmed terminal never rewrites these rows;
        // bootstrap's recoverTransientInputs() is the durable backstop.
        if receipt.confirmed {
            await restoreUnconsumedSteerRows()
        }

        // The settlement write never upgrades an unknown run to confirmed:
        // it only records the already-proven receipt. If it fails, the row
        // stays unresolved and a later admission still re-probes the run.
        _ = try? await admissions.markSettled(
            conversationID: identity.conversationID,
            runID: identity.runID,
            epoch: admissionEpoch,
            confirmed: receipt.confirmed,
            detail: receipt.confirmed
                ? receipt.outcome.rawValue
                : (failure?.code ?? receipt.unconfirmedReason)
        )

        runFinished = true
        cancelDriver?.cancel()
        cancelDriver = nil
        if receipt.confirmed {
            claims.release(conversationID: identity.conversationID, runID: identity.runID)
        }
        phase = (failure != nil && !receipt.confirmed) ? .startFailed : .ended
        fence.settle(confirmed: receipt.confirmed)

        if receipt.confirmed {
            // Give the projection a bounded chance to place the real terminal
            // event before `.ended`. This never affects durable confirmation:
            // the receipt above is already read from SQLite.
            await waitForTerminalProjection(timeout: 0.5)
        }

        if let failure, !receipt.confirmed {
            channel.yield(.startFailed(failure))
        } else {
            channel.yield(.ended(receipt))
        }
        // The durable confirmation above is the fence. The projection task is
        // best-effort and must not block teardown or hold the actor.
        forwardTask?.cancel()
        forwardTask = nil
        channel.finish()
    }

    // MARK: - Waiting helpers (real state only, bounded)

    /// Restores this conversation's steer rows still bound to this run in a
    /// transient state back to `queued` through the existing restoreQueued
    /// contract (which preserves the original run id for Goal-mode rows).
    /// Runs only after a strictly confirmed terminal; a sweep failure never
    /// changes the terminal outcome.
    private func restoreUnconsumedSteerRows() async {
        do {
            let pending = try await runningInputStore.pending(
                conversationID: identity.conversationID
            )
            for row in pending where row.targetRunID == identity.runID
                && row.consumedRunID == nil
                && (row.status == .promoting || row.status == .steerPending) {
                try await runningInputStore.restoreQueued(id: row.id)
            }
        } catch {
            // Best-effort same-session recovery only; the durable admission
            // and terminal receipts above remain the authority.
        }
    }

    /// Re-reads the durable terminal proof for a short bounded window while
    /// the runtime may still be committing its final answer/terminal record.
    /// It never upgrades an unconfirmed receipt beyond what the probe proves;
    /// a stable non-race reason (missing final proof, mismatch) returns at
    /// once instead of waiting.
    private func probeTerminalWithBoundedRetry(timeout: TimeInterval) async -> FloeMacSelfTerminalReceipt {
        let deadline = ContinuousClock.now + .seconds(max(0.2, timeout))
        while true {
            do {
                let receipt = try await admissions.terminalReceipt(
                    conversationID: identity.conversationID,
                    runID: identity.runID,
                    expectedUserMessageID: identity.userMessageID
                )
                if receipt.confirmed {
                    return receipt
                }
                let retryable = receipt.unconfirmedReason == "run_not_terminal"
                    || receipt.unconfirmedReason == "terminal_record_missing"
                guard retryable, ContinuousClock.now < deadline else {
                    return receipt
                }
            } catch {
                return FloeMacSelfTerminalReceipt(
                    runID: identity.runID,
                    conversationID: identity.conversationID,
                    outcome: .unknown,
                    durableRunState: "unknown",
                    durableEndedAt: nil,
                    terminalEventSequence: nil,
                    confirmed: false,
                    unconfirmedReason: "durable_read_failed",
                    finalMessageID: nil,
                    finalMessageVerified: false
                )
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForRunFinished(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0.2, timeout))
        while ContinuousClock.now < deadline {
            if runFinished { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return runFinished
    }

    private func waitForTerminalProjection(timeout: TimeInterval) async {
        let deadline = ContinuousClock.now + .seconds(max(0.05, timeout))
        while terminalObserver.snapshot == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - User questions (owner/run/call fencing)
//
// The session never reimplements question settlement: the durable store's
// CAS transaction remains the only writer. This region only fences a human
// answer against stop/settlement exactly like a steer decision (the same
// decision-token serialization; no fence change), validates the owning
// conversation and run against the session's immutable identity, and maps
// the store's canonical receipts/errors onto the command contract. A late
// answer after settlement receives the original receipt with
// `accepted == false`, so a duplicate tap or a stale card can never settle
// the same question twice.
extension FloeMacSelfSession {

    /// Live runtime wait projection for one question event. The durable
    /// question lives only in the store; `waitingUserQuestion` is the RAM
    /// projection the runtime parks on.
    func setUserQuestionProjection(_ snapshot: UserQuestionWaitingSnapshot) async {
        if snapshot.hasBlockingPending {
            await service.setUserQuestionWait(snapshot)
        } else if await service.snapshot().pendingUserQuestion?.requestID == snapshot.requestID {
            await service.setUserQuestionWait(nil)
        }
    }

    /// Settles one human answer through the durable store. Ownership fencing
    /// is layered: conversation/run here, request/question/run binding plus
    /// the CAS revision inside the store's transaction.
    func resolveQuestion(
        _ command: FloeMacSelfQuestionAnswerCommand
    ) async -> FloeMacSelfQuestionResolution {
        guard !tornDown else { return .rejected(.sessionEnded) }
        guard command.conversationID == identity.conversationID else {
            return .rejected(.conversationMismatch)
        }
        guard command.runID == identity.runID else { return .rejected(.runMismatch) }
        guard questionAnsweringEnabled else { return .rejected(.toolsDisabled) }
        guard let questionCenter else { return .rejected(.sessionEnded) }
        let token = fence.beginSteerDecision()
        do {
            guard let snapshot = try await questionCenter.store.snapshot(requestID: command.requestID) else {
                return .notPending(nil)
            }
            guard snapshot.conversationID == command.conversationID else { return .rejected(.conversationMismatch) }
            guard snapshot.runID == command.runID else { return .rejected(.runMismatch) }
            guard let question = snapshot.questions.first(where: { $0.questionID == command.questionID }) else {
                return .notPending(nil)
            }
            if question.status != .pending {
                return .notPending(UserQuestionAnswerReceipt(target: command.target, status: question.status,
                    revision: question.revision, accepted: false, alreadySettled: true,
                    answer: question.answerRecord(), requestState: snapshot.state))
            }
        } catch {
            return .rejected(.sessionEnded)
        }
        guard let token else { return .rejected(.sessionEnded) }
        guard fence.validateSteerDecision(token), !runFinished, !tornDown else {
            return .rejected(.sessionEnded)
        }

        do {
            let receipt = try await questionCenter.submitHumanAnswer(
                target: command.target,
                answer: command.answer
            )
            if receipt.accepted { return .accepted(receipt) }
            // The store preserved the original settlement; this answer did
            // not settle anything.
            return .notPending(receipt)
        } catch let error as UserQuestionError {
            switch error {
            case .runMismatch:
                return .rejected(.runMismatch)
            case .staleRevision:
                return .rejected(.staleQuestion)
            case .invalidAnswer, .invalidRequest:
                return .rejected(.invalidAnswer)
            case .notFound:
                return .notPending(nil)
            case .missingToolCallID, .missingConversation, .requestConflict,
                 .requestCancelled:
                return .rejected(.sessionEnded)
            }
        } catch {
            return .rejected(.invalidAnswer)
        }
    }

    /// Explicitly cancels one question request owned by this exact run.
    /// Pending questions become cancelled with no answer body; a required
    /// wait returns a cancelled tool receipt to the parked run. Returns false
    /// when the request is unknown or belongs to another run/task.
    func cancelQuestion(requestID: String) async -> Bool {
        guard !tornDown, !runFinished, !fence.isStopRequested,
              let questionCenter, questionAnsweringEnabled else { return false }
        guard let snapshot = try? await questionCenter.store.snapshot(requestID: requestID),
              snapshot.conversationID == identity.conversationID,
              snapshot.runID == identity.runID else { return false }
        guard let token = fence.beginSteerDecision() else { return false }
        guard fence.validateSteerDecision(token), !runFinished, !tornDown else { return false }
        do {
            try await questionCenter.cancelRequest(requestID: requestID)
            return true
        } catch {
            return false
        }
    }
}

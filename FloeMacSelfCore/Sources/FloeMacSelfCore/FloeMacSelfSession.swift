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
    private let runStore: any RunStore
    private let checkpointStore: any CheckpointStore
    private let admissions: FloeMacSelfAdmissionStore
    private let admissionEpoch: Int
    private let claims: FloeMacSelfConversationClaims
    private let fence: FloeMacSelfRunFence
    private let goal: String
    private let toolsEnabled: Bool
    private let boundary: FloeMacSelfTaskBoundary?
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
        verifyPreparedInput: @escaping @Sendable (PersistedMessage) throws -> Void,
        verifyWorkspaceLease: (@Sendable () async throws -> Void)? = nil,
        eventBufferLimit: Int,
        beforeInputRecheck: (@Sendable () async -> Void)? = nil,
        beforeServiceStart: (@Sendable () async -> Void)? = nil,
        afterCancellationAttempt: (@Sendable () async -> Void)? = nil
    ) {
        self.identity = identity
        self.service = service
        self.conversationStore = conversationStore
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
        self.verifyPreparedInput = verifyPreparedInput
        self.verifyWorkspaceLease = verifyWorkspaceLease
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
            try await service.startPrepared(goal: goal, userMessageID: identity.userMessageID)
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

    private func driveCancellationUntilFinished() async {
        while !runFinished && !tornDown && !Task.isCancelled {
            await service.cancel()
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
        lastSnapshot = await service.snapshot()

        let receipt = await probeTerminalWithBoundedRetry(timeout: 1.5)
        terminalReceipt = receipt

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

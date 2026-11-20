// SPDX-License-Identifier: MPL-2.0
//
// One short-lived, single-writer fence per admitted run.
//
// The fence is process-local and deliberately holds its lock only for a few
// instructions. It is NOT held across `ConversationRunService.startPrepared`
// or any database/file await. Its jobs are:
//   * serialize admission/dispatch/settlement transitions for this exact run;
//   * record stop intent immediately (before the durable write and before any
//     wait), so a start cannot be admitted after a stop;
//   * prevent approvals from being forwarded after stop/settlement;
//   * distinguish "never dispatched" from "dispatch may have begun" for
//     cancellation and crash classification.
//
// Cross-process truth is the durable admission row; this fence never replaces
// it and never releases it.

import Foundation

/// Immutable task epoch carried into side-effecting tool execution. It binds
/// the tool wrapper to one exact durable admission attempt, not just to a
/// process or a conversation.
public struct FloeMacSelfTaskEpoch: Sendable, Hashable {
    public let conversationID: UUID
    public let runID: UUID
    public let admissionEpoch: UInt64

    public init(conversationID: UUID, runID: UUID, admissionEpoch: UInt64) {
        self.conversationID = conversationID
        self.runID = runID
        self.admissionEpoch = admissionEpoch
    }
}

enum FloeMacSelfFencePhase: String, Sendable, Hashable {
    case admitting
    case prepared
    case dispatching
    case settling
    case settled
    case tornDown
}

struct FloeMacSelfFenceSnapshot: Sendable, Hashable {
    let phase: FloeMacSelfFencePhase
    let dispatchStarted: Bool
    let stopRequested: Bool
    let stopEpoch: UInt64
    let settled: Bool
}

struct FloeMacSelfDecisionToken: Sendable, Hashable {
    let stopEpoch: UInt64
}

final class FloeMacSelfRunFence: @unchecked Sendable {
    let taskEpoch: FloeMacSelfTaskEpoch

    private let mutex = NSLock()
    private var phase: FloeMacSelfFencePhase = .admitting
    private var stopRequestedAt: Date?
    private var stopEpoch: UInt64 = 0
    private var dispatchStarted = false
    private var settled = false

    init(taskEpoch: FloeMacSelfTaskEpoch) {
        self.taskEpoch = taskEpoch
    }

    /// admitting -> prepared after the durable prepared CAS succeeded.
    @discardableResult
    func markPrepared() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard phase == .admitting, !settled else { return false }
        phase = .prepared
        return true
    }

    /// Checks stop/phase before the durable `starting` write. It does not
    /// mark dispatch yet.
    func prepareDispatch() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard phase == .prepared, !settled, stopRequestedAt == nil else { return false }
        return true
    }

    /// Marks that the start call is about to be invoked. This must be the last
    /// synchronous step before `startPrepared`. A refused commit means no
    /// dispatch may occur.
    func commitDispatch() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard phase == .prepared, !settled, stopRequestedAt == nil, !dispatchStarted else {
            return false
        }
        dispatchStarted = true
        phase = .dispatching
        return true
    }

    /// Blocks new approvals before the durable terminal probe/settlement.
    @discardableResult
    func beginSettlement() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard !settled, phase != .tornDown else { return false }
        phase = .settling
        return true
    }

    /// Records stop intent synchronously. The epoch increases on every call;
    /// the first timestamp is retained for diagnostics. It never clears a
    /// claim and never marks dispatch as having begun.
    @discardableResult
    func recordStopIntent() -> UInt64 {
        mutex.lock()
        defer { mutex.unlock() }
        if stopRequestedAt == nil {
            stopRequestedAt = Date()
        }
        stopEpoch &+= 1
        return stopEpoch
    }

    func settle(confirmed: Bool) {
        mutex.lock()
        defer { mutex.unlock() }
        _ = confirmed
        settled = true
        phase = .settled
    }

    func markTornDown() {
        mutex.lock()
        defer { mutex.unlock() }
        phase = .tornDown
    }

    var isStopRequested: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return stopRequestedAt != nil || settled || phase == .tornDown
    }

    var dispatchHasStarted: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return dispatchStarted
    }

    var snapshot: FloeMacSelfFenceSnapshot {
        mutex.lock()
        defer { mutex.unlock() }
        return FloeMacSelfFenceSnapshot(
            phase: phase,
            dispatchStarted: dispatchStarted,
            stopRequested: stopRequestedAt != nil,
            stopEpoch: stopEpoch,
            settled: settled
        )
    }

    /// A side-effecting tool may execute only while this exact admitted run is
    /// dispatching and has no recorded stop. This is the actual task-epoch /
    /// stop gate used by the executor wrapper.
    var permitsSideEffectExecution: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return phase == .dispatching
            && dispatchStarted
            && !settled
            && stopRequestedAt == nil
    }

    func beginApprovalDecision() -> FloeMacSelfDecisionToken? {
        mutex.lock()
        defer { mutex.unlock() }
        guard phase == .dispatching, dispatchStarted, !settled, stopRequestedAt == nil else {
            return nil
        }
        return FloeMacSelfDecisionToken(stopEpoch: stopEpoch)
    }

    /// Opens a running-steer submission with the same guarantees as an
    /// approval decision: only a dispatched, unsettled, un-stopped run may
    /// accept guidance, and a stop recorded during the store awaits below
    /// invalidates the token before anything reaches the runtime.
    func beginSteerDecision() -> FloeMacSelfDecisionToken? {
        mutex.lock()
        defer { mutex.unlock() }
        guard phase == .dispatching, dispatchStarted, !settled, stopRequestedAt == nil else {
            return nil
        }
        return FloeMacSelfDecisionToken(stopEpoch: stopEpoch)
    }

    /// Revalidates immediately before forwarding a steer. Mirrors
    /// `validateApprovalDecision` for running guidance.
    func validateSteerDecision(_ token: FloeMacSelfDecisionToken) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return phase == .dispatching
            && dispatchStarted
            && !settled
            && stopRequestedAt == nil
            && stopEpoch == token.stopEpoch
    }

    /// Revalidates immediately before forwarding an approval. A stop that was
    /// recorded during an await invalidates the token.
    func validateApprovalDecision(_ token: FloeMacSelfDecisionToken) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return phase == .dispatching
            && dispatchStarted
            && !settled
            && stopRequestedAt == nil
            && stopEpoch == token.stopEpoch
    }

    /// True only when the supplied epoch is this fence's exact admitted task
    /// epoch. Stale wrappers are denied.
    func isCurrentEpoch(_ epoch: FloeMacSelfTaskEpoch) -> Bool {
        epoch == taskEpoch
    }
}

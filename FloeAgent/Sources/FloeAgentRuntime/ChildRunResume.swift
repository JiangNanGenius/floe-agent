// FloeAgentRuntime — durable child checkpoint resume (S7 audit17).
//
// This is TRUE independent child continuation: an interrupted delegated
// child resumes from a bounded, legal-JSON checkpoint of its real loop
// state — actual provider continuation messages, archived replay pairs,
// child-local discovery/skill revisions, truncation counters and the ACTUAL
// spent budget — under an ACTIVE, authorized CURRENT parent run. It is not a
// transcript view and not an interrupted→running state flip:
//
//   * Same child identity: the child run row, its parent relation and the
//     ORIGINAL historical parentRunID are never rewritten. The resumed
//     invocation carries a fresh `ChildExecutionIdentity` whose parentRunID
//     binds the ACTUAL current authorized parent run (structurally enforced:
//     the resumed context only holds the current parent's canonical
//     dispatcher, and `AgentRuntime.dispatchChildTool` refuses any identity
//     whose parentRunID is not its own runID — never "the newest run").
//   * Rights revalidated, never inherited: effective rights, environment,
//     model and available tools are re-derived from the CURRENT parent's
//     live configuration and intersected with the persisted child state at
//     resume. No rights are added; secrets and grants are never persisted.
//   * Budget continuity: the original ABSOLUTE ceiling and the spent total
//     survive process death; a resume continues inside the original
//     allowance and charges the CURRENT parent run's shared budget ledger —
//     never a fresh 20-turn ceiling per resume.
//   * Unknown in-flight mutating calls: durable real results feed back when
//     they exist; otherwise an explicit recovery hold with a truthful,
//     actionable result — NEVER a blind replay.
//   * Lease/CAS: exactly one resumer wins; finished children are refused;
//     cancellation restores the honest interrupted state; a crash mid-resume
//     converges through lease expiry plus launch reconciliation.
//
// Ownership: `ChildResumeService` owns validation + the durable lease. The
// `SubagentRunner` owns seeding/execution. `AgentRuntime` owns the
// parent-side glue (budget mint + context build) so the resumed child is
// charged to the actual current parent run.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

/// Truthful resume refusal reasons. Every case is user/parent-actionable.
public enum ChildResumeError: Error, Sendable, Equatable, LocalizedError {
    /// No durable child record with this id.
    case childNotFound
    case invalidCheckpoint
    case recoveryHeld
    /// The child is not in `.interrupted` — a finished (or never-run) child
    /// never restarts.
    case childNotResumable(state: ChildRunState)
    /// The interrupted child has no durable checkpoint to continue from.
    case noCheckpoint
    /// The persisted checkpoint predates the supported shape; it is refused,
    /// never guessed.
    case unsupportedRevision(found: Int, supported: Int)
    /// Another caller holds the live resume lease.
    case leaseHeldByOther
    /// The child belongs to a different conversation than the CURRENT
    /// parent's: cross-conversation resume is refused.
    case crossConversationResume
    /// The original allowance is fully spent; resuming would mint fresh
    /// budget, which this contract never does.
    case budgetAlreadyExhausted(spent: Int, ceiling: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCheckpoint:
            return "The child's saved continuation is inconsistent; it was retained for recovery."
        case .recoveryHeld:
            return "A previous write has an unknown result. Check its outcome before continuing this subagent."
        case .childNotFound:
            return "No durable child run exists with this identifier."
        case .childNotResumable(let state):
            return "This child is '\(state.rawValue)'; only an interrupted child can be resumed, and a finished child never restarts."
        case .noCheckpoint:
            return "This interrupted child has no durable checkpoint; its exact state is unknown, so it cannot be continued safely."
        case .unsupportedRevision(let found, let supported):
            return "This child's checkpoint uses revision \(found), which this build cannot resume (supported: \(supported))."
        case .leaseHeldByOther:
            return "Another run is already resuming this child; concurrent resumes converge on the first lease holder."
        case .crossConversationResume:
            return "This child belongs to a different task; a child can only resume under a current parent of its own conversation."
        case .budgetAlreadyExhausted(let spent, let ceiling):
            return "The child's original allowance is fully spent (\(spent)/\(ceiling) iterations before the interruption); resuming would mint fresh budget."
        }
    }
}

/// A validated, lease-backed resume plan. Built ONLY by
/// `ChildResumeService.begin` after every authority check passed; the runner
/// consumes it verbatim and never re-interprets its fields.
public struct ChildResumePlan: Sendable {
    /// Same child id as the original run — the durable identity continues.
    public var childID: UUID
    /// The ORIGINAL durable record (state `.interrupted`, original
    /// parentRunID). Never mutated here.
    public var record: ChildRunRecord
    /// The bounded loop-state snapshot to continue from.
    public var checkpoint: ChildRunCheckpoint
    /// This resume's lease owner token; settles via finish/cancel only.
    public var ownerToken: UUID
    /// The resumed invocation identity: same childID, parentRunID bound to
    /// the ACTUAL current authorized parent run, runtime-minted
    /// `delegateCallID = resume-<owner>` so it can never be confused with the
    /// original delegate call.
    public var resumedIdentity: ChildExecutionIdentity
    /// The rebuilt request (original task/context/kind, current parent run).
    public var request: SubagentRequest
    /// 1-based ordinal of this resume (mirror of the CAS column).
    public var resumeOrdinal: Int
    public var leaseExpiresAt: Date
    /// Remaining iterations inside the ORIGINAL allowance (ceiling − spent).
    /// The parent runtime mints the fresh child budget with exactly this
    /// maximum, so the shared ledger intersects the original ceiling.
    public var remainingIterations: Int

    public init(
        childID: UUID,
        record: ChildRunRecord,
        checkpoint: ChildRunCheckpoint,
        ownerToken: UUID,
        resumedIdentity: ChildExecutionIdentity,
        request: SubagentRequest,
        resumeOrdinal: Int,
        leaseExpiresAt: Date,
        remainingIterations: Int
    ) {
        self.childID = childID
        self.record = record
        self.checkpoint = checkpoint
        self.ownerToken = ownerToken
        self.resumedIdentity = resumedIdentity
        self.request = request
        self.resumeOrdinal = resumeOrdinal
        self.leaseExpiresAt = leaseExpiresAt
        self.remainingIterations = remainingIterations
    }
}

public enum ChildResumeAvailability: String, Sendable, Equatable {
    case available, recoveryHeld, budgetExhausted, unavailable
}

/// Validation + durable lease ownership for child resume. The store decides
/// every transition compare-and-swap; this actor only sequences checks and
/// builds the plan, so a plan in hand implies every gate below passed:
///
///   1. the child exists and belongs to the CURRENT parent's conversation
///      (cross-conversation resume is refused);
///   2. the child is `.interrupted` — finished-child refusal;
///   3. a checkpoint exists and its schema revision is supported;
///   4. the original allowance is not fully spent (no fresh budget per
///      resume);
///   5. the durable lease CAS granted THIS caller the resume.
public actor ChildResumeService {
    private let store: any ChildRunStoring & ChildRunCheckpointStoring
    private let leaseDuration: TimeInterval

    public init(
        store: any ChildRunStoring & ChildRunCheckpointStoring,
        leaseDuration: TimeInterval = 30 * 60
    ) {
        self.store = store
        self.leaseDuration = max(60, leaseDuration)
    }

    /// Begins one resume under the CURRENT authorized parent run. The
    /// caller proves parenthood by passing its own runID/conversationID; the
    /// durable identity minted here binds those exact values and the
    /// canonical dispatcher structurally enforces them at dispatch time.
    public func begin(
        childID: UUID,
        currentParentRunID: UUID,
        currentParentConversationID: UUID
    ) async throws -> ChildResumePlan {
        guard let record = try await store.child(id: childID) else {
            throw ChildResumeError.childNotFound
        }
        guard record.conversationID == currentParentConversationID else {
            throw ChildResumeError.crossConversationResume
        }
        guard record.state == .interrupted else {
            throw ChildResumeError.childNotResumable(state: record.state)
        }
        guard let checkpoint = try await store.checkpoint(childRunID: childID) else {
            throw ChildResumeError.noCheckpoint
        }
        guard checkpoint.schemaRevision == ChildRunCheckpoint.currentSchemaRevision else {
            throw ChildResumeError.unsupportedRevision(
                found: checkpoint.schemaRevision,
                supported: ChildRunCheckpoint.currentSchemaRevision
            )
        }
        guard checkpoint.childID == record.id,
              checkpoint.conversationID == record.conversationID,
              checkpoint.rootRunID == record.rootRunID,
              checkpoint.originalParentRunID == record.parentRunID,
              (1...20).contains(checkpoint.hardCeiling),
              (0...checkpoint.hardCeiling).contains(checkpoint.iterationsUsed),
              let kind = SubagentRequest.Kind(rawValue: checkpoint.requestKind) else {
            throw ChildResumeError.invalidCheckpoint
        }
        let pending = checkpoint.pendingCalls + checkpoint.pendingSettled.map(\.call)
        guard pending.allSatisfy({ !$0.id.isEmpty && !$0.toolName.isEmpty && SubagentRunner.rebuiltCall($0) != nil }),
              checkpoint.pendingSettled.allSatisfy({ $0.call.id == $0.result.callID }),
              Set(checkpoint.pendingCalls.map(\.id)).count == checkpoint.pendingCalls.count,
              Set(checkpoint.pendingSettled.map { $0.call.id }).count == checkpoint.pendingSettled.count else {
            throw ChildResumeError.invalidCheckpoint
        }
        guard checkpoint.recoveryHoldCallIDs.isEmpty else { throw ChildResumeError.recoveryHeld }
        let remaining = checkpoint.hardCeiling - checkpoint.iterationsUsed
        guard remaining > 0 else {
            throw ChildResumeError.budgetAlreadyExhausted(
                spent: checkpoint.iterationsUsed,
                ceiling: checkpoint.hardCeiling
            )
        }
        let owner = UUID()
        let leaseExpiresAt = Date().addingTimeInterval(leaseDuration)
        let acquired = try await store.acquireResume(
            childRunID: childID,
            owner: owner,
            resumingParentRunID: currentParentRunID,
            leaseExpiresAt: leaseExpiresAt,
            expectedCheckpoint: checkpoint
        )
        guard acquired else {
            throw ChildResumeError.leaseHeldByOther
        }
        // Runtime-minted resumed identity: same child, ACTUAL current parent.
        // The delegateCallID is a fresh runtime value (resume-<owner>) — the
        // original delegate call mapping on the record/relation is untouched.
        let resumedIdentity = ChildExecutionIdentity(
            childID: childID,
            parentRunID: currentParentRunID,
            rootTaskID: record.rootRunID,
            delegateCallID: "resume-\(owner.uuidString)",
            depth: 1,
            startedAt: record.startedAt
        )
        return ChildResumePlan(
            childID: childID,
            record: record,
            checkpoint: checkpoint,
            ownerToken: owner,
            resumedIdentity: resumedIdentity,
            request: SubagentRequest(
                task: checkpoint.task,
                context: checkpoint.context,
                maxIterations: checkpoint.hardCeiling,
                kind: kind,
                runID: currentParentRunID
            ),
            resumeOrdinal: checkpoint.resumeCount + 1,
            leaseExpiresAt: leaseExpiresAt,
            remainingIterations: remaining
        )
    }

    /// Releases the lease WITHOUT starting the resumed run; the child returns
    /// to the honest `.interrupted` state and stays resumable.
    public func cancel(
        childID: UUID,
        ownerToken: UUID
    ) async throws {
        try await store.cancelResume(childRunID: childID, owner: ownerToken)
    }

    public func availability(childID: UUID) async throws -> ChildResumeAvailability {
        guard let record = try await store.child(id: childID), record.state == .interrupted,
              let checkpoint = try await store.checkpoint(childRunID: childID),
              checkpoint.schemaRevision == ChildRunCheckpoint.currentSchemaRevision,
              checkpoint.childID == record.id, checkpoint.conversationID == record.conversationID,
              checkpoint.originalParentRunID == record.parentRunID, checkpoint.rootRunID == record.rootRunID,
              (1...20).contains(checkpoint.hardCeiling), checkpoint.iterationsUsed >= 0 else { return .unavailable }
        if !checkpoint.recoveryHoldCallIDs.isEmpty { return .recoveryHeld }
        if checkpoint.iterationsUsed >= checkpoint.hardCeiling { return .budgetExhausted }
        return .available
    }

    /// Interrupted children of one conversation that carry a durable
    /// checkpoint — the UI's truthful resume candidate list. A candidate can
    /// still be refused by `begin` (lease held, budget spent); listing is
    /// never a promise.
    public func resumableChildren(conversationID: UUID) async throws -> [ChildRunRecord] {
        let interrupted = try await store.children(conversationID: conversationID)
            .filter { $0.state == .interrupted }
        var candidates: [ChildRunRecord] = []
        for record in interrupted where try await store.checkpoint(childRunID: record.id) != nil {
            candidates.append(record)
        }
        return candidates
    }
}

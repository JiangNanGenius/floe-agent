// FloeAgentRuntime — bounded policy + ranking + rendering for execution
// experience. The runtime's existing durable lifecycle stays authoritative:
// this file READS settled receipt facts (via the bridge below) and derives
// data-minimal `ExecutionExperienceRecord` values. It never grants,
// replaces or bypasses the tool catalog, task scope, environment binding,
// approval, `ActionClaimGate`, `TaskClosureGate` or the execution ledger,
// and it is never fed from assistant-authored text.
//
// Relevance model: `availableToolNames` is typically the whole enabled
// catalog and can NEVER make an old procedure relevant by itself. Recall
// additionally requires the CURRENT task's activated/matched tool family
// (`activatedToolNames`) to overlap the procedure above a bounded ratio,
// and a recall without any activation signal fails closed.
//
// Sealing model: `sealedOutputEvidence` is only ever raised from verdicts
// the caller supplies AFTER an actual native receipt passed integrity
// verification (sealed run-output/artifact digest re-check, or a retained
// capture receipt). The mere presence of an `artifactRefsJSON` field in a
// payload is not, and never will be, sealing evidence.
//
// Authority model for recall: rendered guidance is explicitly lower-authority
// historical context. It is advisory and ignorable, may be superseded by any
// current policy, and must never cause a replay of old arguments, ids, paths
// or values. Every future tool call still passes the ordinary current checks.

import Foundation
import FloeCore
import FloeModels

// MARK: - Recall context

/// The current-origin context a recall happens in. Both tool sets come from
/// the LIVE catalog/discovery and the current task's activation, never from
/// experience rows. `activatedToolNames` empty ⇒ nothing may be recalled.
public struct ExecutionExperienceRecallContext: Sendable {
    public var workspaceID: UUID?
    public var availableToolNames: Set<String>
    public var activatedToolNames: Set<String>
    public var now: Date

    public init(
        workspaceID: UUID?,
        availableToolNames: Set<String>,
        activatedToolNames: Set<String>,
        now: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.availableToolNames = availableToolNames
        self.activatedToolNames = activatedToolNames
        self.now = now
    }
}

// MARK: - Policy

public struct ExecutionExperiencePolicy: Sendable {
    public struct Bounds: Sendable, Equatable {
        /// Maximum steps accepted in one ingestion observation (input gate).
        public var maximumStepsPerObservation: Int
        /// Maximum procedure steps retained in one persisted record.
        public var maximumRetainedProcedureSteps: Int
        /// Completed steps required before any record is derived. A lone
        /// settled call is not a workflow.
        public var minimumSettledSteps: Int
        public var maximumRecoveryPatterns: Int
        public var recallMaxRecords: Int
        public var recallCharacterBudget: Int
        public var recallMaxAge: TimeInterval
        public var retentionInterval: TimeInterval
        /// Minimum fraction of a procedure's step tools that the current
        /// task must have activated for the record to be considered
        /// relevant. Below this, even fully-available procedures stay out.
        public var activationMinimumOverlapRatio: Double

        public static let standard = Bounds(
            maximumStepsPerObservation: ExecutionExperienceLimits.maximumStepsPerObservation,
            maximumRetainedProcedureSteps: ExecutionExperienceLimits.maximumRetainedProcedureSteps,
            minimumSettledSteps: ExecutionExperienceLimits.minimumSettledSteps,
            maximumRecoveryPatterns: ExecutionExperienceLimits.maximumRecoveryPatterns,
            recallMaxRecords: ExecutionExperienceLimits.recallDefaultMaxRecords,
            recallCharacterBudget: ExecutionExperienceLimits.recallCharacterBudget,
            recallMaxAge: 90 * 86_400,
            retentionInterval: 180 * 86_400,
            activationMinimumOverlapRatio: 0.5
        )

        public init(
            maximumStepsPerObservation: Int,
            maximumRetainedProcedureSteps: Int,
            minimumSettledSteps: Int,
            maximumRecoveryPatterns: Int,
            recallMaxRecords: Int,
            recallCharacterBudget: Int,
            recallMaxAge: TimeInterval,
            retentionInterval: TimeInterval,
            activationMinimumOverlapRatio: Double = 0.5
        ) {
            self.maximumRetainedProcedureSteps = max(minimumSettledSteps,
                min(maximumRetainedProcedureSteps,
                    ExecutionExperienceLimits.maximumRetainedProcedureSteps))
            self.maximumStepsPerObservation = max(self.maximumRetainedProcedureSteps,
                min(maximumStepsPerObservation,
                    ExecutionExperienceLimits.maximumStepsPerObservation))
            self.minimumSettledSteps = max(1, min(minimumSettledSteps, self.maximumRetainedProcedureSteps))
            self.maximumRecoveryPatterns = max(1, min(maximumRecoveryPatterns,
                ExecutionExperienceLimits.maximumRecoveryPatterns))
            self.recallMaxRecords = max(1, min(recallMaxRecords, 8))
            self.recallCharacterBudget = max(200, min(recallCharacterBudget,
                ExecutionExperienceLimits.recallCharacterBudget))
            self.recallMaxAge = max(86_400, min(recallMaxAge, 365 * 86_400))
            self.retentionInterval = max(self.recallMaxAge, min(retentionInterval, 365 * 86_400))
            // Fail closed rather than admit a zero/absurd threshold.
            self.activationMinimumOverlapRatio = min(max(activationMinimumOverlapRatio, 0.5), 1.0)
        }
    }

    public let bounds: Bounds

    public init(bounds: Bounds = .standard) { self.bounds = bounds }

    public static let standard = ExecutionExperiencePolicy()

    // MARK: Bridge from native settled receipts

    /// Deterministic outcome resolution for the collector.
    ///
    /// Inputs are ONLY the flat persisted lifecycle facts described in
    /// `ConversationRunService`'s `toolResult` boundary (tool, id, status,
    /// dispatched, the `ToolOutcomeClassification` kind when present).
    /// A `pending` request never reaches this bridge.
    ///
    /// Promotion rule (conservative, rejection-biased): `.completed` ONLY
    /// when the settled status is `"ok"`, the call was actually dispatched
    /// AND the native classification explicitly says `completed`. A missing
    /// or unparseable classification NEVER yields `.completed` — an untyped
    /// "ok" demotes to `.partial` (incomplete evidence). A `completed`
    /// classification contradicted by a `failed` (or any non-ok) status is
    /// a contradictory completion claim and demotes to `.partial`.
    /// waiting/partial/denied/cancelled/noProgress classifications can never
    /// be raised, and a non-dispatched result cannot be completion evidence.
    public static func outcomeKind(
        statusRaw: String,
        classificationKindRaw: String?,
        dispatched: Bool
    ) -> ExecutionOutcomeKind {
        guard let raw = classificationKindRaw,
              let typed = ExecutionOutcomeKind(rawValue: raw) else {
            // Missing/unparseable typed classification: no completion truth.
            switch statusRaw {
            case "ok": return .partial
            case "failed": return .failed
            case "denied": return .denied
            case "expired": return .waitingForResource
            case "cancelled": return .cancelled
            case "needsUser": return .waitingForUser
            default: return .partial
            }
        }
        if typed.isCompleted {
            guard statusRaw == "ok", dispatched else {
                // Contradictory or un-dispatched completion claim: demoted.
                return .partial
            }
            return .completed
        }
        // Any non-completed classification stands as-is; status raw can
        // make it more pessimistic but never raises it.
        return typed
    }

    // MARK: Derivation

    /// Purely native; no provider call. Throws `validationFailed` for any
    /// input that could smuggle content, authority or inconsistent
    /// receipts, so a collector bug can never write a record.
    ///
    /// `scopeChoice` is the caller's EXPLICIT attestation and is never
    /// inferred. `.workspace` requires the observation's real workspace
    /// binding (the exact original; faking "no workspace" to switch scope
    /// is not possible — the binding rides on the observation itself).
    /// `.generic` asserts that only the minimised tool/outcome/order/
    /// recovery structure is the reusable value; the originating workspace
    /// UUID is still kept on the record as an opaque evidence locator so
    /// workspace deletion can clear it.
    ///
    /// `sealedVerifiedCallIDs` may contain ONLY call ids for which the
    /// caller actually verified a native sealed run-output/artifact receipt
    /// (digest re-check or retained capture receipt). Unknown call ids, or
    /// sealed verdicts on non-completed steps, are rejected outright.
    public func derive(
        _ observation: ExecutionSequenceObservation,
        scopeChoice: ExecutionExperienceScopeChoice,
        sealedVerifiedCallIDs: Set<String> = []
    ) throws -> ExecutionExperienceRecord {
        if let issue = observation.structuralValidationIssue() {
            throw FloeError.validationFailed(issue)
        }
        if observation.steps.count > bounds.maximumStepsPerObservation {
            throw FloeError.validationFailed("Experience observation exceeds the bounded ingestion window")
        }
        for step in observation.steps {
            if let issue = step.structuralValidationIssue() {
                throw FloeError.validationFailed(issue)
            }
        }
        let observationCallIDs = Set(observation.steps.map(\.callID))
        guard sealedVerifiedCallIDs.isSubset(of: observationCallIDs) else {
            throw FloeError.validationFailed(
                "Sealed verdict names a call id outside the settled observation"
            )
        }
        let completedSteps = observation.steps.filter { $0.outcome.isCompleted }
        guard completedSteps.count >= bounds.minimumSettledSteps else {
            throw FloeError.validationFailed(
                "No settled completed receipt: nothing reusable may be derived"
            )
        }
        for callID in sealedVerifiedCallIDs.sorted() {
            guard let step = observation.steps.first(where: { $0.callID == callID }),
                  step.outcome.isCompleted else {
                throw FloeError.validationFailed(
                    "Sealed verdict on a non-completed step"
                )
            }
        }

        // Group completed steps by ATTESTED order. Consecutive steps whose
        // boundary is unattested (parallel batch) are canonically sorted
        // within the group instead of pretending a required sequence.
        var groups: [[ExecutionStepObservation]] = []
        var current: [ExecutionStepObservation] = []
        for (index, step) in completedSteps.enumerated() {
            current.append(step)
            let isLast = index == completedSteps.count - 1
            let attestedToNext = step.orderAttestedBeforeNext
            if isLast || attestedToNext {
                groups.append(current)
                current = []
            }
        }
        // Flatten the groups, carrying each step's TRUE group id so the
        // record and renderer never collapse a parallel batch into a
        // required order. Within a multi-member group (boundaries were NOT
        // attested) steps are canonically sorted; across groups the
        // happens-before order IS attested, so group order is preserved.
        var orderedCompleted: [(step: ExecutionStepObservation, groupId: Int)] = []
        for (groupId, group) in groups.enumerated() {
            let sorted: [ExecutionStepObservation]
            if group.count == 1 {
                sorted = group
            } else {
                sorted = group.sorted { lhs, rhs in
                    if lhs.toolName != rhs.toolName { return lhs.toolName < rhs.toolName }
                    return lhs.callID < rhs.callID
                }
            }
            for step in sorted {
                orderedCompleted.append((step, groupId))
            }
        }

        // Roles are derived from data, not from curated domain lists:
        // steps before the first sealed-output step are observed
        // prerequisites, the first sealed-output step is primary, and any
        // later completed step is treated as verification-shaped. Without
        // any sealed verdict, every completed step is primary.
        func sealed(_ step: ExecutionStepObservation) -> Bool {
            sealedVerifiedCallIDs.contains(step.callID)
        }
        let sealedIndex = orderedCompleted.firstIndex { sealed($0.step) }
        var procedureSteps: [ExecutionProcedureStep] = []
        procedureSteps.reserveCapacity(orderedCompleted.count)
        for (index, entry) in orderedCompleted.enumerated() {
            let role: ExecutionStepRole
            if let sealedIndex {
                if index < sealedIndex { role = .prerequisite }
                else if index == sealedIndex { role = .primary }
                else { role = .verification }
            } else {
                role = .primary
            }
            procedureSteps.append(ExecutionProcedureStep(
                toolName: entry.step.toolName,
                outcome: entry.step.outcome,
                role: role,
                producesSealedOutput: sealed(entry.step),
                groupId: entry.groupId
            ))
        }

        // Deterministic compression when the bound is exceeded: keep the
        // leading prerequisite window and the trailing completed window.
        if procedureSteps.count > bounds.maximumRetainedProcedureSteps {
            let lead = ExecutionExperienceLimits.retainedProcedureLeadCount
            let tail = bounds.maximumRetainedProcedureSteps - lead
            var compressed = Array(procedureSteps.prefix(lead))
            compressed.append(contentsOf: procedureSteps.suffix(tail))
            procedureSteps = compressed
        }
        // Compression can skip entire original groups. Preserve each
        // retained parallel group and its proven ordering, while renumbering
        // the surviving groups contiguously for the persisted contract.
        var retainedGroups: [Int: Int] = [:]
        for index in procedureSteps.indices {
            let originalGroup = procedureSteps[index].groupId
            let group = retainedGroups[originalGroup] ?? retainedGroups.count
            retainedGroups[originalGroup] = group
            procedureSteps[index].groupId = group
        }

        // Recovery patterns: every terminal failure/partial observation is
        // kept honestly. A failure is only marked "resolved" when the SAME
        // tool succeeded LATER with an ATTESTED happens-before chain from
        // the failing step to that success (every intermediate boundary's
        // `orderAttestedBeforeNext` is true). A parallel batch member or an
        // unrelated later success in the array is NOT recovery evidence;
        // the failure stays unresolved in that case.
        var recoveryPatterns: [ExecutionRecoveryPattern] = []
        var recovered = 0
        for (index, step) in observation.steps.enumerated()
            where step.outcome.isFailureLike || step.outcome.isPartialLike {
            var attested = step.orderAttestedBeforeNext
            var resolvedWithTool: String? = nil
            var candidate = index + 1
            while candidate < observation.steps.count {
                if attested && observation.steps[candidate].toolName == step.toolName
                    && observation.steps[candidate].outcome.isCompleted {
                    resolvedWithTool = observation.steps[candidate].toolName
                    break
                }
                attested = attested && observation.steps[candidate].orderAttestedBeforeNext
                candidate += 1
            }
            let pattern = ExecutionRecoveryPattern(
                failingTool: step.toolName,
                failureKind: step.outcome,
                recovery: step.recovery,
                resolvedWithTool: resolvedWithTool
            )
            if pattern.isResolved { recovered += 1 }
            recoveryPatterns.append(pattern)
        }
        if recoveryPatterns.count > bounds.maximumRecoveryPatterns {
            recoveryPatterns.sort { lhs, rhs in
                if lhs.isResolved != rhs.isResolved { return lhs.isResolved }
                let leftKey = lhs.failingTool + lhs.failureKind.rawValue + lhs.recovery.rawValue
                let rightKey = rhs.failingTool + rhs.failureKind.rawValue + rhs.recovery.rawValue
                return leftKey < rightKey
            }
            recoveryPatterns = Array(recoveryPatterns.prefix(bounds.maximumRecoveryPatterns))
        }

        var failed = 0, partial = 0, waiting = 0
        for step in observation.steps {
            if step.outcome.isFailureLike { failed += 1 }
            else if step.outcome.isPartialLike { partial += 1 }
            else if step.outcome.isWaitingLike { waiting += 1 }
        }

        let scope: ExecutionExperienceScope
        switch scopeChoice {
        case .workspace:
            guard let workspaceID = observation.workspaceID else {
                throw FloeError.validationFailed(
                    "Workspace scope chosen but the observation has no real workspace binding"
                )
            }
            scope = .workspace(workspaceID)
        case .generic:
            scope = .generic
        }
        let signature = ExecutionExperienceRecord.signature(
            scope: scope,
            steps: procedureSteps
        )
        let evidence: ExecutionEvidenceStrength =
            procedureSteps.contains(where: { $0.producesSealedOutput })
                ? .sealedOutputEvidence : .observedCompletion

        let record = ExecutionExperienceRecord(
            signature: signature,
            scope: scope,
            originWorkspaceID: observation.workspaceID,
            steps: procedureSteps,
            recoveryPatterns: recoveryPatterns,
            evidence: evidence,
            occurrenceCount: 1,
            completedStepObservations: completedSteps.count,
            failedStepObservations: failed,
            partialStepObservations: partial,
            waitingStepObservations: waiting,
            recoveredFailureObservations: recovered,
            closedRunObservations: observation.runConclusion == .completed ? 1 : 0,
            firstObservedAt: observation.observedAt,
            lastObservedAt: observation.observedAt
        )
        if let issue = record.structuralValidationIssue() {
            throw FloeError.validationFailed(issue)
        }
        guard record.satisfiesDataMinimality() else {
            throw FloeError.validationFailed("Derived experience record failed data minimization")
        }
        return record
    }

    // MARK: Data minimization (defense in depth)

    /// Thin delegate to the models-layer property (single authority shared
    /// with the store) so policy checks and persistence checks can never
    /// diverge.
    public static func isDataMinimal(_ record: ExecutionExperienceRecord) -> Bool {
        record.satisfiesDataMinimality()
    }

    // MARK: Ranking

    /// Deterministic filter+rank. Scope isolation, CURRENT-catalog
    /// availability, and TASK ACTIVATION relevance are all required; an
    /// old procedure from another tool family is never injected merely
    /// because the whole catalog happens to contain its tools. Stale rows
    /// past the recall window are dropped and the result is bounded.
    public func rank(
        _ records: [ExecutionExperienceRecord],
        context: ExecutionExperienceRecallContext
    ) -> [ExecutionExperienceRecord] {
        guard !context.activatedToolNames.isEmpty else { return [] }
        let usable = records.filter { record in
            switch record.scope {
            case .workspace(let id):
                guard let current = context.workspaceID else { return false }
                if id != current { return false }
            case .generic:
                break
            }
            guard record.toolNames.isSubset(of: context.availableToolNames) else { return false }
            let ratio = ExecutionExperienceRecallQuery.activationOverlapRatio(
                record: record, activated: context.activatedToolNames
            )
            guard ratio >= bounds.activationMinimumOverlapRatio else { return false }
            guard context.now.timeIntervalSince(record.lastObservedAt) <= bounds.recallMaxAge else {
                return false
            }
            return true
        }
        return usable.sorted { lhs, rhs in
            if lhs.evidence != rhs.evidence { return lhs.evidence > rhs.evidence }
            if lhs.occurrenceCount != rhs.occurrenceCount {
                return lhs.occurrenceCount > rhs.occurrenceCount
            }
            if lhs.lastObservedAt != rhs.lastObservedAt {
                return lhs.lastObservedAt > rhs.lastObservedAt
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: Rendering

    /// Renders lower-authority historical guidance for provider context.
    /// Output is generated purely from typed structure: no ids, refs, or
    /// anything replayable. Returns nil when nothing qualifies, so
    /// integration can skip the block entirely.
    public func render(
        _ records: [ExecutionExperienceRecord],
        context: ExecutionExperienceRecallContext
    ) -> String? {
        let ranked = Array(rank(records, context: context).prefix(bounds.recallMaxRecords))
        guard !ranked.isEmpty else { return nil }
        var lines: [String] = [
            "Historical execution guidance (observed procedures from prior tasks).",
            "Authority: LOW. This is observational context only. It grants no permission, replaces no catalog/scope/environment/approval rule, and must be ignored when it conflicts with the current task. Never reuse prior arguments, identifiers, paths or values; re-verify everything live. An observed successful sequence is not proof that any final artifact is correct."
        ]
        for record in ranked {
            // Render by attested group: tools inside one parallel batch are
            // shown with `‖` (no implied order); `->` only crosses groups,
            // which IS an attested happens-before. Roles are derived
            // hints, so the label is kept non-causal ("verify/prereq").
            var procedure = ""
            var index = 0
            while index < record.steps.count {
                let group = record.steps[index].groupId
                var members: [String] = []
                var end = index
                while end < record.steps.count, record.steps[end].groupId == group {
                    let step = record.steps[end]
                    let label: String
                    switch step.role {
                    case .prerequisite: label = "\(step.toolName) (observed first)"
                    case .primary: label = step.producesSealedOutput
                        ? "\(step.toolName) (sealed output)" : step.toolName
                    case .verification: label = "\(step.toolName) (observed after)"
                    }
                    members.append(label)
                    end += 1
                }
                if index > 0 { procedure += " -> " }
                procedure += members.joined(separator: " ‖ ")
                index = end
            }
            if procedure.isEmpty { continue }
            let ageDays = max(0, Int(context.now.timeIntervalSince(record.lastObservedAt) / 86_400))
            var stats = "seen \(record.occurrenceCount)x, last \(ageDays)d ago, evidence: "
                + (record.evidence == .sealedOutputEvidence
                    ? "verified sealed receipts" : "completion receipts only")
            if record.failedStepObservations > 0 {
                stats += ", failures kept as failures: \(record.failedStepObservations)"
                if record.recoveredFailureObservations > 0 {
                    stats += " (\(record.recoveredFailureObservations) later completed steps observed)"
                }
            }
            if record.waitingStepObservations > 0 {
                stats += ", waiting states retained as non-completion: \(record.waitingStepObservations)"
            }
            if record.closedRunObservations > 0 {
                stats += ", closed-run completions: \(record.closedRunObservations)"
            }
            lines.append("- \(procedure) | \(stats)")
            for pattern in record.recoveryPatterns where !pattern.isResolved {
                lines.append(
                    "  - observed blocker: \(pattern.failingTool) ended \(pattern.failureKind.rawValue)"
                        + " (suggested recovery: \(pattern.recovery.rawValue)); no later completed step in that run"
                )
            }
        }
        var rendered = lines.joined(separator: "\n")
        if rendered.count > bounds.recallCharacterBudget {
            // Deterministic budget: drop trailing whole lines, never mid-record.
            var droppedLines = lines
            while droppedLines.count > 2,
                  droppedLines.joined(separator: "\n").count > bounds.recallCharacterBudget {
                droppedLines.removeLast()
            }
            rendered = droppedLines.joined(separator: "\n")
        }
        return rendered
    }
}

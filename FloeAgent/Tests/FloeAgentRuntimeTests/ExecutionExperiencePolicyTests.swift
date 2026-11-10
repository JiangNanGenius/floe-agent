// FloeAgentRuntimeTests — execution experience policy contract.
//
// Focused on the settled architecture: conservative completion promotion,
// explicit scope choice, attested-order recovery, sealed verdict integrity,
// data minimization, activation-relevance and bounded rendering.

import Foundation
import Testing
@testable import FloeAgentRuntime
import FloeCore
import FloeModels

/// Recall contexts must supply a NOW near the fixed observation time;
/// the policy's 90-day staleness fence is part of the contract.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000 + 7_200)

private func settled(
    _ tool: String,
    call: String,
    outcome: ExecutionOutcomeKind = .completed,
    recovery: ExecutionToolRecovery = .none,
    dispatched: Bool = true,
    captureRef: String? = nil,
    attestedBeforeNext: Bool = true
) -> ExecutionStepObservation {
    ExecutionStepObservation(
        toolName: tool,
        callID: call,
        outcome: outcome,
        recovery: recovery,
        dispatched: dispatched,
        captureRef: captureRef,
        settledAt: Date(timeIntervalSince1970: 1_700_000_000),
        orderAttestedBeforeNext: attestedBeforeNext
    )
}

private func observation(
    steps: [ExecutionStepObservation],
    workspaceID: UUID? = nil,
    temporary: Bool = false,
    conclusion: ExecutionRunConclusion? = nil
) -> ExecutionSequenceObservation {
    ExecutionSequenceObservation(
        conversationID: UUID(),
        runID: UUID(),
        workspaceID: workspaceID,
        isTemporaryConversation: temporary,
        steps: steps,
        runConclusion: conclusion,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Suite("Execution experience policy")
struct ExecutionExperiencePolicyTests {
    private let policy = ExecutionExperiencePolicy.standard

    // MARK: Conservative completion promotion (contract #1)

    @Test("An unclassified bare ok is never treated as completed")
    func okWithoutClassificationIsNotCompleted() {
        #expect(ExecutionExperiencePolicy.outcomeKind(
            statusRaw: "ok", classificationKindRaw: nil, dispatched: true
        ) == .partial)
    }

    @Test("A completed classification contradicted by a failed status is demoted")
    func completedClassificationContradictingStatusIsDemoted() {
        #expect(ExecutionExperiencePolicy.outcomeKind(
            statusRaw: "failed", classificationKindRaw: "completed", dispatched: true
        ) == .partial)
    }

    @Test("Completed requires ok plus typed completed plus dispatch")
    func completedRequiresAllFacts() {
        #expect(ExecutionExperiencePolicy.outcomeKind(
            statusRaw: "ok", classificationKindRaw: "completed", dispatched: true
        ) == .completed)
        #expect(ExecutionExperiencePolicy.outcomeKind(
            statusRaw: "ok", classificationKindRaw: "completed", dispatched: false
        ) == .partial)
        for kind in ["partial", "waitingForUser", "waitingForResource",
                     "denied", "cancelled", "noProgress", "failed"] {
            #expect(ExecutionExperiencePolicy.outcomeKind(
                statusRaw: "ok", classificationKindRaw: kind, dispatched: true
            ) != .completed)
        }
    }

    // MARK: Temporarily/freshness gates

    @Test("Temporary conversations are rejected before any derivation")
    func temporaryRejected() {
        let obs = observation(
            steps: [settled("a.read", call: "c1"), settled("b.write", call: "c2")],
            temporary: true
        )
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic)
        }
    }

    @Test("A completed step without a dispatch receipt cannot be derived")
    func undispatchedCompletedRejected() {
        let obs = observation(steps: [
            settled("a.read", call: "c1", dispatched: false),
            settled("b.write", call: "c2")
        ])
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic)
        }
    }

    // MARK: Explicit scope choice (contract #2)

    @Test("Workspace scope requires a real workspace binding")
    func workspaceScopeRequiresBinding() {
        let obs = observation(steps: [
            settled("a.read", call: "c1"), settled("a.write", call: "c2")
        ], workspaceID: nil)
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .workspace)
        }
    }

    @Test("Generic choice keeps the originating workspace as an opaque locator")
    func genericKeepsOriginLocator() throws {
        let workspace = UUID()
        let obs = observation(steps: [
            settled("a.read", call: "c1"), settled("a.write", call: "c2")
        ], workspaceID: workspace)
        let record = try policy.derive(obs, scopeChoice: .generic)
        #expect(record.scope == .generic)
        #expect(record.originWorkspaceID == workspace)
        let specific = try policy.derive(obs, scopeChoice: .workspace)
        #expect(specific.scope == .workspace(workspace))
        #expect(specific.originWorkspaceID == workspace)
    }

    // MARK: Sealed verdict integrity

    @Test("Sealed verdicts only attach to observed completed calls")
    func sealedVerdictIntegrity() throws {
        let obs = observation(steps: [
            settled("a.read", call: "c1"), settled("a.write", call: "c2")
        ])
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic, sealedVerifiedCallIDs: ["c9"])
        }
        let sealed = try policy.derive(obs, scopeChoice: .generic, sealedVerifiedCallIDs: ["c2"])
        #expect(sealed.evidence == .sealedOutputEvidence)
        let plain = try policy.derive(obs, scopeChoice: .generic)
        #expect(plain.evidence == .observedCompletion)
    }

    @Test("Sealed verdict on a failed step is rejected")
    func sealedOnFailedStepRejected() {
        let obs = observation(steps: [
            settled("a.read", call: "c1", outcome: .failed, recovery: .satisfyPrerequisite),
            settled("a.read", call: "c2")
        ])
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic, sealedVerifiedCallIDs: ["c1"])
        }
    }

    // MARK: Attested order (contract #3)

    @Test("Unattested parallel batches are canonically ordered, not sequenced")
    func parallelBatchCanonicalized() throws {
        let forward = observation(steps: [
            settled("alpha.one", call: "c1", attestedBeforeNext: false),
            settled("beta.two", call: "c2")
        ])
        let swapped = observation(steps: [
            settled("beta.two", call: "c3", attestedBeforeNext: false),
            settled("alpha.one", call: "c4")
        ])
        let a = try policy.derive(forward, scopeChoice: .generic)
        let b = try policy.derive(swapped, scopeChoice: .generic)
        #expect(a.signature == b.signature)
        #expect(a.steps.map(\.toolName) == ["alpha.one", "beta.two"])
        // Attested chains must NOT be re-sorted.
        let chained = observation(steps: [
            settled("beta.two", call: "c5", attestedBeforeNext: true),
            settled("alpha.one", call: "c6")
        ])
        let c = try policy.derive(chained, scopeChoice: .generic)
        #expect(c.signature != a.signature)
        #expect(c.steps.map(\.toolName) == ["beta.two", "alpha.one"])
    }

    @Test("Recovery requires the same tool with an attested later success")
    func recoveryNeedsAttestedSameTool() throws {
        let resolved = observation(steps: [
            settled("exec.shell", call: "r1", outcome: .failed, recovery: .fixArgumentsOrTarget),
            settled("document.read", call: "r2"),
            settled("exec.shell", call: "r3")
        ])
        // A later same-tool success NOT attested after the failing step
        // (an intervening unattested boundary) is not recovery proof.
        let parallel = observation(steps: [
            settled("exec.shell", call: "p1", outcome: .failed, recovery: .fixArgumentsOrTarget,
                    attestedBeforeNext: false),
            settled("exec.shell", call: "p2")
        ])
        let unrelated = observation(steps: [
            settled("exec.shell", call: "u1", outcome: .failed, recovery: .fixArgumentsOrTarget),
            settled("document.read", call: "u2")
        ])
        let r = try policy.derive(resolved, scopeChoice: .generic)
        let p = try policy.derive(parallel, scopeChoice: .generic)
        let u = try policy.derive(unrelated, scopeChoice: .generic)
        #expect(r.recoveredFailureObservations == 1)
        #expect(r.recoveryPatterns.first?.isResolved == true)
        #expect(p.recoveredFailureObservations == 0)
        #expect(p.recoveryPatterns.first?.isResolved == false)
        #expect(u.recoveredFailureObservations == 0)
        // Failures stay failures even when resolved.
        #expect(r.failedStepObservations == 1)
        #expect(p.failedStepObservations == 1)
    }

    // MARK: Data minimization

    @Test("Derived records serialize to identifier tokens only")
    func dataMinimalByConstruction() throws {
        let obs = observation(steps: [
            settled("a.read", call: "call-9", captureRef: "tr_" + String(repeating: "ab", count: 12)),
            settled("a.write", call: "call-10")
        ])
        let record = try policy.derive(obs, scopeChoice: .generic, sealedVerifiedCallIDs: ["call-10"])
        #expect(record.satisfiesDataMinimality())
        #expect(ExecutionExperiencePolicy.isDataMinimal(record))
        let json = try record.canonicalJSON()
        #expect(!json.contains("call-9") || json.count < 4_096)
    }

    @Test("Free-text identifiers are rejected at derivation")
    func freeTextRejected() {
        let obs = observation(steps: [
            settled("evil/tool with path", call: "c1"), settled("b.ok", call: "c2")
        ])
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic)
        }
    }

    // MARK: Deterministic identity and merge

    @Test("Same procedure yields same identity; merge is monotonic")
    func deterministicIdentityAndMerge() throws {
        let workspace = UUID()
        let first = observation(steps: [
            settled("a.read", call: "d1"), settled("a.write", call: "d2")
        ], workspaceID: workspace)
        let second = observation(steps: [
            settled("a.read", call: "d3"), settled("a.write", call: "d4")
        ], workspaceID: workspace)
        let r1 = try policy.derive(first, scopeChoice: .workspace)
        let r2 = try policy.derive(second, scopeChoice: .workspace, sealedVerifiedCallIDs: ["d4"])
        #expect(r1.id == r2.id)
        let merged = r1.merged(with: r2)
        #expect(merged.occurrenceCount == 2)
        #expect(merged.evidence == .sealedOutputEvidence)
        #expect(merged.completedStepObservations == 4)
        #expect(merged.structuralValidationIssue() == nil)
        #expect(merged.satisfiesDataMinimality())
    }

    // MARK: Activation relevance (steer: full catalog ≠ relevance)

    @Test("Full-catalog availability does not recall an unrelated family")
    func activationRelevanceRequired() throws {
        let obs = observation(steps: [
            settled("music.read", call: "m1"), settled("music.render", call: "m2")
        ])
        let record = try policy.derive(obs, scopeChoice: .generic)
        let context = ExecutionExperienceRecallContext(
            workspaceID: nil,
            availableToolNames: ["music.read", "music.render", "exec.shell", "document.read"],
            activatedToolNames: ["exec.shell", "document.read"],
            now: fixedNow
        )
        #expect(policy.rank([record], context: context).isEmpty)
        let emptyActivation = ExecutionExperienceRecallContext(
            workspaceID: nil, availableToolNames: ["music.read", "music.render"],
            activatedToolNames: [],
            now: fixedNow
        )
        #expect(policy.rank([record], context: emptyActivation).isEmpty)
        let matched = ExecutionExperienceRecallContext(
            workspaceID: nil,
            availableToolNames: ["music.read", "music.render", "exec.shell"],
            activatedToolNames: ["music.read", "music.render"],
            now: fixedNow
        )
        #expect(policy.rank([record], context: matched).count == 1)
    }

    @Test("Unavailable tools drop records even when activated")
    func availabilitySubsetRequired() throws {
        let obs = observation(steps: [
            settled("a.read", call: "x1"), settled("a.write", call: "x2")
        ])
        let record = try policy.derive(obs, scopeChoice: .generic)
        let context = ExecutionExperienceRecallContext(
            workspaceID: nil,
            availableToolNames: ["a.read"],
            activatedToolNames: ["a.read", "a.write"],
            now: fixedNow
        )
        #expect(policy.rank([record], context: context).isEmpty)
    }

    // MARK: Bounded rendering

    @Test("Rendered guidance is advisory and never replayable")
    func renderIsLowerAuthorityAndFreeOfIdentity() throws {
        let obs = observation(steps: [
            settled("a.read", call: "secret-call-id", captureRef: "tr_" + String(repeating: "cd", count: 12)),
            settled("a.write", call: "another-call-id")
        ])
        let record = try policy.derive(obs, scopeChoice: .generic, sealedVerifiedCallIDs: ["another-call-id"])
        let context = ExecutionExperienceRecallContext(
            workspaceID: nil, availableToolNames: ["a.read", "a.write"],
            activatedToolNames: ["a.read", "a.write"],
            now: fixedNow
        )
        let rendered = try #require(policy.render([record], context: context))
        #expect(rendered.contains("Authority: LOW"))
        #expect(!rendered.contains("secret-call-id"))
        #expect(!rendered.contains("another-call-id"))
        #expect(!rendered.contains("tr_"))
        #expect(rendered.count <= ExecutionExperiencePolicy.standard.bounds.recallCharacterBudget)
    }

    @Test("Parallel batches render unordered; attested chains keep arrows")
    func parallelBatchRenderedUnordered() throws {
        let parallel = observation(steps: [
            settled("a.one", call: "p1", attestedBeforeNext: false),
            settled("a.two", call: "p2")
        ])
        let parallelRecord = try policy.derive(parallel, scopeChoice: .generic)
        let chain = observation(steps: [
            settled("a.one", call: "c1", attestedBeforeNext: true),
            settled("a.two", call: "c2")
        ])
        let chainRecord = try policy.derive(chain, scopeChoice: .generic)
        // A parallel batch and an attested chain are distinct procedures.
        #expect(parallelRecord.signature != chainRecord.signature)
        let context = ExecutionExperienceRecallContext(
            workspaceID: nil, availableToolNames: ["a.one", "a.two"],
            activatedToolNames: ["a.one", "a.two"], now: fixedNow
        )
        let parallelRendered = try #require(policy.render([parallelRecord], context: context))
        #expect(parallelRendered.contains("‖"))
        #expect(!parallelRendered.contains("a.one -> a.two"))
        let chainRendered = try #require(policy.render([chainRecord], context: context))
        #expect(chainRendered.contains("a.one -> a.two"))
        #expect(!chainRendered.contains("‖"))
    }

    @Test("Overlong observations are rejected at the ingestion bound")
    func boundedIngestionWindow() {
        let many = (0..<ExecutionExperienceLimits.maximumStepsPerObservation + 1).map {
            settled("t\($0).step", call: "call-\($0)")
        }
        let obs = observation(steps: many)
        #expect(throws: (any Error).self) {
            try policy.derive(obs, scopeChoice: .generic)
        }
    }
}

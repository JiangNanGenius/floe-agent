// SPDX-License-Identifier: MPL-2.0
//
// Runtime-preparation continuation — focused admission/readiness regressions.
// AUTHORED, NOT EXECUTED here. No store migration, provider, device, command
// or App UI is used; every case exercises real code over its existing seams:
//
//   * `FacadeRunDomain.linuxPreflightPrerequisitesAreLive` — the exact field
//     set an ordinary launch join and a parked continuation wait on while the
//     local Linux runtime is preparing/verifying.
//   * `C02RunTargetPin.matches` — the pinned-environment identity check the
//     resume admission reuses; its deliberate rootEpoch blindness is re-proved
//     by the admission layer (a generation move is a changed authority).
//   * `C01LinuxEnvironmentMailboxHost` — the truthful environment host port:
//     it fails closed (never fabricates a snapshot) when the generation is
//     not bound, when the caller cancelled, or when the app host mailbox is
//     unbound.
//   * `TaskContinuityRunDescriptor.isResumable` — the retry-admission
//     vocabulary shared by an explicit Continue and a storage-pause resume.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class RuntimePreparationContinuationTests: XCTestCase {

    // MARK: - Live prerequisite composition

    /// The launch-join and parked-wait predicate consumes EXACTLY the five
    /// transport/rootfs/workload facts. The mapping/lease pair is produced by
    /// the first-use preflight, so it must NOT gate preparation continuation:
    /// otherwise a parked run could never be admitted while preflight work is
    /// still settling after an install.
    func testPreflightPrerequisitesRequireExactlyTheFivePrePreflightFacts() {
        var fields = LinuxShellQualificationFields()
        XCTAssertFalse(FacadeRunDomain.linuxPreflightPrerequisitesAreLive(fields),
                       "the compiled default is fail-closed")

        fields.runtimeUidBoundaryVerified = true
        fields.engineConnected = true
        fields.mailboxEpochBound = true
        fields.rootfsQualified = true
        // Mapping + lease are post-preflight products: they alone never gate.
        fields.workspaceMappingSynced = true
        fields.leaseAuthorityQualified = true
        XCTAssertFalse(FacadeRunDomain.linuxPreflightPrerequisitesAreLive(fields),
                       "the workload contract is still unacknowledged")

        fields.singleWorkloadContractAcknowledged = true
        XCTAssertTrue(FacadeRunDomain.linuxPreflightPrerequisitesAreLive(fields))

        let requiredFacts: [WritableKeyPath<LinuxShellQualificationFields, Bool>] = [
            \LinuxShellQualificationFields.runtimeUidBoundaryVerified,
            \LinuxShellQualificationFields.engineConnected,
            \LinuxShellQualificationFields.mailboxEpochBound,
            \LinuxShellQualificationFields.rootfsQualified,
            \LinuxShellQualificationFields.singleWorkloadContractAcknowledged,
        ]
        for field in requiredFacts {
            var copy = fields
            copy[keyPath: field] = false
            XCTAssertFalse(FacadeRunDomain.linuxPreflightPrerequisitesAreLive(copy),
                           "a missing \(field) fact must keep the preparation wait honest")
        }
    }

    // MARK: - Pinned-environment identity (changed-authority recheck)

    private func makeTarget(rootEpoch: UInt64, revision: Int64 = 3) -> C02ExecutionTarget {
        C02ExecutionTarget(
            taskID: UUID(), revision: revision, kind: .localLinux,
            environmentID: "env-local", projectID: nil, workspaceID: UUID(),
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: rootEpoch, remote: nil,
            provenance: .explicitUserSelection,
            createdAt: Date(), updatedAt: Date())
    }

    private func makePin(for target: C02ExecutionTarget,
                         rootEpoch: UInt64) -> C02RunTargetPin {
        C02RunTargetPin(
            runID: UUID(), taskID: target.taskID,
            targetRevision: target.revision, environmentID: target.environmentID,
            shellRootHash: target.shellRootHash, engineOwnerHash: target.engineOwnerHash,
            rootEpoch: rootEpoch, pinnedAt: Date())
    }

    /// `matches` deliberately ignores the root generation: the resume
    /// admission re-proves the live generation itself, so a generation move
    /// with an otherwise identical target is still a CHANGED authority and an
    /// automatic continuation surfaces it instead of adopting it.
    func testRunPinMatchesIgnoresRootEpochByDesignAndRejectsAnyIdentityDrift() {
        let target = makeTarget(rootEpoch: 9)
        let sameGeneration = makePin(for: target, rootEpoch: 9)
        XCTAssertTrue(sameGeneration.matches(target))

        var movedGeneration = target
        movedGeneration.rootEpoch = 10
        XCTAssertTrue(sameGeneration.matches(movedGeneration),
                      "the pin match is generation-blind; the admission re-proves the epoch")

        var newRevision = target
        newRevision.revision = 4
        XCTAssertFalse(sameGeneration.matches(newRevision),
                       "a target revision drift is a changed authority")

        var newEnvironment = target
        newEnvironment.environmentID = "env-replaced"
        XCTAssertFalse(sameGeneration.matches(newEnvironment),
                       "an environment replacement is a changed authority")

        var newShellRoot = target
        newShellRoot.shellRootHash = String(repeating: "c", count: 64)
        XCTAssertFalse(sameGeneration.matches(newShellRoot))

        var newEngineOwner = target
        newEngineOwner.engineOwnerHash = String(repeating: "d", count: 64)
        XCTAssertFalse(sameGeneration.matches(newEngineOwner))
    }

    // MARK: - Truthful environment host port (fail closed, never fabricated)

    func testMailboxHostFailsClosedWhenGenerationIsNotBound() async {
        let host = C01LinuxEnvironmentMailboxHost(epoch: { 0 })
        let status = await host.status(environmentID: "env-local")
        XCTAssertEqual(status.phase, .refused)
        XCTAssertEqual(status.environmentID, "env-local")
        XCTAssertFalse(status.detail.isEmpty)
        XCTAssertEqual(C01LinuxEnvironmentRendering.exitStatus(status), 126)

        let phase = await host.preparationPhase()
        XCTAssertEqual(phase, .refused,
                       "a parked continuation can never read a fabricated preparation phase")

        let start = await host.start(environmentID: "env-local",
                                     cancellation: CancellationToken())
        XCTAssertEqual(start.phase, .refused,
                       "start without a bound generation never pretends to prepare")

        let stop = await host.stop(environmentID: "env-local",
                                   cancellation: CancellationToken())
        XCTAssertEqual(stop.phase, .refused,
                       "stop without a bound generation changes nothing")
    }

    func testMailboxHostRefusesCancelledCallsBeforeAnyDispatch() async {
        let host = C01LinuxEnvironmentMailboxHost(epoch: { 7 })
        let cancelled = CancellationToken()
        cancelled.cancel()
        let start = await host.start(environmentID: "env-local", cancellation: cancelled)
        XCTAssertEqual(start.phase, .refused)
        XCTAssertTrue(start.detail.contains("cancelled"),
                      "a cancelled start is refused before any host dispatch")
        let stop = await host.stop(environmentID: "env-local", cancellation: cancelled)
        XCTAssertEqual(stop.phase, .refused)
        XCTAssertTrue(stop.detail.contains("cancelled"),
                      "a cancelled stop is refused before any host dispatch")
    }

    func testMailboxHostFailsClosedWhenAppHostMailboxIsUnbound() async {
        // The shared mailbox is process-wide; close it so this seam reads the
        // real notBound refusal regardless of neighbouring test order.
        LinuxShellMailbox.shared.close()
        let host = C01LinuxEnvironmentMailboxHost(epoch: { 7 })
        let status = await host.status(environmentID: nil)
        XCTAssertEqual(status.phase, .refused)
        XCTAssertTrue(status.detail.contains("not reachable"),
                      "an unreachable app host is a typed refusal, never a fabricated phase")
    }

    // MARK: - Retry-admission vocabulary shared by Continue and pause resume

    func testResumableRunStatesCoverPreparationWaitAndParkedContinuations() {
        func descriptor(_ state: String) -> TaskContinuityRunDescriptor {
            TaskContinuityRunDescriptor(
                taskID: UUID(), runID: UUID(), state: state,
                conversationMode: "chat", modelID: nil, providerID: nil)
        }
        for resumable in ["preparing", "streamingModel", "waitingApproval",
                          "executingTool", "compacting", "paused", "interrupted",
                          "verifying", "cancelling", "failed", "checkpointed"] {
            XCTAssertTrue(descriptor(resumable).isResumable,
                          "\(resumable) must stay retryable through the continuity paths")
        }
        for terminal in ["completed", "idle"] {
            XCTAssertFalse(descriptor(terminal).isResumable,
                           "\(terminal) is final; retrying it would fabricate a new turn")
            XCTAssertTrue(descriptor(terminal).isTerminal)
        }
        // The durable park truth: a checkpointed row is the recoverable wait
        // source, never a failure.
        XCTAssertTrue(descriptor("checkpointed").isCheckpointed)
        XCTAssertFalse(descriptor("checkpointed").isTerminal)
    }
}

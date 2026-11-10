// SPDX-License-Identifier: MPL-2.0
//
// N07 resource staging policy + generation-bound integration — REAL contract
// tests (authored, NOT executed by this lane; no compiler or XCTest run is
// claimed). The policy tests run the pure production decision function over
// real pin/target shapes; the integration tests exercise the same install /
// current / uninstall box contract the other C02 integrations honor.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeSkills
import FloeTools

final class C02SkillResourceStagingPolicyTests: XCTestCase, @unchecked Sendable {

    private let workspace = URL(fileURLWithPath: "/tmp/floe-policy-workspace", isDirectory: true)

    private func pin(runID: UUID, taskID: UUID, revision: Int64 = 1) -> C02RunTargetPin {
        C02RunTargetPin(
            runID: runID, taskID: taskID, targetRevision: revision,
            environmentID: "env-1", shellRootHash: "a", engineOwnerHash: "b",
            rootEpoch: 7, pinnedAt: Date())
    }

    private func target(taskID: UUID, kind: C02ExecutionTargetKind,
                        revision: Int64 = 1) -> C02ExecutionTarget {
        C02ExecutionTarget(
            taskID: taskID, revision: revision, kind: kind,
            environmentID: "env-1", projectID: nil, workspaceID: UUID(),
            shellRootHash: "a", engineOwnerHash: "b", rootEpoch: 7,
            remote: kind == .ssh ? C02RemoteEnvironmentFacts(
                hostID: UUID(), remoteRootPath: "/home/floe/task",
                operatingSystem: "linux", architecture: "aarch64",
                runtimeGeneration: "gen-1") : nil,
            provenance: .explicitUserSelection, createdAt: Date(), updatedAt: Date())
    }

    // MARK: - Target gate

    func testLocalTargetWithWorkspaceResolvesLocalLane() {
        let runID = UUID(), taskID = UUID()
        let outcome = C02SkillResourceStagingPolicy.resolution(
            pin: pin(runID: runID, taskID: taskID),
            target: target(taskID: taskID, kind: .localLinux),
            workspaceRoot: workspace)
        guard case .local(let root, let guest) = outcome else {
            return XCTFail("expected local, got \(outcome)")
        }
        XCTAssertEqual(root, workspace)
        XCTAssertEqual(guest, C02SkillResourceStaging.guestWorkspaceRoot)
        XCTAssertEqual(guest, "/workspace")
    }

    func testSSHTargetIsTheHonestRemoteBoundaryAndNeverStagedLocally() {
        let runID = UUID(), taskID = UUID()
        let outcome = C02SkillResourceStagingPolicy.resolution(
            pin: pin(runID: runID, taskID: taskID),
            target: target(taskID: taskID, kind: .ssh),
            // Even when a local workspace root still resolves for this run
            // (known source behavior), the remote gate must win: no silent
            // local staging for a remote-pinned task.
            workspaceRoot: workspace)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.remoteResourceStagingUnavailable)
    }

    func testMissingPinOrReboundTargetRefusesWithPreciseReason() {
        let runID = UUID(), taskID = UUID()
        let noPin = C02SkillResourceStagingPolicy.resolution(
            pin: nil, target: nil, workspaceRoot: workspace)
        guard case .unavailable(let reasonNoPin) = noPin else {
            return XCTFail("expected refusal, got \(noPin)")
        }
        XCTAssertEqual(reasonNoPin, SkillStageReason.noLocalExecutionTarget)

        // Target was rebound past the pin (revision mismatch): stale facts
        // must never stage.
        let rebound = C02SkillResourceStagingPolicy.resolution(
            pin: pin(runID: runID, taskID: taskID, revision: 1),
            target: target(taskID: taskID, kind: .localLinux, revision: 2),
            workspaceRoot: workspace)
        guard case .unavailable(let reasonRebound) = rebound else {
            return XCTFail("expected refusal, got \(rebound)")
        }
        XCTAssertEqual(reasonRebound, SkillStageReason.noLocalExecutionTarget)

        // Local target but the workspace authority answered nil: precise
        // workspace reason, not fabricated support.
        let noWorkspace = C02SkillResourceStagingPolicy.resolution(
            pin: pin(runID: runID, taskID: taskID),
            target: target(taskID: taskID, kind: .localLinux),
            workspaceRoot: nil)
        guard case .unavailable(let reasonNoWorkspace) = noWorkspace else {
            return XCTFail("expected refusal, got \(noWorkspace)")
        }
        XCTAssertEqual(reasonNoWorkspace, SkillStageReason.taskWorkspaceUnavailable)
    }

    // MARK: - Integration box (install / current / uninstall fencing)

    func testDomainStagerRefusesHonestlyWhileNoRuntimeIsInstalled() async throws {
        // Exercise the REAL SkillsDomain stager factory (the closure the
        // exact-read branch calls). With no installed integration runtime it
        // must answer the honest transport refusal — never fabricated support.
        guard C02SkillResourceStagingIntegration.current == nil else {
            throw XCTSkip("another suite holds the global staging runtime")
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-noinstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let snapshot = try Self.makeSnapshot(workspace: workspace)
        let stager = SkillsDomain.resourceStager()
        let token = CancellationToken()
        let context = SkillResourceContext(
            runID: UUID(), conversationID: UUID(), environmentID: "env-1",
            workspaceRootURL: workspace, temporaryReadOnly: false, cancellation: token)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.stagingTransportUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe").path))
    }

    func testInstalledRuntimeAnswersAndStaleEpochRefuses() async {
        let epoch = UInt64(Date().timeIntervalSince1970)
        let runID = UUID()
        let runtime = C02SkillResourceStagingIntegration.install(
            epoch: epoch,
            resolve: { _, _ in .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace") },
            prober: nil,
            liveEpoch: { epoch })
        defer { C02SkillResourceStagingIntegration.uninstall(epoch: epoch) }
        XCTAssertTrue(C02SkillResourceStagingIntegration.current === runtime)
        let live = await runtime.resolution(runID: runID, conversationID: nil)
        guard case .local = live else { return XCTFail("expected live local, got \(live)") }

        // The live epoch moves on: the SAME runtime object now refuses (the
        // stager's late callback can never publish against a retired root).
        let movedEpoch = epoch &+ 1
        let staleRuntime = C02SkillResourceStagingIntegration.install(
            epoch: movedEpoch,
            resolve: { _, _ in .unavailable(reason: "unused") },
            prober: nil,
            liveEpoch: { movedEpoch &+ 1 })
        defer { C02SkillResourceStagingIntegration.uninstall(epoch: movedEpoch) }
        let stale = await staleRuntime.resolution(runID: runID, conversationID: nil)
        guard case .unavailable(let reason) = stale else {
            return XCTFail("expected stale refusal, got \(stale)")
        }
        XCTAssertEqual(reason, SkillStageReason.stagingTransportUnavailable)
        // A stale uninstall must not clear the newer generation's binding.
        C02SkillResourceStagingIntegration.uninstall(epoch: epoch)
        XCTAssertTrue(C02SkillResourceStagingIntegration.current === staleRuntime)
    }

    // MARK: - Fixture

    /// One REAL digest-validated package + snapshot for the domain-factory
    /// test (the validator remains the authority for package shape).
    static func makeSnapshot(workspace: URL) throws -> SkillContentSnapshot {
        let package = workspace.appendingPathComponent("pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let skillBytes = Data("---\nname: noinstall-guide\ndescription: fixture\n---\n\nbody\n".utf8)
        try skillBytes.write(to: package.appendingPathComponent("SKILL.md"), options: .atomic)
        let manifest = SkillManifest(id: "noinstall-guide", version: "1.0.0",
                                     capabilities: ["workspace.read"],
                                     tools: ["exec.shell"], platforms: ["linux"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: package.appendingPathComponent("floe.json"), options: .atomic)
        let digest = try SkillPackageValidator.canonicalDigest(
            files: ["SKILL.md": skillBytes, "floe.json": manifestBytes])
        return try SkillContentSnapshot(root: package, expectedDigest: digest)
    }
}

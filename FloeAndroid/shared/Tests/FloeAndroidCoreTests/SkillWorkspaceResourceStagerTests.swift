// SPDX-License-Identifier: MPL-2.0
//
// N07 SkillWorkspaceResourceStager — REAL contract tests (authored, NOT
// executed by this lane; no compiler or XCTest run is claimed). Meaningful
// cases against the production seams only: a REAL validated package fixture,
// a REAL temporary workspace root, and resolver/prober closures that answer
// the production shapes. No fake successful transport: every visibility
// answer is injected honestly like the mailbox probe would return it.
import XCTest
import Foundation
import FloeCore
import FloeSkills
import FloeTools

final class SkillWorkspaceResourceStagerTests: XCTestCase, @unchecked Sendable {

    private var root: URL!
    private var workspace: URL!
    private var packages: URL!

    override func setUp() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skillstager-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        packages = root.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// One REAL digest-validated package + snapshot (the validator remains
    /// the authority for what a package may contain).
    private func makeSnapshot(id: String, scriptBody: String = "#!/bin/sh\necho ok\n") throws
        -> (snapshot: SkillContentSnapshot, digest: String) {
        let package = packages.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let skillBytes = Data(("---\nname: \(id)\ndescription: stager fixture\n---\n\nbody\n").utf8)
        try skillBytes.write(to: package.appendingPathComponent("SKILL.md"), options: .atomic)
        let scriptBytes = Data(scriptBody.utf8)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        try scriptBytes.write(to: package.appendingPathComponent("scripts/run.sh"), options: .atomic)
        let manifest = SkillManifest(id: id, version: "1.0.0",
                                     capabilities: ["workspace.read"],
                                     tools: ["exec.shell"], platforms: ["linux"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: package.appendingPathComponent("floe.json"), options: .atomic)
        let digest = try SkillPackageValidator.canonicalDigest(
            files: ["SKILL.md": skillBytes, "scripts/run.sh": scriptBytes, "floe.json": manifestBytes])
        let snapshot = try SkillContentSnapshot(root: package, expectedDigest: digest)
        return (snapshot, digest)
    }

    private func context(workspaceRoot: URL? = nil, temporary: Bool = false,
                         cancelled: Bool = false) -> SkillResourceContext {
        let token = CancellationToken()
        if cancelled { token.cancel() }
        return SkillResourceContext(
            runID: UUID(), conversationID: UUID(), environmentID: "env-1",
            workspaceRootURL: workspaceRoot ?? workspace,
            temporaryReadOnly: temporary, cancellation: token)
    }

    private func localResolver(root: URL? = nil, guest: String = "/workspace")
        -> @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution {
        { _, _ in .local(workspaceRoot: root ?? self.workspace, guestWorkspaceRoot: guest) }
    }

    private func stagedLeaf(_ digest: String, id: String = "stager-guide") -> URL {
        workspace.appendingPathComponent(".floe/skills/\(id)@\(digest)", isDirectory: true)
    }

    // MARK: - Identity / visibility handoff

    func testStagePublishesVerifiedBundleAndReportsGuestIdentity() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        struct Prober: SkillGuestVisibilityProbing {
            let visible: Bool?
            func isPathVisible(workspaceRoot: URL, relativePath: String,
                               conversationID: UUID?, cancellation: CancellationToken) async -> Bool? {
                visible
            }
        }
        let stager = SkillWorkspaceResourceStager(
            resolve: localResolver(),
            probeVisibility: Prober(visible: true))
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(),
            context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertEqual(bundle.guestRoot, "/workspace/.floe/skills/stager-guide@\(digest)")
        XCTAssertEqual(bundle.pinnedSHA256, digest)
        XCTAssertEqual(bundle.fileCount, 3)
        XCTAssertTrue(bundle.visibleInGuest)
        // Real bytes landed and re-verify against the pinned snapshot.
        XCTAssertTrue(SkillWorkspaceResourceStager.verify(
            stagedRoot: stagedLeaf(digest),
            bundle: SkillWorkspaceResourceStager.stagingBundle(
                manifestID: snapshot.package.manifest.id,
                digest: snapshot.package.canonicalSHA256,
                declaredFiles: snapshot.package.files,
                bytes: snapshot.files)!))
        // scripts/ shebang entry kept its executable intent.
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stagedLeaf(digest).appendingPathComponent("scripts/run.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        // No leftover staging temporaries.
        let entries = try FileManager.default.contentsOfDirectory(atPath:
            workspace.appendingPathComponent(".floe/skills").path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
        // Footer is honest about confirmed visibility.
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: "stager-guide", pinnedSHA256: digest,
            declaredFiles: snapshot.package.files, outcome: outcome)
        XCTAssertTrue(footer.contains("visibleInGuest=true"))
        XCTAssertTrue(footer.contains("guestRoot=/workspace/.floe/skills/stager-guide@\(digest)"))
    }

    func testUnconfirmedVisibilityIsReportedHonestlyWithBoundaryGuidance() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        // No prober installed: visibility is unconfirmed, never fabricated.
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertFalse(bundle.visibleInGuest)
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: "stager-guide", pinnedSHA256: digest,
            declaredFiles: snapshot.package.files, outcome: outcome)
        XCTAssertTrue(footer.contains("visibleInGuest=false"))
        XCTAssertTrue(footer.contains("next workspace import boundary"))
    }

    // MARK: - Same-digest reuse

    func testSameDigestReuseIsIdempotentAndVerifiesBytes() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let first = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged = first else { return XCTFail("first stage failed: \(first)") }
        let leaf = stagedLeaf(digest)
        // A second read of the SAME pinned revision reuses the verified tree.
        let second = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundle) = second else {
            return XCTFail("reuse stage failed: \(second)")
        }
        XCTAssertEqual(bundle.pinnedSHA256, digest)
        XCTAssertTrue(SkillWorkspaceResourceStager.verify(
            stagedRoot: leaf,
            bundle: SkillWorkspaceResourceStager.stagingBundle(
                manifestID: snapshot.package.manifest.id,
                digest: snapshot.package.canonicalSHA256,
                declaredFiles: snapshot.package.files,
                bytes: snapshot.files)!))
        // The advisory marker for the reused leaf exists and no duplicate
        // leaf or staging temporary appeared.
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace
            .appendingPathComponent(".floe/skills/.markers/stager-guide@\(digest).json").path))
        let entries = try FileManager.default.contentsOfDirectory(atPath:
            workspace.appendingPathComponent(".floe/skills").path)
        XCTAssertEqual(entries.filter { $0 == "stager-guide@\(digest)" }.count, 1)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    // MARK: - Retained pinned revision

    func testNewPinnedRevisionStagesSiblingLeafAndNeverReplacesTheOld() async throws {
        let runID = UUID()
        let (first, digestA) = try makeSnapshot(id: "stager-guide", scriptBody: "#!/bin/sh\necho A\n")
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcomeA = await stager.stage(
            snapshot: first, runID: runID, conversationID: UUID(), context: context())
        guard case .staged = outcomeA else { return XCTFail("A failed: \(outcomeA)") }
        // The run's install moved on (update) but THIS run keeps revision A;
        // a second run pins B and must get its own leaf — A is left intact.
        let (second, digestB) = try makeSnapshot(id: "stager-guide", scriptBody: "#!/bin/sh\necho B\n")
        XCTAssertNotEqual(digestA, digestB)
        let outcomeB = await stager.stage(
            snapshot: second, runID: UUID(), conversationID: UUID(), context: context())
        guard case .staged(let bundleB) = outcomeB else {
            return XCTFail("B failed: \(outcomeB)")
        }
        XCTAssertEqual(bundleB.guestRoot, "/workspace/.floe/skills/stager-guide@\(digestB)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedLeaf(digestA).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedLeaf(digestB).path))
        // A remains byte-identical to revision A.
        let scriptA = try Data(contentsOf: stagedLeaf(digestA).appendingPathComponent("scripts/run.sh"))
        XCTAssertEqual(String(decoding: scriptA, as: UTF8.self), "#!/bin/sh\necho A\n")
    }

    // MARK: - Refusals

    func testTemporaryReadOnlyRefusesBeforeAnyEffect() async throws {
        let (snapshot, _) = try makeSnapshot(id: "stager-guide")
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(),
            context: context(temporary: true))
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.temporaryReadOnlyRefused)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe").path))
    }

    func testRemoteTargetRefusesWithoutStagingAnythingLocally() async throws {
        let (snapshot, _) = try makeSnapshot(id: "stager-guide")
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in .unavailable(reason: SkillStageReason.remoteResourceStagingUnavailable) })
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.remoteResourceStagingUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe").path))
        let footer = SkillWorkspaceResourceStager.resourceFooter(
            id: "stager-guide", pinnedSHA256: snapshot.package.canonicalSHA256,
            declaredFiles: snapshot.package.files, outcome: outcome)
        XCTAssertTrue(footer.contains("staged=false"))
        XCTAssertTrue(footer.contains("remoteResourceStagingUnavailable"))
    }

    func testContextWorkspaceMismatchWithResolvedRootRefuses() async throws {
        let (snapshot, _) = try makeSnapshot(id: "stager-guide")
        let foreign = root.appendingPathComponent("ForeignWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(),
            context: context(workspaceRoot: foreign))
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.workspaceMismatch)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: foreign.appendingPathComponent(".floe").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".floe").path))
    }

    // MARK: - No-follow / foreign conflict

    func testPlantedSymlinkAtReservedRootFailsClosedAndIsUntouched() async throws {
        let (snapshot, _) = try makeSnapshot(id: "stager-guide")
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".floe"), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent(".floe/skills"),
            withDestinationURL: outside)
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.reservedConflict)
        // The planted link is exactly as found and nothing leaked outside.
        let values = try workspace.appendingPathComponent(".floe/skills")
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).count, 0)
    }

    func testForeignTreeAtLeafFailsClosedAndIsNotOverwritten() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        let leaf = stagedLeaf(digest)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let foreignBytes = Data("foreign".utf8)
        try foreignBytes.write(to: leaf.appendingPathComponent("SKILL.md"), options: .atomic)
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.pathBlocked)
        // Foreign content is left exactly as found.
        XCTAssertEqual(try Data(contentsOf: leaf.appendingPathComponent("SKILL.md")), foreignBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: leaf.appendingPathComponent("scripts").path))
    }

    // MARK: - Cancellation / rebind fencing

    func testCancelledReadNeverYieldsAPathAndCleansOwnTemporary() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        let token = CancellationToken()
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        // Cancel mid-flight: refuse before stage, then remove the temporary.
        token.cancel()
        let context = SkillResourceContext(
            runID: UUID(), conversationID: UUID(), environmentID: "env-1",
            workspaceRootURL: workspace, temporaryReadOnly: false, cancellation: token)
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedLeaf(digest).path))
        let reserved = workspace.appendingPathComponent(".floe/skills").path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: reserved) else { return }
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    func testPrePublishRootRebindRefusesAndLeavesNewRootUntouched() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        let rebound = root.appendingPathComponent("ReboundWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: rebound, withIntermediateDirectories: true)
        var calls = 0
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                calls += 1
                // First (initial) resolution answers the original root; the
                // mandatory pre-publish re-check observes the rebound root.
                return calls == 1
                    ? .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace")
                    : .local(workspaceRoot: rebound, guestWorkspaceRoot: "/workspace")
            })
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.taskWorkspaceUnavailable)
        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedLeaf(digest).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rebound.appendingPathComponent(".floe").path))
    }

    func testPrePublishLostTargetRefusesAndCleansOwnTemporary() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        var calls = 0
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                calls += 1
                return calls == 1
                    ? .local(workspaceRoot: self.workspace, guestWorkspaceRoot: "/workspace")
                    : .unavailable(reason: SkillStageReason.noLocalExecutionTarget)
            })
        let outcome = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.noLocalExecutionTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedLeaf(digest).path))
        let entries = try FileManager.default.contentsOfDirectory(atPath:
            workspace.appendingPathComponent(".floe/skills").path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    // MARK: - Stale-temp pruning never touches content bundles

    func testPruneRemovesOnlyOwnAgedStagingTemps() async throws {
        let (snapshot, digest) = try makeSnapshot(id: "stager-guide")
        let stager = SkillWorkspaceResourceStager(resolve: localResolver())
        _ = await stager.stage(
            snapshot: snapshot, runID: UUID(), conversationID: UUID(), context: context())
        let reserved = workspace.appendingPathComponent(".floe/skills")
        // A foreign temp that merely borrows the prefix must survive; a real
        // own-aged temp must not.
        let foreign = reserved.appendingPathComponent(".staging-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let aged = reserved.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aged, withIntermediateDirectories: true)
        let past = Date().addingTimeInterval(-(25 * 60 * 60))
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: aged.path)
        SkillWorkspaceResourceStager.pruneStaleStagingTemps(in: reserved)
        let entries = try FileManager.default.contentsOfDirectory(atPath: reserved.path)
        XCTAssertTrue(entries.contains("stager-guide@\(digest)"))
        XCTAssertTrue(entries.contains(".staging-not-a-uuid"))
        XCTAssertFalse(entries.contains(aged.lastPathComponent))
        try? FileManager.default.removeItem(at: foreign)
    }
}

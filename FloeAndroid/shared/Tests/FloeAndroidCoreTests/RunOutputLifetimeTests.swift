// FloeAndroidCoreTests — D04 run-output service LIFETIME semantics over the
// REAL filesystem (job-3135f83ef97c4a21; coordinator API reviews of
// 2026-10-27). No fakes for the thing under test: `RuntimeFacadeRunOutput`
// is exercised as production uses it — install/retire epoch fencing, the
// atomic binding+lease capture (no split capture can publish to rootA and
// validate under rootB), the publication/cleanup exclusion claims, the
// instance-bound registration availability gate against an injected
// `ToolRunnerRegistry`, and the readiness retry composition. Trusted
// closures stand in for the DB existence check (the DB integration is
// Main's batch); everything filesystem-, lock- and epoch-related is the
// real code.

import Foundation
import Testing
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("FloeAndroidCore.RuntimeFacadeRunOutput lifetime")
struct RuntimeFacadeRunOutputLifetimeTests {

    private func scratchRoot() -> (base: URL, artifact: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-ro-lifetime-\(UUID().uuidString)", isDirectory: true)
        let artifact = base.appendingPathComponent("FloeAgent", isDirectory: true)
        return (base, artifact)
    }

    private func makeContext(runID: UUID, callID: String? = "call-1") -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: callID,
            cancellation: CancellationToken(),
            environmentID: "env-1",
            conversationID: UUID()
        )
    }

    private func commitFile(dir: URL, name: String, content: Data) throws -> RunOutputCommit {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url)
        return RunOutputCommit(
            sourceURL: url,
            sha256: FloeDigest.sha256Hex(content),
            byteCount: content.count,
            displayName: name,
            mimeType: "text/plain",
            uti: nil
        )
    }

    // MARK: - Epoch fence

    @Test("retirement keeps a monotonic fence: the same/older epoch can never re-install")
    func retireHighwaterRefusesOldInstall() throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 5))
        facade.retire(epoch: 5)
        // Exactly the retired epoch must NOT resurrect the generation…
        #expect(!facade.install(artifactRootPath: fixture.artifact.path, epoch: 5))
        // …and neither may an older one.
        #expect(!facade.install(artifactRootPath: fixture.artifact.path, epoch: 4))
        // A genuinely newer epoch installs.
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 6))
        // Retirement by a foreign (older) epoch never tears the newer one down.
        facade.retire(epoch: 5)
        #expect(facade.currentBinding()?.epoch == 6)
        facade.retire(epoch: 6)
        #expect(facade.currentBinding() == nil)
    }

    @Test("same-epoch rebind to a different owned root is a real conflict")
    func sameEpochDifferentRootRefused() throws {
        let a = scratchRoot(), b = scratchRoot()
        defer {
            try? FileManager.default.removeItem(at: a.base)
            try? FileManager.default.removeItem(at: b.base)
        }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: a.artifact.path, epoch: 7))
        #expect(!facade.install(artifactRootPath: b.artifact.path, epoch: 7))
        #expect(facade.currentBinding()?.artifactRoot.path == a.artifact.path)
    }

    // MARK: - Atomic capture + boundary revalidation

    @Test("the publication ticket carries the SAME captured root as its epoch; a rebind invalidates it")
    func ticketCaptureIsAtomicAndRebindInvalidates() throws {
        let a = scratchRoot(), b = scratchRoot()
        defer {
            try? FileManager.default.removeItem(at: a.base)
            try? FileManager.default.removeItem(at: b.base)
        }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: a.artifact.path, epoch: 9))
        let runID = UUID()
        guard let ticket = facade.beginPublication(runID: runID) else {
            Issue.record("live generation must mint a ticket")
            return
        }
        #expect(ticket.epoch == 9)
        #expect(ticket.artifactRoot?.path == a.artifact.path)
        // A retire + newer install occurs while the ticket is held (the
        // coordinator's forced sequence). There is no split capture left
        // for it to land between: the ticket itself is the capture.
        facade.retire(epoch: 9)
        #expect(facade.install(artifactRootPath: b.artifact.path, epoch: 10))
        #expect(!facade.isPublicationCurrent(ticket),
                "rootA/epochA bytes must NEVER validate under the rootB/epochB generation")
        facade.endPublication(ticket)
        #expect(!facade.hasActiveLease(forRunID: runID))
        // The NEW generation mints its own root-bound ticket.
        let fresh = try #require(facade.beginPublication(runID: runID))
        #expect(fresh.epoch == 10 && fresh.artifactRoot?.path == b.artifact.path)
        facade.endPublication(fresh)
        facade.retire(epoch: 10)
    }

    @Test("facade publish round-trips the receipt and releases its lease at completion")
    func publishRoundTripReleasesLease() throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 20))
        let runID = UUID()
        let commit = try commitFile(
            dir: fixture.base.appendingPathComponent("workspace"),
            name: "round.txt", content: Data("round trip".utf8))
        let receipt = try facade.publish(
            RunOutputSnapshotRequest(producerTool: "document.createWord", slot: "document", commit: commit),
            using: makeContext(runID: runID)
        )
        #expect(receipt.runID == runID)
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(facade.activeLeaseCount == 0)
        if case .verified(let url) = facade.verify(receipt) {
            #expect(try Data(contentsOf: url) == Data("round trip".utf8))
        } else {
            Issue.record("published snapshot must verify under the bound root")
        }
        facade.retire(epoch: 20)
    }

    // MARK: - Cleanup claim vs admission (real exclusion, not boolean-only)

    @Test("a live lease refuses the cleanup claim, and a held claim refuses new publications")
    func claimAndLeaseExcludeEachOther() throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 30))
        let runID = UUID()
        guard let lease = facade.acquireLease(runID: runID, owner: "svc.producer") else {
            Issue.record("bound generation must grant a lease"); return
        }
        #expect(!facade.beginCleanup(runIDs: [runID]),
                "cleanup may not claim a run an operation still owns")
        facade.releaseLease(lease)
        #expect(facade.beginCleanup(runIDs: [runID]))
        // Admission fence: while the claim is held, new publications fail
        // closed — this is what makes probe-then-delete atomic.
        #expect(facade.beginPublication(runID: runID) == nil)
        // Other runs are unaffected (the claim is narrow, run-owned).
        let other = UUID()
        #expect(facade.beginPublication(runID: other) != nil)
        facade.endCleanup(runIDs: [runID])
        #expect(facade.beginPublication(runID: runID) != nil)
        facade.retire(epoch: 30)
    }

    @Test("double claim is refused: one cleanup owner at a time")
    func claimIsExclusive() throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 31))
        let run = UUID()
        #expect(facade.beginCleanup(runIDs: [run]))
        #expect(!facade.beginCleanup(runIDs: [run]))
        facade.endCleanup(runIDs: [run])
        #expect(facade.beginCleanup(runIDs: [run]))
        facade.endCleanup(runIDs: [run])
        facade.retire(epoch: 31)
    }

    // MARK: - Readiness retry composition (real queue + real facade probe)

    @Test("resumePendingCleanup retains a leased run and completes it after release")
    func resumeRetainsLeasedRunUntilReleased() async throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        let conversation = UUID()
        let run = UUID()
        // A real committed snapshot tree + a real persisted tombstone.
        let tree = fixture.artifact
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(run.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: tree.appendingPathComponent("out.bin"))
        #expect(facade.install(artifactRootPath: fixture.artifact.path, epoch: 40))
        try RunOutputCleanupQueue.enqueue(
            .init(conversationID: conversation, runIDs: [run]),
            storeRoot: fixture.artifact)
        guard let lease = facade.acquireLease(runID: run, owner: "svc.downloading") else {
            Issue.record("lease must be granted"); return
        }
        let retained = await facade.resumePendingCleanup(
            liveOwnership: RunOutputLeaseLiveOwnership(facade: facade),
            operationGate: facade
        ) { _ in false }
        #expect(retained.retainedLiveOutputRequests == 1)
        #expect(retained.completedRequests == 0)
        #expect(FileManager.default.fileExists(atPath: tree.deletingLastPathComponent().path))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.artifact).count == 1)
        facade.releaseLease(lease)
        let completed = await facade.resumePendingCleanup(
            liveOwnership: RunOutputLeaseLiveOwnership(facade: facade),
            operationGate: facade
        ) { _ in false }
        #expect(completed.completedRequests == 1)
        #expect(!FileManager.default.fileExists(atPath: tree.deletingLastPathComponent().path))
        #expect(try RunOutputCleanupQueue.pending(storeRoot: fixture.artifact).isEmpty)
        facade.retire(epoch: 40)
    }

    @Test("an unbound facade fails closed on every surface and reports it honestly")
    func unboundFailsClosed() async throws {
        let fixture = scratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let facade = RuntimeFacadeRunOutput()
        let registry = ToolRunnerRegistry()
        #expect(!facade.registerOutputTool(into: registry))
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) == nil)
        let runID = UUID()
        #expect(facade.beginPublication(runID: runID) == nil)
        #expect(facade.acquireLease(runID: runID, owner: "svc") == nil)
        let commit = try commitFile(
            dir: fixture.base.appendingPathComponent("workspace"),
            name: "x.txt", content: Data("x".utf8))
        #expect(throws: (any Error).self) {
            _ = try facade.publish(
                RunOutputSnapshotRequest(producerTool: "document.createWord", slot: "s", commit: commit),
                using: makeContext(runID: runID))
        }
        let outcome = await facade.resumePendingCleanup { _ in false }
        #expect(outcome.failureDescriptions.contains("run-output cleanup store is not bound"))
    }

    // MARK: - Instance-bound registration

    @Test("registered tool availability follows THIS instance's binding, not the singleton's")
    func registrationIsInstanceBound() throws {
        let a = scratchRoot(), b = scratchRoot()
        defer {
            try? FileManager.default.removeItem(at: a.base)
            try? FileManager.default.removeItem(at: b.base)
        }
        let facadeA = RuntimeFacadeRunOutput()
        let registry = ToolRunnerRegistry()
        #expect(facadeA.install(artifactRootPath: a.artifact.path, epoch: 50))
        #expect(facadeA.registerOutputTool(into: registry))
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) != nil)
        // Retiring A's binding hides the executable surface even though
        // some OTHER facade (the process singleton) may stay bound — the
        // availability closure reads THIS instance only.
        facadeA.retire(epoch: 50)
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) == nil,
                "isAvailable gates the runner on the retiring instance")
        // A fresh instance can take over the slot with its own binding.
        let facadeB = RuntimeFacadeRunOutput()
        #expect(facadeB.install(artifactRootPath: b.artifact.path, epoch: 51))
        #expect(facadeB.registerOutputTool(into: registry))
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) != nil)
        // Existing discovery contract kept honest: the static catalog
        // DESCRIPTOR is documentation (as CatalogToolExecutor already
        // defines it) — it remains after retirement. Only the runner/
        // descriptor EXECUTABLE surface is gated.
        #expect(ToolCatalog.descriptor(named: WorkspacePublishOutputTool.name) != nil)
        facadeB.retire(epoch: 51)
    }
}

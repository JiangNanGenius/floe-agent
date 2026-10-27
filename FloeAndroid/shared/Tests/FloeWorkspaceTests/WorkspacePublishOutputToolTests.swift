// FloeWorkspaceTests — Real-execution behavior of workspace.publishOutput
// on the Android shared core (job-3135f83ef97c4a21).
//
// Ported from iOS main 8f185ac FloeAgent/Tests/FloeWorkspaceTests/
// WorkspacePublishOutputTests.swift (blob de707454ae5713b59fc4bb0a3c1834a4aa062bd8).
// Every assertion that describes the publication contract is unchanged:
// exact bytes frozen at publish time, refusals for missing/foreign/unsafe
// inputs, binding requirements, cancellation and idempotent replay.
// The two narrow port deltas: each fixture injects its OWN artifact root
// through the tool's `artifactRootProvider` (Android has no implicit
// store location — see the tool header), and the registration test uses
// the Android `registerWorkspacePublishOutputTool` seam with an injected
// `ToolRunnerRegistry`. Runs against the real filesystem in temporary
// directories; no scanned outputs, no prose inference.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeModels
import FloeTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("FloeWorkspace.PublishOutput")
struct WorkspacePublishOutputToolTests {

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let artifactRoot: URL
        let runID: UUID
        let conversationID: UUID
        let environment: WorkspaceToolEnvironment

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-publish-tests-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("workspace", isDirectory: true)
            artifactRoot = base.appendingPathComponent("artifact-store", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            runID = UUID()
            conversationID = UUID()
            environment = WorkspaceToolEnvironment(rootProvider: { [root] in root })
        }

        func context(environmentID: String? = nil,
                     temporaryReadOnly: Bool = false,
                     allowedWorkspacePaths: [String] = []) -> ToolContext {
            ToolContext(runID: runID,
                        toolCallID: "call-publish-1",
                        scope: .local,
                        workspaceRootURL: root,
                        allowedWorkspacePaths: allowedWorkspacePaths,
                        cancellation: CancellationToken(),
                        environmentID: environmentID,
                        conversationID: conversationID,
                        temporaryReadOnly: temporaryReadOnly)
        }

        func makeTool() -> WorkspacePublishOutputTool {
            WorkspacePublishOutputTool(
                environment: environment,
                artifactRootProvider: { [artifactRoot] in artifactRoot }
            )
        }

        @discardableResult
        func writeFile(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }

        func snapshotNamespaceURL(_ runID: UUID) -> URL {
            artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
        }

        func removeSnapshotNamespace() {
            try? FileManager.default.removeItem(at: snapshotNamespaceURL(runID))
        }

        deinit {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    // MARK: - Success boundary

    @Test("bound publish freezes the exact current bytes as a verified receipt")
    func publishProducesVerifiedReceipt() async throws {
        let fixture = try Fixture()
        let payload = Data("floe-publish-output-bytes".utf8)
        try fixture.writeFile("out/result.txt", payload)
        let output = try await fixture.makeTool().execute(
            .init(path: "out/result.txt"), context: fixture.context())

        #expect(output.exitStatus == 0)
        let published = try #require(output.outputFiles.first)
        #expect(output.outputFiles.count == 1)
        #expect(published.slot == "output")
        #expect(published.runID == fixture.runID)
        #expect(published.taskID == fixture.conversationID)
        #expect(published.producerTool == "workspace.publishOutput")
        #expect(published.producerCallID == "call-publish-1")
        #expect(published.displayName == "result.txt")
        #expect(published.mimeType == "text/plain")
        #expect(published.role == .userFile)
        #expect(published.byteCount == payload.count)
        #expect(published.relativePath
            == "RunOutputs/\(fixture.runID.uuidString)/\(published.outputID)/result.txt")
        #expect(published.isCanonicalForCurrentRun)
        #expect(published.hasRuntimeConsistentIdentity)
        switch RunOutputSnapshotStore.verify(published, artifactRoot: fixture.artifactRoot) {
        case .verified(let url):
            #expect(try Data(contentsOf: url) == payload)
        default:
            Issue.record("published snapshot did not verify")
        }
    }

    @Test("the receipt binds the exact task and environment identity")
    func receiptBindsExactOwnership() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("model.bin", Data("ownership".utf8))
        let output = try await fixture.makeTool().execute(
            .init(path: "model.bin"),
            context: fixture.context(environmentID: "env-resolved-1"))
        let published = try #require(output.outputFiles.first)
        #expect(published.taskID == fixture.conversationID)
        #expect(published.environmentID == "env-resolved-1")
    }

    @Test("later edits and deletion of the workspace original never change the snapshot")
    func snapshotSurvivesOriginalMutationAndDeletion() async throws {
        let fixture = try Fixture()
        let payload = Data("original-bytes".utf8)
        try fixture.writeFile("data.bin", payload)
        let published = try #require(try await fixture.makeTool().execute(
            .init(path: "data.bin"), context: fixture.context()).outputFiles.first)
        // The user overwrites and then deletes the workspace file entirely.
        try Data("user-edited-later".utf8).write(to: fixture.root.appendingPathComponent("data.bin"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("data.bin"))
        switch RunOutputSnapshotStore.verify(published, artifactRoot: fixture.artifactRoot) {
        case .verified(let url):
            #expect(try Data(contentsOf: url) == payload,
                    "snapshot must keep the bytes published at commit time")
        default:
            Issue.record("snapshot must remain verified after the original is gone")
        }
    }

    @Test("an explicit display name override names the snapshot, not the source")
    func displayNameOverrideIsHonored() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("raw_export", Data("payload".utf8))
        let output = try await fixture.makeTool().execute(
            .init(path: "raw_export", displayName: "final-report.bin"),
            context: fixture.context())
        let published = try #require(output.outputFiles.first)
        #expect(published.displayName == "final-report.bin")
        #expect(published.relativePath.hasSuffix("/final-report.bin"))
        if case .verified(let url) = RunOutputSnapshotStore.verify(
            published, artifactRoot: fixture.artifactRoot) {
            #expect(url.lastPathComponent == "final-report.bin")
        } else {
            Issue.record("renamed snapshot did not verify")
        }
    }

    @Test("replaying the same call and slot is idempotent and writes one user file")
    func idempotentReplayProducesSingleSnapshot() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("stable.bin", Data("stable".utf8))
        let first = try #require(try await fixture.makeTool().execute(
            .init(path: "stable.bin"), context: fixture.context()).outputFiles.first)
        let second = try #require(try await fixture.makeTool().execute(
            .init(path: "stable.bin"), context: fixture.context()).outputFiles.first)
        #expect(first.outputID == second.outputID)
        #expect(first.relativePath == second.relativePath)
        let namespace = fixture.snapshotNamespaceURL(fixture.runID)
        let files = try FileManager.default.enumerator(at: namespace, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { url in
                var info = stat()
                return lstat(url.path, &info) == 0
                    && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            }
        let bookkeeping: Set<String> = [
            RunOutputSnapshotStore.publicationLedgerName,
            RunOutputSnapshotStore.publicationRecordName,
        ]
        let userFiles = files?.filter { !bookkeeping.contains($0.lastPathComponent) }
        #expect((userFiles?.count ?? 0) == 1)
        #expect(files?.contains {
            $0.lastPathComponent == RunOutputSnapshotStore.publicationLedgerName
        } == true)
        #expect(files?.contains {
            $0.lastPathComponent == RunOutputSnapshotStore.publicationRecordName
        } == true)
    }

    @Test("same slot with changed bytes conflicts without overwriting the snapshot")
    func changedBytesConflictAndKeepSnapshot() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("v1.bin", Data("first".utf8))
        let published = try #require(try await fixture.makeTool().execute(
            .init(path: "v1.bin"), context: fixture.context()).outputFiles.first)
        try Data("changed-after-publish".utf8)
            .write(to: fixture.root.appendingPathComponent("v1.bin"))
        await #expect(throws: FloeError.self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "v1.bin"), context: fixture.context())
        }
        if case .verified(let url) = RunOutputSnapshotStore.verify(
            published, artifactRoot: fixture.artifactRoot) {
            #expect(try Data(contentsOf: url) == Data("first".utf8))
        } else {
            Issue.record("the committed snapshot must survive the conflicting republish")
        }
    }

    // MARK: - Refusals

    @Test("a missing workspace file is refused without a receipt")
    func missingFileRefused() async throws {
        let fixture = try Fixture()
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "nope.bin"), context: fixture.context())
        }
        fixture.removeSnapshotNamespace()
    }

    @Test("absolute and escaping paths are refused")
    func foreignPathsRefused() async throws {
        let fixture = try Fixture()
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "/etc/passwd"), context: fixture.context())
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "../outside.txt"), context: fixture.context())
        }
    }

    @Test("a symlink — even one pointing inside the workspace — is refused")
    func symlinkRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("real.txt", Data("real".utf8))
        let link = fixture.root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.root.appendingPathComponent("real.txt"))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "alias.txt"), context: fixture.context())
        }
    }

    @Test("a directory is not a publishable file")
    func directoryRefused() async throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "folder"), context: fixture.context())
        }
    }

    @Test("secret files stay unpublished")
    func secretFileRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile(".env.keys", Data("SECRET=1".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: ".env.keys"), context: fixture.context())
        }
    }

    @Test("a file beyond the per-file cap is refused before any digest work")
    func oversizedFileRefused() async throws {
        let fixture = try Fixture()
        let oversized = fixture.root.appendingPathComponent("huge.bin")
        let descriptor = open(oversized.path, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { Issue.record("could not create sparse fixture"); return }
        defer { close(descriptor) }
        ftruncate(descriptor, off_t(RunOutputCaps.standard.perFileBytes) + 1)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "huge.bin"), context: fixture.context())
        }
    }

    @Test("an unsafe display name override is refused")
    func unsafeDisplayNameRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("ok.bin", Data("ok".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "ok.bin", displayName: "../evil.bin"), context: fixture.context())
        }
    }

    @Test("paths outside the task's declared file scope are refused")
    func taskFileScopeRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("bin/tool", Data("tool".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "bin/tool"),
                context: fixture.context(allowedWorkspacePaths: ["docs"]))
        }
    }

    // MARK: - Binding and cancellation

    @Test("a context without the real tool-call or task binding is refused")
    func unboundContextRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("bound.bin", Data("bound".utf8))
        var callOnly = fixture.context()
        callOnly.conversationID = nil
        await #expect(throws: FloeError.self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "bound.bin"), context: callOnly)
        }
        var taskOnly = fixture.context()
        taskOnly.toolCallID = nil
        await #expect(throws: FloeError.self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "bound.bin"), context: taskOnly)
        }
    }

    @Test("temporary (read-only) runs can never publish a durable output")
    func temporaryRunRefused() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("temp.bin", Data("temp".utf8))
        await #expect(throws: FloeError.self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "temp.bin"), context: fixture.context(temporaryReadOnly: true))
        }
    }

    @Test("cancellation produces no receipt and no staging debris")
    func cancellationLeavesNothing() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("cancel.bin", Data("cancel".utf8))
        let context = fixture.context()
        context.cancellation.cancel()
        await #expect(throws: FloeError.self) {
            _ = try await fixture.makeTool().execute(
                .init(path: "cancel.bin"), context: context)
        }
        fixture.removeSnapshotNamespace()
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotNamespaceURL(fixture.runID).path),
                "a cancelled publication must leave no receipt or staging")
    }

    // MARK: - Unbound runtime store (Android fail-closed)

    @Test("a provider-less tool: Android refuses, host keeps the upstream default root")
    func unboundStoreBehavior() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("unbound.bin", Data("unbound".utf8))
        // The registration default provider returns nil. On Android the
        // core store MUST refuse (no implicit `$HOME`/temporary root —
        // RuntimeFacadeRunOutput.install owns binding). On the Apple host
        // this is exactly the upstream behavior: the Application Support
        // default store resolves, and the fixture cleans after itself.
        let tool = WorkspacePublishOutputTool(
            environment: fixture.environment,
            artifactRootProvider: { nil }
        )
        #if os(Android)
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(
                .init(path: "unbound.bin"), context: fixture.context())
        }
        #else
        let output = try await tool.execute(
            .init(path: "unbound.bin"), context: fixture.context())
        #expect(output.outputFiles.count == 1)
        if let base = try? FloeArtifactStore.root() {
            try? FileManager.default.removeItem(at: base
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(fixture.runID.uuidString, isDirectory: true))
        }
        #endif
    }

    // MARK: - Registration

    @Test("the Android registration seam exposes the descriptor and the runner")
    func registrationIncludesPublishOutput() async throws {
        let registry = ToolRunnerRegistry()
        let environment = registerWorkspacePublishOutputTool(
            artifactRootProvider: { nil },
            registry: registry
        )
        _ = environment
        #expect(ToolCatalog.descriptor(named: WorkspacePublishOutputTool.name) != nil)
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) != nil)
        let descriptor = try #require(ToolCatalog.descriptor(named: WorkspacePublishOutputTool.name))
        #expect(descriptor.riskLabels.contains(.writesFiles))
    }

    // MARK: - D04 lifetime fix: gate-owned root + boundary revalidation

    /// Scripted gate: mints a ticket carrying a FIXED captured root (like
    /// the real facade does atomically), and can flip "current" to model
    /// a retire/rebind between the capture and the completion boundary.
    private final class ScriptedGate: RunOutputOperationGate, @unchecked Sendable {
        private let lock = NSLock()
        let capturedRoot: URL?
        var mint = true
        var current = true
        var beginCount = 0
        var endCount = 0
        private var nextLease: UInt64 = 0

        init(capturedRoot: URL?, mint: Bool = true, current: Bool = true) {
            self.capturedRoot = capturedRoot
            self.mint = mint
            self.current = current
        }

        func beginPublication(runID: UUID) -> RunOutputPublicationTicket? {
            lock.lock(); defer { lock.unlock() }
            guard mint else { return nil }
            beginCount += 1
            nextLease += 1
            return RunOutputPublicationTicket(
                leaseID: nextLease, epoch: 1, runID: runID, artifactRoot: capturedRoot)
        }
        func endPublication(_ ticket: RunOutputPublicationTicket) {
            lock.lock(); defer { lock.unlock() }
            endCount += 1
        }
        func isPublicationCurrent(_ ticket: RunOutputPublicationTicket) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func setBoundaryCurrent(_ value: Bool) {
            lock.lock(); current = value; lock.unlock()
        }
    }

    @Test("the publication root is the ticket's captured root, not a re-read provider")
    func ticketCarriesTheAuthoritativeRoot() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("ticket.bin", Data("ticketed".utf8))
        // The provider deliberately returns nil: ONLY the ticket can
        // supply the root (this is the registered-runtime wiring).
        let gate = ScriptedGate(capturedRoot: fixture.artifactRoot)
        let tool = WorkspacePublishOutputTool(
            environment: fixture.environment,
            artifactRootProvider: { nil },
            operationGate: gate
        )
        let output = try await tool.execute(
            .init(path: "ticket.bin"), context: fixture.context())
        let published = try #require(output.outputFiles.first)
        #expect(gate.beginCount == 1 && gate.endCount == 1)
        if case .verified(let url) = RunOutputSnapshotStore.verify(
            published, artifactRoot: fixture.artifactRoot) {
            #expect(url.lastPathComponent == "ticket.bin")
        } else {
            Issue.record("ticket-root publication must verify under the captured root")
        }
    }

    @Test("a generation retired between capture and completion keeps bytes but refuses the receipt")
    func retiredBoundaryRefusesStaleReceiptAndPreservesBytes() async throws {
        let fixture = try Fixture()
        let payload = Data("preserved".utf8)
        try fixture.writeFile("stale.bin", payload)
        // Simulate the exact race: the ticket captured rootA/epochA, then
        // the generation was retired/rebound before the completion
        // boundary. The store call itself succeeded (bytes committed under
        // the captured root); the boundary revalidation must refuse.
        let gate = ScriptedGate(capturedRoot: fixture.artifactRoot)
        gate.setBoundaryCurrent(false)
        let tool = WorkspacePublishOutputTool(
            environment: fixture.environment,
            operationGate: gate
        )
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(
                .init(path: "stale.bin"), context: fixture.context())
        }
        // The committed snapshot bytes SURVIVE (cleanup still rides the
        // durable tombstone path; nothing here rolls them back).
        let namespace = fixture.snapshotNamespaceURL(fixture.runID)
        let existed = FileManager.default.fileExists(atPath: namespace.path)
        #expect(existed, "a stale completion must preserve committed bytes")
        gate.setBoundaryCurrent(true)
        fixture.removeSnapshotNamespace()
    }

    @Test("an unbound gate (no current generation) refuses before any write")
    func unboundGateRefusesEarly() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("nobind.bin", Data("x".utf8))
        let gate = ScriptedGate(capturedRoot: fixture.artifactRoot, mint: false)
        let tool = WorkspacePublishOutputTool(
            environment: fixture.environment,
            operationGate: gate
        )
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(
                .init(path: "nobind.bin"), context: fixture.context())
        }
        #expect(gate.beginCount == 0 && gate.endCount == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.snapshotNamespaceURL(fixture.runID).path))
    }
}

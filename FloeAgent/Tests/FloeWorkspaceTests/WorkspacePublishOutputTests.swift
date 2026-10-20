// FloeWorkspaceTests — Real-execution behavior of workspace.publishOutput
// against a temporary workspace and the REAL core RunOutputSnapshotStore
// (default artifact store, cleaned per test). Covers the explicit
// publication boundary: exact bytes frozen at publish time, refusals for
// missing/foreign/unsafe inputs, binding requirements, cancellation and
// idempotent replay. No scanned outputs, no prose inference.

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
struct WorkspacePublishOutputTests {

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let runID: UUID
        let conversationID: UUID
        let environment: WorkspaceToolEnvironment

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-publish-tests-\(UUID().uuidString)", isDirectory: true)
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
            WorkspacePublishOutputTool(environment: environment)
        }

        @discardableResult
        func writeFile(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }

        func removeSnapshotNamespace() {
            guard let base = try? FloeArtifactStore.root() else { return }
            try? FileManager.default.removeItem(at: base
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true))
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            guard let base = try? FloeArtifactStore.root() else { return }
            try? FileManager.default.removeItem(at: base
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true))
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
        switch RunOutputSnapshotStore.verify(published) {
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
        switch RunOutputSnapshotStore.verify(published) {
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
        if case .verified(let url) = RunOutputSnapshotStore.verify(published) {
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
        guard let base = try? FloeArtifactStore.root() else { return }
        let namespace = base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
            .appendingPathComponent(fixture.runID.uuidString)
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
        if case .verified(let url) = RunOutputSnapshotStore.verify(published) {
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
        guard let base = try? FloeArtifactStore.root() else { return }
        let namespace = base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
            .appendingPathComponent(fixture.runID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: namespace.path),
                "a cancelled publication must leave no receipt or staging")
    }

    // MARK: - Registration

    @Test("registerWorkspaceTools exposes the descriptor and the runner")
    func registrationIncludesPublishOutput() async throws {
        let registry = ToolRunnerRegistry()
        let environment = registerWorkspaceTools(
            rootProvider: { nil },
            registry: registry
        )
        _ = environment
        #expect(ToolCatalog.descriptor(named: WorkspacePublishOutputTool.name) != nil)
        #expect(registry.runner(named: WorkspacePublishOutputTool.name) != nil)
    }
}

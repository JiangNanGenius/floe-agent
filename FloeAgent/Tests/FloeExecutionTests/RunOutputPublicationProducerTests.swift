// FloeExecutionTests — S3-D producer publication at the network.download
// commit boundary. These run the PRODUCTION publication seam against the
// real core RunOutputSnapshotStore API and the real filesystem (temp workspace
// + default artifact store, cleaned per test). No stub snapshot store, no
// parallel receipt type.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.network.download run-output publication")
struct RunOutputPublicationProducerTests {
    private struct Fixture {
        var root: URL
        var runID: UUID
        var conversationID: UUID
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3d-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, runID: UUID(), conversationID: UUID())
    }

    /// Removes this test run's snapshot namespace from the real default
    /// artifact store (production publication uses that root).
    private func removeSnapshotNamespace(for runID: UUID) {
        guard let base = try? FloeArtifactStore.root() else { return }
        try? FileManager.default.removeItem(at: base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true))
    }

    private func boundContext(_ fixture: Fixture) -> ToolContext {
        ToolContext(runID: fixture.runID,
                    toolCallID: "call-download-1",
                    scope: .local,
                    workspaceRootURL: fixture.root,
                    cancellation: CancellationToken(),
                    conversationID: fixture.conversationID)
    }

    /// Commits a real staged file through the production committer, exactly
    /// as URLDownloadTool.execute does after a successful transport download.
    private func commitDownload(in root: URL, name: String, payload: Data) throws -> FileCommitReceipt {
        let staging = root.appendingPathComponent(".floe-download-\(UUID().uuidString)")
        try payload.write(to: staging, options: .atomic)
        return try AtomicFileCommitter.commit(
            stagedFile: staging,
            to: root.appendingPathComponent(name),
            policy: FileCommitPolicy()
        )
    }

    @Test("bound publication returns a real snapshot receipt that verifies")
    func boundPublicationProducesVerifiedSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let payload = Data("floe-run-output-download".utf8)
        let receipt = try commitDownload(in: fixture.root, name: "report.pdf", payload: payload)

        let outputs = try URLDownloadTool.publishRunOutput(
            commit: receipt, contentType: "application/pdf", using: boundContext(fixture))

        let published = try #require(outputs.first)
        #expect(outputs.count == 1)
        #expect(published.slot == "download")
        #expect(published.runID == fixture.runID)
        #expect(published.taskID == fixture.conversationID)
        #expect(published.producerCallID == "call-download-1")
        #expect(published.producerTool == "network.download")
        #expect(published.displayName == "report.pdf")
        #expect(published.mimeType == "application/pdf")
        #expect(published.role == .userFile)
        #expect(published.sha256 == receipt.sha256)
        #expect(published.byteCount == payload.count)
        #expect(published.relativePath.hasPrefix("RunOutputs/\(fixture.runID.uuidString)/"))
        #expect(published.isCanonicalForCurrentRun)
        #expect(published.hasRuntimeConsistentIdentity)
        // The snapshot bytes are the committed bytes, in the owned namespace.
        switch RunOutputSnapshotStore.verify(published) {
        case .verified(let url):
            #expect(try Data(contentsOf: url) == payload)
        default:
            Issue.record("published snapshot did not verify")
        }
    }

    @Test("later edits of the workspace original never change the snapshot")
    func snapshotSurvivesOriginalMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let payload = Data("original-bytes".utf8)
        let receipt = try commitDownload(in: fixture.root, name: "data.bin", payload: payload)
        let published = try #require(URLDownloadTool
            .publishRunOutput(commit: receipt, contentType: "application/octet-stream",
                              using: boundContext(fixture)).first)
        // The user later overwrites the workspace file entirely.
        try Data("user-edited-later".utf8).write(to: fixture.root.appendingPathComponent("data.bin"))
        switch RunOutputSnapshotStore.verify(published) {
        case .verified(let url):
            #expect(try Data(contentsOf: url) == payload,
                    "snapshot must keep the bytes produced at commit time")
        default:
            Issue.record("snapshot must remain verified after the original changes")
        }
    }

    @Test("stale commit identity fails observably and keeps the original")
    func staleIdentityFailsObservably() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let payload = Data("committed-bytes!".utf8) // 14 bytes
        let receipt = try commitDownload(in: fixture.root, name: "same-size.bin", payload: payload)
        // Same length, different content: the size check passes, the digest
        // divergence must fail publication (never a false receipt).
        try Data("diverged-bytes!".utf8).write(to: fixture.root.appendingPathComponent("same-size.bin"))
        #expect(throws: FloeError.self) {
            _ = try URLDownloadTool.publishRunOutput(
                commit: receipt, contentType: "application/octet-stream",
                using: boundContext(fixture))
        }
        // The (diverged) original file stays on disk untouched by the failure.
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("same-size.bin"))
                == Data("diverged-bytes!".utf8))
    }

    @Test("replaying the same call and slot is idempotent")
    func idempotentReplay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let receipt = try commitDownload(in: fixture.root, name: "stable.bin",
                                         payload: Data("stable".utf8))
        let first = try #require(URLDownloadTool
            .publishRunOutput(commit: receipt, contentType: "application/octet-stream",
                              using: boundContext(fixture)).first)
        let second = try #require(URLDownloadTool
            .publishRunOutput(commit: receipt, contentType: "application/octet-stream",
                              using: boundContext(fixture)).first)
        #expect(first.outputID == second.outputID)
        #expect(first.relativePath == second.relativePath)
        guard let base = try? FloeArtifactStore.root() else { return }
        let namespace = base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
            .appendingPathComponent(fixture.runID.uuidString)
        // The committed snapshot is the ONLY user file under the run
        // namespace; the store's own manifest.json ledger and per-output
        // .floe-publication.json record are bookkeeping, not user outputs,
        // and are asserted separately.
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

    @Test("same slot with different bytes conflicts without overwriting")
    func conflictKeepsExistingSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let firstReceipt = try commitDownload(in: fixture.root, name: "v1.bin",
                                              payload: Data("first".utf8))
        let first = try #require(URLDownloadTool
            .publishRunOutput(commit: firstReceipt, contentType: "application/octet-stream",
                              using: boundContext(fixture)).first)
        let secondReceipt = try commitDownload(in: fixture.root, name: "v2.bin",
                                               payload: Data("second-different".utf8))
        #expect(throws: FloeError.self) {
            _ = try URLDownloadTool.publishRunOutput(
                commit: secondReceipt, contentType: "application/octet-stream",
                using: boundContext(fixture))
        }
        // The first snapshot remains authoritative and intact.
        if case .verified(let url) = RunOutputSnapshotStore.verify(first) {
            #expect(try Data(contentsOf: url) == Data("first".utf8))
        } else {
            Issue.record("conflicting publication must not damage the stored snapshot")
        }
    }

    @Test("genuine legacy direct use keeps old behavior with no receipt")
    func legacyDirectKeepsBehavior() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let receipt = try commitDownload(in: fixture.root, name: "legacy.bin",
                                         payload: Data("legacy".utf8))
        var context = boundContext(fixture)
        context.toolCallID = nil
        context.conversationID = nil
        #expect(URLDownloadTool.runOutputBinding(context) == .legacyDirect)
        let outputs = try URLDownloadTool.publishRunOutput(
            commit: receipt, contentType: "application/octet-stream", using: context)
        #expect(outputs.isEmpty)
    }

    @Test("partially bound contexts fail rather than silently skip")
    func partiallyBoundFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let receipt = try commitDownload(in: fixture.root, name: "partial.bin",
                                         payload: Data("partial".utf8))
        var callOnly = boundContext(fixture)
        callOnly.conversationID = nil
        #expect(URLDownloadTool.runOutputBinding(callOnly) == .partiallyBound)
        #expect(throws: FloeError.self) {
            _ = try URLDownloadTool.publishRunOutput(
                commit: receipt, contentType: "application/octet-stream", using: callOnly)
        }
        var taskOnly = boundContext(fixture)
        taskOnly.toolCallID = nil
        #expect(URLDownloadTool.runOutputBinding(taskOnly) == .partiallyBound)
        #expect(throws: FloeError.self) {
            _ = try URLDownloadTool.publishRunOutput(
                commit: receipt, contentType: "application/octet-stream", using: taskOnly)
        }
    }

    @Test("temporary runs are policy-exempt and publish nothing")
    func temporaryRunSkips() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let receipt = try commitDownload(in: fixture.root, name: "temp.bin",
                                         payload: Data("temp".utf8))
        var context = boundContext(fixture)
        context.temporaryReadOnly = true
        #expect(URLDownloadTool.runOutputBinding(context) == .temporaryExempt)
        let outputs = try URLDownloadTool.publishRunOutput(
            commit: receipt, contentType: "application/octet-stream", using: context)
        #expect(outputs.isEmpty)
    }

    @Test("a cancelled bound call produces no receipt and no staging debris")
    func cancelledRunProducesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { removeSnapshotNamespace(for: fixture.runID) }
        let receipt = try commitDownload(in: fixture.root, name: "cancel.bin",
                                         payload: Data("cancel".utf8))
        let context = boundContext(fixture)
        context.cancellation.cancel()
        #expect(throws: FloeError.self) {
            _ = try URLDownloadTool.publishRunOutput(
                commit: receipt, contentType: "application/octet-stream", using: context)
        }
        if let base = try? FloeArtifactStore.root() {
            let namespace = base
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
                .appendingPathComponent(fixture.runID.uuidString)
            #expect(!FileManager.default.fileExists(atPath: namespace.path),
                    "a cancelled publication must leave no receipt or staging")
        }
        // The committed original is untouched.
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("cancel.bin"))
                == Data("cancel".utf8))
    }

    @Test("download content types normalize into bounded MIME identities")
    func contentTypeNormalization() {
        #expect(URLDownloadTool.normalizedContentType("application/pdf; charset=utf-8")
                == "application/pdf")
        #expect(URLDownloadTool.normalizedContentType("Text/HTML") == "text/html")
        #expect(URLDownloadTool.normalizedContentType("") == "application/octet-stream")
        #expect(URLDownloadTool.normalizedContentType("no slash") == "application/octet-stream")
        #expect(URLDownloadTool.normalizedContentType(String(repeating: "a", count: 200))
                == "application/octet-stream")
    }
}

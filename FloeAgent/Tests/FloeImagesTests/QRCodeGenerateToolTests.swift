import Foundation
import CoreGraphics
import ImageIO
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeImages

@Suite("FloeImages.QRCodeGenerate")
struct QRCodeGenerateToolTests {

    @Test("descriptor is mutating and file-writing")
    func descriptorContract() {
        #expect(QRCodeGenerateTool.name == "image.qr.generate")
        #expect(QRCodeGenerateTool.isSideEffecting)
        #expect(QRCodeGenerateTool.riskLabels == [.writesFiles])
    }

    @Test("validation enforces content, size, level and safe paths")
    func validation() {
        let tool = QRCodeGenerateTool(rootProvider: { nil })
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: String(repeating: "x", count: 2_001))) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", size: 4_096)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", correctionLevel: "X")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", outputPath: "../out.png")) }
        try! tool.validate(.init(content: "https://floe.example", size: 256, correctionLevel: "h"))
    }

    @Test("generation writes a decodable PNG of the requested size")
    func generation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-qr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = QRCodeGenerateTool(rootProvider: { root })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())

        let output = try await tool.execute(
            .init(content: "https://floe.example/qr", size: 256, outputPath: "codes/site.png"),
            context: context
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("codes/site.png"))
        // Unbound (legacy direct) contexts keep the old workspace-only result:
        // no durable run output exists for them and none is fabricated.
        #expect(output.outputFiles.isEmpty)
        let url = root.appendingPathComponent("codes/site.png")
        let image = try #require(
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            }
        )
        #expect(image.width == 256)
        #expect(image.height == 256)

        // Existing destinations are never overwritten.
        let second = try await tool.execute(
            .init(content: "again", outputPath: "codes/site.png"),
            context: context
        )
        #expect(second.exitStatus == 2)
    }

    // MARK: - S3-D run-output publication (chat return)

    private struct BoundScratch {
        let workspaceRoot: URL
        let artifactRoot: URL
        let workspace: URL
        func cleanup() { try? FileManager.default.removeItem(at: workspaceRoot) }
    }

    private func makeBoundScratch(_ label: String) throws -> BoundScratch {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-qr-\(label)-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let artifactRoot = base.appendingPathComponent("ArtifactStore", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return BoundScratch(workspaceRoot: base, artifactRoot: artifactRoot, workspace: workspace)
    }

    private func boundContext(
        runID: UUID = UUID(),
        conversationID: UUID = UUID(),
        callID: String = "qr-call-1",
        temporaryReadOnly: Bool = false
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: callID,
            cancellation: CancellationToken(),
            environmentID: "env-qr-test",
            conversationID: conversationID,
            temporaryReadOnly: temporaryReadOnly
        )
    }

    @Test("a bound run publishes the generated PNG as a chat-verifiable receipt")
    func boundRunPublishesImageReceipt() async throws {
        let scratch = try makeBoundScratch("receipt")
        defer { scratch.cleanup() }
        let runID = UUID()
        let conversationID = UUID()
        let context = boundContext(runID: runID, conversationID: conversationID)
        let tool = QRCodeGenerateTool(
            rootProvider: { scratch.workspace },
            artifactRootProvider: { scratch.artifactRoot }
        )

        let output = try await tool.execute(
            .init(content: "https://floe.example/qr", size: 256, outputPath: "codes/bound.png"),
            context: context
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        let receipt = try #require(output.outputFiles.first)
        // Exact fields the runtime seal and the chat receipt gate require.
        #expect(receipt.producerTool == QRCodeGenerateTool.name)
        #expect(receipt.producerCallID == "qr-call-1")
        #expect(receipt.runID == runID)
        #expect(receipt.taskID == conversationID)
        #expect(receipt.environmentID == "env-qr-test")
        #expect(receipt.slot == QRCodeGenerateTool.outputSlot)
        #expect(receipt.role == .userFile)
        #expect(receipt.mimeType == "image/png")
        #expect(receipt.displayName == "bound.png")
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(receipt.hasRuntimeConsistentIdentity)

        // The snapshot is a real, decodable PNG owned by this run: the chat
        // card path (RunOutputSnapshotStore.verify → QuickLook preview) works.
        guard case .verified(let snapshotURL) = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: scratch.artifactRoot
        ) else {
            Issue.record("published snapshot failed verification")
            return
        }
        let image = try #require(
            CGImageSourceCreateWithURL(snapshotURL as CFURL, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            }
        )
        #expect(image.width == 256 && image.height == 256)

        // Later edits/deletion of the workspace original never change the
        // run's frozen bytes.
        try Data("not a png anymore".utf8).write(
            to: scratch.workspace.appendingPathComponent("codes/bound.png")
        )
        guard case .verified = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: scratch.artifactRoot
        ) else {
            Issue.record("snapshot bytes changed after the workspace original was edited")
            return
        }
    }

    @Test("a replay of the same call and identical bytes returns the same receipt")
    func replayOfIdenticalCommitIsIdempotent() async throws {
        let scratch = try makeBoundScratch("replay")
        defer { scratch.cleanup() }
        let context = boundContext()
        let tool = QRCodeGenerateTool(
            rootProvider: { scratch.workspace },
            artifactRootProvider: { scratch.artifactRoot }
        )
        let first = try await tool.execute(
            .init(content: "same payload", size: 64, outputPath: "codes/replay.png"),
            context: context
        )
        #expect(first.exitStatus == 0)
        let receipt = try #require(first.outputFiles.first)

        // A same-call retry cannot rewrite the workspace destination (the
        // tool never overwrites), but publishing the identical committed
        // bytes again through the store replays deterministically — this is
        // what protects the chat from duplicate cards for one call.
        let replayed = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: QRCodeGenerateTool.name,
                slot: QRCodeGenerateTool.outputSlot,
                commit: RunOutputCommit(
                    sourceURL: scratch.workspace.appendingPathComponent("codes/replay.png"),
                    sha256: receipt.sha256,
                    byteCount: receipt.byteCount,
                    displayName: receipt.displayName,
                    mimeType: "image/png",
                    uti: "public.png"
                )
            ),
            using: context,
            artifactRoot: scratch.artifactRoot
        )
        #expect(replayed == receipt)
    }

    @Test("a different image under the same call and slot conflicts without duplicating")
    func sameCallDifferentOutputConflicts() async throws {
        let scratch = try makeBoundScratch("conflict")
        defer { scratch.cleanup() }
        let context = boundContext()
        let tool = QRCodeGenerateTool(
            rootProvider: { scratch.workspace },
            artifactRootProvider: { scratch.artifactRoot }
        )
        let first = try await tool.execute(
            .init(content: "first payload", size: 64, outputPath: "codes/a.png"),
            context: context
        )
        #expect(first.exitStatus == 0)
        let receipt = try #require(first.outputFiles.first)

        // Same real call, same slot, different committed bytes: honest
        // conflict. Nothing overwrites or silently duplicates the first
        // output, and the second workspace file stays preserved.
        let second = try await tool.execute(
            .init(content: "second payload", size: 64, outputPath: "codes/b.png"),
            context: context
        )
        #expect(second.exitStatus == 2)
        #expect(second.outputFiles.isEmpty)
        #expect(second.summary.contains("status=error"))
        #expect(second.summary.contains("conflict"))
        #expect(second.summary.contains("preserved"))
        guard case .verified = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: scratch.artifactRoot
        ) else {
            Issue.record("the first snapshot must survive a conflicting retry")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: scratch.workspace.appendingPathComponent("codes/b.png").path
        ))
    }

    @Test("temporary runs keep the legacy text result and publish no durable output")
    func temporaryContextPublishesNothing() async throws {
        let scratch = try makeBoundScratch("temporary")
        defer { scratch.cleanup() }
        let context = boundContext(temporaryReadOnly: true)
        let tool = QRCodeGenerateTool(
            rootProvider: { scratch.workspace },
            artifactRootProvider: { scratch.artifactRoot }
        )
        let output = try await tool.execute(
            .init(content: "ephemeral", size: 64, outputPath: "codes/temp.png"),
            context: context
        )
        #expect(output.exitStatus == 0)
        #expect(output.outputFiles.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: scratch.workspace.appendingPathComponent("codes/temp.png").path
        ))
        let namespaces = try? FileManager.default.contentsOfDirectory(atPath: scratch.artifactRoot.path)
        #expect(namespaces == nil || namespaces?.isEmpty == true)
    }

    @Test("a partially bound context fails observably and preserves the file")
    func partiallyBoundFailsHonestly() async throws {
        let scratch = try makeBoundScratch("partial")
        defer { scratch.cleanup() }
        let context = ToolContext(
            runID: UUID(),
            toolCallID: "qr-partial",
            cancellation: CancellationToken()
        )
        let tool = QRCodeGenerateTool(
            rootProvider: { scratch.workspace },
            artifactRootProvider: { scratch.artifactRoot }
        )
        let output = try await tool.execute(
            .init(content: "partial binding", size: 64, outputPath: "codes/partial.png"),
            context: context
        )
        #expect(output.exitStatus == 2)
        #expect(output.outputFiles.isEmpty)
        #expect(output.summary.contains("binding"))
        // The written workspace original is never rolled back.
        #expect(FileManager.default.fileExists(
            atPath: scratch.workspace.appendingPathComponent("codes/partial.png").path
        ))
    }

    @Test("binding policy classifies every producer context")
    func bindingPolicy() {
        let full = boundContext()
        #expect(QRCodeGenerateTool.runOutputBinding(full) == .required)
        let legacy = ToolContext(runID: UUID(), cancellation: CancellationToken())
        #expect(QRCodeGenerateTool.runOutputBinding(legacy) == .legacyDirect)
        let temp = boundContext(temporaryReadOnly: true)
        #expect(QRCodeGenerateTool.runOutputBinding(temp) == .temporaryExempt)
        let callOnly = ToolContext(
            runID: UUID(), toolCallID: "x", cancellation: CancellationToken()
        )
        #expect(QRCodeGenerateTool.runOutputBinding(callOnly) == .partiallyBound)
        let taskOnly = ToolContext(
            runID: UUID(), cancellation: CancellationToken(), conversationID: UUID()
        )
        #expect(QRCodeGenerateTool.runOutputBinding(taskOnly) == .partiallyBound)
        let emptyCall = ToolContext(
            runID: UUID(), toolCallID: "", cancellation: CancellationToken(),
            conversationID: UUID()
        )
        #expect(QRCodeGenerateTool.runOutputBinding(emptyCall) == .partiallyBound)
    }
}

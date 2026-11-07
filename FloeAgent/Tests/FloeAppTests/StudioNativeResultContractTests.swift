// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeModels
@testable import FloeApp

@Suite("Registered native frame and result publication", .serialized)
@MainActor struct StudioNativeResultContractTests {
    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let output = try await execute(name, args, context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func contexts(_ body: @MainActor (ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        var ids: [UUID] = [], contexts: [ToolContext] = [], leases: [WorkspaceCenter.TaskRootLease] = []
        func cleanup() async {
            for lease in leases { lease.release(); try? FileManager.default.removeItem(at: lease.url) }
            for context in contexts {
                if let root = try? FloeArtifactStore.root() {
                    for relative in ["RunOutputs/\(context.runID.uuidString)", "GeneratedImages/Studio/\(context.runID.uuidString)"] {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(relative))
                    }
                }
            }
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
        }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "N13 audio contract", createdAt: now, updatedAt: now))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                let workspace = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "N13 audio contract")
                let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: id); leases.append(lease)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Observe native audio", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "n13-fixture", allowedToolNames: StudioCoordinator.names,
                    workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID() // Trusted fixture host only; never a model-minted grant.
                contexts.append(context)
            }
            try await body(contexts[0], contexts[1]); await cleanup()
        } catch { await cleanup(); throw error }
    }
    private func withOriginal(_ kind: String, context original: ToolContext,
                              body: @MainActor (UUID, URL, ToolContext) async throws -> Void) async throws {
        var context = original; context.toolCallID = "n13-create-" + UUID().uuidString
        let created = try await invoke("studio.create", ["kind": kind, "title": "N13 audio \(UUID().uuidString.prefix(8))"], context)
        let text = try #require((created["record"] as? [String: Any])?["id"] as? String), id = try #require(UUID(uuidString: text))
        let library = try await PersonalContentService.shared.library(), location = try await library.resolve(id)
        context.approvalGrantID = nil
        do {
            try await body(id, location.url, context)
            try await PersonalLibraryFileActions.delete(try await library.resolve(id).record, environment: FloeAgentApp.liveEnvironment)
        } catch {
            if let current = try? await library.resolve(id) { try? await PersonalLibraryFileActions.delete(current.record, environment: FloeAgentApp.liveEnvironment) }
            throw error
        }
    }

    private func execute(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        return try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
    }
    private func frame(_ id: UUID, revision: Int64, seconds: Double = 0, context: ToolContext) async throws -> ToolExecutionOutput {
        try await execute("studio.run", ["projectID": id.uuidString, "action": "inspectFrame",
            "inputJSON": json(["expectedRevision": String(revision), "seconds": seconds, "maximumPixelSize": 128])], context)
    }
    private func movie(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?; try #require(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel); CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, Int32(30 + frame * 60), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)))
        }
        input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
    }

    @Test func registeredImageFrameIsRealPixelEvidenceAndExportPublishesStableRunOutput() async throws {
        try await contexts { first, other in
            try await withOriginal("image", context: first) { id, root, context in
                let session = try await PersonalMediaFactory.session(id: id, directory: root)
                var editing = context; editing.approvalGrantID = UUID(); editing.toolCallID = "n13-fill-pixels"
                _ = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": "image.fill",
                    "inputJSON": json(["expectedRevision": String(session.document.revision), "color": "#FF0000"])], editing)
                let before = session.document, library = try await PersonalContentService.shared.library()
                let modified = try await library.resolve(id).record.modifiedAt
                let observed = try await frame(id, revision: before.revision, context: context)
                let reference = try #require(observed.artifacts.first), image = try VerifiedToolImageArtifact.load(reference, root: FloeArtifactStore.root())
                #expect(observed.artifacts.count == 1 && observed.outputFiles.isEmpty && reference.mimeType == "image/png")
                #expect(reference.relativePath.hasPrefix("GeneratedImages/Studio/" + context.runID.uuidString + "/"))
                let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil)), cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                var pixel = [UInt8](repeating: 0, count: 4)
                let bitmap = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                #expect(pixel[0] > 200 && pixel[1] < 30 && pixel[2] < 30, "The real compositor must show the actual red layer")
                let currentModifiedAt = try await library.resolve(id).record.modifiedAt
                #expect(session.document == before && currentModifiedAt == modified)
                do { _ = try await frame(id, revision: before.revision, context: other); Issue.record("Another task captured this original") } catch {}
                do { _ = try await frame(id, revision: before.revision - 1, context: context); Issue.record("A stale frame revision was accepted") } catch {}
                editing.toolCallID = "n13-export-stable-result"
                let exported = try await execute("studio.run", ["projectID": id.uuidString, "action": "exportMedia"], editing)
                let output = try #require(exported.outputFiles.first)
                #expect(exported.outputFiles.count == 1 && output.runID == context.runID && output.taskID == context.conversationID && output.producerTool == "studio.run")
                guard case .verified(let url) = RunOutputSnapshotStore.verify(output) else { Issue.record("Published native result is not verifiable"); return }
                let bytes = try Data(contentsOf: url), original = try #require(session.exportedFile)
                let originalBytes = try Data(contentsOf: original)
                #expect(StudioToolOutput.hash(bytes) == output.sha256 && bytes == originalBytes)
                try FileManager.default.removeItem(at: original)
                #expect(RunOutputSnapshotStore.verify(output) == .verified(url: url), "A saved result must outlive its mutable original export")
            }
        }
    }

    @Test func registeredSilentVideoFrameRendersActualDifferentTimesWithoutPlayback() async throws {
        try await contexts { context, _ in
            try await withOriginal("video", context: context) { id, root, context in
                let file = try #require(context.workspaceRootURL).appendingPathComponent("Attachments/frame-fixture.mp4")
                try await movie(file)
                let session = try await PersonalMediaFactory.session(id: id, directory: root)
                _ = try await session.importAuthorizedFile(file, expectedRevision: session.document.revision)
                let before = session.document
                let first = try #require(try await frame(id, revision: before.revision, context: context).artifacts.first)
                let next = try #require(try await frame(id, revision: before.revision, seconds: 0.5, context: context).artifacts.first)
                #expect(first.sha256 != next.sha256, "Distinct native source frames must not reuse an icon or cached first frame")
                let artifactRoot = try FloeArtifactStore.root()
                _ = try VerifiedToolImageArtifact.load(first, root: artifactRoot); _ = try VerifiedToolImageArtifact.load(next, root: artifactRoot)
                #expect(session.document == before && session.player == nil && !session.rendering)
            }
        }
    }
}
#endif

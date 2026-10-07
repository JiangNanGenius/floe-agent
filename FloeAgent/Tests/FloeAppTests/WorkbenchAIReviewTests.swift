// FloeAppTests — Workbench AI review + ownership contract.
//
// These tests pin the two review findings that looked correct in the UI but
// discarded the user's confirmed choices: `confirmImageGeneration` used to
// always pass `sourceURL: nil` (image edits silently became plain
// generations) and `confirmVideoGeneration` rebuilt an all-nil options value
// (duration/aspect/resolution were dropped). They also pin the ownership gate
// that used to treat absent caller context as a wildcard.

#if canImport(UIKit)
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
@testable import FloeApp

private func makePNG(at url: URL, width: Int = 64, height: Int = 64) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@MainActor
private final class BridgeRecorder: Sendable {
    struct ImageCall: Sendable {
        var prompt: String
        var modelID: UUID
        var size: String?
        var count: Int
        var sourceURL: URL?
    }
    struct VideoCall: Sendable {
        var prompt: String
        var modelID: UUID
        var options: WorkbenchVideoAIOptions
        var projectID: UUID
    }

    var imageCalls: [ImageCall] = []
    var videoCalls: [VideoCall] = []
    var generatedImageURL: URL?
}

@Suite("FloeApp.Workbench AI review")
@MainActor
struct WorkbenchAIReviewTests {
    private func makeCenter(root: URL, recorder: BridgeRecorder) -> WorkbenchCenter {
        let modelID = UUID()
        let bridge = WorkbenchAIBridge(
            isAvailable: { true },
            imageModels: { [WorkbenchAIModelInfo(id: modelID, displayName: "Mock Image",
                                                 remoteModelID: "mock-image",
                                                 providerName: "Mock")] },
            videoModels: { [WorkbenchAIModelInfo(id: modelID, displayName: "Mock Video",
                                                 remoteModelID: "mock-video",
                                                 providerName: "Mock")] },
            generateImages: { prompt, model, size, count, sourceURL in
                recorder.imageCalls.append(.init(prompt: prompt, modelID: model, size: size,
                                                 count: count, sourceURL: sourceURL))
                if let url = recorder.generatedImageURL {
                    return [url]
                }
                return []
            },
            submitVideo: { prompt, model, options, projectID, _ in
                recorder.videoCalls.append(.init(prompt: prompt, modelID: model, options: options,
                                                 projectID: projectID))
                return UUID()
            },
            refreshJob: { jobID in
                WorkbenchAIJobInfo(id: jobID, state: "running", progress: nil, message: nil,
                                   isActive: true, isWaitStopped: false, modelName: "")
            },
            cancelJob: { _ in },
            jobs: { _ in [] },
            deliverResult: { _ in
                throw FloeError.notFound("no result")
            },
            costNote: { _ in "Mock pricing note" })
        return WorkbenchCenter(rootProvider: { root }, bridge: bridge)
    }

    private func makeImageProject(center: WorkbenchCenter, root: URL,
                                  owner: WorkbenchCenter.Owner = .standalone) async throws -> (id: UUID, sourceURL: URL) {
        let imageURL = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: imageURL)
        await center.startImageProject(sourceURL: imageURL, owner: owner)
        let project = try #require(center.project, "image project must open")
        return (project.id, imageURL)
    }

    @Test func confirmedImageEditKeepsReviewedSourceSizeAndCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BridgeRecorder()
        recorder.generatedImageURL = root.appendingPathComponent("candidate-\(UUID().uuidString).png")
        try makePNG(at: recorder.generatedImageURL!)
        let center = makeCenter(root: root, recorder: recorder)
        _ = try await makeImageProject(center: center, root: root)
        let assetID = try #require(center.project?.assets.first?.id)

        center.prepareImageGeneration(prompt: "edit this", modelID: UUID(),
                                      size: "2K", count: 3, sourceAssetID: assetID)
        let review = try #require(center.aiReview)
        guard case .image(let size, let count, let sourceAssetID) = review.payload else {
            Issue.record("review payload must be an image payload")
            return
        }
        #expect(size == "2K")
        #expect(count == 3)
        #expect(sourceAssetID == assetID)
        #expect(review.assetNames.count == 1, "the referenced asset is shown on the review sheet")

        await center.confirmImageGeneration(review)
        let call = try #require(recorder.imageCalls.first)
        #expect(call.size == "2K", "confirmed size must be submitted, not discarded")
        #expect(call.count == 3, "confirmed count must be submitted")
        let sourceURL = try #require(call.sourceURL, "image edit must submit the reviewed source asset")
        #expect(sourceURL.lastPathComponent.contains("source-"),
                "submitted source must be the project asset, got \(sourceURL.lastPathComponent)")
        #expect(center.candidates.count == 1)

        // Durable recovery: a second center sees the candidate after reopen.
        try await Task.sleep(for: .milliseconds(400))
        let reopened = makeCenter(root: root, recorder: BridgeRecorder())
        await reopened.openProject(id: try #require(center.project?.id))
        #expect(reopened.candidates.count == 1,
                "delivered candidate must survive closing/reopening the project")
    }

    @Test func confirmedVideoJobKeepsReviewedOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BridgeRecorder()
        let center = makeCenter(root: root, recorder: recorder)
        _ = try await makeImageProject(center: center, root: root)

        let options = WorkbenchVideoAIOptions(durationSeconds: 8, aspectRatio: "9:16", resolution: "1080p")
        center.prepareVideoGeneration(prompt: "animate", modelID: UUID(), options: options)
        let review = try #require(center.aiReview)
        guard case .video(let reviewed) = review.payload else {
            Issue.record("review payload must be a video payload")
            return
        }
        #expect(reviewed == options)

        await center.confirmVideoGeneration(review)
        let call = try #require(recorder.videoCalls.first)
        #expect(call.options == options,
                "confirmed duration/aspect/resolution must be submitted verbatim")
        #expect(call.prompt == "animate")
        #expect(call.projectID == center.project?.id)
    }

    @Test func authorizeAccessRequiresExactRecordedContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, recorder: BridgeRecorder())
        let ownerID = UUID()
        let projectID = try await makeImageProject(
            center: center, root: root,
            owner: WorkbenchCenter.Owner(kind: .chat, id: ownerID, environmentID: "env-1")).id

        // Absent context must not bypass the recorded environment/workspace/owner.
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(projectID: projectID, access: MediaProjectAccess())
        }
        // Mismatched context is refused.
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: "env-2", workspacePath: root.path,
                                           ownerKind: "chat", ownerID: ownerID))
        }
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: "env-1",
                                           workspacePath: root.path + "-other",
                                           ownerKind: "chat", ownerID: ownerID))
        }
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: "env-1", workspacePath: root.path,
                                           ownerKind: "chat", ownerID: UUID()))
        }
        // Exact recorded context is allowed.
        try await center.authorizeAccess(
            projectID: projectID,
            access: MediaProjectAccess(environmentID: "env-1", workspacePath: root.path,
                                       ownerKind: "chat", ownerID: ownerID))
    }

    @Test func savedProjectIsFoundResumedAndKeepsEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, recorder: BridgeRecorder())
        let opened = try await makeImageProject(center: center, root: root)
        let layerID = try #require(center.project?.imageLayers.first?.id)
        // A real edit through the shared transaction engine.
        #expect(center.apply(.updateLayer(id: layerID, transform: nil, opacity: 0.42,
                                          isHidden: nil, isLocked: nil, adjustment: nil,
                                          text: nil, crop: .unchanged)))
        let editedRevision = try #require(center.project?.revision)
        #expect(editedRevision > 1)
        await center.saveNow()

        // Reopening the same source finds the saved project instead of
        // starting fresh.
        let candidate = try #require(await center.findResumableProject(
            sourceURLs: [opened.sourceURL], kind: .image, owner: .standalone))
        #expect(candidate.id == opened.id)
        #expect(candidate.revision == editedRevision)

        // Open through the production reopen path and verify the edit and the
        // owner/root context survived.
        center.closeProject()
        await center.openProject(id: candidate.id)
        let reopened = try #require(center.project)
        #expect(reopened.id == opened.id)
        #expect(reopened.revision == editedRevision)
        let reopenedLayer = try #require(reopened.imageLayers.first { $0.id == layerID })
        #expect(abs(reopenedLayer.opacity - 0.42) < 0.0001,
                "the saved opacity edit must survive reopen")
        #expect(reopened.ownerKind == "standalone")
        #expect(reopened.taskWorkspacePath == root.path,
                "the recorded asset root must survive reopen")
    }
}
#endif

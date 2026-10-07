// FloeAppTests — Workbench export delivery + async ownership contract.
//
// Pins the delivery gap repair: a verified export retains its URL, the
// entrance callback fires exactly once and only for verified success, and a
// new attempt / failure / cancellation / project switch can never leave a
// stale success visible. Also pins the asynchronous generation ownership
// repairs (results stay with the frozen project; no duplicate confirmation;
// unknown/interrupted image requests are durable and never auto-resubmitted)
// and the same-task vs other-task media.project access gate.

#if canImport(UIKit)
import Foundation
import Testing
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
@testable import FloeApp

// MARK: - Controllable generation gate

/// Suspends the image/video provider call until the test releases it, so a
/// project switch can happen while the await is genuinely in flight.
private final class GenerationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: [(UUID, CheckedContinuation<T, Error>)] = []
    private(set) var callCount = 0

    func call() async throws -> T {
        let callID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                callCount += 1
                pending.append((callID, continuation))
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                lock.unlock()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            lock.lock()
            if let index = pending.firstIndex(where: { $0.0 == callID }) {
                let continuation = pending.remove(at: index).1
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func waitForCall() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func succeed(_ value: T) { resume { $0.resume(returning: value) } }
    func fail(_ error: Error) { resume { $0.resume(throwing: error) } }

    private func resume(_ action: (CheckedContinuation<T, Error>) -> Void) {
        lock.lock()
        let waiters = pending.map(\.1)
        pending.removeAll()
        lock.unlock()
        waiters.forEach(action)
    }
}

// MARK: - Bridge stub

@MainActor
private final class ExportBridgeStub {
    var imageCalls = 0
    var videoCalls = 0
    var imageGate: GenerationGate<[URL]>?
    var videoGate: GenerationGate<UUID>?
    var generatedImageURL: URL?
    var imageError: Error?

    func makeBridge() -> WorkbenchAIBridge {
        let modelID = UUID()
        return WorkbenchAIBridge(
            isAvailable: { true },
            imageModels: { [WorkbenchAIModelInfo(id: modelID, displayName: "Mock Image",
                                                 remoteModelID: "mock-image", providerName: "Mock")] },
            videoModels: { [WorkbenchAIModelInfo(id: modelID, displayName: "Mock Video",
                                                 remoteModelID: "mock-video", providerName: "Mock")] },
            generateImages: { [weak self] _, _, _, _, _ in
                guard let self else { return [] }
                self.imageCalls += 1
                if let gate = self.imageGate { return try await gate.call() }
                if let error = self.imageError { throw error }
                if let url = self.generatedImageURL { return [url] }
                return []
            },
            submitVideo: { [weak self] _, _, _, _, _ in
                guard let self else { return UUID() }
                self.videoCalls += 1
                if let gate = self.videoGate { return try await gate.call() }
                return UUID()
            },
            refreshJob: { jobID in
                WorkbenchAIJobInfo(id: jobID, state: "running", progress: nil, message: nil,
                                   isActive: true, isWaitStopped: false, modelName: "")
            },
            cancelJob: { _ in },
            jobs: { _ in [] },
            deliverResult: { _ in throw FloeError.notFound("no result") },
            costNote: { _ in "Mock pricing note" })
    }
}

// MARK: - Media fixtures

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

private func makeMovie(at url: URL, width: Int = 640, height: Int = 360,
                       fps: Int = 24, seconds: Double = 2) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * Double(fps))
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        guard let pool = adaptor.pixelBufferPool else { break }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixel = buffer else { break }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let bytes = CVPixelBufferGetBytesPerRow(pixel)
            for row in 0..<height {
                let ptr = base.advanced(by: row * bytes).assumingMemoryBound(to: UInt32.self)
                for column in 0..<width {
                    ptr[column] = 0xFF000000 | UInt32((Double(column) / Double(width)) * 200) << 8
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

// MARK: - Suite

@Suite("FloeApp.Workbench export delivery", .serialized)
@MainActor
struct WorkbenchExportDeliveryTests {
    private func makeCenter(root: URL, stub: ExportBridgeStub) -> WorkbenchCenter {
        WorkbenchCenter(rootProvider: { root }, bridge: stub.makeBridge())
    }

    private func makeImageProject(center: WorkbenchCenter, root: URL) async throws -> URL {
        let imageURL = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: imageURL)
        await center.startImageProject(sourceURL: imageURL, owner: .standalone)
        _ = try #require(center.project)
        return imageURL
    }

    private func makeVideoProject(center: WorkbenchCenter, root: URL, seconds: Double = 2) async throws {
        let videoURL = root.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        try await makeMovie(at: videoURL, seconds: seconds)
        await center.startVideoProject(clipURLs: [videoURL], musicURL: nil, owner: .standalone)
        _ = try #require(center.project, "video project must open")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Image delivery

    @Test func verifiedImageExportRetainsResultAndFiresEntranceCallbackOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeImageProject(center: center, root: root)

        var callbackURLs: [URL] = []
        center.setExportEntranceCallback { callbackURLs.append($0) }

        await center.exportImage(options: ImageExportOptions(format: .png, fileName: "result-a"))
        let first = try #require(center.lastExportResult)
        #expect(first.kind == .image)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(callbackURLs == [first.url], "verified success fires the entrance callback once")

        await center.exportImage(options: ImageExportOptions(format: .png, fileName: "result-b"))
        let second = try #require(center.lastExportResult)
        #expect(second.url != first.url)
        #expect(callbackURLs.count == 1, "the entrance callback fires exactly once per presentation")

        var more: [URL] = []
        center.setExportEntranceCallback { more.append($0) }
        await center.exportImage(options: ImageExportOptions(format: .png, fileName: "result-c"))
        #expect(more.count == 1, "re-arming by the next panel presentation restores one delivery")
    }

    @Test func failedImageExportClearsStaleResultAndNeverCallsBack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeImageProject(center: center, root: root)

        var callbackCount = 0
        center.setExportEntranceCallback { _ in callbackCount += 1 }
        await center.exportImage(options: ImageExportOptions(format: .png, fileName: "ok"))
        #expect(center.lastExportResult != nil)

        // JPEG + preserve transparency on the alpha PNG fixture is rejected by
        // the renderer's verified-export validation — deterministic failure.
        await center.exportImage(options: ImageExportOptions(
            format: .jpeg, quality: 0.9, preserveTransparency: true,
            stripMetadata: true, fileName: "bad"))
        #expect(center.lastExportResult == nil, "a failed attempt must clear the previous success")
        #expect(callbackCount == 1, "failure never invokes the entrance callback")
        #expect(center.alert != nil, "a real failure surfaces an actionable alert")
    }

    @Test func clearExportDeliveryDropsRetainedResultAndMessage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeImageProject(center: center, root: root)
        await center.exportImage(options: ImageExportOptions(fileName: "ok"))
        #expect(center.lastExportResult != nil)
        center.clearExportDelivery()
        #expect(center.lastExportResult == nil)
        #expect(center.lastExportMessage == nil)
    }

    // MARK: Video delivery

    @Test func verifiedVideoExportRetainsResultAndFiresEntranceCallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeVideoProject(center: center, root: root)

        var callbackURLs: [URL] = []
        center.setExportEntranceCallback { callbackURLs.append($0) }
        let canvas = try #require(center.project?.canvas)
        let options = VideoExportOptions(codec: .h264, width: canvas.width, height: canvas.height,
                                         frameRate: canvas.frameRate ?? 24, fileName: "video-ok")
        await center.exportVideo(options: options)
        let result = try #require(center.lastExportResult, "verified H.264 export must be retained")
        #expect(result.kind == .video)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(callbackURLs == [result.url])
    }

    @Test func invalidVideoExportClearsStaleResult() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeVideoProject(center: center, root: root)

        var callbackCount = 0
        center.setExportEntranceCallback { _ in callbackCount += 1 }
        let canvas = try #require(center.project?.canvas)
        await center.exportVideo(options: VideoExportOptions(
            codec: .h264, width: canvas.width, height: canvas.height,
            frameRate: canvas.frameRate ?? 24, fileName: "video-good"))
        #expect(center.lastExportResult != nil)
        #expect(callbackCount == 1)

        // frame rate 0 fails deterministic validation before any encoder runs.
        await center.exportVideo(options: VideoExportOptions(
            codec: .h264, width: canvas.width, height: canvas.height,
            frameRate: 0, fileName: "video-bad"))
        #expect(center.lastExportResult == nil, "failed export must clear the previous success")
        #expect(callbackCount == 1, "a failed attempt never fires the entrance callback")
    }

    @Test func cancelledVideoExportLeavesNoStaleSuccessOrCallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeVideoProject(center: center, root: root)
        let canvas = try #require(center.project?.canvas)

        var callbackFired = false
        center.setExportEntranceCallback { _ in callbackFired = true }
        let options = VideoExportOptions(codec: .h264, width: canvas.width, height: canvas.height,
                                         frameRate: canvas.frameRate ?? 24, fileName: "video-cancel")
        let task = Task { await center.exportVideo(options: options) }
        for _ in 0..<300 where center.exportProgress == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        center.cancelExport()
        await task.value

        #expect(center.lastExportResult == nil, "cancellation must not leave a shareable success")
        #expect(!callbackFired, "cancellation never invokes the entrance callback")
        if let message = center.lastExportMessage {
            #expect(message.lowercased().contains("cancel") || message.contains("取消"))
        }
    }

    @Test func switchingProjectClearsRetainedExport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeImageProject(center: center, root: root)
        let firstID = try #require(center.project?.id)
        await center.exportImage(options: ImageExportOptions(fileName: "first"))
        #expect(center.lastExportResult != nil)

        let second = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: second)
        await center.startImageProject(sourceURL: second, owner: .standalone)
        #expect(center.project?.id != firstID)
        #expect(center.lastExportResult == nil, "another project must not inherit the export result")
    }

    // MARK: Asynchronous generation ownership

    private func imageReviewRequest(modelID: UUID) -> WorkbenchCenter.AIReviewRequest {
        WorkbenchCenter.AIReviewRequest(
            kind: .image, prompt: "edit", modelID: modelID, modelName: "Mock Image",
            payload: .image(size: "1K", count: 1, sourceAssetID: nil),
            assetNames: [], parameters: ["Count": "1"], costNote: "Mock pricing note")
    }

    @Test func projectSwitchDuringImageGenerationDeliversToOriginalProject() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        let gate = GenerationGate<[URL]>()
        stub.imageGate = gate
        let center = makeCenter(root: root, stub: stub)
        try await makeImageProject(center: center, root: root)
        let firstID = try #require(center.project?.id)
        let modelID = try #require(center.imageModelsForUI().first?.id)

        let deliverable = root.appendingPathComponent("candidate-\(UUID().uuidString).png")
        try makePNG(at: deliverable)

        let generation = Task { await center.confirmImageGeneration(imageReviewRequest(modelID: modelID)) }
        await gate.waitForCall()

        let secondSource = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: secondSource)
        await center.startImageProject(sourceURL: secondSource, owner: .standalone)
        #expect(center.project?.id != firstID)
        #expect(center.candidates.isEmpty, "another project must not show the first project's result")

        gate.succeed([deliverable])
        await generation.value

        #expect(center.candidates.isEmpty, "visible project still owns no candidates")
        await center.openProject(id: firstID)
        #expect(center.candidates.count == 1, "the candidate belongs to the project the review targeted")
        #expect(center.candidates.first?.url == deliverable)
    }

    @Test func duplicateImageConfirmationSubmitsOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        let center = makeCenter(root: root, stub: stub)
        try await makeImageProject(center: center, root: root)
        let modelID = try #require(center.imageModelsForUI().first?.id)
        let request = imageReviewRequest(modelID: modelID)

        await center.confirmImageGeneration(request)
        await center.confirmImageGeneration(request)
        #expect(stub.imageCalls == 1, "a confirmed review can never be submitted twice")
    }

    @Test func transportFailureRecordsUnknownAndIsNeverAutoResubmitted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        stub.imageError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let center = makeCenter(root: root, stub: stub)
        try await makeImageProject(center: center, root: root)
        let projectID = try #require(center.project?.id)
        let modelID = try #require(center.imageModelsForUI().first?.id)

        await center.confirmImageGeneration(imageReviewRequest(modelID: modelID))
        #expect(stub.imageCalls == 1)
        #expect(center.imageRequests.map(\.status) == [.unknown],
                "a post-submission transport failure is unknown, not a definitive failure")

        // Reopening (app restoration) keeps the truthful status and never
        // automatically resubmits.
        await center.openProject(id: projectID)
        #expect(center.imageRequests.map(\.status) == [.unknown])
        #expect(stub.imageCalls == 1)
    }

    @Test func definitiveProviderFailureIsRecordedAsFailed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        stub.imageError = FloeError.validationFailed("provider rejected the request")
        let center = makeCenter(root: root, stub: stub)
        try await makeImageProject(center: center, root: root)
        let modelID = try #require(center.imageModelsForUI().first?.id)

        await center.confirmImageGeneration(imageReviewRequest(modelID: modelID))
        #expect(center.imageRequests.map(\.status) == [.failed])
    }

    @Test func interruptedInFlightRequestIsDurableAndShowsTruthfulStatus() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        let gate = GenerationGate<[URL]>()
        stub.imageGate = gate
        let center = makeCenter(root: root, stub: stub)
        try await makeImageProject(center: center, root: root)
        let projectID = try #require(center.project?.id)
        let modelID = try #require(center.imageModelsForUI().first?.id)

        let task = Task { await center.confirmImageGeneration(imageReviewRequest(modelID: modelID)) }
        await gate.waitForCall()
        task.cancel()
        await task.value
        gate.fail(CancellationError())
        #expect(center.imageRequests.map(\.status) == [.interrupted])

        // A fresh center (app relaunch) loads the persisted record; the
        // outcome stays interrupted and is never retried.
        let reopened = makeCenter(root: root, stub: ExportBridgeStub())
        await reopened.openProject(id: projectID)
        #expect(reopened.imageRequests.map(\.status) == [.interrupted])
        #expect((reopened.imageRequests.first?.message?.isEmpty) == false)
    }

    @Test func submittedRequestLeftOnDiskIsReclassifiedInterruptedOnRestore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        try await makeImageProject(center: center, root: root)
        let projectID = try #require(center.project?.id)

        // Simulate a record abandoned mid-submission (app killed before the
        // provider call recorded an outcome).
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(
            "FloeAgent/MediaProjects/ImageRequests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = WorkbenchImageRequestStore.Record(
            id: UUID(), projectID: projectID, prompt: "p", modelID: UUID(),
            modelName: "m", detail: "", createdAt: Date(), status: .submitted, message: nil)
        let data = try JSONEncoder().encode([record])
        try data.write(to: directory.appendingPathComponent("\(projectID.uuidString).json"))

        let reopened = makeCenter(root: root, stub: ExportBridgeStub())
        await reopened.openProject(id: projectID)
        #expect(reopened.imageRequests.map(\.status) == [.interrupted])
    }

    @Test func duplicateVideoConfirmationSubmitsOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = ExportBridgeStub()
        let center = makeCenter(root: root, stub: stub)
        try await makeVideoProject(center: center, root: root)
        let modelID = try #require(center.videoModelsForUI().first?.id)
        let request = WorkbenchCenter.AIReviewRequest(
            kind: .video, prompt: "animate", modelID: modelID, modelName: "Mock Video",
            payload: .video(options: WorkbenchVideoAIOptions(durationSeconds: 5, aspectRatio: "16:9",
                                                             resolution: "720p")),
            assetNames: [], parameters: [:], costNote: "Mock pricing note")
        await center.confirmVideoGeneration(request)
        await center.confirmVideoGeneration(request)
        #expect(stub.videoCalls == 1)
    }

    // MARK: media.project same-task ownership

    @Test func mediaProjectAllowsSameTaskAndDeniesOtherTask() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root: root, stub: ExportBridgeStub())
        let taskA = UUID()
        let imageURL = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: imageURL)
        await center.startImageProject(
            sourceURL: imageURL,
            owner: WorkbenchCenter.Owner(kind: .chat, id: taskA, environmentID: nil))
        let projectID = try #require(center.project?.id)

        // The agent in the SAME conversation/workspace passes the gate.
        try await center.authorizeAccess(
            projectID: projectID,
            access: MediaProjectAccess(environmentID: nil, workspacePath: root.resolvingSymlinksInPath().path,
                                       ownerKind: "chat", ownerID: taskA))

        // A different conversation is refused.
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: nil, workspacePath: root.path,
                                           ownerKind: "chat", ownerID: UUID()))
        }
        // A workspace-only (no owner) caller is refused.
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: nil, workspacePath: root.path,
                                           ownerKind: nil, ownerID: nil))
        }
        // Another workspace is refused.
        await #expect(throws: (any Error).self) {
            try await center.authorizeAccess(
                projectID: projectID,
                access: MediaProjectAccess(environmentID: nil, workspacePath: root.path + "-other",
                                           ownerKind: "chat", ownerID: taskA))
        }
    }
}
#endif

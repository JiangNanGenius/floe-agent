//
//  CADAnimationExport.swift
//  FloeCADKit
//
//  Real native MP4 export and single-frame capture from the live RealityKit
//  Present. Frames are actual `ARView.snapshot` renders of the same stage the
//  user sees (bodies, materials, camera, assembly instances and the animated
//  overrides); nothing is emulated, scripted or substituted with the
//  engineering viewport.
//
//  Export is service-owned: the caller receives an id, progress is reported
//  with completed/total frames, cancellation removes the staging directory and
//  the destination is only promoted after the file is verified AND the
//  document/stage generation fence still matches.
//

#if canImport(AVFoundation) && canImport(RealityKit) && canImport(UIKit)
import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import RealityKit
import UIKit
import simd

// MARK: - Settings / results

public nonisolated enum CADAnimationVideoCodec: String, Sendable, CaseIterable {
    case h264
    case hevc
}

public nonisolated struct CADAnimationExportSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: CADAnimationVideoCodec
    public var bitrate: Int?
    public var overwrite: Bool
    public var posterEnabled: Bool

    public init(width: Int = 1920,
                height: Int = 1080,
                frameRate: Int = 30,
                codec: CADAnimationVideoCodec = .h264,
                bitrate: Int? = nil,
                overwrite: Bool = false,
                posterEnabled: Bool = true) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.bitrate = bitrate
        self.overwrite = overwrite
        self.posterEnabled = posterEnabled
    }

    public static let `default` = CADAnimationExportSettings()

    public static let minimumDimension = 64
    public static let maximumDimension = 4096
    public static let maximumPixels = 3840 * 2160
    public static let maximumFrames = 18_000
    public static let maximumOutputBytes: Int64 = 512 * 1024 * 1024

    public var validationError: String? {
        guard width % 2 == 0, height % 2 == 0 else {
            return "Video width and height must be even numbers."
        }
        guard width >= Self.minimumDimension, width <= Self.maximumDimension,
              height >= Self.minimumDimension, height <= Self.maximumDimension else {
            return "Video dimensions must be between \(Self.minimumDimension) and \(Self.maximumDimension) pixels."
        }
        guard width * height <= Self.maximumPixels else {
            return "Video dimensions exceed the 4K pixel limit."
        }
        guard frameRate >= 1, frameRate <= 60 else {
            return "Frame rate must be between 1 and 60 fps."
        }
        if let bitrate, bitrate < 250_000 || bitrate > 80_000_000 {
            return "Video bitrate must be between 250 kbps and 80 Mbps."
        }
        return nil
    }

    public func validated() throws -> CADAnimationExportSettings {
        if let message = validationError {
            throw CADAnimationExportError.invalidSettings(message)
        }
        return self
    }
}

public nonisolated enum CADAnimationExportPhase: String, Sendable {
    case preparing
    case rendering
    case finalizing
    case finished
    case failed
    case cancelled
}

public nonisolated struct CADAnimationExportProgress: Sendable, Equatable {
    public var phase: CADAnimationExportPhase
    public var completedFrames: Int
    public var totalFrames: Int
    public var timeSeconds: Double

    public init(phase: CADAnimationExportPhase,
                completedFrames: Int = 0,
                totalFrames: Int = 0,
                timeSeconds: Double = 0) {
        self.phase = phase
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
        self.timeSeconds = timeSeconds
    }

    public var fraction: Double {
        guard totalFrames > 0 else { return 0 }
        return min(max(Double(completedFrames) / Double(totalFrames), 0), 1)
    }

    public var isFinished: Bool {
        phase == .finished || phase == .failed || phase == .cancelled
    }
}

public nonisolated struct CADAnimationExportResult: Sendable, Equatable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var durationSeconds: Double
    public var frameCount: Int
    public var codec: String
    public var hasAudio: Bool
    public var byteCount: Int64
    /// Actual first frame of the exported clip as PNG, when enabled.
    public var posterPNG: Data?

    public init(url: URL, width: Int, height: Int, frameRate: Double,
                durationSeconds: Double, frameCount: Int, codec: String,
                hasAudio: Bool, byteCount: Int64, posterPNG: Data? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.codec = codec
        self.hasAudio = hasAudio
        self.byteCount = byteCount
        self.posterPNG = posterPNG
    }
}

public nonisolated struct CADAnimationExportStatus: Sendable, Equatable {
    public var id: UUID
    public var progress: CADAnimationExportProgress
    public var result: CADAnimationExportResult?
    public var error: String?
    public var isCancelled: Bool

    public var isFinished: Bool { progress.isFinished }

    public init(id: UUID,
                progress: CADAnimationExportProgress,
                result: CADAnimationExportResult? = nil,
                error: String? = nil,
                isCancelled: Bool = false) {
        self.id = id
        self.progress = progress
        self.result = result
        self.error = error
        self.isCancelled = isCancelled
    }
}

public nonisolated struct CADAnimationExportHandle: Sendable, Equatable {
    public var id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public nonisolated struct CADAnimationFrameCapture: Sendable, Equatable {
    public var imageData: Data
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var revision: Int
    public var changeCount: Int
    public var contentSHA256: String
    public var sha256: String
    public var clipID: UUID
    public var timeSeconds: Double
    public var frameIndex: Int
    public var frameRate: Int
    public var documentKey: String
    public var renderer: String
    public var note: String
}

public nonisolated enum CADAnimationImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
}

public nonisolated enum CADAnimationExportError: Error, LocalizedError, Sendable {
    case invalidSettings(String)
    case invalidDestination(String)
    case destinationExists
    case exportInProgress
    case readOnly
    case noClip
    case presentationNotActive
    case rendererUnavailable
    case stale
    case cancelled
    case writer(String)
    case verification(String)
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let message), .invalidDestination(let message):
            return message
        case .destinationExists:
            return "A file already exists at the destination."
        case .exportInProgress:
            return "Another animation capture or export is already using this document."
        case .readOnly:
            return "A read-only CAD document cannot be exported."
        case .noClip:
            return "This document has no animation clip to export."
        case .presentationNotActive:
            return "The app must be in the foreground so the native 3D renderer can draw the animation."
        case .rendererUnavailable:
            return "The native presentation renderer is unavailable."
        case .stale:
            return "The document changed during export; the video was discarded."
        case .cancelled:
            return "Video export was cancelled."
        case .writer(let message), .verification(let message), .encoding(let message):
            return message
        }
    }
}

// MARK: - Service-owned export center

@MainActor
public final class CADAnimationExportCenter {
    public static let shared = CADAnimationExportCenter()

    private struct Job {
        var documentKey: String
        var status: CADAnimationExportStatus
        var task: Task<Void, Never>?
        var waiters: [CheckedContinuation<CADAnimationExportStatus, Never>] = []
        var progressHandler: (@MainActor (CADAnimationExportProgress) -> Void)?
        var startedAt = Date()
    }

    private var jobs: [UUID: Job] = [:]
    private let maximumRetainedJobs = 16

    private init() {}

    public func status(_ id: UUID) -> CADAnimationExportStatus? { jobs[id]?.status }

    public func wait(_ id: UUID) async -> CADAnimationExportStatus {
        if let job = jobs[id], job.status.isFinished { return job.status }
        if jobs[id] == nil {
            return CADAnimationExportStatus(
                id: id,
                progress: CADAnimationExportProgress(phase: .failed),
                error: CADAnimationExportError.cancelled.localizedDescription,
                isCancelled: true)
        }
        return await withCheckedContinuation { continuation in
            guard var job = jobs[id] else {
                continuation.resume(returning: CADAnimationExportStatus(
                    id: id,
                    progress: CADAnimationExportProgress(phase: .failed),
                    error: CADAnimationExportError.cancelled.localizedDescription,
                    isCancelled: true))
                return
            }
            job.waiters.append(continuation)
            jobs[id] = job
        }
    }

    public func cancel(_ id: UUID) {
        guard var job = jobs[id], !job.status.isFinished else { return }
        job.task?.cancel()
        var progress = job.status.progress
        progress.phase = .cancelled
        job.status.progress = progress
        job.status.isCancelled = true
        jobs[id] = job
    }

    func cancelAll(documentKey: String) {
        for (id, job) in jobs where job.documentKey == documentKey {
            cancel(id)
        }
    }

    func hasActiveJob(documentKey: String) -> Bool {
        jobs.values.contains {
            $0.documentKey == documentKey
                && ($0.task != nil || !$0.status.isFinished)
        }
    }

    // Worker-facing -----------------------------------------------------------

    func register(documentKey: String,
                  totalFrames: Int,
                  progress: (@MainActor (CADAnimationExportProgress) -> Void)?)
    -> UUID {
        pruneIfNeeded()
        let id = UUID()
        jobs[id] = Job(
            documentKey: documentKey,
            status: CADAnimationExportStatus(
                id: id,
                progress: CADAnimationExportProgress(
                    phase: .preparing, completedFrames: 0,
                    totalFrames: totalFrames, timeSeconds: 0)),
            progressHandler: progress)
        return id
    }

    func attach(task: Task<Void, Never>, to id: UUID) {
        jobs[id]?.task = task
    }

    func update(_ id: UUID, _ progress: CADAnimationExportProgress) {
        guard var job = jobs[id], !job.status.isFinished else { return }
        job.status.progress = progress
        jobs[id] = job
        job.progressHandler?(progress)
    }

    func finish(_ id: UUID, status: CADAnimationExportStatus) {
        guard var job = jobs[id] else { return }
        job.status = status
        job.task = nil
        let waiters = job.waiters
        job.waiters = []
        jobs[id] = job
        for waiter in waiters { waiter.resume(returning: status) }
        job.progressHandler?(status.progress)
    }

    private func pruneIfNeeded() {
        let finished = jobs.filter { $0.value.status.isFinished }
            .sorted { $0.value.startedAt < $1.value.startedAt }
        guard jobs.count >= maximumRetainedJobs else { return }
        for entry in finished.prefix(max(0, jobs.count - maximumRetainedJobs + 1)) {
            jobs.removeValue(forKey: entry.key)
        }
    }
}

// MARK: - Render session

/// One exclusive render lease over either the visible Present or a
/// service-owned native RealityKit host. `release` restores the baseline and
/// tears down the host; it never writes the document.
@MainActor
private struct CADAnimationRenderSession {
    let controller: CADPresentationRenderController
    let handle: CADPresentationHandle
    let generation: UInt64
    let lease: UUID
    let release: () -> Void
}

// MARK: - Document export API

@MainActor
public extension FloeCADDocument {
    /// Start a service-owned MP4 export. The frame loop renders the ACTUAL
    /// live Present when visible, otherwise a service-owned native RealityKit
    /// host (same controller/stage, no fake frames); the returned id can be polled with
    /// `animationExportStatus`, cancelled with `cancelAnimationExport`, and
    /// awaited with `waitForAnimationExport`.
    @discardableResult
    func startAnimationExportMP4(
        clipID: UUID? = nil,
        to destination: URL,
        settings: CADAnimationExportSettings = .default,
        progress: (@MainActor (CADAnimationExportProgress) -> Void)? = nil
    ) throws -> CADAnimationExportHandle {
        guard !isClosed else { throw CADAnimationExportError.cancelled }
        guard !isReadOnly else { throw CADAnimationExportError.readOnly }
        let cleanSettings = try settings.validated()
        let state = animationLoadState()
        let clip = clipID.flatMap { state.animation.clip(withID: $0) }
            ?? state.animation.activeClip
        guard let clip else { throw CADAnimationExportError.noClip }
        let documentKey = url.standardizedFileURL.path
        guard !CADAnimationExportCenter.shared.hasActiveJob(
            documentKey: documentKey) else {
            throw CADAnimationExportError.exportInProgress
        }
        try Self.validateAnimationExportDestination(destination,
                                                     settings: cleanSettings)
        let totalFrames = clip.frameCount(at: cleanSettings.frameRate)
        let center = CADAnimationExportCenter.shared
        let id = center.register(documentKey: documentKey,
                                 totalFrames: totalFrames,
                                 progress: progress)
        let task = Task { @MainActor in
            let status = await self.runAnimationExport(
                id: id, clip: clip, destination: destination,
                settings: cleanSettings)
            center.finish(id, status: status)
        }
        center.attach(task: task, to: id)
        return CADAnimationExportHandle(id: id)
    }

    func animationExportStatus(_ id: UUID) -> CADAnimationExportStatus? {
        CADAnimationExportCenter.shared.status(id)
    }

    func cancelAnimationExport(_ id: UUID) {
        CADAnimationExportCenter.shared.cancel(id)
    }

    func waitForAnimationExport(_ id: UUID) async -> CADAnimationExportStatus {
        await CADAnimationExportCenter.shared.wait(id)
    }

    /// Awaitable convenience. Cancelling the caller cancels the service job
    /// and its staging directory.
    @discardableResult
    func exportAnimationMP4(
        clipID: UUID? = nil,
        to destination: URL,
        settings: CADAnimationExportSettings = .default,
        progress: (@MainActor (CADAnimationExportProgress) -> Void)? = nil
    ) async throws -> CADAnimationExportResult {
        let handle = try startAnimationExportMP4(
            clipID: clipID, to: destination, settings: settings,
            progress: progress)
        let status = await withTaskCancellationHandler {
            await waitForAnimationExport(handle.id)
        } onCancel: {
            Task { @MainActor in
                CADAnimationExportCenter.shared.cancel(handle.id)
            }
        }
        if let result = status.result { return result }
        if status.isCancelled { throw CADAnimationExportError.cancelled }
        throw CADAnimationExportError.verification(
            status.error ?? "Video export did not produce a file.")
    }

    // MARK: Single frame

    func captureAnimationFramePNG(clipID: UUID? = nil,
                                  time: Double,
                                  width: Int = 1920,
                                  height: Int = 1080,
                                  frameRate: Int = 30) async throws
    -> CADAnimationFrameCapture {
        try await captureAnimationFrame(clipID: clipID, time: time,
                                        width: width, height: height,
                                        frameRate: frameRate, format: .png)
    }

    /// Capture a specified integer frame at `fps` (default 30). The time is
    /// derived from the same frame plan the MP4 writer uses.
    func captureAnimationFramePNG(clipID: UUID? = nil,
                                  frame: Int,
                                  fps: Int = 30,
                                  width: Int = 1920,
                                  height: Int = 1080) async throws
    -> CADAnimationFrameCapture {
        let state = animationLoadState()
        let clip = clipID.flatMap { state.animation.clip(withID: $0) }
            ?? state.animation.activeClip
        guard let clip else { throw CADAnimationExportError.noClip }
        let time = Self.animationFrameTime(
            frame: frame, fps: fps, duration: clip.duration)
        return try await captureAnimationFramePNG(
            clipID: clip.id, time: time, width: width, height: height,
            frameRate: fps)
    }

    func captureAnimationFrameJPEG(clipID: UUID? = nil,
                                   time: Double,
                                   width: Int = 1920,
                                   height: Int = 1080,
                                   frameRate: Int = 30,
                                   quality: CGFloat = 0.92) async throws
    -> CADAnimationFrameCapture {
        try await captureAnimationFrame(clipID: clipID, time: time,
                                        width: width, height: height,
                                        frameRate: frameRate,
                                        format: .jpeg,
                                        jpegQuality: quality)
    }

    /// Capture one animation frame from the live Present, or from a
    /// service-owned native RealityKit host when Present is closed. The frame
    /// is applied transiently under an exclusive render lease and the baseline
    /// is restored before returning.
    func captureAnimationFrame(clipID: UUID? = nil,
                               time: Double,
                               width: Int = 1920,
                               height: Int = 1080,
                               frameRate: Int = 30,
                               format: CADAnimationImageFormat = .png,
                               jpegQuality: CGFloat = 0.92) async throws
    -> CADAnimationFrameCapture {
        guard !isClosed else { throw CADAnimationExportError.cancelled }
        guard !isReadOnly else { throw CADAnimationExportError.readOnly }
        guard width >= 64, width <= 4096 else {
            throw CADAnimationExportError.invalidSettings(
                "Frame width must be between 64 and 4096 pixels.")
        }
        let state = animationLoadState()
        let clip = clipID.flatMap { state.animation.clip(withID: $0) }
            ?? state.animation.activeClip
        guard let clip else { throw CADAnimationExportError.noClip }
        guard !CADAnimationExportCenter.shared.hasActiveJob(
            documentKey: url.standardizedFileURL.path) else {
            throw CADAnimationExportError.exportInProgress
        }
        guard height >= 64, height <= 4096 else {
            throw CADAnimationExportError.invalidSettings(
                "Frame height must be between 64 and 4096 pixels.")
        }
        let session = try await acquireAnimationRenderSession(
            width: width, height: height)
        defer { session.release() }
        let controller = session.controller
        let handle = session.handle
        let lease = session.lease
        let model = CADAnimationPlaybackModel()
        model.attach(document: self, handle: handle, clipID: clip.id)
        let documentKey = url.standardizedFileURL.path
        let documentRevision = self.revision
        let documentChangeCount = self.liveChangeCount
        let documentContentSHA = self.contentSHA256
        let generation = session.generation
        let clamped = min(max(time.isFinite ? time : 0, 0), clip.duration)
        guard let frame = model.exportFrame(at: clamped) else {
            throw CADAnimationExportError.noClip
        }
        let applied = controller.applyAnimation(
            camera: frame.camera,
            instanceTransforms: frame.matrices,
            token: String(format: "capture|%@|%.6f", clip.id.uuidString, clamped),
            expectedGeneration: generation,
            lease: lease)
        guard applied else { throw CADAnimationExportError.stale }
        let image = try await controller.snapshotImage(targetWidth: width)
        if Task.isCancelled { throw CADAnimationExportError.cancelled }
        guard !isClosed,
              url.standardizedFileURL.path == documentKey,
              documentRevision == revision,
              documentChangeCount == liveChangeCount,
              documentContentSHA == contentSHA256,
              controller.renderGeneration == generation,
              controller.holdsAnimationLease(lease) else {
            throw CADAnimationExportError.stale
        }
        let data: Data
        let mimeType: String
        switch format {
        case .png:
            guard let png = image.pngData() else {
                throw CADAnimationExportError.encoding("The frame could not be encoded as PNG.")
            }
            data = png
            mimeType = "image/png"
        case .jpeg:
            guard let jpeg = image.jpegData(compressionQuality: min(max(jpegQuality, 0.1), 1)) else {
                throw CADAnimationExportError.encoding("The frame could not be encoded as JPEG.")
            }
            data = jpeg
            mimeType = "image/jpeg"
        }
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let fps = min(max(frameRate, 1), 60)
        let frameIndex = min(max(Int((clamped * Double(fps)).rounded()),
                                 0), max(clip.frameCount(at: fps) - 1, 0))
        return CADAnimationFrameCapture(
            imageData: data, mimeType: mimeType,
            width: pixelWidth, height: pixelHeight,
            revision: documentRevision, changeCount: documentChangeCount,
            contentSHA256: documentContentSHA,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            clipID: clip.id, timeSeconds: clamped, frameIndex: frameIndex,
            frameRate: fps, documentKey: documentKey,
            renderer: "presentation",
            note: "Actual animated RealityKit frame (live Present or service render host); the document and assembly baseline were not changed.")
    }

    // MARK: Render session

    /// Use the visible Present when it is showing this document; otherwise
    /// create a service-owned native RealityKit host (real controller/stage,
    /// no fake frames). Both paths hold one exclusive render lease.
    private func acquireAnimationRenderSession(
        width: Int, height: Int
    ) async throws -> CADAnimationRenderSession {
        guard UIApplication.shared.applicationState != .background else {
            throw CADAnimationExportError.presentationNotActive
        }
        // A display-only exploded preview must not be baked into an animated
        // artifact. In that case use a baseline service host and leave the
        // user's visible preview untouched.
        let hasExplodedPreview = CADExplodedViewPreview.current(for: session)?.isActive == true
        if !hasExplodedPreview,
           let handle = CADPresentationCaptureRegistry.shared.activeHandle(for: self),
           let controller = handle.controller {
            guard let lease = controller.beginAnimationLease() else {
                throw CADAnimationExportError.rendererUnavailable
            }
            return CADAnimationRenderSession(
                controller: controller, handle: handle,
                generation: controller.renderGeneration, lease: lease,
                release: {
                    controller.endAnimationLease(lease)
                    controller.clearAnimation()
                })
        }
        guard let host = CADPresentationServiceRenderHost(
            document: self, width: width, height: height) else {
            throw CADAnimationExportError.presentationNotActive
        }
        guard await host.waitUntilReady() else {
            host.release()
            throw CADAnimationExportError.rendererUnavailable
        }
        guard let lease = host.controller.beginAnimationLease() else {
            host.release()
            throw CADAnimationExportError.rendererUnavailable
        }
        return CADAnimationRenderSession(
            controller: host.controller, handle: host.handle,
            generation: host.controller.renderGeneration, lease: lease,
            release: {
                host.controller.endAnimationLease(lease)
                host.controller.clearAnimation()
                host.release()
            })
    }

    // MARK: Export implementation

    private func runAnimationExport(
        id: UUID,
        clip: CADAnimationClip,
        destination: URL,
        settings: CADAnimationExportSettings
    ) async -> CADAnimationExportStatus {
        let center = CADAnimationExportCenter.shared
        let totalFrames = clip.frameCount(at: settings.frameRate)
        guard totalFrames <= CADAnimationExportSettings.maximumFrames else {
            return CADAnimationExportStatus(
                id: id,
                progress: CADAnimationExportProgress(
                    phase: .failed, totalFrames: totalFrames),
                error: CADAnimationExportError.invalidSettings(
                    "The animation exceeds the \(CADAnimationExportSettings.maximumFrames)-frame export bound.").localizedDescription)
        }
        let documentKey = url.standardizedFileURL.path
        let documentRevision = self.revision
        let documentChangeCount = self.liveChangeCount
        let documentContentSHA = self.contentSHA256
        var posterPNG: Data?
        var writer: AVAssetWriter?
        var stagingDirectory: URL?
        var renderSession: CADAnimationRenderSession?
        defer { renderSession?.release() }

        func report(_ phase: CADAnimationExportPhase,
                    completed: Int, time: Double) {
            center.update(id, CADAnimationExportProgress(
                phase: phase, completedFrames: completed,
                totalFrames: totalFrames, timeSeconds: time))
        }

        do {
            guard !isClosed else { throw CADAnimationExportError.cancelled }
            let session = try await acquireAnimationRenderSession(
                width: settings.width, height: settings.height)
            renderSession = session
            let controller = session.controller
            let exportLease = session.lease
            let generation = session.generation
            let model = CADAnimationPlaybackModel()
            model.attach(document: self, handle: session.handle, clipID: clip.id)
            guard model.exportFrame(at: 0) != nil else {
                throw CADAnimationExportError.noClip
            }

            let fileManager = FileManager.default
            let parent = destination.deletingLastPathComponent()
            let staging = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).export-\(UUID().uuidString)",
                isDirectory: true)
            stagingDirectory = staging
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedURL = staging.appendingPathComponent("movie.mp4")
            let output = try Self.makeAnimationWriter(
                url: stagedURL, settings: settings)
            writer = output.writer
            let input = output.input
            let adaptor = output.adaptor
            guard output.writer.startWriting() else {
                throw CADAnimationExportError.writer(
                    output.writer.error?.localizedDescription ?? "The video encoder could not start.")
            }
            output.writer.startSession(atSourceTime: .zero)
            report(.rendering, completed: 0, time: 0)

            let environment = CADPresentationSceneBuilder.environment(
                from: viewAppearance)
            let background = CIColor(
                red: CGFloat(environment.backgroundColor.x),
                green: CGFloat(environment.backgroundColor.y),
                blue: CGFloat(environment.backgroundColor.z),
                alpha: 1)
            let ciContext = CIContext()
            let pixelAttributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]

            var completed = 0
            while completed < totalFrames {
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState != .background else {
                    throw CADAnimationExportError.presentationNotActive
                }
                guard controller.holdsAnimationLease(exportLease),
                      controller.renderGeneration == generation,
                      liveChangeCount == documentChangeCount,
                      revision == documentRevision,
                      contentSHA256 == documentContentSHA else {
                    throw CADAnimationExportError.stale
                }
                let time = Self.animationFrameTime(
                    frame: completed, fps: settings.frameRate,
                    duration: clip.duration)
                guard let frame = model.exportFrame(at: time) else {
                    throw CADAnimationExportError.noClip
                }
                guard controller.applyAnimation(
                    camera: frame.camera,
                    instanceTransforms: frame.matrices,
                    token: String(format: "export|%@|%.6f", clip.id.uuidString, time),
                    expectedGeneration: generation,
                    lease: exportLease) else {
                    throw CADAnimationExportError.stale
                }
                let image = try await controller.snapshotImage(targetWidth: settings.width)
                try Task.checkCancellation()
                if completed == 0, settings.posterEnabled {
                    posterPNG = image.pngData()
                }
                guard let buffer = Self.makePixelBuffer(
                    image: image, width: settings.width, height: settings.height,
                    adaptor: adaptor, attributes: pixelAttributes,
                    background: background, context: ciContext) else {
                    throw CADAnimationExportError.encoding(
                        "The rendered frame could not be converted to video pixels.")
                }
                try await Self.waitUntilReady(input)
                try Task.checkCancellation()
                let presentationTime = CMTime(
                    value: Int64(completed), timescale: CMTimeScale(settings.frameRate))
                guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                    throw CADAnimationExportError.writer(
                        output.writer.error?.localizedDescription
                            ?? "The video encoder rejected frame \(completed + 1).")
                }
                completed += 1
                report(.rendering, completed: completed, time: time)
                await Task.yield()
            }

            report(.finalizing, completed: totalFrames, time: clip.duration)
            input.markAsFinished()
            await Self.finishWriting(output.writer)
            guard output.writer.status == .completed else {
                throw CADAnimationExportError.writer(
                    output.writer.error?.localizedDescription
                        ?? "The video encoder did not finish.")
            }
            writer = nil

            // Verify the staged file before any promotion.
            let stagedAttributes = try FileManager.default.attributesOfItem(
                atPath: stagedURL.path)
            guard let stagedSize = (stagedAttributes[.size] as? NSNumber)?.int64Value,
                  stagedSize > 1024,
                  stagedSize <= CADAnimationExportSettings.maximumOutputBytes else {
                throw CADAnimationExportError.verification(
                    "The encoded video is empty or exceeds the 512 MiB output bound.")
            }
            let verified = try await Self.verifyAnimationVideo(
                stagedURL, expectedWidth: settings.width,
                expectedHeight: settings.height,
                expectedFrameRate: settings.frameRate,
                expectedDuration: clip.duration,
                expectedFrameCount: totalFrames,
                codec: settings.codec)
            try Task.checkCancellation()
            guard !isClosed,
                  controller.holdsAnimationLease(exportLease),
                  controller.renderGeneration == generation,
                  liveChangeCount == documentChangeCount,
                  revision == documentRevision,
                  contentSHA256 == documentContentSHA else {
                throw CADAnimationExportError.stale
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path),
               !settings.overwrite {
                throw CADAnimationExportError.destinationExists
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destination)
            }
            try? FileManager.default.removeItem(at: staging)
            stagingDirectory = nil
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: destination.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let result = CADAnimationExportResult(
                url: destination.standardizedFileURL,
                width: verified.width, height: verified.height,
                frameRate: verified.frameRate,
                durationSeconds: verified.duration,
                frameCount: verified.frameCount,
                codec: settings.codec.rawValue,
                hasAudio: verified.hasAudio,
                byteCount: bytes,
                posterPNG: posterPNG)
            report(.finished, completed: totalFrames, time: clip.duration)
            return CADAnimationExportStatus(
                id: id,
                progress: CADAnimationExportProgress(
                    phase: .finished, completedFrames: totalFrames,
                    totalFrames: totalFrames, timeSeconds: clip.duration),
                result: result)
        } catch is CancellationError {
            writer?.cancelWriting()
            if let stagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
            let progress = CADAnimationExportProgress(
                phase: .cancelled, completedFrames: 0,
                totalFrames: totalFrames, timeSeconds: 0)
            return CADAnimationExportStatus(
                id: id, progress: progress,
                error: CADAnimationExportError.cancelled.localizedDescription,
                isCancelled: true)
        } catch {
            writer?.cancelWriting()
            if let stagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
            let progress = CADAnimationExportProgress(
                phase: .failed, completedFrames: 0,
                totalFrames: totalFrames, timeSeconds: 0)
            return CADAnimationExportStatus(
                id: id, progress: progress,
                error: error.localizedDescription)
        }
    }

    // MARK: Writer / pixels

    private static func makeAnimationWriter(
        url: URL, settings: CADAnimationExportSettings
    ) throws -> (writer: AVAssetWriter, input: AVAssetWriterInput,
                adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw CADAnimationExportError.writer(error.localizedDescription)
        }
        let pixelCount = settings.width * settings.height
        let bitrate = settings.bitrate ?? min(
            40_000_000, max(2_000_000, pixelCount * settings.frameRate / 3))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
        ]
        let codec: AVVideoCodecType
        switch settings.codec {
        case .h264:
            codec = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            codec = .hevc
        }
        let settingsDictionary: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: settingsDictionary, forMediaType: .video) else {
            throw CADAnimationExportError.writer(
                "This device does not support the requested video encoder settings.")
        }
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: settingsDictionary)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw CADAnimationExportError.writer(
                "The video encoder input could not be attached.")
        }
        writer.add(input)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        return (writer, input, adaptor)
    }

    private static func makePixelBuffer(
        image: UIImage, width: Int, height: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        attributes: [String: Any],
        background: CIColor,
        context: CIContext
    ) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary, &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(cgImage: cgImage)
        let scale = min(CGFloat(width) / max(source.extent.width, 1),
                        CGFloat(height) / max(source.extent.height, 1))
        let scaled = source.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(
            by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
        let canvasColor = CIImage(color: background).cropped(to: canvas)
        let composed = positioned.composited(over: canvasColor)
        context.render(composed, to: pixelBuffer, bounds: canvas,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixelBuffer
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        var waits = 0
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if waits >= 5_000 {
                throw CADAnimationExportError.writer(
                    "The video encoder stayed busy for too long.")
            }
            try await Task.sleep(for: .milliseconds(2))
            waits += 1
        }
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    // MARK: Verification / destination

    private struct VerifiedVideo {
        var width: Int
        var height: Int
        var frameRate: Double
        var duration: Double
        var frameCount: Int
        var hasAudio: Bool
    }

    private static func verifyAnimationVideo(
        _ url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedFrameRate: Int,
        expectedDuration: Double,
        expectedFrameCount: Int,
        codec: CADAnimationVideoCodec
    ) async throws -> VerifiedVideo {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration).seconds
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            guard playable, duration.isFinite, duration > 0 else {
                throw CADAnimationExportError.verification(
                    "The exported video is not playable.")
            }
            guard let track = videos.first else {
                throw CADAnimationExportError.verification(
                    "The exported video has no video track.")
            }
            let size = try await track.load(.naturalSize)
            let rate = try await track.load(.nominalFrameRate)
            guard Int(size.width.rounded()) == expectedWidth,
                  Int(size.height.rounded()) == expectedHeight else {
                throw CADAnimationExportError.verification(
                    "The exported video is \(Int(size.width))×\(Int(size.height)), not \(expectedWidth)×\(expectedHeight).")
            }
            guard abs(Double(rate) - Double(expectedFrameRate)) <= 1.0 else {
                throw CADAnimationExportError.verification(
                    "The exported video frame rate is \(rate), not \(expectedFrameRate).")
            }
            let tolerance = max(0.2, 2 / Double(expectedFrameRate))
            guard abs(duration - expectedDuration) <= tolerance else {
                throw CADAnimationExportError.verification(
                    "The exported video duration is \(duration) s, not \(expectedDuration) s.")
            }
            let descriptions = try await track.load(.formatDescriptions)
            if let fourCC = descriptions.first.map({
                CMFormatDescriptionGetMediaSubType($0)
            }) {
                let actual = Self.fourCCString(fourCC)
                let expected = codec == .h264 ? "avc1" : "hvc1"
                // Some encoders report `avc3`/`hev1`; both are the same codec
                // family and still a real encoded track.
                let accepted = codec == .h264
                    ? ["avc1", "avc3"]
                    : ["hvc1", "hev1"]
                guard accepted.contains(actual.lowercased())
                        || actual.lowercased() == expected else {
                    throw CADAnimationExportError.verification(
                        "The exported video codec is \(actual), not \(expected).")
                }
            }
            let frameCount = max(1, Int((duration * Double(expectedFrameRate)).rounded()))
            guard abs(frameCount - expectedFrameCount) <= 1 else {
                throw CADAnimationExportError.verification(
                    "The exported video has \(frameCount) frames, not \(expectedFrameCount).")
            }
            let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber
            guard let bytes, bytes.int64Value > 1_024 else {
                throw CADAnimationExportError.verification(
                    "The exported video is empty.")
            }
            return VerifiedVideo(width: expectedWidth, height: expectedHeight,
                                 frameRate: Double(expectedFrameRate),
                                 duration: duration, frameCount: expectedFrameCount,
                                 hasAudio: !audios.isEmpty)
        } catch let error as CADAnimationExportError {
            throw error
        } catch {
            throw CADAnimationExportError.verification(
                "The exported video could not be verified: \(error.localizedDescription)")
        }
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "----"
    }

    private static func validateAnimationExportDestination(
        _ destination: URL,
        settings: CADAnimationExportSettings
    ) throws {
        guard destination.isFileURL else {
            throw CADAnimationExportError.invalidDestination(
                "The export destination must be a file URL.")
        }
        let standardized = destination.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "mp4" else {
            throw CADAnimationExportError.invalidDestination(
                "The export destination must end in .mp4.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path,
                                          isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw CADAnimationExportError.invalidDestination(
                "The export destination is a directory, not a file.")
        }
        let parent = standardized.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path,
                                             isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw CADAnimationExportError.invalidDestination(
                "The export destination folder does not exist.")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw CADAnimationExportError.invalidDestination(
                "The export destination folder is not writable.")
        }
        if FileManager.default.fileExists(atPath: standardized.path),
           !settings.overwrite {
            throw CADAnimationExportError.destinationExists
        }
    }
}

#endif

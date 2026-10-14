import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shared service

/// Shared enhancement execution service. Owns the real pipeline:
/// preflight -> bounded decode -> processing -> timestamps/audio -> staged
/// encoding -> reopen validation -> atomic commit. A failed or cancelled run
/// never replaces the source and never leaves a partial destination.
public actor MediaEnhancementService: FrameProcessing {
    public struct Limits: Sendable {
        public var guards = MediaEnhancementGuards.Limits()
        /// Outputs up to this duration are frame-counted after encoding; longer
        /// outputs report an estimated count with a warning.
        public var fullFrameCountValidationSeconds: Double = 120
        public var maximumFullFrameCount: Int = 20_000

        public init() {}
    }

    private let runtime: MediaCoreMLRuntime
    private let limits: Limits
    private let bridge = MediaImageBridge()
    private let store = MediaPixelBufferStore()

    /// - Parameter modelResolver: resolves installed model ids for `mode=coreml`.
    ///   Workspace scope is never held here: each request snapshots the
    ///   caller's root, so concurrent task/selection changes cannot redirect
    ///   an in-flight or queued job.
    public init(
        modelResolver: (any MediaModelResolving)? = nil,
        limits: Limits = Limits()
    ) {
        self.runtime = MediaCoreMLRuntime(resolver: modelResolver)
        self.limits = limits
    }

    // MARK: FrameProcessing

    /// Legacy entry points without an explicit scope fail closed instead of
    /// falling back to a current/global workspace root. Scoped callers use
    /// `process(_:)` (or the async `enhance(_:)`) with
    /// `FrameProcessingRequest.workspaceRoot` set.
    public func interpolate(input: URL, output: URL, targetFPS: Double, mode: String, modelID: String?) async throws -> String {
        _ = (input, output, targetFPS, mode, modelID)
        throw FloeError.validationFailed("an explicit workspace scope is required; build a FrameProcessingRequest with workspaceRoot")
    }

    public func superResolution(input: URL, output: URL, scaleFactor: Int, mode: String, modelID: String?) async throws -> String {
        _ = (input, output, scaleFactor, mode, modelID)
        throw FloeError.validationFailed("an explicit workspace scope is required; build a FrameProcessingRequest with workspaceRoot")
    }

    /// New primary entry point: carries quality, overwrite consent, progress
    /// and cancellation end to end.
    public func process(_ request: FrameProcessingRequest) async throws -> String {
        let result = try await enhance(request)
        return result.digest
    }

    /// Structured variant used by the qualification host and long-job adapters.
    public func enhance(_ request: FrameProcessingRequest) async throws -> MediaEnhancementResult {
        let quality = try MediaEnhancementQuality(requested: request.quality)
        guard let mode = MediaEnhancementMode(rawValue: request.mode.lowercased()) else {
            throw FloeError.validationFailed("mode must be quality, lowLatency, metalFX or coreml")
        }
        // Snapshot the caller's trusted scope exactly once and freeze it for
        // both paths. No current selection, first project or global provider
        // is ever consulted.
        guard let scopedRoot = request.workspaceRoot else {
            throw FloeError.validationFailed("an explicit workspace scope is required; enhancement never guesses the current workspace")
        }
        let canonicalRoot = try snapshotRoot(scopedRoot)
        let inputURL = try canonical(request.input, root: canonicalRoot)
        let outputURL = try canonical(request.output, root: canonicalRoot)
        guard inputURL.path != outputURL.path else {
            throw FloeError.validationFailed("Enhancement requires a separate output file; the source is preserved")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: outputURL.path)
        if exists && !request.overwrite {
            throw FloeError.validationFailed("output already exists; pass overwrite=true to replace it explicitly")
        }
        do {
            return try await run(request: request, mode: mode, quality: quality,
                                 inputURL: inputURL, outputURL: outputURL)
        } catch is CancellationError {
            throw FloeError.cancelled
        }
    }

    /// Validates the caller-supplied root once (it must exist and be a
    /// directory) and returns its canonical form.
    private func snapshotRoot(_ root: URL) throws -> URL {
        guard root.isFileURL, !root.path.contains("\0") else {
            throw FloeError.validationFailed("The workspace scope must be a file URL")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FloeError.validationFailed("The workspace scope does not exist")
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func canonical(_ url: URL, root: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else {
            throw FloeError.validationFailed("Enhancement paths must be file URLs")
        }
        return try MediaPathGuard.resolve(url.path, root: root)
    }

    // MARK: Orchestration

    private func run(
        request: FrameProcessingRequest,
        mode: MediaEnhancementMode,
        quality: MediaEnhancementQuality?,
        inputURL: URL,
        outputURL: URL
    ) async throws -> MediaEnhancementResult {
        request.progress(MediaEnhancementProgress(phase: .preflight, completedUnits: 0, totalUnits: 1))
        let source = try await MediaSourceInspector.inspect(url: inputURL)
        let guarded = try MediaEnhancementGuards.validate(source: source, request: request.mediaRequest(input: inputURL, output: outputURL), limits: limits.guards)
        if source.isImage {
            return try await runImage(
                request: request, mode: mode, quality: quality ?? .balanced,
                source: source, outputWidth: guarded.displayWidth, outputHeight: guarded.displayHeight,
                inputURL: inputURL, outputURL: outputURL
            )
        }
        return try await runVideo(
            request: request, mode: mode, quality: quality ?? .quality,
            source: source, framesPerPair: guarded.framesPerPair,
            outputWidth: guarded.displayWidth, outputHeight: guarded.displayHeight,
            inputURL: inputURL, outputURL: outputURL
        )
    }

    // MARK: Video pipeline

    private func runVideo(
        request: FrameProcessingRequest,
        mode: MediaEnhancementMode,
        quality: MediaEnhancementQuality,
        source: MediaSourceDescriptor,
        framesPerPair: Int,
        outputWidth: Int,
        outputHeight: Int,
        inputURL: URL,
        outputURL: URL
    ) async throws -> MediaEnhancementResult {
        let container = try videoContainer(for: outputURL)
        let targetFPS: Double
        let phases: [Float]
        let interpolationEngine: (any MediaInterpolationEngine)?
        let superResolutionEngine: (any MediaSuperResolutionEngine)?
        var warnings: [String] = []

        switch request.operation {
        case .interpolation(let fps):
            targetFPS = fps
            phases = (1..<framesPerPair).map { Float(Double($0) / Double(framesPerPair)) }
            superResolutionEngine = nil
            interpolationEngine = try await makeInterpolationEngine(
                mode: mode, quality: quality, source: source,
                framesPerPair: framesPerPair, modelID: request.modelID
            )
        case .superResolution(let scaleFactor):
            guard !source.isImage else { throw FloeError.validationFailed("Use the image path for still images") }
            targetFPS = source.naturalFPS
            phases = []
            interpolationEngine = nil
            superResolutionEngine = try await makeSuperResolutionEngine(
                mode: mode, quality: quality, source: source,
                scaleFactor: scaleFactor, modelID: request.modelID, inputType: .video
            )
        }

        let engineName = interpolationEngine?.name ?? superResolutionEngine?.name ?? "none"
        let prepared = try (interpolationEngine?.prepare() ?? superResolutionEngine?.prepare() ?? [])
        warnings.append(contentsOf: prepared.filter { !$0.hasPrefix("engine=") })

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw FloeError.validationFailed("Input has no video track") }
        let transform = try await videoTrack.load(.preferredTransform)
        let exifOrientation = source.hadRotation ? MediaFrameOrientation.exifOrientation(transform: transform) : 1

        let staged = outputURL.stagedSibling
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: MediaImageBridge.bgra]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw FloeError.validationFailed("Cannot decode the video track") }

        let writer = try AVAssetWriter(outputURL: staged, fileType: container.fileType)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]
        let bitrate = Self.derivedBitrate(width: outputWidth, height: outputHeight, fps: targetFPS)
        videoSettings[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: Int(max(1, (targetFPS * 2).rounded())),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw FloeError.validationFailed("Device rejected the requested H.264 settings for \(outputWidth)x\(outputHeight)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw FloeError.validationFailed("Cannot connect the video writer") }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: MediaImageBridge.bgra,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )

        var audioStream: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if source.hasAudio, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            // Pass-through copy when the container accepts the source format;
            // otherwise transcode to AAC without touching the video path.
            let passthroughInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            passthroughInput.expectsMediaDataInRealTime = false
            if writer.canAdd(passthroughInput), reader.canAdd(audioOutput) {
                audioStream = (audioOutput, passthroughInput)
            } else {
                let description = try await audioTrack.load(.formatDescriptions).first
                if let description, let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.mSampleRate,
                        AVNumberOfChannelsKey: Int(format.mChannelsPerFrame)
                    ]
                    let encodedInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                    encodedInput.expectsMediaDataInRealTime = false
                    let pcmOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    pcmOutput.alwaysCopiesSampleData = false
                    if writer.canAdd(encodedInput), reader.canAdd(pcmOutput) {
                        audioStream = (pcmOutput, encodedInput)
                    } else {
                        warnings.append("the source audio track cannot be copied into \(container.fileType.rawValue); the output will be silent")
                    }
                }
            }
        } else if source.hasAudio {
            warnings.append("the source audio track could not be opened; the output will be silent")
        }

        reader.add(videoOutput)
        if let audioStream { reader.add(audioStream.output); writer.add(audioStream.input) }
        writer.add(videoInput)
        let control = MediaTransferControl(reader: reader, writer: writer)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? FloeError.internalError("Could not start media processing")
        }
        writer.startSession(atSourceTime: .zero)
        defer { try? FileManager.default.removeItem(at: staged) }

        let expectedOutputFrames = max(1, Int((source.durationSeconds * targetFPS).rounded()))
        let work = VideoEnhancementWork(
            reader: reader, videoOutput: videoOutput, videoInput: videoInput, adaptor: adaptor,
            writer: writer, control: control, engine: interpolationEngine, superResolutionEngine: superResolutionEngine,
            phases: phases, framesPerPair: framesPerPair, source: source, outputWidth: outputWidth,
            outputHeight: outputHeight, targetFPS: targetFPS, exifOrientation: exifOrientation,
            expectedOutputFrames: expectedOutputFrames, bridge: bridge, store: store,
            cancellation: request.cancellation, progress: request.progress
        )

        let cancellationWatcher = Task {
            while !Task.isCancelled {
                if request.cancellation?.isCancelled == true { control.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { cancellationWatcher.cancel() }

        let audioTransfer: MediaSampleTransfer? = audioStream.map {
            MediaSampleTransfer(source: $0.output, destination: $0.input, control: control)
        }
        let audioTask: Task<Void, any Error>? = audioTransfer.map { transfer in
            Task { try await transfer.run(cancellation: request.cancellation) }
        }
        let outcome: VideoEnhancementOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await work.run()
            } onCancel: {
                control.cancel()
            }
            try await audioTask?.value
        } catch {
            control.cancel()
            _ = try? await audioTask?.value
            interpolationEngine?.teardown()
            superResolutionEngine?.teardown()
            throw error
        }
        interpolationEngine?.teardown()
        superResolutionEngine?.teardown()
        try request.cancellation?.throwIfCancelled()

        do {
            if let audioStream, !outcome.videoFinished {
                throw FloeError.internalError("video stream did not finish before audio copy")
            }
            _ = audioStream
            try await control.finish()
        } catch {
            throw FloeError.internalError("Media writer did not finish: \(error.localizedDescription)")
        }

        request.progress(MediaEnhancementProgress(phase: .validating, completedUnits: 0, totalUnits: 1))
        let validation = try await MediaEnhancementValidator.validateVideo(
            staged: staged,
            expectedWidth: outputWidth,
            expectedHeight: outputHeight,
            expectedFPS: targetFPS,
            expectedDuration: source.durationSeconds,
            expectAudio: source.hasAudio && audioStream != nil,
            expectInterpolatedFrames: interpolationEngine != nil,
            motionObserved: outcome.motionObserved,
            limits: limits
        )
        try request.cancellation?.throwIfCancelled()

        request.progress(MediaEnhancementProgress(phase: .committing, completedUnits: 0, totalUnits: 1))
        let receipt = try commit(staged: staged, destination: outputURL, overwrite: request.overwrite, cancellation: request.cancellation)
        return MediaEnhancementResult(
            outputPath: outputURL.path,
            engine: engineName,
            mode: mode.rawValue,
            inputKind: "video",
            sourceWidth: source.displayWidth,
            sourceHeight: source.displayHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            sourceFPS: source.naturalFPS,
            outputFPS: targetFPS,
            sourceDurationSeconds: source.durationSeconds,
            outputDurationSeconds: validation.durationSeconds,
            sourceFrameCount: outcome.sourceFrameCount,
            outputFrameCount: validation.frameCount,
            interpolatedFrameCount: outcome.interpolatedFrames,
            audioCopied: validation.audioTrackSeconds != nil,
            hadRotation: source.hadRotation,
            outputBytes: Int64(receipt.byteCount),
            outputSHA256: receipt.sha256,
            warnings: warnings + validation.warnings
        )
    }

    // MARK: Image pipeline

    private func runImage(
        request: FrameProcessingRequest,
        mode: MediaEnhancementMode,
        quality: MediaEnhancementQuality,
        source: MediaSourceDescriptor,
        outputWidth: Int,
        outputHeight: Int,
        inputURL: URL,
        outputURL: URL
    ) async throws -> MediaEnhancementResult {
        guard case .superResolution(let scaleFactor) = request.operation else {
            throw FloeError.validationFailed("Frame interpolation requires a video input")
        }
        let engine = try await makeSuperResolutionEngine(
            mode: mode, quality: quality, source: source,
            scaleFactor: scaleFactor, modelID: request.modelID, inputType: .image
        )
        var warnings = try engine.prepare().filter { !$0.hasPrefix("engine=") }
        defer { engine.teardown() }

        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw FloeError.validationFailed("Image could not be decoded")
        }
        let inputBuffer = try store.makeBuffer(format: MediaImageBridge.bgra, width: source.width, height: source.height)
        let orientationProperty = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        try bridge.render(
            source: buffer(from: cgImage, width: source.width, height: source.height),
            destination: inputBuffer,
            exifOrientation: orientationProperty ?? 1
        )
        let outputBuffer = try store.makeBuffer(format: MediaImageBridge.bgra, width: outputWidth, height: outputHeight)
        try engine.scale(current: inputBuffer, output: outputBuffer)

        let staged = outputURL.stagedSibling
        defer { try? FileManager.default.removeItem(at: staged) }
        try writeImage(outputBuffer, to: staged, uniformType: try imageType(for: outputURL))
        let validation = try MediaEnhancementValidator.validateImage(
            staged: staged, expectedWidth: outputWidth, expectedHeight: outputHeight
        )
        try request.cancellation?.throwIfCancelled()
        let receipt = try commit(staged: staged, destination: outputURL, overwrite: request.overwrite, cancellation: request.cancellation)
        _ = validation.byteCount
        return MediaEnhancementResult(
            outputPath: outputURL.path,
            engine: engine.name,
            mode: mode.rawValue,
            inputKind: "image",
            sourceWidth: source.displayWidth,
            sourceHeight: source.displayHeight,
            outputWidth: validation.width,
            outputHeight: validation.height,
            sourceFPS: 0,
            outputFPS: 0,
            sourceDurationSeconds: 0,
            outputDurationSeconds: 0,
            sourceFrameCount: 1,
            outputFrameCount: 1,
            interpolatedFrameCount: 0,
            audioCopied: false,
            hadRotation: source.hadRotation,
            outputBytes: Int64(receipt.byteCount),
            outputSHA256: receipt.sha256,
            warnings: warnings
        )
    }

    // MARK: Engine factories

    private func makeInterpolationEngine(
        mode: MediaEnhancementMode,
        quality: MediaEnhancementQuality,
        source: MediaSourceDescriptor,
        framesPerPair: Int,
        modelID: String?
    ) async throws -> any MediaInterpolationEngine {
        switch mode {
        case .quality:
            // The VTFrameProcessor configuration types are absent from the
            // Simulator SDK headers; the engines compile on macOS hosts and
            // physical devices only, so the Simulator reports the honest
            // unsupported reason instead of silently swapping backends.
            #if targetEnvironment(simulator)
            throw FloeError.invalidConfiguration("VTFrameProcessor frame rate conversion is not supported in the Simulator; run it on a macOS host or a physical device")
            #else
            guard #available(iOS 26.0, macOS 15.4, *) else {
                throw FloeError.invalidConfiguration("VTFrameProcessor frame rate conversion requires iOS 26 or macOS 15.4")
            }
            return VideoToolboxInterpolationEngine(
                width: source.displayWidth, height: source.displayHeight,
                framesPerPair: framesPerPair, quality: quality, bridge: bridge, store: store
            )
            #endif
        case .lowLatency:
            #if targetEnvironment(simulator)
            throw FloeError.invalidConfiguration("VT low-latency frame interpolation is not supported in the Simulator; run it on a macOS host or a physical device")
            #else
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw FloeError.invalidConfiguration("VT low-latency interpolation requires iOS 26 or macOS 26")
            }
            return try VideoToolboxLowLatencyInterpolationEngine(
                width: source.displayWidth, height: source.displayHeight,
                framesPerPair: framesPerPair, bridge: bridge, store: store
            )
            #endif
        case .metalFX:
            throw FloeError.invalidConfiguration(
                "MetalFX frame interpolation requires renderer-provided motion vectors and depth; it cannot interpolate a decoded video file. Use mode=quality or mode=lowLatency"
            )
        case .coreml:
            guard let modelID else {
                throw FloeError.validationFailed("mode=coreml requires an explicit modelID from media.models")
            }
            let loaded = try await runtime.model(id: modelID)
            return try CoreMLInterpolationEngine(
                loaded: loaded, width: source.displayWidth, height: source.displayHeight,
                framesPerPair: framesPerPair, quality: quality, bridge: bridge, store: store
            )
        }
    }

    private func makeSuperResolutionEngine(
        mode: MediaEnhancementMode,
        quality: MediaEnhancementQuality,
        source: MediaSourceDescriptor,
        scaleFactor: Int,
        modelID: String?,
        inputType: MediaSRInputType
    ) async throws -> any MediaSuperResolutionEngine {
        switch mode {
        case .quality:
            #if targetEnvironment(simulator)
            throw FloeError.invalidConfiguration("VTFrameProcessor super resolution is not supported in the Simulator; run it on a macOS host or a physical device")
            #else
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw FloeError.invalidConfiguration("VTFrameProcessor super resolution requires iOS 26 or macOS 26")
            }
            return VideoToolboxSuperResolutionEngine(
                width: source.displayWidth, height: source.displayHeight, scaleFactor: scaleFactor,
                inputType: inputType == .video ? .video : .image, bridge: bridge, store: store
            )
            #endif
        case .lowLatency:
            #if targetEnvironment(simulator)
            throw FloeError.invalidConfiguration("VT low-latency super resolution is not supported in the Simulator; run it on a macOS host or a physical device")
            #else
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw FloeError.invalidConfiguration("VT low-latency super resolution requires iOS 26 or macOS 26")
            }
            return VideoToolboxLowLatencySuperResolutionEngine(
                width: source.displayWidth, height: source.displayHeight, scaleFactor: scaleFactor,
                bridge: bridge, store: store
            )
            #endif
        case .metalFX:
            #if canImport(Metal) && canImport(MetalFX)
            return try MetalFXSpatialSuperResolutionEngine(
                width: source.displayWidth, height: source.displayHeight, scaleFactor: scaleFactor,
                bridge: bridge, store: store
            )
            #else
            throw FloeError.invalidConfiguration("MetalFX is unavailable on this platform")
            #endif
        case .coreml:
            guard let modelID else {
                throw FloeError.validationFailed("mode=coreml requires an explicit modelID from media.models")
            }
            let loaded = try await runtime.model(id: modelID)
            return try CoreMLSuperResolutionEngine(
                loaded: loaded, width: source.displayWidth, height: source.displayHeight,
                scaleFactor: scaleFactor, quality: quality, bridge: bridge, store: store
            )
        }
    }

    // MARK: Helpers

    private func commit(
        staged: URL,
        destination: URL,
        overwrite: Bool,
        cancellation: CancellationToken?
    ) throws -> FileCommitReceipt {
        let policy = FileCommitPolicy(
            conflict: overwrite ? .replaceAtomically(consent: true) : .failIfExists,
            checkCancellation: { try cancellation?.throwIfCancelled() }
        )
        return try AtomicFileCommitter.commit(stagedFile: staged, to: destination, policy: policy)
    }

    static func derivedBitrate(width: Int, height: Int, fps: Double) -> Int {
        let bits = Double(width) * Double(height) * max(fps, 1) * 0.1
        return Int(min(max(bits, 2_000_000), 80_000_000))
    }

    private func videoContainer(for url: URL) throws -> (fileType: AVFileType, label: String) {
        switch url.pathExtension.lowercased() {
        case "mp4": return (.mp4, "mp4")
        case "mov": return (.mov, "mov")
        case "m4v": return (.m4v, "m4v")
        default: throw FloeError.validationFailed("Video enhancement outputs must be mp4, mov or m4v")
        }
    }

    private func imageType(for url: URL) throws -> UTType {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "tif", "tiff": return .tiff
        default: throw FloeError.validationFailed("Image enhancement outputs must be png, jpeg, heic or tiff")
        }
    }

    private func buffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try store.makeBuffer(format: MediaImageBridge.bgra, width: width, height: height)
        bridge.cicontext.render(
            CIImage(cgImage: image), to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: bridge.colorSpace
        )
        return buffer
    }

    private func writeImage(_ buffer: CVPixelBuffer, to url: URL, uniformType: UTType) throws {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = bridge.cicontext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: bridge.colorSpace) else {
            throw FloeError.internalError("Could not encode the enhanced image")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uniformType.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("Could not create an image destination for \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FloeError.internalError("Image encoding failed")
        }
    }

}

// MARK: - FrameProcessing request bridge

extension FrameProcessingRequest {
    func mediaRequest(input: URL, output: URL) -> MediaEnhancementRequest {
        MediaEnhancementRequest(
            inputPath: input.path,
            outputPath: output.path,
            operation: operation,
            mode: mode,
            modelID: modelID,
            quality: quality,
            overwrite: overwrite,
            workspaceRootPath: workspaceRoot?.path
        )
    }
}

// MARK: - Video work (dedicated worker)

struct VideoEnhancementOutcome: Sendable {
    var sourceFrameCount: Int
    var interpolatedFrames: Int
    var videoFinished: Bool
    var motionObserved: Bool
}

/// All AVFoundation state for one video run. The blocking loop executes on a
/// dedicated serial worker, never on Swift's cooperative pool.
final class VideoEnhancementWork: @unchecked Sendable {
    let reader: AVAssetReader
    let videoOutput: AVAssetReaderTrackOutput
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let writer: AVAssetWriter
    let control: MediaTransferControl
    let engine: (any MediaInterpolationEngine)?
    let superResolutionEngine: (any MediaSuperResolutionEngine)?
    let phases: [Float]
    let framesPerPair: Int
    let source: MediaSourceDescriptor
    let outputWidth: Int
    let outputHeight: Int
    let targetFPS: Double
    let exifOrientation: UInt32
    let expectedOutputFrames: Int
    let bridge: MediaImageBridge
    let store: MediaPixelBufferStore
    let cancellation: CancellationToken?
    let progress: @Sendable (MediaEnhancementProgress) -> Void

    private let queue = DispatchQueue(label: "org.floe.media.enhancement", qos: .userInitiated)

    init(
        reader: AVAssetReader, videoOutput: AVAssetReaderTrackOutput, videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter, control: MediaTransferControl,
        engine: (any MediaInterpolationEngine)?, superResolutionEngine: (any MediaSuperResolutionEngine)?,
        phases: [Float], framesPerPair: Int, source: MediaSourceDescriptor, outputWidth: Int,
        outputHeight: Int, targetFPS: Double, exifOrientation: UInt32, expectedOutputFrames: Int,
        bridge: MediaImageBridge, store: MediaPixelBufferStore, cancellation: CancellationToken?,
        progress: @escaping @Sendable (MediaEnhancementProgress) -> Void
    ) {
        self.reader = reader
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.writer = writer
        self.control = control
        self.engine = engine
        self.superResolutionEngine = superResolutionEngine
        self.phases = phases
        self.framesPerPair = framesPerPair
        self.source = source
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.targetFPS = targetFPS
        self.exifOrientation = exifOrientation
        self.expectedOutputFrames = expectedOutputFrames
        self.bridge = bridge
        self.store = store
        self.cancellation = cancellation
        self.progress = progress
    }

    func run() async throws -> VideoEnhancementOutcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let outcome = try execute()
                    continuation.resume(returning: outcome)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute() throws -> VideoEnhancementOutcome {
        var sourceFrameCount = 0
        var interpolatedFrames = 0
        var outputIndex = 0
        var motionObserved = false
        var diffSamples: [Double] = []

        func checkCancellation() throws {
            try cancellation?.throwIfCancelled()
            if control.writer.status == .cancelled || control.reader.status == .cancelled { throw FloeError.cancelled }
        }

        func readNext() throws -> CVPixelBuffer? {
            while true {
                try checkCancellation()
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    if control.reader.status == .cancelled { throw FloeError.cancelled }
                    guard control.reader.status != .failed else {
                        throw control.reader.error ?? FloeError.internalError("Video decode failed")
                    }
                    return nil
                }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                return pixelBuffer
            }
        }

        func append(_ buffer: CVPixelBuffer, index: Int) throws {
            while !videoInput.isReadyForMoreMediaData {
                try checkCancellation()
                Thread.sleep(forTimeInterval: 0.002)
            }
            let time = CMTime(
                value: Int64((Double(index) * 60_000.0 / targetFPS).rounded()),
                timescale: 60_000
            )
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? FloeError.internalError("Video append failed at frame \(index)")
            }
        }

        func upright(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
            guard exifOrientation != 1 else { return buffer }
            let upright = try store.makeBuffer(
                format: MediaImageBridge.bgra,
                width: source.displayWidth,
                height: source.displayHeight
            )
            try bridge.render(source: buffer, destination: upright, exifOrientation: exifOrientation)
            return upright
        }

        var current = try readNext()
        var previousInput: CVPixelBuffer?
        while let frame = current {
            try checkCancellation()
            sourceFrameCount += 1
            let normalized = try upright(frame)
            let nextRaw = try readNext()
            let next = try nextRaw.map { try upright($0) }

            // Motion sampling for the post-encode duplicate check (bounded).
            if let next, diffSamples.count < 6 {
                let diff = try MediaModelReadiness.meanAbsoluteDifference(normalized, next)
                diffSamples.append(diff)
                if diff > 0.002 { motionObserved = true }
            }
            previousInput = normalized

            switch (engine, superResolutionEngine) {
            case (let engine?, nil):
                try append(normalized, index: outputIndex)
                outputIndex += 1
                if let next {
                    let destinations = try (0..<engine.interpolatedPerPair).map { _ in
                        try store.makeBuffer(format: MediaImageBridge.bgra, width: outputWidth, height: outputHeight)
                    }
                    if !destinations.isEmpty {
                        try engine.interpolate(current: normalized, next: next, phases: phases, outputs: destinations)
                        for destination in destinations {
                            try append(destination, index: outputIndex)
                            outputIndex += 1
                            interpolatedFrames += 1
                        }
                    }
                }
            case (nil, let engine?):
                let destination = try store.makeBuffer(format: MediaImageBridge.bgra, width: outputWidth, height: outputHeight)
                try engine.scale(current: normalized, output: destination)
                try append(destination, index: outputIndex)
                outputIndex += 1
            default:
                throw FloeError.internalError("No enhancement engine is attached")
            }

            if outputIndex % 10 == 0 || next == nil {
                progress(MediaEnhancementProgress(phase: .processing, completedUnits: outputIndex, totalUnits: max(1, expectedOutputFrames)))
            }
            current = next
        }
        videoInput.markAsFinished()
        return VideoEnhancementOutcome(
            sourceFrameCount: sourceFrameCount,
            interpolatedFrames: interpolatedFrames,
            videoFinished: true,
            motionObserved: motionObserved
        )
    }
}

// MARK: - Output validation

enum MediaEnhancementValidator {
    struct VideoValidation {
        var durationSeconds: Double
        var frameCount: Int
        var audioTrackSeconds: Double?
        var warnings: [String]
    }

    struct ImageValidation {
        var width: Int
        var height: Int
        var byteCount: Int
    }

    static func validateVideo(
        staged: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedFPS: Double,
        expectedDuration: Double,
        expectAudio: Bool,
        expectInterpolatedFrames: Bool,
        motionObserved: Bool,
        limits: MediaEnhancementService.Limits
    ) async throws -> VideoValidation {
        var warnings: [String] = []
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw FloeError.validationFailed("Encoded output is missing")
        }
        let asset = AVURLAsset(url: staged)
        guard try await asset.load(.isPlayable) else {
            throw FloeError.validationFailed("Encoded output is not playable")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FloeError.validationFailed("Encoded output has no duration") }
        let tolerance = max(0.2, 2.0 / expectedFPS)
        guard abs(duration - expectedDuration) <= tolerance else {
            throw FloeError.validationFailed(
                "Encoded duration \(String(format: "%.3f", duration))s differs from the source \(String(format: "%.3f", expectedDuration))s"
            )
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FloeError.validationFailed("Encoded output has no video track")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: size).applying(transform)
        let width = Int(abs(displayed.width).rounded())
        let height = Int(abs(displayed.height).rounded())
        guard width == expectedWidth, height == expectedHeight else {
            throw FloeError.validationFailed("Encoded dimensions \(width)x\(height) do not match the requested \(expectedWidth)x\(expectedHeight)")
        }
        let rate = Double(try await track.load(.nominalFrameRate))
        guard rate > 0, abs(rate - expectedFPS) <= max(0.5, expectedFPS * 0.02) else {
            throw FloeError.validationFailed("Encoded frame rate \(rate) does not match the requested \(expectedFPS)")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        if expectAudio && audioTrack == nil {
            throw FloeError.validationFailed("Encoded output lost the source audio track")
        }
        var audioSeconds: Double?
        if let audioTrack {
            let range = try await audioTrack.load(.timeRange)
            audioSeconds = range.duration.seconds
            if abs(range.duration.seconds - duration) > 1.0 {
                warnings.append("audio duration \(String(format: "%.2f", range.duration.seconds))s differs from video \(String(format: "%.2f", duration))s")
            }
        }
        let counted = try await countFrames(
            asset: asset, track: track, duration: duration,
            fullSeconds: limits.fullFrameCountValidationSeconds, maximum: limits.maximumFullFrameCount
        )
        if counted.estimated {
            warnings.append("frame count estimated at \(counted.count) (output exceeds the full-count validation bound)")
        } else if expectedFPS > 0 {
            let nominal = Int((duration * expectedFPS).rounded())
            if abs(counted.count - nominal) > max(2, nominal / 50) {
                warnings.append("counted frames \(counted.count) differ from fps x duration \(nominal)")
            }
        }
        if expectInterpolatedFrames {
            let duplicate = try await checkInterpolatedFrames(
                asset: asset, track: track, motionObserved: motionObserved
            )
            if duplicate.duplicateLikely {
                throw FloeError.validationFailed(
                    "Interpolated output frames appear to be duplicates of their neighbours despite visible source motion"
                )
            }
            if let note = duplicate.note { warnings.append(note) }
        }
        return VideoValidation(durationSeconds: duration, frameCount: counted.count, audioTrackSeconds: audioSeconds, warnings: warnings)
    }

    private static func countFrames(
        asset: AVURLAsset, track: AVAssetTrack, duration: Double, fullSeconds: Double, maximum: Int
    ) async throws -> (count: Int, estimated: Bool) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FloeError.validationFailed("Could not read the encoded video track") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FloeError.internalError("Could not start output verification") }
        var count = 0
        var hitSafetyLimit = false
        while let sample = output.copyNextSampleBuffer() {
            _ = sample
            count += 1
            if count >= maximum { hitSafetyLimit = true; break }
        }
        reader.cancelReading()
        if !hitSafetyLimit && duration <= fullSeconds {
            return (count, false)
        }
        let rate = Double(try await track.load(.nominalFrameRate))
        return (Int((duration * max(rate, 1)).rounded()), true)
    }

    private static func checkInterpolatedFrames(
        asset: AVURLAsset, track: AVAssetTrack, motionObserved: Bool
    ) async throws -> (duplicateLikely: Bool, note: String?) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return (false, "could not re-read the output for duplicate validation") }
        reader.add(output)
        guard reader.startReading() else { return (false, "could not re-read the output for duplicate validation") }
        defer { reader.cancelReading() }
        var frames: [CVPixelBuffer] = []
        while frames.count < 6, let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(buffer) }
        }
        guard frames.count >= 3 else {
            return (false, "output is too short for interpolated-frame sampling")
        }
        var minDifference: Double = 1
        for index in 1..<(frames.count - 1) {
            let left = try MediaModelReadiness.meanAbsoluteDifference(frames[index], frames[index - 1])
            let right = try MediaModelReadiness.meanAbsoluteDifference(frames[index], frames[index + 1])
            minDifference = min(minDifference, max(left, right))
        }
        if !motionObserved {
            return (false, "source scene is static; duplicate equality is expected")
        }
        // H.264 quantisation can shrink differences; 1/255 is well below any
        // genuine interpolated frame difference and well above codec noise.
        if minDifference < 1.0 / 255.0 {
            return (true, nil)
        }
        return (false, String(format: "interpolated frame minimum neighbour difference %.5f", minDifference))
    }

    static func validateImage(staged: URL, expectedWidth: Int, expectedHeight: Int) throws -> ImageValidation {
        guard let source = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw FloeError.validationFailed("Encoded image could not be reopened")
        }
        guard width == expectedWidth, height == expectedHeight else {
            throw FloeError.validationFailed("Encoded image is \(width)x\(height), expected \(expectedWidth)x\(expectedHeight)")
        }
        let bytes = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { throw FloeError.validationFailed("Encoded image is empty") }
        return ImageValidation(width: width, height: height, byteCount: bytes)
    }
}

extension URL {
    /// Sibling staging path: same volume as the destination so the final move
    /// is atomic, unique per run so concurrent runs never collide.
    var stagedSibling: URL {
        let directory = deletingLastPathComponent()
        let name = ".floe-enhance-\(UUID().uuidString).\(pathExtension.isEmpty ? "tmp" : pathExtension)"
        return directory.appendingPathComponent(name)
    }
}

#endif

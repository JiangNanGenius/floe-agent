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
        let cancellation = request.cancellation?.derived() ?? CancellationToken()
        let effective = FrameProcessingRequest(operation: request.operation, input: request.input, output: request.output,
            mode: request.mode, modelID: request.modelID, quality: request.quality, overwrite: request.overwrite,
            workspaceRoot: request.workspaceRoot, progress: request.progress, cancellation: cancellation)
        do {
            return try await withTaskCancellationHandler {
                try cancellation.throwIfCancelled()
                return try await run(request: effective, mode: mode, quality: quality, inputURL: inputURL, outputURL: outputURL)
            } onCancel: { cancellation.cancel() }
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
        let format = try MediaEnhancementFormat(source: source, mode: mode, output: outputURL)
        let bridge = MediaImageBridge(colorSpace: format.workingSpace)
        let store = MediaPixelBufferStore()
        let container = try videoContainer(for: outputURL)
        let targetFPS: Double
        let phases: [Float]
        let interpolationEngine: (any MediaInterpolationEngine)?
        let superResolutionEngine: (any MediaSuperResolutionEngine)?
        var warnings: [String] = [format.description]

        switch request.operation {
        case .interpolation(let fps):
            targetFPS = fps
            phases = (1..<framesPerPair).map { Float(Double($0) / Double(framesPerPair)) }
            superResolutionEngine = nil
            interpolationEngine = try await makeInterpolationEngine(
                mode: mode, quality: quality, source: source,
                framesPerPair: framesPerPair, modelID: request.modelID, bridge: bridge, store: store
            )
        case .superResolution(let scaleFactor):
            guard !source.isImage else { throw FloeError.validationFailed("Use the image path for still images") }
            targetFPS = source.naturalFPS
            phases = []
            interpolationEngine = nil
            superResolutionEngine = try await makeSuperResolutionEngine(
                mode: mode, quality: quality, source: source,
                scaleFactor: scaleFactor, modelID: request.modelID, inputType: .video, bridge: bridge, store: store
            )
        }

        let engineName = interpolationEngine?.name ?? superResolutionEngine?.name ?? "none"
        let prepared = try (interpolationEngine?.prepare() ?? superResolutionEngine?.prepare() ?? [])
        warnings.append(contentsOf: prepared.filter { !$0.hasPrefix("engine=") })
        defer { interpolationEngine?.teardown(); superResolutionEngine?.teardown() }

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw FloeError.validationFailed("Input has no video track") }
        let transform = try await videoTrack.load(.preferredTransform)
        let exifOrientation = source.hadRotation ? MediaFrameOrientation.exifOrientation(transform: transform) : 1

        let staged = outputURL.stagedSibling
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format.readerPixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw FloeError.validationFailed("Cannot decode the video track") }

        let writer = try AVAssetWriter(outputURL: staged, fileType: container.fileType)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight
        ]
        let bitrate = Self.derivedBitrate(width: outputWidth, height: outputHeight, fps: targetFPS)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: Int(max(1, (targetFPS * 2).rounded()))
        ]
        if format.hdr { compression[AVVideoProfileLevelKey] = "HEVC_Main10_AutoLevel" }
        else if !format.alpha { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        if format.hdr { videoSettings[AVVideoColorPropertiesKey] = format.videoColorProperties }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw FloeError.validationFailed("Device rejected the requested \(format.codec.rawValue) settings for \(outputWidth)x\(outputHeight)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw FloeError.validationFailed("Cannot connect the video writer") }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: format.writerPixelFormat,
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

        let expectedOutputFrames = max(1, Int(ceil(source.durationSeconds * targetFPS)))
        let work = VideoEnhancementWork(
            reader: reader, videoOutput: videoOutput, videoInput: videoInput, adaptor: adaptor,
            writer: writer, control: control, engine: interpolationEngine, superResolutionEngine: superResolutionEngine,
            phases: phases, framesPerPair: framesPerPair, source: source, outputWidth: outputWidth,
            outputHeight: outputHeight, targetFPS: targetFPS, exifOrientation: exifOrientation,
            expectedOutputFrames: expectedOutputFrames, maximumFrames: limits.guards.maximumSourceFrames,
            format: format, bridge: bridge, store: store,
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
            writer.endSession(atSourceTime: CMTime(seconds: source.durationSeconds, preferredTimescale: 600_000))
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
            limits: limits, format: format, evidence: outcome.pixelEvidence
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
        let format = try MediaEnhancementFormat(source: source, mode: mode, output: outputURL)
        let bridge = MediaImageBridge(colorSpace: format.workingSpace)
        let store = MediaPixelBufferStore()
        let engine = try await makeSuperResolutionEngine(
            mode: mode, quality: quality, source: source,
            scaleFactor: scaleFactor, modelID: request.modelID, inputType: .image, bridge: bridge, store: store
        )
        let warnings = try engine.prepare().filter { !$0.hasPrefix("engine=") } + [format.description]
        defer { engine.teardown() }

        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            throw FloeError.validationFailed("Image could not be decoded")
        }
        if format.hdr {
            guard cgImage.bitsPerComponent >= 16, let space = cgImage.colorSpace,
                  space.model == .rgb || space.model == .monochrome else {
                throw FloeError.invalidConfiguration("The high precision image could not be decoded with its original precision and color space")
            }
        }
        let orientationProperty = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        let inputBuffer = try store.makeBuffer(format: format.workingPixelFormat, width: source.displayWidth, height: source.displayHeight)
        try bridge.render(image: CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(orientationProperty ?? 1)), destination: inputBuffer)
        let outputBuffer = try store.makeBuffer(format: format.workingPixelFormat, width: outputWidth, height: outputHeight)
        let engineInput = format.alpha ? try bridge.opaqueColor(inputBuffer, store: store) : inputBuffer
        try request.cancellation?.throwIfCancelled()
        try engine.scale(current: engineInput, output: outputBuffer, cancellation: request.cancellation)
        let finalBuffer: CVPixelBuffer
        if format.alpha {
            finalBuffer = try store.makeBuffer(format: format.workingPixelFormat, width: outputWidth, height: outputHeight)
            try bridge.restoreAlpha(color: outputBuffer, current: inputBuffer, destination: finalBuffer)
        } else { finalBuffer = outputBuffer }
        let evidence = try MediaPixelEvidence.capture(finalBuffer, bridge: bridge)
        if format.hdr { try MediaPixelEvidence.requireRange(source: MediaPixelEvidence.capture(inputBuffer, bridge: bridge), output: evidence) }
        let staged = outputURL.stagedSibling
        defer { try? FileManager.default.removeItem(at: staged) }
        try writeImage(finalBuffer, to: staged, uniformType: try imageType(for: outputURL), format: format, bridge: bridge)
        let validation = try MediaEnhancementValidator.validateImage(
            staged: staged, expectedWidth: outputWidth, expectedHeight: outputHeight,
            format: format, evidence: evidence, bridge: bridge
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
        modelID: String?, bridge: MediaImageBridge, store: MediaPixelBufferStore
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
        inputType: MediaSRInputType, bridge: MediaImageBridge, store: MediaPixelBufferStore
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

    private func writeImage(_ buffer: CVPixelBuffer, to url: URL, uniformType: UTType,
                            format: MediaEnhancementFormat, bridge: MediaImageBridge) throws {
        let image = bridge.image(buffer)
        if format.hdr {
            guard let bytes = bridge.cicontext.tiffRepresentation(of: image, format: .RGBAh, colorSpace: format.workingSpace, options: [:]) else {
                throw FloeError.invalidConfiguration("Floating-point TIFF encoding is unavailable")
            }
            try bytes.write(to: url, options: .atomic)
            return
        }
        guard let cgImage = bridge.cicontext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: bridge.colorSpace),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, uniformType.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("Could not create the enhanced image")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw FloeError.internalError("Image encoding failed") }
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
    var pixelEvidence: [MediaPixelEvidence]
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
    let maximumFrames: Int
    let format: MediaEnhancementFormat
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
        maximumFrames: Int, format: MediaEnhancementFormat,
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
        self.maximumFrames = maximumFrames
        self.format = format
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
        let clock = try MediaOutputFrameClock(fps: targetFPS)
        var sourceFrameCount = 0
        var interpolatedFrames = 0
        var outputIndex = 0
        var motionObserved = false
        var diffSamples: [Double] = []
        var pixelEvidence: [MediaPixelEvidence] = []

        func checkCancellation() throws {
            try cancellation?.throwIfCancelled()
            if control.writer.status == .cancelled || control.reader.status == .cancelled { throw FloeError.cancelled }
        }

        func readNext() throws -> (buffer: CVPixelBuffer, pts: CMTime)? {
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
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric, pts.seconds.isFinite else {
                    throw FloeError.validationFailed("A decoded video frame has no usable timestamp")
                }
                return (pixelBuffer, pts)
            }
        }

        func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
            guard outputIndex < maximumFrames else { throw FloeError.validationFailed("Output frame bound exceeded") }
            while !videoInput.isReadyForMoreMediaData {
                try checkCancellation()
                guard writer.status == .writing else {
                    throw writer.error ?? FloeError.internalError("Video writer stopped accepting frames")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if pixelEvidence.count < 8 && (format.hdr || format.alpha) {
                pixelEvidence.append(try MediaPixelEvidence.capture(buffer, bridge: bridge))
            }
            let encodedBuffer: CVPixelBuffer
            if format.hdr {
                encodedBuffer = try store.makeBuffer(format: format.writerPixelFormat, width: outputWidth, height: outputHeight)
                CVBufferSetAttachment(encodedBuffer, kCVImageBufferColorPrimariesKey, format.primaries! as CFString, .shouldPropagate)
                CVBufferSetAttachment(encodedBuffer, kCVImageBufferTransferFunctionKey, format.transfer! as CFString, .shouldPropagate)
                CVBufferSetAttachment(encodedBuffer, kCVImageBufferYCbCrMatrixKey, (format.matrix ?? (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)) as CFString, .shouldPropagate)
                try bridge.render(source: buffer, destination: encodedBuffer, outputSpace: format.encodedSpace)
            } else {
                encodedBuffer = buffer
                if format.alpha { CVBufferSetAttachment(encodedBuffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate) }
            }
            try checkCancellation()
            guard adaptor.append(encodedBuffer, withPresentationTime: time) else {
                throw writer.error ?? FloeError.internalError("Video append failed at frame \(outputIndex)")
            }
            outputIndex += 1
        }

        func gridTime(_ index: Int) throws -> CMTime {
            CMTime(value: try clock.ticks(at: index), timescale: clock.numerator)
        }

        func upright(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
            let upright = try store.makeBuffer(format: format.workingPixelFormat,
                width: source.displayWidth, height: source.displayHeight)
            // Decode attachments describe the source color space; only after
            // normalization are RGB buffers interpreted in our working space.
            var image = CIImage(cvPixelBuffer: buffer)
            if exifOrientation != 1 { image = image.oriented(forExifOrientation: Int32(exifOrientation)) }
            try bridge.render(image: image, destination: upright)
            return upright
        }

        var current = try readNext()
        while let frame = current {
            try checkCancellation()
            sourceFrameCount += 1
            guard sourceFrameCount <= maximumFrames else { throw FloeError.validationFailed("Source frame bound exceeded") }
            let normalized = try upright(frame.buffer)
            let nextRaw = try readNext()
            if let nextRaw, CMTimeCompare(nextRaw.pts, frame.pts) <= 0 {
                throw FloeError.validationFailed("Decoded frame timestamps are not increasing")
            }
            let next = try nextRaw.map { try upright($0.buffer) }
            if let next, !format.hdr, diffSamples.count < 6 {
                let diff = try MediaModelReadiness.meanAbsoluteDifference(normalized, next)
                diffSamples.append(diff)
                if diff > 0.002 { motionObserved = true }
            }

            switch (engine, superResolutionEngine) {
            case (let engine?, nil):
                let end = nextRaw?.pts ?? CMTime(seconds: source.durationSeconds, preferredTimescale: 600_000)
                let assetEnd = CMTime(seconds: source.durationSeconds, preferredTimescale: 600_000)
                // The same output clock runs through every actual input PTS
                // interval. Source frames are emitted only when they lie on
                // that clock; 24->60 is not approximated by a fixed 3x loop.
                while CMTimeCompare(try gridTime(outputIndex), end) < 0,
                      CMTimeCompare(try gridTime(outputIndex), assetEnd) < 0 {
                    try checkCancellation()
                    let time = try gridTime(outputIndex)
                    if next == nil || CMTimeCompare(time, frame.pts) <= 0 {
                        // Hold the first/last available source across the
                        // bounded leading/trailing gap; never invent motion.
                        try append(normalized, at: time)
                        continue
                    }
                    let batchLimit = max(1, engine.interpolatedPerPair)
                    var batchPhases: [Float] = []
                    var batchTimes: [CMTime] = []
                    for offset in 0..<batchLimit {
                        let index = outputIndex + offset
                        let targetTime = try gridTime(index)
                        guard CMTimeCompare(targetTime, end) < 0,
                              CMTimeCompare(targetTime, assetEnd) < 0 else { break }
                        let phase = try clock.phase(at: index, sourcePTS: frame.pts.seconds,
                                                   nextPTS: nextRaw!.pts.seconds)
                        guard phase > 0, phase < 1 else {
                            throw FloeError.validationFailed("An interpolation phase fell outside its source pair")
                        }
                        batchPhases.append(min(Float(1).nextDown, max(Float.leastNonzeroMagnitude, Float(phase))))
                        batchTimes.append(targetTime)
                    }
                    let destinations = try batchTimes.map { _ in
                        try store.makeBuffer(format: format.workingPixelFormat, width: outputWidth, height: outputHeight)
                    }
                    guard !destinations.isEmpty, let next else {
                        throw FloeError.internalError("No source pair for an output clock sample")
                    }
                    let firstColor = format.alpha ? try bridge.opaqueColor(normalized, store: store) : normalized
                    let nextColor = format.alpha ? try bridge.opaqueColor(next, store: store) : next
                    try engine.interpolate(current: firstColor, next: nextColor, phases: batchPhases, outputs: destinations, cancellation: cancellation)
                    // An HDR-to-dark transition can legitimately lose the
                    // current frame's peak as phase approaches 1. Pixel-range
                    // preservation is verified against each SAME output frame
                    // before encoding and after reopening, never against an
                    // unrelated endpoint maximum.
                    for (index, destination) in destinations.enumerated() {
                        if format.alpha {
                            let composed = try store.makeBuffer(format: format.workingPixelFormat, width: outputWidth, height: outputHeight)
                            try bridge.restoreAlpha(color: destination, current: normalized, next: next,
                                                    phase: batchPhases[index], destination: composed)
                            try append(composed, at: batchTimes[index])
                        } else { try append(destination, at: batchTimes[index]) }
                        interpolatedFrames += 1
                    }
                }
            case (nil, let engine?):
                // Spatial enhancement does not retime VFR video.
                if CMTimeCompare(frame.pts, .zero) >= 0, frame.pts.seconds < source.durationSeconds {
                    let destination = try store.makeBuffer(format: format.workingPixelFormat,
                        width: outputWidth, height: outputHeight)
                    let color = format.alpha ? try bridge.opaqueColor(normalized, store: store) : normalized
                    try engine.scale(current: color, output: destination, cancellation: cancellation)
                    if format.hdr { try MediaPixelEvidence.requireRange(source: MediaPixelEvidence.capture(normalized, bridge: bridge), output: MediaPixelEvidence.capture(destination, bridge: bridge)) }
                    if format.alpha {
                        let composed = try store.makeBuffer(format: format.workingPixelFormat, width: outputWidth, height: outputHeight)
                        try bridge.restoreAlpha(color: destination, current: normalized, destination: composed)
                        try append(composed, at: frame.pts)
                    } else { try append(destination, at: frame.pts) }
                }
            default:
                throw FloeError.internalError("No enhancement engine is attached")
            }
            progress(MediaEnhancementProgress(phase: .processing, completedUnits: outputIndex,
                                              totalUnits: max(1, expectedOutputFrames)))
            current = nextRaw
        }
        guard outputIndex > 0 else { throw FloeError.validationFailed("No timed video frames were produced") }
        videoInput.markAsFinished()
        return VideoEnhancementOutcome(sourceFrameCount: sourceFrameCount,
            interpolatedFrames: interpolatedFrames, videoFinished: true, motionObserved: motionObserved, pixelEvidence: pixelEvidence)
    }

}

/// Small, deterministic pixel witness captured before encoding and compared
/// with the same frame after reopening. It detects flattened alpha and clipped
/// highlights; metadata by itself is never accepted as pixel preservation.
struct MediaPixelEvidence: Sendable {
    var maximumLinearRGB: Float
    var minimumAlpha: Float
    var maximumAlpha: Float

    static func capture(_ buffer: CVPixelBuffer, bridge: MediaImageBridge) throws -> Self {
        try capture(bridge.image(buffer), bridge: bridge)
    }

    static func capture(_ image: CIImage, bridge: MediaImageBridge) throws -> Self {
        let side = 16
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let small = normalized.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / image.extent.width,
                                                               y: CGFloat(side) / image.extent.height))
        var values = [Float](repeating: 0, count: side * side * 4)
        values.withUnsafeMutableBytes { bytes in
            bridge.cicontext.render(small, toBitmap: bytes.baseAddress!, rowBytes: side * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf, colorSpace: bridge.colorSpace)
        }
        guard values.allSatisfy(\.isFinite) else { throw FloeError.validationFailed("Output pixels contain non-finite values") }
        var result = Self(maximumLinearRGB: 0, minimumAlpha: 1, maximumAlpha: 0)
        for index in stride(from: 0, to: values.count, by: 4) {
            result.maximumLinearRGB = max(result.maximumLinearRGB, max(values[index], max(values[index + 1], values[index + 2])))
            result.minimumAlpha = min(result.minimumAlpha, values[index + 3])
            result.maximumAlpha = max(result.maximumAlpha, values[index + 3])
        }
        return result
    }

    static func requireRange(source: Self, output: Self) throws {
        if source.maximumLinearRGB > 1.1 {
            guard output.maximumLinearRGB > 1.02,
                  output.maximumLinearRGB >= source.maximumLinearRGB * 0.5 else {
                throw FloeError.validationFailed("HDR highlight range was clipped during processing or encoding")
            }
        }
    }

    func verify(reopened: Self, format: MediaEnhancementFormat) throws {
        if format.hdr { try Self.requireRange(source: self, output: reopened) }
        if format.alpha {
            guard abs(minimumAlpha - reopened.minimumAlpha) <= 0.10,
                  abs(maximumAlpha - reopened.maximumAlpha) <= 0.10 else {
                throw FloeError.validationFailed("The reopened output did not preserve its alpha plane")
            }
        }
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
        limits: MediaEnhancementService.Limits, format: MediaEnhancementFormat, evidence: [MediaPixelEvidence]
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
        if format.hdr || format.alpha {
            let inspected = try await MediaSourceInspector.inspect(url: staged)
            guard !format.hdr || (inspected.isHDR && (inspected.bitDepth ?? 0) >= 10 && inspected.colorPrimary == format.primaries && inspected.transferFunction == format.transfer) else {
                throw FloeError.validationFailed("Encoded HDR color information differs from the source")
            }
            guard !format.alpha || inspected.hasAlpha else { throw FloeError.validationFailed("Encoded output has no alpha channel") }
            let reader = try AVAssetReader(asset: asset)
            let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format.readerPixelFormat])
            guard reader.canAdd(decoded) else { throw FloeError.validationFailed("Cannot reopen the encoded precision/alpha format") }
            reader.add(decoded)
            guard reader.startReading() else { throw reader.error ?? FloeError.validationFailed("Cannot decode the encoded precision/alpha format") }
            defer { reader.cancelReading() }
            let bridge = MediaImageBridge(colorSpace: format.workingSpace)
            for expected in evidence {
                guard let sample = decoded.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw FloeError.validationFailed("Encoded output ended before pixel verification")
                }
                try expected.verify(reopened: MediaPixelEvidence.capture(buffer, bridge: bridge), format: format)
            }
            guard reader.status != .failed else { throw reader.error ?? FloeError.validationFailed("Pixel verification decode failed") }
            warnings.append("reopenedPixelSamples=\(evidence.count) precision=\(format.hdr ? "10bit-PQ/HLG" : "RGB8-alpha")")
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
        if expectInterpolatedFrames && !format.hdr {
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

    static func validateImage(staged: URL, expectedWidth: Int, expectedHeight: Int,
                              format: MediaEnhancementFormat, evidence: MediaPixelEvidence, bridge: MediaImageBridge) throws -> ImageValidation {
        guard let source = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw FloeError.validationFailed("Encoded image could not be reopened")
        }
        guard width == expectedWidth, height == expectedHeight else {
            throw FloeError.validationFailed("Encoded image is \(width)x\(height), expected \(expectedWidth)x\(expectedHeight)")
        }
        if format.alpha || format.hdr {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else { throw FloeError.validationFailed("Encoded image pixels cannot be reopened") }
            if format.alpha && !(properties[kCGImagePropertyHasAlpha] as? Bool ?? false) {
                throw FloeError.validationFailed("Encoded image lost its alpha channel")
            }
            if format.hdr && image.bitsPerComponent < 16 { throw FloeError.validationFailed("Encoded image lost its high precision") }
            try evidence.verify(reopened: MediaPixelEvidence.capture(CIImage(cgImage: image), bridge: bridge), format: format)
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

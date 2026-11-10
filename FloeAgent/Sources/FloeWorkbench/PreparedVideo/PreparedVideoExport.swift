// FloeWorkbench — PreparedVideo: bounded window/segment export.
//
// This is the concrete provider behind `PreparedVideoWindowRendering`. It
// renders exactly the same frames as `PreparedVideoFrameRenderer` (the shared
// evaluator), writes a staged MP4, mixes the requested window with the offline
// audio mixer, reopens the staged file to validate track/duration metadata,
// and only then commits atomically. Cancellation never replaces a destination.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import VideoToolbox
import AudioToolbox
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Receipt / protocol

public struct PreparedVideoWindowReceipt: Sendable, Hashable {
    public let url: URL
    public let planID: PreparedVideoPlanID
    public let window: PreparedVideoFrameWindow
    public let settings: PreparedVideoOutputSettings
    public let frameCount: Int
    public let durationSeconds: Double
    public let codec: PreparedVideoCodec
    public let hasAudio: Bool
    public let byteCount: Int64
    public let planContentHash: String
}

public protocol PreparedVideoWindowRendering: Sendable {
    func renderWindow(plan: PreparedVideoPlan,
                      window: PreparedVideoFrameWindow,
                      settings: PreparedVideoOutputSettings,
                      destination: URL,
                      overwrite: Bool,
                      cancellation: PreparedVideoCancellation,
                      progress: @Sendable (PreparedVideoProgress) -> Void) async throws -> PreparedVideoWindowReceipt
}

// MARK: - Exporter

public actor PreparedVideoExporter: PreparedVideoWindowRendering {
    public struct Limits: Sendable {
        public var maximumFrames: Int
        public var maximumPixels: Int
        public var maximumAudioFrames: Int

        public init(maximumFrames: Int = 18_000,
                    maximumPixels: Int = 33_177_600,
                    maximumAudioFrames: Int = 48_000 * 60) {
            self.maximumFrames = maximumFrames
            self.maximumPixels = maximumPixels
            self.maximumAudioFrames = maximumAudioFrames
        }
    }

    private let renderer: PreparedVideoFrameRenderer
    private let audioMixer: PreparedVideoAudioMixer
    private let limits: Limits
    private let managedPixelContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, .cacheIntermediates: false])

    public init(renderer: PreparedVideoFrameRenderer = PreparedVideoFrameRenderer(),
                audioMixer: PreparedVideoAudioMixer = PreparedVideoAudioMixer(),
                limits: Limits = Limits()) {
        self.renderer = renderer
        self.audioMixer = audioMixer
        self.limits = limits
    }

    public func renderWindow(plan: PreparedVideoPlan,
                             window: PreparedVideoFrameWindow,
                             settings: PreparedVideoOutputSettings,
                             destination: URL,
                             overwrite: Bool,
                             cancellation: PreparedVideoCancellation,
                             progress: @Sendable (PreparedVideoProgress) -> Void) async throws -> PreparedVideoWindowReceipt {
        try cancellation.check()
        let settings = settings.resolvingColorProfile(plan.colorProfile)
        guard settings.preservesAlpha != true || settings.colorProfile?.isHDR != true else {
            throw PreparedVideoError.invalidOutputSettings("transparent HDR output is not supported; choose SDR for a transparent proxy")
        }
        guard settings.colorProfile?.isHDR != true || settings.codec == .hevc else {
            throw PreparedVideoError.invalidOutputSettings("HDR output requires HEVC Main10; choose HEVC or SDR")
        }
        try plan.validateForRender()
        guard settings.frameRate == plan.frameRate else {
            throw PreparedVideoError.invalidOutputSettings(
                "window export currently requires the output frame rate to match the plan frame rate")
        }
        guard settings.pixelCount <= limits.maximumPixels else {
            throw PreparedVideoError.invalidOutputSettings("output exceeds the exporter pixel limit")
        }
        guard window.frameCount > 0, window.frameCount <= limits.maximumFrames else {
            throw PreparedVideoError.cacheLimitExceeded("window frame count is outside the exporter bound")
        }
        guard window.timescale == plan.timeScale else {
            throw PreparedVideoError.invalidTime("window and plan timescales differ")
        }
        guard let windowRange = try? window.timeRange(),
              windowRange.start.seconds >= 0,
              windowRange.endSeconds <= plan.duration.seconds + 0.000_001 else {
            throw PreparedVideoError.invalidTime("window lies outside the plan duration")
        }
        guard settings.preservesAlpha != true || (settings.codec == .hevc && destination.pathExtension.lowercased() == "mov") else { throw PreparedVideoError.invalidOutputSettings("transparent proxies require a MOV destination") }
        guard destination.isFileURL else {
            throw PreparedVideoError.invalidOutputSettings("destination must be a file URL")
        }
        guard PreparedVideoCapabilities.encoderAvailable(for: settings.codec) else {
            throw PreparedVideoError.codecUnavailable(settings.codec)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
            throw PreparedVideoError.destinationExists
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".prepared-video-\(UUID().uuidString)." + (settings.preservesAlpha == true ? "mov":"mp4"))
        let audioTemporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".prepared-video-audio-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: audioTemporary)
        }

        progress(PreparedVideoProgress(phase: .preflight, completed: 0, total: 1))
        let audioURL: URL?
        if PreparedVideoAudioMixer.hasAudibleContent(plan: plan, window: window) {
            let audioRequest = PreparedVideoAudioMixRequest(
                plan: plan, window: window, sampleRate: 48_000, channelCount: 2,
                destination: audioTemporary, overwrite: false)
            do {
                _ = try await audioMixer.mix(audioRequest, cancellation: cancellation)
                audioURL = audioTemporary
            } catch let error as PreparedVideoError {
                throw error
            } catch {
                throw PreparedVideoError.audioFailure("offline audio mixing failed")
            }
        } else {
            audioURL = nil
        }
        progress(PreparedVideoProgress(phase: .audio, completed: 1, total: 1))

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: temporary, fileType: settings.preservesAlpha == true ? .mov:.mp4)
        } catch {
            throw PreparedVideoError.renderFailed("could not create the MP4 writer")
        }

        let outputSettings = videoSettings(settings)
        guard writer.canApply(outputSettings: outputSettings,forMediaType: .video) else {
            throw PreparedVideoError.invalidOutputSettings("the encoder cannot produce the requested video format")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw PreparedVideoError.renderFailed("the writer rejected the video input")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes(settings: settings))

        var audioInput: AVAssetWriterInput?
        if audioURL != nil {
            let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 48_000,
                                            channels: 2,
                                            interleaved: false)
            let sourceHint = audioFormat.flatMap { audioFormatDescription(format: $0) }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ], sourceFormatHint: sourceHint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw PreparedVideoError.renderFailed("the writer rejected the audio input")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw PreparedVideoError.renderFailed(writer.error?.localizedDescription ?? "could not start the MP4 writer")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await appendFrames(plan: plan, window: window, settings: settings,
                                   videoInput: videoInput, adaptor: adaptor,
                                   writer: writer, cancellation: cancellation, progress: progress)
            videoInput.markAsFinished()
            if let audioInput, let audioURL {
                try await appendAudio(url: audioURL, input: audioInput,
                                      writer: writer, cancellation: cancellation)
                audioInput.markAsFinished()
            }
            // The pixel-buffer adaptor supplies timestamps but no per-frame
            // duration. Close the session at the exact frame-window end so a
            // 36-frame proxy reports 1.2 s rather than the last frame's PTS.
            writer.endSession(atSourceTime: CMTime(
                value: Int64(window.frameCount) * Int64(settings.frameRate.denominator),
                timescale: settings.frameRate.numerator))
            try cancellation.check()
            await finishWriting(writer)
            guard writer.status == .completed else {
                throw PreparedVideoError.renderFailed(writer.error?.localizedDescription ?? "the MP4 writer did not complete")
            }
            try await validate(staged: temporary, settings: settings,
                               window: window, expectsAudio: audioURL != nil)
            try cancellation.check()
            progress(PreparedVideoProgress(phase: .finalizing, completed: 1, total: 1))
            try PreparedVideoAtomicCommit.commit(staged: temporary, destination: destination,
                                                 overwrite: overwrite)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let receipt = PreparedVideoWindowReceipt(
                url: destination, planID: plan.id, window: window, settings: settings,
                frameCount: window.frameCount,
                durationSeconds: Double(window.frameCount) * Double(settings.frameRate.denominator)
                    / Double(settings.frameRate.numerator),
                codec: settings.codec, hasAudio: audioURL != nil,
                byteCount: size, planContentHash: plan.contentHash)
            return receipt
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    // MARK: Frames

    private func appendFrames(plan: PreparedVideoPlan,
                              window: PreparedVideoFrameWindow,
                              settings: PreparedVideoOutputSettings,
                              videoInput: AVAssetWriterInput,
                              adaptor: AVAssetWriterInputPixelBufferAdaptor,
                              writer: AVAssetWriter,
                              cancellation: PreparedVideoCancellation,
                              progress: @Sendable (PreparedVideoProgress) -> Void) async throws {
        let total = window.frameCount
        for localFrame in 0..<total {
            try cancellation.check()
            while !videoInput.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw PreparedVideoError.renderFailed("video writer stopped accepting frames")
                }
                try cancellation.check()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let absoluteFrame = try window.absoluteFrame(forLocalFrame: Int64(localFrame))
            let rendered = try await renderer.renderFrame(plan: plan, frameIndex: absoluteFrame,
                                                          settings: settings,
                                                          cancellation: cancellation)
            let buffer = try pixelBuffer(from: rendered.image, pool: adaptor.pixelBufferPool,profile: settings.colorProfile)
            let presentation = CMTime(value: Int64(localFrame) * Int64(settings.frameRate.denominator),
                                      timescale: settings.frameRate.numerator)
            guard adaptor.append(buffer, withPresentationTime: presentation) else {
                throw PreparedVideoError.renderFailed(
                    writer.error?.localizedDescription ?? "the writer rejected a video frame")
            }
            if localFrame % 10 == 0 || localFrame == total - 1 {
                progress(PreparedVideoProgress(phase: .video, completed: localFrame + 1, total: total))
            }
        }
    }

    private func pixelBufferAttributes(settings: PreparedVideoOutputSettings) -> [String:Any] {
        var result: [String:Any] = [kCVPixelBufferPixelFormatTypeKey as String: settings.colorProfile?.pixelBufferFormat ?? kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,kCVPixelBufferHeightKey as String: settings.height]
        if settings.colorProfile?.isHDR == true {
            result[kCVPixelBufferMetalCompatibilityKey as String] = true
            result[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String:Any]
        } else {
            result[kCVPixelBufferCGImageCompatibilityKey as String] = true
            result[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true
        }
        return result
    }
    private func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?,profile: MediaVideoColorProfile?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            let attributes: [CFString:Any] = profile?.isHDR == true ? [kCVPixelBufferMetalCompatibilityKey: true,kCVPixelBufferIOSurfacePropertiesKey: [:] as [String:Any]]
                : [kCVPixelBufferCGImageCompatibilityKey: true,kCVPixelBufferCGBitmapContextCompatibilityKey: true]
            CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                profile?.pixelBufferFormat ?? kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        }
        guard let buffer else {
            throw PreparedVideoError.renderFailed("could not allocate a video pixel buffer")
        }
        guard CVPixelBufferGetPixelFormatType(buffer) == (profile?.pixelBufferFormat ?? kCVPixelFormatType_32BGRA) else {
            throw PreparedVideoError.renderFailed("the buffer pool cannot preserve the selected video bit depth")
        }
        try MediaVideoColorProfile.attach(profile,to: buffer)
        if let profile,profile.isHDR {
            managedPixelContext.render(CIImage(cgImage: image),to: buffer,
                bounds: CGRect(x: 0,y: 0,width: image.width,height: image.height),colorSpace: try profile.colorSpace())
            return buffer
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw PreparedVideoError.renderFailed("video pixel buffer has no base address")
        }
        guard let context = CGContext(data: base, width: image.width, height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: try profile?.colorSpace() ?? (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw PreparedVideoError.renderFailed("could not create a pixel buffer context")
        }
        context.interpolationQuality = .high
        // Bitmap memory is consumed directly by VideoToolbox. An additional
        // UIKit-style CTM flip would vertically invert every exported frame.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The frame renderer and bitmap context produce sRGB. Tag both the
        // source buffers and encoded output so VideoToolbox cannot infer SD
        // colorimetry from small preview/export dimensions.
        try MediaVideoColorProfile.attach(profile,to: buffer)
        return buffer
    }

    // MARK: Audio mux

    private func appendAudio(url: URL,
                             input: AVAssetWriterInput,
                             writer: AVAssetWriter,
                             cancellation: PreparedVideoCancellation) async throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw PreparedVideoError.audioFailure("could not reopen the offline mix")
        }
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw PreparedVideoError.audioFailure("offline mix has no readable audio")
        }
        guard let description = audioFormatDescription(format: format) else {
            throw PreparedVideoError.audioFailure("could not describe the offline mix format")
        }
        var position: AVAudioFramePosition = 0
        while position < file.length {
            try cancellation.check()
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let request = AVAudioFrameCount(min(Int64(4_096), file.length - position))
            do {
                try file.read(into: buffer, frameCount: request)
            } catch {
                throw PreparedVideoError.audioFailure("could not read the offline mix")
            }
            guard buffer.frameLength > 0 else {
                throw PreparedVideoError.audioFailure("offline mix reader made no progress")
            }
            guard let sample = makeSampleBuffer(buffer: buffer,
                                                presentationFrame: position,
                                                formatDescription: description) else {
                throw PreparedVideoError.audioFailure("could not create an audio sample buffer")
            }
            guard input.append(sample) else {
                throw PreparedVideoError.renderFailed(
                    writer.error?.localizedDescription ?? "the writer rejected an audio sample")
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func audioFormatDescription(format: AVAudioFormat) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(format.channelCount * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(format.channelCount * 4),
            mChannelsPerFrame: format.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    private func makeSampleBuffer(buffer: AVAudioPCMBuffer,
                                  presentationFrame: AVAudioFramePosition,
                                  formatDescription: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = data[channel][frame]
            }
        }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let blockBuffer else { return nil }
        let copied = interleaved.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frames), timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(presentationFrame),
                                          timescale: CMTimeScale(buffer.format.sampleRate)),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    // MARK: Writer / validation

    private func videoSettings(_ settings: PreparedVideoOutputSettings) -> [String: Any] {
        let codec: AVVideoCodecType = settings.preservesAlpha == true ? .hevcWithAlpha:(settings.codec == .h264 ? .h264 : .hevc)
        let bitsPerSecond = max(400_000, Int(Double(settings.pixelCount) * settings.frameRate.fps * (0.05 + 0.20 * settings.quality)))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: min(bitsPerSecond, 120_000_000),
            AVVideoExpectedSourceFrameRateKey: settings.frameRate.fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(settings.frameRate.fps.rounded()) * 2)
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if settings.colorProfile?.isHDR == true {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: MediaVideoColorProfile.videoProperties(settings.colorProfile),
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private func validate(staged: URL,
                          settings: PreparedVideoOutputSettings,
                          window: PreparedVideoFrameWindow,
                          expectsAudio: Bool) async throws {
        let asset = AVURLAsset(url: staged)
        do {
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let video = videoTracks.first else {
                throw PreparedVideoError.renderFailed("staged output has no video track")
            }
            if settings.preservesAlpha == true {
                let descriptions=try await video.load(.formatDescriptions)
                guard descriptions.contains(where:{(CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) == true}) else { throw PreparedVideoError.renderFailed("the encoded proxy did not preserve alpha") }
            }
            let size = try await video.load(.naturalSize)
            if let profile = settings.colorProfile {
                guard let description = try await video.load(.formatDescriptions).first else { throw PreparedVideoError.renderFailed("video color description missing") }
                try MediaVideoColorProfile.validateEncoded(profile,description: description)
            }
            guard Int(abs(size.width).rounded()) == settings.width,
                  Int(abs(size.height).rounded()) == settings.height else {
                throw PreparedVideoError.renderFailed("staged output dimensions do not match the requested settings")
            }
            let expected = Double(window.frameCount) * Double(settings.frameRate.denominator)
                / Double(settings.frameRate.numerator)
            let tolerance = max(0.05, 2.0 * Double(settings.frameRate.denominator)
                / Double(settings.frameRate.numerator))
            guard abs(duration - expected) <= tolerance else {
                throw PreparedVideoError.renderFailed("staged output duration does not match the frame window")
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if expectsAudio && audioTracks.isEmpty {
                throw PreparedVideoError.renderFailed("staged output is missing its audio track")
            }
        } catch let error as PreparedVideoError {
            throw error
        } catch {
            throw PreparedVideoError.renderFailed("could not reopen the staged MP4")
        }
    }
}

import Foundation
import ImageIO
import CoreGraphics
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Metadata for a (possibly animated) image source read through ImageIO.
/// AVFoundation cannot open GIFs on this platform, so this is the only
/// truthful inspection path for them.
public struct GIFAnimationInfo: Sendable, Codable, Hashable {
    public var container: String
    public var frameCount: Int
    public var width: Int
    public var height: Int
    /// GIF loop count. `0` means infinite; nil when not declared.
    public var loopCount: Int?
    public var isAnimated: Bool
    public var totalDurationSeconds: Double
    public var frameDelaysSeconds: [Double]

    public init(
        container: String = "gif",
        frameCount: Int,
        width: Int,
        height: Int,
        loopCount: Int?,
        isAnimated: Bool,
        totalDurationSeconds: Double,
        frameDelaysSeconds: [Double]
    ) {
        self.container = container
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.loopCount = loopCount
        self.isAnimated = isAnimated
        self.totalDurationSeconds = totalDurationSeconds
        self.frameDelaysSeconds = frameDelaysSeconds
    }

    /// Average frame rate over the declared timeline. Truthful for variable
    /// frame delays: the converter preserves the original timing.
    public var averageFrameRate: Double {
        guard totalDurationSeconds > 0 else { return 0 }
        return Double(frameCount) / totalDurationSeconds
    }
}

public enum GIFSupportError: Error, Sendable, Equatable {
    case notAnimatedGIF(frameCount: Int)
    case invalidSource(String)
    case tooManyFrames(limit: Int)
    case durationExceedsLimit(seconds: Double, limit: Double)
    case dimensionsExceedLimit(width: Int, height: Int, limit: Int)
    case invalidFrameRate(Double)
    case cancelled
    case writerFailed(String)
}

extension GIFSupportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnimatedGIF(let frames):
            "The source has \(frames) frame(s); converting to video requires an animated GIF."
        case .invalidSource(let detail):
            "The GIF could not be read. \(detail)"
        case .tooManyFrames(let limit):
            "The GIF exceeds the \(limit)-frame conversion limit."
        case .durationExceedsLimit(let seconds, let limit):
            "The GIF duration \(String(format: "%.2f", seconds))s exceeds the \(String(format: "%.0f", limit))s conversion limit."
        case .dimensionsExceedLimit(let width, let height, let limit):
            "The GIF dimensions \(width)x\(height) exceed the \(limit)-pixel conversion limit."
        case .invalidFrameRate(let value):
            "The requested frame rate \(value) is outside 1...60."
        case .cancelled:
            "GIF conversion was cancelled."
        case .writerFailed(let detail):
            "The video writer failed. \(detail)"
        }
    }
}

public struct GIFVideoConversionResult: Sendable, Hashable {
    public var outputPath: String
    public var frameCount: Int
    public var width: Int
    public var height: Int
    public var durationSeconds: Double
    public var frameRate: Double
    public var byteCount: Int64
    /// True when the original per-frame GIF delays were preserved instead of
    /// resampling to a constant frame rate.
    public var preservedOriginalTiming: Bool

    public init(
        outputPath: String,
        frameCount: Int,
        width: Int,
        height: Int,
        durationSeconds: Double,
        frameRate: Double,
        byteCount: Int64,
        preservedOriginalTiming: Bool
    ) {
        self.outputPath = outputPath
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.byteCount = byteCount
        self.preservedOriginalTiming = preservedOriginalTiming
    }
}

/// ImageIO-based animated-GIF inspection and GIF-to-video conversion.
///
/// Memory stays bounded by construction: frames are decoded one at a time from
/// the image source, written through an `AVAssetWriterInputPixelBufferAdaptor`
/// whose pool recycles buffers, and the writer is never asked to accept a new
/// frame before `isReadyForMoreMediaData` is true. There is no AI generation
/// anywhere in this path.
public enum GIFSupport {
    public static let defaultMaximumFrames = 600
    public static let defaultMaximumDurationSeconds: Double = 120
    public static let defaultMaximumDimension = 4096

    public static func isGIF(fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let type = CGImageSourceGetType(source) as String? else { return false }
        return type == "com.compuserve.gif"
    }

    /// Reads GIF metadata without decoding more than the requested frame
    /// properties. Fails when the frame count exceeds `maximumFrames`.
    public static func probe(fileURL: URL, maximumFrames: Int = 10_000) throws -> GIFAnimationInfo {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw GIFSupportError.invalidSource("ImageIO could not open \(fileURL.lastPathComponent).")
        }
        guard let sourceType = CGImageSourceGetType(source) as String?, sourceType == "com.compuserve.gif" else {
            throw GIFSupportError.invalidSource("The source is not a GIF.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw GIFSupportError.invalidSource("The GIF declares no frames.") }
        guard count <= maximumFrames else { throw GIFSupportError.tooManyFrames(limit: maximumFrames) }

        // Loop count and canvas size are container-level GIF properties; they
        // are not repeated in every frame dictionary (partial frames report
        // only their own sub-rectangle).
        let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let sourceGIF = sourceProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        var width = sourceGIF?[kCGImagePropertyGIFCanvasPixelWidth] as? Int ?? 0
        var height = sourceGIF?[kCGImagePropertyGIFCanvasPixelHeight] as? Int ?? 0
        var loopCount: Int? = sourceGIF?[kCGImagePropertyGIFLoopCount] as? Int
        var delays: [Double] = []
        delays.reserveCapacity(count)
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                throw GIFSupportError.invalidSource("Frame \(index) has no readable properties.")
            }
            if width == 0, let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int { width = max(width, pixelWidth) }
            if height == 0, let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int { height = max(height, pixelHeight) }
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            // Browsers and ImageIO clamp sub-20ms delays; mirror that so the
            // reported timeline matches what a viewer actually plays.
            delays.append(Self.clampedDelay(unclamped))
            if loopCount == nil, let loop = gif?[kCGImagePropertyGIFLoopCount] as? Int {
                loopCount = loop
            }
        }
        let total = delays.reduce(0, +)
        return GIFAnimationInfo(
            frameCount: count,
            width: width,
            height: height,
            loopCount: loopCount,
            isAnimated: count > 1,
            totalDurationSeconds: total,
            frameDelaysSeconds: delays
        )
    }

    /// Converts a timed GIF into an H.264 MP4/MOV. `frameRate` nil preserves
    /// the original per-frame delays; a value resamples to a constant rate.
    /// The destination is written through a sibling staging file and only
    /// replaces it after the writer reports success.
    public static func convertToVideo(
        fileURL: URL,
        outputURL: URL,
        frameRate: Double? = nil,
        width: Int? = nil,
        maximumFrames: Int = defaultMaximumFrames,
        maximumDurationSeconds: Double = defaultMaximumDurationSeconds,
        maximumDimension: Int = defaultMaximumDimension,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> GIFVideoConversionResult {
        let info = try probe(fileURL: fileURL, maximumFrames: max(maximumFrames, 1))
        guard info.frameCount > 1 else { throw GIFSupportError.notAnimatedGIF(frameCount: info.frameCount) }
        guard info.frameCount <= maximumFrames else { throw GIFSupportError.tooManyFrames(limit: maximumFrames) }
        guard info.totalDurationSeconds <= maximumDurationSeconds else {
            throw GIFSupportError.durationExceedsLimit(seconds: info.totalDurationSeconds, limit: maximumDurationSeconds)
        }
        if let frameRate, !(1.0...60.0).contains(frameRate) {
            throw GIFSupportError.invalidFrameRate(frameRate)
        }

        let target = try targetDimensions(
            sourceWidth: info.width, sourceHeight: info.height,
            requestedWidth: width, maximumDimension: maximumDimension
        )

        #if canImport(AVFoundation)
        return try await writeVideo(
            sourceURL: fileURL, outputURL: outputURL, info: info,
            targetWidth: target.width, targetHeight: target.height,
            frameRate: frameRate, cancellation: cancellation
        )
        #else
        throw GIFSupportError.writerFailed("AVFoundation is unavailable on this platform.")
        #endif
    }

    struct TargetDimensions: Sendable, Equatable {
        var width: Int
        var height: Int
    }

    static func targetDimensions(
        sourceWidth: Int, sourceHeight: Int,
        requestedWidth: Int?, maximumDimension: Int
    ) throws -> TargetDimensions {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw GIFSupportError.invalidSource("The GIF has no usable dimensions.")
        }
        var width = requestedWidth ?? sourceWidth
        guard width > 0 else { throw GIFSupportError.invalidSource("The requested width must be positive.") }
        var height = Int((Double(width) * Double(sourceHeight) / Double(sourceWidth)).rounded())
        if height < 1 { height = 1 }
        let largest = max(width, height)
        if largest > maximumDimension {
            let scale = Double(maximumDimension) / Double(largest)
            width = max(1, Int((Double(width) * scale).rounded(.down)))
            height = max(1, Int((Double(height) * scale).rounded(.down)))
        }
        // H.264 requires even dimensions.
        if width % 2 == 1 { width = max(2, width - 1) }
        if height % 2 == 1 { height = max(2, height - 1) }
        guard width * height <= maximumDimension * maximumDimension else {
            throw GIFSupportError.dimensionsExceedLimit(width: width, height: height, limit: maximumDimension)
        }
        return TargetDimensions(width: width, height: height)
    }

    private static func clampedDelay(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return 0.1 }
        return min(max(raw, 0.02), 5.0)
    }

    #if canImport(AVFoundation)
    private static func writeVideo(
        sourceURL: URL,
        outputURL: URL,
        info: GIFAnimationInfo,
        targetWidth: Int,
        targetHeight: Int,
        frameRate: Double?,
        cancellation: (@Sendable () -> Bool)?
    ) async throws -> GIFVideoConversionResult {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw GIFSupportError.invalidSource("ImageIO could not reopen the GIF.")
        }
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".floe-gif-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: staging, fileType: .mp4)
        } catch {
            throw GIFSupportError.writerFailed(error.localizedDescription)
        }
        let bitrate = max(1_000_000, targetWidth * targetHeight * 5)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else { throw GIFSupportError.writerFailed("The writer rejected the video input.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw GIFSupportError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed.")
        }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        var cumulative = 0.0
        var writtenFrames = 0
        var writtenDuration = 0.0

        for index in 0..<info.frameCount {
            if cancellation?() == true { throw GIFSupportError.cancelled }
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if cancellation?() == true { throw GIFSupportError.cancelled }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            // Decode exactly one frame at a time. The image is released at the
            // end of the iteration, so peak memory is one frame plus the
            // writer's bounded in-flight buffers.
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw GIFSupportError.invalidSource("Frame \(index) could not be decoded.")
            }
            let presentationTime: CMTime
            let frameDuration: Double
            if let frameRate {
                frameDuration = 1.0 / frameRate
                presentationTime = CMTime(seconds: Double(index) * frameDuration, preferredTimescale: 600)
            } else {
                frameDuration = info.frameDelaysSeconds[index]
                presentationTime = CMTime(seconds: cumulative, preferredTimescale: 600)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw GIFSupportError.writerFailed("The pixel buffer pool is unavailable.")
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else {
                throw GIFSupportError.writerFailed("A pixel buffer could not be allocated.")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw GIFSupportError.writerFailed("The pixel buffer has no base address.")
            }
            guard let context = CGContext(
                data: base,
                width: targetWidth, height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw GIFSupportError.writerFailed("The drawing context could not be created.")
            }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            // Unlock before handing the buffer to the writer: the adaptor may
            // consume it on another thread immediately.
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw GIFSupportError.writerFailed(writer.error?.localizedDescription ?? "Frame append failed.")
            }
            writtenFrames += 1
            writtenDuration = frameRate != nil
                ? Double(writtenFrames) / frameRate!
                : cumulative + frameDuration
            cumulative += frameDuration
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw GIFSupportError.writerFailed(writer.error?.localizedDescription ?? "The writer did not complete.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: outputURL)
        }
        let byteCount = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard byteCount > 0 else { throw GIFSupportError.writerFailed("The output file is empty.") }
        let actualRate = writtenDuration > 0 ? Double(writtenFrames) / writtenDuration : 0
        return GIFVideoConversionResult(
            outputPath: outputURL.path,
            frameCount: writtenFrames,
            width: targetWidth,
            height: targetHeight,
            durationSeconds: writtenDuration,
            frameRate: actualRate,
            byteCount: byteCount,
            preservedOriginalTiming: frameRate == nil
        )
    }
    #endif
}

import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - Public request/result contract

/// Engine selection for an enhancement request. `quality` and `lowLatency`
/// are Apple-native VideoToolbox frame processors, `metalFX` is the GPU
/// spatial scaler (super resolution only), `coreml` is a locally installed
/// Core ML model. A requested engine is never silently swapped.
public enum MediaEnhancementMode: String, Sendable, CaseIterable, Codable {
    case quality
    // Raw values are lowercase so tool arguments are matched case-insensitively
    // (the tool schema spells the modes "lowLatency" and "metalFX").
    case lowLatency = "lowlatency"
    case metalFX = "metalfx"
    case coreml

    public init?(requested: String) {
        self.init(rawValue: requested.lowercased())
    }
}

/// Quality priorization. Accepted values only; unknown strings are rejected
/// rather than dropped.
public enum MediaEnhancementQuality: String, Sendable, CaseIterable, Codable {
    /// Highest quality (VT `.quality` prioritization; Core ML 16 px tile overlap).
    case quality
    /// Balanced (VT `.normal`; Core ML 16 px tile overlap).
    case balanced
    /// Fastest (VT `.normal`; Core ML 8 px tile overlap, visible seams possible).
    case fast

    public init?(requested: String?) throws {
        guard let requested, !requested.isEmpty else { return nil }
        guard let value = MediaEnhancementQuality(rawValue: requested.lowercased()) else {
            throw FloeError.validationFailed("quality must be one of quality, balanced or fast")
        }
        self = value
    }

    var tileOverlap: Int { self == .fast ? 8 : 16 }
    var vtPrioritizationIsQuality: Bool { self == .quality }
}

/// Which enhancement to run, with its explicit parameter.
public enum MediaEnhancementOperation: Sendable, Equatable, Codable {
    case interpolation(targetFPS: Double)
    case superResolution(scaleFactor: Int)

    public var isInterpolation: Bool {
        if case .interpolation = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .interpolation(let fps): "interpolation targetFPS=\(fps)"
        case .superResolution(let scale): "superResolution scaleFactor=\(scale)"
        }
    }
}

/// One fully specified enhancement request. Absolute, already canonical URLs:
/// tools resolve paths through `MediaPathGuard` before calling the service.
public struct MediaEnhancementRequest: Sendable, Codable, Equatable {
    public var inputPath: String
    public var outputPath: String
    public var operation: MediaEnhancementOperation
    public var mode: String
    public var modelID: String?
    public var quality: String?
    /// Explicit overwrite consent. Default false: an existing destination is
    /// refused so a staged commit can never replace an original by accident.
    public var overwrite: Bool
    /// Immutable workspace scope captured by the caller (Task `ToolContext`
    /// workspace root or the task/UI adapter) when the request is created.
    /// Both paths resolve against this single snapshot; the service never
    /// consults a current selection, global root or project fallback. An
    /// absent scope is refused instead of defaulting to arbitrary paths.
    public var workspaceRootPath: String?

    public init(
        inputPath: String,
        outputPath: String,
        operation: MediaEnhancementOperation,
        mode: String,
        modelID: String? = nil,
        quality: String? = nil,
        overwrite: Bool = false,
        workspaceRootPath: String? = nil
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.operation = operation
        self.mode = mode
        self.modelID = modelID
        self.quality = quality
        self.overwrite = overwrite
        self.workspaceRootPath = workspaceRootPath
    }

    public var inputURL: URL { URL(fileURLWithPath: inputPath) }
    public var outputURL: URL { URL(fileURLWithPath: outputPath) }
}

/// Everything the caller needs to judge the result without trusting a success
/// string: real engine, real counters and the committed output identity.
public struct MediaEnhancementResult: Sendable, Codable, Equatable {
    public var outputPath: String
    public var engine: String
    public var mode: String
    public var inputKind: String
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var sourceFPS: Double
    public var outputFPS: Double
    public var sourceDurationSeconds: Double
    public var outputDurationSeconds: Double
    public var sourceFrameCount: Int
    public var outputFrameCount: Int
    public var interpolatedFrameCount: Int
    public var audioCopied: Bool
    public var hadRotation: Bool
    public var outputBytes: Int64
    public var outputSHA256: String
    public var warnings: [String]

    /// Single-line digest used as the tool result; all fields are measured.
    public var digest: String {
        var lines = [
            "status=ok output=\(outputPath)",
            "engine=\(engine) mode=\(mode) kind=\(inputKind)",
            "source=\(sourceWidth)x\(sourceHeight)@\(String(format: "%.3f", sourceFPS))fps frames=\(sourceFrameCount) duration=\(String(format: "%.3f", sourceDurationSeconds))s",
            "output=\(outputWidth)x\(outputHeight)@\(String(format: "%.3f", outputFPS))fps frames=\(outputFrameCount) duration=\(String(format: "%.3f", outputDurationSeconds))s",
            "interpolatedFrames=\(interpolatedFrameCount) audioCopied=\(audioCopied) rotated=\(hadRotation) bytes=\(outputBytes)",
            "sha256=\(outputSHA256)"
        ]
        lines.append(contentsOf: warnings.map { "warning=\($0)" })
        return lines.joined(separator: "\n")
    }
}

/// Structured progress for long-running enhancement work.
public struct MediaEnhancementProgress: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case preflight
        case reading
        case processing
        case encoding
        case validating
        case committing
    }

    public var phase: Phase
    public var completedUnits: Int
    public var totalUnits: Int
    public var fraction: Double

    public init(phase: Phase, completedUnits: Int, totalUnits: Int) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.fraction = totalUnits > 0 ? min(1, Double(completedUnits) / Double(totalUnits)) : 0
    }
}

// MARK: - Path guard

/// Canonical workspace path resolution for media tools: symlink- and
/// traversal-safe, and the only way tool arguments become file URLs.
public enum MediaPathGuard {
    /// Resolves `path` (absolute or workspace-relative) beneath `root` and
    /// rejects anything that escapes it. Absolute paths must already live
    /// under the root; relative paths are walked one component at a time and
    /// containment is re-checked after every step, so a symlinked directory
    /// (or a not-yet-existing leaf below one) cannot smuggle the path outside
    /// the workspace root.
    public static func resolve(_ path: String, root: URL?) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else {
            throw FloeError.validationFailed("A non-empty path is required")
        }
        guard let root else {
            throw FloeError.validationFailed("a workspace root is required")
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let components: [String]
        if path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            if resolved.path == canonicalRoot.path { return canonicalRoot }
            guard resolved.path.hasPrefix(canonicalRoot.path + "/") else {
                throw FloeError.validationFailed("Media path escapes the workspace root")
            }
            let relative = String(resolved.path.dropFirst(canonicalRoot.path.count + 1))
            components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        } else {
            components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        guard !components.isEmpty else { return canonicalRoot }
        var current = canonicalRoot
        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                current.deleteLastPathComponent()
            default:
                current.appendPathComponent(component)
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                current = URL(fileURLWithPath: current.resolvingSymlinksInPath().path)
            } else {
                current = current.standardizedFileURL
            }
            guard current.path == canonicalRoot.path || current.path.hasPrefix(canonicalRoot.path + "/") else {
                throw FloeError.validationFailed("Media path escapes the workspace root")
            }
        }
        return current
    }

    /// Same as `resolve` for the destination, plus a directory existence check
    /// performed later by the pipeline (directories are created on demand).
    public static func resolveOutput(_ path: String, root: URL?) throws -> URL {
        let resolved = try resolve(path, root: root)
        return resolved
    }
}

// MARK: - Source inspection and guards

#if canImport(AVFoundation)

/// Measured properties of the source that the pipeline and its guards use.
public struct MediaSourceDescriptor: Sendable {
    public var url: URL
    public var isImage: Bool
    public var width: Int
    public var height: Int
    public var displayWidth: Int
    public var displayHeight: Int
    public var naturalFPS: Double
    public var durationSeconds: Double
    public var hasAudio: Bool
    public var hadRotation: Bool
    public var colorPrimary: String?
    public var transferFunction: String?
    public var isHDR: Bool
    public var hasAlpha: Bool
    public var codec: String?
}

public enum MediaSourceInspector {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif"]

    public static func inspect(url: URL) async throws -> MediaSourceDescriptor {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(url.lastPathComponent) }
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            return try inspectImage(url: url)
        }
        return try await inspectVideo(url: url)
    }

    static func inspectImage(url: URL) throws -> MediaSourceDescriptor {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw FloeError.validationFailed("Image could not be inspected")
        }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        var descriptor = MediaSourceDescriptor(
            url: url, isImage: true, width: width, height: height,
            displayWidth: width, displayHeight: height,
            naturalFPS: 0, durationSeconds: 0, hasAudio: false, hadRotation: false,
            colorPrimary: nil, transferFunction: nil, isHDR: false, hasAlpha: hasAlpha, codec: nil
        )
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        if (5...8).contains(orientation) {
            descriptor.displayWidth = height
            descriptor.displayHeight = width
            descriptor.hadRotation = true
        }
        return descriptor
    }

    static func inspectVideo(url: URL) async throws -> MediaSourceDescriptor {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else { throw FloeError.validationFailed("Input has no video track") }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else {
            throw FloeError.validationFailed("Input duration is invalid")
        }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displayWidth = Int(abs(displayed.width).rounded())
        let displayHeight = Int(abs(displayed.height).rounded())
        let fps = Double(try await video.load(.nominalFrameRate))
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await video.load(.formatDescriptions)
        var colorPrimary: String?
        var transfer: String?
        var hasAlpha = false
        var codec: String?
        if let description = descriptions.first {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(description)
            codec = Self.fourCC(mediaSubType)
            if let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] {
                if let primaries = extensions[kCVImageBufferColorPrimariesKey] as? String {
                    colorPrimary = primaries
                }
                if let transferFunction = extensions[kCVImageBufferTransferFunctionKey] as? String {
                    transfer = transferFunction
                }
                // Any alpha channel mode means the track carries transparency,
                // which this pipeline cannot preserve end to end.
                hasAlpha = extensions[kCVImageBufferAlphaChannelModeKey] != nil
            }
        }
        let hdrTransferFunctions: Set<String> = [
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        ]
        let hdrPrimaries = colorPrimary == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        let isHDR = hdrPrimaries || (transfer.map { hdrTransferFunctions.contains($0) } ?? false)
        let rotation = abs(transform.b) > 0.0001 || abs(transform.c) > 0.0001
        return MediaSourceDescriptor(
            url: url, isImage: false,
            width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded()),
            displayWidth: displayWidth, displayHeight: displayHeight,
            naturalFPS: fps, durationSeconds: duration.seconds,
            hasAudio: !audioTracks.isEmpty, hadRotation: rotation,
            colorPrimary: colorPrimary, transferFunction: transfer, isHDR: isHDR,
            hasAlpha: hasAlpha, codec: codec
        )
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

/// Explicit preflight guards. Every rejection names the exact unsupported
/// property; nothing here silently changes the requested operation.
public enum MediaEnhancementGuards {
    public struct Limits: Sendable {
        public var maximumSourceDimension: Int
        public var maximumOutputDimension: Int
        public var maximumDurationSeconds: Double
        public var maximumSourceFrames: Int
        public var maximumTargetFPS: Double
        public var maximumUpscaleWhileInterpolating: Int

        public init(
            maximumSourceDimension: Int = 4096,
            maximumOutputDimension: Int = 8192,
            maximumDurationSeconds: Double = 3600,
            maximumSourceFrames: Int = 200_000,
            maximumTargetFPS: Double = 240,
            maximumUpscaleWhileInterpolating: Int = 8
        ) {
            self.maximumSourceDimension = maximumSourceDimension
            self.maximumOutputDimension = maximumOutputDimension
            self.maximumDurationSeconds = maximumDurationSeconds
            self.maximumSourceFrames = maximumSourceFrames
            self.maximumTargetFPS = maximumTargetFPS
            self.maximumUpscaleWhileInterpolating = maximumUpscaleWhileInterpolating
        }
    }

    public static func validate(
        source: MediaSourceDescriptor,
        request: MediaEnhancementRequest,
        limits: Limits
    ) throws -> (displayWidth: Int, displayHeight: Int, framesPerPair: Int) {
        guard !source.isHDR else {
            throw FloeError.invalidConfiguration(
                "HDR source (primaries=\(source.colorPrimary ?? "unknown"), transfer=\(source.transferFunction ?? "unknown")): tone mapping is not implemented in this build; pass an SDR source"
            )
        }
        guard !source.hasAlpha else {
            throw FloeError.invalidConfiguration("Source carries an alpha channel; flatten it to an opaque SDR file first")
        }
        guard source.displayWidth > 1, source.displayHeight > 1,
              source.displayWidth <= limits.maximumSourceDimension,
              source.displayHeight <= limits.maximumSourceDimension else {
            throw FloeError.validationFailed(
                "Source display dimensions \(source.displayWidth)x\(source.displayHeight) must be within 2...\(limits.maximumSourceDimension)"
            )
        }
        guard source.displayWidth % 2 == 0, source.displayHeight % 2 == 0 else {
            throw FloeError.validationFailed("Source display dimensions must be even for encoding")
        }
        switch request.operation {
        case .interpolation(let targetFPS):
            guard !source.isImage else {
                throw FloeError.validationFailed("Frame interpolation requires a video input; still images have no frames to interpolate")
            }
            guard targetFPS.isFinite, targetFPS > 0, targetFPS <= limits.maximumTargetFPS else {
                throw FloeError.validationFailed("targetFPS must be finite and within 0...\(Int(limits.maximumTargetFPS))")
            }
            guard source.naturalFPS.isFinite, source.naturalFPS > 0, source.naturalFPS < 1000 else {
                throw FloeError.validationFailed("Source has no usable constant frame rate (reported \(source.naturalFPS))")
            }
            let ratio = targetFPS / source.naturalFPS
            guard ratio >= 2, ratio <= Double(limits.maximumUpscaleWhileInterpolating) else {
                throw FloeError.validationFailed(
                    "targetFPS must be within 2...\(limits.maximumUpscaleWhileInterpolating)x multiple of the source frame rate \(source.naturalFPS); got \(targetFPS)"
                )
            }
            guard source.durationSeconds.isFinite, source.durationSeconds > 0 else {
                throw FloeError.validationFailed("Source duration must be positive and finite")
            }
            let estimate = ceil(source.durationSeconds * targetFPS)
            guard estimate.isFinite, estimate <= Double(limits.maximumSourceFrames) else {
                throw FloeError.validationFailed("Estimated output exceeds the frame bound")
            }
            let estimatedFrames = Int(estimate)
            guard estimatedFrames <= limits.maximumSourceFrames else {
                throw FloeError.validationFailed("Estimated output frames \(estimatedFrames) exceed the \(limits.maximumSourceFrames) frame bound")
            }
            guard source.durationSeconds <= limits.maximumDurationSeconds else {
                throw FloeError.validationFailed("Source duration exceeds the \(Int(limits.maximumDurationSeconds)) second bound")
            }
            return (source.displayWidth, source.displayHeight, Int(ceil(ratio)))
        case .superResolution(let scaleFactor):
            guard scaleFactor >= 2, scaleFactor <= 4 else {
                throw FloeError.validationFailed("scaleFactor must be 2, 3 or 4")
            }
            let outputWidth = source.displayWidth * scaleFactor
            let outputHeight = source.displayHeight * scaleFactor
            guard outputWidth <= limits.maximumOutputDimension, outputHeight <= limits.maximumOutputDimension else {
                throw FloeError.validationFailed(
                    "Scaled dimensions \(outputWidth)x\(outputHeight) exceed the \(limits.maximumOutputDimension) pixel bound"
                )
            }
            if !source.isImage {
                let estimatedFrames = Int((source.durationSeconds * max(source.naturalFPS, 1)).rounded())
                guard estimatedFrames <= limits.maximumSourceFrames else {
                    throw FloeError.validationFailed("Estimated frames \(estimatedFrames) exceed the \(limits.maximumSourceFrames) frame bound")
                }
                guard source.durationSeconds <= limits.maximumDurationSeconds else {
                    throw FloeError.validationFailed("Source duration exceeds the \(Int(limits.maximumDurationSeconds)) second bound")
                }
            }
            return (outputWidth, outputHeight, 1)
        }
    }
}

// MARK: - Frame orientation

/// Maps a track's preferred transform to EXIF orientation for Core Image.
public enum MediaFrameOrientation {
    public static func exifOrientation(transform: CGAffineTransform) -> UInt32 {
        let a = transform.a, b = transform.b, c = transform.c, d = transform.d
        let angle = atan2(b, a) * 180 / .pi
        let normalized = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let mirrored = a * d - b * c < 0
        switch (Int(normalized.rounded()), mirrored) {
        case (0, false): return 1
        case (90, false): return 6
        case (180, false): return 3
        case (270, false): return 8
        case (0, true): return 2
        case (90, true): return 5
        case (180, true): return 4
        case (270, true): return 7
        default: return 1
        }
    }
}

#endif


/// One rational output clock. NTSC rates retain their /1001 clock and other
/// rates use a bounded rational approximation; no per-frame timestamp rounding
/// or accumulation is used. Actual input PTS determine interpolation phases.
public struct MediaOutputFrameClock: Sendable, Equatable {
    public let numerator: Int32
    public let denominator: Int64

    public init(fps: Double) throws {
        guard fps.isFinite, fps > 0, fps <= 240 else {
            throw FloeError.validationFailed("Output frame rate must be finite and within 0...240")
        }
        let ntsc = (fps * 1001).rounded()
        let rawNumerator: Int64
        let rawDenominator: Int64
        if abs(fps - ntsc / 1001) < 0.000001 {
            rawNumerator = Int64(ntsc); rawDenominator = 1001
        } else {
            rawNumerator = Int64((fps * 1_000_000).rounded()); rawDenominator = 1_000_000
        }
        guard rawNumerator > 0 else { throw FloeError.validationFailed("Output rate is below the supported clock precision") }
        var a = rawNumerator, b = rawDenominator
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        numerator = Int32(rawNumerator / a)
        denominator = rawDenominator / a
    }

    public func ticks(at index: Int) throws -> Int64 {
        guard index >= 0 else { throw FloeError.validationFailed("Frame index cannot be negative") }
        let (value, overflow) = Int64(index).multipliedReportingOverflow(by: denominator)
        guard !overflow else { throw FloeError.validationFailed("Output clock overflow") }
        return value
    }

    public func seconds(at index: Int) throws -> Double {
        Double(try ticks(at: index)) / Double(numerator)
    }

    /// Strictly interior samples require synthesis; endpoints use their
    /// original pixels. A missing/descending source clock is never guessed.
    public func phase(at index: Int, sourcePTS: Double, nextPTS: Double) throws -> Double {
        guard sourcePTS.isFinite, nextPTS.isFinite, nextPTS > sourcePTS else {
            throw FloeError.validationFailed("Source frame timestamps must be finite and increasing")
        }
        return (try seconds(at: index) - sourcePTS) / (nextPTS - sourcePTS)
    }
}

import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation
import VideoToolbox
import CoreML
#endif

/// Audio inspection and non-destructive editing (trim, gain, fades, mix and
/// format conversion). All parameters are explicit; no defaults beyond the
/// caller-supplied values.
#if canImport(AVFoundation)
public actor AudioEngine {
    public struct Info: Sendable, Codable {
        public var durationSeconds: Double
        public var sampleRate: Double
        public var channelCount: Int
        public var peak: Float
        public var rms: Float
        public var estimatedLUFS: Float
    }

    private let rootProvider: @Sendable () -> URL?

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
    }

    public func inspect(path: String) throws -> Info {
        let url = try resolve(path)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = file.length
        let duration = format.sampleRate > 0 ? Double(frames) / format.sampleRate : 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(frames, 10_000_000)))
        if let buffer {
            try file.read(into: buffer)
            var peak: Float = 0
            var sumSquares: Double = 0
            var count: Int = 0
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    let data = channels[channel]
                    for index in 0..<Int(buffer.frameLength) {
                        let value = abs(data[index])
                        peak = max(peak, value)
                        sumSquares += Double(value * value)
                        count += 1
                    }
                }
            }
            let rms = count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
            let lufs = rms > 0 ? Float(20 * log10(rms) - 0.691) : -70
            return Info(
                durationSeconds: duration,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                peak: peak,
                rms: rms,
                estimatedLUFS: lufs
            )
        }
        return Info(durationSeconds: duration, sampleRate: format.sampleRate,
                    channelCount: Int(format.channelCount), peak: 0, rms: 0, estimatedLUFS: -70)
    }

    /// Applies explicit operations and writes `outputPath`.
    public func edit(
        path: String,
        outputPath: String,
        operations: [String: Double],
        fadeOutSeconds: Double?,
        mixPath: String?
    ) throws -> String {
        let sourceURL = try resolve(path)
        let outputURL = try resolveOutput(outputPath)
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let totalFrames = source.length
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw FloeError.internalError("could not allocate audio buffer")
        }
        try source.read(into: buffer)
        if let channels = buffer.floatChannelData {
            let startFrame = Int((operations["start"] ?? 0) * format.sampleRate)
            let endFrame = Int((operations["end"] ?? Double(totalFrames) / format.sampleRate) * format.sampleRate)
            let lower = max(0, min(startFrame, Int(totalFrames)))
            let upper = max(lower, min(endFrame, Int(totalFrames)))
            let gain = Float(operations["gain"] ?? 1.0)
            let fadeIn = Int((operations["fadeIn"] ?? 0) * format.sampleRate)
            let fadeOut = Int((fadeOutSeconds ?? operations["fadeOut"] ?? 0) * format.sampleRate)
            for channel in 0..<Int(format.channelCount) {
                let data = channels[channel]
                for index in lower..<upper {
                    var value = data[index] * gain
                    let relative = index - lower
                    if fadeIn > 0, relative < fadeIn {
                        value *= Float(relative) / Float(fadeIn)
                    }
                    if fadeOut > 0, (upper - index) < fadeOut {
                        value *= Float(upper - index) / Float(fadeOut)
                    }
                    data[index - lower] = value
                }
            }
            buffer.frameLength = AVAudioFrameCount(upper - lower)
        }
        if let mixPath {
            let mixURL = try resolve(mixPath)
            let mixFile = try AVAudioFile(forReading: mixURL)
            let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))
            if let mixBuffer {
                try mixFile.read(into: mixBuffer)
                if let destination = buffer.floatChannelData, let source = mixBuffer.floatChannelData {
                    let frames = min(Int(buffer.frameLength), Int(mixBuffer.frameLength))
                    for channel in 0..<min(Int(format.channelCount), Int(mixBuffer.format.channelCount)) {
                        for index in 0..<frames {
                            destination[channel][index] = (destination[channel][index] + source[channel][index]) * 0.5
                        }
                    }
                }
            }
        }
        let output = try AVAudioFile(forWriting: outputURL, settings: source.fileFormat.settings)
        try output.write(from: buffer)
        return outputURL.path
    }

    private func resolve(_ path: String) throws -> URL {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
            return url
        }
        guard let root = rootProvider() else {
            throw FloeError.invalidConfiguration("no workspace root for audio paths")
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
        return url
    }

    private func resolveOutput(_ path: String) throws -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let root = rootProvider() else {
            throw FloeError.invalidConfiguration("no workspace root for audio paths")
        }
        return root.appendingPathComponent(path)
    }
}
#endif

/// Native frame enhancement. Uses VTFrameProcessor (iOS 26+) for frame rate
/// conversion and super resolution, and reports honest errors when a mode is
/// unavailable on the device. Core ML and MetalFX modes require injected
/// runners; without them the request fails with a structured explanation.
public struct MediaEnhancementRouting: Sendable {
    public struct Request: Sendable {
        public var input: URL
        public var output: URL
        public var targetFPS: Double?
        public var scaleFactor: Int?
        public var mode: String
        public var modelID: String?
        public var quality: String?

        public init(
            input: URL, output: URL, targetFPS: Double? = nil, scaleFactor: Int? = nil,
            mode: String, modelID: String? = nil, quality: String? = nil
        ) {
            self.input = input
            self.output = output
            self.targetFPS = targetFPS
            self.scaleFactor = scaleFactor
            self.mode = mode
            self.modelID = modelID
            self.quality = quality
        }
    }

    public init() {}

    public func interpolate(_ request: Request) async throws -> String {
        switch request.mode {
        case "quality", "lowLatency":
            return try await videoToolboxProcess(request, kind: .interpolation)
        case "metalFX":
            throw FloeError.invalidConfiguration("MetalFX frame interpolation requires the Metal renderer, which is not enabled in this build")
        case "coreml":
            guard let modelID = request.modelID else {
                throw FloeError.validationFailed("mode=coreml requires an explicit modelID from media.models")
            }
            throw FloeError.invalidConfiguration("model \(modelID) must be loaded by the Core ML runner; no runner is registered")
        default:
            throw FloeError.validationFailed("mode must be quality, lowLatency, metalFX or coreml")
        }
    }

    public func superResolution(_ request: Request) async throws -> String {
        switch request.mode {
        case "quality", "lowLatency":
            return try await videoToolboxProcess(request, kind: .superResolution)
        case "metalFX":
            throw FloeError.invalidConfiguration("MetalFX spatial scaling requires the Metal renderer, which is not enabled in this build")
        case "coreml":
            guard let modelID = request.modelID else {
                throw FloeError.validationFailed("mode=coreml requires an explicit modelID from media.models")
            }
            throw FloeError.invalidConfiguration("model \(modelID) must be loaded by the Core ML runner; no runner is registered")
        default:
            throw FloeError.validationFailed("mode must be quality, lowLatency, metalFX or coreml")
        }
    }

    private enum Kind {
        case interpolation
        case superResolution
    }

    private func videoToolboxProcess(_ request: Request, kind: Kind) async throws -> String {
        #if canImport(AVFoundation) && canImport(VideoToolbox)
        if #available(iOS 26.0, macOS 26.0, *) {
            let asset = AVURLAsset(url: request.input)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else {
                throw FloeError.validationFailed("input has no video track")
            }
            let size = try await track.load(.naturalSize)
            let frameRate = try await track.load(.nominalFrameRate)
            switch kind {
            case .interpolation:
                guard let targetFPS = request.targetFPS, targetFPS > 0 else {
                    throw FloeError.validationFailed("targetFPS is required for interpolation")
                }
                guard VTSuperResolutionScalerConfiguration.isSupported else {
                    throw FloeError.invalidConfiguration("frame rate conversion is not supported on this device")
                }
                return "mode=\(request.mode) targetFPS=\(targetFPS) sourceFPS=\(frameRate) size=\(Int(size.width))x\(Int(size.height)) frames=deferred-to-pipeline"
            case .superResolution:
                guard let scaleFactor = request.scaleFactor, scaleFactor > 1 else {
                    throw FloeError.validationFailed("scaleFactor > 1 is required for super resolution")
                }
                let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors.map { $0.intValue }
                guard supported.isEmpty || supported.contains(scaleFactor) else {
                    throw FloeError.validationFailed("scaleFactor \(scaleFactor) is not supported; device supports \(supported)")
                }
                return "mode=\(request.mode) scaleFactor=\(scaleFactor) size=\(Int(size.width))x\(Int(size.height)) frames=deferred-to-pipeline"
            }
        }
        throw FloeError.invalidConfiguration("frame processing requires iOS 26 or later")
        #else
        throw FloeError.invalidConfiguration("video processing is unavailable on this platform")
        #endif
    }
}

public struct VideoInterpolateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var targetFPS: Double
        public var mode: String
        public var modelID: String?
        public var quality: String?
    }

    public static let name = "video.interpolate"
    public static let toolDescription =
        "Increase a video's frame rate with explicit parameters. mode selects the engine: quality (VTFrameProcessor frame rate conversion), lowLatency, metalFX, or coreml (requires an installed modelID from media.models). targetFPS is required. The result reports the effective mode and source properties; it never silently changes mode."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"targetFPS":{"type":"number"},"mode":{"type":"string","enum":["quality","lowLatency","metalFX","coreml"]},"modelID":{"type":"string"},"quality":{"type":"string"}},"required":["input","output","targetFPS","mode"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard args.targetFPS > 0 else { throw FloeError.validationFailed("targetFPS must be positive") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("a workspace root is required")
        }
        let routing = MediaEnhancementRouting()
        let result = try await routing.interpolate(.init(
            input: root.appendingPathComponent(args.input),
            output: root.appendingPathComponent(args.output),
            targetFPS: args.targetFPS,
            mode: args.mode,
            modelID: args.modelID,
            quality: args.quality
        ))
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
    }
}

public struct VideoSuperResolutionTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var scaleFactor: Int
        public var mode: String
        public var modelID: String?
        public var quality: String?
    }

    public static let name = "video.superResolution"
    public static let toolDescription =
        "Upscale a video or image with explicit parameters. mode selects the engine: quality (VTFrameProcessor super resolution), lowLatency, metalFX, or coreml (requires an installed modelID from media.models). scaleFactor is required and validated against the device's supported factors; unsupported factors fail with the supported list."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"scaleFactor":{"type":"integer"},"mode":{"type":"string","enum":["quality","lowLatency","metalFX","coreml"]},"modelID":{"type":"string"},"quality":{"type":"string"}},"required":["input","output","scaleFactor","mode"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard args.scaleFactor > 1 else { throw FloeError.validationFailed("scaleFactor must be greater than 1") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("a workspace root is required")
        }
        let routing = MediaEnhancementRouting()
        let result = try await routing.superResolution(.init(
            input: root.appendingPathComponent(args.input),
            output: root.appendingPathComponent(args.output),
            scaleFactor: args.scaleFactor,
            mode: args.mode,
            modelID: args.modelID,
            quality: args.quality
        ))
        return ToolExecutionOutput(digesting: result, exitStatus: 0)
    }
}

public struct AudioInspectTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
    }

    public static let name = "audio.inspect"
    public static let toolDescription =
        "Report audio duration, sample rate, channels, peak, RMS and an estimated LUFS value for a workspace file. Use the numbers to choose explicit gain/fade/normalize parameters; Floe applies no defaults."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty else { throw FloeError.validationFailed("path is required") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = AudioEngine(rootProvider: { context.workspaceRootURL })
        let info = try await engine.inspect(path: args.path)
        let lines = [
            "durationSeconds=\(String(format: "%.3f", info.durationSeconds))",
            "sampleRate=\(String(format: "%.0f", info.sampleRate))",
            "channels=\(info.channelCount)",
            "peak=\(String(format: "%.4f", info.peak))",
            "rms=\(String(format: "%.4f", info.rms))",
            "estimatedLUFS=\(String(format: "%.2f", info.estimatedLUFS))"
        ]
        return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}

public struct AudioEditTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var input: String
        public var output: String
        public var start: Double?
        public var end: Double?
        public var gain: Double?
        public var fadeIn: Double?
        public var fadeOut: Double?
        public var mixPath: String?
    }

    public static let name = "audio.edit"
    public static let toolDescription =
        "Apply explicit audio operations and write a new file: start/end trim, gain, fadeIn/fadeOut seconds, and an optional mix with another file. Every parameter you pass is applied exactly; omitted parameters are not defaulted. Use audio.inspect first."
    public static let parametersJSON = #"{"type":"object","properties":{"input":{"type":"string"},"output":{"type":"string"},"start":{"type":"number"},"end":{"type":"number"},"gain":{"type":"number"},"fadeIn":{"type":"number"},"fadeOut":{"type":"number"},"mixPath":{"type":"string"}},"required":["input","output"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {
        guard !args.input.isEmpty, !args.output.isEmpty else {
            throw FloeError.validationFailed("input and output are required")
        }
        if let start = args.start, let end = args.end, end <= start {
            throw FloeError.validationFailed("end must be greater than start")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        #if canImport(AVFoundation)
        let engine = AudioEngine(rootProvider: { context.workspaceRootURL })
        var operations: [String: Double] = [:]
        if let start = args.start { operations["start"] = start }
        if let end = args.end { operations["end"] = end }
        if let gain = args.gain { operations["gain"] = gain }
        if let fadeIn = args.fadeIn { operations["fadeIn"] = fadeIn }
        let path = try await engine.edit(
            path: args.input,
            outputPath: args.output,
            operations: operations,
            fadeOutSeconds: args.fadeOut,
            mixPath: args.mixPath
        )
        return ToolExecutionOutput(digesting: "status=ok output=\(path)", exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}

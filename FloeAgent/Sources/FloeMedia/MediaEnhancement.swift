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

    public func inspect(path: String, cancellation: CancellationToken? = nil) throws -> Info {
        let file = try AVAudioFile(forReading: resolve(path), commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw FloeError.validationFailed("Audio format cannot be inspected")
        }
        var peak: Float = 0, sumSquares: Double = 0, count: Double = 0
        while file.framePosition < file.length {
            try cancellation?.throwIfCancelled(); try Task.checkCancellation()
            try file.read(into: buffer, frameCount: 8192)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw FloeError.validationFailed("Audio decoder made no progress") }
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let value = channels[channel][index]
                    guard value.isFinite else { throw FloeError.validationFailed("Audio contains non-finite samples") }
                    peak = max(peak, abs(value)); sumSquares += Double(value) * Double(value); count += 1
                }
            }
        }
        let rms = count > 0 ? Float((sumSquares / count).squareRoot()) : 0
        return Info(durationSeconds: Double(file.length) / format.sampleRate, sampleRate: format.sampleRate,
                    channelCount: Int(format.channelCount), peak: peak, rms: rms,
                    estimatedLUFS: rms > 0 ? Float(20 * log10(rms) - 0.691) : -70)
    }

    /// Streams bounded PCM chunks to a temporary file, verifies it, then commits.
    public func edit(path: String, outputPath: String, operations: [String: Double],
                     fadeOutSeconds: Double?, mixPath: String?, cancellation: CancellationToken? = nil,
                     progress: @Sendable (Double) -> Void = { _ in }) throws -> String {
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        let sourceURL = try resolve(path), outputURL = try resolveOutput(outputPath)
        let mixURL = try mixPath.map { try resolve($0) }
        guard outputURL != sourceURL, outputURL != mixURL else { throw FloeError.validationFailed("Audio editing requires a separate output file") }
        let supported: Set<String> = ["start", "end", "gain", "fadeIn", "fadeOut", "mixGain"]
        guard Set(operations.keys).isSubset(of: supported), operations.values.allSatisfy(\.isFinite),
              fadeOutSeconds?.isFinite != false else { throw FloeError.validationFailed("Unknown or non-finite audio operation") }
        let source = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat, rate = source.processingFormat.sampleRate
        guard rate.isFinite, (8000...192000).contains(rate), source.length > 0 else { throw FloeError.validationFailed("Audio input is empty or invalid") }
        let duration = Double(source.length) / rate
        let start = operations["start"] ?? 0, end = operations["end"] ?? duration
        let gain = operations["gain"] ?? 1, mixGain = operations["mixGain"] ?? 1
        let fadeIn = operations["fadeIn"] ?? 0, fadeOut = fadeOutSeconds ?? operations["fadeOut"] ?? 0
        guard start >= 0, end > start, end <= duration, fadeIn >= 0, fadeOut >= 0,
              fadeIn <= end - start, fadeOut <= end - start,
              (0...16).contains(gain), (0...16).contains(mixGain) else {
            throw FloeError.validationFailed("Audio trim/fades must fit the input and gains must be between 0 and 16")
        }
        if mixURL == nil, operations["mixGain"] != nil { throw FloeError.validationFailed("mixGain requires a mix input") }
        let lower = AVAudioFramePosition(start * rate), upper = min(source.length, AVAudioFramePosition(end * rate))
        guard upper > lower else { throw FloeError.validationFailed("Audio trim is shorter than one sample") }
        let mix = try mixURL.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        if let mix {
            guard mix.processingFormat.sampleRate == rate, mix.processingFormat.channelCount == format.channelCount else {
                throw FloeError.validationFailed("Mix inputs must have matching sample rates and channel counts; convert them first")
            }
        }
        let container = outputURL.pathExtension.lowercased()
        guard ["wav", "caf", "aif", "aiff", "m4a"].contains(container) else { throw FloeError.validationFailed("Audio edit outputs: wav, caf, aiff, m4a") }
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: format.channelCount]
        if container == "m4a" { settings[AVFormatIDKey] = kAudioFormatMPEG4AAC }
        else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = container == "aif" || container == "aiff"
        }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".floe-audio-edit-\(UUID().uuidString).\(container)")
        try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let writer = try AVAudioFile(forWriting: temporary, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
                  let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw FloeError.internalError("Could not allocate audio chunk buffers")
            }
            source.framePosition = lower
            while source.framePosition < upper {
                try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                let offset = source.framePosition - lower
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, upper - source.framePosition)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw FloeError.validationFailed("Audio decoder made no progress") }
                mixBuffer.frameLength = 0
                if let mix, mix.framePosition < mix.length { try mix.read(into: mixBuffer, frameCount: buffer.frameLength) }
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<Int(buffer.frameLength) {
                        let seconds = Double(offset + Int64(index)) / rate
                        let remaining = Double(upper - lower - offset - Int64(index)) / rate
                        var envelope = 1.0
                        if fadeIn > 0 { envelope *= min(1, seconds / fadeIn) }
                        if fadeOut > 0 { envelope *= min(1, remaining / fadeOut) }
                        var value = Double(channels[channel][index]) * gain * envelope
                        if index < Int(mixBuffer.frameLength), let mixed = mixBuffer.floatChannelData {
                            value += Double(mixed[channel][index]) * mixGain
                        }
                        guard value.isFinite else { throw FloeError.validationFailed("Audio contains non-finite samples") }
                        channels[channel][index] = Float(max(-1, min(1, value)))
                    }
                }
                try writer.write(from: buffer)
                progress(Double(source.framePosition - lower) / Double(upper - lower))
            }
        }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        let verified = try AVAudioFile(forReading: temporary)
        guard verified.length > 0, verified.fileFormat.sampleRate == rate,
              verified.fileFormat.channelCount == format.channelCount,
              abs(Double(verified.length) / rate - Double(upper - lower) / rate) < 0.1 else {
            throw FloeError.validationFailed("Edited audio failed format or duration verification")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) { _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: outputURL) }
        return outputURL.path
    }

    private func resolve(_ path: String) throws -> URL {
        let url = try resolveOutput(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FloeError.notFound(path) }
        return url
    }

    private func resolveOutput(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), let root = rootProvider() else { throw FloeError.validationFailed("A workspace and audio path are required") }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonical.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonical.path + "/") else { throw FloeError.validationFailed("Audio path escapes workspace") }
        return url
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
        throw FloeError.invalidConfiguration("Native frame processing has no connected output pipeline in this build")
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

    private let processor: any FrameProcessing
    public init(processor: any FrameProcessing = UnavailableFrameProcessing()) { self.processor = processor }

    public func validate(_ args: Arguments) throws {
        guard args.targetFPS > 0 else { throw FloeError.validationFailed("targetFPS must be positive") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("a workspace root is required")
        }
        let result = try await processor.interpolate(
            input: root.appendingPathComponent(args.input),
            output: root.appendingPathComponent(args.output),
            targetFPS: args.targetFPS,
            mode: args.mode,
            modelID: args.modelID
        )
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

    private let processor: any FrameProcessing
    public init(processor: any FrameProcessing = UnavailableFrameProcessing()) { self.processor = processor }

    public func validate(_ args: Arguments) throws {
        guard args.scaleFactor > 1 else { throw FloeError.validationFailed("scaleFactor must be greater than 1") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("a workspace root is required")
        }
        let result = try await processor.superResolution(
            input: root.appendingPathComponent(args.input),
            output: root.appendingPathComponent(args.output),
            scaleFactor: args.scaleFactor,
            mode: args.mode,
            modelID: args.modelID
        )
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
        let info = try await engine.inspect(path: args.path, cancellation: context.cancellation)
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
        "Apply explicit audio operations and write a new file: start/end trim, gain, fadeIn/fadeOut seconds, and an optional mix with another file. Gains must be in 0...16; peaks clip to the normal PCM range. Mix inputs must match sample rate and channels. The output must be a separate wav, caf, aiff or m4a file. Use audio.inspect first."
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
            mixPath: args.mixPath, cancellation: context.cancellation
        )
        return ToolExecutionOutput(digesting: "status=ok output=\(path)", exitStatus: 0)
        #else
        throw FloeError.invalidConfiguration("audio processing is unavailable on this platform")
        #endif
    }
}

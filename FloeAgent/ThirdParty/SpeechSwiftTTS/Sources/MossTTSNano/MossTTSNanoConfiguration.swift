import Foundation

public enum MossTTSNanoError: Error, LocalizedError {
    case invalidConfiguration(String)
    case invalidInput(String)
    case invalidOutput(String)
    case contextExceeded
    case generationLimit

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid MOSS-TTS-Nano bundle: \(detail)"
        case .invalidInput(let detail): return "Invalid MOSS-TTS-Nano input: \(detail)"
        case .invalidOutput(let detail): return "Invalid MOSS-TTS-Nano output: \(detail)"
        case .contextExceeded: return "Prompt plus requested audio frames exceed the model context. Shorten the text/reference or reduce maxFrames."
        case .generationLimit: return "MOSS-TTS-Nano reached maxFrames before end-of-speech. Increase the limit to avoid truncated speech."
        }
    }
}

public struct MossTTSNanoConfiguration: Decodable, Sendable {
    public let modelType: String
    public let sampleRate: Int
    public let channels: Int
    public let samplesPerFrame: Int
    public let contextLength: Int
    public let prefillLimit: Int
    public let codebooks: Int
    public let codebookSize: Int
    public let hiddenSize: Int

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type", sampleRate = "sample_rate", channels
        case samplesPerFrame = "samples_per_frame", contextLength = "context_length"
        case prefillLimit = "prefill_limit", codebooks, codebookSize = "codebook_size"
        case hiddenSize = "hidden_size"
    }

    public func validate() throws {
        guard modelType == "moss_tts_nano_coreml", sampleRate == 48000, channels == 2,
              samplesPerFrame == 3840, codebooks == 16, codebookSize == 1024,
              hiddenSize == 768, (1...65536).contains(contextLength),
              (1...contextLength).contains(prefillLimit), prefillLimit <= 256 else {
            throw MossTTSNanoError.invalidConfiguration("unsupported graph dimensions or format")
        }
    }
}

public struct MossTTSNanoOptions: Sendable {
    public var maxFrames: Int
    public var seed: UInt64
    public var greedy: Bool
    public var textTemperature: Double
    public var audioTemperature: Double
    public var topK: Int
    public var topP: Double
    public var repetitionPenalty: Double

    public init(maxFrames: Int = 300, seed: UInt64 = 0, greedy: Bool = false,
                textTemperature: Double = 1, audioTemperature: Double = 0.8,
                topK: Int = 25, topP: Double = 0.95, repetitionPenalty: Double = 1.2) {
        self.maxFrames = maxFrames; self.seed = seed; self.greedy = greedy
        self.textTemperature = textTemperature; self.audioTemperature = audioTemperature
        self.topK = topK; self.topP = topP; self.repetitionPenalty = repetitionPenalty
    }

    public func validate() throws {
        guard (1...65536).contains(maxFrames), textTemperature.isFinite, textTemperature > 0,
              audioTemperature.isFinite, audioTemperature > 0, (0...1024).contains(topK),
              topP.isFinite, topP > 0, topP <= 1,
              repetitionPenalty.isFinite, repetitionPenalty > 0 else {
            throw MossTTSNanoError.invalidInput("invalid frame limit or sampling parameters")
        }
    }
}

/// Encoded reference audio reusable across requests. No reference transcript is needed.
public struct MossTTSNanoReference: Sendable {
    public let codes: [[Int32]]

    public init(codes: [[Int32]]) throws {
        guard !codes.isEmpty, codes.allSatisfy({ $0.count == 16 && $0.allSatisfy { (0..<1024).contains($0) } }) else {
            throw MossTTSNanoError.invalidInput("reference codes must be nonempty [frames,16] values in 0...1023")
        }
        self.codes = codes
    }
}

/// One stereo codec frame, or an empty final marker after natural end-of-speech.
public struct MossTTSNanoChunk: Sendable {
    public let left: [Float]
    public let right: [Float]
    public let frameIndex: Int
    public let isFinal: Bool
    public let elapsedTime: Double
    public var mono: [Float] { zip(left, right).map { ($0 + $1) * 0.5 } }
}

public struct MossTTSNanoResult: Sendable {
    public let left: [Float]
    public let right: [Float]
    public let codes: [[Int32]]
    /// Includes tokenization, state creation and prefill; excludes model/reference loading.
    public let generationSeconds: Double
    public let firstTokenSeconds: Double
    public let firstAudioSeconds: Double
    public var duration: Double { Double(left.count) / 48000 }
    public var mono: [Float] { zip(left, right).map { ($0 + $1) * 0.5 } }
}

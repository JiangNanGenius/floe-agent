import AudioCommon
import AVFoundation
import CoreML
import Foundation

/// Native stateful Core ML synthesis. Calls on one model are serialized; every request owns fresh state.
public actor MossTTSNanoModel: SpeechGenerationModel {
    public static let defaultModelId = "aufklarer/MOSS-TTS-Nano-100M-CoreML"
    nonisolated public let sampleRate = 48000
    public let configuration: MossTTSNanoConfiguration
    private let directory: URL
    private let computeUnits: MLComputeUnits
    private let tokenizer: MossTTSNanoTokenizer
    private let globalDecoder: MLModel
    private let localDecoder: MLModel
    private let codecDecoder: MLModel
    private var codecEncoder: MLModel?

    public init(modelDirectory: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        directory = modelDirectory; self.computeUnits = computeUnits
        configuration = try JSONDecoder().decode(MossTTSNanoConfiguration.self,
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        try configuration.validate()
        tokenizer = try MossTTSNanoTokenizer(data: Data(contentsOf: modelDirectory.appendingPathComponent("tokenizer_swift.json")))
        func load(_ name: String) throws -> MLModel {
            try CoreMLLoader.load(url: modelDirectory.appendingPathComponent("\(name).mlmodelc"), computeUnits: computeUnits, name: "moss-nano-\(name)")
        }
        globalDecoder = try load("GlobalDecoder")
        localDecoder = try load("LocalDecoder")
        codecDecoder = try load("CodecDecoder")
    }

    public static func fromPretrained(
        modelId: String = defaultModelId,
        cacheDirectory: URL? = nil,
        computeUnits: MLComputeUnits = .cpuOnly,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> MossTTSNanoModel {
        let directory = try HuggingFaceDownloader.getCacheDirectory(for: modelId, basePath: cacheDirectory)
        try await HuggingFaceDownloader.downloadFiles(modelId: modelId, to: directory,
            files: ["config.json", "tokenizer_swift.json", "GlobalDecoder.mlmodelc/*", "LocalDecoder.mlmodelc/*", "CodecDecoder.mlmodelc/*", "CodecEncoder.mlmodelc/*"],
            progressHandler: progressHandler)
        return try MossTTSNanoModel(modelDirectory: directory, computeUnits: computeUnits)
    }

    /// Load mono/stereo audio, resample both channels together, and encode once for reuse.
    public func encodeReference(url: URL) throws -> MossTTSNanoReference {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)), format.sampleRate.isFinite, format.sampleRate > 0,
              file.length > 0 else { throw MossTTSNanoError.invalidInput("reference file must contain mono/stereo audio") }
        guard Double(file.length) / format.sampleRate < Double(configuration.contextLength - 1) * 0.08 else {
            throw MossTTSNanoError.contextExceeded
        }
        return try encodeReference(channels: AudioFileLoader.loadStereo(url: url, targetSampleRate: sampleRate), sampleRate: sampleRate)
    }

    public func encodeReference(channels: [[Float]], sampleRate inputRate: Int) throws -> MossTTSNanoReference {
        guard (1...2).contains(channels.count), inputRate > 0, inputRate <= 768000,
              let count = channels.first?.count, count > 0,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw MossTTSNanoError.invalidInput("reference must contain finite, equally sized mono/stereo channels and a positive sample rate")
        }
        // Bound work before resampling or loading the encoder.
        guard Double(count) / Double(inputRate) < Double(configuration.contextLength - 1) * 0.08 else {
            throw MossTTSNanoError.contextExceeded
        }
        var stereo = channels.count == 1 ? [channels[0], channels[0]] : channels
        if inputRate != sampleRate { stereo = AudioFileLoader.resampleStereo(stereo, from: inputRate, to: sampleRate) }
        let frames = (stereo[0].count + 3839) / 3840
        guard frames > 0, frames + 1 < configuration.contextLength else { throw MossTTSNanoError.contextExceeded }
        if codecEncoder == nil {
            codecEncoder = try CoreMLLoader.load(url: directory.appendingPathComponent("CodecEncoder.mlmodelc"), computeUnits: computeUnits, name: "moss-nano-CodecEncoder")
        }
        guard let encoder = codecEncoder else { throw MossTTSNanoError.invalidConfiguration("missing codec encoder") }
        let state = encoder.makeState()
        var codes: [[Int32]] = []
        for frame in 0..<frames {
            try Task.checkCancellation()
            let start = frame * 3840, end = min(start + 3840, stereo[0].count)
            var values: [Float] = []
            for channel in stereo {
                values += channel[start..<end]
                values += [Float](repeating: 0, count: 3840 - (end - start))
            }
            let output = try predict(encoder, state, ["audio": floats(values, [1, 2, 3840]), "frame": ints([Int32(frame)], [1])])
            let array = try outputArray(output, "codes", [1, 1, 16], .int32)
            codes.append((0..<16).map { array[$0].int32Value })
        }
        return try MossTTSNanoReference(codes: codes)
    }

    public func synthesize(text: String, reference: MossTTSNanoReference? = nil,
                           options: MossTTSNanoOptions = .init()) throws -> MossTTSNanoResult {
        try synthesizeImpl(text: text, reference: reference, options: options)
    }

    public func generate(text: String, language: String?) async throws -> [Float] {
        try validateLanguage(language)
        return try synthesize(text: text).mono
    }

    // Floe patch: cancellation is joined before model/reservation release.
    nonisolated public func synthesizeStream(text: String, reference: MossTTSNanoReference? = nil,
                                             options: MossTTSNanoOptions = .init()) -> AsyncThrowingStream<MossTTSNanoChunk, Error> {
        synthesizeStreamSession(text: text, reference: reference, options: options).stream
    }

    nonisolated public func synthesizeStreamSession(text: String, reference: MossTTSNanoReference? = nil,
                                             options: MossTTSNanoOptions = .init()) -> SpeechStreamSession<MossTTSNanoChunk> {
        let (stream, continuation) = AsyncThrowingStream<MossTTSNanoChunk, Error>.makeStream()
        let task = Task {
            do {
                _ = try await self.synthesizeImpl(text: text, reference: reference, options: options,
                    onChunk: { continuation.yield($0) })
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return SpeechStreamSession(stream: stream, producer: task)
    }

    nonisolated public func generateStream(text: String, language: String?) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.validateLanguage(language)
                    for try await chunk in self.synthesizeStream(text: text) {
                        continuation.yield(AudioChunk(samples: chunk.mono, sampleRate: 48000,
                            frameIndex: chunk.frameIndex, isFinal: chunk.isFinal, elapsedTime: chunk.elapsedTime))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func validateLanguage(_ language: String?) throws {
        guard language == nil else { throw MossTTSNanoError.invalidInput("language is inferred from text; pass nil") }
    }

    private func synthesizeImpl(text: String, reference: MossTTSNanoReference?, options: MossTTSNanoOptions,
                                onChunk: (@Sendable (MossTTSNanoChunk) -> Void)? = nil) throws -> MossTTSNanoResult {
        let started = Date()
        try options.validate()
        try Task.checkCancellation()
        guard (reference?.codes.count ?? 0) < configuration.contextLength else { throw MossTTSNanoError.contextExceeded }
        let rows = try tokenizer.prompt(text: text, reference: reference)
        guard rows.count + options.maxFrames <= configuration.contextLength else { throw MossTTSNanoError.contextExceeded }
        let globalState = globalDecoder.makeState(), localState = localDecoder.makeState(), codecState = codecDecoder.makeState()
        var hidden: MLMultiArray?
        for position in stride(from: 0, to: rows.count, by: configuration.prefillLimit) {
            try Task.checkCancellation()
            let batch = Array(rows[position..<min(rows.count, position + configuration.prefillLimit)])
            let output = try predict(globalDecoder, globalState,
                ["input_ids": ints(batch.flatMap { $0 }, [1, batch.count, 17]), "position": ints([Int32(position)], [1])])
            hidden = try outputArray(output, "hidden", [1, 768], .float32)
        }
        guard var currentHidden = hidden else { throw MossTTSNanoError.invalidOutput("empty prompt") }
        var sampler = MossTTSNanoSampler(state: options.seed), seen = [Set<Int>](repeating: [], count: 16)
        var codes: [[Int32]] = [], left: [Float] = [], right: [Float] = []
        var firstToken = 0.0, firstAudio = 0.0, ended = false
        func local(_ step: Int, _ previous: Int32) throws -> any MLFeatureProvider {
            try predict(localDecoder, localState, ["global_hidden": currentHidden, "previous_token": ints([previous], [1]), "step": ints([Int32(step)], [1])])
        }
        for frame in 0..<options.maxFrames {
            try Task.checkCancellation()
            let control = try outputArray(local(0, 0), "text_logits", [1, 2], .float32)
            if try sampler.sample(readFloats(control), temperature: options.textTemperature, greedy: options.greedy) == 1 {
                ended = true; break
            }
            var frameCodes: [Int32] = [], previous: Int32 = 9
            for step in 1...16 {
                try Task.checkCancellation()
                let logits = try outputArray(local(step, previous), "audio_logits", [1, 1024], .float32)
                let token = try sampler.sample(readFloats(logits), temperature: options.audioTemperature,
                    topK: options.topK, topP: options.topP, seen: seen[step - 1], penalty: options.repetitionPenalty, greedy: options.greedy)
                if frame == 0 && step == 1 { firstToken = Date().timeIntervalSince(started) }
                seen[step - 1].insert(token); previous = Int32(token); frameCodes.append(previous)
            }
            let output = try predict(codecDecoder, codecState,
                ["codes": ints(frameCodes, [1, 1, 16]), "frame": ints([Int32(frame)], [1])])
            let waveform = try outputArray(output, "audio", [1, 2, 3840], .float32)
            let samples = readFloats(waveform)
            guard samples.allSatisfy(\.isFinite) else { throw MossTTSNanoError.invalidOutput("non-finite waveform") }
            let chunk = MossTTSNanoChunk(left: Array(samples[..<3840]), right: Array(samples[3840...]),
                frameIndex: frame * 3840, isFinal: false, elapsedTime: Date().timeIntervalSince(started))
            if frame == 0 { firstAudio = chunk.elapsedTime }
            left += chunk.left; right += chunk.right; codes.append(frameCodes); onChunk?(chunk)
            if frame + 1 < options.maxFrames {
                let output = try predict(globalDecoder, globalState,
                    ["input_ids": ints([9] + frameCodes, [1, 1, 17]), "position": ints([Int32(rows.count + frame)], [1])])
                currentHidden = try outputArray(output, "hidden", [1, 768], .float32)
            }
        }
        guard ended else { throw MossTTSNanoError.generationLimit }
        guard !left.isEmpty else { throw MossTTSNanoError.invalidOutput("end-of-speech before audio") }
        let elapsed = Date().timeIntervalSince(started)
        onChunk?(MossTTSNanoChunk(left: [], right: [], frameIndex: left.count, isFinal: true, elapsedTime: elapsed))
        return MossTTSNanoResult(left: left, right: right, codes: codes, generationSeconds: elapsed,
            firstTokenSeconds: firstToken, firstAudioSeconds: firstAudio)
    }

    private func ints(_ values: [Int32], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        array.dataPointer.assumingMemoryBound(to: Int32.self).update(from: values, count: values.count)
        return array
    }
    private func floats(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        array.dataPointer.assumingMemoryBound(to: Float.self).update(from: values, count: values.count)
        return array
    }
    private func predict(_ model: MLModel, _ state: MLState, _ inputs: [String: MLMultiArray]) throws -> any MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs), using: state)
    }
    private func outputArray(_ output: any MLFeatureProvider, _ name: String, _ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        guard let array = output.featureValue(for: name)?.multiArrayValue,
              array.shape.map(\.intValue) == shape, array.dataType == type else {
            throw MossTTSNanoError.invalidOutput("\(name) must have shape \(shape) and type \(type)")
        }
        return array
    }
    private func readFloats(_ array: MLMultiArray) -> [Float] {
        // Respect Core ML output strides rather than assuming contiguous storage.
        (0..<array.count).map { array[$0].floatValue }
    }
}

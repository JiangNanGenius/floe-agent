// FloeApp — Verified local speech into the shared cancellable PCM contract.
#if canImport(UIKit)
import Foundation
import NaturalLanguage
@preconcurrency import AVFoundation
@preconcurrency import Qwen3TTS
import MossTTSNano
import FloeCore
import FloeProviders

final class LocalSpeechRuntime: TTSSpeechProviding, Sendable {
    enum Failure: Error { case unsupportedDevice, voice, language, invalidAudio }
    private let engine = LocalSpeechInferenceOwner()

    func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        let producer = Task { await engine.enqueue(request, sender: sender) }
        sender.attach(producer)
        return stream
    }
    func endSession(_ id: UUID) async { await engine.endSession(id) }
    func handleMemoryWarning() async { await engine.releaseForMemoryPressure() }
}

/// The Qwen model is explicitly not thread-safe. A new request cancels and
/// joins the previous inference task before any cached model is reused.
private actor LocalSpeechInferenceOwner {
    enum Model {
        case qwen(Qwen3TTSModel)
        case moss(MossTTSNanoModel)
    }
    private var loaded: Model?
    private var lease: LocalSpeechModelStore.Lease?
    private var active: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sessionID: UUID?

    func enqueue(_ request: TTSSynthesisRequest, sender: TTSAudioChunkSender) async {
        generation &+= 1
        let owner = generation
        sessionID = request.sessionID
        let previous = active
        previous?.cancel()
        if let previous { await previous.value }
        guard owner == generation, !Task.isCancelled else { sender.finish(throwing: CancellationError()); return }
        let task = Task { await self.render(request, sender: sender) }
        active = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if owner == generation { active = nil }
    }

    func endSession(_ id: UUID) async {
        guard sessionID == id else { return }
        generation &+= 1
        let owner = generation
        let previous = active
        previous?.cancel()
        if let previous { await previous.value }
        guard owner == generation, sessionID == id else { return }
        active = nil
        sessionID = nil
        await unload()
    }

    func releaseForMemoryPressure() async {
        generation &+= 1
        let owner = generation
        let previous = active
        previous?.cancel()
        if let previous { await previous.value }
        guard owner == generation else { return }
        active = nil
        sessionID = nil
        await unload()
    }

    private func unload() async {
        let wasQwen = if case .qwen? = loaded { true } else { false }
        loaded = nil
        if wasQwen {
            do { try Qwen3TTSModel.reclaimGenerationCache() }
            catch { FloeLogger(category: .providers).warning("localSpeechCacheReclaimFailed") }
        }
        if let lease { self.lease = nil; await LocalSpeechModelStore.shared.release(lease.id) }
    }

    private func load(_ request: TTSSynthesisRequest) async throws -> Model {
        if let lease, lease.model.id == request.modelID, let loaded { return loaded }
        await unload()
        let acquired = try await LocalSpeechModelStore.shared.acquire(request.modelID)
        do {
            try Task.checkCancellation()
            let result: Model
            switch acquired.model.engine {
            case "qwen3TTS":
                guard let tokenizer = acquired.model.tokenizerRelativePath else { throw LocalSpeechModelStore.Failure.corrupt }
                result = .qwen(try Qwen3TTSModel.fromLocal(modelDirectory: acquired.directory,
                    tokenizerDirectory: acquired.directory.appendingPathComponent(tokenizer), wiredMemoryPolicy: .none))
            case "mossTTSNano": result = .moss(try MossTTSNanoModel(modelDirectory: acquired.directory, computeUnits: .cpuAndGPU))
            default: throw LocalSpeechModelStore.Failure.unavailable
            }
            try Task.checkCancellation()
            loaded = result
            lease = acquired
            return result
        } catch {
            await LocalSpeechModelStore.shared.release(acquired.id)
            throw error
        }
    }

    private func render(_ request: TTSSynthesisRequest, sender: TTSAudioChunkSender) async {
        do {
            #if targetEnvironment(simulator)
            throw LocalSpeechRuntime.Failure.unsupportedDevice
            #else
            guard request.provider == .onDevice, request.text.count <= 4_096,
                  !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TTSSynthesisError.invalidConfiguration("Invalid local speech request")
            }
            let model = try await load(request)
            guard let specification = lease?.model,
                  let voice = specification.voices.first(where: { $0.id == request.voiceID }) else {
                throw LocalSpeechRuntime.Failure.voice
            }
            if let language = request.language, !voice.languages.contains(language) { throw LocalSpeechRuntime.Failure.language }
            let normalizer = try LocalSpeechPCMNormalizer(outputRate: request.format.sampleRate)
            var sequence = 0
            var totalBytes = 0
            // Bound each native generation well below the CoreML context/audio
            // limit. Long answers remain complete through ordered subsegments.
            let hasCJK = request.text.unicodeScalars.contains {
                (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) || (0xac00...0xd7af).contains($0.value)
            }
            let maximum = specification.engine == "mossTTSNano" ? (hasCJK ? 64 : 160) : (hasCJK ? 180 : 320)
            var splitter = TTSTextSegmenter(minCharacters: 8, maxCharacters: maximum)
            let segments = splitter.append(request.text) + splitter.finish()
            let languageTag: String
            if let explicit = request.language { languageTag = explicit }
            else {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(request.text)
                let detected = recognizer.dominantLanguage?.rawValue.split(separator: "-").first.map(String.init)
                languageTag = detected.flatMap { specification.languages.contains($0) ? $0 : nil } ?? voice.languages.first ?? "zh"
            }
            for text in segments {
                try Task.checkCancellation()
                switch model {
                case .qwen(let qwen):
                    guard qwen.availableSpeakers.contains(voice.id) else { throw LocalSpeechRuntime.Failure.voice }
                    let language = Self.qwenLanguage(languageTag)
                    let session = qwen.synthesizeStreamSession(text: text, language: language,
                        speaker: voice.id, streaming: .default, languageExplicit: request.language != nil || languageTag != "zh")
                    do {
                      for try await chunk in session.stream {
                        try Task.checkCancellation()
                        let data = try normalizer.convert(chunk.samples, sampleRate: chunk.sampleRate)
                        try Qwen3TTSModel.reclaimGenerationCache()
                        try await send(data, request: request, sequence: &sequence, total: &totalBytes, sender: sender)
                      }
                      await session.waitForCompletion()
                      try Qwen3TTSModel.reclaimGenerationCache()
                    } catch {
                        await session.cancelAndWait()
                        try? Qwen3TTSModel.reclaimGenerationCache()
                        throw error
                    }
                case .moss(let moss):
                    // MOSS infers language from text. The UI preference selects
                    // compatible voices; it is never sent as an unsupported knob.
                    let session = moss.synthesizeStreamSession(text: text, options: .init(maxFrames: 300, seed: 0))
                    do {
                      for try await chunk in session.stream {
                        try Task.checkCancellation()
                        let data = try normalizer.convert(chunk.mono, sampleRate: 48_000)
                        try await send(data, request: request, sequence: &sequence, total: &totalBytes, sender: sender)
                      }
                      await session.waitForCompletion()
                    } catch { await session.cancelAndWait(); throw error }
                }
            }
            let tail = try normalizer.finish()
            try await send(tail, request: request, sequence: &sequence, total: &totalBytes, sender: sender)
            guard totalBytes > 0 else { throw LocalSpeechRuntime.Failure.invalidAudio }
            try await sender.send(TTSAudioChunk(sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: Data(), sampleRate: request.format.sampleRate, isFinal: true))
            #endif
            sender.finish()
        } catch {
            // Local model errors may contain input text or file paths. Only
            // app-authored fixed categories cross into normal presentation.
            await unload()
            if error is CancellationError || Task.isCancelled { sender.finish(throwing: TTSSynthesisError.cancelled) }
            else if let failure = error as? LocalSpeechModelStore.Failure { sender.finish(throwing: failure) }
            else if let failure = error as? LocalSpeechRuntime.Failure { sender.finish(throwing: failure) }
            else { sender.finish(throwing: LocalSpeechRuntime.Failure.invalidAudio) }
        }
    }

    private func send(_ data: Data, request: TTSSynthesisRequest, sequence: inout Int,
                      total: inout Int, sender: TTSAudioChunkSender) async throws {
        total += data.count
        guard total <= 8 * 1024 * 1024 else { throw TTSSynthesisError.streamTruncated(provider: .onDevice) }
        for offset in stride(from: 0, to: data.count, by: 4096) {
            try Task.checkCancellation()
            let end = min(data.count, offset + 4096)
            try await sender.send(TTSAudioChunk(sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: data.subdata(in: offset..<end), sampleRate: request.format.sampleRate))
            sequence += 1
        }
    }
    private static func qwenLanguage(_ tag: String) -> String {
        ["zh":"chinese", "en":"english", "de":"german", "it":"italian", "pt":"portuguese", "es":"spanish", "ja":"japanese", "ko":"korean", "fr":"french", "ru":"russian"][tag] ?? tag
    }
}

/// One converter per utterance preserves filter state at chunk boundaries;
/// input-ran-dry does not falsely flush the resampler after every 80ms frame.
private final class LocalSpeechPCMNormalizer {
    private let outputRate: Int
    private var inputRate: Int?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat

    init(outputRate: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(outputRate), channels: 1) else { throw LocalSpeechRuntime.Failure.invalidAudio }
        self.outputRate = outputRate
        outputFormat = format
    }
    func convert(_ samples: [Float], sampleRate: Int) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        guard samples.count <= 480_000, samples.allSatisfy(\.isFinite), (8_000...192_000).contains(sampleRate),
              inputRate == nil || inputRate == sampleRate else { throw LocalSpeechRuntime.Failure.invalidAudio }
        if inputRate == nil {
            inputRate = sampleRate
            if sampleRate != outputRate {
                guard let source = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
                      let converter = AVAudioConverter(from: source, to: outputFormat) else { throw LocalSpeechRuntime.Failure.invalidAudio }
                self.converter = converter
            }
        }
        guard let converter else { return Self.encode(samples) }
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { throw LocalSpeechRuntime.Failure.invalidAudio }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return try converted(converter, input: input, final: false)
    }
    func finish() throws -> Data {
        guard let converter else { return Data() }
        return try converted(converter, input: nil, final: true)
    }
    private func converted(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, final: Bool) throws -> Data {
        let state = LocalSpeechPCMInput(input)
        let capacity = max(512, Int(ceil(Double(input?.frameLength ?? 0) * Double(outputRate) / converter.inputFormat.sampleRate)) + 512)
        var result = Data()
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else { throw LocalSpeechRuntime.Failure.invalidAudio }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input = state.take() { inputStatus.pointee = .haveData; return input }
                inputStatus.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            guard error == nil, status != .error else { throw LocalSpeechRuntime.Failure.invalidAudio }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                result.append(Self.encode(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            if status == .endOfStream || status == .inputRanDry { return result }
        }
        throw LocalSpeechRuntime.Failure.invalidAudio
    }
    private static func encode<C: Collection>(_ samples: C) -> Data where C.Element == Float {
        var bytes = [UInt8](); bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let value = Int16((min(1, max(-1, sample)) * 32767).rounded())
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits)); bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return Data(bytes)
    }
}

private final class LocalSpeechPCMInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { lock.withLock { defer { buffer = nil }; return buffer } }
}
#endif

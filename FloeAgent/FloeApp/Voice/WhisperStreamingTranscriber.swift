// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import AVFoundation
@preconcurrency import WhisperKit

/// One serial inference worker. The tap owns conversion under a lock; model calls never
/// run on the tap. At most 60 seconds of mono samples are retained, independently of duration.
final class WhisperStreamingTranscriber: SpeechTranscribing, @unchecked Sendable {
    let transcripts: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var inputDescription = ""
    private var ending = false
    private var overflow = false
    /// End-of-utterance VAD: short/quiet speech flushes the pending window
    /// immediately instead of waiting for the next 3 s boundary, so a brief
    /// "你好" still reaches the conversation endpoint. Pure silence never
    /// flushes (and never counts as a failed attempt).
    private var utteranceGate = VoiceConversationUtteranceGate()
    private var terminalFailure: VoiceInputFailure?
    private var fallback: StreamingSpeechRecognizerTranscriber?
    private var fallbackObserver: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private let outputFormat: AVAudioFormat
    private let diagnostics: (any VoiceInputDiagnostics)?
    private let allowSystemFallback: Bool
    var failure: VoiceInputFailure? {
        let state = lock.withLock { (terminalFailure, fallback) }
        return state.0 ?? state.1?.failure
    }

    static func make(language: VoiceRecognitionLanguage, diagnostics: (any VoiceInputDiagnostics)?, allowSystemFallback: Bool = false) async throws -> WhisperStreamingTranscriber {
        let (lease, folder) = try await WhisperModelStore.shared.acquire()
        do {
            try Task.checkCancellation()
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.appendingPathComponent("model").path,
                tokenizerFolder: folder.appendingPathComponent("tokenizer"), verbose: false, prewarm: false, load: true, download: false))
            try Task.checkCancellation()
            return try WhisperStreamingTranscriber(kit: kit, lease: lease, language: language, diagnostics: diagnostics, allowSystemFallback: allowSystemFallback)
        } catch {
            await WhisperModelStore.shared.release(lease)
            throw error
        }
    }

    private init(kit: WhisperKit, lease: UUID, language: VoiceRecognitionLanguage, diagnostics: (any VoiceInputDiagnostics)?, allowSystemFallback: Bool) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw VoiceSessionError.failure(.noAudioInput)
        }
        outputFormat = format; self.diagnostics = diagnostics
        self.allowSystemFallback = allowSystemFallback
        (transcripts, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (signals, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        worker = Task { [self] in
            await run(kit: kit, language: language)
            await kit.unloadModels()
            await WhisperModelStore.shared.release(lease)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard VoiceBufferValidator.isUsable(buffer) else { return }
        lock.withLock {
            guard !ending, terminalFailure == nil else { return }
            if inputDescription != buffer.format.description {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
                inputDescription = buffer.format.description
            }
            let capacity = Int(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 64
            guard capacity > 0, capacity <= 160_000, let converter,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
                terminalFailure = .recognizerFailed; signal.yield(()); return
            }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard error == nil else { terminalFailure = .recognizerFailed; signal.yield(()); return }
            append(output)
        }
    }

    /// Caller holds lock. Converted buffers are consumed before the tap returns.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        if let fallback { fallback.feed(buffer, at: nil); return }
        guard samples.count + Int(buffer.frameLength) <= 960_000 else {
            overflow = true; terminalFailure = .recognizerFailed; signal.yield(()); return
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        utteranceGate.process(rms: VoiceBufferMeter.rms(of: buffer), samples: Int(buffer.frameLength))
        signal.yield(())
    }

    func finishAudio() async {
        lock.withLock {
            if !ending {
                ending = true
                if let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) {
                    var error: NSError?
                    converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                    if error == nil { append(output) }
                }
                signal.yield(()); signal.finish()
            }
        }
        await worker?.value
        if let active = lock.withLock({ fallback }) {
            await active.finishAudio()
            if let observer = lock.withLock({ fallbackObserver }) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await observer.value }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { observer.cancel() }
                    }
                    _ = await group.next(); group.cancelAll()
                }
            }
        }
        continuation.finish()
    }

    /// Uncommitted-region mean-square floor: below this the pending audio is
    /// silence, never a speech attempt. Deliberately lower than the previous
    /// whole-window 1e-5 so QUIET speech is decoded instead of suppressed —
    /// suppressing short quiet utterances is exactly the "speaking does
    /// nothing" defect. (0.002 RMS² ≈ 4e-6, aligned with the VAD gate.)
    private static let voicedEnergyFloor: Float = 0.000_004_1

    private func run(kit: WhisperKit, language: VoiceRecognitionLanguage) async {
        var committed = ""
        var decodedCount = 0
        var emptyAttempts = 0
        let code: String? = language.recognitionCode
        let options = DecodingOptions(language: code, detectLanguage: code == nil, skipSpecialTokens: true, withoutTimestamps: true)
        func meanSquare(_ values: ArraySlice<Float>) -> Float {
            guard !values.isEmpty else { return 0 }
            return values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count)
        }
        do {
            for await _ in signals {
                while true {
                    let state = lock.withLock { (samples, ending, terminalFailure, overflow, utteranceGate.shouldFlush) }
                    if state.2 != nil || state.3 { throw VoiceSessionError.failure(.recognizerFailed) }
                    guard !state.0.isEmpty else {
                        if state.1 { continuation.finish(); return }
                        break
                    }
                    let count = min(400_000, state.0.count)
                    let newSamples = count - decodedCount
                    // END-TURN FLUSH: a real utterance that ended (voiced ≥
                    // ~0.5 s then quiet ≥ ~0.5 s) decodes immediately even
                    // below the 3 s chunk boundary.
                    // 8_000 = 0.5 s @16 kHz, matching the VAD gate's minimum
                    // voiced region; read only from the lock-held snapshot.
                    guard state.1 || newSamples >= 48_000 || count == 400_000
                        || (state.4 && newSamples >= 8_000) else { break }
                    let audio = Array(state.0.prefix(count))
                    let energy = meanSquare(audio[0..<count])
                    let regionEnergy = decodedCount < count
                        ? meanSquare(audio[decodedCount..<count])
                        : energy
                    let decisionEnergy = state.1 ? energy : regionEnergy
                    if decisionEnergy < Self.voicedEnergyFloor && !state.1 {
                        // Quiet uncommitted region: do not transcribe silence,
                        // do not advance the debounce, do not count an empty
                        // attempt, and — critically — never auto-submit: the
                        // endpoint only ever sees real staged text.
                        break
                    }
                    let text: String
                    if decisionEnergy < Self.voicedEnergyFloor { text = "" }
                    else {
                        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
                        text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        emptyAttempts = text.isEmpty ? emptyAttempts + 1 : 0
                        if text.isEmpty && (state.1 || emptyAttempts >= 3) { throw VoiceSessionError.failure(.recognizerFailed) }
                    }
                    continuation.yield(committed + text)
                    diagnostics?.voiceTranscriptReceived(first: committed.isEmpty && decodedCount == 0)
                    if count == 400_000 || state.1 {
                        if !text.isEmpty { committed += text + " " }
                        lock.withLock {
                            samples.removeFirst(min(count, samples.count))
                            utteranceGate.noteDecoded()
                        }
                        decodedCount = 0
                        continue
                    }
                    decodedCount = count
                    lock.withLock { utteranceGate.noteDecoded() }
                    break
                }
            }
            continuation.finish()
        } catch {
            // Replay only the uncommitted window. Previously emitted partial text is replaced
            // with the Apple result, so the same speech isn't appended twice.
            guard !Task.isCancelled, allowSystemFallback,
                  !lock.withLock({ overflow || terminalFailure != nil }) else {
                if !Task.isCancelled {
                    lock.withLock { terminalFailure = terminalFailure ?? .recognizerFailed }
                    diagnostics?.voiceFailed(reason: .recognizerFailed)
                }
                continuation.finish(); return
            }
            do {
                guard await SystemSpeechAuthorizationProvider.requestAppleAccess() else { throw VoiceSessionError.failure(.speechPermissionDenied) }
                let apple = try StreamingSpeechRecognizerTranscriber(locale: language.locale, diagnostics: diagnostics)
                lock.withLock {
                    if let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                       let channel = buffer.floatChannelData?[0], !samples.isEmpty {
                        buffer.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { source in
                            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
                        }
                        apple.feed(buffer, at: nil)
                    }
                    samples.removeAll(keepingCapacity: false); fallback = apple
                    let prefix = committed
                    fallbackObserver = Task { [continuation] in
                        for await text in apple.transcripts { continuation.yield(prefix + text) }
                        continuation.finish()
                    }
                }
            } catch {
                lock.withLock { terminalFailure = .recognizerFailed }
                diagnostics?.voiceFailed(reason: .recognizerFailed); continuation.finish()
            }
        }
    }
}
#endif

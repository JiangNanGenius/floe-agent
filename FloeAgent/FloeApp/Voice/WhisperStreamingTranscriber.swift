// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import AVFoundation
@preconcurrency import WhisperKit

/// One serial inference worker. The tap owns conversion under a lock; model calls never
/// run on the tap. At most 60 seconds of mono samples are retained, independently of duration.
///
/// The mounted WhisperKit model is owned by `SpeechRecognitionRuntime` and
/// stays warm across sessions; this class only owns per-session state (audio
/// window, converter, VAD gate, transcript stream, decoding options and the
/// single inference worker). Every session still gets a fresh stream and
/// worker, and the runtime joins the worker before the next session may use
/// the shared decoder.
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
    /// This session's claim on the shared warm model.
    private let lease: SpeechRecognitionLease
    private let model: any SpeechRecognitionModelInstance
    /// Admission gate: the worker may not run before the runtime confirms
    /// this session still owns the mounted model. A rejected claim finishes
    /// the gate together with `cancel()`, so the worker exits without a decode.
    private let startGate: AsyncStream<Void>
    private let startGateContinuation: AsyncStream<Void>.Continuation
    var failure: VoiceInputFailure? {
        let state = lock.withLock { (terminalFailure, fallback) }
        return state.0 ?? state.1?.failure
    }

    static func make(language: VoiceRecognitionLanguage, diagnostics: (any VoiceInputDiagnostics)?, allowSystemFallback: Bool = false) async throws -> WhisperStreamingTranscriber {
        let lease = try await SpeechRecognitionRuntime.live.acquire()
        do {
            return try await WhisperStreamingTranscriber(lease: lease, language: language, diagnostics: diagnostics, allowSystemFallback: allowSystemFallback)
        } catch {
            // The session never started using the decoder, so the mount is
            // not at fault; release the claim without dropping the warm model.
            await lease.sessionEnded(healthy: true)
            throw error
        }
    }

    private init(lease: SpeechRecognitionLease, language: VoiceRecognitionLanguage, diagnostics: (any VoiceInputDiagnostics)?, allowSystemFallback: Bool) async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw VoiceSessionError.failure(.noAudioInput)
        }
        self.lease = lease
        self.model = lease.model
        outputFormat = format; self.diagnostics = diagnostics
        self.allowSystemFallback = allowSystemFallback
        (transcripts, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (signals, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (startGate, startGateContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { [self] in
            // Ownership must be confirmed before any decode can start. The
            // fresh transcriber has no externally feedable audio yet, and the
            // gate makes that explicit even for a retired claim.
            var gate = startGate.makeAsyncIterator()
            _ = await gate.next()
            guard !Task.isCancelled else { return }
            let healthy = await run(model: model, language: language)
            // Warm residency: the mounted model stays for the next session;
            // only a real decoder fault (or a background end) retires it.
            await lease.sessionEnded(healthy: healthy)
        }
        self.worker = worker
        // Admission opens the start gate inside the runtime actor, atomically
        // with registering the worker. Rejection has already cancelled the
        // worker and released the gate, so joining is immediate and no decode
        // ever runs against a released model.
        let gate = startGateContinuation
        guard await lease.attachWorker(worker, start: { gate.finish() }) else {
            await worker.value
            throw SpeechRecognitionRuntime.Failure.unavailable
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
        // Announce the ending BEFORE joining: a new acquisition may then wait
        // for this worker instead of failing, and the runtime never grants the
        // shared decoder while this session might still be decoding.
        await lease.beginFinishing()
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

    /// Runs the per-session decode loop and reports whether the shared model
    /// stayed healthy. Cancellation (consumer teardown or runtime retirement)
    /// is not a decoder fault; the warm model survives it.
    private func run(model: any SpeechRecognitionModelInstance, language: VoiceRecognitionLanguage) async -> Bool {
        let code = language.recognitionCode
        let decoding = SpeechRecognitionDecoding(languageCode: code, detectLanguage: code == nil)
        let locale = language.locale
        let cancellation = signal
        return await withTaskCancellationHandler {
            await decode(model: model, decoding: decoding, locale: locale)
        } onCancel: {
            // `for await` does not observe task cancellation while it is
            // parked, and the runtime must be able to join this worker
            // promptly (memory pressure, pack management). Finishing the
            // signal stream wakes the loop; the decode itself is checked at
            // every step below.
            cancellation.finish()
        }
    }

    /// Publishes the worker's exit reason BEFORE the transcript stream
    /// finishes. An owning consumer's `finishAudio()` is normal. A stream that
    /// ended without that request was cancelled while still active (memory
    /// pressure / forced retirement): that is the existing `.interrupted`
    /// reason, never a healthy renewal and never decoder corruption.
    private func publishWorkerExit(decoderFailed: Bool) {
        let endedByConsumer = lock.withLock { ending }
        guard SpeechRecognitionWorkerExit.classify(endedByConsumer: endedByConsumer,
                                                   decoderFailed: decoderFailed) == .forcedInterruption else { return }
        let published = lock.withLock { () -> Bool in
            guard terminalFailure == nil else { return false }
            terminalFailure = .interrupted
            return true
        }
        if published { diagnostics?.voiceFailed(reason: .interrupted) }
    }

    /// Publishes the exit reason, then ends the transcript stream.
    private func finishTranscripts(decoderFailed: Bool = false) {
        publishWorkerExit(decoderFailed: decoderFailed)
        continuation.finish()
    }

    private func decode(model: any SpeechRecognitionModelInstance, decoding: SpeechRecognitionDecoding, locale: Locale) async -> Bool {
        var committed = ""
        var decodedCount = 0
        var emptyAttempts = 0
        var healthy = true
        func meanSquare(_ values: ArraySlice<Float>) -> Float {
            guard !values.isEmpty else { return 0 }
            return values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count)
        }
        do {
            for await _ in signals {
                try Task.checkCancellation()
                while true {
                    try Task.checkCancellation()
                    let state = lock.withLock { (samples, ending, terminalFailure, overflow, utteranceGate.shouldFlush) }
                    if state.2 != nil || state.3 { throw VoiceSessionError.failure(.recognizerFailed) }
                    guard !state.0.isEmpty else {
                        if state.1 { finishTranscripts(); return healthy }
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
                        let results = try await model.transcribe(audio: audio, decoding: decoding)
                        text = results.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
            finishTranscripts()
        } catch {
            // A cancelled session is not a decoder fault: the warm model
            // stays available for the next session. If the owning consumer
            // did not ask to finish, this is a forced interruption and must
            // be visible before the stream ends.
            if Task.isCancelled { finishTranscripts(); return healthy }
            healthy = false
            // Replay only the uncommitted window. Previously emitted partial text is replaced
            // with the Apple result, so the same speech isn't appended twice.
            guard allowSystemFallback,
                  !lock.withLock({ overflow || terminalFailure != nil }) else {
                lock.withLock { terminalFailure = terminalFailure ?? .recognizerFailed }
                diagnostics?.voiceFailed(reason: .recognizerFailed)
                finishTranscripts(decoderFailed: true); return healthy
            }
            do {
                guard await SystemSpeechAuthorizationProvider.requestAppleAccess() else { throw VoiceSessionError.failure(.speechPermissionDenied) }
                let apple = try StreamingSpeechRecognizerTranscriber(locale: locale, diagnostics: diagnostics)
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
                diagnostics?.voiceFailed(reason: .recognizerFailed); finishTranscripts(decoderFailed: true)
            }
        }
        return healthy
    }

    deinit {
        // A dropped session must never keep the shared decoder claimed if its
        // consumer forgot finishAudio (pack management would then report a
        // phantom busy). The token fences this call from newer sessions.
        let lease = self.lease
        Task { await lease.sessionEnded(healthy: true) }
    }
}

// MARK: - Production wiring

/// One mounted WhisperKit instance. `@unchecked Sendable` on purpose: the
/// residency runtime is its single owner and serializes every `transcribe` /
/// `unmount` call (the decoder is not thread-safe).
struct WhisperKitRecognitionModel: SpeechRecognitionModelInstance, @unchecked Sendable {
    let kit: WhisperKit
    let identity: String

    func transcribe(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [String] {
        let options = DecodingOptions(language: decoding.languageCode, detectLanguage: decoding.detectLanguage,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        return try await kit.transcribe(audioArray: audio, decodeOptions: options).map(\.text)
    }

    func unmount() async {
        await kit.unloadModels()
    }
}

extension SpeechRecognitionRuntime {
    /// The single production runtime. The store singleton is process-wide, so
    /// dictation and continuous voice share this exact warm lease.
    static let live = SpeechRecognitionRuntime(dependencies: .whisperLive())
}

extension SpeechRecognitionRuntime.Dependencies {
    /// Production seams: bundled manifest identity, verified file lease +
    /// WhisperKit mount, store release, and the pack-management handshake.
    static func whisperLive() -> SpeechRecognitionRuntime.Dependencies {
        SpeechRecognitionRuntime.Dependencies(
            installedIdentity: { await WhisperModelStore.shared.installedIdentity() },
            load: {
                let (leaseID, folder) = try await WhisperModelStore.shared.acquire(resident: true)
                do {
                    try Task.checkCancellation()
                    let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.appendingPathComponent("model").path,
                        tokenizerFolder: folder.appendingPathComponent("tokenizer"), verbose: false, prewarm: false, load: true, download: false))
                    try Task.checkCancellation()
                    // The store's folder name is "<manifest id>-<revision>", the
                    // exact identity the runtime compares against installed.
                    return SpeechRecognitionRuntime.Loaded(
                        model: WhisperKitRecognitionModel(kit: kit, identity: folder.lastPathComponent),
                        leaseID: leaseID)
                } catch {
                    await WhisperModelStore.shared.release(leaseID)
                    throw error
                }
            },
            releaseLease: { leaseID in await WhisperModelStore.shared.release(leaseID) },
            installResidencyHook: { runtime in
                await WhisperModelStore.shared.setResidentReleaser { await runtime.releaseForModelManagement() }
            })
    }
}
#endif

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
    /// Recoverable local failures. `sentenceTooLong` reports that one whole
    /// sentence exceeds the model's real native input/context limit (or the
    /// pre-existing 4096-character request bound) — the text is preserved
    /// untouched and nothing is truncated, fragmented or partially
    /// synthesized.
    enum Failure: Error {
        case unsupportedDevice, voice, language, invalidAudio, sentenceTooLong
    }
    private let engine = LocalSpeechInferenceOwner()

    /// Local PCM travels in far larger pieces than the shared 4 KiB cloud
    /// target: one native MOSS frame is ~80 ms (7.7 KiB at 48 kHz) and the
    /// player must never be fed a single frame at a time.
    fileprivate static let pcmSliceBytes = 32_768
    /// Bounded lead for the local producer. The shared default channel holds
    /// only 8 × 4 KiB (~0.33 s), which cannot cover one slow generative frame;
    /// 1 MiB of s16le mono is ~10.9 s at 48 kHz — enough for generation to run
    /// ahead of playback while memory stays small and cancellation latency is
    /// still one channel close away.
    private static let channelSlotCapacity = 256
    private static let channelByteCapacity = 1024 * 1024

    func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make(
            slotCapacity: Self.channelSlotCapacity, byteCapacity: Self.channelByteCapacity)
        let producer = Task { await engine.enqueue(request, sender: sender) }
        sender.attach(producer)
        return stream
    }
    func endSession(_ id: UUID) async { await engine.endSession(id) }

    /// Foreground residency ends (background/inactive). Only releases an idle
    /// engine: a run that still owns the model keeps it mounted.
    func setForeground(_ isForeground: Bool) async { await engine.setForeground(isForeground) }
    /// Pack replacement/deletion handshake. The caller has already joined the
    /// stopped session, so the lease can be released even though a small pack
    /// is normally kept warm.
    func releaseForPackManagement() async { await engine.releaseForPackManagement() }
    func handleMemoryWarning() async { await engine.releaseForMemoryPressure() }

    // Internal pure seams for the same divider and budget used by the private
    // inference owner. Tests need no model mount or access to that actor.
    static func mossDividedBlocks(_ text: String, fits: (String) -> Bool) -> [String] {
        LocalSpeechInferenceOwner.mossDividedBlocks(text, fits: fits)
    }

    static func mossEstimatedFramesFit(_ text: String, hasCJK: Bool, contextLength: Int) -> Bool {
        LocalSpeechInferenceOwner.mossEstimatedFramesFit(text, hasCJK: hasCJK, contextLength: contextLength)
    }

    /// Load-validation hook: acquire a store lease (byte verification runs
    /// inside), load the engine, and resolve the selection voice's reference
    /// asset when it declares one. Uses a private engine instance so a probe
    /// never disturbs an in-flight session. Simulator cannot host these packs.
    nonisolated static func validateLocalPack(modelID: String, voiceID: String?) async -> LocalPackValidation {
        #if targetEnvironment(simulator)
        return .failed
        #else
        return await LocalSpeechInferenceOwner().probe(modelID: modelID, voiceID: voiceID)
        #endif
    }
}

/// Sending into the shared speech channel must be cooperative with task
/// cancellation.
///
/// `TTSAudioChunkStream.Sender.send` parks a producer on a plain continuation
/// while the queue is full; that park does not observe task cancellation, and
/// only closing the channel (`finish`) wakes it. A consumer that stops without
/// draining the channel would otherwise strand the producer, and the owner's
/// `enqueue`/`endSession` join of that task would never return — every later
/// utterance then hangs before the model is even mounted. Closing our own
/// channel from the cancellation handler wakes the park (chunks already queued
/// stay available to a live consumer; the producer throws `.cancelled`).
enum CancellableSpeechSend {
    static func send(_ chunk: TTSAudioChunk, sender: TTSAudioChunkSender) async throws {
        try await withTaskCancellationHandler {
            try await sender.send(chunk)
        } onCancel: {
            sender.finish(throwing: TTSSynthesisError.cancelled)
        }
    }
}

/// Foreground residency policy for the enhanced local voice pack.
///
/// The default pack is small (368.7 MB MOSS nano) and expensive to mount, so a
/// successfully mounted engine stays warm across ordinary stop/end/voice
/// changes while the app is in the foreground. The legacy 2.5 GB CustomVoice
/// pack is deliberately not pinned by this policy. Real memory pressure, pack
/// switching and leaving the foreground still release the engine.
enum LocalSpeechResidencyPolicy {
    /// Upper bound for a pack kept warm between utterances. Sized for the
    /// small default pack only; large legacy packs keep the previous release
    /// behavior.
    static let warmRetentionByteLimit: Int64 = 512 * 1024 * 1024

    static func retainsWarmModel(byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= warmRetentionByteLimit
    }
    /// Ordinary session end (stop or natural finish): a small pack stays
    /// mounted, a large one is released.
    static func unloadsAfterSessionEnd(byteCount: Int64?, isForeground: Bool = true) -> Bool {
        if !isForeground { return true }
        guard let byteCount else { return false }
        return !retainsWarmModel(byteCount: byteCount)
    }
    /// Background/inactive idle release never takes the model from a run that
    /// still owns it.
    static func releasesOnIdleLifecycle(hasActiveRun: Bool) -> Bool { !hasActiveRun }
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
    private var isForeground = true
    /// Validated reference voices, keyed by voice id + asset digest. Cleared
    /// with the model lease so a remount can never reuse stale codes.
    private var references: [String: MossTTSNanoReference] = [:]

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
        // A finished or stopped utterance keeps a small warm pack mounted so
        // the next utterance reuses it instead of paying the 368.7 MB mount
        // again. Large legacy packs keep the previous release behavior.
        if LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: lease?.model.byteCount, isForeground: isForeground) {
            await unload(reason: isForeground ? "sessionEndLargePack" : "backgroundSessionEnd")
        }
    }

    /// Remember background retirement even when a run still owns the engine.
    /// Its final endSession releases the model after playback has safely joined.
    func setForeground(_ value: Bool) async {
        isForeground = value
        guard !value,
              LocalSpeechResidencyPolicy.releasesOnIdleLifecycle(hasActiveRun: active != nil || sessionID != nil) else { return }
        await unload(reason: "idleLifecycle")
    }

    func releaseForPackManagement() async {
        generation &+= 1
        let owner = generation
        let previous = active
        previous?.cancel()
        if let previous { await previous.value }
        guard owner == generation else { return }
        active = nil
        sessionID = nil
        await unload(reason: "packManagement")
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
        await unload(reason: "memoryPressure")
    }

    private func unload(reason: String) async {
        guard loaded != nil || lease != nil else { return }
        let wasQwen = if case .qwen? = loaded { true } else { false }
        loaded = nil
        references = [:]
        if wasQwen {
            do { try Qwen3TTSModel.reclaimGenerationCache() }
            catch { FloeLogger(category: .providers).warning("localSpeechCacheReclaimFailed") }
        }
        if let lease { self.lease = nil; await LocalSpeechModelStore.shared.release(lease.id) }
        FloeLogger(category: .providers).debug("localSpeechUnload reason=\(reason)")
    }

    private func load(_ request: TTSSynthesisRequest) async throws -> Model {
        if let lease, lease.model.id == request.modelID, let loaded { return loaded }
        await unload(reason: "modelSwitch")
        let acquired = try await LocalSpeechModelStore.shared.acquire(request.modelID)
        do {
            try Task.checkCancellation()
            let started = Date()
            let result: Model
            switch acquired.model.engine {
            case "qwen3TTS":
                guard let tokenizer = acquired.model.tokenizerRelativePath else { throw LocalSpeechModelStore.Failure.corrupt }
                result = .qwen(try Qwen3TTSModel.fromLocal(modelDirectory: acquired.directory,
                    tokenizerDirectory: acquired.directory.appendingPathComponent(tokenizer), wiredMemoryPolicy: .none))
            case "mossTTSNano": result = .moss(try MossTTSNanoModel(modelDirectory: acquired.directory, computeUnits: .cpuOnly))
            default: throw LocalSpeechModelStore.Failure.unavailable
            }
            try Task.checkCancellation()
            loaded = result
            lease = acquired
            // Diagnostics only (no user-facing progress): a cold mount is the
            // dominant first-audio cost, so its duration must be observable.
            FloeLogger(category: .providers).debug(
                "localSpeechMount engine=\(acquired.model.engine) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return result
        } catch {
            await LocalSpeechModelStore.shared.release(acquired.id)
            throw error
        }
    }

    private func render(_ request: TTSSynthesisRequest, sender: TTSAudioChunkSender) async {
        let renderStarted = Date()
        var firstChunkLogged = false
        do {
            #if targetEnvironment(simulator)
            throw LocalSpeechRuntime.Failure.unsupportedDevice
            #else
            guard request.provider == .onDevice,
                  !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TTSSynthesisError.invalidConfiguration("Invalid local speech request")
            }
            // Pre-mount recoverable length bound for one utterance request:
            // the complete sentence is preserved untouched (never truncated,
            // summarized or synthesized in pieces) and no model work starts.
            guard request.text.count <= 4_096 else { throw LocalSpeechRuntime.Failure.sentenceTooLong }
            let model = try await load(request)
            guard let specification = lease?.model,
                  let voice = specification.voices.first(where: { $0.id == request.voiceID }) else {
                throw LocalSpeechRuntime.Failure.voice
            }
            if let language = request.language, !voice.languages.contains(language) { throw LocalSpeechRuntime.Failure.language }
            let normalizer = try LocalSpeechPCMNormalizer(outputRate: request.format.sampleRate)
            var sequence = 0
            var totalBytes = 0
            // The upper layers now submit ONE complete sentence per request,
            // so the sentence reaches the model whole — never re-fragmented
            // here. Hard capacity stays with the native guards: MOSS checks
            // real prompt rows + maxFrames against the pack's actual
            // contextLength BEFORE generating (contextExceeded) and refuses
            // silently truncating audio (generationLimit); both surface as
            // the recoverable sentenceTooLong. The Qwen runtime caps
            // generation at six codec frames per real text token itself.
            let hasCJK = TTSSpeechBudget.hasCJKCharacter(request.text)
            let languageTag: String
            if let explicit = request.language { languageTag = explicit }
            else {
                // Requests now arrive one complete sentence at a time, so
                // detection must stay anchored to the SELECTED voice: an
                // embedded English sentence inside a Chinese answer keeps
                // the voice's primary tag (the pinned contract's mixed
                // zh/en guidance) instead of flipping conditioning
                // mid-answer. A detected language the voice does not
                // declare is never used.
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(request.text)
                let detected = recognizer.dominantLanguage?.rawValue.split(separator: "-").first.map(String.init)
                languageTag = detected.flatMap { voice.languages.contains($0) ? $0 : nil } ?? voice.languages.first ?? "zh"
            }
            for text in [request.text] {
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
                        if !data.isEmpty, !firstChunkLogged {
                            firstChunkLogged = true
                            Self.logFirstChunk(since: renderStarted)
                        }
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
                    // A published reference voice contributes its validated codec
                    // codes; the catalog default timbre passes nil. Any envelope,
                    // size or hash mismatch fails closed before synthesis.
                    let reference = try referenceVoice(for: voice)
                    // Frame budget per BLOCK, sized against the pack's REAL
                    // contextLength with measured-rate margins
                    // (TTSSpeechBudget). The native actual-row context check
                    // remains authoritative and fails before any audio;
                    // reaching maxFrames without end-of-speech is a loud
                    // generationLimit, never a silent truncation.
                    let contextLength = await moss.configuration.contextLength
                    // A fused Markdown answer (independent list items and
                    // paragraphs with no terminal punctuation) can exceed the
                    // pack's real context as ONE request even though every
                    // line is a complete standalone unit. Divide only at
                    // SEMANTIC boundaries (blank-line paragraphs, then
                    // complete list-item lines) so each MOSS call stays a
                    // whole, natural unit: no mid-sentence cuts, no mid-URL
                    // or mid-number cuts, no softwrap splits, ordered,
                    // lossless, duplicate-free.
                    let blocks = Self.mossDividedBlocks(text) { block in
                        Self.mossEstimatedFramesFit(block, hasCJK: hasCJK, contextLength: contextLength)
                    }
                    for block in blocks {
                        try Task.checkCancellation()
                        let maxFrames = TTSSpeechBudget.mossMaxFrames(
                            contextLength: contextLength,
                            characterCount: block.count, hasCJK: hasCJK)
                        let session = moss.synthesizeStreamSession(text: block, reference: reference,
                            options: .init(maxFrames: maxFrames, seed: 0))
                        do {
                          for try await chunk in session.stream {
                            try Task.checkCancellation()
                            let data = try normalizer.convert(chunk.mono, sampleRate: 48_000)
                            if !data.isEmpty, !firstChunkLogged {
                                firstChunkLogged = true
                                Self.logFirstChunk(since: renderStarted)
                            }
                            try await send(data, request: request, sequence: &sequence, total: &totalBytes, sender: sender)
                          }
                          await session.waitForCompletion()
                        } catch { await session.cancelAndWait(); throw error }
                        // Between blocks the same stream continues: the
                        // player keeps consuming (bounded supply/backpressure
                        // upstream), so generation of block N+1 overlaps the
                        // tail of block N exactly like the standalone
                        // sentence pipeline.
                    }
                }
            }
            let tail = try normalizer.finish()
            try await send(tail, request: request, sequence: &sequence, total: &totalBytes, sender: sender)
            guard totalBytes > 0 else { throw LocalSpeechRuntime.Failure.invalidAudio }
            try await CancellableSpeechSend.send(TTSAudioChunk(sessionID: request.sessionID,
                segmentIndex: request.segmentIndex, sequence: sequence, pcm: Data(),
                sampleRate: request.format.sampleRate, isFinal: true), sender: sender)
            #endif
            sender.finish()
        } catch {
            // Local model errors may contain input text or file paths. Only
            // app-authored fixed categories cross into normal presentation.
            // A cancelled utterance never discards a successfully mounted
            // pack: the model stays warm for the next answer and for a voice
            // change. Real failures fall back to releasing it.
            if !(error is CancellationError) && !Task.isCancelled {
                await unload(reason: "renderFailure")
            }
            if error is CancellationError || Task.isCancelled { sender.finish(throwing: TTSSynthesisError.cancelled) }
            else if let failure = error as? LocalSpeechModelStore.Failure { sender.finish(throwing: failure) }
            else if let failure = error as? LocalSpeechRuntime.Failure { sender.finish(throwing: failure) }
            else if let native = error as? MossTTSNanoError {
                // The native context/frame guards are the model's own hard
                // limits: contextExceeded fires BEFORE any generation and
                // generationLimit is a loud pre-END failure, never a silent
                // truncation. Both are recoverable "sentence too long".
                switch native {
                case .contextExceeded, .generationLimit:
                    sender.finish(throwing: LocalSpeechRuntime.Failure.sentenceTooLong)
                default:
                    sender.finish(throwing: LocalSpeechRuntime.Failure.invalidAudio)
                }
            }
            else { sender.finish(throwing: LocalSpeechRuntime.Failure.invalidAudio) }
        }
    }

    /// Resolve the selection voice's reference codes (bundled or downloaded),
    /// validating hash and envelope every mount; cache per revision+digest.
    private func referenceVoice(for voice: LocalSpeechModel.Voice) throws -> MossTTSNanoReference? {
        guard let asset = voice.reference else { return nil }
        let key = voice.id + "@" + asset.sha256
        if let cached = references[key] { return cached }
        guard let directory = lease?.directory,
              let codes = try? LocalSpeechVoiceReference.load(reference: asset, modelDirectory: directory)
        else { throw LocalSpeechRuntime.Failure.voice }
        guard let reference = try? MossTTSNanoReference(codes: codes) else { throw LocalSpeechRuntime.Failure.voice }
        references[key] = reference
        return reference
    }

    /// One-shot load-validation for the migration hook. Never touches `loaded`
    /// or `lease`; only reports the outcome.
    func probe(modelID: String, voiceID: String?) async -> LocalPackValidation {
        #if targetEnvironment(simulator)
        return .failed
        #else
        let acquired: LocalSpeechModelStore.Lease
        do { acquired = try await LocalSpeechModelStore.shared.acquire(modelID) }
        catch let failure as LocalSpeechModelStore.Failure {
            switch failure {
            case .busy, .memory, .thermal: return .deferred
            case .unavailable, .corrupt, .space: return .failed
            }
        } catch { return .deferred }
        let result = Self.loadEngine(acquired: acquired, voiceID: voiceID)
        await LocalSpeechModelStore.shared.release(acquired.id)
        return result
        #endif
    }

    private static func loadEngine(acquired: LocalSpeechModelStore.Lease, voiceID: String?) -> LocalPackValidation {
        switch acquired.model.engine {
        case "mossTTSNano":
            do {
                _ = try MossTTSNanoModel(modelDirectory: acquired.directory, computeUnits: .cpuOnly)
                if let voice = acquired.model.voices.first(where: { $0.id == voiceID }), let asset = voice.reference {
                    guard let codes = try? LocalSpeechVoiceReference.load(reference: asset, modelDirectory: acquired.directory),
                          (try? MossTTSNanoReference(codes: codes)) != nil else { return .failed }
                }
                return .passed
            } catch { return .failed }
        case "qwen3TTS":
            guard let tokenizer = acquired.model.tokenizerRelativePath else { return .failed }
            do {
                _ = try Qwen3TTSModel.fromLocal(modelDirectory: acquired.directory,
                    tokenizerDirectory: acquired.directory.appendingPathComponent(tokenizer), wiredMemoryPolicy: .none)
                return .passed
            } catch { return .failed }
        default: return .failed
        }
    }

    private static func logFirstChunk(since started: Date) {
        // Diagnostics only: first generated chunk latency is the second half of
        // first-audio time (mount is logged separately).
        FloeLogger(category: .providers).debug(
            "localSpeechFirstChunk ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    private func send(_ data: Data, request: TTSSynthesisRequest, sequence: inout Int,
                      total: inout Int, sender: TTSAudioChunkSender) async throws {
        total += data.count
        guard total <= 8 * 1024 * 1024 else { throw TTSSynthesisError.streamTruncated(provider: .onDevice) }
        let sliceBytes = LocalSpeechRuntime.pcmSliceBytes
        for offset in stride(from: 0, to: data.count, by: sliceBytes) {
            try Task.checkCancellation()
            let end = min(data.count, offset + sliceBytes)
            try await CancellableSpeechSend.send(TTSAudioChunk(sessionID: request.sessionID,
                segmentIndex: request.segmentIndex, sequence: sequence,
                pcm: data.subdata(in: offset..<end), sampleRate: request.format.sampleRate), sender: sender)
            sequence += 1
        }
    }
    private static func qwenLanguage(_ tag: String) -> String {
        ["zh":"chinese", "en":"english", "de":"german", "it":"italian", "pt":"portuguese", "es":"spanish", "ja":"japanese", "ko":"korean", "fr":"french", "ru":"russian"][tag] ?? tag
    }

    /// Estimated speech frames for one block at the measured slowest script
    /// rate (plus the EOS margin). Uses ONLY the published TTSSpeechBudget
    /// curves — no invented character caps.
    static func mossEstimatedFrames(_ text: String, hasCJK: Bool) -> Int {
        Int((Double(text.count) * TTSSpeechBudget.mossFramesPerCharacter(hasCJK: hasCJK)).rounded(.up))
            + TTSSpeechBudget.mossEndOfSpeechMarginFrames
    }

    /// True when one block's estimated frames fit the pack's real context
    /// alongside the fixed template reservation and the safety margin the
    /// frame budget never claims. The native actual-row check stays
    /// authoritative; this only decides where a fused answer MAY be divided.
    static func mossEstimatedFramesFit(_ text: String, hasCJK: Bool, contextLength: Int) -> Bool {
        mossEstimatedFrames(text, hasCJK: hasCJK)
            + TTSSpeechBudget.mossTemplateRowsUpperBound
            + TTSSpeechBudget.mossContextSafetyRows
            <= contextLength
    }

    /// Divides one fused synthesis block ONLY at semantic boundaries, and
    /// only when the whole block does not fit the pack budget:
    /// 1. blank-line paragraph boundaries (always safe);
    /// 2. complete standalone list-item lines (a leading Markdown bullet,
    ///    enumerator or backtick-introduced item) — an independent complete
    ///    unit by construction.
    /// A line that is none of those (a softwrapped prose sentence, a URL, a
    /// decimal) is NEVER cut: an over-budget single line passes through
    /// whole and the native guard fails it loudly — no silent mid-sentence
    /// chop ever happens here. Division preserves complete ordered coverage:
    /// every content line is kept exactly once, in order.
    static func mossDividedBlocks(
        _ text: String,
        fits: (String) -> Bool
    ) -> [String] {
        guard !fits(text) else { return [text] }
        var divided: [String] = []
        for paragraph in splitAtParagraphBoundaries(text) {
            if fits(paragraph) {
                divided.append(paragraph)
                continue
            }
            // An over-budget paragraph of standalone list items divides at
            // item boundaries; anything else passes through whole — the
            // native context check fails it loudly. Semantic completeness
            // always beats forced fitting: never a mid-sentence cut.
            divided.append(contentsOf: splitAtListItemLines(paragraph))
        }
        return divided.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Blank-line paragraph split with complete ordered coverage: every
    /// content line is kept exactly once, in order (separator blank lines
    /// ride with the preceding block and are formatting-only).
    private static func splitAtParagraphBoundaries(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                // A blank line ends the current paragraph; the separator
                // newlines belong to the boundary and ride with the block.
                current += "\n"
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current += current.isEmpty ? String(line) : "\n" + line
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }

    /// Line split at standalone list-item boundaries. Only lines that BEGIN
    /// a new semantic item divide a block; a continuation line (softwrap,
    /// URL, decimal, plain prose) never does. Complete ordered coverage:
    /// every line is kept exactly once, in order.
    private static func splitAtListItemLines(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let startsItem = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("• ") || trimmed.hasPrefix("· ")
                || (trimmed.first?.isNumber == true && trimmed.dropFirst().first == ".")
                || trimmed.hasPrefix("`")
            if startsItem, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(current)
                current = String(line)
            } else {
                current += current.isEmpty ? String(line) : "\n" + line
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result.count > 1 ? result : [text]
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

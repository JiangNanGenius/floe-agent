// FloeApp — Ordered synthesis into the continuous session's AEC output.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeProviders

/// Synthesis completion only closes a unit's input. The voice coordinator
/// owns real playback completion and records what actually reached the speaker.
@MainActor
final class ContinuousVoiceSpeechBridge {
    typealias Synthesize = @MainActor (VoiceConversationSpeechUnit) -> TTSAudioChunkStream

    private weak var output: (any VoiceConversationSpeechOutput)?
    private let synthesize: Synthesize
    private let onFailure: @MainActor (Error) -> Void
    private let onRoundEnded: @MainActor (UUID) -> Void
    private var eventsTask: Task<Void, Never>?
    private var synthesisTask: Task<Void, Never>?
    private var activeRound: VoiceConversationRoundToken?
    private var activeUnitID: UUID?
    private var queue: [VoiceConversationSpeechUnit] = []
    private var lastQueuedIndex = -1
    private var producedUnits = 0
    private var queuedUnits = 0
    private var expectedUnits: Int?
    private var roundInputEnded = false
    private var generation: UInt64 = 0

    enum Failure: Error {
        case invalidAudio
        case emptyAudio
        case truncatedAudio
        case queueFull
        case inconsistentRound
    }

    init(
        output: any VoiceConversationSpeechOutput,
        synthesize: @escaping Synthesize,
        onFailure: @escaping @MainActor (Error) -> Void,
        onRoundEnded: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.output = output
        self.synthesize = synthesize
        self.onFailure = onFailure
        self.onRoundEnded = onRoundEnded
    }

    func connect() {
        guard eventsTask == nil, let output else { return }
        let events = output.speechEvents
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.receive(event)
            }
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        invalidateRound()
    }

    private func invalidateRound() {
        generation &+= 1
        let ended = activeRound?.id
        synthesisTask?.cancel()
        synthesisTask = nil
        activeUnitID = nil
        queue.removeAll(keepingCapacity: true)
        activeRound = nil
        expectedUnits = nil
        producedUnits = 0
        queuedUnits = 0
        roundInputEnded = false
        lastQueuedIndex = -1
        if let ended { onRoundEnded(ended) }
    }

    private func receive(_ event: VoiceConversationSpeechEvent) {
        switch event {
        case .roundStarted(let token):
            invalidateRound()
            activeRound = token
        case .unitQueued(let unit):
            guard unit.token == activeRound else { return }
            guard unit.index > lastQueuedIndex else { return }
            guard queue.count < 64,
                  queue.reduce(unit.text.count, { $0 + $1.text.count }) <= 64_000 else {
                fail(Failure.queueFull)
                return
            }
            lastQueuedIndex = unit.index
            queuedUnits += 1
            queue.append(unit)
            pump()
        case .roundTextCompleted(let token, let unitCount):
            guard token == activeRound else { return }
            guard unitCount >= producedUnits, unitCount == queuedUnits else {
                fail(Failure.inconsistentRound)
                return
            }
            expectedUnits = unitCount
            finishRoundInputIfReady()
        case .outputStopped(let token, _):
            if token == activeRound { invalidateRound() }
        case .outputDrained(let token):
            if token == activeRound { invalidateRound() }
        case .unitProgress, .unitCompleted, .outputPaused, .outputResumed:
            break
        }
    }

    private func pump() {
        guard synthesisTask == nil, !queue.isEmpty, activeRound != nil else { return }
        let unit = queue.removeFirst()
        let attempt = generation
        activeUnitID = unit.id
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                var carry = Data()
                var byteCount = 0
                var lastSequence = -1
                var finalSeen = false
                var sampleRate: Int?
                let chunks = self.synthesize(unit)
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    guard self.isCurrent(unit, attempt: attempt) else { return }
                    guard chunk.sessionID == unit.token.id,
                          chunk.segmentIndex == unit.index else { continue }
                    guard chunk.sequence > lastSequence else { continue }
                    lastSequence = chunk.sequence
                    guard !finalSeen, chunk.pcm.count <= 256 * 1_024,
                          (8_000...192_000).contains(chunk.sampleRate),
                          sampleRate == nil || sampleRate == chunk.sampleRate else {
                        throw Failure.invalidAudio
                    }
                    sampleRate = chunk.sampleRate
                    byteCount += chunk.pcm.count
                    guard byteCount <= 8 * 1_024 * 1_024 else { throw Failure.invalidAudio }
                    carry.append(chunk.pcm)
                    let usable = carry.count - carry.count % 2
                    if usable > 0 {
                        let samples = Self.decodePCM16(carry.prefix(usable))
                        carry = Data(carry.dropFirst(usable))
                        let audio = VoiceConversationAudioChunk(
                            samples: samples, channelCount: 1, sampleRate: Double(chunk.sampleRate)
                        )
                        while self.isCurrent(unit, attempt: attempt) {
                            try Task.checkCancellation()
                            guard let output = self.output else { return }
                            switch output.appendAudio(audio, to: unit) {
                            case .accepted:
                                break
                            case .rejectedStale:
                                return
                            case .rejectedInvalidFormat:
                                throw Failure.invalidAudio
                            case .rejectedOverCapacity:
                                // Preserve the same chunk while the real
                                // player drains. Never drop or replay it.
                                try await Task.sleep(for: .milliseconds(20))
                                continue
                            }
                            break
                        }
                    }
                    finalSeen = chunk.isFinal
                }
                try Task.checkCancellation()
                guard self.isCurrent(unit, attempt: attempt) else { return }
                guard finalSeen, carry.isEmpty else { throw Failure.truncatedAudio }
                guard byteCount > 0 else { throw Failure.emptyAudio }
                self.output?.endUnit(unit)
                self.producedUnits += 1
                self.activeUnitID = nil
                self.synthesisTask = nil
                self.pump()
                self.finishRoundInputIfReady()
            } catch is CancellationError {
                // A newer round or scene lifecycle owns the next action.
            } catch {
                guard self.isCurrent(unit, attempt: attempt) else { return }
                self.fail(error)
            }
        }
    }

    private func finishRoundInputIfReady() {
        guard let token = activeRound, let expectedUnits,
              producedUnits == expectedUnits, queue.isEmpty,
              activeUnitID == nil, !roundInputEnded else { return }
        roundInputEnded = true
        output?.endRoundAudio(token)
    }

    private func isCurrent(_ unit: VoiceConversationSpeechUnit, attempt: UInt64) -> Bool {
        generation == attempt && activeRound == unit.token && activeUnitID == unit.id
    }

    private func fail(_ error: Error) {
        invalidateRound()
        output?.stopNow()
        onFailure(error)
    }

    private static func decodePCM16(_ bytes: Data.SubSequence) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(bytes.count / 2)
        bytes.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
                samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            }
        }
        return samples
    }
}
#endif

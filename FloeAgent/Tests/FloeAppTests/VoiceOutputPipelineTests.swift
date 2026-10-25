// FloeApp — Focused regressions for the shared continuous-speech output path.
//
// Cause coverage (296 report + native AVAudioConverter probe):
// 1. Resampler identity must be the SOURCE→DESTINATION format pair, never
//    `AVAudioFormat.description` (which embeds the object address, so the old
//    cache never hit and rebuilt a converter per chunk).
// 2. `.none` priming + stable reuse reproduce exact frame counts; tiny chunks
//    must not produce a permanent zero-output silence.
// 3. The coordinator credits the ACTUAL native queued frames, so played-frame
//    offsets stay reachable (a prediction-only ledger never completed a unit).
// 4. A permanently engine-refused chunk fails visibly instead of retrying the
//    same consumed input at audio rate for the whole round.

#if canImport(UIKit)
import Foundation
import AVFoundation
import Testing
import FloeCore
import FloeProviders
@testable import FloeApp

@MainActor
@Suite("Continuous voice output pipeline")
struct VoiceOutputPipelineTests {

    // MARK: - Converter identity and exactness

    @Test("Resampler identity is the semantic format pair, not the object description")
    func converterIdentityIsSemantic() throws {
        let rate = 24_000.0
        let destination = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))
        let peers = (0..<4).map { _ in
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                          channels: 1, interleaved: false)!
        }
        let keys = Set(peers.map {
            VoiceConversationLiveStack.converterCacheKey(from: $0, to: destination)
        })
        #expect(keys.count == 1, "Semantically equal formats must identify one converter")
        #expect(Set(peers.map(\.description)).count == 4,
                "The old key source (description) is address-bearing; this is the confirmed defect")

        let otherRate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                      channels: 1, interleaved: false)!
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        #expect(VoiceConversationLiveStack.converterCacheKey(from: otherRate, to: destination)
                != keys.first)
        #expect(VoiceConversationLiveStack.converterCacheKey(from: peers[0], to: stereo)
                != keys.first)
    }

    @Test("Stable reuse with .none priming reproduces exact frame counts and reuses one converter")
    func converterReuseIsExactAndBounded() throws {
        let stack = VoiceConversationLiveStack(language: .automatic)
        let destination = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        ))

        func source(_ frames: Int) throws -> AVAudioPCMBuffer {
            // A fresh, semantically equal format instance per chunk: the exact
            // shape production produces (old cache missed every time).
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                       frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<frames {
                channel[index] = Float(sin(Double(index) * 0.1)) * 0.1
            }
            return buffer
        }

        // 24k → 48k, the native probe's production-equivalent case.
        var total = 0
        var zeroCalls = 0
        for _ in 0..<10 {
            let out = try #require(stack.convert(try source(1_920), to: destination))
            total += Int(out.frameLength)
            if out.frameLength == 0 { zeroCalls += 1 }
        }
        #expect(total == 38_400, "Stable reuse + .none priming must equal rate arithmetic exactly")
        #expect(zeroCalls == 0)

        // A tiny chunk must not be swallowed: the old fresh-converter path
        // produced 0 output for EVERY 16-frame chunk.
        var tinyTotal = 0
        for _ in 0..<10 {
            let out = try #require(stack.convert(try source(16), to: destination))
            #expect(out.frameLength > 0, "A tiny chunk must produce output, never vanish")
            tinyTotal += Int(out.frameLength)
        }
        #expect(tinyTotal > 0)
        #expect(stack.converterCacheCount == 1,
                "One semantic format pair must retain exactly one converter")

        // Fractional-rate guard: 16k → 44.1k per-chunk rounding differs from a
        // ratio prediction, but every chunk must still convert without loss.
        let fractional = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        for chunkFrames in [961, 192, 4_800] {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                       frameCapacity: AVAudioFrameCount(chunkFrames)))
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<chunkFrames {
                channel[index] = Float(sin(Double(index) * 0.05)) * 0.1
            }
            let capacity = VoiceConversationLiveStack.conversionCapacity(
                sourceFrames: chunkFrames, from: format, to: fractional
            )
            let out = try #require(stack.convert(buffer, to: fractional))
            #expect(out.frameLength > 0)
            #expect(Int(out.frameLength) <= capacity,
                    "The output must fit the declared capacity bound")
        }
    }

    @Test("Fractional downsampling accepts consumed input even when no output is ready")
    func bufferedConversionIsNotFailure() throws {
        let stack = VoiceConversationLiveStack(language: .automatic)
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let destination = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        var frames = 0
        var buffered = 0
        for _ in 0..<20 {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1))
            input.frameLength = 1
            input.floatChannelData?[0][0] = 0.1
            let output = try #require(stack.convert(input, to: destination))
            frames += Int(output.frameLength)
            if output.frameLength == 0 { buffered += 1 }
        }
        #expect(frames == 18)
        #expect(buffered > 0, "Consumed buffered input must remain successful, never replayed")
        #expect(stack.converterCacheCount == 1)
    }

    // MARK: - Coordinator credits ACTUAL native frames

    @Test("Actual scheduled frames, not the ratio prediction, complete units and drain")
    func actualScheduledFramesAreAuthoritative() async {
        let rig = VoiceRig()
        await rig.coordinator.start()
        await rig.say("真实帧优先")
        rig.clock.advance(by: 0.95)
        await rig.settle()
        await rig.confirmFinal("一。二。三。")
        let units = rig.log.units
        #expect(units.count == 3)

        // The sink reports 84 REAL frames for each 100-frame chunk (the
        // resampler priming shortfall the native probe measured). With
        // prediction-only crediting, played frames can never reach the unit
        // offset: no unit completes and the receipt is `interrupted chars=0`
        // (the 296 report).
        rig.stack.scheduledFrameOverride = 84
        for unit in units {
            let chunk = VoiceConversationAudioChunk(
                samples: [Float](repeating: 0.2, count: 100), channelCount: 1, sampleRate: 8_000
            )
            #expect(rig.coordinator.appendAudio(chunk, to: unit) == .accepted)
            rig.coordinator.endUnit(unit)
        }
        if let token = rig.coordinator.currentRound {
            rig.coordinator.endRoundAudio(token)
        }

        rig.stack.stepPlayed(frames: 84)
        await rig.settle()
        #expect(rig.log.completed.map(\.text) == ["一。"])
        #expect(rig.coordinator.completedSpokenText == "一。")

        rig.stack.stepPlayed(frames: 168)
        await rig.settle()
        #expect(rig.log.completed.count == 2)

        rig.stack.stepPlayed(frames: 252)
        await rig.settle(30)
        #expect(rig.log.completed.count == 3)
        #expect(rig.driving.receipts.last?.status == .completed)
        #expect(rig.driving.receipts.last?.spokenText.isEmpty == false)
    }

    // MARK: - Bridge refusal semantics

    private final class Output: VoiceConversationSpeechOutput {
        let speechEvents: AsyncStream<VoiceConversationSpeechEvent>
        let events: AsyncStream<VoiceConversationSpeechEvent>.Continuation
        var completedSpokenText = ""
        var accepted: [(UUID, VoiceConversationAudioChunk)] = []
        /// Number of leading `.rejectedEngine` refusals before accepting.
        var engineRefusals = 0
        var appendAttempts = 0
        var endedUnits = 0
        var endedRounds = 0
        var stops = 0
        init() {
            (speechEvents, events) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
        }
        func appendAudio(_ chunk: VoiceConversationAudioChunk, to unit: VoiceConversationSpeechUnit)
            -> VoiceConversationSpeechAppendResult {
            appendAttempts += 1
            if engineRefusals > 0 {
                engineRefusals -= 1
                return .rejectedEngine
            }
            accepted.append((unit.id, chunk))
            return .accepted
        }
        func endUnit(_ unit: VoiceConversationSpeechUnit) { endedUnits += 1 }
        func endRoundAudio(_ token: VoiceConversationRoundToken) { endedRounds += 1 }
        func pauseOutput() {}
        func resumeOutput() {}
        func stopNow() { stops += 1 }
    }

    private func unit(_ token: VoiceConversationRoundToken) -> VoiceConversationSpeechUnit {
        VoiceConversationSpeechUnit(id: UUID(), token: token, index: 0, text: "你好。")
    }

    private func chunk(_ unit: VoiceConversationSpeechUnit, sequence: Int) -> TTSAudioChunk {
        TTSAudioChunk(sessionID: unit.token.id, segmentIndex: unit.index, sequence: sequence,
                      pcm: Data([0x00, 0x00]), sampleRate: 24_000, isFinal: true)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Expected asynchronous bridge event was not delivered")
    }

    @Test("A permanently engine-refused chunk fails visibly instead of retrying for the round")
    func permanentEngineRefusalFailsVisibly() async throws {
        let output = Output()
        output.engineRefusals = 10_000
        var failure: Error?
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        let speechUnit = unit(token)
        let bridge = ContinuousVoiceSpeechBridge(output: output, synthesize: { requested in
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.attach(Task {
                do {
                    try await sender.send(chunk(requested, sequence: 0))
                    sender.finish()
                } catch { sender.finish(throwing: error) }
            })
            return TTSConfiguredStream(stream: stream, close: { sender.finish() })
        }, onFailure: { failure = $0 }, engineRetryLimit: 3)
        bridge.connect()
        output.events.yield(.roundStarted(token))
        output.events.yield(.unitQueued(speechUnit))
        output.events.yield(.roundTextCompleted(token: token, unitCount: 1))
        try await waitUntil { failure != nil || output.endedRounds == 1 }

        guard case .some(.sinkStalled) = failure as? ContinuousVoiceSpeechBridge.Failure else {
            Issue.record("A permanent engine refusal must fail with sinkStalled, got \(String(describing: failure))")
            return
        }
        #expect(output.stops == 1, "The stalled round must stop the sink")
        #expect(output.appendAttempts == 4, "One bounded retry ladder: limit 3 → 4 attempts")
        #expect(output.accepted.isEmpty)
        #expect(output.endedUnits == 0, "A consumed-but-unplayable unit is never reported as ended")
        bridge.stop()
    }

    @Test("A transient engine refusal (graph restart) recovers and completes the unit")
    func transientEngineRefusalRecovers() async throws {
        let output = Output()
        output.engineRefusals = 2
        var failures = 0
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        let speechUnit = unit(token)
        let bridge = ContinuousVoiceSpeechBridge(output: output, synthesize: { requested in
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.attach(Task {
                do {
                    try await sender.send(chunk(requested, sequence: 0))
                    sender.finish()
                } catch { sender.finish(throwing: error) }
            })
            return TTSConfiguredStream(stream: stream, close: { sender.finish() })
        }, onFailure: { _ in failures += 1 }, engineRetryLimit: 5)
        bridge.connect()
        output.events.yield(.roundStarted(token))
        output.events.yield(.unitQueued(speechUnit))
        output.events.yield(.roundTextCompleted(token: token, unitCount: 1))
        try await waitUntil { output.endedRounds == 1 || failures > 0 }
        #expect(failures == 0)
        #expect(output.accepted.count == 1)
        #expect(output.endedUnits == 1)
        #expect(output.endedRounds == 1)
        bridge.stop()
    }
}
#endif

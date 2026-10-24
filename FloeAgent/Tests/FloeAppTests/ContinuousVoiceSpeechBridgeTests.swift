#if canImport(UIKit)
import Foundation
import os
import Testing
import FloeCore
import FloeProviders
@testable import FloeApp

@MainActor
struct ContinuousVoiceSpeechBridgeTests {
    private final class Output: VoiceConversationSpeechOutput {
        let speechEvents: AsyncStream<VoiceConversationSpeechEvent>
        let events: AsyncStream<VoiceConversationSpeechEvent>.Continuation
        var completedSpokenText = ""
        var accepted: [(UUID, VoiceConversationAudioChunk)] = []
        var capacityRefusals = 0
        var endedUnits = 0
        var endedRounds = 0
        var stops = 0
        init() {
            (speechEvents, events) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
        }
        func appendAudio(_ chunk: VoiceConversationAudioChunk, to unit: VoiceConversationSpeechUnit)
            -> VoiceConversationSpeechAppendResult {
            if capacityRefusals > 0 {
                capacityRefusals -= 1
                return .rejectedOverCapacity
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

    private func chunk(_ unit: VoiceConversationSpeechUnit, _ bytes: [UInt8], sequence: Int,
                       final: Bool = false) -> TTSAudioChunk {
        TTSAudioChunk(sessionID: unit.token.id, segmentIndex: unit.index, sequence: sequence,
                      pcm: Data(bytes), sampleRate: 24_000, isFinal: final)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Expected asynchronous bridge event was not delivered")
    }

    @Test func oddByteChunksAndCapacityWaitPreserveAudioAndDoNotInventPlayback() async throws {
        let output = Output()
        output.capacityRefusals = 1
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        let unit = unit(token)
        var errors = 0
        let bridge = ContinuousVoiceSpeechBridge(output: output, synthesize: { requested in
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.attach(Task {
                do {
                    try await sender.send(chunk(requested, [0x00], sequence: 0))
                    try await sender.send(chunk(requested, [0x80, 0xFF, 0x7F], sequence: 1))
                    try await sender.send(chunk(requested, [], sequence: 2, final: true))
                    sender.finish()
                } catch { sender.finish(throwing: error) }
            })
            return TTSConfiguredStream(stream: stream, close: { sender.finish() })
        }, onFailure: { _ in errors += 1 })
        bridge.connect()
        output.events.yield(.roundStarted(token))
        output.events.yield(.unitQueued(unit))
        output.events.yield(.roundTextCompleted(token: token, unitCount: 1))
        try await waitUntil { output.endedRounds == 1 || errors > 0 }
        #expect(errors == 0)
        #expect(output.accepted.count == 1)
        #expect(output.accepted.first?.1.samples == [-1, Float(32_767) / 32_768])
        #expect(output.endedUnits == 1)
        #expect(output.completedSpokenText.isEmpty)
        bridge.stop()
    }

    @Test func interruptedSourceCannotAppendIntoNewRound() async throws {
        let output = Output()
        let old = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        let fresh = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        let oldUnit = unit(old)
        let newUnit = unit(fresh)
        var oldSource: TTSAudioChunkSender?
        let bridge = ContinuousVoiceSpeechBridge(output: output, synthesize: { requested in
            let (stream, sender) = TTSAudioChunkStream.make()
            if requested.token == old { oldSource = sender }
            else {
                sender.attach(Task {
                    do {
                        try await sender.send(chunk(requested, [0, 0], sequence: 0, final: true))
                        sender.finish()
                    } catch { sender.finish(throwing: error) }
                })
            }
            return TTSConfiguredStream(stream: stream, close: { sender.finish() })
        }, onFailure: { _ in Issue.record("Unexpected synthesis failure") })
        bridge.connect()
        output.events.yield(.roundStarted(old))
        output.events.yield(.unitQueued(oldUnit))
        try await waitUntil { oldSource != nil }
        output.events.yield(.outputStopped(token: old, reason: .bargeIn))
        output.events.yield(.roundStarted(fresh))
        output.events.yield(.unitQueued(newUnit))
        output.events.yield(.roundTextCompleted(token: fresh, unitCount: 1))
        try await waitUntil { output.endedRounds == 1 }
        #expect(oldSource?.sendBounded(chunk(oldUnit, [0xFF, 0x7F], sequence: 0, final: true)) == false)
        oldSource?.finish()
        #expect(output.accepted.map(\.0) == [newUnit.id])
        bridge.stop()
    }

    // MARK: - Supply deadlines (primary-owned bridge init:
    // firstChunkDeadline/nextChunkDeadline, tiny values injected here)

    @Test func sourceThatNeverEmitsFailsOnDeadlineAndClosesSource() async throws {
        let output = Output()
        let closed = OSAllocatedUnfairLock(initialState: false)
        var failures = 0
        let bridge = ContinuousVoiceSpeechBridge(
            output: output,
            synthesize: { _ in
                let (stream, sender) = TTSAudioChunkStream.make()
                return TTSConfiguredStream(stream: stream, close: {
                    closed.withLock { $0 = true }
                    sender.finish()
                })
            },
            onFailure: { _ in failures += 1 },
            onRoundEnded: { _ in },
            firstChunkDeadline: .milliseconds(30),
            nextChunkDeadline: .milliseconds(30))
        bridge.connect()
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        output.events.yield(.roundStarted(token))
        output.events.yield(.unitQueued(unit(token)))
        output.events.yield(.roundTextCompleted(token: token, unitCount: 1))
        try await waitUntil { failures > 0 }
        #expect(closed.withLock { $0 }, "A dead source must be closed on the supply deadline")
        #expect(failures == 1)
        #expect(output.accepted.isEmpty)
        #expect(output.endedRounds == 0)
        bridge.stop()
    }

    @Test func firstChunkInsideDeadlineStillCompletesTheRound() async throws {
        let output = Output()
        var failures = 0
        let bridge = ContinuousVoiceSpeechBridge(
            output: output,
            synthesize: { requested in
                let (stream, sender) = TTSAudioChunkStream.make()
                sender.attach(Task {
                    do {
                        try await Task.sleep(for: .milliseconds(40))
                        try await sender.send(chunk(requested, [0, 0], sequence: 0, final: true))
                        sender.finish()
                    } catch { sender.finish(throwing: error) }
                })
                return TTSConfiguredStream(stream: stream, close: { sender.finish() })
            },
            onFailure: { _ in failures += 1 },
            onRoundEnded: { _ in },
            firstChunkDeadline: .milliseconds(500),
            nextChunkDeadline: .milliseconds(500))
        bridge.connect()
        let token = VoiceConversationRoundToken(id: UUID(), sessionGeneration: 1)
        output.events.yield(.roundStarted(token))
        output.events.yield(.unitQueued(unit(token)))
        output.events.yield(.roundTextCompleted(token: token, unitCount: 1))
        try await waitUntil { output.endedRounds == 1 || failures > 0 }
        #expect(failures == 0)
        #expect(output.endedRounds == 1)
        #expect(output.endedUnits == 1)
        bridge.stop()
    }
}
#endif

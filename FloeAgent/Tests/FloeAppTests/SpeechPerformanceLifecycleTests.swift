// FloeAppTests — Enhanced local speech lifecycle, supply and stall boundaries.
//
// These cover the defects that produced the build290 "minutes-long spinner,
// no audio" and "audible but choppy" reports: a producer parked on a full
// speech channel that ignored cancellation (so the session join never
// returned), unconditional unload on ordinary stop, unbounded first-audio
// waiting, and one-buffer-at-a-time playback scheduling.
#if canImport(UIKit)
import XCTest
import FloeCore
import FloeProviders
@testable import FloeApp

@MainActor
final class SpeechPerformanceLifecycleTests: XCTestCase {
    // MARK: - Channel cancellation boundary

    /// A producer parked on a full channel must finish when its task is
    /// cancelled. This is the exact boundary that wedged build290: the parked
    /// send ignored cancellation, so `LocalSpeechInferenceOwner`'s
    /// `await previous.value` never returned and every later utterance spun
    /// before the model was even mounted.
    func testCancelledParkedProducerAlwaysFinishes() async {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 1, byteCapacity: 4096)
        let session = UUID()
        var outcome = ""
        let producer = Task { @MainActor () -> Void in
            do {
                for sequence in 0..<4 {
                    try await CancellableSpeechSend.send(TTSAudioChunk(
                        sessionID: session, segmentIndex: 0, sequence: sequence,
                        pcm: Data(repeating: 7, count: 1024), sampleRate: 24_000), sender: sender)
                }
                outcome = "completed"
            } catch is CancellationError {
                outcome = "cancelled"
            } catch {
                outcome = (error as? TTSSynthesisError) == .cancelled ? "cancelled" : "other"
            }
        }
        sender.attach(producer)
        // One chunk fits the queue; the producer is parked on the second send.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(producer.isCancelled)

        producer.cancel()
        guard case .value = await Self.bounded({ await producer.value }) else {
            return XCTFail("parked producer did not finish after cancellation")
        }
        XCTAssertEqual(outcome, "cancelled")

        // The channel is terminal for a later consumer as well; nothing can
        // restart playback from queued chunks after the producer gave up.
        let box = SnapshotIteratorBox(stream.makeAsyncIterator())
        guard case .value(let terminal) = await Self.bounded({ await box.drainToTerminal() }) else {
            return XCTFail("channel did not reach a terminal state")
        }
        XCTAssertTrue(terminal)
    }

    /// `ConfiguredTTSSpeechSource`'s segment stream must be terminally closed
    /// by the consumer's exit path, never left for the next utterance to join.
    func testConfiguredStreamCloseIsTerminal() async throws {
        let provider = SlowStubProvider(chunkCount: 32)
        let service = TTSSpeechService(localProvider: provider)
        let request = TTSSynthesisRequest(
            provider: .onDevice, billingRoute: .payAsYouGo,
            modelID: "moss-tts-nano-100m-coreml", voiceID: "serena", text: "你好世界")
        let prepared = TTSConfiguredStream.make(
            request: request, credential: { "" }, service: service)
        let box = SnapshotIteratorBox(prepared.stream.makeAsyncIterator())
        let first = try await box.next()
        XCTAssertEqual(first?.sequence, 0)

        // The consumer stops taking chunks (the old play() path unwound here
        // without closing). The close must be the same explicit exit step.
        prepared.closeStream()
        guard case .value(let terminal) = await Self.bounded({ await box.drainToTerminal() }) else {
            return XCTFail("closed segment stream did not terminate")
        }
        XCTAssertTrue(terminal)
    }

    // MARK: - Playback supply shaping

    func testPrimeBatchRefillAndFinalFlush() throws {
        let rate = 24_000.0
        let supply = try SpeechPlaybackSupply(sampleRate: rate)
        supply.append(Self.pcm(seconds: 0.5, rate: rate))
        XCTAssertNil(supply.takeScheduleFrames(final: false), "below the prime lead")
        XCTAssertFalse(supply.canStartPlayback)

        supply.append(Self.pcm(seconds: 0.8, rate: rate))
        let prime = try XCTUnwrap(supply.takeScheduleFrames(final: false))
        _ = supply.takeBytes(frames: prime)
        XCTAssertEqual(Double(prime) / rate, 1.2, accuracy: 0.02)
        XCTAssertFalse(supply.canStartPlayback, "playback starts only after scheduling")
        supply.didSchedule(frames: prime)
        XCTAssertTrue(supply.canStartPlayback)
        supply.markPrimed()

        // Steady state: one bounded batch per hand-off, never the whole
        // pending queue at once.
        supply.append(Self.pcm(seconds: 1.4, rate: rate))
        let batch = try XCTUnwrap(supply.takeScheduleFrames(final: false))
        _ = supply.takeBytes(frames: batch)
        XCTAssertEqual(Double(batch) / rate, 0.8, accuracy: 0.02)

        // Starvation gap: playback drains, then audio resumes only after a
        // full refill batch so output is continuous rather than chopped.
        supply.didPlay(frames: prime + batch)
        XCTAssertTrue(supply.isStarving)
        // Post-starvation hysteresis is real: the refill target (1.0 s) is
        // larger than a steady batch, so 0.7 s and then 0.9 s pending are not
        // scheduled as a trickle.
        XCTAssertNil(supply.takeScheduleFrames(final: false))
        supply.append(Self.pcm(seconds: 0.2, rate: rate))
        XCTAssertNil(supply.takeScheduleFrames(final: false), "0.9 s is still below the refill target")
        supply.append(Self.pcm(seconds: 0.2, rate: rate))
        let refill = try XCTUnwrap(supply.takeScheduleFrames(final: false))
        _ = supply.takeBytes(frames: refill)
        XCTAssertEqual(Double(refill) / rate, 1.0, accuracy: 0.02)

        // Segment end flushes everything still pending (the lead has room).
        supply.markSegmentFinal()
        supply.append(Self.pcm(seconds: 0.4, rate: rate))
        let tail = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: tail)
        XCTAssertEqual(Double(tail) / rate, 0.5, accuracy: 0.02)
    }

    func testBoundedLeadCarryAndDrain() throws {
        let rate = 48_000.0
        var limits = SpeechPlaybackSupply.Limits.standard
        limits.maxBufferedSeconds = 3.0
        let supply = try SpeechPlaybackSupply(sampleRate: rate, limits: limits)
        supply.didSchedule(frames: Int(2.5 * rate))
        supply.append(Self.pcm(seconds: 2.0, rate: rate))
        supply.markEnded()
        let room = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: room)
        XCTAssertEqual(Double(room) / rate, 0.5, accuracy: 0.02,
                       "the player never holds more than the bounded lead")

        // Odd provider splits carry the dangling byte instead of dropping it.
        let split = try SpeechPlaybackSupply(sampleRate: rate)
        split.append(Data([1, 2, 3]))
        XCTAssertNotNil(split.carry)
        XCTAssertEqual(split.pendingFrames, 1)
        split.append(Data([4]))
        XCTAssertNil(split.carry)
        XCTAssertEqual(split.pendingFrames, 2)

        // Played progress, not scheduling, defines a drained answer.
        let drain = try SpeechPlaybackSupply(sampleRate: rate)
        XCTAssertFalse(drain.isDrained)
        drain.didSchedule(frames: 100)
        XCTAssertFalse(drain.isDrained, "an un-ended answer is never drained")
        drain.markEnded()
        drain.didPlay(frames: 99)
        XCTAssertFalse(drain.isDrained)
        drain.didPlay(frames: 1)
        XCTAssertTrue(drain.isDrained)

        XCTAssertThrowsError(try SpeechPlaybackSupply(sampleRate: 0))
    }

    func testBackgroundSessionEndRetiresEvenTheSmallModel() {
        XCTAssertFalse(LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: 369_000_000, isForeground: true))
        XCTAssertTrue(LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: 369_000_000, isForeground: false))
    }

    func testPlayedCallbacksDoNotDiscardPendingTail() throws {
        let supply = try SpeechPlaybackSupply(sampleRate: 24_000)
        supply.didSchedule(frames: 72_000)
        supply.append(Self.pcm(seconds: 0.5, rate: 24_000))
        supply.markEnded()
        // Several completions may reach the actor before the drain task resumes.
        supply.didPlay(frames: 72_000)
        XCTAssertFalse(supply.isDrained, "unscheduled tail remains audible work")
        let tail = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: tail)
        supply.didSchedule(frames: tail)
        XCTAssertFalse(supply.isDrained)
        supply.didPlay(frames: tail)
        XCTAssertTrue(supply.isDrained)
    }

    func testShortSegmentPrimesOnlyPastItsThreshold() throws {
        let rate = 24_000.0
        let supply = try SpeechPlaybackSupply(sampleRate: rate)
        supply.append(Self.pcm(seconds: 0.5, rate: rate))
        let frames = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: frames)
        supply.didSchedule(frames: frames)
        supply.markSegmentFinal()
        XCTAssertFalse(supply.canStartPlayback, "0.5 s is below the short-segment lead")
        supply.didPlay(frames: frames)
        supply.append(Self.pcm(seconds: 0.2, rate: rate))
        let more = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: more)
        supply.didSchedule(frames: more)
        XCTAssertTrue(supply.canStartPlayback)
    }

    /// The drain loop must never re-check a scheduling predicate: with no
    /// pending audio but unplayed buffers, only the played callback can move
    /// it forward. (A condition that stays true would spin and starve that
    /// very callback on the MainActor.)
    func testDrainHasNoProgressSourceWithoutAPlayedCallback() throws {
        let rate = 24_000.0
        let supply = try SpeechPlaybackSupply(sampleRate: rate)
        supply.append(Self.pcm(seconds: 0.45, rate: rate))
        supply.markEnded()
        var scheduled = 0
        while supply.hasSchedulableAudio {
            let frames = try XCTUnwrap(supply.takeScheduleFrames(final: true))
            _ = supply.takeBytes(frames: frames)
            supply.didSchedule(frames: frames)
            scheduled += frames
        }
        XCTAssertEqual(Double(scheduled) / rate, 0.45, accuracy: 0.02,
                       "a short final batch is scheduled whole")
        XCTAssertEqual(supply.pendingFrames, 0)
        XCTAssertFalse(supply.isDrained)
        XCTAssertFalse(supply.hasSchedulableAudio,
                       "no pending audio: the loop must suspend for a played callback")
        supply.didPlay(frames: scheduled)
        XCTAssertTrue(supply.isDrained)
    }

    /// A full bounded lead blocks further scheduling for the same reason.
    func testFullLeadBlocksSchedulingUntilPlaybackAdvances() throws {
        let rate = 24_000.0
        let supply = try SpeechPlaybackSupply(sampleRate: rate)
        supply.append(Self.pcm(seconds: 3.4, rate: rate))
        supply.markEnded()
        let first = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: first)
        supply.didSchedule(frames: first)
        XCTAssertEqual(Double(first) / rate, 3.0, accuracy: 0.02)
        XCTAssertFalse(supply.canScheduleMore)
        XCTAssertFalse(supply.hasSchedulableAudio, "no lead room: must wait for played progress")
        supply.didPlay(frames: Int(2.0 * rate))
        XCTAssertTrue(supply.hasSchedulableAudio)
        let remaining = try XCTUnwrap(supply.takeScheduleFrames(final: true))
        _ = supply.takeBytes(frames: remaining)
        XCTAssertEqual(Double(remaining) / rate, 0.4, accuracy: 0.03)
        supply.didSchedule(frames: remaining)
        supply.didPlay(frames: Int(1.0 * rate))
        supply.didPlay(frames: remaining)
        XCTAssertTrue(supply.isDrained)
    }

    // MARK: - Residency policy

    func testResidencyPolicyDecisionTable() {
        // The default MOSS nano pack (368.7 MB) stays warm across utterances.
        XCTAssertTrue(LocalSpeechResidencyPolicy.retainsWarmModel(byteCount: 368_700_000))
        XCTAssertFalse(LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: 368_700_000))
        // The legacy 2.5 GB CustomVoice pack is never pinned by this policy.
        XCTAssertFalse(LocalSpeechResidencyPolicy.retainsWarmModel(byteCount: 2_498_400_000))
        XCTAssertTrue(LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: 2_498_400_000))
        // Nothing mounted means nothing to release.
        XCTAssertFalse(LocalSpeechResidencyPolicy.unloadsAfterSessionEnd(byteCount: nil))
        // Background/inactive release never takes the model from a live run.
        XCTAssertFalse(LocalSpeechResidencyPolicy.releasesOnIdleLifecycle(hasActiveRun: true))
        XCTAssertTrue(LocalSpeechResidencyPolicy.releasesOnIdleLifecycle(hasActiveRun: false))
    }

    // MARK: - Stall surfacing

    func testStallFailuresSurfaceActionablePlaybackKey() {
        XCTAssertEqual(SpeechFailureCopy.key(for: SpeechPlaybackFailure.firstChunkTimeout), "voice.error.playback")
        XCTAssertEqual(SpeechFailureCopy.key(for: SpeechPlaybackFailure.supplyStalled), "voice.error.playback")
        XCTAssertLessThanOrEqual(SpeechSupplyDeadline.firstChunk, .seconds(120))
        XCTAssertLessThanOrEqual(SpeechSupplyDeadline.nextChunk, .seconds(60))
        XCTAssertLessThanOrEqual(SpeechSupplyDeadline.firstPlayout, .seconds(30))
    }

    // MARK: - Helpers

    private static func pcm(seconds: Double, rate: Double) -> Data {
        Data(repeating: 0, count: Int(seconds * rate) * 2)
    }

    private enum Bounded<T: Sendable>: Sendable {
        case value(T)
        case timeout
    }

    /// Bounds an awaited operation so a regression fails instead of hanging the
    /// whole app-hosted test process.
    private static func bounded<T: Sendable>(seconds: Double = 3,
                                             _ operation: @escaping @Sendable () async -> T) async -> Bounded<T> {
        await withTaskGroup(of: Bounded<T>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }
}

/// Single-consumer iterator box for the bounded test waits.
private final class SnapshotIteratorBox: @unchecked Sendable {
    private var iterator: TTSAudioChunkStream.Iterator
    init(_ iterator: TTSAudioChunkStream.Iterator) { self.iterator = iterator }
    func next() async throws -> TTSAudioChunk? { try await iterator.next() }
    /// Consumes until the stream ends or throws; false means "still running".
    func drainToTerminal() async -> Bool {
        do {
            while true {
                if try await next() == nil { return true }
            }
        } catch {
            return true
        }
    }
}

/// Streams `chunkCount` chunks through a deliberately shallow channel so the
/// forwarding producer parks (queue full) exactly like the local model does.
private final class SlowStubProvider: TTSSpeechProviding, @unchecked Sendable {
    private let chunkCount: Int
    init(chunkCount: Int) { self.chunkCount = chunkCount }

    func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 2, byteCapacity: 8_192)
        let task = Task {
            do {
                for sequence in 0..<chunkCount {
                    try await sender.send(TTSAudioChunk(
                        sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                        sequence: sequence, pcm: Data(repeating: 1, count: 1024),
                        sampleRate: 24_000))
                }
                sender.finish()
            } catch {
                sender.finish(throwing: error)
            }
        }
        sender.attach(task)
        return stream
    }
}
#endif

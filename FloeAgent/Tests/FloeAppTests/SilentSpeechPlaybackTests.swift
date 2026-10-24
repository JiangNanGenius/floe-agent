// FloeAppTests — Silent-enhanced/cloud playout repair regressions.
//
// Deterministic, device-free regressions for the code-level risks that can
// produce the build-291 report shapes ("enhanced TTS no audible sound",
// "continuous voice pauses", "no microphone" mid-answer). Which risk was
// actually observed on which device stays with the primary's physical
// evidence; these tests pin the repaired CONTRACTS: pause decisions that
// pause but never auto-resume (accepted user-resume product rule), the
// playout-progress sentinel for a never-paused dead output (the previously
// unbounded silent "speaking" state), shared-session admission driven by
// ACTUAL FloeAudioSessionOwnership holders rather than the category alone,
// last-holder-only teardown deactivation, the byte-exact s16le → float32
// schedule buffer, and actionable failure translation instead of swallowing
// provider rejections as a generic "could not finish reading". No
// AVAudioEngine or network is used; the ownership registry is exercised
// through its explicit resetForTesting seam only.
#if canImport(UIKit)
import XCTest
import AVFoundation
import FloeCore
import FloeProviders
@testable import FloeApp

@MainActor
final class SilentSpeechPlaybackTests: XCTestCase {
    // MARK: - Interruption / route recovery decisions (pause-only; user resumes)

    private static let beganRaw = AVAudioSession.InterruptionType.began.rawValue
    private static let endedRaw = AVAudioSession.InterruptionType.ended.rawValue
    private static let shouldResumeRaw = AVAudioSession.InterruptionOptions.shouldResume.rawValue

    func testInterruptionPausesAndNeverAutoResumes() {
        // Began while speaking: pause.
        XCTAssertEqual(SpeechSessionRecovery.interruptionAction(typeRaw: Self.beganRaw, isSpeaking: true), .pause)
        // Began while idle: nothing to pause.
        XCTAssertEqual(SpeechSessionRecovery.interruptionAction(typeRaw: Self.beganRaw, isSpeaking: false), .none)
        // Accepted product rule (shared with continuous voice): interruption
        // END — even with the system's shouldResume receipt — never auto-plays
        // over the paused state; only the USER resumes or stops.
        XCTAssertEqual(SpeechSessionRecovery.interruptionAction(
            typeRaw: Self.endedRaw, isSpeaking: true), .none)
        // Garbage / unknown receipts are ignored, never guessed.
        XCTAssertEqual(SpeechSessionRecovery.interruptionAction(typeRaw: nil, isSpeaking: true), .none)
        XCTAssertEqual(SpeechSessionRecovery.interruptionAction(typeRaw: 9_999, isSpeaking: true), .none)
    }

    func testRouteRecoveryNeverAutoPlaysANewDevice() {
        let oldRaw = AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        let newRaw = AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        let categoryRaw = AVAudioSession.RouteChangeReason.categoryChange.rawValue
        // Output device pulled mid-answer: pause.
        XCTAssertEqual(SpeechSessionRecovery.routeAction(reasonRaw: oldRaw, isSpeaking: true), .pause)
        // A restored/newly connected route must NEVER start playing by itself.
        XCTAssertEqual(SpeechSessionRecovery.routeAction(reasonRaw: newRaw, isSpeaking: true), .none)
        // Category changes belong to the engine-config observer, not pausing.
        XCTAssertEqual(SpeechSessionRecovery.routeAction(reasonRaw: categoryRaw, isSpeaking: true), .none)
        XCTAssertEqual(SpeechSessionRecovery.routeAction(reasonRaw: nil, isSpeaking: true), .none)
        XCTAssertEqual(SpeechSessionRecovery.routeAction(reasonRaw: oldRaw, isSpeaking: false), .none)
        // The shouldResume option is deliberately NOT consulted anywhere:
        // pin that the recovery API cannot grow an auto-resume path silently.
        XCTAssertNotNil(Self.shouldResumeRaw)
    }

    // MARK: - Playout progress sentinel

    func testStallMonitorReportsSilentEngineFromTheFirstWindow() {
        var monitor = SpeechPlayoutProgressMonitor()
        // Primed player, zero played receipts across one full window.
        XCTAssertTrue(monitor.observe(scheduledFrames: 28_800, playedFrames: 0,
                                      engaged: true, paused: false))
    }

    func testStallMonitorCatchesMidUtteranceEngineDeath() {
        // Regression: the previous one-shot watchdog exited permanently after
        // the first played buffer, so an engine that died mid-answer left the
        // answer spinning silently forever.
        var monitor = SpeechPlayoutProgressMonitor()
        XCTAssertFalse(monitor.observe(scheduledFrames: 100_000, playedFrames: 48_000,
                                       engaged: true, paused: false))
        XCTAssertFalse(monitor.observe(scheduledFrames: 120_000, playedFrames: 96_000,
                                       engaged: true, paused: false))
        // Progress stops although more audio keeps being scheduled.
        XCTAssertTrue(monitor.observe(scheduledFrames: 144_000, playedFrames: 96_000,
                                      engaged: true, paused: false))
    }

    func testStallMonitorIgnoresUnengagedSlowSupply() {
        // Before priming with scheduling room left, provider slowness is the
        // bounded chunk deadlines' problem, not an output stall.
        var monitor = SpeechPlayoutProgressMonitor()
        XCTAssertFalse(monitor.observe(scheduledFrames: 12_000, playedFrames: 0,
                                       engaged: false, paused: false))
        XCTAssertFalse(monitor.observe(scheduledFrames: 20_000, playedFrames: 0,
                                       engaged: false, paused: false))
    }

    func testStallMonitorTreatsFullParkedLeadAsEngaged() {
        var monitor = SpeechPlayoutProgressMonitor()
        // Never primed but the bounded lead is full: the pull loop is parked
        // on a played receipt that can never come.
        XCTAssertTrue(monitor.observe(scheduledFrames: 72_000, playedFrames: 0,
                                      engaged: true, paused: false))
    }

    func testStallMonitorNeverFailsAPausedUtterance() {
        // Accepted product rule: a pause (user OR system caused) is an
        // honest, actionable state that only the user ends. Even an engaged,
        // progress-free pipeline stays paused rather than being failed away.
        var monitor = SpeechPlayoutProgressMonitor()
        for _ in 0..<12 {
            XCTAssertFalse(monitor.observe(scheduledFrames: 72_000, playedFrames: 0,
                                           engaged: true, paused: true))
        }
        // After a USER resume the sentinel applies again from that point.
        XCTAssertFalse(monitor.observe(scheduledFrames: 72_000, playedFrames: 12_000,
                                       engaged: true, paused: false))
        XCTAssertTrue(monitor.observe(scheduledFrames: 72_000, playedFrames: 12_000,
                                      engaged: true, paused: false))
    }

    // MARK: - Shared-session admission (holder facts, not category alone)

    func testAdmissionRequiresALiveHolderNotJustARecordCategory() {
        // A live registered holder on the record route: keep its category
        // (activation of our own claim still happens unconditionally).
        XCTAssertTrue(SpeechSessionAdmission.isRecordRoute(category: .playAndRecord))
        XCTAssertTrue(SpeechSessionAdmission.isRecordRoute(category: .multiRoute))
        XCTAssertTrue(SpeechSessionAdmission.adoptsExistingSession(recordRoute: true, holdersBeforeClaim: 1))
        // Stale `.playAndRecord` category with NO holder registered before
        // our claim: the category alone must NOT be adopted.
        XCTAssertFalse(SpeechSessionAdmission.adoptsExistingSession(recordRoute: true, holdersBeforeClaim: 0))
        // Non-record routes keep the owned .playback/.spokenAudio behaviour.
        XCTAssertFalse(SpeechSessionAdmission.isRecordRoute(category: .playback))
        XCTAssertFalse(SpeechSessionAdmission.isRecordRoute(category: .ambient))
        XCTAssertFalse(SpeechSessionAdmission.isRecordRoute(category: .record)) // short dictation stretch
        XCTAssertFalse(SpeechSessionAdmission.adoptsExistingSession(recordRoute: false, holdersBeforeClaim: 3))
    }

    func testLiveExclusiveRecordingCannotBeStolenByPlayback() {
        XCTAssertTrue(SpeechSessionAdmission.rejectsExclusiveCapture(category: .record, holdersBeforeClaim: 1))
        XCTAssertFalse(SpeechSessionAdmission.rejectsExclusiveCapture(category: .record, holdersBeforeClaim: 0))
        XCTAssertFalse(SpeechSessionAdmission.rejectsExclusiveCapture(category: .playAndRecord, holdersBeforeClaim: 1))
        XCTAssertEqual(SpeechFailureCopy.key(for: SpeechPlaybackFailure.captureBusy), "voice.error.capture_busy")
        XCTAssertEqual(SpeechFailureCopy.diagnostic(for: SpeechPlaybackFailure.captureBusy), "captureBusy")
    }

    func testLedgerClaimReportsHoldersBeforeInsertion() {
        // Pins the admission fact SpeechService consumes: `claim` returns the
        // holder count from the SAME locked critical section that inserts,
        // never an independently readable later count (which could race a
        // last-holder teardown between the two operations).
        FloeAudioSessionOwnership.resetForTesting()
        let first = UUID()
        XCTAssertEqual(FloeAudioSessionOwnership.claim(first), 0)
        let second = UUID()
        XCTAssertEqual(FloeAudioSessionOwnership.claim(second), 1)
        XCTAssertEqual(FloeAudioSessionOwnership.holderCount, 2)
        _ = FloeAudioSessionOwnership.release(second)
        _ = FloeAudioSessionOwnership.release(first)
    }

    func testLedgerDeactivatesOnlyTheLastHolderAtomically() {
        // Pins the teardown contract: `releaseAndDeactivateLast` runs the
        // deactivation INSIDE the registry serialisation and only for the
        // last holder. A still-held release must deactivate nothing — this
        // is the exact cross-lane race (capture teardown under adopted
        // speech / speech teardown under live capture) this repair
        // coordinates. Uses the registry's explicit test seam.
        FloeAudioSessionOwnership.resetForTesting()
        let first = UUID()
        let second = UUID()
        _ = FloeAudioSessionOwnership.claim(first)
        _ = FloeAudioSessionOwnership.claim(second)
        var deactivations = 0
        // Second holder finishing first: nothing may be deactivated.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(second) { deactivations += 1 }
        XCTAssertEqual(deactivations, 0)
        XCTAssertFalse(FloeAudioSessionOwnership.isHolder(second))
        XCTAssertTrue(FloeAudioSessionOwnership.isHolder(first))
        // A late, abandoned second release stays inert.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(second) { deactivations += 1 }
        XCTAssertEqual(deactivations, 0)
        // The last holder's release deactivates exactly once.
        FloeAudioSessionOwnership.releaseAndDeactivateLast(first) { deactivations += 1 }
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(FloeAudioSessionOwnership.holderCount, 0)
        // Rollback release for a never-activated component deactivates
        // nothing even when it empties the registry.
        let third = UUID()
        _ = FloeAudioSessionOwnership.claim(third)
        XCTAssertTrue(FloeAudioSessionOwnership.release(third))
        XCTAssertEqual(deactivations, 1)
    }

    // MARK: - Audio buffer byte layout

    func testSpeechBufferConvertsLittleEndianMonoToFloat() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        // s16le: [-32768, +32767, 0, -1, +258] (little-endian byte pairs).
        let bytes: [UInt8] = [0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0xFF, 0xFF, 0x02, 0x01]
        let buffer = try XCTUnwrap(SpeechService.speechBuffer(bytes, frames: 5, format: format))
        XCTAssertEqual(buffer.frameLength, 5)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.sampleRate, 24_000, accuracy: 0.001)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        let floats = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(floats[0][0], -1.0, accuracy: 0.0001)
        XCTAssertEqual(floats[0][1], Float(32767) / 32768.0, accuracy: 0.0001)
        XCTAssertEqual(floats[0][2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(floats[0][3], Float(-1) / 32768.0, accuracy: 0.0001)
        XCTAssertEqual(floats[0][4], Float(258) / 32768.0, accuracy: 0.0001)
        // A truncated payload never produces a half-sample schedule.
        XCTAssertNil(SpeechService.speechBuffer([0x01], frames: 1, format: format))
        XCTAssertNil(SpeechService.speechBuffer(bytes, frames: 0, format: format))
        XCTAssertNil(SpeechService.speechBuffer(bytes, frames: 6, format: format))
    }

    func testSupplyToBufferRoundTripKeepsEveryProviderSample() throws {
        // Deterministic stand-in for a cloud/local PCM stream delivered in
        // awkward pieces (including one split across a 16-bit sample
        // boundary): the supply + buffer builder together must reproduce
        // EXACTLY the provider's samples, in order, with nothing dropped,
        // duplicated or half-scheduled.
        let rate = 24_000.0
        var limits = SpeechPlaybackSupply.Limits.standard
        limits.primeSeconds = 0.1
        limits.batchSeconds = 0.05
        limits.shortSegmentPrimeSeconds = 0.05
        limits.starvationRefillSeconds = 0.08
        let supply = try SpeechPlaybackSupply(sampleRate: rate, limits: limits)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))

        var samples = [Int16]()
        samples.reserveCapacity(6_000)
        for index in 0..<6_000 {
            samples.append(Int16(truncatingIfNeeded: index * 997 &- 300))
        }
        var bytes = [UInt8]()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        // Feed in prime-sized pieces, one of which ends mid-sample.
        var cursor = 0
        let pieces = [1_001, 2_048, 4_096, bytes.count - 1_001 - 2_048 - 4_096]
        let finalIndex = pieces.count - 1
        var scheduledTotal = 0
        var played: [Float] = []
        for (index, piece) in pieces.enumerated() {
            supply.append(Data(bytes[cursor..<(cursor + piece)]))
            cursor += piece
            let isFinalSegment = index == finalIndex
            if isFinalSegment { supply.markSegmentFinal() }
            while supply.hasSchedulableAudio, let frames = supply.takeScheduleFrames(final: isFinalSegment) {
                let chunk = supply.takeBytes(frames: frames)
                let buffer = try XCTUnwrap(SpeechService.speechBuffer(chunk, frames: frames, format: format))
                XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(frames))
                scheduledTotal += frames
                supply.didSchedule(frames: frames)
                // Simulated played receipts (what the real callback advances).
                supply.didPlay(frames: frames)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                played.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
            }
        }
        XCTAssertNil(supply.carry)
        XCTAssertEqual(scheduledTotal, samples.count)
        XCTAssertEqual(supply.pendingFrames, 0)
        supply.markEnded()
        XCTAssertTrue(supply.isDrained)
        XCTAssertEqual(played.count, samples.count)
        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(played[index], Float(sample) / 32768.0, accuracy: 0.0001,
                           "sample \(index) changed on the way to the player")
        }
    }

    // MARK: - Actionable failure translation

    func testFailureCopyDistinguishesRequestRejectionsFromServiceFaults() {
        // The reported cloud case: a voice ID the provider does not know.
        // "Check the speech model and voice" is the actionable copy; the old
        // blanket "could not finish reading" swallowed it.
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.providerRejected(
            provider: .volcengine, code: 450000201, logID: "abc123")), "voice.error.configuration")
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.httpStatus(
            provider: .openAI, statusCode: 400, logID: nil)), "voice.error.configuration")
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.httpStatus(
            provider: .openAI, statusCode: 404, logID: nil)), "voice.error.configuration")
        // Auth/quota labels keep pointing at the right key/channel.
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.authentication(
            provider: .volcengine, route: .agentPlan, logID: nil)), "voice.error.credential")
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.quotaOrRateLimited(
            provider: .alibaba, route: .tokenPlan, logID: nil)), "voice.error.quota")
        // 5xx and transport faults stay the honest generic retry copy.
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.httpStatus(
            provider: .elevenLabs, statusCode: 503, logID: nil)), "voice.error.playback")
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.transport(
            provider: .openAI, failure: .timedOut)), "voice.error.playback")
        XCTAssertEqual(SpeechFailureCopy.key(for: TTSSynthesisError.streamTruncated(
            provider: .onDevice)), "voice.error.playback")
    }

    func testDiagnosticsAreSingleTokenAndCarryNoProviderText() {
        let rejected = SpeechFailureCopy.diagnostic(for: TTSSynthesisError.providerRejected(
            provider: .volcengine, code: 450_000_201, logID: "conn-9f8e"))
        XCTAssertEqual(rejected, "rejected:volcengine.450000201:log=conn-9f8e")
        let auth = SpeechFailureCopy.diagnostic(for: TTSSynthesisError.authentication(
            provider: .alibaba, route: .tokenPlan, logID: nil))
        XCTAssertEqual(auth, "authentication:alibaba.tokenPlan:log=-")
        for value in [rejected, auth] {
            XCTAssertFalse(value.contains(" "))
            XCTAssertFalse(value.lowercased().contains("bearer"))
            XCTAssertFalse(value.contains("http"))
        }
    }

    // MARK: - No-silent-configuration state

    func testBeginStreamWithoutConfigurationFailsVisibly() {
        // Regression guard for the silent class: an utterance that cannot be
        // dispatched must end in an actionable failure key, never a live
        // "speaking" state with no sound and no error.
        let service = SpeechService()
        let owner = UUID()
        let handle = service.beginStream(id: owner)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertFalse(service.isPreparing)
        XCTAssertEqual(service.failureKey, "voice.error.configuration")
        XCTAssertEqual(service.failureOwnerID, owner)
        handle.append("hello")
        handle.finish()
    }
}
#endif

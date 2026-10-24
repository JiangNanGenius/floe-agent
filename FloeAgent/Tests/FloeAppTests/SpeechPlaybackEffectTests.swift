// FloeAppTests — Native qualification for the shared speech playback effect.
//
// These tests render REAL PCM through the production helper
// (`SpeechPlaybackEffectGraph` inside a real `AVAudioEngine` running in
// offline manual-rendering mode) and measure the output, instead of merely
// asserting unit properties:
//   * content duration at 0.5x / 1x / 2x rate (duration = frames / rate),
//   * fundamental frequency at neutral tempo with semitone shifts (+3, −5,
//     +4 at rate 1.5), proving rate and pitch each apply exactly once and
//     independently (no varispeed coupling, no double rate),
//   * neutral passthrough tolerance (duration, energy and pitch preserved),
//   * nonzero, finite rendered PCM on every path (mono and stereo),
//   * contract normalization/clamping for non-finite / out-of-range inputs,
//   * the OUTPUT-TAIL truth for the final syllable: the player's last
//     `.dataPlayedBack` proves only INPUT consumption, so the rendered tail
//     beyond the input-accounting expectation is measured and must stay
//     inside the FRAME-clock drain allowance (production waits on real mixer
//     output frames, never a blind sleep and never a non-silent census),
//   * one frozen configuration across two back-to-back units inside one real
//     engine (the continuous-voice round contract; no receipt retune),
//   * the targeted stop/reset path with real rendered buffers: `reset()`
//     discards the slow segment's held look-ahead before the next segment,
//     while the no-reset control proves the old tail would otherwise play,
//   * drain-bound/latency arithmetic, the real output-frame meter (silence
//     counts, reset starts a new epoch) and a real
//     AVAudioEngine/AVAudioUnitTimePitch object build.
// All cases are bounded (fixed input length + fixed frame budget), device
// free, network free and use generated sine PCM only.
import XCTest
import AVFoundation
#if canImport(UIKit) && canImport(FloeCore)
import FloeCore
#endif
@testable import FloeApp

@MainActor
final class SpeechPlaybackEffectTests: XCTestCase {
    // MARK: - Signal fixtures and measurement helpers

    private static let rate = 24_000.0

    private static func sine(frequency: Double, seconds: Double, channels: Int = 1,
                             amplitude: Float = 0.4) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let frames = AVAudioFrameCount((seconds * rate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let phaseStep: Double = 2.0 * Double.pi * frequency / Self.rate
        let scale: Double = Double(amplitude)
        for channel in 0..<channels {
            guard let destination = buffer.floatChannelData?[channel] else { continue }
            for index in 0..<Int(frames) {
                destination[index] = Float(scale * sin(phaseStep * Double(index)))
            }
        }
        return buffer
    }

    private static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
    }

    /// First/last frame index whose absolute value crosses `threshold`, the
    /// RMS measured INSIDE that content window only (the render budget may
    /// pad trailing silence) and the all-finite flag.
    private static func measure(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.01)
        -> (start: Int, end: Int, contentRMS: Double, finite: Bool) {
        let values = samples(buffer)
        var finite = true
        var start: Int?
        var end = 0
        for index in values.indices {
            let value = values[index]
            if !value.isFinite { finite = false; continue }
            if abs(value) > threshold {
                if start == nil { start = index }
                end = index + 1
            }
        }
        var contentRMS = 0.0
        if let start, end > start {
            var sum = 0.0
            for index in start..<end { sum += Double(values[index]) * Double(values[index]) }
            contentRMS = (sum / Double(end - start)).squareRoot()
        }
        return (start ?? values.count, end, contentRMS, finite)
    }

    /// Goertzel magnitude sweep over [start, start+length) (channel 0).
    private static func dominantFrequency(_ buffer: AVAudioPCMBuffer, from start: Int, length: Int) -> Double? {
        guard length > 2_000 else { return nil }
        let upper = min(start + length, Int(buffer.frameLength))
        guard upper - start > 2_000, let channel = buffer.floatChannelData?[0] else { return nil }
        let slice = UnsafeBufferPointer(start: channel + start, count: upper - start)
        var best = (frequency: 0.0, power: -1.0)
        var frequency = 80.0
        while frequency <= 1_300.0 {
            let power = goertzelPower(slice, frequency: frequency, sampleRate: rate)
            if power > best.power { best = (frequency, power) }
            frequency += 1.0
        }
        return best.frequency
    }

    private static func goertzelPower(_ samples: UnsafeBufferPointer<Float>, frequency: Double,
                                      sampleRate: Double) -> Double {
        let omega = 2 * .pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0
        var s2 = 0.0
        for value in samples {
            let s0 = Double(value) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    private struct RenderReport {
        let inputFrames: Int
        let contentFrames: Int
        let contentStart: Int
        let rms: Double
        let frequency: Double?
        let finite: Bool
    }

    private func render(_ input: AVAudioPCMBuffer, rate ratio: Double, semitones: Double,
                        extraBudget: Double = 1.35) throws -> RenderReport {
        let controls = VoicePlaybackControls(rateRatio: ratio, pitchSemitones: semitones)
        let budget = AVAudioFrameCount((Double(input.frameLength) / controls.rateRatio * extraBudget)
            .rounded(.up))
        let output = try SpeechPlaybackEffectRender.render(input: input, controls: controls,
                                                            budgetFrames: max(budget, 12_288))
        let metrics = Self.measure(output)
        let frequency = metrics.end > metrics.start
            ? Self.dominantFrequency(output, from: metrics.start + (metrics.end - metrics.start) / 5,
                                     length: (metrics.end - metrics.start) * 3 / 5)
            : nil
        return RenderReport(inputFrames: Int(input.frameLength),
                            contentFrames: max(0, metrics.end - metrics.start),
                            contentStart: metrics.start,
                            rms: metrics.contentRMS, frequency: frequency, finite: metrics.finite)
    }

    // MARK: - Contract value normalization

    func testControlsNormalizeNonFiniteAndClampToContract() {
        XCTAssertEqual(VoicePlaybackControls(rateRatio: .nan, pitchSemitones: .nan), .neutral)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: .infinity, pitchSemitones: -.infinity), .neutral)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 0.1, pitchSemitones: 40),
                       VoicePlaybackControls(rateRatio: 0.5, pitchSemitones: 6.0))
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 9.0, pitchSemitones: -40),
                       VoicePlaybackControls(rateRatio: 2.0, pitchSemitones: -6.0))
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 1.25, pitchSemitones: -3).rateRatio, 1.25)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 1.25, pitchSemitones: -3).pitchCents, -300)
    }

    func testControlsNeutralityAndExpectedFrames() {
        XCTAssertTrue(VoicePlaybackControls.neutral.isNeutral)
        XCTAssertFalse(VoicePlaybackControls(rateRatio: 1, pitchSemitones: 0.5).isNeutral)
        XCTAssertEqual(VoicePlaybackControls.neutral.expectedOutputFrames(for: 24_000), 24_000)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 2, pitchSemitones: 0).expectedOutputFrames(for: 24_000), 12_000)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 0.5, pitchSemitones: 0).expectedOutputFrames(for: 24_000), 48_000)
        XCTAssertEqual(VoicePlaybackControls(rateRatio: 1.5, pitchSemitones: 4).expectedOutputFrames(for: 48_000), 32_000)
        XCTAssertEqual(VoicePlaybackControls.neutral.expectedOutputFrames(for: 0), 0)
    }

    // MARK: - Offline rendered PCM proofs (real AVAudioEngine + AVAudioUnitTimePitch)

    func testNeutralPassthroughPreservesDurationEnergyAndPitch() throws {
        let input = Self.sine(frequency: 440, seconds: 1.0)
        let report = try render(input, rate: 1.0, semitones: 0)
        let inputMetrics = Self.measure(input)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05, "neutral render must be nonzero PCM")
        // Duration: the neutral unit must not stretch or compress beyond its
        // documented edge latency.
        XCTAssertEqual(Double(report.contentFrames), Double(inputMetrics.end - inputMetrics.start),
                       accuracy: Double(input.frameLength) * 0.05)
        // Energy: unity-gain passthrough within tolerance of the direct sine.
        XCTAssertEqual(report.rms / inputMetrics.contentRMS, 1.0, accuracy: 0.05)
        // Pitch: unchanged fundamental.
        XCTAssertEqual(report.frequency!, 440, accuracy: 440 * 0.01)
    }

    func testDoubleRateHalvesContentDurationAndKeepsPitch() throws {
        let report = try render(Self.sine(frequency: 440, seconds: 1.0), rate: 2.0, semitones: 0)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05)
        // 1.0 s of 440 Hz at rate 2 → ~0.5 s of content (24000 frames / 2).
        XCTAssertEqual(Double(report.contentFrames), 12_000, accuracy: 12_000 * 0.05)
        // Time compression must NOT raise the pitch (that would be varispeed
        // / a resampler path); a double-rate bug would halve duration again.
        XCTAssertEqual(report.frequency!, 440, accuracy: 440 * 0.02)
    }

    func testHalfRateDoublesContentDurationAndKeepsPitch() throws {
        let report = try render(Self.sine(frequency: 440, seconds: 1.0), rate: 0.5, semitones: 0)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05)
        XCTAssertEqual(Double(report.contentFrames), 48_000, accuracy: 48_000 * 0.05)
        XCTAssertEqual(report.frequency!, 440, accuracy: 440 * 0.02)
    }

    func testPitchUpShiftsFundamentalOnceAtNeutralTempo() throws {
        let report = try render(Self.sine(frequency: 440, seconds: 1.0), rate: 1.0, semitones: 3)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05)
        let expected = 440 * pow(2.0, 3.0 / 12.0) // 587.33 Hz
        XCTAssertEqual(report.frequency!, expected, accuracy: expected * 0.02)
        // Pitch shift never changes duration.
        XCTAssertEqual(Double(report.contentFrames), 24_000, accuracy: 24_000 * 0.05)
    }

    func testPitchDownShiftsFundamentalOnceAtNeutralTempo() throws {
        let report = try render(Self.sine(frequency: 440, seconds: 1.0), rate: 1.0, semitones: -5)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05)
        let expected = 440 * pow(2.0, -5.0 / 12.0) // 329.63 Hz
        XCTAssertEqual(report.frequency!, expected, accuracy: expected * 0.02)
        XCTAssertEqual(Double(report.contentFrames), 24_000, accuracy: 24_000 * 0.05)
    }

    func testCombinedRateAndPitchEachAppliedExactlyOnce() throws {
        // rate 1.5 + 4 semitones: duration = frames / 1.5 exactly once, and
        // frequency = 440 * 2^(4/12) exactly once. A double application of
        // either axis lands far outside these tolerances.
        let report = try render(Self.sine(frequency: 440, seconds: 1.0), rate: 1.5, semitones: 4)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05)
        XCTAssertEqual(Double(report.contentFrames), 16_000, accuracy: 16_000 * 0.05)
        let expected = 440 * pow(2.0, 4.0 / 12.0)
        XCTAssertEqual(report.frequency!, expected, accuracy: expected * 0.02)
    }

    func testRenderedPcmIsNonZeroAndFinite() throws {
        // A short first sentence must already produce real processed PCM.
        let report = try render(Self.sine(frequency: 300, seconds: 0.25), rate: 1.5, semitones: -2)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.contentFrames, 0)
        XCTAssertGreaterThan(report.rms, 0.05)
    }

    func testStereoNeutralPassthroughRendersNonZero() throws {
        // The live duplex stack runs its player at the engine output format
        // (typically stereo 48 kHz); the shared unit must render both
        // channels there too. Bounded: 0.4 s.
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let frames = AVAudioFrameCount(0.4 * Self.rate)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        input.frameLength = frames
        let phaseStep: Double = 2.0 * Double.pi * 330.0 / Self.rate
        for channel in 0..<2 {
            guard let destination = input.floatChannelData?[channel] else { continue }
            for index in 0..<Int(frames) {
                destination[index] = Float(0.35 * sin(phaseStep * Double(index)))
            }
        }
        let output = try SpeechPlaybackEffectRender.render(input: input, controls: .neutral,
                                                            budgetFrames: AVAudioFrameCount(1.4 * Double(frames)))
        let left = Self.measure(output)
        XCTAssertGreaterThan(left.contentRMS, 0.03, "stereo render must be nonzero PCM")
        XCTAssertTrue(left.finite)
        let right = Self.samples(output, channel: 1)
        XCTAssertTrue(right.allSatisfy(\.isFinite))
        var sum = 0.0
        for index in left.start..<max(left.start + 1, left.end) { sum += Double(right[index]) * Double(right[index]) }
        XCTAssertGreaterThan((sum / Double(max(1, left.end - left.start))).squareRoot(), 0.03,
                             "channel 1 must carry rendered audio")
    }

    /// The final-syllable risk: the last player receipt only proves INPUT
    /// consumption, so the rendered output must still settle within the
    /// bounded look-ahead allowance. A short final segment at the slowest
    /// contract rate measures the real tail; the production drain waits for
    /// this many REAL mixer output FRAMES (measured at the actual tap rate),
    /// never a fixed sleep and never a non-silent-sample count.
    func testShortFinalSegmentTailStaysInsideDrainBound() throws {
        let input = Self.sine(frequency: 440, seconds: 0.15) // 3600 frames
        let report = try render(input, rate: 0.5, semitones: 0, extraBudget: 1.6)
        XCTAssertTrue(report.finite)
        XCTAssertGreaterThan(report.rms, 0.05, "final segment must render audible PCM")
        let expected = VoicePlaybackControls(rateRatio: 0.5, pitchSemitones: 0)
            .expectedOutputFrames(for: Int(input.frameLength)) // 7200
        XCTAssertGreaterThan(report.contentFrames, expected - 1_000)
        let drainFrames = SpeechPlaybackEffectRender.drainFrameCount(
            nodeLatencySeconds: 0, sampleRate: Self.rate)
        XCTAssertLessThanOrEqual(report.contentFrames, expected + drainFrames,
                                 "measured tail must stay inside the drain frame allowance")
        // The allowance must actually cover the measured tail (25.4 ms here);
        // a quiet/low-energy end must not need any additional content count.
        XCTAssertGreaterThanOrEqual(drainFrames, 609,
                                    "allowance must cover the measured 24 kHz tail")
    }

    /// Two concatenated "units" rendered through ONE graph with ONE frozen
    /// configuration: both keep the same rate-derived duration and the same
    /// pitch shift. This is the continuous-voice round contract (one tuning
    /// per answer) proven against real AU output; no retune is performed on
    /// player receipts anywhere in production.
    func testTwoUnitsShareOneFrozenConfigurationInsideRealEngine() throws {
        let unitFrames = 12_000 // 0.5 s at 24 kHz each
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(unitFrames * 2))!
        input.frameLength = AVAudioFrameCount(unitFrames * 2)
        let destination = input.floatChannelData![0]
        let firstStep: Double = 2.0 * Double.pi * 440.0 / Self.rate
        let secondStep: Double = 2.0 * Double.pi * 660.0 / Self.rate
        for index in 0..<unitFrames {
            destination[index] = Float(0.4 * sin(firstStep * Double(index)))
        }
        for index in 0..<unitFrames {
            destination[unitFrames + index] = Float(0.4 * sin(secondStep * Double(index)))
        }
        let controls = VoicePlaybackControls(rateRatio: 0.75, pitchSemitones: 5)
        let output = try SpeechPlaybackEffectRender.render(
            input: input, controls: controls, budgetFrames: AVAudioFrameCount(36_000), chunkFrames: 512)
        let metrics = Self.measure(output)
        XCTAssertTrue(metrics.finite)
        XCTAssertGreaterThan(metrics.contentRMS, 0.05)
        // duration = 24000 / 0.75 = 32000 frames for BOTH units together.
        XCTAssertEqual(Double(metrics.end - metrics.start), 32_000, accuracy: 32_000 * 0.08)
        let expectedFirst = 440 * pow(2.0, 5.0 / 12.0) // 587.33
        let expectedSecond = 660 * pow(2.0, 5.0 / 12.0) // 881.0
        let firstFrequency = Self.dominantFrequency(output, from: metrics.start + 1_500, length: 4_000)
        let secondFrequency = Self.dominantFrequency(output, from: metrics.start + 18_000, length: 4_000)
        XCTAssertEqual(firstFrequency!, expectedFirst, accuracy: expectedFirst * 0.025)
        XCTAssertEqual(secondFrequency!, expectedSecond, accuracy: expectedSecond * 0.025)
    }

    // MARK: - Drain clock and meter (real frame counts, no content census)

    /// The SDK reports `AVAudioUnitTimePitch.latency == 0` ("unknown or
    /// none"), so the allowance is the measured tail plus a small margin; a
    /// reported nonzero latency is honoured instead. The result is converted
    /// to frames at the ACTUAL tap sample rate by the production callers.
    func testDrainBoundHonoursReportedLatencyAndMeasuredTail() {
        XCTAssertEqual(SpeechPlaybackEffectRender.measuredTailSeconds, 0.026, accuracy: 0.0001)
        let measured = SpeechPlaybackEffectRender.drainBoundSeconds(nodeLatencySeconds: 0)
        XCTAssertGreaterThanOrEqual(measured, 0.026)
        XCTAssertLessThanOrEqual(measured, 0.05)
        let reported = SpeechPlaybackEffectRender.drainBoundSeconds(nodeLatencySeconds: 0.25)
        XCTAssertGreaterThanOrEqual(reported, 0.25)
        XCTAssertEqual(SpeechPlaybackEffectRender.drainFrameCount(nodeLatencySeconds: 0, sampleRate: 48_000),
                       Int((measured * 48_000).rounded(.up)))
        XCTAssertEqual(SpeechPlaybackEffectRender.drainFrameCount(nodeLatencySeconds: 0, sampleRate: 24_000),
                       Int((measured * 24_000).rounded(.up)))
        XCTAssertEqual(SpeechPlaybackEffectRender.drainFrameCount(nodeLatencySeconds: 0, sampleRate: 0), 0)
        XCTAssertEqual(SpeechPlaybackEffectRender.drainFrameCount(nodeLatencySeconds: 0, sampleRate: .nan), 0)
    }

    /// The meter counts EVERY rendered frame (silence included) and tracks
    /// the actual tap format; reset starts a new epoch from zero. This is the
    /// exact arithmetic the render-thread tap performs. It deliberately does
    /// not inspect sample values: a quiet tail is still a rendered tail.
    func testOutputMeterCountsFramesIncludingSilenceAndResets() async {
        // The production install path: nil format means the mixer's ACTUAL
        // output format (44.1/48 kHz stereo on hardware), never the provider
        // PCM format. Install/remove on a non-rendering engine is safe.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mono24k = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: mono24k)
        let installedMeter = SpeechPlaybackOutputMeter()
        installedMeter.install(on: engine.mainMixerNode)
        XCTAssertGreaterThan(installedMeter.sampleRate, 0,
                             "tap resolves the mixer output rate, not the provider rate")
        installedMeter.remove()
        engine.detach(player)

        let meter = SpeechPlaybackOutputMeter()
        XCTAssertEqual(meter.outputFrames, 0)
        XCTAssertEqual(meter.sampleRate, 0)
        meter.record(frames: 4_096, sampleRate: 48_000)
        meter.record(frames: 4_096, sampleRate: 48_000)
        XCTAssertEqual(meter.outputFrames, 8_192)
        XCTAssertEqual(meter.sampleRate, 48_000)
        // A silent buffer contributes its frames exactly like a loud one.
        meter.record(frames: 1_024, sampleRate: 48_000)
        XCTAssertEqual(meter.outputFrames, 9_216)
        meter.reset()
        XCTAssertEqual(meter.outputFrames, 0)
        XCTAssertEqual(meter.sampleRate, 48_000, "the actual tap format is retained")
        meter.record(frames: 2_048, sampleRate: 44_100)
        XCTAssertEqual(meter.outputFrames, 2_048)
        XCTAssertEqual(meter.sampleRate, 44_100)
        // Dead meter: the growth settle fails at the bound, never reports a
        // fake success after a fixed delay.
        meter.reset()
        let started = Date()
        let settled = await meter.settleTail(
            baseline: 0, requiredFrames: 1_000, deadline: 0.05,
            pollInterval: 0.005, isPaused: { false })
        XCTAssertFalse(settled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        meter.remove()
    }

    // MARK: - Targeted stop/reset (cancellation must discard the AU tail)

    /// Real rendered proof for the cancellation path: a slow first segment is
    /// stopped mid-flight; the SAME engine then plays a second segment at
    /// neutral speed. `timePitch.reset()` (the production `graph.reset()`)
    /// must discard the first segment's held look-ahead: the first output
    /// after the boundary carries the second segment (880 Hz) and its full
    /// 0.25 s duration, with no 440 Hz residue. The same experiment without
    /// reset is the differential control and keeps playing the old tail.
    func testStopResetDiscardsHeldEffectTailBeforeNewSegment() throws {
        let withReset = try Self.resetProof(performReset: true)
        XCTAssertGreaterThan(withReset.contentAfterBoundary, 5_500,
                             "second segment must render its full duration")
        XCTAssertLessThan(withReset.contentAfterBoundary, 6_600,
                          "no old look-ahead may be appended after reset")
        XCTAssertEqual(withReset.frequencyAfterBoundary, 880, accuracy: 880 * 0.03,
                       "the fresh segment must be heard immediately after reset")
        XCTAssertLessThan(withReset.oldTonePower, withReset.newTonePower * 0.01,
                          "reset must leave essentially no 440 Hz residue")
        let withoutReset = try Self.resetProof(performReset: false)
        XCTAssertGreaterThan(withoutReset.oldTonePower, withReset.oldTonePower * 100,
                             "control: without reset the held 440 Hz tail keeps playing")
        XCTAssertGreaterThan(withoutReset.contentAfterBoundary,
                             withReset.contentAfterBoundary + 500,
                             "control proves the reset is what discards old output")
    }

    private struct ResetProof {
        let contentAfterBoundary: Int
        let frequencyAfterBoundary: Double
        let oldTonePower: Double
        let newTonePower: Double
    }

    /// Builds the real engine once per variant. Production order is mirrored:
    /// player.stop → player.reset → graph.reset (state + neutral parameters)
    /// → new segment. No engine, microphone or VPIO object is reset.
    private static func resetProof(performReset: Bool) throws -> ResetProof {
        let first = sine(frequency: 440, seconds: 0.3)
        let second = sine(frequency: 880, seconds: 0.25)
        let format = first.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(player)
        let graph = SpeechPlaybackEffectGraph(controls: VoicePlaybackControls(rateRatio: 0.5, pitchSemitones: 0))
        graph.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(first, at: nil, options: [], completionCallbackType: .dataPlayedBack)
        try engine.start()
        player.play()
        var chunks: [AVAudioPCMBuffer] = []
        var total = 0
        func renderChunks(_ count: Int) {
            for _ in 0..<count {
                guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else { return }
                _ = try? engine.renderOffline(512, to: chunk)
                if chunk.frameLength == 0 { return }
                chunks.append(chunk)
                total += Int(chunk.frameLength)
            }
        }
        defer {
            player.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            graph.uninstall()
        }
        renderChunks(6) // 3072 output frames of the slow first segment
        let boundary = total
        player.stop()
        player.reset()
        if performReset {
            graph.reset()
        } else {
            graph.apply(.neutral)
        }
        player.scheduleBuffer(second, at: nil, options: [], completionCallbackType: .dataPlayedBack)
        player.play()
        renderChunks(80)
        guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            throw SpeechPlaybackEffectRenderFailure.budgetExceeded
        }
        merged.frameLength = AVAudioFrameCount(total)
        var written = 0
        for chunk in chunks {
            let frames = min(Int(chunk.frameLength), total - written)
            merged.floatChannelData![0].advanced(by: written)
                .update(from: chunk.floatChannelData![0], count: frames)
            written += frames
        }
        let metrics = measure(merged)
        let frequency = dominantFrequency(merged, from: boundary, length: 4_000) ?? 0
        // Tone census over the first 1800 frames after the boundary: with a
        // reset the old 440 Hz tail is gone; without it, it dominates.
        let window = min(1_800, max(0, Int(merged.frameLength) - boundary))
        let base = merged.floatChannelData![0].advanced(by: boundary)
        let slice = UnsafeBufferPointer(start: base, count: window)
        let oldTone = window > 0 ? goertzelPower(slice, frequency: 440, sampleRate: rate) : 0
        let newTone = window > 0 ? goertzelPower(slice, frequency: 880, sampleRate: rate) : 0
        return ResetProof(contentAfterBoundary: max(0, metrics.end - boundary),
                          frequencyAfterBoundary: frequency,
                          oldTonePower: oldTone,
                          newTonePower: newTone)
    }

    // MARK: - Real object graph build (production wiring, not device playback)

    func testEffectGraphBuildsAndTearsDownRealEngineNodes() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let graph = SpeechPlaybackEffectGraph(controls: VoicePlaybackControls(rateRatio: 1.5, pitchSemitones: -3))
        graph.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        XCTAssertTrue(graph.isInstalled)
        XCTAssertTrue(engine.attachedNodes.contains(graph.timePitch))
        // The unit is a real AVAudioUnitTimePitch carrying exactly the
        // contract values once (rate ratio, pitch in cents).
        XCTAssertEqual(graph.timePitch.rate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(graph.timePitch.pitch, -300, accuracy: 0.0001)
        XCTAssertEqual(graph.appliedControls, VoicePlaybackControls(rateRatio: 1.5, pitchSemitones: -3))
        graph.apply(.neutral)
        XCTAssertEqual(graph.timePitch.rate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(graph.timePitch.pitch, 0.0, accuracy: 0.0001)
        // Targeted reset keeps the node installed but clears state/parameters.
        graph.apply(VoicePlaybackControls(rateRatio: 0.5, pitchSemitones: 4))
        graph.reset()
        XCTAssertTrue(graph.isInstalled)
        XCTAssertEqual(graph.appliedControls, .neutral)
        XCTAssertEqual(graph.timePitch.rate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(graph.timePitch.pitch, 0.0, accuracy: 0.0001)
        graph.uninstall()
        XCTAssertFalse(graph.isInstalled)
        XCTAssertFalse(engine.attachedNodes.contains(graph.timePitch))
        engine.detach(player)
    }

#if canImport(UIKit) && canImport(FloeCore)
    // MARK: - "Use System Voice" fallback keeps the frozen controls

    func testSystemVoiceFallbackKeepsFrozenControlsWithoutCloudIdentity() {
        let connectionID = UUID()
        let base = TTSSettingsSnapshot(
            provider: .volcengine,
            billingRoute: .agentPlan,
            modelID: "seed-tts-2.0",
            voiceID: "zh_female_vv_uranus_bigtts",
            speechRateRatio: 0.65,
            speechPitchSemitones: -4,
            autoReadEnabled: true,
            allowBargeIn: false,
            connectionProviderID: connectionID,
            language: "zh-CN")
        let fallback = SpeechService.systemVoiceFallback(from: base)
        // Only the SOURCE becomes Apple; the frozen playback controls survive.
        XCTAssertEqual(fallback.provider, .apple)
        XCTAssertEqual(fallback.playbackControls, base.playbackControls)
        XCTAssertEqual(fallback.speechRateRatio, 0.65)
        XCTAssertEqual(fallback.speechPitchSemitones, -4)
        XCTAssertEqual(fallback.autoReadEnabled, true)
        XCTAssertEqual(fallback.allowBargeIn, false)
        XCTAssertEqual(fallback.language, "zh-CN")
        // No cloud credential/billing/model/voice reuse and no auto-selection.
        XCTAssertEqual(fallback.billingRoute, .payAsYouGo)
        XCTAssertNil(fallback.connectionProviderID)
        XCTAssertEqual(fallback.modelID, "")
        XCTAssertEqual(fallback.voiceID, "")
        XCTAssertNil(fallback.openAIBaseURL)
        XCTAssertNil(fallback.alibabaRegion)
        // An already-Apple snapshot keeps its explicit system voice; only the
        // cloud identity of a failed cloud utterance is discarded.
        let systemBase = TTSSettingsSnapshot(
            provider: .apple,
            voiceID: "com.apple.ttsbundle.Samantha-compact",
            speechRateRatio: 0.8,
            speechPitchSemitones: 2)
        let systemFallback = SpeechService.systemVoiceFallback(from: systemBase)
        XCTAssertEqual(systemFallback.provider, .apple)
        XCTAssertEqual(systemFallback.voiceID, systemBase.voiceID)
        XCTAssertEqual(systemFallback.playbackControls, systemBase.playbackControls)
    }
#endif
}

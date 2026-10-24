// FloeApp — Shared playback-side speech rate/pitch effect (final-output DSP, one application).
//
// SPDX-License-Identifier: MPL-2.0
//
// Every configured speech provider emits PCM and the configured generation
// path keeps the provider speed knob at exactly 1.0 (PLAYBACK-CONTROL-CONTRACT
// / CONTROL-INTERFACE: double-rate prevention), so the user's speech speed and
// intonation are a PLAYBACK effect: ONE AVAudioUnitTimePitch sitting between
// the speech player node and the engine mixer. The same helper serves ordinary
// chat read-aloud (Chat/SpeechService.swift) and the continuous-voice duplex
// output (Voice/VoiceConversationLive.swift); the microphone/VPIO input path
// is never routed through it.
//
// Contract values live in the Foundation-only `Voice/VoicePlaybackControls.swift`
// so the voice kernel does not depend on AVFoundation. This file only maps the
// frozen value onto the real node and qualifies it with real rendered PCM.
//
// Two drain rules that the previous patch got wrong and this file now states:
//   1. The final-syllable settle waits on REAL rendered output FRAMES (the
//      mixer tap's frame clock), never on a count of non-silent samples. Quiet
//      speech, pauses and zero crossings are legitimate and must not trip a
//      false "tail unsettled" warning.
//   2. Cancellation uses the targeted `AVAudioNode.reset()` on the player and
//      the time-pitch unit (plus the neutral parameter write) to discard held
//      look-ahead; it never resets the whole duplex engine, the microphone or
//      voice processing. The output meter's frame counter is reset for the new
//      epoch, and old frames can never be credited as new-round progress
//      (played progress itself comes from epoch-fenced player receipts).

import Foundation
import AVFoundation

/// One reusable `AVAudioUnitTimePitch` plus the graph wiring for a
/// player → effect → mixer output chain. Applies controls once; parameter
/// writes are idempotent, so callers must never re-reset the effect per PCM
/// chunk to make progress.
final class SpeechPlaybackEffectGraph {
    let timePitch = AVAudioUnitTimePitch()
    private weak var hostEngine: AVAudioEngine?
    private(set) var appliedControls: VoicePlaybackControls

    init(controls: VoicePlaybackControls = .neutral) {
        self.appliedControls = controls
        timePitch.rate = Float(controls.rateRatio)
        timePitch.pitch = Float(controls.pitchCents)
    }

    var isInstalled: Bool { hostEngine != nil }

    /// Builds the REAL engine object graph: `player → timePitch → mixer`,
    /// replacing the direct `player → mixer` edge. Call on a stopped engine,
    /// before `engine.start()` (both production graphs already follow that
    /// order; the live stack re-runs it inside its connect step).
    func install(in engine: AVAudioEngine, from player: AVAudioPlayerNode,
                 to mixer: AVAudioMixerNode, format: AVAudioFormat) {
        if hostEngine !== engine {
            engine.attach(timePitch)
            hostEngine = engine
        }
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: mixer, format: format)
        apply(appliedControls)
    }

    /// Detaches the unit from its host engine (engine teardown / rebuild).
    func uninstall() {
        if let engine = hostEngine {
            engine.disconnectNodeOutput(timePitch)
            engine.detach(timePitch)
        }
        hostEngine = nil
    }

    /// Applies rate and pitch exactly once to the shared unit. `rate == 1`
    /// and `pitch == 0` is the documented neutral passthrough: the unit still
    /// renders, so callers that keep one live unit across rounds do not have
    /// to rewire a running engine. Ordinary read-aloud does NOT call this for
    /// a neutral utterance — it keeps its historical direct player → mixer
    /// edge and never installs the node at all.
    func apply(_ controls: VoicePlaybackControls) {
        appliedControls = controls
        timePitch.rate = Float(controls.rateRatio)
        timePitch.pitch = Float(controls.pitchCents)
    }

    /// Targeted cancellation/reset. `AVAudioNode.reset()` clears the unit's
    /// retained processing state (including the time-pitch look-ahead that
    /// survived a bare `player.stop()` in the previous patch). Parameters are
    /// written back to neutral because reset does not rewind parameter values.
    /// This is deliberately scoped to this one unit: the caller has already
    /// stopped the player, and the duplex engine/microphone/VPIO graph is
    /// untouched.
    func reset() {
        timePitch.reset()
        apply(.neutral)
    }

    /// Maximum render delay the node itself reports. A zero value means
    /// "unknown or none" per the SDK, so callers must combine it with the
    /// measured bound below rather than treating 0 as "no tail".
    var reportedLatencySeconds: TimeInterval {
        let value = timePitch.latency
        return value.isFinite && value > 0 ? value : 0
    }
}

/// Real output-frame clock for the FINAL-syllable drain decision.
///
/// A player `.dataPlayedBack` receipt only proves the source frames left the
/// player; a downstream `AVAudioUnitTimePitch` still holds its look-ahead, so
/// at rate < 1 the audible tail outlives the last input receipt. Callers must
/// settle on ACTUAL mixer-rendered frames measured by this tap before tearing
/// the graph down. The counter deliberately counts ALL rendered frames (it
/// never inspects sample values): silent gaps are legitimate, and a
/// non-silent-sample census against a total frame target can never be reached
/// by ordinary speech. The tap block runs on the render thread; counting is
/// lock-guarded and allocation-free.
final class SpeechPlaybackOutputMeter {
    private let lock = NSLock()
    private var frames = 0
    private var rate: Double = 0
    private var installedNode: AVAudioMixerNode?

    /// Every mixer frame rendered since install (or since `reset()`).
    var outputFrames: Int { lock.withLock { frames } }

    /// ACTUAL tap format sample rate (from the mixer output buffer), not the
    /// provider's PCM rate. Seeded at install from the mixer's output format
    /// and refreshed from each tap buffer.
    var sampleRate: Double { lock.withLock { rate } }

    /// Installs the counting tap on the node that feeds the speaker.
    /// `format` is nil so the mixer supplies its real output format (the
    /// provider PCM format is generally 24 kHz mono while the hardware mixer
    /// renders 44.1/48 kHz stereo; forcing the former onto the tap is wrong).
    /// The caller fences installation/identity exactly like its other engine
    /// observers (generation + engine identity live at the call site).
    func install(on node: AVAudioMixerNode, format: AVAudioFormat? = nil) {
        let busFormat = format ?? node.outputFormat(forBus: 0)
        lock.withLock {
            frames = 0
            rate = busFormat.sampleRate
            installedNode = node
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.record(frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        }
    }

    /// The exact counting step the render-thread tap performs. Internal so the
    /// deterministic host test can exercise the arithmetic without pretending
    /// a manual-rendering tap delivered buffers (manual rendering does not
    /// support mixer taps; the probe recorded that platform fact).
    func record(frames count: Int, sampleRate bufferRate: Double) {
        guard count > 0 else { return }
        lock.withLock {
            frames += count
            if bufferRate.isFinite, bufferRate > 0 { rate = bufferRate }
        }
    }

    /// New epoch: the counter restarts at zero. Any tap callback still in
    /// flight may add at most one render quantum of the OLD epoch here; the
    /// drain decision uses a baseline captured after the last input receipt
    /// (and played progress uses epoch-fenced player receipts), so that
    /// residue can never be credited to the new round.
    func reset() {
        lock.withLock { frames = 0 }
    }

    func remove() {
        let node = lock.withLock { () -> AVAudioMixerNode? in
            let value = installedNode
            installedNode = nil
            return value
        }
        node?.removeTap(onBus: 0)
    }

    /// Bounded, growth-based settle used by the ordinary player. Success is
    /// defined ONLY by real rendered-frame growth from `baseline` reaching
    /// `requiredFrames`; `deadline` bounds a dead pipeline and is never used
    /// as a blind success delay. While the utterance is paused the mixer
    /// renders silence (the held tail cannot advance), so paused time is
    /// excluded from the budget and the baseline is re-anchored; a user
    /// resume continues the same wait at the same position.
    @MainActor
    func settleTail(baseline initial: Int, requiredFrames: Int,
                    deadline: TimeInterval, pollInterval: TimeInterval = 0.005,
                    isPaused: () -> Bool) async -> Bool {
        guard requiredFrames > 0 else { return true }
        var baseline = initial
        var activeElapsed: TimeInterval = 0
        let poll = max(0.002, pollInterval)
        while activeElapsed < deadline {
            if Task.isCancelled { return false }
            if isPaused() {
                // Silence frames rendered while paused are NOT effect output.
                try? await Task.sleep(nanoseconds: UInt64(0.02 * 1_000_000_000))
                baseline = outputFrames
                continue
            }
            if outputFrames - baseline >= requiredFrames { return true }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
            activeElapsed += poll
        }
        return outputFrames - baseline >= requiredFrames
    }
}

enum SpeechPlaybackEffectRenderFailure: Error {
    case invalidInput
    case manualModeUnavailable
    case engineStartFailed
    case renderFailed
    case budgetExceeded
}

/// Offline render primitive used by the native qualification tests: builds a
/// REAL `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch` graph
/// in manual (offline) rendering mode and renders the processed output. This
/// is the same unit and same wiring the production graphs use; no property
/// inspection substitutes for the rendered PCM. The loop and frame budget are
/// strictly bounded.
enum SpeechPlaybackEffectRender {
    static let chunkFrames: AVAudioFrameCount = 4_096

    /// Measured worst-case post-input tail (seconds) across the contract
    /// range: 25.4 ms at 0.15 s/0.5×, 25.4 ms at 48 kHz (measured with real
    /// manual renders; see the lane evidence). The unit reports
    /// `latency == 0` ("unknown or none"), so the drain allowance is
    /// `max(reported, measured)` plus one small control-cycle margin. It is
    /// NOT a sleep: callers wait for this many REAL output frames to render.
    static let measuredTailSeconds: TimeInterval = 0.026
    static let unknownLatencyMarginSeconds: TimeInterval = 0.010

    /// Frames of rendered output that prove the effect's held look-ahead has
    /// drained after the last input receipt.
    static func drainFrameCount(nodeLatencySeconds: TimeInterval, sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return max(1, Int((drainBoundSeconds(nodeLatencySeconds: nodeLatencySeconds) * sampleRate).rounded(.up)))
    }

    /// The documented time allowance behind `drainFrameCount` (diagnostics and
    /// bounded-dead-pipeline math only).
    static func drainBoundSeconds(nodeLatencySeconds: TimeInterval) -> TimeInterval {
        let reported = nodeLatencySeconds.isFinite && nodeLatencySeconds > 0 ? nodeLatencySeconds : 0
        return max(reported, measuredTailSeconds) + unknownLatencyMarginSeconds
    }

    static func render(input: AVAudioPCMBuffer, controls: VoicePlaybackControls,
                       budgetFrames: AVAudioFrameCount,
                       chunkFrames: AVAudioFrameCount = 4_096)
        throws -> AVAudioPCMBuffer {
        let format = input.format
        guard input.frameLength > 0, input.floatChannelData != nil,
              format.commonFormat == .pcmFormatFloat32, format.channelCount > 0,
              format.sampleRate > 0, budgetFrames > chunkFrames else {
            throw SpeechPlaybackEffectRenderFailure.invalidInput
        }
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: chunkFrames)
        } catch {
            throw SpeechPlaybackEffectRenderFailure.manualModeUnavailable
        }
        let player = AVAudioPlayerNode()
        let graph = SpeechPlaybackEffectGraph(controls: controls)
        engine.attach(player)
        // The SAME production wiring both lanes use: player → timePitch → mixer.
        graph.install(in: engine, from: player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(input, at: nil, options: [], completionCallbackType: .dataPlayedBack)
        do {
            try engine.start()
        } catch {
            engine.disableManualRenderingMode()
            throw SpeechPlaybackEffectRenderFailure.engineStartFailed
        }
        defer {
            player.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            engine.detach(player)
            graph.uninstall()
        }
        player.play()
        var chunks: [AVAudioPCMBuffer] = []
        var totalFrames: AVAudioFrameCount = 0
        while totalFrames < budgetFrames {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw SpeechPlaybackEffectRenderFailure.invalidInput
            }
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(chunkFrames, to: chunk)
            } catch {
                throw SpeechPlaybackEffectRenderFailure.renderFailed
            }
            if chunk.frameLength == 0 { break }
            totalFrames += chunk.frameLength
            chunks.append(chunk)
            if status.rawValue < 0 { break }
        }
        guard totalFrames > 0 else { throw SpeechPlaybackEffectRenderFailure.renderFailed }
        guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw SpeechPlaybackEffectRenderFailure.budgetExceeded
        }
        merged.frameLength = totalFrames
        guard let destination = merged.floatChannelData else {
            throw SpeechPlaybackEffectRenderFailure.budgetExceeded
        }
        var written: AVAudioFrameCount = 0
        for chunk in chunks {
            guard let source = chunk.floatChannelData else { continue }
            let frames = min(chunk.frameLength, totalFrames - written)
            for channel in 0..<Int(format.channelCount) {
                destination[channel].advanced(by: Int(written))
                    .update(from: source[channel], count: Int(frames))
            }
            written += frames
        }
        merged.frameLength = written
        return merged
    }
}

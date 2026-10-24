// FloeApp — Frozen playback controls for one spoken output stretch.
//
// SPDX-License-Identifier: MPL-2.0
//
// Foundation-only on purpose: the continuous-voice kernel (interfaces,
// coordinator, bridge seam) must be compilable and testable without
// AVFoundation. The AVAudioUnitTimePitch mapping lives in the AVFoundation
// helper (`Chat/SpeechPlaybackControlGraph.swift`); this value carries only
// the frozen contract numbers. The Core settings type (`FloeCore
// .TTSPlaybackControls`) is mapped explicitly below when FloeCore is linked;
// there is exactly one normalization rule (this initializer), never a second
// clamp inside the audio layer.
//
// Contract (PLAYBACK-CONTROL-CONTRACT / CONTROL-INTERFACE):
//   rate 0.5...2.0, neutral 1.0; pitch −6...+6 semitones, neutral 0.
// Non-finite inputs fall back to neutral instead of inventing a fallback
// channel; out-of-range finite values clamp.

import Foundation

struct VoicePlaybackControls: Equatable, Hashable, Sendable {
    static let rateRange = 0.5...2.0
    static let semitoneRange = -6.0...6.0

    let rateRatio: Double
    let pitchSemitones: Double

    init(rateRatio: Double, pitchSemitones: Double) {
        self.rateRatio = rateRatio.isFinite
            ? Self.clamp(rateRatio, to: Self.rateRange) : 1.0
        self.pitchSemitones = pitchSemitones.isFinite
            ? Self.clamp(pitchSemitones, to: Self.semitoneRange) : 0.0
    }

    static let neutral = VoicePlaybackControls(rateRatio: 1.0, pitchSemitones: 0.0)

    var isNeutral: Bool { rateRatio == 1.0 && pitchSemitones == 0.0 }

    /// `AVAudioUnitTimePitch.pitch` is expressed in cents.
    var pitchCents: Double { pitchSemitones * 100.0 }

    /// Audible output frames this control's rate produces from `inputFrames`
    /// of scheduled source audio (pitch never changes duration). The real
    /// render leads/trails this figure only by the unit's look-ahead, never by
    /// a second factor of the rate; callers use it only for accounting, never
    /// as proof that frames were actually rendered.
    func expectedOutputFrames(for inputFrames: Int) -> Int {
        guard inputFrames > 0 else { return 0 }
        return Int((Double(inputFrames) / rateRatio).rounded())
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

#if canImport(FloeCore)
import FloeCore

extension VoicePlaybackControls {
    /// Explicit bridge from the persisted settings contract. `FloeCore` owns
    /// persistence and its own defensive normalization; this mapping keeps the
    /// same two numbers and never adds a second transform.
    init(_ controls: TTSPlaybackControls) {
        self.init(rateRatio: controls.speechRateRatio,
                  pitchSemitones: controls.speechPitchSemitones)
    }
}
#endif

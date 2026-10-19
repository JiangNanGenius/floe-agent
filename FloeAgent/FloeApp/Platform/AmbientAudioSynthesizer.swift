// FloeApp — the locally synthesized attention cue for the PiP sound surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// The ambient loop is the bundled, licensed meditation track in
// `Resources/Audio/PiPAmbientMeditation.wav`; this file keeps only the short
// attention/terminal chime. Generation is pure math — the tests assert
// determinism, bounded size and the exact PCM framing, not that some player
// object exists.

import Foundation
import os

/// Deterministic procedural audio for the PiP attention cue.
enum AmbientAudioSynthesizer {
    static let sampleRate: Double = 44_100

    // MARK: - Public rendered forms

    /// One short finite chime for terminal/attention cues.
    static func cueWavData() -> Data {
        renderCache.withLock { state in
            if let hit = state.cue { return hit }
            let wav = wav(samples: cueSamples())
            state.cue = wav
            return wav
        }
    }

    // MARK: - Cache (lock-owning Sendable state, no static mutables)

    private struct RenderState {
        var cue: Data?
    }

    private static let renderCache = OSAllocatedUnfairLock(initialState: RenderState())

    // MARK: - Cue

    /// Two quick decaying partials (660/990 Hz), ~0.3 s, finite.
    static var cueSampleCount: Int { Int(0.30 * sampleRate) }

    private static func cueSamples() -> [Float] {
        let total = cueSampleCount
        var out = [Float](repeating: 0, count: total)
        let rate = Float(sampleRate)
        let lowPhaseStep: Float = 2 * Float.pi * 660 / rate
        let highPhaseStep: Float = 2 * Float.pi * 990 / rate
        let attackSamples = 0.004 * rate
        for index in 0..<total {
            let samplePosition = Float(index)
            let t = samplePosition / rate
            let envelope = expf(-t * 9)
            let fade = min(1, t / attackSamples)
            let tone = sinf(samplePosition * lowPhaseStep) * 0.6
                + sinf(samplePosition * highPhaseStep) * 0.35
            out[index] = tone * envelope * fade
        }
        return normalize(out, peak: 0.8)
    }

    private static func normalize(_ samples: [Float], peak: Float) -> [Float] {
        var maxAmplitude: Float = 0
        for sample in samples { maxAmplitude = max(maxAmplitude, abs(sample)) }
        guard maxAmplitude > 0.0001 else { return samples }
        let scale = peak / maxAmplitude
        return samples.map { $0 * scale }
    }

    // MARK: - WAV framing

    /// Mono 16-bit PCM WAV for the finite cue. Small enough to keep fully in
    /// memory.
    private static func wav(samples: [Float]) -> Data {
        var data = Data()
        let frames = UInt32(samples.count)
        let byteRate = UInt32(sampleRate) * 2 // mono 16-bit
        data.appendWAVMagic("RIFF")
        data.appendLE(UInt32(36) + frames * 2)
        data.appendWAVMagic("WAVE")
        data.appendWAVMagic("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // PCM
        data.appendLE(UInt16(1)) // mono
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(UInt16(2)) // block align
        data.appendLE(UInt16(16)) // bits per sample
        data.appendWAVMagic("data")
        data.appendLE(frames * 2)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.appendLE(Int16(clamped * 32_767))
        }
        return data
    }
}

private extension Data {
    mutating func appendWAVMagic(_ magic: String) {
        append(contentsOf: Array(magic.utf8))
    }

    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: Int16) {
        appendLE(UInt16(bitPattern: value))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

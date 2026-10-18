// FloeApp — locally generated seamless ambient loops and the attention cue.
//
// SPDX-License-Identifier: MPL-2.0
//
// Both ambient sounds are synthesized from a fixed seed at runtime: finite,
// crossfade-stitched loops rendered once and cached as 16-bit PCM WAV data.
// Nothing is downloaded and no third-party audio asset is bundled, so there
// is no licence surface and no network dependency. Generation is pure math —
// the tests assert determinism, loop continuity, bounded size and that the
// two sounds are spectrally distinct, not that some player object exists.

import Foundation
import os

/// Deterministic procedural audio for the PiP sound surface.
enum AmbientAudioSynthesizer {
    static let sampleRate: Double = 44_100
    /// Audible loop length (rain).
    static let rainLoopSeconds: Double = 6.0
    /// Audible loop length (brown noise).
    static let brownLoopSeconds: Double = 8.0
    /// Head/tail equal-energy crossfade window that makes the loop seam-free.
    static let crossfadeSeconds: Double = 0.5

    private enum Seed {
        static let rain: UInt64 = 0x52_41_49_4E_20_56_31_00 // "RAIN V1 "
        static let brown: UInt64 = 0x42_52_4F_57_4E_56_31_00 // "BROWN V1"
    }

    // MARK: - Public rendered forms

    /// Looping PCM payload for one ambient sound. Cached per sound; bounded
    /// by the fixed loop durations above (~0.5–0.7 MB int16 mono each).
    static func wavData(for sound: PiPAmbientSound) -> Data {
        switch sound {
        case .rain:
            return renderCache.withLock { state in
                if let hit = state.loops[sound.rawValue] { return hit }
                let wav = wav(samples: rainSamples(
                    count: sampleCount(rainLoopSeconds), seed: Seed.rain
                ))
                state.loops[sound.rawValue] = wav
                return wav
            }
        case .brownNoise:
            return renderCache.withLock { state in
                if let hit = state.loops[sound.rawValue] { return hit }
                let wav = wav(samples: brownNoiseSamples(
                    count: sampleCount(brownLoopSeconds), seed: Seed.brown
                ))
                state.loops[sound.rawValue] = wav
                return wav
            }
        }
    }

    /// One short finite chime for terminal/attention cues.
    static func cueWavData() -> Data {
        renderCache.withLock { state in
            if let hit = state.cue { return hit }
            let wav = wav(samples: cueSamples())
            state.cue = wav
            return wav
        }
    }

    /// Raw float samples (−1…1) for tests and diagnostics; no WAV framing.
    static func loopSamples(for sound: PiPAmbientSound) -> [Float] {
        switch sound {
        case .rain:
            return rainSamples(count: sampleCount(rainLoopSeconds), seed: Seed.rain)
        case .brownNoise:
            return brownNoiseSamples(count: sampleCount(brownLoopSeconds), seed: Seed.brown)
        }
    }

    // MARK: - Cache (lock-owning Sendable state, no static mutables)

    private struct RenderState {
        var loops: [String: Data] = [:]
        var cue: Data?
    }

    private static let renderCache = OSAllocatedUnfairLock(initialState: RenderState())

    /// Test/diagnostic hook: drops the rendered caches so a cold regeneration
    /// can be measured. Production code never calls this.
    static func clearCachesForTesting() {
        renderCache.withLock { state in
            state.loops = [:]
            state.cue = nil
        }
    }

    // MARK: - Rain

    /// Filtered noise bed plus sparse droplet transients. Deliberately keeps
    /// high-frequency energy so it is audibly distinct from brown noise.
    private static func rainSamples(count: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let raw = renderSeamlessLoop(count: count) { total in
            var out = [Float](repeating: 0, count: total)
            let rate = Float(sampleRate)
            // Bed: lightly low-passed white noise with three slow swells.
            let loopSeconds = Float(total) / rate
            let swellStep: Float = 3.0 / max(loopSeconds, 0.001)
            let twoPi: Float = 2 * Float.pi
            var lowpass: Float = 0
            var swellPhase: Float = 0
            for index in 0..<total {
                let white: Float = rng.nextFloat() * 2 - 1
                lowpass += 0.22 * (white - lowpass)
                swellPhase += swellStep
                let swell: Float = 1 + 0.28 * sinf(swellPhase * twoPi)
                out[index] = (white * 0.34 + lowpass * 0.55) * swell
            }
            // Droplets: short decaying sine bursts at random pitch plus a
            // 1–3 ms broadband tick. Rate ~12/s, deterministic from the seed.
            let dropletsPerSecond: Float = 12
            let tickSamples: Float = 0.0022 * rate
            var position: Float = rng.nextFloat() * 0.5 * rate
            while position < Float(total) {
                let lengthSamples: Int = Int(0.012 * rate) + Int(rng.nextUInt32() % 30) * Int(rate / 1000)
                let pitch: Float = 420 + Float(rng.nextUInt32() % 1900)
                let amplitude: Float = 0.16 + rng.nextFloat() * 0.20
                let tau: Float = max(1, 0.006 * rate + Float(rng.nextUInt32() % 24) * (rate / 1000))
                let phaseStep: Float = twoPi * pitch / rate
                let baseIndex = Int(position)
                for offset in 0..<lengthSamples {
                    let index = baseIndex + offset
                    if index >= total { break }
                    let t = Float(offset)
                    let decay = expf(-t / tau)
                    let tone = sinf(t * phaseStep)
                    let tick: Float
                    if t < tickSamples {
                        tick = (rng.nextFloat() * 2 - 1) * 0.35
                    } else {
                        tick = 0
                    }
                    out[index] += amplitude * decay * tone + tick * decay
                }
                // Poisson-ish spacing in samples.
                let intervalSeconds = -logf(max(rng.nextFloat(), 0.0001)) / dropletsPerSecond
                position += intervalSeconds * rate * 0.5
            }
            return out
        }
        return normalize(raw, peak: 0.9)
    }

    // MARK: - Brown noise

    /// Leaky-integrated white noise: almost all energy below a few hundred
    /// hertz. Same band shape regardless of seed so it stays a true loop.
    private static func brownNoiseSamples(count: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let raw = renderSeamlessLoop(count: count) { total in
            var out = [Float](repeating: 0, count: total)
            var brown: Float = 0
            for index in 0..<total {
                let white: Float = rng.nextFloat() * 2 - 1
                brown += 0.018 * white - 0.0015 * brown
                if brown > 1 { brown = 1 }
                if brown < -1 { brown = -1 }
                out[index] = brown
            }
            // Gentle level breathing so the rumble never sounds static.
            let twoPi: Float = 2 * Float.pi
            let denominator = Float(max(total, 1))
            for index in 0..<total {
                let phase = Float(index) / denominator * twoPi * 2
                out[index] *= 1 + 0.18 * sinf(phase)
            }
            return out
        }
        return normalize(raw, peak: 0.9)
    }

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

    // MARK: - Loop stitching

    /// Generates `count + crossfade` samples and folds the extra tail into
    /// the head with an equal-power crossfade, so index `count-1 → 0` is a
    /// natural continuation of the source sequence, not a hard seam.
    private static func renderSeamlessLoop(
        count: Int,
        generate: (_ total: Int) -> [Float]
    ) -> [Float] {
        let fade = Int(crossfadeSeconds * sampleRate)
        let total = count + fade
        let raw = generate(total)
        var out = [Float](repeating: 0, count: count)
        let fadeFloat = Float(fade)
        for index in 0..<count {
            if index < fade {
                let t = Float(index) / fadeFloat
                let headWeight = sqrtf(t)
                let tailWeight = sqrtf(max(0, 1 - t))
                out[index] = raw[index] * headWeight + raw[count + index] * tailWeight
            } else {
                out[index] = raw[index]
            }
        }
        return out
    }

    private static func sampleCount(_ seconds: Double) -> Int {
        Int(seconds * sampleRate)
    }

    private static func normalize(_ samples: [Float], peak: Float) -> [Float] {
        var maxAmplitude: Float = 0
        for sample in samples { maxAmplitude = max(maxAmplitude, abs(sample)) }
        guard maxAmplitude > 0.0001 else { return samples }
        let scale = peak / maxAmplitude
        return samples.map { $0 * scale }
    }

    // MARK: - WAV framing

    /// Mono 16-bit PCM WAV. Small enough to keep fully in memory; the real
    /// player decodes once per loop and holds no expanding buffers.
    static func wav(samples: [Float]) -> Data {
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

    /// Mean-square energy above a ~350 Hz one-pole split. Tests use it to
    /// prove rain ≠ brown audibly without an FFT dependency.
    static func highFrequencyEnergy(_ samples: [Float]) -> Double {
        guard samples.count > 8 else { return 0 }
        var lowpass: Float = 0
        var energy: Double = 0
        for sample in samples {
            lowpass += 0.05 * (sample - lowpass)
            let high = sample - lowpass
            energy += Double(high * high)
        }
        return energy / Double(samples.count)
    }

    /// Mean-square energy of the same one-pole low pass (a few hundred Hz).
    static func lowFrequencyEnergy(_ samples: [Float]) -> Double {
        guard samples.count > 8 else { return 0 }
        var lowpass: Float = 0
        var energy: Double = 0
        for sample in samples {
            lowpass += 0.05 * (sample - lowpass)
            energy += Double(lowpass * lowpass)
        }
        return energy / Double(samples.count)
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

/// SplitMix64: deterministic, allocation-free PRNG. Fixed seeds make every
/// rendered loop byte-identical across launches and devices.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUInt32() -> UInt32 {
        UInt32(truncatingIfNeeded: nextUInt64() >> 32)
    }

    /// Uniform in 0…1 (exclusive of 1).
    mutating func nextFloat() -> Float {
        Float(nextUInt32() >> 8) / Float(1 << 24)
    }
}

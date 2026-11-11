// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMeetings

/// Stateful Float32 mono → PCM16 little-endian mono resampler for the
/// continuous live-ASR feed. Providers require 16 kHz PCM16 while the shared
/// capture tap delivers the route's native rate (8–192 kHz).
///
/// Decimation is preceded by a real anti-aliasing stage: a windowed-sinc FIR
/// low-pass at 0.45× the target Nyquist band, streamed with a carry buffer so
/// the output is identical whether a burst arrives as one frame or many, and
/// fractional tap positions are evaluated by interpolating between adjacent
/// FIR phases. Without this stage, source content above the target Nyquist
/// frequency would alias into the recognition band instead of being rejected.
///
/// The lossless original and the AAC chunks are written by the recorder
/// unaffected; this stream is the recognition input only.
public struct MeetingPCMDownsampler: Sendable {
    public let targetSampleRate: Double

    /// FIR state, rebuilt when the source rate changes (the recorder
    /// guarantees a constant rate per capture, so this happens at most once).
    private var ratio: Double = 1
    private var kernel: [Float] = []
    private var halfWidth = 0

    /// Stream-position bookkeeping: `base` is the absolute index of
    /// `pending[0]`, `nextTap` the absolute fractional center of the next
    /// output sample.
    private var pending: [Float] = []
    private var base: Int64 = 0
    private var nextTap: Double = 0

    public init(targetSampleRate: Double = 16_000) throws {
        guard targetSampleRate.isFinite, (8_000...48_000).contains(targetSampleRate) else {
            throw MeetingError.captureBackendFailed("Unsupported live-ASR target sample rate.")
        }
        self.targetSampleRate = targetSampleRate
    }

    /// Resample one captured frame (little-endian Float32 samples). Returns
    /// PCM16 little-endian mono data ready for `ASRLiveSession.feed`.
    public mutating func push(_ frame: Data, sourceSampleRate: Double) throws -> Data {
        guard sourceSampleRate.isFinite, (8_000...192_000).contains(sourceSampleRate) else {
            throw MeetingError.captureBackendFailed("Unsupported live-ASR source sample rate.")
        }
        guard frame.count % MemoryLayout<Float>.size == 0 else {
            throw MeetingError.captureBackendFailed("Invalid live-ASR frame alignment.")
        }
        let incoming = frame.withUnsafeBytes { raw -> [Float] in
            let bound = raw.bindMemory(to: Float.self)
            return Array(bound)
        }
        guard !incoming.isEmpty else { return Data() }
        try configureIfNeeded(sourceSampleRate: sourceSampleRate)
        var buffer = pending
        buffer.append(contentsOf: incoming)
        let bufferBase = base
        let end = bufferBase + Int64(buffer.count)
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(incoming.count) / ratio) + 2)
        while nextTap + Double(halfWidth) <= Double(end) - 1 {
            output.append(Self.pcm16(evaluate(buffer, at: nextTap - Double(bufferBase))))
            nextTap += ratio
        }
        // Keep the samples the next FIR window can still touch: a later tap
        // looks back halfWidth from positions up to halfWidth + one ratio
        // step past this buffer's end.
        let keepCount = 2 * halfWidth + Int(ratio.rounded(.up)) + 2
        let keepFrom = max(bufferBase, end - Int64(keepCount))
        if keepFrom > bufferBase {
            let drop = Int(keepFrom - bufferBase)
            pending = Array(buffer[drop...])
            base = keepFrom
        } else {
            pending = buffer
        }
        return output.withUnsafeBytes { Data($0) }
    }

    /// Drain the stream tail after the last push. Bounded by the FIR half
    /// width; taps past the final sample clamp to it.
    public mutating func flush() -> Data {
        guard !kernel.isEmpty else { return Data() }
        var output: [Int16] = []
        let end = base + Int64(pending.count)
        while nextTap <= Double(end) - 1 {
            output.append(Self.pcm16(evaluate(pending, at: nextTap - Double(base))))
            nextTap += ratio
        }
        return output.withUnsafeBytes { Data($0) }
    }

    // MARK: - Filter

    private mutating func configureIfNeeded(sourceSampleRate: Double) throws {
        let newRatio = sourceSampleRate / targetSampleRate
        guard newRatio != ratio || kernel.isEmpty else { return }
        // Anti-aliasing corner: below half the target band, with a transition
        // wide enough to keep the tap count bounded at extreme ratios.
        let corner = min(sourceSampleRate, targetSampleRate) * 0.45
        let taps = 2 * Int(ceil(6 * max(1, newRatio))) + 1
        kernel = Self.windowedSincLowPass(corner: corner, sampleRate: sourceSampleRate, taps: taps)
        halfWidth = (taps - 1) / 2
        ratio = newRatio
    }

    /// Hann-windowed sinc low-pass, DC-normalized to unit gain.
    static func windowedSincLowPass(corner: Double, sampleRate: Double, taps: Int) -> [Float] {
        let count = max(3, taps | 1)
        let half = (count - 1) / 2
        let normalized = corner / sampleRate // cycles per sample
        var coefficients = [Float](repeating: 0, count: count)
        var sum: Float = 0
        for index in 0..<count {
            let offset = index - half
            let sinc: Double
            if offset == 0 {
                sinc = 2 * normalized
            } else {
                let phase = 2 * .pi * normalized * Double(offset)
                sinc = sin(phase) / (.pi * Double(offset))
            }
            let window = 0.5 * (1 - cos(2 * .pi * Double(index) / Double(count - 1)))
            let value = Float(sinc * window)
            coefficients[index] = value
            sum += value
        }
        guard sum > 0 else { return coefficients }
        return coefficients.map { $0 / sum }
    }

    /// Fractional-position FIR evaluation with linear interpolation between
    /// adjacent tap phases; reads outside the buffer clamp to its ends.
    private func evaluate(_ buffer: [Float], at position: Double) -> Float {
        var accumulator: Float = 0
        let lower = Int(position.rounded(.down))
        let fraction = Float(position - Double(lower))
        for tap in 0..<kernel.count {
            let offset = lower + tap - halfWidth
            let a = sample(buffer, at: offset)
            let b = sample(buffer, at: offset + 1)
            accumulator += kernel[tap] * (a + (b - a) * fraction)
        }
        return accumulator
    }

    private func sample(_ buffer: [Float], at index: Int) -> Float {
        if index < 0 { return buffer.first ?? 0 }
        if index >= buffer.count { return buffer.last ?? 0 }
        return buffer[index]
    }

    static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clamped = max(-1, min(1, sample))
        return Int16((clamped * 32_767).rounded())
    }
}

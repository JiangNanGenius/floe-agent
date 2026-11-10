// SPDX-License-Identifier: MPL-2.0
import Foundation
import Accelerate

private struct AudioPCMField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func audioPCMRequireFields(_ decoder: any Decoder, _ allowed: Set<String>) throws {
    let all = try decoder.container(keyedBy: AudioPCMField.self)
    if let unknown = all.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [unknown], debugDescription: "Unknown audio effect field"))
    }
}

public enum AudioPCMProcessingError: Error, Sendable, Equatable {
    case invalidInput(String)
    case limitExceeded(String)
    case cancelled
    case transformUnavailable
    case changedSource
}

/// Planar Float32 PCM in its own source clock. No hardware input or playback.
public struct AudioPCM: Sendable, Equatable {
    public let sampleRate: Double
    public var channels: [[Float]]
    public init(sampleRate: Double, channels: [[Float]]) throws {
        self.sampleRate = sampleRate; self.channels = channels
        try validate()
    }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var durationSeconds: Double { Double(frameCount) / sampleRate }
    public func validate(maximumBytes: Int = 64 * 1_024 * 1_024) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), (1...2).contains(channels.count),
              frameCount > 0, channels.allSatisfy({ $0.count == frameCount }) else { throw AudioPCMProcessingError.invalidInput("finite mono/stereo PCM with equal nonempty channels is required") }
        guard maximumBytes > 0, frameCount <= maximumBytes / (channels.count * MemoryLayout<Float>.stride) else { throw AudioPCMProcessingError.limitExceeded("PCM exceeds its explicit memory budget") }
        guard channels.allSatisfy({ $0.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) }) else { throw AudioPCMProcessingError.invalidInput("non-finite or out-of-range PCM samples") }
    }
}

public struct AudioPCMMeasurement: Codable, Sendable, Equatable {
    public let frames: Int
    public let sampleRate: Double
    public let channels: Int
    public let peak: Double
    public let rms: Double
    public init(_ pcm: AudioPCM) {
        frames = pcm.frameCount; sampleRate = pcm.sampleRate; channels = pcm.channels.count
        var peak = 0.0, power = 0.0
        for channel in pcm.channels { for value in channel { peak = max(peak, abs(Double(value))); power += Double(value) * Double(value) } }
        self.peak = peak; rms = sqrt(power / Double(max(1, frames * channels)))
    }
}

public struct AudioPCMWork: Sendable {
    public var isCancelled: @Sendable () -> Bool
    public var progress: @Sendable (Double) -> Void
    public init(isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.isCancelled = isCancelled; self.progress = progress
    }
    public func check() throws { if isCancelled() || Task.isCancelled { throw AudioPCMProcessingError.cancelled } }
}

/// An explicit noise-only interval in the supplied PCM, rather than a speech
/// detector or a gate. nil selects a bounded lower-quantile spectral estimate.
public struct AudioNoiseProfileRange: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var durationSeconds: Double
    public init(startSeconds: Double, durationSeconds: Double) { self.startSeconds = startSeconds; self.durationSeconds = durationSeconds }
    private enum CodingKeys: String, CodingKey { case startSeconds, durationSeconds }
    public init(from decoder: any Decoder) throws {
        try audioPCMRequireFields(decoder, ["startSeconds", "durationSeconds"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startSeconds: try values.decode(Double.self, forKey: .startSeconds), durationSeconds: try values.decode(Double.self, forKey: .durationSeconds))
    }
}

public struct AudioSpectralDenoiseSettings: Codable, Sendable, Equatable {
    public var amount: Double
    public var maximumReductionDB: Double
    public var noiseOnlyRange: AudioNoiseProfileRange?
    public init(amount: Double = 0.8, maximumReductionDB: Double = 18, noiseOnlyRange: AudioNoiseProfileRange? = nil) {
        self.amount = amount; self.maximumReductionDB = maximumReductionDB; self.noiseOnlyRange = noiseOnlyRange
    }
    private enum CodingKeys: String, CodingKey { case amount, maximumReductionDB, noiseOnlyRange }
    public init(from decoder: any Decoder) throws {
        try audioPCMRequireFields(decoder, ["amount", "maximumReductionDB", "noiseOnlyRange"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(amount: try values.decodeIfPresent(Double.self, forKey: .amount) ?? 0.8,
            maximumReductionDB: try values.decodeIfPresent(Double.self, forKey: .maximumReductionDB) ?? 18,
            noiseOnlyRange: try values.decodeIfPresent(AudioNoiseProfileRange.self, forKey: .noiseOnlyRange))
        do { try validate() } catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid spectral noise-reduction settings")) }
    }
    public func validate() throws {
        guard amount.isFinite, (0...1).contains(amount), maximumReductionDB.isFinite, (0...36).contains(maximumReductionDB) else { throw AudioPCMProcessingError.invalidInput("denoise amount must be 0...1 and maximum reduction 0...36 dB") }
        if let range = noiseOnlyRange {
            guard range.startSeconds.isFinite, range.startSeconds >= 0, range.durationSeconds.isFinite, range.durationSeconds > 0 else { throw AudioPCMProcessingError.invalidInput("noise-only interval must be finite and positive") }
        }
    }
}

public struct AudioSpectralDenoiseResult: Sendable {
    public let pcm: AudioPCM
    public let input: AudioPCMMeasurement
    public let output: AudioPCMMeasurement
    public let profileMethod: String
    public let profileFrames: Int
    public let fftLength: Int
    public let hopLength: Int
    public let limitations: [String]
}

/// Welch spectral noise profile -> bounded Wiener gain -> overlap-add.
/// Desired audio is processed while present; this is not amplitude gating.
public enum AudioSpectralDenoiser {
    private static let length = 2_048
    private static let hop = 512
    private static let maximumProfileFrames = 256

    public static func process(_ pcm: AudioPCM, settings: AudioSpectralDenoiseSettings = .init(), work: AudioPCMWork = .init()) throws -> AudioSpectralDenoiseResult {
        try work.check(); try pcm.validate(); try settings.validate()
        let before = AudioPCMMeasurement(pcm)
        if settings.amount == 0 || settings.maximumReductionDB == 0 {
            return .init(pcm: pcm, input: before, output: before, profileMethod: "bypass", profileFrames: 0, fftLength: length, hopLength: hop, limitations: [])
        }
        let transform = try AudioComplexDFT(length: length)
        let window = (0..<length).map { Float(sin(Double.pi * (Double($0) + 0.5) / Double(length))) }
        let profile = try makeProfile(pcm, settings: settings, window: window, transform: transform, work: work)
        let floorGain = Float(pow(10, -settings.maximumReductionDB / 20))
        var output = [[Float]](repeating: [Float](repeating: 0, count: pcm.frameCount), count: pcm.channels.count)
        var normalization = [Float](repeating: 0, count: pcm.frameCount)
        var previous = [Float](repeating: 1, count: length)
        let frameCount = (pcm.frameCount + length / 2 + hop - 1) / hop
        for frame in 0..<frameCount {
            try work.check()
            let start = frame * hop - length / 2
            var spectra = [(real: [Float], imaginary: [Float])]()
            var power = [Float](repeating: 0, count: length)
            for channel in pcm.channels {
                var input = [Float](repeating: 0, count: length)
                for j in 0..<length where (0..<pcm.frameCount).contains(start + j) { input[j] = channel[start + j] * window[j] }
                let spectrum = transform.forward(input)
                for bin in 0..<length { power[bin] += (spectrum.real[bin] * spectrum.real[bin] + spectrum.imaginary[bin] * spectrum.imaginary[bin]) / Float(pcm.channels.count) }
                spectra.append(spectrum)
            }
            var rawGains = [Float](repeating: 0, count: length)
            for bin in 0..<length {
                let residual = max(0, 1 - Float(settings.amount) * profile.power[bin] / max(power[bin], 1e-20))
                rawGains[bin] = max(floorGain, sqrt(residual))
            }
            var gains = rawGains
            for bin in 0..<length {
                let left = (bin + length - 1) % length, right = (bin + 1) % length
                let spatial = rawGains[bin] * 0.5 + (rawGains[left] + rawGains[right]) * 0.25
                // Faster attenuation and slower recovery suppress musical
                // noise without shifting or replacing the source waveform.
                let blend: Float = spatial < previous[bin] ? 0.7 : 0.25
                gains[bin] = previous[bin] + blend * (spatial - previous[bin])
            }
            previous = gains
            for channel in spectra.indices {
                var spectrum = spectra[channel]
                for bin in 0..<length { spectrum.real[bin] *= gains[bin]; spectrum.imaginary[bin] *= gains[bin] }
                let samples = transform.inverse(spectrum)
                for j in 0..<length where (0..<pcm.frameCount).contains(start + j) { output[channel][start + j] += samples[j] * window[j] }
            }
            for j in 0..<length where (0..<pcm.frameCount).contains(start + j) { normalization[start + j] += window[j] * window[j] }
            if frame % 16 == 0 { work.progress(0.15 + 0.8 * Double(frame + 1) / Double(frameCount)) }
        }
        for i in normalization.indices {
            if i % 8_192 == 0 { try work.check() }
            guard normalization[i] > 1e-12 else { throw AudioPCMProcessingError.transformUnavailable }
            for channel in output.indices { output[channel][i] /= normalization[i] }
        }
        let result = try AudioPCM(sampleRate: pcm.sampleRate, channels: output)
        try work.check(); work.progress(1)
        let notes = settings.noiseOnlyRange == nil
            ? ["Automatic lower-quantile estimation targets steady background noise. Continuous desired tones or dense music can be reduced; select a noise-only interval when available.", "This is spectral noise reduction, not a neural speech/music separator. Time-varying noise and overlapping voices may remain."]
            : ["The selected interval must contain background noise only. Desired material in that interval may also be reduced.", "Time-varying noise, overlapping voices and reverberation may remain; this is not neural speech/music separation."]
        return .init(pcm: result, input: before, output: .init(result), profileMethod: settings.noiseOnlyRange == nil ? "lower-quantile-spectral" : "explicit-noise-only-welch", profileFrames: profile.frames, fftLength: length, hopLength: hop, limitations: notes)
    }

    private static func makeProfile(_ pcm: AudioPCM, settings: AudioSpectralDenoiseSettings, window: [Float], transform: AudioComplexDFT, work: AudioPCMWork) throws -> (power: [Float], frames: Int) {
        let lower: Int, upper: Int
        if let range = settings.noiseOnlyRange {
            guard range.startSeconds + range.durationSeconds <= pcm.durationSeconds + 0.5 / pcm.sampleRate,
                  range.durationSeconds * pcm.sampleRate >= Double(length) else { throw AudioPCMProcessingError.invalidInput("noise-only interval must fit the supplied audio and contain at least one FFT window") }
            lower = Int((range.startSeconds * pcm.sampleRate).rounded()); upper = min(pcm.frameCount, Int(((range.startSeconds + range.durationSeconds) * pcm.sampleRate).rounded()))
        } else { lower = 0; upper = pcm.frameCount }
        let possible = max(1, (upper - lower + hop - 1) / hop)
        let count = min(maximumProfileFrames, possible)
        var powers = [[Float]](repeating: [], count: length)
        for frame in 0..<count {
            try work.check()
            let center = lower + (count == 1 ? (upper - lower) / 2 : Int(Double(frame) * Double(max(0, upper - lower - 1)) / Double(count - 1)))
            let start = center - length / 2
            var power = [Float](repeating: 0, count: length)
            for channel in pcm.channels {
                var input = [Float](repeating: 0, count: length)
                for j in 0..<length where (lower..<upper).contains(start + j) { input[j] = channel[start + j] * window[j] }
                let spectrum = transform.forward(input)
                for bin in 0..<length { power[bin] += (spectrum.real[bin] * spectrum.real[bin] + spectrum.imaginary[bin] * spectrum.imaginary[bin]) / Float(pcm.channels.count) }
            }
            for bin in 0..<length { powers[bin].append(power[bin]) }
            if frame % 16 == 0 { work.progress(0.15 * Double(frame + 1) / Double(count)) }
        }
        var profile = [Float](repeating: 0, count: length)
        for bin in 0..<length {
            if settings.noiseOnlyRange != nil { profile[bin] = powers[bin].reduce(0, +) / Float(count) }
            else {
                let sorted = powers[bin].sorted(), selected = sorted[Int(Double(count - 1) * 0.2)]
                // Conservative scale: exponential-bin mean is ~4.48*q20.
                // Use 2*q20 to limit suppression of continuously active audio.
                profile[bin] = selected * 2
            }
        }
        return (profile, count)
    }
}

private final class AudioComplexDFT {
    let length: Int
    private let analysis: vDSP_DFT_Setup
    private let synthesis: vDSP_DFT_Setup
    init(length: Int) throws {
        guard let analysis = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else { throw AudioPCMProcessingError.transformUnavailable }
        guard let synthesis = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .INVERSE) else { vDSP_DFT_DestroySetup(analysis); throw AudioPCMProcessingError.transformUnavailable }
        self.length = length; self.analysis = analysis; self.synthesis = synthesis
    }
    deinit { vDSP_DFT_DestroySetup(analysis); vDSP_DFT_DestroySetup(synthesis) }
    func forward(_ input: [Float]) -> (real: [Float], imaginary: [Float]) {
        let imaginary = [Float](repeating: 0, count: length)
        var realOutput = imaginary, imaginaryOutput = imaginary
        vDSP_DFT_Execute(analysis, input, imaginary, &realOutput, &imaginaryOutput)
        return (realOutput, imaginaryOutput)
    }
    func inverse(_ input: (real: [Float], imaginary: [Float])) -> [Float] {
        var realOutput = [Float](repeating: 0, count: length), imaginaryOutput = realOutput
        vDSP_DFT_Execute(synthesis, input.real, input.imaginary, &realOutput, &imaginaryOutput)
        let scale = Float(length)
        for i in realOutput.indices { realOutput[i] /= scale }
        return realOutput
    }
}

public struct AudioDuckingSettings: Codable, Sendable, Equatable {
    public var thresholdDB: Double
    public var reductionDB: Double
    public var kneeDB: Double
    public var attackSeconds: Double
    public var releaseSeconds: Double
    public var holdSeconds: Double
    public var lookAheadSeconds: Double
    public init(thresholdDB: Double = -38, reductionDB: Double = 12, kneeDB: Double = 6, attackSeconds: Double = 0.02, releaseSeconds: Double = 0.35, holdSeconds: Double = 0.08, lookAheadSeconds: Double = 0.015) {
        self.thresholdDB = thresholdDB; self.reductionDB = reductionDB; self.kneeDB = kneeDB; self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds; self.holdSeconds = holdSeconds; self.lookAheadSeconds = lookAheadSeconds
    }
    private enum CodingKeys: String, CodingKey { case thresholdDB, reductionDB, kneeDB, attackSeconds, releaseSeconds, holdSeconds, lookAheadSeconds }
    public init(from decoder: any Decoder) throws {
        try audioPCMRequireFields(decoder, ["thresholdDB", "reductionDB", "kneeDB", "attackSeconds", "releaseSeconds", "holdSeconds", "lookAheadSeconds"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(thresholdDB: try values.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? -38,
            reductionDB: try values.decodeIfPresent(Double.self, forKey: .reductionDB) ?? 12,
            kneeDB: try values.decodeIfPresent(Double.self, forKey: .kneeDB) ?? 6,
            attackSeconds: try values.decodeIfPresent(Double.self, forKey: .attackSeconds) ?? 0.02,
            releaseSeconds: try values.decodeIfPresent(Double.self, forKey: .releaseSeconds) ?? 0.35,
            holdSeconds: try values.decodeIfPresent(Double.self, forKey: .holdSeconds) ?? 0.08,
            lookAheadSeconds: try values.decodeIfPresent(Double.self, forKey: .lookAheadSeconds) ?? 0.015)
        do { try validate() } catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid dialogue-ducking settings")) }
    }
    public func validate() throws {
        guard thresholdDB.isFinite, (-80...0).contains(thresholdDB), reductionDB.isFinite, (0...36).contains(reductionDB),
              kneeDB.isFinite, (0.1...24).contains(kneeDB), attackSeconds.isFinite, (0.001...1).contains(attackSeconds),
              releaseSeconds.isFinite, (0.01...5).contains(releaseSeconds), holdSeconds.isFinite, (0...2).contains(holdSeconds),
              lookAheadSeconds.isFinite, (0...0.1).contains(lookAheadSeconds) else { throw AudioPCMProcessingError.invalidInput("ducking settings are outside their supported range") }
    }
}

public struct AudioDuckingResult: Sendable {
    public let pcm: AudioPCM
    public let input: AudioPCMMeasurement
    public let output: AudioPCMMeasurement
    public let sidechain: AudioPCMMeasurement
    public let minimumGain: Double
    public let attenuatedFrames: Int
    public let sidechainStartSeconds: Double
}

/// The narration drives an RMS detector and a smooth, linked-channel gain.
/// A silent/out-of-window sidechain never statically attenuates the music.
public enum AudioSidechainDucker {
    public static func process(target: AudioPCM, sidechain: AudioPCM, sidechainStartSeconds: Double = 0, settings: AudioDuckingSettings = .init(), work: AudioPCMWork = .init()) throws -> AudioDuckingResult {
        try work.check(); try target.validate(); try sidechain.validate(); try settings.validate()
        guard target.sampleRate == sidechain.sampleRate, sidechainStartSeconds.isFinite,
              abs(sidechainStartSeconds) <= 100_000 else { throw AudioPCMProcessingError.invalidInput("sidechain must share the target sample clock and have a finite relative start") }
        let offset = Int((sidechainStartSeconds * target.sampleRate).rounded())
        let lookAhead = Int((settings.lookAheadSeconds * target.sampleRate).rounded())
        let attack = exp(-1 / (settings.attackSeconds * target.sampleRate)), release = exp(-1 / (settings.releaseSeconds * target.sampleRate))
        let detector = exp(-1 / (0.005 * target.sampleRate)), hold = Int((settings.holdSeconds * target.sampleRate).rounded())
        var envelopes = [Float](repeating: 0, count: sidechain.frameCount), rmsPower = 0.0
        for i in envelopes.indices {
            if i % 8_192 == 0 { try work.check() }
            var power = 0.0
            for channel in sidechain.channels { power = max(power, Double(channel[i]) * Double(channel[i])) }
            rmsPower = detector * rmsPower + (1 - detector) * power
            envelopes[i] = Float(sqrt(max(0, rmsPower)))
        }
        var output = target.channels, gain = 1.0, heldGain = 1.0, remainingHold = 0, minimum = 1.0, attenuated = 0
        for i in 0..<target.frameCount {
            if i % 8_192 == 0 { try work.check(); work.progress(Double(i) / Double(target.frameCount)) }
            let position = i + lookAhead - offset
            let rms = envelopes.indices.contains(position) ? Double(envelopes[position]) : 0
            let levelDB = 20 * log10(max(1e-12, rms))
            let amount = max(0, min(1, (levelDB - settings.thresholdDB) / settings.kneeDB))
            var desired = pow(10, -settings.reductionDB * amount / 20)
            if amount > 0 { heldGain = desired; remainingHold = hold }
            else if remainingHold > 0 { desired = heldGain; remainingHold -= 1 }
            let smoothing = desired < gain ? attack : release
            gain = desired + smoothing * (gain - desired)
            minimum = min(minimum, gain)
            if gain < 0.999 { attenuated += 1 }
            for channel in output.indices { output[channel][i] *= Float(gain) }
        }
        let result = try AudioPCM(sampleRate: target.sampleRate, channels: output)
        try work.check(); work.progress(1)
        return .init(pcm: result, input: .init(target), output: .init(result), sidechain: .init(sidechain), minimumGain: minimum, attenuatedFrames: attenuated, sidechainStartSeconds: sidechainStartSeconds)
    }
}

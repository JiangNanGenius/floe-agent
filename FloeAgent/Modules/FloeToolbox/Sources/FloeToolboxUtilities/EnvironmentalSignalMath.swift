import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Bounded rolling retention for environmental samples. Oldest values drop past capacity.
public struct SignalSampleBuffer<Value: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Value] = []
    public private(set) var droppedCount: Int = 0
    public init(capacity: Int) {
        precondition((1...1_000_000).contains(capacity), "capacity out of range")
        self.capacity = capacity
    }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    /// Oldest first.
    public var values: [Value] { storage }
    public mutating func append(_ value: Value) {
        if storage.count == capacity { storage.removeFirst(); droppedCount += 1 }
        storage.append(value)
    }
    public mutating func reset() { storage.removeAll(); droppedCount = 0 }
}

/// Pure signal/pressure math for the environmental workbenches. Everything here is
/// deterministic and free of hardware state so it can be verified without sensors.
public enum EnvironmentalSignalMath {
    /// Digital silence floor for level display, in dBFS. Raw digital levels are
    /// relative full-scale readings, never calibrated sound-pressure levels.
    public static let dbFloor: Double = -160

    /// Digital full-scale level for a linear RMS value. Non-positive or non-finite
    /// input reports the silence floor; results never exceed 0 dBFS.
    public static func dbFS(rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return dbFloor }
        return min(max(20 * log10(rms), dbFloor), 0)
    }

    /// Root-mean-square of mono samples in linear units; nil for empty input.
    /// Non-finite samples count as silence so a broken frame never poisons a level.
    public static func rms(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var sum = 0.0
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Largest absolute sample; nil for empty input. Non-finite samples count as silence.
    public static func peak(_ samples: [Float]) -> Float? {
        guard !samples.isEmpty else { return nil }
        var result: Float = 0
        for sample in samples {
            let value = sample.isFinite ? abs(sample) : 0
            if value > result { result = value }
        }
        return result
    }

    /// Barometric unit conversions; nil for non-finite input.
    public static func hectopascals(fromKilopascals kilopascals: Double) -> Double? {
        guard kilopascals.isFinite else { return nil }
        return kilopascals * 10
    }

    public static func kilopascals(fromHectopascals hectopascals: Double) -> Double? {
        guard hectopascals.isFinite else { return nil }
        return hectopascals / 10
    }

    /// Altitude relative to a zero baseline in the same units (subtraction only —
    /// the baseline provenance stays with the caller). Nil on non-finite input.
    public static func relativeAltitude(current: Double, baseline: Double) -> Double? {
        guard current.isFinite, baseline.isFinite else { return nil }
        return current - baseline
    }

    /// International Standard Atmosphere pressure-altitude relation: the altitude
    /// difference in meters between `pressureHpa` and `referenceHpa`. This is a
    /// reference conversion for pressure trends only; real relative altitude comes
    /// from the barometer and weather drift is not an altitude change.
    public static func standardAtmosphereAltitudeDifference(pressureHpa: Double,
                                                            referenceHpa: Double) -> Double? {
        guard pressureHpa.isFinite, referenceHpa.isFinite,
              pressureHpa > 0, referenceHpa > 0 else { return nil }
        return 44_330.77 * (1 - pow(pressureHpa / referenceHpa, 0.190_263))
    }

    /// Parabolic interpolation of a magnitude-spectrum peak for a fractional bin.
    /// Flat or edge spectra fall back to the integer bin.
    public static func interpolatedPeakBin(magnitudes: [Float], bin: Int) -> Double {
        guard bin > 0, bin < magnitudes.count - 1 else { return Double(bin) }
        let y1 = Double(magnitudes[bin - 1])
        let y2 = Double(magnitudes[bin])
        let y3 = Double(magnitudes[bin + 1])
        let denominator = y1 - 2 * y2 + y3
        guard denominator.isFinite, abs(denominator) > 1e-12 else { return Double(bin) }
        let delta = 0.5 * (y1 - y3) / denominator
        guard delta.isFinite else { return Double(bin) }
        return Double(bin) + min(max(delta, -0.5), 0.5)
    }
}

/// Fixed-frame forward FFT producing a relative amplitude spectrum. The analyzer
/// is cheap (one windowed complex transform per call) but NOT thread-safe: call it
/// from one serial queue at a time. Amplitudes are single-sided relative units
/// (interior bins scale 2/N after a normalized Hann window); they suit relative
/// spectra and tone detection, not absolute acoustical calibration.
public final class EnvironmentalSignalFFT: @unchecked Sendable {
    public let frameSize: Int
    /// Highest usable bin index (Nyquist); `magnitudes` covers 0...binCount.
    public let binCount: Int

    #if canImport(Accelerate)
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var scratch: [Float]
    private var real: [Float]
    private var imag: [Float]

    public init?(frameSize: Int) {
        guard (256...65_536).contains(frameSize), frameSize.nonzeroBitCount == 1 else { return nil }
        let length = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(length, FFTRadix(kFFTRadix2)) else { return nil }
        self.frameSize = frameSize
        self.binCount = frameSize / 2
        self.log2n = length
        self.setup = setup
        self.window = [Float](repeating: 0, count: frameSize)
        self.scratch = [Float](repeating: 0, count: frameSize)
        self.real = [Float](repeating: 0, count: frameSize)
        self.imag = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Relative amplitude magnitudes for bins 0...binCount. Short frames are
    /// zero-padded, long frames truncated, non-finite samples read as silence.
    public func magnitudes(for samples: [Float]) -> [Float] {
        let n = frameSize
        for index in 0..<n {
            let value = index < samples.count ? samples[index] : 0
            real[index] = value.isFinite ? value : 0
        }
        vDSP_vmul(real, 1, window, 1, &scratch, 1, vDSP_Length(n))
        swap(&real, &scratch)
        imag = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { realParts in
            imag.withUnsafeMutableBufferPointer { imaginaryParts in
                var split = DSPSplitComplex(realp: realParts.baseAddress!,
                                            imagp: imaginaryParts.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        var squared = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { realParts in
            imag.withUnsafeMutableBufferPointer { imaginaryParts in
                var split = DSPSplitComplex(realp: realParts.baseAddress!,
                                            imagp: imaginaryParts.baseAddress!)
                vDSP_zvmags(&split, 1, &squared, 1, vDSP_Length(n))
            }
        }
        let scale = 2 / Float(n)
        var result = [Float](repeating: 0, count: binCount + 1)
        for bin in 0...binCount { result[bin] = squared[bin].squareRoot() * scale }
        return result
    }
    #else
    public init?(frameSize: Int) {
        guard (256...65_536).contains(frameSize), frameSize.nonzeroBitCount == 1 else { return nil }
        self.frameSize = frameSize
        self.binCount = frameSize / 2
    }

    /// Platforms without Accelerate cannot transform; the spectrum stays silent.
    public func magnitudes(for samples: [Float]) -> [Float] {
        [Float](repeating: 0, count: binCount + 1)
    }
    #endif

    /// Dominant frequency in Hz from a `magnitudes` array via parabolic peak
    /// interpolation. Returns nil for silence, spectra whose peak stays below
    /// `minAmplitude` (no clear tone), or invalid input — never an invented 0 Hz.
    public func dominantFrequency(magnitudes: [Float], sampleRate: Double,
                                  minAmplitude: Float) -> Double? {
        guard magnitudes.count == binCount + 1, sampleRate.isFinite, sampleRate > 0,
              minAmplitude > 0 else { return nil }
        var peakBin = 0
        var peakValue: Float = 0
        for bin in 1..<(magnitudes.count - 1) where magnitudes[bin] > peakValue {
            peakValue = magnitudes[bin]
            peakBin = bin
        }
        guard peakValue >= minAmplitude else { return nil }
        let refined = EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: magnitudes, bin: peakBin)
        let hertz = refined * sampleRate / Double(frameSize)
        guard hertz.isFinite, hertz > 0 else { return nil }
        return hertz
    }

    /// One-shot analysis convenience: spectrum plus dominant frequency.
    public func analyze(samples: [Float], sampleRate: Double,
                        minAmplitude: Float) -> (magnitudes: [Float], dominantFrequency: Double?) {
        let spectrum = magnitudes(for: samples)
        return (spectrum, dominantFrequency(magnitudes: spectrum, sampleRate: sampleRate,
                                            minAmplitude: minAmplitude))
    }
}

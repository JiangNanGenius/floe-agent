import Foundation
import Testing
@testable import FloeToolboxUtilities

private let fftFrameSize = 4096

private func makeFFT() -> EnvironmentalSignalFFT {
    guard let fft = EnvironmentalSignalFFT(frameSize: fftFrameSize) else {
        Issue.record("FFT setup failed for \(fftFrameSize)")
        fatalError("unreachable")
    }
    return fft
}

/// Integer-bin sine so the expected FFT peak lands exactly on a bin.
private func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<count).map { index in
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        return Float(Double(amplitude) * sin(phase))
    }
}

@Test func fftRejectsInvalidFrameSizes() {
    #expect(EnvironmentalSignalFFT(frameSize: 100) == nil)
    #expect(EnvironmentalSignalFFT(frameSize: 1000) == nil)
    #expect(EnvironmentalSignalFFT(frameSize: 128) == nil)
    #expect(EnvironmentalSignalFFT(frameSize: 4096) != nil)
    #expect(EnvironmentalSignalFFT(frameSize: 256) != nil)
}

@Test func fftFindsExactBinSineAt48k() {
    // 48,000 / 4096 = 11.71875 Hz per bin; 256 bins = exactly 3000 Hz.
    let fft = makeFFT()
    let sampleRate = 48_000.0
    let spectrum = fft.magnitudes(for: sine(frequency: 3000, sampleRate: sampleRate, count: fftFrameSize))
    #expect(spectrum.count == fft.binCount + 1)
    let peakBin = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] })
    #expect(peakBin == 256)
    let dominant = fft.dominantFrequency(magnitudes: spectrum, sampleRate: sampleRate, minAmplitude: 1e-4)
    #expect(dominant != nil)
    #expect(abs(dominant! - 3000) < 0.5)
}

@Test func fftFindsOffBinSineAt44k1() {
    let fft = makeFFT()
    let sampleRate = 44_100.0
    // 1000 Hz is not an integer bin (10.766 Hz/bin); interpolation stays within a bin.
    let spectrum = fft.magnitudes(for: sine(frequency: 1000, sampleRate: sampleRate, count: fftFrameSize))
    let dominant = fft.dominantFrequency(magnitudes: spectrum, sampleRate: sampleRate, minAmplitude: 1e-4)
    #expect(dominant != nil)
    #expect(abs(dominant! - 1000) < sampleRate / Double(fftFrameSize))
    // A 440 Hz tone stays well separated from the 1000 Hz spectrum.
    let lowSpectrum = fft.magnitudes(for: sine(frequency: 440, sampleRate: sampleRate, count: fftFrameSize))
    let lowDominant = fft.dominantFrequency(magnitudes: lowSpectrum, sampleRate: sampleRate, minAmplitude: 1e-4)
    #expect(lowDominant != nil && abs(lowDominant! - 440) < sampleRate / Double(fftFrameSize))
}

@Test func fftSilenceHasNoDominantTone() {
    let fft = makeFFT()
    let silence = [Float](repeating: 0, count: fftFrameSize)
    let spectrum = fft.magnitudes(for: silence)
    #expect(spectrum.allSatisfy { $0 == 0 })
    #expect(fft.dominantFrequency(magnitudes: spectrum, sampleRate: 48_000, minAmplitude: 1e-4) == nil)
    #expect(fft.dominantFrequency(magnitudes: spectrum, sampleRate: 48_000, minAmplitude: 0) == nil)
}

@Test func fftSubThresholdSpectrumReportsNoTone() {
    let fft = makeFFT()
    // A whisper-quiet tone below the detection threshold must not invent a frequency.
    let quiet = sine(frequency: 1000, sampleRate: 48_000, count: fftFrameSize, amplitude: 1e-6)
    let spectrum = fft.magnitudes(for: quiet)
    #expect(fft.dominantFrequency(magnitudes: spectrum, sampleRate: 48_000, minAmplitude: 1e-4) == nil)
    // Invalid arguments never produce a frequency.
    #expect(fft.dominantFrequency(magnitudes: spectrum, sampleRate: 0, minAmplitude: 1e-4) == nil)
    #expect(fft.dominantFrequency(magnitudes: spectrum, sampleRate: .nan, minAmplitude: 1e-4) == nil)
    #expect(fft.dominantFrequency(magnitudes: [0, 1, 0], sampleRate: 48_000, minAmplitude: 1e-4) == nil)
}

@Test func fftZeroPadsShortFramesAndSanitizesBadSamples() {
    let fft = makeFFT()
    let full = fft.magnitudes(for: sine(frequency: 3000, sampleRate: 48_000, count: fftFrameSize))
    var short = sine(frequency: 3000, sampleRate: 48_000, count: fftFrameSize / 2)
    short.append(.nan)
    short.append(.infinity)
    let padded = fft.magnitudes(for: short)
    #expect(padded.count == full.count)
    // Zero-padding halves the tone energy but keeps the peak on the same bin.
    let peakBin = padded.indices.max(by: { padded[$0] < padded[$1] })
    #expect(peakBin == 256)
    #expect(padded[256] < full[256])
}

@Test func dbFSConversionIsFiniteAndBounded() {
    // A 0.5-amplitude sine has RMS 0.5/√2 ≈ 0.3536 → ≈ -9.03 dBFS.
    let expected = 20 * log10(0.5 / 2.0.squareRoot())
    #expect(abs(EnvironmentalSignalMath.dbFS(rms: 0.5 / 2.0.squareRoot()) - expected) < 1e-9)
    #expect(abs(EnvironmentalSignalMath.dbFS(rms: 1) - 0) < 1e-9)
    #expect(EnvironmentalSignalMath.dbFS(rms: 0) == EnvironmentalSignalMath.dbFloor)
    #expect(EnvironmentalSignalMath.dbFS(rms: -1) == EnvironmentalSignalMath.dbFloor)
    #expect(EnvironmentalSignalMath.dbFS(rms: .nan) == EnvironmentalSignalMath.dbFloor)
    #expect(EnvironmentalSignalMath.dbFS(rms: .infinity) == EnvironmentalSignalMath.dbFloor)
    #expect(EnvironmentalSignalMath.dbFloor == -160)
    // Digital full scale never reads above 0 dBFS, even for out-of-range input.
    #expect(EnvironmentalSignalMath.dbFS(rms: 4) == 0)
}

@Test func rmsAndPeakHandleSilenceClippingAndBadSamples() {
    #expect(EnvironmentalSignalMath.rms([]) == nil)
    #expect(EnvironmentalSignalMath.peak([]) == nil)
    #expect(EnvironmentalSignalMath.rms([0, 0, 0]) == 0)
    #expect(EnvironmentalSignalMath.peak([0, 0, 0]) == 0)
    // Clipped ±1 signal: RMS 1 → 0 dBFS, peak 1.
    let clipped: [Float] = (0..<1024).map { $0 % 2 == 0 ? 1 : -1 }
    let rms = EnvironmentalSignalMath.rms(clipped)
    #expect(rms != nil && abs(rms! - 1) < 1e-6)
    #expect(EnvironmentalSignalMath.dbFS(rms: rms!) == 0)
    #expect(EnvironmentalSignalMath.peak(clipped) == 1)
    // Non-finite samples count as silence rather than poisoning the result.
    #expect(EnvironmentalSignalMath.rms([.nan, .infinity, .nan]) == 0)
    #expect(EnvironmentalSignalMath.peak([.nan, -.infinity]) == 0)
    let mixed: [Float] = [0.5, .nan, 0.5, 0.5]
    let mixedRMS = EnvironmentalSignalMath.rms(mixed)
    #expect(mixedRMS != nil && abs(mixedRMS! - (0.75 / 4).squareRoot()) < 1e-6)
}

@Test func interpolatedPeakBinHandlesFlatAndEdgeSpectra() {
    let flat = [Float](repeating: 1, count: 32)
    #expect(EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: flat, bin: 5) == 5)
    #expect(EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: flat, bin: 0) == 0)
    #expect(EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: flat, bin: 31) == 31)
    // Symmetric peak centered on bin 10 interpolates to exactly 10.
    var symmetric = [Float](repeating: 0, count: 32)
    symmetric[9] = 0.5; symmetric[10] = 1; symmetric[11] = 0.5
    #expect(abs(EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: symmetric, bin: 10) - 10) < 1e-9)
    // Asymmetric peak shifts the interpolated bin toward the larger neighbor.
    var skewed = [Float](repeating: 0, count: 32)
    skewed[9] = 0.9; skewed[10] = 1; skewed[11] = 0.2
    let refined = EnvironmentalSignalMath.interpolatedPeakBin(magnitudes: skewed, bin: 10)
    #expect(refined > 9.5 && refined < 10)
}

@Test func pressureUnitConversionsRoundTrip() {
    #expect(EnvironmentalSignalMath.hectopascals(fromKilopascals: 101.325) == 1013.25)
    #expect(EnvironmentalSignalMath.kilopascals(fromHectopascals: 1013.25) == 101.325)
    #expect(EnvironmentalSignalMath.hectopascals(fromKilopascals: .nan) == nil)
    #expect(EnvironmentalSignalMath.kilopascals(fromHectopascals: .infinity) == nil)
    let roundTrip = EnvironmentalSignalMath.kilopascals(fromHectopascals:
        EnvironmentalSignalMath.hectopascals(fromKilopascals: 98.7)!)
    #expect(roundTrip != nil && abs(roundTrip! - 98.7) < 1e-9)
}

@Test func relativeAltitudeSubtractsTheZeroBaseline() {
    #expect(EnvironmentalSignalMath.relativeAltitude(current: 12.5, baseline: 10) == 2.5)
    #expect(EnvironmentalSignalMath.relativeAltitude(current: 8, baseline: 10) == -2)
    #expect(EnvironmentalSignalMath.relativeAltitude(current: .nan, baseline: 10) == nil)
    #expect(EnvironmentalSignalMath.relativeAltitude(current: 10, baseline: .infinity) == nil)
}

@Test func standardAtmosphereMatchesKnownPressureAltitudes() {
    // Sea-level pressure reads zero difference against itself.
    let sea = EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(pressureHpa: 1013.25, referenceHpa: 1013.25)
    #expect(sea != nil && abs(sea!) < 1e-6)
    // ISA table: 500 hPa ≈ 5574 m above the 1013.25 hPa reference.
    let high = EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(pressureHpa: 500, referenceHpa: 1013.25)
    #expect(high != nil && abs(high! - 5574) < 5)
    // Higher pressure than the reference reads a negative difference.
    let below = EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(pressureHpa: 1040, referenceHpa: 1013.25)
    #expect(below != nil && below! < 0)
    #expect(EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(pressureHpa: 0, referenceHpa: 1013.25) == nil)
    #expect(EnvironmentalSignalMath.standardAtmosphereAltitudeDifference(pressureHpa: 900, referenceHpa: -1) == nil)
}

@Test func signalSampleBufferDropsOldestAndResets() {
    var buffer = SignalSampleBuffer<Int>(capacity: 3)
    for value in 1...5 { buffer.append(value) }
    #expect(buffer.count == 3)
    #expect(buffer.values == [3, 4, 5])
    #expect(buffer.droppedCount == 2)
    buffer.reset()
    #expect(buffer.isEmpty && buffer.droppedCount == 0)
    var single = SignalSampleBuffer<String>(capacity: 1)
    single.append("a"); single.append("b")
    #expect(single.values == ["b"] && single.droppedCount == 1)
}

@Test func fftAnalyzeMatchesSeparateCalls() {
    let fft = makeFFT()
    let samples = sine(frequency: 3000, sampleRate: 48_000, count: fftFrameSize)
    let combined = fft.analyze(samples: samples, sampleRate: 48_000, minAmplitude: 1e-4)
    let separate = fft.magnitudes(for: samples)
    #expect(combined.magnitudes == separate)
    #expect(combined.dominantFrequency != nil && abs(combined.dominantFrequency! - 3000) < 0.5)
}

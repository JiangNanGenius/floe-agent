import Foundation
import FloeToolboxUtilities

/// One retained analysis reading in digital full-scale units (dBFS). These are
/// relative digital levels, never calibrated sound-pressure levels.
public struct MacSoundSample: Sendable, Equatable {
    /// Seconds since measurement start; preserved across pause/resume.
    public let timestamp: TimeInterval
    public let levelDBFS: Double
    public let peakDBFS: Double
    public let dominantFrequency: Double?

    public init(timestamp: TimeInterval, levelDBFS: Double, peakDBFS: Double, dominantFrequency: Double?) {
        self.timestamp = timestamp
        self.levelDBFS = levelDBFS
        self.peakDBFS = peakDBFS
        self.dominantFrequency = dominantFrequency
    }
}

/// Display-ready spectrum. `bands` are 0...1 heights aligned with
/// `bandFrequencies` in Hz. Mirrors the iOS `ToolboxSoundSpectrum` shape, which
/// lives in the iOS-only workbench target and therefore is not linked here.
public struct MacSoundSpectrum: Sendable, Equatable {
    public let bands: [Float]
    public let bandFrequencies: [Double]

    public init(bands: [Float], bandFrequencies: [Double]) {
        self.bands = bands
        self.bandFrequencies = bandFrequencies
    }

    public static let empty = MacSoundSpectrum(bands: [], bandFrequencies: [])
}

/// Per-frame output of `MacSoundAnalyzer`.
public struct MacSoundReading: Sendable, Equatable {
    public let levelDBFS: Double
    public let peakDBFS: Double
    public let dominantFrequency: Double?
    public let spectrum: MacSoundSpectrum
    public let appendToHistory: Bool

    public init(levelDBFS: Double, peakDBFS: Double, dominantFrequency: Double?,
                spectrum: MacSoundSpectrum, appendToHistory: Bool) {
        self.levelDBFS = levelDBFS
        self.peakDBFS = peakDBFS
        self.dominantFrequency = dominantFrequency
        self.spectrum = spectrum
        self.appendToHistory = appendToHistory
    }
}

/// Pure analysis for the Mac microphone analyzer. It reuses the shared
/// `EnvironmentalSignalFFT` / `EnvironmentalSignalMath` (already covered by the
/// shared FloeToolbox tests) and mirrors the iOS `SoundAnalysisCore` smoothing,
/// band plan and history cadence so both platforms read identically.
///
/// Not thread-safe: call from one serial queue (the system adapter owns that
/// queue, exactly like the iOS service).
public final class MacSoundAnalyzer: @unchecked Sendable {
    public static let defaultFrameSize = 4_096
    public static let defaultHistoryEveryFrames = 5
    /// Tones quieter than this relative amplitude report no dominant frequency
    /// instead of inventing one from the noise floor.
    public static let minimumDetectableAmplitude: Float = 1e-4

    public let sampleRate: Double
    public let frameSize: Int
    public let bandCount: Int
    private let historyEveryFrames: Int
    private let fft: EnvironmentalSignalFFT?
    private let bandPlan: [(lowBin: Int, highBin: Int, centerHz: Double)]
    private var smoothedDB = EnvironmentalSignalMath.dbFloor
    private var frameCounter = 0

    /// `frameSize` must be a power of two in 256...65536; nil otherwise.
    public init?(
        sampleRate: Double,
        frameSize: Int = MacSoundAnalyzer.defaultFrameSize,
        historyEveryFrames: Int = MacSoundAnalyzer.defaultHistoryEveryFrames
    ) {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 768_000,
              (256...65_536).contains(frameSize), frameSize.nonzeroBitCount == 1,
              historyEveryFrames >= 1 else { return nil }
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.historyEveryFrames = historyEveryFrames
        let fft = EnvironmentalSignalFFT(frameSize: frameSize)
        self.fft = fft
        let binCount = (fft?.binCount ?? frameSize / 2) + 1
        let plan = Self.makeBandPlan(binCount: binCount, sampleRate: sampleRate, frameSize: frameSize)
        self.bandPlan = plan
        self.bandCount = plan.count
    }

    /// 40 log-spaced bands from 20 Hz to min(nyquist × 0.95, 16 kHz).
    private static func makeBandPlan(
        binCount: Int,
        sampleRate: Double,
        frameSize: Int
    ) -> [(lowBin: Int, highBin: Int, centerHz: Double)] {
        let nyquist = sampleRate / 2
        let topHz = min(nyquist * 0.95, 16_000)
        guard topHz > 20 else { return [] }
        let bandCount = 40
        let ratio = pow(topHz / 20, 1 / Double(bandCount))
        var plan: [(lowBin: Int, highBin: Int, centerHz: Double)] = []
        var lowHz = 20.0
        for _ in 0..<bandCount {
            let highHz = min(lowHz * ratio, topHz)
            let lowBin = max(1, Int((lowHz * Double(frameSize) / sampleRate).rounded(.down)))
            let highBin = min(binCount - 2, max(lowBin, Int((highHz * Double(frameSize) / sampleRate).rounded(.up))))
            plan.append((lowBin, highBin, (lowHz * highHz).squareRoot()))
            lowHz = highHz
            if highHz >= topHz { break }
        }
        return plan
    }

    /// Consumes one mono frame. Returns nil only for an empty frame.
    public func process(_ samples: [Float]) -> MacSoundReading? {
        guard let rms = EnvironmentalSignalMath.rms(samples) else { return nil }
        frameCounter += 1
        let instantaneous = EnvironmentalSignalMath.dbFS(rms: rms)
        // Fast attack, slow release: steady reading without hiding peaks.
        smoothedDB = instantaneous > smoothedDB
            ? instantaneous
            : smoothedDB + (instantaneous - smoothedDB) * 0.25
        let peak = EnvironmentalSignalMath.peak(samples) ?? 0
        let peakDBFS = EnvironmentalSignalMath.dbFS(rms: Double(peak))

        var dominant: Double?
        var spectrum = MacSoundSpectrum.empty
        if let fft {
            let (magnitudes, frequency) = fft.analyze(
                samples: samples,
                sampleRate: sampleRate,
                minAmplitude: Self.minimumDetectableAmplitude
            )
            dominant = frequency
            var bands = [Float]()
            var centers = [Double]()
            bands.reserveCapacity(bandPlan.count)
            centers.reserveCapacity(bandPlan.count)
            for band in bandPlan {
                var magnitude: Float = 0
                for bin in band.lowBin...band.highBin where magnitudes[bin] > magnitude {
                    magnitude = magnitudes[bin]
                }
                bands.append(Self.displayUnit(magnitude: magnitude))
                centers.append(band.centerHz)
            }
            spectrum = MacSoundSpectrum(bands: bands, bandFrequencies: centers)
        }

        return MacSoundReading(
            levelDBFS: smoothedDB,
            peakDBFS: peakDBFS,
            dominantFrequency: dominant,
            spectrum: spectrum,
            appendToHistory: frameCounter % historyEveryFrames == 0
        )
    }

    /// Clears smoothing/cadence state; the next frame starts a new measurement.
    public func reset() {
        smoothedDB = EnvironmentalSignalMath.dbFloor
        frameCounter = 0
    }

    /// dB-mapped display height: -100 dB → 0, 0 dB → 1.
    private static func displayUnit(magnitude: Float) -> Float {
        guard magnitude > 0 else { return 0 }
        let db = 20 * log10(Double(magnitude))
        return Float(min(max((db + 100) / 100, 0), 1))
    }
}

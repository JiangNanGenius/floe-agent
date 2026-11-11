import Foundation
import FloeToolboxUtilities
#if os(iOS)
import CoreMotion
#endif

public enum ToolboxPressurePhase: String, Sendable, Equatable {
    case idle, starting, running, stopping
}

/// CoreMotion barometer authorization mirrored without exposing CoreMotion types
/// to the cross-platform surface. Starting updates while `.notDetermined` is what
/// presents the system permission prompt.
public enum ToolboxPressureAuthorization: String, Sendable, Equatable {
    case notDetermined, restricted, denied, authorized
    public var isAuthorized: Bool { self == .authorized }
}

/// One barometer frame converted into plain, Sendable values.
public struct ToolboxPressureSample: Sendable, Equatable {
    /// CoreMotion sensor timestamp (seconds since boot).
    public let timestamp: TimeInterval
    /// Wall-clock receipt time.
    public let receivedAt: Date
    /// Barometric pressure in hectopascals (hPa).
    public let pressureHpa: Double
    /// Pressure-derived altitude in meters relative to the current update stream.
    public let relativeAltitude: Double
    public init(timestamp: TimeInterval, receivedAt: Date, pressureHpa: Double, relativeAltitude: Double) {
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.pressureHpa = pressureHpa
        self.relativeAltitude = relativeAltitude
    }
}

/// A bounded, exportable trend point. Altitude is relative to the zero baseline.
public struct ToolboxPressurePlotPoint: Sendable, Equatable {
    /// Seconds since the first retained measurement, including pauses.
    public let timestamp: TimeInterval
    public let pressureHpa: Double
    /// Altitude in meters relative to the zero baseline (stream start when unset).
    public let altitude: Double
    public init(timestamp: TimeInterval, pressureHpa: Double, altitude: Double) {
        self.timestamp = timestamp
        self.pressureHpa = pressureHpa
        self.altitude = altitude
    }
}

#if os(iOS)

/// Barometric altimeter owner backed by its own `CMAltimeter` — separate from the
/// shared CoreMotion owner used by the motion instruments. Readings are pressure
/// in hPa and pressure-derived *relative* altitude in meters; no absolute
/// altitude, GPS floor, or weather compensation is invented. Pausing keeps the
/// zero baseline, extrema and bounded history; stopping on exit releases the
/// sensor. Every handler delivery is fenced by a generation counter.
@MainActor @Observable public final class ToolboxPressureService {
    public static let shared = ToolboxPressureService()

    public private(set) var phase: ToolboxPressurePhase = .idle
    public private(set) var authorization: ToolboxPressureAuthorization
    public private(set) var latest: ToolboxPressureSample?
    /// Last sensor delivery error; cleared on the next successful start.
    public private(set) var streamError: String?

    /// Raw relative-altitude baseline subtracted from readings; set on the first
    /// sample of every stream. `setZeroReference` re-points it at the current
    /// reading, `clearZeroReference` restores the stream-start reference.
    public private(set) var zeroBaseline: Double?
    public private(set) var isZeroed: Bool = false

    /// Session extrema over displayed altitude and pressure; cleared by `resetHistory()`.
    public private(set) var minimumAltitude: Double?
    public private(set) var maximumAltitude: Double?
    public private(set) var minimumPressureHpa: Double?
    public private(set) var maximumPressureHpa: Double?

    /// ~20 minutes at the ~1 Hz delivery rate; oldest samples drop off.
    public let historyCapacity = 1200
    public private(set) var history = SignalSampleBuffer<ToolboxPressurePlotPoint>(capacity: 1200)

    private let altimeter = CMAltimeter()
    private let deliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var generation = 0
    /// Sensor timestamp of the first sample of the current stream.
    private var streamStartTimestamp: TimeInterval?
    /// Unlike the per-stream altitude baseline, the history clock survives
    /// pause/resume so retained samples keep increasing timestamps.
    private var measurementStartTimestamp: TimeInterval?
    /// Raw relative altitude of the first sample of the current stream.
    private var streamInitialAltitude: Double?
    /// Displayed altitude of the last accepted sample; keeps readings continuous
    /// across a pause/resume rebase (a new stream restarts raw altitude near zero).
    private var lastDisplayedAltitude: Double?
    /// Set while starting a stream that must rebase against the pre-pause reading.
    private var resumeContinuity = false

    public init() {
        authorization = Self.currentAuthorization()
    }

    public var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    public func refreshAuthorization() {
        authorization = Self.currentAuthorization()
    }

    /// Starts sampling. No-op when the barometer is unavailable or access is
    /// denied; the first start while `.notDetermined` presents the system prompt.
    public func start() {
        guard isAvailable else { return }
        refreshAuthorization()
        guard authorization != .denied, authorization != .restricted else { return }
        guard phase != .running, phase != .starting else { return }
        generation += 1
        let streamGeneration = generation
        if lastDisplayedAltitude != nil { resumeContinuity = true }
        phase = .starting
        streamError = nil
        altimeter.startRelativeAltitudeUpdates(to: deliveryQueue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == streamGeneration else { return }
                    self.streamError = error.localizedDescription
                    self.stopStream()
                }
                return
            }
            guard let data, let sample = Self.makeSample(from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == streamGeneration, self.phase != .idle else { return }
                self.accept(sample)
            }
        }
        phase = .running
    }

    /// Pauses sampling, keeping history, extrema and the zero baseline.
    public func pause() {
        generation += 1
        stopStream()
    }

    /// Clears retained history and extrema; sampling continues unaffected.
    public func resetHistory() {
        history.reset()
        measurementStartTimestamp = nil
        minimumAltitude = nil
        maximumAltitude = nil
        minimumPressureHpa = nil
        maximumPressureHpa = nil
    }

    /// Re-points the zero baseline at the current reading, so displayed altitude
    /// reads 0 m from here. Honest relative reference only — never an absolute floor.
    /// Retained history and extrema shift by the same delta so reference frames
    /// never mix.
    public func setZeroReference() {
        guard let raw = latest?.relativeAltitude else { return }
        applyZeroBaseline(raw, zeroed: true)
    }

    /// Restores the stream-start reference (displayed altitude relative to when
    /// the current stream began measuring).
    public func clearZeroReference() {
        guard let initial = streamInitialAltitude else { return }
        applyZeroBaseline(initial, zeroed: false)
    }

    /// Displayed altitude of the latest sample: raw reading minus the baseline.
    public var displayedAltitude: Double? {
        guard let sample = latest else { return nil }
        return EnvironmentalSignalMath.relativeAltitude(current: sample.relativeAltitude,
                                                        baseline: zeroBaseline ?? 0)
    }

    /// Actual retained samples as CSV. Timestamps are seconds since stream start.
    public func makeCSV() -> String {
        var lines = ["time_s,pressure_hpa,pressure_kpa,altitude_m,zeroed"]
        let zeroed = isZeroed ? "1" : "0"
        for point in history.values {
            let kilopascals = EnvironmentalSignalMath.kilopascals(fromHectopascals: point.pressureHpa) ?? 0
            lines.append(String(format: "%.3f,%.4f,%.5f,%.3f,%@",
                                point.timestamp, point.pressureHpa, kilopascals, point.altitude, zeroed))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func currentAuthorization() -> ToolboxPressureAuthorization {
        switch CMAltimeter.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func stopStream() {
        phase = .stopping
        altimeter.stopRelativeAltitudeUpdates()
        streamStartTimestamp = nil
        streamInitialAltitude = nil
        phase = .idle
    }

    func accept(_ sample: ToolboxPressureSample) {
        if measurementStartTimestamp == nil { measurementStartTimestamp = sample.timestamp }
        if streamStartTimestamp == nil {
            streamStartTimestamp = sample.timestamp
            streamInitialAltitude = sample.relativeAltitude
            if resumeContinuity, let last = lastDisplayedAltitude {
                zeroBaseline = sample.relativeAltitude - last
            } else {
                zeroBaseline = sample.relativeAltitude
            }
            resumeContinuity = false
        }
        latest = sample
        guard let displayed = EnvironmentalSignalMath.relativeAltitude(
            current: sample.relativeAltitude, baseline: zeroBaseline ?? sample.relativeAltitude) else { return }
        lastDisplayedAltitude = displayed
        minimumAltitude = min(minimumAltitude ?? displayed, displayed)
        maximumAltitude = max(maximumAltitude ?? displayed, displayed)
        minimumPressureHpa = min(minimumPressureHpa ?? sample.pressureHpa, sample.pressureHpa)
        maximumPressureHpa = max(maximumPressureHpa ?? sample.pressureHpa, sample.pressureHpa)
        history.append(ToolboxPressurePlotPoint(
            timestamp: sample.timestamp - (measurementStartTimestamp ?? sample.timestamp),
            pressureHpa: sample.pressureHpa,
            altitude: displayed))
        if phase == .starting { phase = .running }
    }

    /// Moves the baseline and shifts every retained displayed-altitude value by the
    /// same delta, so history, extrema and future samples share one reference frame.
    private func applyZeroBaseline(_ baseline: Double, zeroed: Bool) {
        guard let sample = latest else { return }
        let before = EnvironmentalSignalMath.relativeAltitude(
            current: sample.relativeAltitude, baseline: zeroBaseline ?? sample.relativeAltitude)
        zeroBaseline = baseline
        isZeroed = zeroed
        guard let before,
              let after = EnvironmentalSignalMath.relativeAltitude(
                current: sample.relativeAltitude, baseline: baseline),
              after != before else { return }
        let delta = after - before
        lastDisplayedAltitude = after
        if let minimumAltitude { self.minimumAltitude = minimumAltitude + delta }
        if let maximumAltitude { self.maximumAltitude = maximumAltitude + delta }
        var rebased = SignalSampleBuffer<ToolboxPressurePlotPoint>(capacity: history.capacity)
        for point in history.values {
            rebased.append(ToolboxPressurePlotPoint(timestamp: point.timestamp,
                                                    pressureHpa: point.pressureHpa,
                                                    altitude: point.altitude + delta))
        }
        history = rebased
    }

    nonisolated private static func makeSample(from data: CMAltitudeData) -> ToolboxPressureSample? {
        let pressureKpa = data.pressure.doubleValue
        let altitude = data.relativeAltitude.doubleValue
        guard pressureKpa.isFinite, altitude.isFinite,
              let pressureHpa = EnvironmentalSignalMath.hectopascals(fromKilopascals: pressureKpa) else {
            return nil
        }
        return ToolboxPressureSample(timestamp: data.timestamp, receivedAt: Date(),
                                     pressureHpa: pressureHpa, relativeAltitude: altitude)
    }
}

#else

/// macOS has no CMAltimeter; the same public surface reports honest unavailability.
@MainActor public final class ToolboxPressureService {
    public static let shared = ToolboxPressureService()

    public private(set) var phase: ToolboxPressurePhase = .idle
    public private(set) var authorization: ToolboxPressureAuthorization = .restricted
    public private(set) var latest: ToolboxPressureSample?
    public private(set) var streamError: String?
    public private(set) var zeroBaseline: Double?
    public private(set) var isZeroed = false
    public private(set) var minimumAltitude: Double?
    public private(set) var maximumAltitude: Double?
    public private(set) var minimumPressureHpa: Double?
    public private(set) var maximumPressureHpa: Double?
    public let historyCapacity = 1200
    public private(set) var history = SignalSampleBuffer<ToolboxPressurePlotPoint>(capacity: 1200)

    public init() {}
    public var isAvailable: Bool { false }
    public var displayedAltitude: Double? { nil }
    public func refreshAuthorization() {}
    public func start() {}
    public func pause() {}
    public func resetHistory() {}
    public func setZeroReference() {}
    public func clearZeroReference() {}
    public func makeCSV() -> String { "time_s,pressure_hpa,pressure_kpa,altitude_m,zeroed\n" }
}

#endif

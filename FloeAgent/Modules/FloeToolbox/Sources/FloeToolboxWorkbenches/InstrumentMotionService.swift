import Foundation
import Observation
import FloeToolboxUtilities
#if os(iOS)
import CoreMotion
import UIKit
#endif

public enum InstrumentStreamKind: String, Sendable, Hashable, CaseIterable {
    case level, motion, compass
}

public enum InstrumentStreamPhase: Sendable, Equatable {
    case idle, starting, running, stopping
}

/// Opaque sampling token. Releasing a stale lease never disturbs a newer stream.
public struct InstrumentMotionLease: Sendable, Hashable {
    public let identifier: UUID
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
}

public enum InstrumentMagneticAccuracy: String, Sendable, Equatable {
    case uncalibrated, low, medium, high
}

/// One CoreMotion device-motion frame converted into plain, Sendable values.
public struct InstrumentMotionSample: Sendable, Equatable {
    /// CoreMotion device timestamp (seconds since boot).
    public let timestamp: TimeInterval
    /// Wall-clock receipt time.
    public let receivedAt: Date
    public let attitude: InstrumentQuaternion
    /// World-up in device coordinates, derived from the fused attitude.
    public let up: InstrumentVec3
    public let gravity: InstrumentVec3
    public let userAcceleration: InstrumentVec3
    /// Rotation rate in radians per second, device coordinates.
    public let rotationRate: InstrumentVec3
    /// Magnetic heading in [0, 360) degrees; nil while invalid or on non-compass streams.
    public let heading: Double?
    /// Calibrated magnetic field in microtesla; nil when no magnetometer sample exists.
    public let magneticField: InstrumentVec3?
    public let magneticAccuracy: InstrumentMagneticAccuracy?
    public init(timestamp: TimeInterval, receivedAt: Date, attitude: InstrumentQuaternion,
                up: InstrumentVec3, gravity: InstrumentVec3, userAcceleration: InstrumentVec3,
                rotationRate: InstrumentVec3, heading: Double? = nil,
                magneticField: InstrumentVec3? = nil, magneticAccuracy: InstrumentMagneticAccuracy? = nil) {
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.attitude = attitude
        self.up = up
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.heading = heading
        self.magneticField = magneticField
        self.magneticAccuracy = magneticAccuracy
    }
}

/// A bounded, exportable motion plot point.
public struct InstrumentMotionPlotPoint: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let acceleration: InstrumentVec3
    public let rotation: InstrumentVec3
    public let pitch: Double
    public let roll: Double
    public let yaw: Double
    public init(timestamp: TimeInterval, acceleration: InstrumentVec3, rotation: InstrumentVec3,
                pitch: Double, roll: Double, yaw: Double) {
        self.timestamp = timestamp
        self.acceleration = acceleration
        self.rotation = rotation
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
    }
}

/// Readings belong to one workbench, including while its sampling lease is paused
/// or superseded. The shared hardware owner never writes another session's state.
@MainActor @Observable public final class InstrumentMotionSession {
    public private(set) var latest: InstrumentMotionSample?
    public private(set) var streamError: String?
    public private(set) var levelReference: InstrumentQuaternion?
    public private(set) var motionHistory = InstrumentSampleBuffer<InstrumentMotionPlotPoint>(capacity: 480)

    private var samplingLease: InstrumentMotionLease?
    private var historyStartTimestamp: TimeInterval?

    public init() {}

    func beginSampling(for lease: InstrumentMotionLease) {
        samplingLease = lease
        streamError = nil
    }

    func endSampling(for lease: InstrumentMotionLease) {
        guard samplingLease == lease else { return }
        samplingLease = nil
    }

    func fail(_ message: String, for lease: InstrumentMotionLease) {
        guard samplingLease == lease else { return }
        streamError = message
    }

    func record(_ sample: InstrumentMotionSample, kind: InstrumentStreamKind, for lease: InstrumentMotionLease) {
        guard samplingLease == lease, sample.timestamp.isFinite,
              latest.map({ sample.timestamp > $0.timestamp }) ?? true else { return }
        latest = sample
        guard kind == .motion, let euler = InstrumentMath.eulerDegrees(attitude: sample.attitude) else { return }
        if historyStartTimestamp == nil { historyStartTimestamp = sample.timestamp }
        motionHistory.append(InstrumentMotionPlotPoint(
            timestamp: sample.timestamp - (historyStartTimestamp ?? sample.timestamp),
            acceleration: sample.userAcceleration, rotation: sample.rotationRate,
            pitch: euler.pitch, roll: euler.roll, yaw: euler.yaw))
    }

    /// Keep one time origin across pauses. Reset explicitly makes the next frame 0 s.
    public func resetHistory() {
        motionHistory.reset()
        historyStartTimestamp = nil
    }

    public func setLevelReference(_ quaternion: InstrumentQuaternion) {
        levelReference = quaternion
    }

    public func clearLevelReference() {
        levelReference = nil
    }

    public func levelUpVector(for sample: InstrumentMotionSample) -> InstrumentVec3 {
        if let reference = levelReference,
           let relative = InstrumentMath.relativeUp(current: sample.attitude, reference: reference) {
            return relative
        }
        return sample.up
    }
}

#if os(iOS)

/// App-wide CoreMotion owner. Views hold short-lived leases; only the newest lease
/// drives sampling, and every handler delivery is fenced by a generation counter.
/// Taking over from another instrument is never silent: the superseded lease simply
/// stops being active, and observing views see that through the published state.
@MainActor @Observable public final class InstrumentMotionService {
    public static let shared = InstrumentMotionService()

    public private(set) var phase: InstrumentStreamPhase = .idle
    public private(set) var activeKind: InstrumentStreamKind?
    public private(set) var activeLease: InstrumentMotionLease?

    private var activeSession: InstrumentMotionSession?
    private let manager = CMMotionManager()
    private let deliveryQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var generation = 0

    public init() {}

    public func isAvailable(_ kind: InstrumentStreamKind) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        switch kind {
        case .level, .motion:
            return true
        case .compass:
            guard manager.isMagnetometerAvailable else { return false }
            let frames = CMMotionManager.availableAttitudeReferenceFrames()
            return frames.contains(.xMagneticNorthZVertical)
        }
    }

    /// Starts sampling for the lease kind, replacing any other active stream.
    /// The replaced lease stops being active immediately, which observing views
    /// surface as their paused state. Returns nil when the kind is unsupported.
    @discardableResult
    public func acquire(_ kind: InstrumentStreamKind, session: InstrumentMotionSession) -> InstrumentMotionLease? {
        guard isAvailable(kind) else { return nil }
        generation += 1
        stopStream()
        if let activeLease { activeSession?.endSampling(for: activeLease) }
        let lease = InstrumentMotionLease()
        activeLease = lease
        activeKind = kind
        activeSession = session
        session.beginSampling(for: lease)
        phase = .starting
        startStream(kind, generation: generation)
        phase = .running
        return lease
    }

    /// True only while this lease currently owns the stream.
    public func isActive(_ lease: InstrumentMotionLease) -> Bool {
        activeLease == lease
    }

    /// Stops sampling, but only if this lease still owns the stream.
    public func release(_ lease: InstrumentMotionLease) {
        guard activeLease == lease else { return }
        generation += 1
        stopStream()
        activeSession?.endSampling(for: lease)
        activeSession = nil
        activeLease = nil
        activeKind = nil
        phase = .idle
    }

    public func stopAll() {
        generation += 1
        stopStream()
        if let activeLease { activeSession?.endSampling(for: activeLease) }
        activeSession = nil
        activeLease = nil
        activeKind = nil
        phase = .idle
    }

    private func stopStream() {
        phase = .stopping
        manager.stopDeviceMotionUpdates()
    }

    private func startStream(_ kind: InstrumentStreamKind, generation streamGeneration: Int) {
        manager.deviceMotionUpdateInterval = kind == .compass ? 1.0 / 30.0 : 1.0 / 60.0
        let frame: CMAttitudeReferenceFrame = kind == .compass
            ? .xMagneticNorthZVertical
            : .xArbitraryZVertical
        manager.showsDeviceMovementDisplay = kind == .compass
        manager.startDeviceMotionUpdates(using: frame, to: deliveryQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == streamGeneration,
                          let lease = self.activeLease else { return }
                    self.activeSession?.fail(error.localizedDescription, for: lease)
                    self.stopAll()
                }
                return
            }
            guard let motion, let sample = Self.makeSample(from: motion, kind: kind) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == streamGeneration, self.phase == .running,
                      let lease = self.activeLease else { return }
                self.activeSession?.record(sample, kind: kind, for: lease)
            }
        }
    }

    nonisolated private static func makeSample(from motion: CMDeviceMotion, kind: InstrumentStreamKind) -> InstrumentMotionSample? {
        let quaternion = motion.attitude.quaternion
        let attitude = InstrumentQuaternion(quaternion.x, quaternion.y, quaternion.z, quaternion.w)
        guard let up = InstrumentMath.upVector(attitude: attitude) else { return nil }
        // CoreMotion reports gravity and user acceleration in g; convert once to m/s².
        let scale = InstrumentMath.standardGravityMps2
        let gravity = InstrumentVec3(motion.gravity.x * scale, motion.gravity.y * scale, motion.gravity.z * scale)
        let userAcceleration = InstrumentVec3(motion.userAcceleration.x * scale,
                                              motion.userAcceleration.y * scale,
                                              motion.userAcceleration.z * scale)
        let rotationRate = InstrumentVec3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
        guard gravity.isFinite, userAcceleration.isFinite, rotationRate.isFinite else {
            return nil
        }
        var heading: Double? = nil
        var magneticField: InstrumentVec3? = nil
        var magneticAccuracy: InstrumentMagneticAccuracy? = nil
        if kind == .compass {
            let value = motion.heading
            if value.isFinite, value >= 0 {
                heading = InstrumentMath.normalizedDegrees(value)
            } else {
                heading = InstrumentMath.headingDegrees(attitude: attitude)
            }
            let field = motion.magneticField
            let vector = InstrumentVec3(field.field.x, field.field.y, field.field.z)
            if vector.isFinite {
                magneticField = vector
                switch field.accuracy {
                case .uncalibrated: magneticAccuracy = .uncalibrated
                case .low: magneticAccuracy = .low
                case .medium: magneticAccuracy = .medium
                case .high: magneticAccuracy = .high
                @unknown default: magneticAccuracy = .uncalibrated
                }
            }
        }
        return InstrumentMotionSample(timestamp: motion.timestamp, receivedAt: Date(), attitude: attitude,
                                      up: up, gravity: gravity, userAcceleration: userAcceleration,
                                      rotationRate: rotationRate, heading: heading,
                                      magneticField: magneticField, magneticAccuracy: magneticAccuracy)
    }
}

@MainActor
extension InstrumentMotionService {
    /// Maps a device-frame up vector into the current interface orientation.
    /// +x drifts toward the raised right edge of the screen, +y toward the raised top.
    public static func screenBubble(up: InstrumentVec3, orientation: UIInterfaceOrientation) -> (x: Double, y: Double) {
        let point = InstrumentMath.bubblePosition(up: up) ?? (x: 0, y: 0)
        switch orientation {
        case .portraitUpsideDown: return (-point.x, -point.y)
        case .landscapeLeft: return (-point.y, point.x)
        case .landscapeRight: return (point.y, -point.x)
        default: return (point.x, point.y)
        }
    }

    public static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.effectiveGeometry.interfaceOrientation }
            .first ?? .unknown
    }
}

#else

/// macOS has no CoreMotion; the same public surface reports honest unavailability.
@MainActor public final class InstrumentMotionService {
    public static let shared = InstrumentMotionService()

    public private(set) var phase: InstrumentStreamPhase = .idle
    public private(set) var activeKind: InstrumentStreamKind?
    public private(set) var activeLease: InstrumentMotionLease?

    public init() {}

    public func isAvailable(_ kind: InstrumentStreamKind) -> Bool { false }
    @discardableResult public func acquire(_ kind: InstrumentStreamKind, session: InstrumentMotionSession) -> InstrumentMotionLease? { nil }
    public func isActive(_ lease: InstrumentMotionLease) -> Bool { false }
    public func release(_ lease: InstrumentMotionLease) {}
    public func stopAll() {}
}

#endif

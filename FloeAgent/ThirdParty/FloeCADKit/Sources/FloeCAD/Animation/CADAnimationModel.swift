//
//  CADAnimationModel.swift
//  FloeCADKit
//
//  Persisted, renderer-neutral keyframe animation for a native FloeCAD
//  document. Clips animate the presentation camera and assembly instance
//  translation/rotation only; they never store geometry, never replace the
//  assembly baseline. Ordinary authored tracks are not a simulation; an
//  explicit physics-backed clip references one validated scene-settings cache.
//
//  Units and axes
//  --------------
//  - Instance translation is millimetres in the model's right-handed +Y-up
//    frame, matching `CADAssembly.CADTransform`.
//  - Camera values are presentation metres (the same space as
//    `CADPresentationCamera`), so the live Present can consume them directly.
//  - Quaternions are stored as (x, y, z, w) and normalized on use.
//
//  This file is deliberately Foundation/simd only: the interpolation and
//  preset math can be exercised without RealityKit, and the presentation
//  adapters live beside the RealityKit surface.
//

import Foundation
import simd

// MARK: - Document

/// The optional `animationData` payload of a FloeCAD package. Absent on every
/// document that never animated; additive, so old documents open unchanged.
public nonisolated struct CADAnimationDocument: Codable, Sendable, Equatable {
    /// Schema 2 adds the authored timing curve. Documents that never stored a
    /// curve keep schema 1, so an ordinary legacy/default clip stays writable
    /// by the released schema-1 reader. Once a real curve (or a higher
    /// schema) is stored, the header never drops back to 1 just because the
    /// curve was later removed.
    public static let legacySchemaVersion = 1
    public static let timingCurveSchemaVersion = 2
    public static let physicsSchemaVersion = 3
    public static let rigSchemaVersion = 4
    public static let currentSchemaVersion = rigSchemaVersion
    public static let defaultDurationSeconds: Double = 5
    public static let minimumDurationSeconds: Double = 0.1
    public static let maximumDurationSeconds: Double = 600
    public static let maximumClips = 16
    public static let maximumTracksPerClip = 128
    public static let maximumKeyframesPerTrack = 512
    public static let maximumEncodedBytes = 2 * 1024 * 1024
    public static let maximumNameLength = 80

    public var schemaVersion: Int
    public var clips: [CADAnimationClip]
    public var activeClipID: UUID?

    public init(schemaVersion: Int = CADAnimationDocument.legacySchemaVersion,
                clips: [CADAnimationClip] = [],
                activeClipID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.clips = clips
        self.activeClipID = activeClipID ?? clips.first?.id
    }

    public var activeClip: CADAnimationClip? {
        if let activeClipID, let match = clips.first(where: { $0.id == activeClipID }) {
            return match
        }
        return clips.first
    }

    public func clip(withID id: UUID) -> CADAnimationClip? {
        clips.first { $0.id == id }
    }

    public var isEmpty: Bool { clips.isEmpty }

    public var clipCount: Int { clips.count }

    public var trackCount: Int { clips.reduce(0) { $0 + $1.tracks.count } }

    public var keyframeCount: Int {
        clips.reduce(0) { total, clip in
            total + clip.tracks.reduce(0) { $0 + $1.keyframes.count }
        }
    }

    /// Schema required by the REAL stored data, independent of the declared
    /// header. A timing curve is non-additive for a schema-1 writer, so its
    /// presence requires schema 2 even if a bad/older writer left the header
    /// at 1.
    public var requiredSchemaVersion: Int {
        if clips.contains(where: { $0.rigID != nil }) { return Self.rigSchemaVersion }
        if clips.contains(where: { $0.physicsCacheID != nil }) { return Self.physicsSchemaVersion }
        return clips.contains { clip in
            clip.tracks.contains { track in
                track.keyframes.contains { $0.timingCurve != nil }
            }
        } ? CADAnimationDocument.timingCurveSchemaVersion
          : CADAnimationDocument.legacySchemaVersion
    }

    /// A curve that is present but unreadable must never be accepted as a
    /// writer input. Raw load/store assessment preserves those bytes and the
    /// animation surface reports them read-only; this is the last local check
    /// before a programmatic candidate is encoded.
    public var hasInvalidTimingCurve: Bool {
        clips.contains { clip in
            clip.tracks.contains { track in
                track.keyframes.contains {
                    guard let curve = $0.timingCurve else { return false }
                    return !curve.isValid
                }
            }
        }
    }

    /// Clamp, sort and bound a document before it is stored. Values that
    /// cannot be addressed at all (non-finite times, unknown targets) are
    /// dropped here rather than left to fail every later evaluation.
    ///
    /// The header is NOT unconditionally stamped with the newest schema.
    /// Legacy/default clips without a curve stay at schema 1; a real curve
    /// raises it to 2; an already-higher header is preserved so removing the
    /// last curve can never lower a document's declared/floor semantics.
    public func sanitized() -> CADAnimationDocument {
        var clean = self
        clean.clips = Array(clips.prefix(CADAnimationDocument.maximumClips))
            .map { $0.sanitized() }
            .filter { !$0.tracks.isEmpty || !$0.name.isEmpty }
        clean.schemaVersion = max(
            max(self.schemaVersion, CADAnimationDocument.legacySchemaVersion),
            clean.requiredSchemaVersion)
        if let activeClipID, clean.clips.contains(where: { $0.id == activeClipID }) {
            clean.activeClipID = activeClipID
        } else {
            clean.activeClipID = clean.clips.first?.id
        }
        return clean
    }
}

// MARK: - Clip

public nonisolated struct CADAnimationClip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var duration: Double
    /// Playback preference persisted with the clip; playback itself is
    /// transient and never writes the document.
    public var isLooping: Bool
    public var speed: Double
    public var tracks: [CADAnimationTrack]
    /// References the sole sceneSettings cache; no preset/baked key duplication.
    public var physicsCacheID: UUID? = nil
    public var rigID: UUID? = nil

    public init(id: UUID = UUID(),
                name: String,
                duration: Double = CADAnimationDocument.defaultDurationSeconds,
                isLooping: Bool = true,
                speed: Double = 1,
                tracks: [CADAnimationTrack] = []) {
        self.id = id
        self.name = name
        self.duration = CADAnimationClip.validDuration(duration)
        self.isLooping = isLooping
        self.speed = CADAnimationClip.validSpeed(speed)
        self.tracks = tracks
    }

    public var cameraTrack: CADAnimationTrack? {
        tracks.first { $0.target.kind == .camera }
    }

    public var instanceTracks: [CADAnimationTrack] {
        tracks.filter { $0.target.kind == .instance }
    }

    public var keyframeCount: Int { tracks.reduce(0) { $0 + $1.keyframes.count } }

    /// Total frames at an integer frame rate, including frame zero. The video
    /// export uses the exact same count so progress and metadata agree.
    public func frameCount(at frameRate: Int) -> Int {
        let fps = min(max(frameRate, 1), 60)
        return max(1, Int((duration * Double(fps)).rounded()))
    }

    public static func validDuration(_ value: Double) -> Double {
        guard value.isFinite else { return CADAnimationDocument.defaultDurationSeconds }
        return min(max(value, CADAnimationDocument.minimumDurationSeconds),
                   CADAnimationDocument.maximumDurationSeconds)
    }

    public static func validSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0.1), 8)
    }

    public func sanitized() -> CADAnimationClip {
        var clean = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.name = String((trimmed.isEmpty ? "Animation" : trimmed)
            .prefix(CADAnimationDocument.maximumNameLength))
        clean.duration = Self.validDuration(duration)
        clean.speed = Self.validSpeed(speed)
        var seenTargets = Set<String>()
        var boundedTracks: [CADAnimationTrack] = []
        for track in tracks.prefix(CADAnimationDocument.maximumTracksPerClip) {
            guard track.target.isValid, seenTargets.insert(track.target.stableKey).inserted else {
                continue
            }
            boundedTracks.append(track.sanitized(maximumTime: clean.duration))
        }
        clean.tracks = boundedTracks
        return clean
    }
}

// MARK: - Track

public nonisolated struct CADAnimationTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var target: CADAnimationTarget
    public var keyframes: [CADAnimationKeyframe]

    public init(id: UUID = UUID(),
                target: CADAnimationTarget,
                keyframes: [CADAnimationKeyframe] = []) {
        self.id = id
        self.target = target
        self.keyframes = keyframes
    }

    public func sanitized(maximumTime: Double) -> CADAnimationTrack {
        var clean = self
        clean.keyframes = CADAnimationKeyframe.sortedAndDeduplicated(
            keyframes.prefix(CADAnimationDocument.maximumKeyframesPerTrack),
            maximumTime: maximumTime)
        return clean
    }
}

// MARK: - Target

/// A track either drives the presentation camera or one placed assembly
/// instance. `instanceID` is the stable assembly instance identity (the same
/// identity the presentation scene uses for its entity), never the source
/// body's identity. `sourceBodyID` records which definition the animation was
/// authored against so a re-bound instance can be reported instead of moved
/// silently.
public nonisolated struct CADAnimationTarget: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case camera
        case instance
    }

    public var kind: Kind
    public var instanceID: UUID?
    public var sourceBodyID: UUID?

    public init(kind: Kind, instanceID: UUID? = nil, sourceBodyID: UUID? = nil) {
        self.kind = kind
        self.instanceID = instanceID
        self.sourceBodyID = sourceBodyID
    }

    public static let camera = CADAnimationTarget(kind: .camera)

    public static func instance(_ instanceID: UUID, sourceBodyID: UUID? = nil) -> CADAnimationTarget {
        CADAnimationTarget(kind: .instance, instanceID: instanceID,
                           sourceBodyID: sourceBodyID)
    }

    public var isValid: Bool {
        switch kind {
        case .camera:
            return instanceID == nil
        case .instance:
            return instanceID != nil
        }
    }

    public var stableKey: String {
        switch kind {
        case .camera:
            return "camera"
        case .instance:
            return "instance:\(instanceID?.uuidString ?? "-")"
        }
    }
}

// MARK: - Keyframe

public nonisolated struct CADAnimationKeyframe: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Seconds from the clip start.
    public var time: Double
    /// Interpolation of the segment that STARTS at this keyframe.
    public var interpolation: CADAnimationInterpolation
    /// Optional additive timing curve for the segment that STARTS here. When
    /// present and valid it overrides `interpolation`; nil keeps the legacy
    /// linear/easeInOut behaviour. This member is additive: old documents
    /// decode it as nil and older readers ignore it.
    public var timingCurve: CADAnimationTimingCurve?
    public var camera: CADAnimationCameraValue?
    public var instance: CADAnimationInstanceValue?

    public init(id: UUID = UUID(),
                time: Double,
                interpolation: CADAnimationInterpolation = .linear,
                camera: CADAnimationCameraValue? = nil,
                instance: CADAnimationInstanceValue? = nil,
                timingCurve: CADAnimationTimingCurve? = nil) {
        self.id = id
        self.time = time
        self.interpolation = interpolation
        self.camera = camera
        self.instance = instance
        self.timingCurve = timingCurve
    }

    /// Normalized segment progress. A valid authored timing curve wins; an
    /// absent or malformed curve falls back to the persisted enumeration so a
    /// damaged additive member never changes the evaluated pose.
    public func progress(_ rawProgress: Double) -> Double {
        if let timingCurve, timingCurve.isValid {
            return timingCurve.progress(rawProgress)
        }
        return interpolation.eased(rawProgress)
    }

    public func value(for kind: CADAnimationTarget.Kind) -> CADAnimationKeyframeValue? {
        switch kind {
        case .camera:
            return camera.map(CADAnimationKeyframeValue.camera)
        case .instance:
            return instance.map(CADAnimationKeyframeValue.instance)
        }
    }

    public func isValid(for kind: CADAnimationTarget.Kind) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        switch kind {
        case .camera:
            return camera?.isValid == true && instance == nil
        case .instance:
            return instance?.isValid == true && camera == nil
        }
    }

    static func sortedAndDeduplicated<S: Sequence>(_ frames: S,
                                                   maximumTime: Double) -> [CADAnimationKeyframe]
    where S.Element == CADAnimationKeyframe {
        var result: [CADAnimationKeyframe] = []
        for frame in frames {
            guard frame.time.isFinite, frame.time >= 0 else { continue }
            var clean = frame
            clean.time = min(frame.time, max(maximumTime, 0))
            clean.interpolation = frame.interpolation
            if let index = result.firstIndex(where: { abs($0.time - clean.time) < 1e-6 }) {
                // Collapse a near-identical duplicate onto the time already
                // stored for that bucket: the later value wins, but a 1e-7 s
                // duplicate must not move the bucket away from 0, or a
                // sanitized track would start at a non-zero time.
                clean.time = result[index].time
                result[index] = clean
            } else {
                result.append(clean)
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

public nonisolated enum CADAnimationKeyframeValue: Sendable, Equatable {
    case camera(CADAnimationCameraValue)
    case instance(CADAnimationInstanceValue)

    public var cameraValue: CADAnimationCameraValue? {
        if case .camera(let value) = self { return value }
        return nil
    }

    public var instanceValue: CADAnimationInstanceValue? {
        if case .instance(let value) = self { return value }
        return nil
    }
}

// MARK: - Interpolation

public nonisolated enum CADAnimationInterpolation: String, Codable, Sendable, CaseIterable {
    case linear
    case easeInOut

    public var titleKey: String {
        switch self {
        case .linear: return "cad.animation.interpolation.linear"
        case .easeInOut: return "cad.animation.interpolation.easeInOut"
        }
    }

    /// Normalized segment progress. `easeInOut` is the standard cubic
    /// ease-in-out (zero velocity at both ends); it is deterministic and the
    /// exact function is covered by the focused tests.
    public func eased(_ progress: Double) -> Double {
        let t = min(max(progress.isFinite ? progress : 0, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeInOut:
            if t < 0.5 {
                return 4 * t * t * t
            }
            let shifted = -2 * t + 2
            return 1 - (shifted * shifted * shifted) / 2
        }
    }
}

// MARK: - Timing curve

/// Narrow, additive timing curve for one keyframe's outgoing segment.
///
/// The four values are the standard cubic-Bézier control points
/// `(x1, y1, x2, y2)` with the implicit endpoints `(0, 0)` and `(1, 1)`.
/// All four control values stay in `0...1`, so the curve is a function of
/// time and cannot push an interpolated camera/part value outside the two
/// endpoint values. A nil `timingCurve` keeps the existing
/// `CADAnimationInterpolation` behaviour, so documents written before this
/// field existed evaluate exactly as before and older readers ignore the
/// additive JSON member.
public nonisolated struct CADAnimationTimingCurve: Codable, Sendable, Equatable {
    /// The accepted control-value range. An authored edit outside it is
    /// refused instead of being silently clamped or dropped.
    public static let minimumControlValue = 0.0
    public static let maximumControlValue = 1.0
    public static let defaultCurve = CADAnimationTimingCurve(
        x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    public var x1: Double
    public var y1: Double
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public var isValid: Bool {
        x1.isFinite && y1.isFinite && x2.isFinite && y2.isFinite
            && x1 >= Self.minimumControlValue && x1 <= Self.maximumControlValue
            && y1 >= Self.minimumControlValue && y1 <= Self.maximumControlValue
            && x2 >= Self.minimumControlValue && x2 <= Self.maximumControlValue
            && y2 >= Self.minimumControlValue && y2 <= Self.maximumControlValue
    }

    /// Normalized segment progress in `0...1`. A deterministic Newton solve
    /// with a bisection fallback keeps this a real evaluated curve, not a
    /// cosmetic mode label.
    public func progress(_ rawProgress: Double) -> Double {
        let x = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        guard isValid else { return x }
        var t = x
        for _ in 0..<6 {
            let error = sample(x1, x2, t) - x
            if abs(error) < 1e-7 { return sample(y1, y2, t) }
            let slope = derivative(x1, x2, t)
            guard slope.isFinite, abs(slope) > 1e-9 else { break }
            let next = t - error / slope
            guard next.isFinite, next > 0, next < 1 else { break }
            t = next
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<40 {
            t = (lower + upper) * 0.5
            let value = sample(x1, x2, t)
            if abs(value - x) < 1e-7 { break }
            if value < x { lower = t } else { upper = t }
        }
        return sample(y1, y2, t)
    }

    /// Point at Bézier parameter `t`, in curve space. The native editor draws
    /// the same shape the evaluator consumes.
    public func point(at t: Double) -> (x: Double, y: Double) {
        let value = min(max(t.isFinite ? t : 0, 0), 1)
        return (sample(x1, x2, value), sample(y1, y2, value))
    }

    private func sample(_ p1: Double, _ p2: Double, _ t: Double) -> Double {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * t * p1
            + 3 * oneMinusT * t * t * p2
            + t * t * t
    }

    private func derivative(_ p1: Double, _ p2: Double, _ t: Double) -> Double {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * p1
            + 6 * oneMinusT * t * (p2 - p1)
            + 3 * t * t * (1 - p2)
    }
}

// MARK: - Camera value

public nonisolated struct CADAnimationCameraValue: Codable, Sendable, Equatable {
    /// Orbit target in presentation metres.
    public var target: SIMD3<Double>
    /// Eye distance in metres.
    public var distance: Double
    public var azimuthRadians: Double
    public var elevationRadians: Double
    public var fovYDegrees: Double

    public init(target: SIMD3<Double> = .zero,
                distance: Double = 1,
                azimuthRadians: Double = .pi * 0.22,
                elevationRadians: Double = .pi * 0.12,
                fovYDegrees: Double = 60) {
        self.target = target
        self.distance = distance
        self.azimuthRadians = azimuthRadians
        self.elevationRadians = elevationRadians
        self.fovYDegrees = fovYDegrees
    }

    public var isValid: Bool {
        target.x.isFinite && target.y.isFinite && target.z.isFinite
            && distance.isFinite && distance > 0
            && distance <= 500
            && azimuthRadians.isFinite && elevationRadians.isFinite
            && elevationRadians > -1.5707 && elevationRadians < 1.5707
            && fovYDegrees.isFinite && fovYDegrees >= 10 && fovYDegrees <= 150
    }

    /// Fit a whole model from millimetre bounds, matching the presentation's
    /// `CADPresentationCamera.fitted` math (bounding sphere, 18% margin,
    /// portrait aspect respected) but expressed as a persisted value.
    public static func fitted(boundsMinMM: SIMD3<Double>?,
                              boundsMaxMM: SIMD3<Double>?,
                              fovYDegrees: Double = 60,
                              aspect: Double? = nil) -> CADAnimationCameraValue {
        guard let minBound = boundsMinMM, let maxBound = boundsMaxMM,
              minBound.x.isFinite, minBound.y.isFinite, minBound.z.isFinite,
              maxBound.x.isFinite, maxBound.y.isFinite, maxBound.z.isFinite else {
            return CADAnimationCameraValue(fovYDegrees: fovYDegrees)
        }
        let centerMM = (minBound + maxBound) * 0.5
        let radiusMM = max(simd_length((maxBound - minBound) * 0.5), 0.5)
        let radiusM = radiusMM / 1_000
        let vertical = max(fovYDegrees, 10) * .pi / 360
        var half = vertical
        if let aspect, aspect.isFinite, aspect > 0, aspect < 1 {
            half = atan(tan(vertical) * aspect)
        }
        let distance = min(max(radiusM / max(tan(half), 0.05) * 1.18,
                               radiusM * 1.6), 500)
        return CADAnimationCameraValue(
            target: SIMD3(centerMM.x / 1_000, centerMM.y / 1_000, centerMM.z / 1_000),
            distance: distance,
            azimuthRadians: .pi * 0.22,
            elevationRadians: .pi * 0.12,
            fovYDegrees: min(max(fovYDegrees, 10), 150))
    }

    public func interpolated(to other: CADAnimationCameraValue, progress: Double) -> CADAnimationCameraValue {
        let t = min(max(progress.isFinite ? progress : 0, 0), 1)
        return CADAnimationCameraValue(
            target: target + (other.target - target) * t,
            distance: distance + (other.distance - distance) * t,
            // Angles interpolate linearly so a full turntable turn keeps its
            // direction instead of being shortened to the nearest angle.
            azimuthRadians: azimuthRadians + (other.azimuthRadians - azimuthRadians) * t,
            elevationRadians: elevationRadians + (other.elevationRadians - elevationRadians) * t,
            fovYDegrees: fovYDegrees + (other.fovYDegrees - fovYDegrees) * t)
    }

    public var normalizedAngles: CADAnimationCameraValue {
        var clean = self
        func wrapped(_ angle: Double) -> Double {
            guard angle.isFinite else { return 0 }
            let twoPi = Double.pi * 2
            var value = angle.truncatingRemainder(dividingBy: twoPi)
            if value > .pi { value -= twoPi }
            if value < -.pi { value += twoPi }
            return value
        }
        clean.azimuthRadians = wrapped(azimuthRadians)
        return clean
    }
}

// MARK: - Instance value

public nonisolated struct CADAnimationInstanceValue: Codable, Sendable, Equatable {
    /// Instance placement translation in millimetres (model space).
    public var translationMM: SIMD3<Double>
    /// (x, y, z, w) rotation; normalized on use.
    public var rotation: SIMD4<Double>

    public init(translationMM: SIMD3<Double> = .zero,
                rotation: SIMD4<Double> = SIMD4(0, 0, 0, 1)) {
        self.translationMM = translationMM
        self.rotation = rotation
    }

    public var isValid: Bool {
        translationMM.x.isFinite && translationMM.y.isFinite && translationMM.z.isFinite
            && rotation.x.isFinite && rotation.y.isFinite
            && rotation.z.isFinite && rotation.w.isFinite
            && simd_length_squared(rotation) > 1e-12
    }

    public var normalizedRotation: SIMD4<Double> {
        let length = simd_length(rotation)
        guard length > 1e-12, length.isFinite else { return SIMD4(0, 0, 0, 1) }
        return rotation / length
    }

    public func interpolated(to other: CADAnimationInstanceValue, progress: Double) -> CADAnimationInstanceValue {
        let t = min(max(progress.isFinite ? progress : 0, 0), 1)
        return CADAnimationInstanceValue(
            translationMM: translationMM + (other.translationMM - translationMM) * t,
            rotation: CADAnimationQuaternion.slerp(normalizedRotation,
                                                   other.normalizedRotation,
                                                   t))
    }
}

// MARK: - Quaternion math

public nonisolated enum CADAnimationQuaternion {
    public static func normalize(_ value: SIMD4<Double>) -> SIMD4<Double> {
        let length = simd_length(value)
        guard length > 1e-12, length.isFinite else { return SIMD4(0, 0, 0, 1) }
        return value / length
    }

    /// Shortest-path spherical interpolation. Nearly identical quaternions use
    /// a normalized linear interpolation to avoid dividing by a vanishing
    /// sine; a degenerate input becomes identity.
    public static func slerp(_ start: SIMD4<Double>, _ end: SIMD4<Double>,
                             _ progress: Double) -> SIMD4<Double> {
        let a = normalize(start)
        var b = normalize(end)
        let t = min(max(progress.isFinite ? progress : 0, 0), 1)
        var dot = simd_dot(a, b)
        if dot < 0 {
            b = -b
            dot = -dot
        }
        dot = min(max(dot, -1), 1)
        if dot > 0.9995 {
            return normalize(a + (b - a) * t)
        }
        let theta = acos(dot)
        let sine = sin(theta)
        guard abs(sine) > 1e-12 else { return a }
        let weightA = sin((1 - t) * theta) / sine
        let weightB = sin(t * theta) / sine
        return normalize(a * weightA + b * weightB)
    }

    /// Intrinsic XYZ Euler degrees to an (x, y, z, w) quaternion. Used by the
    /// JSON API so a caller can author a part rotation without packing a
    /// quaternion by hand.
    public static func fromEulerDegrees(_ degrees: SIMD3<Double>) -> SIMD4<Double> {
        // simd_quatd(angle:axis:) takes the rotation angle in radians and
        // applies the half-angle internally. Passing a pre-halved angle here
        // silently authored every part rotation at half its declared value.
        let radians = degrees * (.pi / 180)
        let qx = simd_quatd(angle: radians.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatd(angle: radians.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatd(angle: radians.z, axis: SIMD3(0, 0, 1))
        let q = qz * qy * qx
        return normalize(SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real))
    }

    /// Intrinsic XYZ Euler degrees matching `fromEulerDegrees`. Near gimbal
    /// lock the roll/yaw pair is not unique; this returns one deterministic
    /// finite representative for the editable value form.
    public static func eulerDegrees(from quaternion: SIMD4<Double>) -> SIMD3<Double> {
        let q = normalize(quaternion)
        let x = q.x, y = q.y, z = q.z, w = q.w
        let sinPitch = min(max(2 * (w * y - z * x), -1), 1)
        let pitch = asin(sinPitch)
        let roll: Double
        let yaw: Double
        if abs(sinPitch) > 0.999999 {
            // Gimbal lock: put the remaining rotation on yaw.
            roll = 0
            yaw = atan2(2 * (x * y + w * z), 1 - 2 * (y * y + z * z))
        } else {
            roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
            yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        }
        let degrees = 180 / Double.pi
        return SIMD3(roll * degrees, pitch * degrees, yaw * degrees)
    }

    /// True when the quaternion rotates `vector` by roughly `angleDegrees`
    /// around `axis`; used by the focused tests (kept here so the test and the
    /// runtime use the same convention).
    public static func rotated(_ vector: SIMD3<Double>, by quaternion: SIMD4<Double>) -> SIMD3<Double> {
        let q = simd_quatd(ix: quaternion.x, iy: quaternion.y,
                           iz: quaternion.z, r: quaternion.w)
        return q.act(vector)
    }
}

// MARK: - Issue

public nonisolated struct CADAnimationIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case corruptData
        case newerSchema
        case missingInstance
        case missingSource
        case sourceBindingChanged
        case sourceGeometryUpdated
        case invalidTrackValue
        case duplicateTrack
        case tooLarge
    }

    public var id: String
    public var kind: Kind
    public var clipID: UUID?
    public var trackID: UUID?
    public var instanceID: UUID?
    public var detail: String

    public init(id: String,
                kind: Kind,
                clipID: UUID? = nil,
                trackID: UUID? = nil,
                instanceID: UUID? = nil,
                detail: String) {
        self.id = id
        self.kind = kind
        self.clipID = clipID
        self.trackID = trackID
        self.instanceID = instanceID
        self.detail = detail
    }

    public var localizationKey: String {
        switch kind {
        case .corruptData: return "cad.animation.issue.corrupt"
        case .newerSchema: return "cad.animation.issue.newerSchema"
        case .missingInstance: return "cad.animation.issue.missingInstance"
        case .missingSource: return "cad.animation.issue.missingSource"
        case .sourceBindingChanged: return "cad.animation.issue.sourceChanged"
        case .sourceGeometryUpdated: return "cad.animation.issue.sourceUpdated"
        case .invalidTrackValue: return "cad.animation.issue.invalidValue"
        case .duplicateTrack: return "cad.animation.issue.duplicateTrack"
        case .tooLarge: return "cad.animation.issue.tooLarge"
        }
    }
}

// MARK: - Evaluation scene context

/// Renderer-neutral identity of the assembly and the source bodies at one
/// evaluation. Built from the live document; never a second assembly store.
public nonisolated struct CADAnimationSceneContext: Sendable, Equatable {
    public struct Instance: Sendable, Equatable {
        public var id: UUID
        public var sourceBodyID: UUID
        public var sourceRevision: UInt64?
        public var baseline: CADAnimationInstanceValue

        public init(id: UUID, sourceBodyID: UUID,
                    sourceRevision: UInt64? = nil,
                    baseline: CADAnimationInstanceValue) {
            self.id = id
            self.sourceBodyID = sourceBodyID
            self.sourceRevision = sourceRevision
            self.baseline = baseline
        }
    }

    public var instances: [UUID: Instance]
    public var bodyRevisions: [UUID: UInt64]
    public var boundsMinMM: SIMD3<Double>?
    public var boundsMaxMM: SIMD3<Double>?
    public var spherePhysics: CADSpherePhysicsPlayback? = nil
    public var rig: CADRigPlayback? = nil

    public init(instances: [UUID: Instance] = [:],
                bodyRevisions: [UUID: UInt64] = [:],
                boundsMinMM: SIMD3<Double>? = nil,
                boundsMaxMM: SIMD3<Double>? = nil) {
        self.instances = instances
        self.bodyRevisions = bodyRevisions
        self.boundsMinMM = boundsMinMM
        self.boundsMaxMM = boundsMaxMM
    }
}

// MARK: - Evaluation

public nonisolated struct CADAnimationEvaluation: Sendable, Equatable {
    public var clipID: UUID
    public var time: Double
    public var duration: Double
    public var camera: CADAnimationCameraValue?
    /// Final instance placements to render for this frame, keyed by the stable
    /// assembly instance identity.
    public var instances: [UUID: CADAnimationInstanceValue]
    public var issues: [CADAnimationIssue]
    public var physicsFloorYMM: Double? = nil
    public var rigDeformation: CADRigDeformation? = nil

    public init(clipID: UUID,
                time: Double,
                duration: Double,
                camera: CADAnimationCameraValue? = nil,
                instances: [UUID: CADAnimationInstanceValue] = [:],
                issues: [CADAnimationIssue] = [], physicsFloorYMM: Double? = nil) {
        self.clipID = clipID
        self.time = time
        self.duration = duration
        self.camera = camera
        self.instances = instances
        self.issues = issues
        self.physicsFloorYMM = physicsFloorYMM
    }

    public var hasOverrides: Bool { camera != nil || !instances.isEmpty || rigDeformation != nil }
}

// MARK: - Preset

public nonisolated enum CADAnimationPreset {
    /// A restrained establishing shot followed by a dolly toward the authored
    /// view and a short final hold. It works for parts and buildings, uses the
    /// existing camera track/export path, and never moves model geometry.
    public static func reveal(name: String = "Reveal", duration: Double = 6,
                              base: CADAnimationCameraValue) -> CADAnimationClip {
        let length = CADAnimationClip.validDuration(duration)
        let end = base.isValid ? base : CADAnimationCameraValue()
        var start = end
        start.distance = min(end.distance * 1.7, 500)
        start.azimuthRadians = end.azimuthRadians - .pi / 5
        start.elevationRadians = min(max(end.elevationRadians + .pi / 12, -1.48), 1.48)
        var middle = end
        middle.distance = min(end.distance * 1.18, 500)
        middle.azimuthRadians = end.azimuthRadians - .pi / 12
        let keys = [
            CADAnimationKeyframe(time: 0, interpolation: .easeInOut, camera: start),
            CADAnimationKeyframe(time: length * 0.55, interpolation: .easeInOut, camera: middle),
            CADAnimationKeyframe(time: length * 0.85, interpolation: .linear, camera: end),
            CADAnimationKeyframe(time: length, interpolation: .linear, camera: end)
        ]
        return CADAnimationClip(name: name, duration: length, isLooping: false, tracks: [.init(target: .camera, keyframes: keys)])
    }

    /// One full orbit around the current (or fitted) camera target. Two
    /// linear keys keep angular speed constant.
    public static func turntable(name: String = "Turntable",
                                 duration: Double = CADAnimationDocument.defaultDurationSeconds,
                                 base: CADAnimationCameraValue,
                                 turns: Double = 1) -> CADAnimationClip {
        let length = CADAnimationClip.validDuration(duration)
        var start = base
        start.azimuthRadians = start.azimuthRadians.truncatingRemainder(dividingBy: .pi * 2)
        var end = start
        end.azimuthRadians = start.azimuthRadians + .pi * 2 * (turns.isFinite ? turns : 1)
        let track = CADAnimationTrack(
            target: .camera,
            keyframes: [
                CADAnimationKeyframe(time: 0, interpolation: .linear, camera: start),
                CADAnimationKeyframe(time: length, interpolation: .linear, camera: end),
            ])
        return CADAnimationClip(name: name, duration: length, isLooping: true,
                                speed: 1, tracks: [track])
    }

    /// Parts move radially away from the assembly centre and return to their
    /// exact baseline placement. Absolute keyframes are computed from the
    /// passed baseline; the assembly itself is never changed.
    public static func explodeReturn(name: String = "Explode",
                                     duration: Double = CADAnimationDocument.defaultDurationSeconds,
                                     seeds: [CADAnimationInstanceSeed],
                                     distanceMM: Double? = nil) -> CADAnimationClip {
        let length = CADAnimationClip.validDuration(duration)
        guard !seeds.isEmpty else {
            return CADAnimationClip(name: name, duration: length)
        }
        let center = seeds.reduce(SIMD3<Double>.zero) { $0 + $1.value.translationMM }
            / Double(seeds.count)
        let maxRadius = seeds.reduce(0.0) {
            max($0, simd_length($1.value.translationMM - center))
        }
        let travel = distanceMM ?? max(25, maxRadius * 0.35)
        let tracks: [CADAnimationTrack] = seeds.map { seed in
            var direction = seed.value.translationMM - center
            if simd_length_squared(direction) < 1e-9 {
                direction = SIMD3(1, 0.6, 0.8)
            }
            direction = simd_normalize(direction)
            let outward = seed.value.interpolated(
                to: CADAnimationInstanceValue(
                    translationMM: seed.value.translationMM + direction * travel,
                    rotation: seed.value.rotation),
                progress: 1)
            return CADAnimationTrack(
                target: .instance(seed.instanceID, sourceBodyID: seed.sourceBodyID),
                keyframes: [
                    CADAnimationKeyframe(time: 0, interpolation: .easeInOut,
                                         instance: seed.value),
                    CADAnimationKeyframe(time: length * 0.45, interpolation: .easeInOut,
                                         instance: outward),
                    CADAnimationKeyframe(time: length, interpolation: .easeInOut,
                                         instance: seed.value),
                ])
        }
        return CADAnimationClip(name: name, duration: length, isLooping: true,
                                speed: 1, tracks: tracks)
    }
}

public nonisolated struct CADAnimationInstanceSeed: Sendable, Equatable {
    public var instanceID: UUID
    public var sourceBodyID: UUID
    public var value: CADAnimationInstanceValue

    public init(instanceID: UUID, sourceBodyID: UUID,
                value: CADAnimationInstanceValue) {
        self.instanceID = instanceID
        self.sourceBodyID = sourceBodyID
        self.value = value
    }
}

// MARK: - Persisted format intent

/// Raw classification of the optional animation column. It deliberately does
/// NOT decode through the Swift model first: a schema-1 writer can ignore an
/// unknown `timingCurve` member and then rewrite the record without it, so the
/// package floor and the animation read/editability state must be derived
/// from the persisted bytes themselves.
///
/// The inspector is intentionally narrow (schema header plus the new curve
/// member). Other animation fields keep their existing decode/issue path.
public nonisolated struct CADAnimationFormatIntent: Sendable, Equatable {
    /// Package floor implied by the animation bytes, using the existing
    /// coordinated associative/curve floor (2).
    public var requiredVersion = CADAnimationDocument.legacySchemaVersion
    public var declaredSchemaVersion: Int?
    public var containsTimingCurve = false
    public var containsPhysicsCache = false
    public var containsRig = false
    /// A curve member this build cannot verify. The original bytes must be
    /// preserved; no reader/writer may replace it with linear/ease.
    public var isMalformed = false

    public var isFutureSchema: Bool {
        guard let declaredSchemaVersion else { return false }
        return declaredSchemaVersion > CADAnimationDocument.currentSchemaVersion
    }
}

public nonisolated enum CADAnimationFormat {
    /// Inspect the actual JSON bytes. Missing data is legacy/empty. A missing
    /// or non-integer schema is malformed; a schema above this build's
    /// current version is future and keeps at least its own floor (capped in
    /// practice by `CADDocumentFormat.supportedVersion`, so a far-future value
    /// makes the package unwritable instead of silently downgrading it).
    public static func intent(_ data: Data?) -> CADAnimationFormatIntent {
        var result = CADAnimationFormatIntent()
        guard let data, !data.isEmpty else { return result }
        guard data.count <= CADAnimationDocument.maximumEncodedBytes else {
            result.requiredVersion = CADAnimationDocument.timingCurveSchemaVersion
            result.isMalformed = true
            return result
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            result.requiredVersion = CADAnimationDocument.timingCurveSchemaVersion
            result.isMalformed = true
            return result
        }
        guard let rawSchema = object["schemaVersion"],
              let schema = realInteger(rawSchema), schema >= 1 else {
            result.requiredVersion = CADAnimationDocument.timingCurveSchemaVersion
            result.isMalformed = true
            return result
        }
        result.declaredSchemaVersion = schema
        if schema > CADAnimationDocument.currentSchemaVersion {
            result.requiredVersion = max(CADAnimationDocument.timingCurveSchemaVersion,
                                         schema)
        } else if schema >= CADAnimationDocument.timingCurveSchemaVersion {
            result.requiredVersion = max(result.requiredVersion, schema)
        }
        guard let rawClips = object["clips"] else {
            result.isMalformed = true
            result.requiredVersion = max(result.requiredVersion,
                                          CADAnimationDocument.timingCurveSchemaVersion)
            return result
        }
        guard let clips = rawClips as? [[String: Any]] else {
            result.isMalformed = true
            result.requiredVersion = max(result.requiredVersion,
                                          CADAnimationDocument.timingCurveSchemaVersion)
            return result
        }
        for clip in clips {
            if let raw = clip["physicsCacheID"], !(raw is NSNull) {
                result.containsPhysicsCache = true
                result.requiredVersion = max(result.requiredVersion, 7)
                if schema < CADAnimationDocument.physicsSchemaVersion || (raw as? String).flatMap(UUID.init(uuidString:)) == nil { result.isMalformed = true }
            }
            if let raw = clip["rigID"], !(raw is NSNull) {
                result.containsRig = true; result.requiredVersion = max(result.requiredVersion, 7)
                if let physics = clip["physicsCacheID"], !(physics is NSNull) { result.isMalformed = true }
                if schema < CADAnimationDocument.rigSchemaVersion || (raw as? String).flatMap(UUID.init(uuidString:)) == nil { result.isMalformed = true }
            }
            guard let rawTracks = clip["tracks"],
                  let tracks = rawTracks as? [[String: Any]] else {
                result.isMalformed = true
                continue
            }
            for track in tracks {
                guard let rawKeyframes = track["keyframes"],
                      let keyframes = rawKeyframes as? [[String: Any]] else {
                    result.isMalformed = true
                    continue
                }
                for keyframe in keyframes {
                    guard let rawCurve = keyframe["timingCurve"] else { continue }
                    if rawCurve is NSNull { continue }
                    result.containsTimingCurve = true
                    result.requiredVersion = max(result.requiredVersion,
                                                  CADAnimationDocument.timingCurveSchemaVersion)
                    guard let curve = rawCurve as? [String: Any],
                          Set(curve.keys) == Set(["x1", "y1", "x2", "y2"]),
                          let x1 = realNumber(curve["x1"]),
                          let y1 = realNumber(curve["y1"]),
                          let x2 = realNumber(curve["x2"]),
                          let y2 = realNumber(curve["y2"]),
                          CADAnimationTimingCurve(x1: x1, y1: y1,
                                                  x2: x2, y2: y2).isValid else {
                        result.isMalformed = true
                        continue
                    }
                }
            }
        }
        if result.isMalformed {
            result.requiredVersion = max(result.requiredVersion,
                                          CADAnimationDocument.timingCurveSchemaVersion)
        }
        return result
    }

    /// JSONSerialization bridges booleans to NSNumber and `doubleValue`
    /// accepts them as 1/0. A persisted control value must be a real number.
    private static func realNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        guard String(cString: number.objCType) != "c" else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return value
    }

    private static func realInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        guard String(cString: number.objCType) != "c" else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(),
              value >= Double(Int.min), value <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }
}

// MARK: - Codec

public nonisolated enum CADAnimationCodec {
    public static func encode(_ animation: CADAnimationDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(animation)
    }

    public static func decode(_ data: Data) throws -> CADAnimationDocument {
        try JSONDecoder().decode(CADAnimationDocument.self, from: data)
    }
}

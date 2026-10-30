//
//  CADAnimationModel.swift
//  FloeCADKit
//
//  Persisted, renderer-neutral keyframe animation for a native FloeCAD
//  document. Clips animate the presentation camera and assembly instance
//  translation/rotation only; they never store geometry, never replace the
//  assembly baseline and never describe a physics/kinematics simulation.
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
    public static let currentSchemaVersion = 1
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

    public init(schemaVersion: Int = CADAnimationDocument.currentSchemaVersion,
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

    /// Clamp, sort and bound a document before it is stored. Values that
    /// cannot be addressed at all (non-finite times, unknown targets) are
    /// dropped here rather than left to fail every later evaluation.
    public func sanitized() -> CADAnimationDocument {
        var clean = self
        clean.schemaVersion = CADAnimationDocument.currentSchemaVersion
        clean.clips = Array(clips.prefix(CADAnimationDocument.maximumClips))
            .map { $0.sanitized() }
            .filter { !$0.tracks.isEmpty || !$0.name.isEmpty }
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
    public var camera: CADAnimationCameraValue?
    public var instance: CADAnimationInstanceValue?

    public init(id: UUID = UUID(),
                time: Double,
                interpolation: CADAnimationInterpolation = .linear,
                camera: CADAnimationCameraValue? = nil,
                instance: CADAnimationInstanceValue? = nil) {
        self.id = id
        self.time = time
        self.interpolation = interpolation
        self.camera = camera
        self.instance = instance
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
        let half = degrees * (.pi / 360)
        let qx = simd_quatd(angle: half.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatd(angle: half.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatd(angle: half.z, axis: SIMD3(0, 0, 1))
        let q = qz * qy * qx
        return normalize(SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real))
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

    public init(clipID: UUID,
                time: Double,
                duration: Double,
                camera: CADAnimationCameraValue? = nil,
                instances: [UUID: CADAnimationInstanceValue] = [:],
                issues: [CADAnimationIssue] = []) {
        self.clipID = clipID
        self.time = time
        self.duration = duration
        self.camera = camera
        self.instances = instances
        self.issues = issues
    }

    public var hasOverrides: Bool { camera != nil || !instances.isEmpty }
}

// MARK: - Preset

public nonisolated enum CADAnimationPreset {
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

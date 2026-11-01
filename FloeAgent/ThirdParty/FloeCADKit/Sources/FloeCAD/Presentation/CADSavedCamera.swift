//
//  CADSavedCamera.swift
//  FloeCADKit
//
//  X21 — named, persisted presentation cameras (saved "shots").
//
//  A saved camera is document state, not a renderer setting: it stores the
//  orbit pose, the projection and the framing the user saw, and it is written
//  through the SAME additive `sceneSettings` record as the environment and the
//  legacy scene camera. Perspective and orthographic use one shared framing
//  value (`fovYDegrees`): an orthographic camera derives its visible
//  half-height from `distanceMM * tan(fovY / 2)`, exactly like the engineering
//  viewport, so toggling projection never changes the model's on-screen size.
//
//  Units are document millimetres, matching `CADSceneSettings.Camera`; the
//  RealityKit presentation converts once to metres. Nothing here mutates a
//  mesh, a selection or a second scene store.
//

import Foundation
import simd

// MARK: - Projection

/// Projection shared by every saved camera, the native Present camera and the
/// engineering capture. Raw values are persisted.
public nonisolated enum CADCameraProjection: String, Codable, Sendable,
                                               CaseIterable, Equatable {
    case perspective
    case orthographic

    public var isOrthographic: Bool { self == .orthographic }
}

// MARK: - Saved camera

public nonisolated struct CADSavedCamera: Identifiable, Equatable, Sendable,
                                                  Codable {
    public static let currentSchemaVersion = 1

    /// Bounded document growth. Saving beyond this refuses rather than
    /// silently dropping an older shot.
    public static let maximumCount = 32
    public static let maximumNameLength = 60
    public static let minimumDistanceMM = 2.0
    public static let maximumDistanceMM = 500_000.0
    public static let minimumFovYDegrees = 10.0
    public static let maximumFovYDegrees = 150.0
    /// The presentation's orbit limit. A saved camera must be reproducible by
    /// the native surface, whose `stageTransform` becomes unstable as the
    /// view direction approaches a pole.
    public static let maximumElevationRadians = 1.48
    public static let minimumFrameAspect = 0.2
    public static let maximumFrameAspect = 5.0

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var projection: CADCameraProjection
    /// Orbit target in document millimetres.
    public var targetMM: SIMD3<Double>
    /// Eye distance in document millimetres.
    public var distanceMM: Double
    public var azimuthRadians: Double
    public var elevationRadians: Double
    /// Vertical framing angle in degrees, used by both projections.
    public var fovYDegrees: Double
    /// Export frame width ÷ height captured when the view was saved.
    public var frameAspect: Double
    public var createdAt: Date

    public init(schemaVersion: Int = CADSavedCamera.currentSchemaVersion,
                id: UUID = UUID(),
                name: String,
                projection: CADCameraProjection = .perspective,
                targetMM: SIMD3<Double> = .zero,
                distanceMM: Double = 1_000,
                azimuthRadians: Double = .pi * 0.22,
                elevationRadians: Double = .pi * 0.12,
                fovYDegrees: Double = 60,
                frameAspect: Double = 1,
                createdAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.projection = projection
        self.targetMM = targetMM
        self.distanceMM = distanceMM
        self.azimuthRadians = azimuthRadians
        self.elevationRadians = elevationRadians
        self.fovYDegrees = fovYDegrees
        self.frameAspect = frameAspect
        self.createdAt = createdAt
    }

    /// Build from the historical single `CADSceneSettings.Camera` (the legacy
    /// scene camera). That camera is already in millimetres.
    public init(id: UUID = UUID(),
                name: String,
                documentCamera: CADSceneSettings.Camera,
                frameAspect: Double = 1,
                createdAt: Date = Date()) {
        self.init(
            id: id,
            name: name,
            projection: documentCamera.isOrthographic ? .orthographic : .perspective,
            targetMM: SIMD3(documentCamera.targetX,
                            documentCamera.targetY,
                            documentCamera.targetZ),
            distanceMM: documentCamera.distance,
            azimuthRadians: documentCamera.azimuthRadians,
            elevationRadians: documentCamera.elevationRadians,
            fovYDegrees: documentCamera.fovYDegrees,
            frameAspect: frameAspect,
            createdAt: createdAt)
    }

    /// The same pose in the persisted scene-settings shape (millimetres).
    public var documentCamera: CADSceneSettings.Camera {
        CADSceneSettings.Camera(
            azimuthRadians: azimuthRadians,
            elevationRadians: elevationRadians,
            distance: distanceMM,
            targetX: targetMM.x,
            targetY: targetMM.y,
            targetZ: targetMM.z,
            fovYDegrees: fovYDegrees,
            isOrthographic: projection.isOrthographic)
    }

    // MARK: Validation

    /// A repaired copy, or nil when a required value can never be a camera.
    /// Names are trimmed and whitespace-collapsed; numeric values are clamped
    /// into the documented bounds so a hand-edited package stays openable.
    public var sanitized: CADSavedCamera? {
        guard let cleanName = Self.normalizedName(name) else { return nil }
        guard targetMM.x.isFinite, targetMM.y.isFinite, targetMM.z.isFinite else {
            return nil
        }
        guard distanceMM.isFinite, distanceMM > 0,
              azimuthRadians.isFinite, elevationRadians.isFinite,
              abs(elevationRadians) <= Self.maximumElevationRadians + 1e-9,
              fovYDegrees.isFinite,
              fovYDegrees >= Self.minimumFovYDegrees,
              fovYDegrees <= Self.maximumFovYDegrees,
              frameAspect.isFinite, frameAspect > 0 else { return nil }
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.name = cleanName
        copy.distanceMM = min(max(distanceMM, Self.minimumDistanceMM),
                              Self.maximumDistanceMM)
        copy.elevationRadians = min(max(elevationRadians,
                                        -Self.maximumElevationRadians),
                                    Self.maximumElevationRadians)
        copy.frameAspect = Self.sanitizedFrameAspect(frameAspect)
        copy.fovYDegrees = min(max(fovYDegrees, Self.minimumFovYDegrees),
                               Self.maximumFovYDegrees)
        return copy
    }

    /// Trim, collapse internal whitespace and enforce the single-row length.
    /// Empty or over-long names refuse instead of being silently truncated.
    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var collapsed = ""
        var pendingSpace = false
        for character in trimmed {
            if character.isWhitespace {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace {
                collapsed.append(" ")
                pendingSpace = false
            }
            collapsed.append(character)
        }
        guard !collapsed.isEmpty,
              collapsed.count <= maximumNameLength else { return nil }
        return collapsed
    }

    public static func sanitizedFrameAspect(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, minimumFrameAspect), maximumFrameAspect)
    }

    public static func sanitizedFrameAspect(_ value: Double?) -> Double {
        guard let value else { return 1 }
        return sanitizedFrameAspect(value)
    }

    /// Human-readable frame label. Ratios are exact presets within a small
    /// tolerance; everything else is a locale-independent decimal ratio.
    public var frameLabel: String { Self.frameLabel(forAspect: frameAspect) }

    public static func frameLabel(forAspect aspect: Double) -> String {
        let presets: [(Double, String)] = [
            (1, "1:1"), (4.0 / 3, "4:3"), (3.0 / 2, "3:2"),
            (16.0 / 9, "16:9"), (16.0 / 10, "16:10"),
            (3.0 / 4, "3:4"), (2.0 / 3, "2:3"), (9.0 / 16, "9:16"),
        ]
        for (value, label) in presets where abs(aspect - value) <= 0.005 {
            return label
        }
        return String(format: "%.2f:1", aspect)
    }

    // MARK: Codable

    /// Additive reads tolerate an entry written before `frameAspect`,
    /// `createdAt` or `schemaVersion` existed. Pose/projection/name stay
    /// required: a missing projection is never guessed as perspective.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, projection, targetMM, distanceMM
        case azimuthRadians, elevationRadians, fovYDegrees, frameAspect
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projection = try container.decode(CADCameraProjection.self,
                                          forKey: .projection)
        targetMM = try container.decode(SIMD3<Double>.self, forKey: .targetMM)
        distanceMM = try container.decode(Double.self, forKey: .distanceMM)
        azimuthRadians = try container.decode(Double.self, forKey: .azimuthRadians)
        elevationRadians = try container.decode(Double.self, forKey: .elevationRadians)
        fovYDegrees = try container.decode(Double.self, forKey: .fovYDegrees)
        frameAspect = try container.decodeIfPresent(
            Double.self, forKey: .frameAspect) ?? 1
        createdAt = try container.decodeIfPresent(
            Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(projection, forKey: .projection)
        try container.encode(targetMM, forKey: .targetMM)
        try container.encode(distanceMM, forKey: .distanceMM)
        try container.encode(azimuthRadians, forKey: .azimuthRadians)
        try container.encode(elevationRadians, forKey: .elevationRadians)
        try container.encode(fovYDegrees, forKey: .fovYDegrees)
        try container.encode(frameAspect, forKey: .frameAspect)
        try container.encode(createdAt, forKey: .createdAt)
    }

    // MARK: Bounded description

    /// Bounded JSON for `query kind=scene|camera` and assistant state. No
    /// image/mesh bytes; every number is the value the camera actually uses.
    public var summaryJSON: [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "projection": projection.rawValue,
            "target_mm": [targetMM.x, targetMM.y, targetMM.z],
            "distance_mm": distanceMM,
            "azimuth_radians": azimuthRadians,
            "elevation_radians": elevationRadians,
            "fov_y_degrees": fovYDegrees,
            "frame_aspect": frameAspect,
            "frame": frameLabel,
            "created_at": createdAt.timeIntervalSince1970,
        ]
    }

    // MARK: Engineering camera

    /// The same shot as the engineering `TurntableCamera` (millimetres). Used
    /// by real offscreen captures and observation; it never touches the live
    /// viewport camera.
    var turntableCamera: TurntableCamera {
        var camera = TurntableCamera()
        camera.target = SIMD3(Float(targetMM.x), Float(targetMM.y), Float(targetMM.z))
        camera.distance = Float(max(distanceMM, Self.minimumDistanceMM))
        camera.azimuth = Float(azimuthRadians)
        camera.elevation = Float(min(max(elevationRadians,
                                         -Self.maximumElevationRadians),
                                     Self.maximumElevationRadians))
        camera.projection = projection.isOrthographic
            ? .orthographic
            : .perspective(fovY: Float(fovYDegrees) * .pi / 180)
        return camera
    }
}

// MARK: - Scene camera summary

/// Bounded camera state carried by a scene snapshot so `query kind=scene` and
/// the assistant never infer a projection from a render.
nonisolated struct CADSceneCameraSummary: Sendable, Equatable {
    var active: CADSavedCamera?
    var saved: [CADSavedCamera]

    static let empty = CADSceneCameraSummary(active: nil, saved: [])

    var summaryJSON: [String: Any] {
        [
            "count": saved.count,
            "active_id": active?.id.uuidString ?? "",
            "active_name": active?.name ?? "",
            "active_projection": active?.projection.rawValue ?? "",
            "saved": saved.map(\.summaryJSON),
            "note": "Saved views belong to this document. Selecting a view is "
                + "an undoable document edit; orbiting, panning, zooming or "
                + "fitting only changes the live view.",
        ]
    }
}

// MARK: - Scene settings helpers

extension CADSceneSettings {
    /// Valid entries in stored order, duplicate ids removed. Invalid entries
    /// are ignored on read (the package stays openable); the next camera edit
    /// writes only the valid list.
    var cleanSavedCameras: [CADSavedCamera] {
        var seen = Set<UUID>()
        return (savedCameras ?? []).compactMap { entry in
            guard let clean = entry.sanitized,
                  seen.insert(clean.id).inserted else { return nil }
            return clean
        }
    }

    /// The selected camera, or nil when the id no longer resolves.
    var activeSavedCameraEntry: CADSavedCamera? {
        guard let activeCameraID else { return nil }
        return cleanSavedCameras.first { $0.id == activeCameraID }
    }
}

// MARK: - Native presentation conversion

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
extension CADSavedCamera {
    /// The saved shot in RealityKit presentation metres. Framing is preserved:
    /// the orthographic half-height is derived from the same `fovYDegrees`.
    var presentationCamera: CADPresentationCamera {
        CADPresentationCamera(
            target: SIMD3(Float(targetMM.x / 1_000),
                          Float(targetMM.y / 1_000),
                          Float(targetMM.z / 1_000)),
            distance: Float(max(distanceMM / 1_000, 0.002)),
            azimuthRadians: Float(azimuthRadians),
            elevationRadians: Float(elevationRadians),
            fovYDegrees: Float(fovYDegrees),
            projection: projection)
    }

    /// Capture the live Present camera (metres) as document millimetres.
    init(presentationCamera camera: CADPresentationCamera,
         name: String,
         frameAspect: Double,
         id: UUID = UUID(),
         createdAt: Date = Date()) {
        self.init(
            id: id,
            name: name,
            projection: camera.projection,
            targetMM: SIMD3(Double(camera.target.x),
                            Double(camera.target.y),
                            Double(camera.target.z)) * 1_000,
            distanceMM: Double(camera.distance) * 1_000,
            azimuthRadians: Double(camera.azimuthRadians),
            elevationRadians: Double(camera.elevationRadians),
            fovYDegrees: Double(camera.fovYDegrees),
            frameAspect: frameAspect,
            createdAt: createdAt)
    }
}

extension CADPresentationCamera {
    /// Whether the live camera still shows exactly this saved shot. Used to
    /// report a temporary orbit honestly without writing the bookmark.
    func matches(_ saved: CADSavedCamera,
                 targetToleranceMM: Double = 0.05,
                 distanceToleranceFraction: Double = 0.0005,
                 angleToleranceRadians: Double = 1e-4,
                 fovToleranceDegrees: Double = 1e-3) -> Bool {
        guard projection == saved.projection else { return false }
        let liveTargetMM = SIMD3(Double(target.x), Double(target.y),
                                 Double(target.z)) * 1_000
        guard simd_length(liveTargetMM - saved.targetMM) <= targetToleranceMM else {
            return false
        }
        let liveDistanceMM = Double(distance) * 1_000
        let distanceTolerance = max(0.01,
                                    saved.distanceMM * distanceToleranceFraction)
        guard abs(liveDistanceMM - saved.distanceMM) <= distanceTolerance else {
            return false
        }
        guard Self.wrappedAngleDifference(Double(azimuthRadians),
                                          saved.azimuthRadians)
                <= angleToleranceRadians,
              abs(Double(elevationRadians) - saved.elevationRadians)
                <= angleToleranceRadians else { return false }
        return abs(Double(fovYDegrees) - saved.fovYDegrees)
            <= fovToleranceDegrees
    }

    private static func wrappedAngleDifference(_ a: Double, _ b: Double) -> Double {
        var delta = (a - b).truncatingRemainder(dividingBy: .pi * 2)
        if delta > .pi { delta -= .pi * 2 }
        if delta < -.pi { delta += .pi * 2 }
        return abs(delta)
    }
}
#endif

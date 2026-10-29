// SPDX-License-Identifier: MPL-2.0
//
// LegacySceneMigration.swift — FloeCore
//
// Pure, side-effect-free contract for migrating a legacy 3D Director scene
// (`CanvasScene3D` embedded in a `scene3D` canvas node) into a native FloeCAD
// `.floecad` document. The actual package creation and the canvas commit live
// in the app layer (`LegacySceneMigrationService`); everything that decides
// "can this scene be migrated without loss" and everything that identifies the
// exact source bytes lives here so it can be unit-tested on the host and
// shared by the migration service, the canvas routing (T6) and the agent tool
// adapters (T5).
//
// Rules:
//   * A scene is migrated ONLY when every object, camera and lighting value is
//     representable. Any issue aborts BEFORE a package or node is created; the
//     legacy node, its embedded scene and its preview stay intact and the
//     caller shows the reasons. There is no partial-success migration.
//   * `LegacySceneMigrationMarker` is recorded in node metadata on success.
//     The embedded `scene3D` payload remains on the node as the recoverable
//     original; node routing prefers the native binding metadata.
//   * `canonicalDigest` identifies the exact migrated scene bytes; a later
//     mismatch between the marker digest and the embedded scene is a conflict
//     that is surfaced, never silently re-migrated.

import Foundation

/// Why a legacy scene value cannot be represented by a native CAD document.
public enum LegacySceneMigrationIssue: String, Sendable, Codable, Equatable {
    /// An object/camera/light value is NaN or infinite.
    case nonFiniteValue
    /// A scale component is zero or negative (RealityKit would reject it and
    /// the mesh would collapse/invert — the original visual is unrecoverable).
    case nonPositiveScale
    /// A scale component is finite but outside the bounded migration range;
    /// CAD meshes at extreme scales lose precision and cannot be promised.
    case scaleOutOfRange
    /// `colorHex` is not `#RGB` / `#RRGGBB` / `#RRGGBBAA`.
    case invalidColorHex
    /// Camera distance or field of view is non-positive / non-physical.
    case invalidCamera
    /// Light intensity is negative or non-finite.
    case invalidLighting
    /// Two objects share the same UUID; provenance cannot be mapped uniquely.
    case duplicateObjectID
}

/// One precise, user-presentable rejection reason. Stable `objectID`/`field`
/// let callers point at the exact scene value; `message` is a neutral English
/// string the app localizes by `code` in its own catalog.
public struct LegacySceneMigrationReason: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(issue.rawValue):\(objectID?.uuidString ?? "-"):\(field)" }
    public var issue: LegacySceneMigrationIssue
    public var objectID: UUID?
    public var field: String
    public var detail: String

    public init(issue: LegacySceneMigrationIssue, objectID: UUID? = nil,
                field: String, detail: String) {
        self.issue = issue; self.objectID = objectID
        self.field = field; self.detail = detail
    }

    /// Stable machine code for catalog lookup, e.g.
    /// `legacy_scene_migration.nonPositiveScale`.
    public var code: String { "legacy_scene_migration.\(issue.rawValue)" }
}

/// Result of evaluating one scene. `isFullyRepresentable` is the gate.
public struct LegacySceneMigrationEvaluation: Sendable, Equatable {
    public var isFullyRepresentable: Bool
    public var reasons: [LegacySceneMigrationReason]
    public var objectCount: Int
    /// SHA-256 hex of the canonical scene encoding (stable across devices).
    public var canonicalDigest: String

    public init(isFullyRepresentable: Bool, reasons: [LegacySceneMigrationReason],
                objectCount: Int, canonicalDigest: String) {
        self.isFullyRepresentable = isFullyRepresentable
        self.reasons = reasons
        self.objectCount = objectCount
        self.canonicalDigest = canonicalDigest
    }
}

/// The node-metadata marker written when a scene has been migrated. Persisted
/// as JSON under `CADCanvasNodePlanner.MetadataKeys.legacyMigration`.
public struct LegacySceneMigrationMarker: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Canonical digest of the migrated embedded scene.
    public var sceneDigest: String
    public var objectCount: Int
    public var migratedAt: Date

    public init(schemaVersion: Int = LegacySceneMigrationMarker.currentSchemaVersion,
                sceneDigest: String, objectCount: Int, migratedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.sceneDigest = sceneDigest
        self.objectCount = objectCount
        self.migratedAt = migratedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sceneDigest, objectCount, migratedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Markers written before the version field existed are version 1.
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sceneDigest = try values.decode(String.self, forKey: .sceneDigest)
        objectCount = try values.decodeIfPresent(Int.self, forKey: .objectCount) ?? 0
        migratedAt = try values.decodeIfPresent(Date.self, forKey: .migratedAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// What a canvas node currently is with respect to legacy-scene migration.
public enum LegacyNodeMigrationState: Sendable, Equatable {
    /// A legacy `scene3D` node that still carries its embedded scene and has
    /// never been migrated: a first edit may migrate it.
    case legacyUnchanged(CanvasScene3D)
    /// A migrated node with a valid marker matching the embedded scene.
    case migrated(CanvasScene3D, LegacySceneMigrationMarker)
    /// A marker exists but the embedded scene digest differs: the node carries
    /// legacy edits that were never migrated. Never auto-resolved.
    case conflict(embeddedDigest: String, markerDigest: String)
    /// Not a legacy scene node (native CAD file node, or any other kind).
    case notLegacyScene
}

public enum LegacySceneMigration {

    /// Scale is accepted in [minScale, maxScale] per axis. The legacy editor
    /// slider covers 0.05...8; persisted values outside a sane physical range
    /// cannot be promised through the CAD tessellation pipeline.
    public static let minScale: Double = 0.000_1
    public static let maxScale: Double = 10_000

    /// Evaluate whether the scene migrates with no loss. Pure: no I/O.
    public static func evaluate(_ scene: CanvasScene3D) -> LegacySceneMigrationEvaluation {
        var reasons: [LegacySceneMigrationReason] = []
        var seenIDs = Set<UUID>()

        for object in scene.objects {
            if !seenIDs.insert(object.id).inserted {
                reasons.append(.init(issue: .duplicateObjectID, objectID: object.id,
                                     field: "id", detail: "Duplicate object UUID \(object.id.uuidString)."))
            }
            if !(object.position.x.isFinite && object.position.y.isFinite && object.position.z.isFinite) {
                reasons.append(.init(issue: .nonFiniteValue, objectID: object.id,
                                     field: "position", detail: "Object position is not finite."))
            }
            if !(object.rotation.x.isFinite && object.rotation.y.isFinite && object.rotation.z.isFinite) {
                reasons.append(.init(issue: .nonFiniteValue, objectID: object.id,
                                     field: "rotation", detail: "Object rotation is not finite."))
            }
            for (label, value) in [("scale.x", object.scale.x), ("scale.y", object.scale.y), ("scale.z", object.scale.z)] {
                if !value.isFinite {
                    reasons.append(.init(issue: .nonFiniteValue, objectID: object.id,
                                         field: label, detail: "Scale component is not finite."))
                } else if value <= 0 {
                    reasons.append(.init(issue: .nonPositiveScale, objectID: object.id,
                                         field: label, detail: "Scale component must be positive, got \(value)."))
                } else if value < minScale || value > maxScale {
                    reasons.append(.init(issue: .scaleOutOfRange, objectID: object.id,
                                         field: label,
                                         detail: "Scale \(value) is outside [\(minScale), \(maxScale)]."))
                }
            }
            if !object.roughness.isFinite {
                reasons.append(.init(issue: .nonFiniteValue, objectID: object.id,
                                     field: "roughness", detail: "Roughness is not finite."))
            }
            if parseColorHex(object.colorHex) == nil {
                reasons.append(.init(issue: .invalidColorHex, objectID: object.id,
                                     field: "colorHex", detail: "Unparsable color: \(object.colorHex)."))
            }
        }

        let camera = scene.camera
        if !(camera.orbitYaw.isFinite && camera.orbitPitch.isFinite
             && camera.target.x.isFinite && camera.target.y.isFinite && camera.target.z.isFinite
             && camera.fieldOfView.isFinite && camera.distance.isFinite) {
            reasons.append(.init(issue: .invalidCamera, field: "camera",
                                 detail: "A camera value is not finite."))
        } else {
            if !(camera.distance > 0) {
                reasons.append(.init(issue: .invalidCamera, field: "camera.distance",
                                     detail: "Camera distance must be positive, got \(camera.distance)."))
            }
            if !(camera.fieldOfView > 0 && camera.fieldOfView < 170) {
                reasons.append(.init(issue: .invalidCamera, field: "camera.fieldOfView",
                                     detail: "Field of view must be in (0, 170) degrees, got \(camera.fieldOfView)."))
            }
        }

        let lighting = scene.lighting
        if !(lighting.keyIntensity.isFinite && lighting.fillIntensity.isFinite) {
            reasons.append(.init(issue: .nonFiniteValue, field: "lighting",
                                 detail: "A light intensity is not finite."))
        } else if lighting.keyIntensity < 0 || lighting.fillIntensity < 0 {
            reasons.append(.init(issue: .invalidLighting, field: "lighting",
                                 detail: "Light intensity must not be negative."))
        }

        return LegacySceneMigrationEvaluation(
            isFullyRepresentable: reasons.isEmpty,
            reasons: reasons,
            objectCount: scene.objects.count,
            canonicalDigest: canonicalDigest(of: scene))
    }

    /// Stable SHA-256 over the exact scene content: sorted JSON keys,
    /// deterministic dates, no platform-dependent encoding.
    public static func canonicalDigest(of scene: CanvasScene3D) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(scene)) ?? Data()
        return FloeDigest.sha256Hex(data)
    }

    /// Parse `#RGB`, `#RRGGBB` or `#RRGGBBAA` to sRGB components in 0...1.
    /// Mirrors the legacy director's tolerant parser; nil means unparsable.
    /// `#RRGGBBAA` keeps RGB and reports FULL opacity: the legacy renderer
    /// parsed the whole value and used only its low 24 bits (alpha never
    /// displayed), so preserving alpha here would invent transparency the
    /// scene never had.
    public static func parseColorHex(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 {
            let chars = Array(hex)
            hex = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        func byte(_ slice: Substring) -> Double? {
            guard let value = UInt8(slice, radix: 16) else { return nil }
            return Double(value) / 255
        }
        guard let r = byte(hex.prefix(2)),
              let g = byte(hex.dropFirst(2).prefix(2)),
              let b = byte(hex.dropFirst(4).prefix(2)) else { return nil }
        return (r, g, b, 1)
    }
}

public extension CanvasNode {
    /// Classify this node relative to the legacy→native migration. Binding
    /// metadata (a native CAD source path) is honored even on a node that still
    /// carries the embedded original, which is the post-migration state.
    var legacySceneMigrationState: LegacyNodeMigrationState {
        guard let scene = scene3D else { return .notLegacyScene }
        let digest = LegacySceneMigration.canonicalDigest(of: scene)
        if let raw = metadata[CADCanvasNodePlanner.MetadataKeys.legacyMigration],
           let data = raw.data(using: .utf8),
           let marker = try? JSONDecoder().decode(LegacySceneMigrationMarker.self, from: data) {
            return marker.sceneDigest == digest
                ? .migrated(scene, marker)
                : .conflict(embeddedDigest: digest, markerDigest: marker.sceneDigest)
        }
        return .legacyUnchanged(scene)
    }
}

//
//  LegacySceneImport.swift
//  FloeCADKit
//
//  Neutral PUBLIC import boundary for legacy 3D Director scenes.
//
//  The pre-unification Canvas "3D scene" is a lightweight RealityKit
//  composition (five primitives, Euler placement, flat material, camera,
//  two lights, background, grid). This file is the ONE supported way to turn
//  such a scene into a native `.floecad` document: it validates every value
//  first (all-or-nothing — never a partial migration), builds one plain mesh
//  body per object with the EXACT legacy geometry baked (unit metre meshes,
//  non-uniform scale applied to the vertices, Z·Y·X Euler degrees mapped to
//  the body placement quaternion, no invented parametric feature history and
//  no plane extrude), maps colour/roughness/metallic/visibility onto the
//  existing `BodyMaterialSpec`, and persists the scene-level presentation
//  (camera, lighting, background, grid) in the additive `sceneSettings`
//  package column so the workbench opens with the legacy view intact.
//
//  Units: the legacy scene is authored in RealityKit metres; FloeCAD is
//  millimetres. Every length (position, camera distance/target, light
//  positions) and the per-axis scale bake convert ×1000 exactly once, here.
//

import Foundation
import simd
import Euclid

// MARK: - Public input (neutral, FloeCore-independent)

/// A legacy 3D scene, expressed in the native workbench's terms. Metres and
/// degrees in, millimetres handled internally.
public nonisolated struct CADLegacyScene: Sendable, Equatable {
    public nonisolated struct Object: Sendable, Equatable {
        public nonisolated enum Kind: String, Sendable, Codable, CaseIterable {
            case box, sphere, cylinder, cone, plane
        }
        public var id: UUID
        public var name: String
        public var kind: Kind
        /// Metres, Y-up — the legacy entity position (mesh centre).
        public var positionX: Double
        public var positionY: Double
        public var positionZ: Double
        /// Euler degrees applied Z·Y·X (RealityKit `entity.orientation`).
        public var rotationX: Double
        public var rotationY: Double
        public var rotationZ: Double
        /// Non-uniform scale, positive; baked into the mesh vertices.
        public var scaleX: Double
        public var scaleY: Double
        public var scaleZ: Double
        /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
        public var colorHex: String
        /// 0…1 (clamped).
        public var roughness: Double
        public var metallic: Bool
        public var isHidden: Bool

        public init(id: UUID, name: String, kind: Kind,
                    positionX: Double, positionY: Double, positionZ: Double,
                    rotationX: Double, rotationY: Double, rotationZ: Double,
                    scaleX: Double, scaleY: Double, scaleZ: Double,
                    colorHex: String, roughness: Double, metallic: Bool,
                    isHidden: Bool) {
            self.id = id; self.name = name; self.kind = kind
            self.positionX = positionX; self.positionY = positionY; self.positionZ = positionZ
            self.rotationX = rotationX; self.rotationY = rotationY; self.rotationZ = rotationZ
            self.scaleX = scaleX; self.scaleY = scaleY; self.scaleZ = scaleZ
            self.colorHex = colorHex; self.roughness = roughness
            self.metallic = metallic; self.isHidden = isHidden
        }
    }

    public nonisolated struct Camera: Sendable, Equatable {
        /// Degrees; eye = target + d·(cos p·sin y, −sin p, cos p·cos y).
        public var yawDegrees: Double
        public var pitchDegrees: Double
        /// Metres.
        public var distance: Double
        public var targetX: Double
        public var targetY: Double
        public var targetZ: Double
        /// Vertical field of view, degrees.
        public var fieldOfViewDegrees: Double

        public init(yawDegrees: Double, pitchDegrees: Double, distance: Double,
                    targetX: Double, targetY: Double, targetZ: Double,
                    fieldOfViewDegrees: Double) {
            self.yawDegrees = yawDegrees; self.pitchDegrees = pitchDegrees
            self.distance = distance
            self.targetX = targetX; self.targetY = targetY; self.targetZ = targetZ
            self.fieldOfViewDegrees = fieldOfViewDegrees
        }
    }

    public nonisolated struct Lighting: Sendable, Equatable {
        /// RealityKit directional/key intensity (lux-like) — mapped with a
        /// bounded normalisation, never silently dropped.
        public var keyIntensity: Double
        public var fillIntensity: Double
        public var castsShadows: Bool

        public init(keyIntensity: Double, fillIntensity: Double, castsShadows: Bool) {
            self.keyIntensity = keyIntensity; self.fillIntensity = fillIntensity
            self.castsShadows = castsShadows
        }
    }

    public nonisolated enum Background: String, Sendable, Codable, CaseIterable {
        case studio, graphite, midnight, chromaGreen
    }

    public var objects: [Object]
    public var camera: Camera
    public var lighting: Lighting
    public var background: Background
    public var showsGrid: Bool
    /// Canonical digest of the original scene (from FloeCore's
    /// `LegacySceneMigration.canonicalDigest`) and its exact bytes, persisted
    /// as provenance for conflict detection and recovery.
    public var sourceDigest: String
    public var sourceSceneJSON: Data?

    public init(objects: [Object], camera: Camera, lighting: Lighting,
                background: Background, showsGrid: Bool,
                sourceDigest: String, sourceSceneJSON: Data? = nil) {
        self.objects = objects; self.camera = camera; self.lighting = lighting
        self.background = background; self.showsGrid = showsGrid
        self.sourceDigest = sourceDigest; self.sourceSceneJSON = sourceSceneJSON
    }
}

/// Result of a successful import: the created body ids in object order.
public nonisolated struct CADLegacySceneImportResult: Sendable, Equatable {
    public var bodyIDs: [UUID]
    public var settingsWritten: Bool
    /// The knowingly bounded visual differences of this migration, ready for
    /// the caller to disclose (never silently dropped). Also persisted in the
    /// package's scene presentation.
    public var visualApproximations: [CADLegacyVisualApproximation]

    public init(bodyIDs: [UUID], settingsWritten: Bool,
                visualApproximations: [CADLegacyVisualApproximation] = []) {
        self.bodyIDs = bodyIDs
        self.settingsWritten = settingsWritten
        self.visualApproximations = visualApproximations
    }
}

/// A knowingly bounded visual difference between the retired RealityKit
/// presentation and the unified workbench render. Recorded with every migrated
/// scene so the canvas preview / open UI / agent state can show it; the
/// mapping never claims more fidelity than it has.
public nonisolated enum CADLegacyVisualApproximation: String, Sendable, Codable,
                                                       CaseIterable, Equatable {
    /// RealityKit light intensities are photometric (lux-like); the workbench
    /// shading is unitless. The stored intensity scale is normalized against
    /// the legacy defaults (28 000 key / 7 000 fill) and bounded to [0, 4];
    /// relative change is preserved, absolute photometry is not, and the
    /// exact original intensities stay in the retained source JSON.
    case lightingIntensityNormalized
    /// The legacy directional light rendered a real shadow map; the workbench
    /// enables its existing planar ground-shadow pass instead.
    case planarGroundShadow
}

// MARK: - Persisted scene presentation

/// Scene-level presentation persisted in the package's additive
/// `sceneSettings` column. Absent on ordinary CAD documents; older builds
/// ignore the unknown key (they decode the document record without it).
public nonisolated struct CADSceneSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public nonisolated struct Camera: Codable, Equatable, Sendable {
        public var azimuthRadians: Double
        public var elevationRadians: Double
        public var distance: Double
        public var targetX: Double
        public var targetY: Double
        public var targetZ: Double
        public var fovYDegrees: Double
        public var isOrthographic: Bool

        public init(azimuthRadians: Double, elevationRadians: Double, distance: Double,
                    targetX: Double, targetY: Double, targetZ: Double,
                    fovYDegrees: Double, isOrthographic: Bool) {
            self.azimuthRadians = azimuthRadians; self.elevationRadians = elevationRadians
            self.distance = distance
            self.targetX = targetX; self.targetY = targetY; self.targetZ = targetZ
            self.fovYDegrees = fovYDegrees; self.isOrthographic = isOrthographic
        }
    }

    public nonisolated struct Lighting: Codable, Equatable, Sendable {
        public var keyIntensityScale: Double
        public var keyDirectionX: Double
        public var keyDirectionY: Double
        public var keyDirectionZ: Double
        public var fillIntensityScale: Double
        public var fillPositionX: Double
        public var fillPositionY: Double
        public var fillPositionZ: Double
        public var castsShadows: Bool

        public init(keyIntensityScale: Double,
                    keyDirectionX: Double, keyDirectionY: Double, keyDirectionZ: Double,
                    fillIntensityScale: Double,
                    fillPositionX: Double, fillPositionY: Double, fillPositionZ: Double,
                    castsShadows: Bool) {
            self.keyIntensityScale = keyIntensityScale
            self.keyDirectionX = keyDirectionX
            self.keyDirectionY = keyDirectionY
            self.keyDirectionZ = keyDirectionZ
            self.fillIntensityScale = fillIntensityScale
            self.fillPositionX = fillPositionX
            self.fillPositionY = fillPositionY
            self.fillPositionZ = fillPositionZ
            self.castsShadows = castsShadows
        }
    }

    public nonisolated struct Background: Codable, Equatable, Sendable {
        public var topRed: Double; public var topGreen: Double; public var topBlue: Double
        public var bottomRed: Double; public var bottomGreen: Double; public var bottomBlue: Double
        public init(topRed: Double, topGreen: Double, topBlue: Double,
                    bottomRed: Double, bottomGreen: Double, bottomBlue: Double) {
            self.topRed = topRed; self.topGreen = topGreen; self.topBlue = topBlue
            self.bottomRed = bottomRed; self.bottomGreen = bottomGreen; self.bottomBlue = bottomBlue
        }
    }

    /// Provenance of a migrated legacy scene: the exact source digest, the
    /// ordered legacy→body id map (agent tools use it to resolve identities),
    /// the original scene bytes so a recovery/export can reconstruct the
    /// legacy payload without the canvas node, and the bounded visual
    /// approximations the preview/open UI must disclose.
    public nonisolated struct LegacyProvenance: Codable, Equatable, Sendable {
        public var kind: String
        public var sceneDigest: String
        public var objectCount: Int
        public var migratedAt: Date
        public var legacyObjectIDs: [UUID]
        public var bodyIDs: [UUID]
        public var originalSceneJSON: Data?
        /// Absent in a pre-disclosure package (decodes as nil); present for
        /// every migration made by this build.
        public var visualApproximations: [CADLegacyVisualApproximation]?

        public init(kind: String = "legacy-scene-3d",
                    sceneDigest: String, objectCount: Int, migratedAt: Date,
                    legacyObjectIDs: [UUID], bodyIDs: [UUID],
                    originalSceneJSON: Data?,
                    visualApproximations: [CADLegacyVisualApproximation]? = nil) {
            self.kind = kind; self.sceneDigest = sceneDigest
            self.objectCount = objectCount; self.migratedAt = migratedAt
            self.legacyObjectIDs = legacyObjectIDs; self.bodyIDs = bodyIDs
            self.originalSceneJSON = originalSceneJSON
            self.visualApproximations = visualApproximations
        }
    }

    public var schemaVersion: Int
    public var camera: Camera?
    public var lighting: Lighting?
    public var background: Background?
    public var showsGrid: Bool?
    public var legacy: LegacyProvenance?
    /// Environment/light/floor appearance for the shared scene snapshot.
    /// Additive optional: older documents decode with nil and use the default
    /// studio/daylight/dark presets.
    var presentation: CADViewAppearance?

    public init(schemaVersion: Int = CADSceneSettings.currentSchemaVersion,
                camera: Camera? = nil, lighting: Lighting? = nil,
                background: Background? = nil, showsGrid: Bool? = nil,
                legacy: LegacyProvenance? = nil) {
        self.schemaVersion = schemaVersion
        self.camera = camera; self.lighting = lighting
        self.background = background; self.showsGrid = showsGrid; self.legacy = legacy
    }
}

// MARK: - Validation

/// Why a legacy value cannot be represented. Returned BEFORE any mutation.
public nonisolated struct CADLegacySceneImportError: Error, LocalizedError, Sendable, Equatable {
    public var reasons: [String]
    public var errorDescription: String? {
        reasons.isEmpty ? "The legacy scene cannot be imported."
            : "The legacy scene cannot be imported: " + reasons.joined(separator: "; ")
    }
    public init(reasons: [String]) { self.reasons = reasons }
}

nonisolated enum CADLegacySceneValidator {
    /// Full pre-flight validation. Empty result = representable.
    static func validate(_ scene: CADLegacyScene) -> [String] {
        var reasons: [String] = []
        var seen = Set<UUID>()
        for object in scene.objects {
            let label = "\(object.kind.rawValue) \(object.id.uuidString.prefix(8))"
            if !seen.insert(object.id).inserted {
                reasons.append("\(label): duplicate object id")
            }
            let position = [object.positionX, object.positionY, object.positionZ]
            if !position.allSatisfy(\.isFinite) {
                reasons.append("\(label): non-finite position")
            }
            let rotation = [object.rotationX, object.rotationY, object.rotationZ]
            if !rotation.allSatisfy(\.isFinite) {
                reasons.append("\(label): non-finite rotation")
            }
            for (axis, value) in [("x", object.scaleX), ("y", object.scaleY), ("z", object.scaleZ)] {
                if !value.isFinite || value <= 0 {
                    reasons.append("\(label): scale.\(axis) must be finite and positive")
                } else if value < 1e-4 || value > 10_000 {
                    reasons.append("\(label): scale.\(axis)=\(value) is outside the representable range")
                }
            }
            if !object.roughness.isFinite {
                reasons.append("\(label): non-finite roughness")
            }
            if CADLegacySceneColor.parse(object.colorHex) == nil {
                reasons.append("\(label): unparsable color \(object.colorHex)")
            }
        }
        let camera = scene.camera
        if !(camera.yawDegrees.isFinite && camera.pitchDegrees.isFinite
             && camera.distance.isFinite && camera.fieldOfViewDegrees.isFinite
             && camera.targetX.isFinite && camera.targetY.isFinite && camera.targetZ.isFinite) {
            reasons.append("camera: non-finite value")
        } else {
            if !(camera.distance > 0) { reasons.append("camera: distance must be positive") }
            if !(camera.fieldOfViewDegrees > 0 && camera.fieldOfViewDegrees < 170) {
                reasons.append("camera: field of view must be in (0, 170) degrees")
            }
        }
        if !scene.lighting.keyIntensity.isFinite || !scene.lighting.fillIntensity.isFinite {
            reasons.append("lighting: non-finite intensity")
        } else if scene.lighting.keyIntensity < 0 || scene.lighting.fillIntensity < 0 {
            reasons.append("lighting: intensity must not be negative")
        }
        if scene.sourceDigest.isEmpty {
            reasons.append("provenance: missing source digest")
        }
        return reasons
    }
}

// MARK: - Colour

nonisolated enum CADLegacySceneColor {
    /// Parse `#RGB`/`#RRGGBB`/`#RRGGBBAA` to sRGB components (0…1). Mirrors the
    /// legacy parser; `#RRGGBBAA` keeps RGB with FULL opacity because the
    /// legacy renderer never displayed alpha (it used only the low 24 bits).
    static func parse(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
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

    /// sRGB → linear, matching how the renderer consumes `baseColor`
    /// ("linear-ish RGBA") and how RealityKit displayed the authored color.
    static func linear(_ component: Double) -> Double {
        let c = min(max(component, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Mesh building

/// Unit meshes matching the legacy RealityKit primitives exactly (metre
/// scale, centred at the entity origin), then scaled ×1000·scale so the
/// exported body geometry IS the legacy geometry in millimetres.
nonisolated enum CADLegacySceneMesh {
    /// Legacy corner radii of the two `generateBox` primitives, in unit-metre
    /// space (before the entity scale). Box: 2×0.08 of a 1 m edge; plane:
    /// `generateBox(size: (1, 0.04, 1), cornerRadius: 0.02)` where the radius
    /// is exactly half the thickness, so the slab is the fully rounded
    /// "pillow" RealityKit draws (sharp-edge or infinite-plane readings would
    /// both be wrong).
    static let boxCornerRadius = 0.08
    static let planeCornerRadius = 0.02

    /// RealityKit `generateBox(size: 1, cornerRadius: 0.08)` and the plane
    /// slab `generateBox(size: (1, 0.04, 1), cornerRadius: 0.02)` are rounded
    /// cuboids. The rounding is BAKED as real convex mesh geometry
    /// (`RoundedBoxKit`: 6 flat faces + 12 quarter-cylinder edges + 8 octant
    /// spheres, vertices exactly on the analytic surface, exact normals) —
    /// the bevel is never dropped, and no parametric feature history is
    /// invented: the body is a plain mesh, exactly like every other primitive
    /// here. The per-axis entity scale and metres→mm then bake in one
    /// affine step, so the corner radius follows the legacy entity scale
    /// (non-uniformly, exactly as RealityKit rendered it).
    static func mesh(for kind: CADLegacyScene.Object.Kind,
                     scale: SIMD3<Double>) -> Euclid.Mesh {
        let unit: Euclid.Mesh
        switch kind {
        case .box:
            unit = RoundedBoxKit.mesh(
                size: Vector(1, 1, 1), cornerRadius: boxCornerRadius)
        case .sphere:
            unit = .sphere(radius: 0.5, slices: 32, stacks: 24)
        case .cylinder:
            unit = .cylinder(radius: 0.5, height: 1, slices: 48)
        case .cone:
            unit = .cone(radius: 0.5, height: 1, slices: 48)
        case .plane:
            // The legacy plane is a thin slab (1 × 0.04 × 1), NOT an infinite
            // plane and NOT an extruded sketch — no feature history invented.
            unit = RoundedBoxKit.mesh(
                size: Vector(1, 0.04, 1), cornerRadius: planeCornerRadius)
        }
        let mm = 1000.0
        return unit.scaled(by: Vector(scale.x * mm, scale.y * mm, scale.z * mm))
    }

    /// Z·Y·X Euler degrees → quaternion. `simd_quatd` composition
    /// `z * y * x` applies X first, then Y, then Z — the legacy
    /// `zRotation * yRotation * xRotation` order.
    static func quaternion(rotationX: Double, rotationY: Double, rotationZ: Double) -> simd_quatd {
        let deg = Double.pi / 180
        let qx = simd_quatd(angle: rotationX * deg, axis: SIMD3(1, 0, 0))
        let qy = simd_quatd(angle: rotationY * deg, axis: SIMD3(0, 1, 0))
        let qz = simd_quatd(angle: rotationZ * deg, axis: SIMD3(0, 0, 1))
        return simd_normalize(qz * qy * qx)
    }
}

// MARK: - Import

public extension FloeCADDocument {
    /// Import a legacy 3D Director scene into this (normally brand-new)
    /// document. THROWS before any mutation when any value is not
    /// representable — the caller keeps the legacy node and preview intact.
    /// On success the bodies/settings are one undoable transaction; the
    /// caller saves and verifies the package.
    @discardableResult
    @MainActor
    func importLegacyScene(_ scene: CADLegacyScene) throws -> CADLegacySceneImportResult {
        let reasons = CADLegacySceneValidator.validate(scene)
        guard reasons.isEmpty else {
            throw CADLegacySceneImportError(reasons: reasons)
        }

        // Crash-recovery idempotency: the package may already carry this
        // exact scene (saved, but the canvas commit never happened). Return
        // the recorded result without touching the document — never a second
        // set of bodies.
        if let existing = sceneSettings?.legacy,
           existing.sceneDigest == scene.sourceDigest,
           existing.bodyIDs.count == scene.objects.count {
            return CADLegacySceneImportResult(
                bodyIDs: existing.bodyIDs, settingsWritten: true,
                visualApproximations: existing.visualApproximations
                    ?? Self.visualApproximations(for: scene))
        }

        // Bodies preserve the legacy object UUIDs, so a partial/colliding
        // import is refused before any mutation instead of duplicating.
        let existingBodyIDs = Set(session.document.bodies.map(\.id.raw))
        let collisions = scene.objects.map(\.id).filter { existingBodyIDs.contains($0) }
        guard collisions.isEmpty else {
            throw CADLegacySceneImportError(reasons: [
                "The document already contains bodies for \(collisions.count) object(s) of this scene."
            ])
        }

        var document = session.document
        var bodies: [Body] = []
        for object in scene.objects {
            let scale = SIMD3(object.scaleX, object.scaleY, object.scaleZ)
            let mesh = CADLegacySceneMesh.mesh(for: object.kind, scale: scale)
            var transform = Transform3D()
            transform.translation = SIMD3(
                object.positionX * 1000, object.positionY * 1000, object.positionZ * 1000)
            transform.rotation = CADLegacySceneMesh.quaternion(
                rotationX: object.rotationX,
                rotationY: object.rotationY,
                rotationZ: object.rotationZ)
            transform.scale = 1
            var body = Body(
                id: BodyID(raw: object.id),
                name: document.uniqueBodyName(base: object.name.isEmpty
                    ? object.kind.rawValue.capitalized : object.name),
                transform: transform,
                primitive: nil,
                euclidMesh: mesh,
                revision: document.nextRevision())
            body.isHidden = object.isHidden
            let srgb = CADLegacySceneColor.parse(object.colorHex)
                ?? (r: 0.357, g: 0.553, b: 0.937, a: 1)
            body.material = BodyMaterialSpec(
                baseColor: SIMD4(
                    CADLegacySceneColor.linear(srgb.r),
                    CADLegacySceneColor.linear(srgb.g),
                    CADLegacySceneColor.linear(srgb.b),
                    srgb.a),
                metallic: object.metallic ? 1 : 0,
                roughness: min(max(object.roughness, 0), 1),
                baseColorTexture: nil).clamped
            document.bodies.append(body)
            bodies.append(body)
        }

        let settings = Self.sceneSettings(from: scene)
        let settingsData = try JSONEncoder().encode(settings)

        var commands: [DocumentCommand] = bodies.map {
            AddBodyCommand(body: $0, title: "Import \($0.name)")
        }
        commands.append(SetSceneSettingsDataCommand(
            before: session.document.sceneSettingsData,
            after: settingsData))
        session.perform(CompositeCommand(title: "Import Legacy Scene", commands: commands))
        // An already-open workbench picks the new presentation up at once.
        viewModel().reloadSceneSettings()
        return CADLegacySceneImportResult(
            bodyIDs: bodies.map(\.id.raw), settingsWritten: true,
            visualApproximations: Self.visualApproximations(for: scene))
    }

    /// The persisted scene presentation, if this package carries one.
    @MainActor
    var sceneSettings: CADSceneSettings? {
        guard let data = session.document.sceneSettingsData else { return nil }
        return try? JSONDecoder().decode(CADSceneSettings.self, from: data)
    }

    /// Build the persisted presentation from the legacy scene: camera (yaw =
    /// azimuth, elevation = −pitch), key light direction from (3.5, 5, 4)
    /// toward the origin, fill point light at (−3, 2.5, 2) in mm, exact
    /// background colours from the legacy presets, grid visibility and full
    /// provenance.
    static func sceneSettings(from scene: CADLegacyScene) -> CADSceneSettings {
        let camera = CADSceneSettings.Camera(
            azimuthRadians: scene.camera.yawDegrees * .pi / 180,
            elevationRadians: -scene.camera.pitchDegrees * .pi / 180,
            distance: scene.camera.distance * 1000,
            targetX: scene.camera.targetX * 1000,
            targetY: scene.camera.targetY * 1000,
            targetZ: scene.camera.targetZ * 1000,
            fovYDegrees: scene.camera.fieldOfViewDegrees,
            isOrthographic: false)
        // RealityKit's physically-based intensities do not translate 1:1 to
        // this renderer's unitless shading; the scale is NORMALISED against
        // the legacy defaults (28000 key / 7000 fill) so the default scene
        // renders like the legacy default, and user-changed intensities
        // change the render proportionally. Bounded to [0, 4].
        let keyScale = min(max(scene.lighting.keyIntensity / 28_000, 0), 4)
        let fillScale = min(max(scene.lighting.fillIntensity / 7_000, 0), 4)
        let keyDirection = simd_normalize(SIMD3(3.5, 5.0, 4.0))
        let lighting = CADSceneSettings.Lighting(
            keyIntensityScale: keyScale,
            keyDirectionX: keyDirection.x, keyDirectionY: keyDirection.y,
            keyDirectionZ: keyDirection.z,
            fillIntensityScale: fillScale,
            fillPositionX: -3 * 1000, fillPositionY: 2.5 * 1000, fillPositionZ: 2 * 1000,
            castsShadows: scene.lighting.castsShadows)
        let rgb = Self.backgroundRGB(for: scene.background)
        let background = CADSceneSettings.Background(
            topRed: rgb.r, topGreen: rgb.g, topBlue: rgb.b,
            bottomRed: rgb.r, bottomGreen: rgb.g, bottomBlue: rgb.b)
        let legacy = CADSceneSettings.LegacyProvenance(
            sceneDigest: scene.sourceDigest,
            objectCount: scene.objects.count,
            migratedAt: Date(),
            legacyObjectIDs: scene.objects.map(\.id),
            bodyIDs: scene.objects.map(\.id),
            originalSceneJSON: scene.sourceSceneJSON,
            visualApproximations: Self.visualApproximations(for: scene))
        return CADSceneSettings(
            camera: camera, lighting: lighting, background: background,
            showsGrid: scene.showsGrid, legacy: legacy)
    }

    /// The bounded visual differences of this mapping, derived from the scene
    /// itself: intensity normalization always applies; the planar
    /// ground-shadow approximation only when the legacy scene cast shadows.
    static func visualApproximations(
        for scene: CADLegacyScene
    ) -> [CADLegacyVisualApproximation] {
        var approximations: [CADLegacyVisualApproximation] = [.lightingIntensityNormalized]
        if scene.lighting.castsShadows {
            approximations.append(.planarGroundShadow)
        }
        return approximations
    }

    /// Exact legacy `UIColor(sceneBackground:)` values.
    static func backgroundRGB(for background: CADLegacyScene.Background) -> (r: Double, g: Double, b: Double) {
        switch background {
        case .studio: return (0.12, 0.14, 0.18)
        case .graphite: return (0.08, 0.08, 0.08)
        case .midnight: return (0.025, 0.055, 0.12)
        case .chromaGreen: return (0.02, 0.42, 0.17)
        }
    }
}

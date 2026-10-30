//
//  CADAssembly.swift
//  FloeCADKit
//
//  Assembly model for FloeCAD: shared immutable part instances with their own
//  transforms, explicit independent copies, positioning constraints and
//  interference checks. Instances reference document bodies by stable
//  `BodyID`; a "shared" instance never mutates the source body — only its own
//  placement. The persisted contract is JSON in the document package
//  (`assembly.json`-equivalent `project.assemblyData`), separate from the
//  binary B-rep blobs.
//

import Foundation
import simd

/// Rigid placement of an instance: translation + unit quaternion (+ uniform
/// scale, normally 1). Double precision because constraint solves and
/// interference checks run on exact geometry.
public nonisolated struct CADTransform: Codable, Sendable, Equatable {
    public var position: SIMD3<Double>
    /// Quaternion (x, y, z, w).
    public var rotation: SIMD4<Double>
    public var scale: SIMD3<Double>

    public init(position: SIMD3<Double> = .zero,
                rotation: SIMD4<Double> = SIMD4(0, 0, 0, 1),
                scale: SIMD3<Double> = SIMD3(1, 1, 1)) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = CADTransform()
}

/// One placed part in the assembly.
public nonisolated struct CADAssemblyInstance: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// The document body this instance places (the shared part definition).
    public var bodyID: UUID
    public var transform: CADTransform
    public var isHidden: Bool
    /// True when this instance was created as an explicit independent COPY:
    /// it owns a duplicated body rather than referencing the shared one.
    public var isIndependentCopy: Bool
    /// Body created for an independent copy (nil for shared instances).
    public var copiedBodyID: UUID?
    /// `meshRevision` of the placed body at the last solve/refresh, used to
    /// detect a stale source part. Optional so assembly JSON written before
    /// this field existed still decodes; nil reads as "unrecorded".
    /// Revisions are session-scoped (they are re-minted on document load), so
    /// a reopened document legitimately reports every instance stale until the
    /// next `sourceUpdate` apply.
    public var sourceRevision: UInt64?

    public init(id: UUID = UUID(),
                name: String,
                bodyID: UUID,
                transform: CADTransform = .identity,
                isHidden: Bool = false,
                isIndependentCopy: Bool = false,
                copiedBodyID: UUID? = nil,
                sourceRevision: UInt64? = nil) {
        self.id = id
        self.name = name
        self.bodyID = bodyID
        self.transform = transform
        self.isHidden = isHidden
        self.isIndependentCopy = isIndependentCopy
        self.copiedBodyID = copiedBodyID
        self.sourceRevision = sourceRevision
    }
}

public nonisolated enum CADAssemblyConstraintKind: String, Codable, Sendable, CaseIterable {
    /// Instance A is fixed in world space.
    case fixed
    /// A's axis is collinear with B's axis.
    case coaxial
    /// A's reference plane is coplanar (align) with B's plane.
    case planarAlign
    /// Distance between A's reference point and B's reference point.
    case distance
    /// Angle between A's axis and B's axis, degrees.
    case angle
}

/// A positioning constraint. Geometry references are stored in each instance's
/// LOCAL frame (point + direction), so they survive instance moves and replay
/// against the solved placement.
public nonisolated struct CADAssemblyConstraint: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CADAssemblyConstraintKind
    public var instanceA: UUID
    public var instanceB: UUID?
    /// Local-frame reference on A / B (axis point + direction, or plane origin
    /// + normal).
    public var pointA: SIMD3<Double>
    public var directionA: SIMD3<Double>
    public var pointB: SIMD3<Double>?
    public var directionB: SIMD3<Double>?
    /// Distance (mm) or angle (degrees) for the driven kinds.
    public var value: Double?
    public var isSuppressed: Bool
    /// Mesh revision of the placed source body when the reference was picked.
    /// Optional so constraint JSON written before this field existed decodes;
    /// nil reads as "unrecorded" (legacy hand-entered geometry). A mismatch is
    /// reported as a stale reference, never silently re-bound.
    public var sourceRevisionA: UInt64?
    public var sourceRevisionB: UInt64?

    public init(id: UUID = UUID(),
                kind: CADAssemblyConstraintKind,
                instanceA: UUID,
                instanceB: UUID? = nil,
                pointA: SIMD3<Double> = .zero,
                directionA: SIMD3<Double> = SIMD3(0, 0, 1),
                pointB: SIMD3<Double>? = nil,
                directionB: SIMD3<Double>? = nil,
                value: Double? = nil,
                isSuppressed: Bool = false,
                sourceRevisionA: UInt64? = nil,
                sourceRevisionB: UInt64? = nil) {
        self.id = id
        self.kind = kind
        self.instanceA = instanceA
        self.instanceB = instanceB
        self.pointA = pointA
        self.directionA = directionA
        self.pointB = pointB
        self.directionB = directionB
        self.value = value
        self.isSuppressed = isSuppressed
        self.sourceRevisionA = sourceRevisionA
        self.sourceRevisionB = sourceRevisionB
    }
}

// MARK: - Exploded views

/// One instance's override inside an exploded view. A nil direction/distance
/// inherits the view default; the offset itself is still explicit per
/// instance, so a named view never depends on assembly order or viewport
/// state.
public nonisolated struct CADExplodedViewEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var instanceID: UUID
    /// World-space direction; nil = the view's default direction.
    public var direction: SIMD3<Double>?
    /// Offset length in mm; nil = the view's default distance.
    public var distanceMM: Double?

    public init(id: UUID = UUID(), instanceID: UUID,
                direction: SIMD3<Double>? = nil,
                distanceMM: Double? = nil) {
        self.id = id
        self.instanceID = instanceID
        self.direction = direction
        self.distanceMM = distanceMM
    }
}

/// A persisted, named exploded view. It is DISPLAY/DRAWING state only: the
/// view never rewrites `CADAssemblyInstance.transform` or any body geometry.
/// Preview offsets are derived from this value on demand; reset simply stops
/// using them.
public nonisolated struct CADExplodedView: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Unit world-space direction used by entries without their own.
    public var direction: SIMD3<Double>
    /// Default offset length in mm.
    public var distanceMM: Double
    public var entries: [CADExplodedViewEntry]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                direction: SIMD3<Double> = SIMD3(1, 1, 1),
                distanceMM: Double = 40,
                entries: [CADExplodedViewEntry] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.direction = direction
        self.distanceMM = distanceMM
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func entry(for instanceID: UUID) -> CADExplodedViewEntry? {
        entries.first { $0.instanceID == instanceID }
    }

    /// Resolved world-space offset for one instance. Only instances listed in
    /// `entries` are displaced — an unlisted instance stays at its base
    /// placement, which is what makes the per-instance include list honest.
    /// Non-finite/zero input directions resolve to no offset rather than a
    /// NaN placement.
    public func offset(for instanceID: UUID) -> SIMD3<Double> {
        guard let entry = entry(for: instanceID) else { return .zero }
        let rawDirection = entry.direction ?? direction
        let rawDistance = entry.distanceMM ?? distanceMM
        guard rawDistance.isFinite, rawDistance != 0,
              rawDirection.x.isFinite, rawDirection.y.isFinite, rawDirection.z.isFinite else {
            return .zero
        }
        let length = simd_length(rawDirection)
        guard length > 1e-12 else { return .zero }
        return (rawDirection / length) * rawDistance
    }
}

public nonisolated struct CADAssembly: Codable, Sendable, Equatable {
    public static let maxExplodedViews = 32
    public static let maxExplodedEntriesPerView = 128

    public var instances: [CADAssemblyInstance]
    public var constraints: [CADAssemblyConstraint]
    /// Additive persisted exploded views. Missing in older assembly JSON;
    /// the custom decoder below defaults it to empty instead of failing.
    public var explodedViews: [CADExplodedView]

    public init(instances: [CADAssemblyInstance] = [],
                constraints: [CADAssemblyConstraint] = [],
                explodedViews: [CADExplodedView] = []) {
        self.instances = instances
        self.constraints = constraints
        self.explodedViews = explodedViews
    }

    enum CodingKeys: String, CodingKey {
        case instances, constraints, explodedViews
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instances = try container.decodeIfPresent([CADAssemblyInstance].self,
                                                  forKey: .instances) ?? []
        constraints = try container.decodeIfPresent([CADAssemblyConstraint].self,
                                                    forKey: .constraints) ?? []
        explodedViews = try container.decodeIfPresent([CADExplodedView].self,
                                                      forKey: .explodedViews) ?? []
    }

    public static func decode(from data: Data?) throws -> CADAssembly {
        guard let data, !data.isEmpty else { return CADAssembly() }
        return try JSONDecoder().decode(CADAssembly.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func instance(_ id: UUID) -> CADAssemblyInstance? {
        instances.first { $0.id == id }
    }

    public func explodedView(_ id: UUID) -> CADExplodedView? {
        explodedViews.first { $0.id == id }
    }

    /// Base placement with the named view's world offset added. Only the
    /// translation changes; rotation/scale (and every stored transform) stay
    /// untouched. A view whose id is missing yields the base placement.
    public func explodedTransform(for instanceID: UUID,
                                  viewID: UUID?) -> CADTransform? {
        guard let instance = instance(instanceID) else { return nil }
        guard let viewID, let view = explodedView(viewID) else { return instance.transform }
        var transform = instance.transform
        transform.position += view.offset(for: instanceID)
        return transform
    }
}

/// Result of a constraint solve. `invalidReferences` lists constraints whose
/// instance/geometry no longer resolves; `conflicting` lists constraints that
/// cannot be satisfied together (DOF conflict).
public nonisolated struct CADAssemblySolveResult: Sendable, Equatable {
    public var updatedInstances: [CADAssemblyInstance]
    public var invalidReferences: [UUID]
    public var conflicting: [UUID]
    public var solved: Bool

    public init(updatedInstances: [CADAssemblyInstance],
                invalidReferences: [UUID] = [],
                conflicting: [UUID] = [],
                solved: Bool) {
        self.updatedInstances = updatedInstances
        self.invalidReferences = invalidReferences
        self.conflicting = conflicting
        self.solved = solved
    }
}

// MARK: - Placement

extension CADTransform {
    /// The kernel TRS placement of this instance transform (uniform scale),
    /// mirroring `CADAssemblySolver.transform3D(from:)` so the VIEWPORT and the
    /// solver/derived code compute the identical placement. Non-finite or
    /// degenerate rotations fall back to identity rotation rather than
    /// poisoning the render matrix.
    nonisolated func placement3D() -> Transform3D {
        let length = simd_length(rotation)
        let quaternion = length > 1e-12
            ? simd_quatd(ix: rotation.x / length,
                         iy: rotation.y / length,
                         iz: rotation.z / length,
                         r: rotation.w / length)
            : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        return Transform3D(translation: position,
                           rotation: quaternion,
                           scale: scale.x)
    }

    /// True when this transform is finite with positive uniform scale — the
    /// same validity rule the assembly solver applies before placement.
    nonisolated var isPlaceable: Bool {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite, rotation.w.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              scale.x > 0, scale.y > 0, scale.z > 0 else { return false }
        let spread = max(scale.x, max(scale.y, scale.z))
        guard abs(scale.x - scale.y) <= 1e-9 * spread,
              abs(scale.y - scale.z) <= 1e-9 * spread,
              simd_length(rotation) > 1e-12 else { return false }
        return true
    }
}

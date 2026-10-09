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

    public init(id: UUID = UUID(),
                kind: CADAssemblyConstraintKind,
                instanceA: UUID,
                instanceB: UUID? = nil,
                pointA: SIMD3<Double> = .zero,
                directionA: SIMD3<Double> = SIMD3(0, 0, 1),
                pointB: SIMD3<Double>? = nil,
                directionB: SIMD3<Double>? = nil,
                value: Double? = nil,
                isSuppressed: Bool = false) {
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
    }
}

public nonisolated struct CADAssembly: Codable, Sendable, Equatable {
    public var instances: [CADAssemblyInstance]
    public var constraints: [CADAssemblyConstraint]

    public init(instances: [CADAssemblyInstance] = [],
                constraints: [CADAssemblyConstraint] = []) {
        self.instances = instances
        self.constraints = constraints
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

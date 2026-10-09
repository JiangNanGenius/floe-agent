//
//  FeatureRefs.swift
//  openshape3d
//
//  Phase D (Task A0) — persistent identity + references for the parametric
//  feature graph. Every type here is the FROZEN CONTRACT consumed by TopoNaming
//  (A2), the KernelOps push/pull op (A5), FeatureGraph (B1) and DocumentSession
//  (C1), so their exact spellings must not drift.
//
//  All types are `nonisolated`, Codable, Hashable, Sendable: the graph is
//  replayed off the main actor and round-tripped through the SwiftData store as
//  JSON blobs. Model space is Double.
//
//  Nested enums are marked `nonisolated` explicitly — under the module's
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` they do NOT inherit the outer
//  type's isolation (same reasoning as AutoConstraintEngine's nested types).
//
//  BodyID / SketchID / ConstructionPlaneID / SketchPlane / RevolveAxis are
//  existing kernel types (GeometryTypes.swift, SketchPlanes.swift,
//  SketchTypes.swift, KernelOps.swift) — reused, never redefined. Two of them
//  lack conformances the reference enums require; those are bridged at the
//  bottom of this file by hand (synthesis cannot reach across source files).
//

import Foundation
import simd

// MARK: - Identity

/// Stable identity of a feature node; minted once, reused across every rebuild.
nonisolated struct FeatureID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

// MARK: - Body / profile / plane / axis references

/// A body produced by a feature: the producing feature plus the minted body id.
nonisolated struct BodyRef: Codable, Hashable, Sendable {
    var producer: FeatureID
    var bodyID: BodyID
}

/// A closed profile selected inside a sketch: the outer loop entity ids, the
/// entity ids of each hole loop, and an optional interior seed point used to
/// disambiguate which enclosed region was picked.
nonisolated struct ProfileRef: Codable, Hashable, Sendable {
    var sketchID: SketchID
    var entityIDs: [UUID]
    var holeEntityIDs: [[UUID]]
    var seedPoint: SIMD2<Double>?
}

/// The plane a feature is built on.
nonisolated struct PlaneRef: Codable, Hashable, Sendable {
    nonisolated enum Source: Codable, Hashable, Sendable {
        case sketch(SketchID)
        case construction(ConstructionPlaneID)
        case ground
        case explicit(SketchPlane)
    }
    var source: Source
}

/// The axis a revolve/mirror is taken about.
nonisolated struct AxisRef: Codable, Hashable, Sendable {
    nonisolated enum Source: Codable, Hashable, Sendable {
        case sketchLine(SketchID, UUID)
        case explicit(RevolveAxis)
    }
    var source: Source
}

// MARK: - Faces

/// The six faces of a primitive box, in signed-axis order.
nonisolated enum BoxFace: Int, Codable, Sendable {
    case px, nx, py, ny, pz, nz
}

/// What a face *is* relative to the feature that created it. This is the
/// creator-local name; `FaceSignature` is the geometric fingerprint used to
/// re-resolve it after a rebuild.
nonisolated enum FaceRole: Codable, Hashable, Sendable {
    case boxFace(BoxFace)
    case cylinderSide
    case cylinderCap(top: Bool)
    case sphereSurface
    case extrudeStartCap
    case extrudeEndCap
    case extrudeWall(loopIndex: Int, edgeIndex: Int)
    case derived(index: Int)
}

/// Geometric fingerprint of a face, used by `SignatureNaming` to re-find a face
/// after the body is rebuilt (centroid + normal + area, plus a plane offset for
/// planar faces and the radius for cylindrical ones).
nonisolated struct FaceSignature: Codable, Hashable, Sendable {
    nonisolated enum Kind: Codable, Hashable, Sendable {
        case planar
        case cylindrical(radius: Double)
    }
    var kind: Kind
    var normal: SIMD3<Double>
    var centroid: SIMD3<Double>
    var area: Double
    var planeOffset: Double
}

/// A persistent reference to a face on a feature-produced body.
/// Note on `elementName` (docs/TOPO_NAMING_HISTORY_DESIGN.md step 4): an
/// OPTIONAL kernel-history identity layered under the signature. Synthesized
/// Codable decodes optionals with `decodeIfPresent` and omits nil on encode,
/// so documents written before the field exist load unchanged and legacy
/// refs stay byte-identical on disk. Resolution: a name hit wins outright;
/// a name MISS falls back to signature scoring gated by an ambiguity margin;
/// a ref with no name resolves exactly as it always did.
nonisolated struct FaceRef: Codable, Hashable, Sendable {
    var body: BodyRef
    var creator: FeatureID
    var role: FaceRole
    var signature: FaceSignature
    var elementName: ElementName? = nil
}

// MARK: - Edges

/// Geometric fingerprint of a straight edge, used to re-find it after the input
/// body is rebuilt. The STABLE identifier is the pair of adjacent face outward
/// normals (an edge is "the crease between the +Z and +X faces"); midpoint,
/// direction and length break ties between parallel same-face-pair edges. Unlike
/// a `FaceRef`, an edge blend DESTROYS the edge it references, so an `EdgeRef` is
/// always resolved against the feature's INPUT body, never its output.
nonisolated struct EdgeSignature: Codable, Hashable, Sendable {
    var midpoint: SIMD3<Double>
    var direction: SIMD3<Double>
    var length: Double
    var normalA: SIMD3<Double>
    var normalB: SIMD3<Double>
}

/// A persistent reference to a straight edge on a feature-produced body.
///
/// `faceNames` is the kernel-history identity (step 4b): the unordered pair
/// of adjacent-face names — "the crease between the top cap and wall X" —
/// which survives rebuilds exactly as long as its two faces do, where the
/// geometric signature drifts with every edit. Optional and omitted when
/// nil, so old documents load unchanged; replay resolves by identity when
/// EVERY ref of the feature carries one, else falls back to signatures.
nonisolated struct EdgeRef: Codable, Hashable, Sendable {
    var body: BodyRef
    var signature: EdgeSignature
    var faceNames: EdgeName? = nil
}

// MARK: - Expressions & intents

/// A scalar feature parameter. Tranche 1 uses `.value` only; `formula` is
/// reserved for tranche-2 expressions/variables so no schema change is needed.
nonisolated struct Expr: Codable, Hashable, Sendable {
    var value: Double
    var formula: String? = nil
}

/// The boolean decision captured at commit time so replay is deterministic and
/// never re-derived by sample-point auto-detect.
nonisolated struct BooleanIntent: Codable, Hashable, Sendable {
    nonisolated enum Op: Codable, Hashable, Sendable {
        case newBody, union, subtract, intersect
    }
    var op: Op
    var resolvedTargets: [BodyRef]
}

/// Which way a push/pull grows the selected face.
nonisolated enum PushPullMode: Codable, Hashable, Sendable {
    case planarAxial, cylinderRadial
}

// MARK: - Conformance bridges for reused kernel types
//
// `PlaneRef.Source.explicit(SketchPlane)` and `AxisRef.Source.explicit(RevolveAxis)`
// require these existing kernel types to be Hashable / Codable. `SketchPlane`
// (SketchTypes.swift) is already Codable + Equatable — it only needs Hashable.
// `RevolveAxis` (KernelOps.swift) is only Equatable + Sendable — it needs both
// Codable and Hashable. Conformance synthesis cannot cross source files, so
// these are implemented by hand here (both members are SIMD*<Double>, which are
// themselves Codable + Hashable).

nonisolated extension SketchPlane: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(origin)
        hasher.combine(xAxis)
        hasher.combine(yAxis)
    }
}

nonisolated extension RevolveAxis: Codable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case point, direction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            point: try container.decode(SIMD2<Double>.self, forKey: .point),
            direction: try container.decode(SIMD2<Double>.self, forKey: .direction)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(point, forKey: .point)
        try container.encode(direction, forKey: .direction)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(point)
        hasher.combine(direction)
    }
}

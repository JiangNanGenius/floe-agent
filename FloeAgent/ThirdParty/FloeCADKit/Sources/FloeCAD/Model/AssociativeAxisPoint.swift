//
//  AssociativeAxisPoint.swift
//  FloeCAD
//
//  M08 — the persistent value model for associative construction AXES and
//  DATUM POINTS, plus the pure geometric adapters that resolve them.
//
//  This file follows the M07 associative construction-plane contract exactly:
//
//    * a definition is the SOURCE OF TRUTH; the cached world frame on
//      `ConstructionAxis` / `DatumPoint` is only a display cache;
//    * every definition carries an explicit semantic version and stable
//      semantic source identities (named face, edge reference, sketch anchor,
//      construction plane/axis ids) — never a cached world coordinate and
//      never an index or nearest-lookalike rebound;
//    * a PRESENT definition this build cannot read throws from
//      `init(from:)`; it must never decode to nil (which would silently turn
//      an associative datum back into an absolute cached one);
//    * resolution reads the CURRENT source geometry from the frozen writer's
//      snapshot and refuses explicitly when the source is missing, ambiguous,
//      suppressed, rolled back, forward or degenerate.
//
//  No dependency walker, feature-graph replay, named-face lookup or resolved
//  cache lives here: `AssociativeGeometryResolver` owns those and calls these
//  pure adapters. Storage is the existing per-row blob (`ConstructionAxis`)
//  and the additive `datumPoints` record list, so undo, save/reopen, merge and
//  named versions keep working without a second store.
//

import Foundation
import simd

// MARK: - Errors

/// A value-level reason an associative axis or datum point cannot be decoded
/// or resolved. The unsupported-kind/version cases are DECODE failures and
/// must open the document opaque/read-only with its original bytes; the
/// remaining cases are resolution failures reported as a broken reference.
nonisolated enum AssociativeAxisPointError: Error, LocalizedError, Equatable, Sendable {
    /// A definition payload names a kind this build does not implement.
    case unsupportedDefinitionKind(String)
    /// A definition payload has a semantic version this build cannot read.
    case unsupportedSemanticVersion(Int)
    /// The payload's own fields contradict each other or its kind's shape.
    case invalidDefinitionShape(String)
    /// A numeric input was NaN or infinite.
    case nonFiniteValue(String)
    /// A direction could not be normalized into a usable axis.
    case degenerateDirection(String)
    /// A frozen reference direction collapsed against the current geometry.
    case degenerateReference(String)
    /// Two points meant to define an axis/point coincided.
    case coincidentPoints(String)
    /// Two planes meant to define an intersection line are parallel/coincident,
    /// or an axis has no unique intersection with a plane.
    case parallelSources(String)
    /// The definition's own `source.body.bodyID` and frozen `sourceVersion`
    /// name different bodies.
    case sourceVersionBodyMismatch(source: BodyID, version: BodyID)
    /// The caller resolved a face/edge on a different body than the frozen one.
    case sourceBodyMismatch(expected: BodyID, actual: BodyID)
    /// A stored attachment frame is not a finite orthonormal right-handed
    /// basis, or carries state this kind does not own.
    case invalidAttachmentFrame(String)
    /// The snapshot body transform is not a positive finite similarity
    /// transform.
    case invalidBodyTransform(String)
    /// A construction axis does not lie in the plane a revolve consumes; the
    /// kernel's revolve axis is 2D in that plane, so a projection would be an
    /// invented line. Refused, never approximated.
    case axisNotInPlane(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedDefinitionKind(kind):
            return "Unsupported construction axis or datum point definition kind '\(kind)'."
        case let .unsupportedSemanticVersion(version):
            return "Unsupported associative datum definition version \(version)."
        case let .invalidDefinitionShape(reason):
            return "Invalid associative datum definition: \(reason)."
        case let .nonFiniteValue(label):
            return "\(label) is not finite."
        case let .degenerateDirection(reason):
            return "Cannot derive a stable axis direction: \(reason)."
        case let .degenerateReference(reason):
            return "Cannot derive a stable reference direction: \(reason)."
        case let .coincidentPoints(reason):
            return "Cannot derive geometry from coincident points: \(reason)."
        case let .parallelSources(reason):
            return "The sources do not meet in a unique line or point: \(reason)."
        case let .sourceVersionBodyMismatch(source, version):
            return "The definition names source body \(source.raw.uuidString) "
                + "but freezes geometry for body \(version.raw.uuidString)."
        case let .sourceBodyMismatch(expected, actual):
            return "The resolved source belongs to body \(actual.raw.uuidString), "
                + "but the definition is frozen to body \(expected.raw.uuidString)."
        case let .invalidAttachmentFrame(reason):
            return "Invalid datum attachment frame: \(reason)."
        case let .invalidBodyTransform(reason):
            return "Invalid body transform: \(reason)."
        case let .axisNotInPlane(reason):
            return "The construction axis does not lie in the revolve plane: \(reason)."
        }
    }

    /// True only for a PRESENT definition written to a newer/other semantic
    /// contract. The load boundary must catch this case, keep the original row
    /// bytes, and open the document opaque and read-only; it is not a
    /// broken-reference case that may fall back to the cached frame.
    var requiresOpaqueReadOnlyDocument: Bool {
        switch self {
        case .unsupportedDefinitionKind, .unsupportedSemanticVersion:
            return true
        default:
            return false
        }
    }
}

// MARK: - Stable references

/// A persisted reference to a document construction axis.
///
/// Storing the identity — never the resolved line — is what lets a consumer
/// (a circular pattern) follow its axis after a source edit and after reopen.
/// The axis is resolved through the document's own resolver during replay.
nonisolated struct ConstructionAxisRef: Codable, Hashable, Sendable {
    var axisID: ConstructionAxisID

    init(_ axisID: ConstructionAxisID) {
        self.axisID = axisID
    }
}

/// One of the two point sources a two-point axis / midpoint may name.
///
/// A sketch anchor is the solver's own semantic point identity; a datum point
/// is another persisted associative point. There is deliberately no
/// "nearest point" or coordinate variant, so a replaced identity is a broken
/// reference instead of a silent rebind.
nonisolated enum DatumPointSource: Codable, Hashable, Sendable {
    case sketchAnchor(SketchAnchorRef)
    case datumPoint(DatumPointID)

    var diagnosticKey: String {
        switch self {
        case let .sketchAnchor(anchor): return "anchor:" + anchor.key
        case let .datumPoint(id): return "point:" + id.raw.uuidString
        }
    }
}

// MARK: - Current source geometry

/// The current geometry of an axis SOURCE, in the source body's LOCAL space.
/// The resolver builds this from the frozen writer's snapshot; this file never
/// performs naming, lookup or replay itself.
nonisolated struct SourceAxisGeometry: Equatable, Sendable {
    var bodyID: BodyID
    /// A point ON the source axis (edge midpoint / face centroid).
    var origin: SIMD3<Double>
    /// Source direction. Need not be exactly unit; resolution normalizes once.
    var direction: SIMD3<Double>
    /// Body-local display extent of the source (edge length / face size).
    var extent: Double

    init(bodyID: BodyID, origin: SIMD3<Double>, direction: SIMD3<Double>, extent: Double) {
        self.bodyID = bodyID
        self.origin = origin
        self.direction = direction
        self.extent = extent
    }

    /// A straight edge as an axis source: the drawn/revolved axis is the edge
    /// line, so the origin is its midpoint and the extent its length.
    static func alongEdge(bodyID: BodyID, start: SIMD3<Double>, end: SIMD3<Double>)
        -> SourceAxisGeometry {
        SourceAxisGeometry(bodyID: bodyID, origin: (start + end) / 2,
                           direction: end - start, extent: simd_length(end - start))
    }
}

/// The current geometry of a CYLINDRICAL face source, in the source body's
/// LOCAL space.
///
/// `axisPoint` is the cylinder's OWN analytic axis placement point read from
/// the exact kernel face — NOT the face centroid, a bounding-box centre or a
/// projected guess. An axis point assembled those ways is off the true line
/// whenever the face is a partial cylinder, and it is precisely the value a
/// revolve/pattern would then spin about. `centroid` is kept separately (and
/// only) to choose a display anchor on that same exact line, which cannot
/// change the line; `radius` and `extent` size the display.
nonisolated struct SourceCylinderGeometry: Equatable, Sendable {
    var bodyID: BodyID
    var centroid: SIMD3<Double>
    /// A point ON the cylinder's analytic axis, from the kernel face.
    var axisPoint: SIMD3<Double>
    /// Analytic axis direction (need not be exactly unit).
    var axisDirection: SIMD3<Double>
    /// Analytic radius in body-local mm.
    var radius: Double
    /// Body-local axial extent available for a drawn line (mm, > 0).
    var extent: Double

    init(
        bodyID: BodyID,
        centroid: SIMD3<Double>,
        axisPoint: SIMD3<Double>,
        axisDirection: SIMD3<Double>,
        radius: Double,
        extent: Double
    ) {
        self.bodyID = bodyID
        self.centroid = centroid
        self.axisPoint = axisPoint
        self.axisDirection = axisDirection
        self.radius = radius
        self.extent = extent
    }
}

/// A resolved world-space construction axis.
///
/// `origin` is a point on the line, `direction` is UNIT and `extent` only
/// sizes the drawn segment — it never affects the math (the same contract as
/// `ConstructionAxis.length`). Consumers use `origin`/`direction` directly.
nonisolated struct ResolvedAxisGeometry: Codable, Equatable, Sendable {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>
    var extent: Double

    init(origin: SIMD3<Double>, direction: SIMD3<Double>, extent: Double) {
        self.origin = origin
        self.direction = direction
        self.extent = extent
    }
}

/// A resolved world-space datum point.
nonisolated struct ResolvedDatumPointGeometry: Codable, Equatable, Sendable {
    var position: SIMD3<Double>

    init(position: SIMD3<Double>) {
        self.position = position
    }
}

// MARK: - Expression slots

/// One formula-capable scalar owned by an axis or datum-point definition.
nonisolated struct AssociativeDatumExpressionSlot: Equatable, Sendable {
    var name: String
    /// Public authoring unit: `mm` for every offset this build supports.
    var unit: String
    var expr: Expr
}

// MARK: - Face axis

/// A construction axis from one exact named PLANAR face: the face's outward
/// normal through a point on the face.
///
/// `attachment` freezes the face's in-plane frame exactly like an M07 offset
/// plane, so a body rotation carries the axis and a re-orientation of the face
/// re-derives it. `offset` moves the axis WITHIN the face along the frozen
/// in-plane x axis, in world millimetres — a normal axis displaced across its
/// own face, which is what an offset datum axis means for a revolve or a
/// circular pattern.
///
/// Cylindrical faces are deliberately NOT accepted HERE: a cylinder has no
/// single normal-through-a-point line, so it has its own `CylinderAxisDefinition`
/// (which reads the face's analytic axis point from the exact kernel query).
/// This kind stays planar-only; resolution still refuses a face that is not a
/// planar kernel face.
nonisolated struct FaceAxisDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: FaceRef
    let sourceVersion: GeometryVersionRef
    /// Frozen in-plane frame of the source face. Its `anchorOffset` is unused
    /// (and must be zero): the editable displacement is `offset`.
    let attachment: PlaneAttachmentFrame
    /// World millimetres along the resolved in-plane x axis.
    var offset: Expr

    init(
        version: Int = FaceAxisDefinition.supportedVersion,
        source: FaceRef,
        sourceVersion: GeometryVersionRef,
        attachment: PlaneAttachmentFrame,
        offset: Expr
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
        self.attachment = attachment
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion, attachment, offset
    }

    /// Decode the semantic version FIRST so a future payload is reported as an
    /// unsupported version even when its other fields no longer match.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(FaceRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        attachment = try container.decode(PlaneAttachmentFrame.self, forKey: .attachment)
        offset = try container.decode(Expr.self, forKey: .offset)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard offset.value.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue("axis offset")
        }
        try attachment.validate()
        guard abs(attachment.anchorOffset.x) <= 1e-9,
              abs(attachment.anchorOffset.y) <= 1e-9 else {
            throw AssociativeAxisPointError.invalidAttachmentFrame(
                "a face axis owns its displacement in `offset`, not in the frame")
        }
    }

    /// The current axis: the face's normal through its current anchor, moved
    /// `offset` world millimetres along the frozen in-plane x axis.
    func resolvedAxis(
        face: SourceFaceGeometry,
        bodyTransform: Transform3D,
        extent: Double
    ) throws -> ResolvedAxisGeometry {
        try validate()
        guard face.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceBodyMismatch(
                expected: sourceVersion.bodyID, actual: face.bodyID)
        }
        guard extent.isFinite, extent > 0 else {
            throw AssociativeAxisPointError.nonFiniteValue("axis display extent")
        }
        let frame = try attachment.resolvedPlane(
            face: face, bodyTransform: bodyTransform, offsetMM: 0)
        let origin = frame.origin + frame.xAxis * offset.value
        try AxisPointMath.requireFinite(origin, "resolved axis origin")
        return ResolvedAxisGeometry(origin: origin, direction: frame.normal, extent: extent)
    }
}

// MARK: - Edge axis

/// A construction axis along one persisted straight edge.
///
/// `source` reuses the document's existing `EdgeRef` identity/signature
/// contract (M26 owns how an edge is re-found). `reference` is a frozen
/// body-local direction used only to choose the perpendicular offset
/// direction: resolution projects it into the CURRENT perpendicular plane and
/// normalizes it, or refuses when it collapsed. `offset` moves the axis
/// perpendicular to the edge in world millimetres.
nonisolated struct EdgeAxisDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: EdgeRef
    let sourceVersion: GeometryVersionRef
    /// Body-local direction used to choose the offset's perpendicular.
    let reference: SIMD3<Double>
    /// World millimetres along the resolved perpendicular.
    var offset: Expr

    init(
        version: Int = EdgeAxisDefinition.supportedVersion,
        source: EdgeRef,
        sourceVersion: GeometryVersionRef,
        reference: SIMD3<Double>,
        offset: Expr
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
        self.reference = reference
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion, reference, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(EdgeRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        reference = try container.decode(SIMD3<Double>.self, forKey: .reference)
        offset = try container.decode(Expr.self, forKey: .offset)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard offset.value.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue("axis offset")
        }
        try AxisPointMath.requireFinite(reference, "edge axis reference")
        guard simd_length(reference) > 1e-6 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "the edge axis reference direction has no length")
        }
    }

    /// The current axis: the edge line, moved `offset` world millimetres in the
    /// projected frozen reference direction. The body's own scale is applied
    /// exactly once, to the body-local edge, never again to the offset.
    func resolvedAxis(
        edge: SourceAxisGeometry,
        bodyTransform: Transform3D,
        scale: Double
    ) throws -> ResolvedAxisGeometry {
        try validate()
        guard edge.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceBodyMismatch(
                expected: sourceVersion.bodyID, actual: edge.bodyID)
        }
        try AxisPointMath.validate(bodyTransform)
        let localDirection = try AxisPointMath.unit(edge.direction, "edge direction")
        let projected = reference - localDirection * simd_dot(reference, localDirection)
        guard simd_length(projected) > 1e-6 else {
            throw AssociativeAxisPointError.degenerateReference(
                "the frozen reference direction is parallel to the current edge")
        }
        let localPerpendicular = simd_normalize(projected)
        let worldDirection = simd_normalize(bodyTransform.rotation.act(localDirection))
        let worldPerpendicular = simd_normalize(bodyTransform.rotation.act(localPerpendicular))
        let worldOrigin = bodyTransform.applying(to: edge.origin) + worldPerpendicular * offset.value
        try AxisPointMath.requireFinite(worldOrigin, "resolved axis origin")
        let display = max(edge.extent * scale, 1e-6)
        return ResolvedAxisGeometry(origin: worldOrigin, direction: worldDirection, extent: display)
    }
}

// MARK: - Cylinder axis

/// A construction axis along one exact named CYLINDRICAL face: the face's
/// analytic cylinder axis.
///
/// Unlike `FaceAxisDefinition` (a planar face's normal through an anchored
/// point), a cylinder has no single "normal through the centroid" line: its
/// axis is the analytic line the surface is generated around. Resolution reads
/// that line's OWN placement point plus its direction from the frozen writer's
/// exact kernel face, so a partial cylinder, a moved body and a re-created
/// cylinder all resolve to the true centre line rather than a centroid guess.
///
/// It deliberately has no offset: a cylinder is rotationally symmetric, so a
/// perpendicular displacement has no source-defined direction and would be an
/// arbitrary line dressed up as an edit. `length` is still the display size,
/// and the source can be reselected like every other kind.
nonisolated struct CylinderAxisDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: FaceRef
    let sourceVersion: GeometryVersionRef

    init(
        version: Int = CylinderAxisDefinition.supportedVersion,
        source: FaceRef,
        sourceVersion: GeometryVersionRef
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion
    }

    /// The semantic version is decoded FIRST so a future payload is reported
    /// as an unsupported version even when its other fields changed shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(FaceRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
    }

    /// The current axis: the analytic cylinder line.
    ///
    /// The returned origin is the EXACT axis point slid along the SAME line to
    /// sit beside the current face centroid — the line is unchanged, only the
    /// drawn anchor moves. A body rotation carries both, and the scale is
    /// applied once to the body-local line.
    func resolvedAxis(
        cylinder: SourceCylinderGeometry,
        bodyTransform: Transform3D,
        scale: Double
    ) throws -> ResolvedAxisGeometry {
        try validate()
        guard cylinder.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceBodyMismatch(
                expected: sourceVersion.bodyID, actual: cylinder.bodyID)
        }
        guard cylinder.radius.isFinite, cylinder.radius > 0 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "the resolved cylinder radius is not positive")
        }
        try AxisPointMath.validate(bodyTransform)
        try AxisPointMath.requireFinite(cylinder.axisPoint, "cylinder axis point")
        try AxisPointMath.requireFinite(cylinder.centroid, "cylinder face centroid")
        let localDirection = try AxisPointMath.unit(cylinder.axisDirection, "cylinder axis direction")

        // Display anchor: the exact axis point translated ALONG the exact
        // axis direction to the plane through the current face centroid. A
        // translation along the line leaves the line identical.
        let along = simd_dot(cylinder.centroid - cylinder.axisPoint, localDirection)
        let localAnchor = cylinder.axisPoint + localDirection * along
        let worldDirection = simd_normalize(bodyTransform.rotation.act(localDirection))
        let worldOrigin = bodyTransform.applying(to: localAnchor)
        try AxisPointMath.requireFinite(worldOrigin, "resolved axis origin")
        let display = max(cylinder.extent * scale, 1e-6)
        return ResolvedAxisGeometry(origin: worldOrigin, direction: worldDirection, extent: display)
    }
}

// MARK: - Two-point axis

/// A construction axis through two persisted point identities.
///
/// The points are semantic identities (solver anchors or datum points), never
/// world coordinates: a parent edit moves the axis, and a deleted/replaced
/// identity is a broken reference. Creation order is geometry order: the first
/// point is the origin, the direction points from it to the second.
nonisolated struct TwoPointAxisDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let points: [DatumPointSource]

    init(
        version: Int = TwoPointAxisDefinition.supportedVersion,
        points: [DatumPointSource]
    ) {
        self.version = version
        self.points = points
    }

    private enum CodingKeys: String, CodingKey {
        case version, points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        points = try container.decode([DatumPointSource].self, forKey: .points)
        try TwoPointAxisDefinition.validate(points: points)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        try Self.validate(points: points)
    }

    private static func validate(points: [DatumPointSource]) throws {
        guard points.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a two-point axis must carry exactly two points")
        }
        guard Set(points.map(\.diagnosticKey)).count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a two-point axis must name two distinct points")
        }
    }

    /// Deterministic in argument order: origin = first, direction toward the
    /// second. Coincident points refuse instead of fitting a direction.
    static func resolvedAxis(
        first: SIMD3<Double>,
        second: SIMD3<Double>
    ) throws -> ResolvedAxisGeometry {
        try AxisPointMath.requireFinite(first, "first point")
        try AxisPointMath.requireFinite(second, "second point")
        let delta = second - first
        let length = simd_length(delta)
        guard length.isFinite, length > 1e-9 else {
            throw AssociativeAxisPointError.coincidentPoints(
                "the two axis points coincide")
        }
        return ResolvedAxisGeometry(
            origin: first, direction: delta / length, extent: length)
    }

    func resolvedAxis(worldPoints: [SIMD3<Double>]) throws -> ResolvedAxisGeometry {
        try validate()
        guard worldPoints.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "two resolved points are required")
        }
        return try Self.resolvedAxis(first: worldPoints[0], second: worldPoints[1])
    }
}

// MARK: - Two-plane axis

/// A construction axis from the intersection of two associative construction
/// planes (M07 definitions included). Resolution reads each plane's CURRENT
/// resolved frame; parallel/coincident planes refuse instead of picking an
/// arbitrary line.
nonisolated struct TwoPlaneAxisDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let planes: [ConstructionPlaneID]

    init(
        version: Int = TwoPlaneAxisDefinition.supportedVersion,
        planes: [ConstructionPlaneID]
    ) {
        self.version = version
        self.planes = planes
    }

    private enum CodingKeys: String, CodingKey {
        case version, planes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        planes = try container.decode([ConstructionPlaneID].self, forKey: .planes)
        try TwoPlaneAxisDefinition.validate(planes: planes)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        try Self.validate(planes: planes)
    }

    private static func validate(planes: [ConstructionPlaneID]) throws {
        guard planes.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a two-plane axis must carry exactly two planes")
        }
        guard Set(planes.map(\.raw)).count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a two-plane axis must name two distinct planes")
        }
    }

    /// Intersect two resolved world planes. `sizes` only sizes the drawn axis.
    static func resolvedAxis(
        first: SketchPlane,
        second: SketchPlane,
        sizes: (first: Double, second: Double)
    ) throws -> ResolvedAxisGeometry {
        // The pure intersection math already exists in the construction-axis
        // kit; this adapter only turns its optional into an explicit refusal so
        // a parallel or coincident pair is reported instead of guessed.
        guard let axis = ConstructionAxisKit.intersection(
            planeAOrigin: first.origin, planeANormal: first.normal,
            planeBOrigin: second.origin, planeBNormal: second.normal)
        else {
            throw AssociativeAxisPointError.parallelSources(
                "the two planes are parallel or coincident")
        }
        let display = max(min(sizes.first, sizes.second), 1e-6)
        return ResolvedAxisGeometry(origin: axis.origin, direction: axis.direction,
                                    extent: display)
    }

    func resolvedAxis(planes resolved: [SketchPlane], sizes: [Double]) throws -> ResolvedAxisGeometry {
        try validate()
        guard resolved.count == 2, sizes.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "two resolved planes are required")
        }
        return try Self.resolvedAxis(first: resolved[0], second: resolved[1],
                                     sizes: (sizes[0], sizes[1]))
    }
}

// MARK: - Axis definition

/// The persistent construction-axis definition. Each case carries its own
/// explicit semantic version; a present definition never falls back to the
/// cached absolute line when it cannot be read or resolved.
nonisolated enum ConstructionAxisDefinition: Codable, Equatable, Sendable {
    case face(FaceAxisDefinition)
    case edge(EdgeAxisDefinition)
    /// M08 R2: an exact named cylindrical face's analytic axis.
    case cylinder(CylinderAxisDefinition)
    case twoPoints(TwoPointAxisDefinition)
    case twoPlanes(TwoPlaneAxisDefinition)

    nonisolated enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case face
        case edge
        case cylinder
        case twoPoints
        case twoPlanes
    }

    var kind: Kind {
        switch self {
        case .face: return .face
        case .edge: return .edge
        case .cylinder: return .cylinder
        case .twoPoints: return .twoPoints
        case .twoPlanes: return .twoPlanes
        }
    }

    /// The payload's semantic version, e.g. for a dependency fingerprint.
    var semanticVersion: Int {
        switch self {
        case let .face(definition): return definition.version
        case let .edge(definition): return definition.version
        case let .cylinder(definition): return definition.version
        case let .twoPoints(definition): return definition.version
        case let .twoPlanes(definition): return definition.version
        }
    }

    /// The semantic version this build can read for this kind.
    var supportedSemanticVersion: Int {
        switch self {
        case .face: return FaceAxisDefinition.supportedVersion
        case .edge: return EdgeAxisDefinition.supportedVersion
        case .cylinder: return CylinderAxisDefinition.supportedVersion
        case .twoPoints: return TwoPointAxisDefinition.supportedVersion
        case .twoPlanes: return TwoPlaneAxisDefinition.supportedVersion
        }
    }

    var isSupportedSemanticVersion: Bool {
        semanticVersion == supportedSemanticVersion
    }

    /// The frozen body version a face/edge source resolves against, if any.
    var writerVersion: GeometryVersionRef? {
        switch self {
        case let .face(definition): return definition.sourceVersion
        case let .edge(definition): return definition.sourceVersion
        case let .cylinder(definition): return definition.sourceVersion
        case .twoPoints, .twoPlanes: return nil
        }
    }

    /// Formula-capable scalars in their public authoring units. Two-point and
    /// two-plane axes follow geometry only.
    var expressionSlots: [AssociativeDatumExpressionSlot] {
        switch self {
        case let .face(definition):
            return [AssociativeDatumExpressionSlot(
                name: "offset", unit: "mm", expr: definition.offset)]
        case let .edge(definition):
            return [AssociativeDatumExpressionSlot(
                name: "offset", unit: "mm", expr: definition.offset)]
        case .twoPoints, .twoPlanes, .cylinder:
            return []
        }
    }

    /// Return a copy with one named expression replaced, or nil when this kind
    /// has no such slot.
    func settingExpression(named name: String, to expr: Expr) -> ConstructionAxisDefinition? {
        switch self {
        case var .face(definition) where name == "offset":
            definition.offset = expr
            return .face(definition)
        case var .edge(definition) where name == "offset":
            definition.offset = expr
            return .edge(definition)
        default:
            return nil
        }
    }

    /// Re-evaluate every formula against `variables`, updating only changed
    /// `.value` caches. A missing/non-finite formula leaves the definition
    /// untouched so the resolver reports it.
    func reevaluated(with variables: [String: Double]) -> ConstructionAxisDefinition? {
        var changed = false
        var result = self
        for slot in expressionSlots {
            guard let formula = slot.expr.formula,
                  let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                  value.isFinite, value != slot.expr.value else { continue }
            var expr = slot.expr
            expr.value = value
            guard let updated = result.settingExpression(named: slot.name, to: expr) else { continue }
            result = updated
            changed = true
        }
        return changed ? result : nil
    }

    /// Rewrite formula text in every expression slot (variable rename).
    func rewritingFormulas(_ transform: (String) -> String?) -> ConstructionAxisDefinition? {
        var changed = false
        var result = self
        for slot in expressionSlots {
            guard let formula = slot.expr.formula,
                  let rewritten = transform(formula), rewritten != formula else { continue }
            var expr = slot.expr
            expr.formula = rewritten
            guard let updated = result.settingExpression(named: slot.name, to: expr) else { continue }
            result = updated
            changed = true
        }
        return changed ? result : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, face, edge, cylinder, twoPoints, twoPlanes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.face.rawValue:
            self = .face(try container.decode(FaceAxisDefinition.self, forKey: .face))
        case Kind.edge.rawValue:
            self = .edge(try container.decode(EdgeAxisDefinition.self, forKey: .edge))
        case Kind.cylinder.rawValue:
            self = .cylinder(try container.decode(CylinderAxisDefinition.self, forKey: .cylinder))
        case Kind.twoPoints.rawValue:
            self = .twoPoints(try container.decode(TwoPointAxisDefinition.self, forKey: .twoPoints))
        case Kind.twoPlanes.rawValue:
            self = .twoPlanes(try container.decode(TwoPlaneAxisDefinition.self, forKey: .twoPlanes))
        default:
            throw AssociativeAxisPointError.unsupportedDefinitionKind(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .face(definition):
            try container.encode(Kind.face, forKey: .kind)
            try container.encode(definition, forKey: .face)
        case let .edge(definition):
            try container.encode(Kind.edge, forKey: .kind)
            try container.encode(definition, forKey: .edge)
        case let .cylinder(definition):
            try container.encode(Kind.cylinder, forKey: .kind)
            try container.encode(definition, forKey: .cylinder)
        case let .twoPoints(definition):
            try container.encode(Kind.twoPoints, forKey: .kind)
            try container.encode(definition, forKey: .twoPoints)
        case let .twoPlanes(definition):
            try container.encode(Kind.twoPlanes, forKey: .kind)
            try container.encode(definition, forKey: .twoPlanes)
        }
    }
}

// MARK: - Revolve consumer adapter

/// Conversion and validation between a resolved world construction-axis line
/// and the 2D `RevolveAxis` the existing revolve kernel consumes.
///
/// `KernelOps.revolve` and `OCCTKernel.revolveSolid` both take an axis IN the
/// sketch plane and lift it through the plane's own basis. A construction axis
/// that is not in that plane has no exact 2D equivalent, so this adapter
/// refuses explicitly instead of projecting the line — a projection would
/// silently revolve about a different axis, which is exactly the kind of
/// invented engine this contract forbids.
nonisolated enum RevolveAxisBinding {
    /// Maximum distance (mm) the line may sit off the plane for the axis to
    /// count as coplanar. Exact constructions resolve at round-off; the
    /// tolerance only absorbs that, never a design displacement.
    static func planeTolerance(extent: Double) -> Double {
        let scaled = abs(extent) * 1e-9
        return max(1e-6, scaled.isFinite ? scaled : 1e-6)
    }

    /// The angle tolerance: a line whose unit direction is within this |cos|
    /// of the plane normal is not in the plane.
    static var directionTolerance: Double { 1e-6 }

    /// Project the resolved line into `plane`, or throw `.axisNotInPlane`.
    ///
    /// The returned point/direction are in the plane's own (u, v) coordinates,
    /// the exact units `RevolveAxis` already uses. The direction is NOT
    /// normalized here: a construction axis's direction needs no rescaling
    /// because the kernel only uses it as a line direction.
    static func planeLocal(
        _ geometry: ResolvedAxisGeometry,
        plane: SketchPlane,
        tolerance: Double? = nil
    ) throws -> RevolveAxis {
        try AxisPointMath.requireFinite(geometry.origin, "resolved axis origin")
        let direction = try AxisPointMath.unit(geometry.direction, "resolved axis direction")
        try AxisPointMath.requireFinite(plane.origin, "revolve plane origin")
        let normal = try AxisPointMath.unit(plane.normal, "revolve plane normal")
        let xAxis = try AxisPointMath.unit(plane.xAxis, "revolve plane x axis")
        let yAxis = try AxisPointMath.unit(plane.yAxis, "revolve plane y axis")
        guard abs(simd_dot(direction, normal)) <= directionTolerance else {
            throw AssociativeAxisPointError.axisNotInPlane(
                "the axis is not parallel to the revolve plane")
        }
        let height = simd_dot(geometry.origin - plane.origin, normal)
        let limit = tolerance ?? planeTolerance(extent: geometry.extent)
        guard abs(height) <= limit else {
            throw AssociativeAxisPointError.axisNotInPlane(
                "the axis line is \(height) mm off the revolve plane")
        }
        let point = SIMD2(
            simd_dot(geometry.origin - plane.origin, xAxis),
            simd_dot(geometry.origin - plane.origin, yAxis))
        let projected = SIMD2(
            simd_dot(direction, xAxis),
            simd_dot(direction, yAxis))
        guard simd_length(projected) > 1e-9 else {
            throw AssociativeAxisPointError.degenerateDirection(
                "the axis collapses when projected into the revolve plane")
        }
        try AxisPointMath.requireFinite(SIMD3(point.x, point.y, 0), "projected revolve axis point")
        return RevolveAxis(point: point, direction: projected)
    }
}

// MARK: - Datum point identity and entity

nonisolated struct DatumPointID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

/// A datum point in the document. `position` is the last resolved world
/// millimetres — a display/selection cache only, exactly like
/// `ConstructionPlane.plane`. `definition` is the source of truth when
/// present; nil keeps a legacy absolute point (a coordinate the user placed).
nonisolated struct DatumPoint: Identifiable, Codable, Equatable, Sendable {
    let id: DatumPointID
    var position: SIMD3<Double>
    var name: String
    var isHidden: Bool
    var definition: DatumPointDefinition?

    init(
        id: DatumPointID = DatumPointID(),
        position: SIMD3<Double> = .zero,
        name: String = "Point",
        isHidden: Bool = false,
        definition: DatumPointDefinition? = nil
    ) {
        self.id = id
        self.position = position
        self.name = name
        self.isHidden = isHidden
        self.definition = definition
    }

    private enum CodingKeys: String, CodingKey {
        case id, position, name, isHidden, definition
    }

    /// `isHidden` is optional on decode so a point written before it existed
    /// still loads. A present but unsupported `definition` throws out of
    /// `DatumPointDefinition.init(from:)`; it is never swallowed into nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DatumPointID.self, forKey: .id)
        position = try container.decode(SIMD3<Double>.self, forKey: .position)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Point"
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        definition = try container.decodeIfPresent(
            DatumPointDefinition.self, forKey: .definition)
    }

    /// Encoding is explicit so an absolute point keeps the exact legacy key
    /// set. `position` stays encoded even for an associative point: it is the
    /// last resolved display cache.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(name, forKey: .name)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encodeIfPresent(definition, forKey: .definition)
    }
}

// MARK: - Face-center point

/// A datum point at the current centre of one exact named face. Resolution
/// reads the frozen writer's current face centroid, so an upstream edit moves
/// the point.
nonisolated struct FaceCenterPointDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: FaceRef
    let sourceVersion: GeometryVersionRef

    init(
        version: Int = FaceCenterPointDefinition.supportedVersion,
        source: FaceRef,
        sourceVersion: GeometryVersionRef
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(FaceRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
    }

    func resolvedPoint(face: SourceFaceGeometry, bodyTransform: Transform3D)
        throws -> ResolvedDatumPointGeometry {
        try validate()
        guard face.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceBodyMismatch(
                expected: sourceVersion.bodyID, actual: face.bodyID)
        }
        try AxisPointMath.validate(bodyTransform)
        try AxisPointMath.requireFinite(face.centroid, "face centroid")
        let position = bodyTransform.applying(to: face.centroid)
        try AxisPointMath.requireFinite(position, "resolved point")
        return ResolvedDatumPointGeometry(position: position)
    }
}

// MARK: - Edge point

/// A datum point on one persisted straight edge, at a signed world-millimetre
/// offset from the edge midpoint along the edge. Offset 0 is the midpoint.
nonisolated struct EdgePointDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: EdgeRef
    let sourceVersion: GeometryVersionRef
    var offset: Expr

    init(
        version: Int = EdgePointDefinition.supportedVersion,
        source: EdgeRef,
        sourceVersion: GeometryVersionRef,
        offset: Expr
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(EdgeRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        offset = try container.decode(Expr.self, forKey: .offset)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard offset.value.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue("point offset")
        }
    }

    func resolvedPoint(edge: SourceAxisGeometry, bodyTransform: Transform3D)
        throws -> ResolvedDatumPointGeometry {
        try validate()
        guard edge.bodyID == sourceVersion.bodyID else {
            throw AssociativeAxisPointError.sourceBodyMismatch(
                expected: sourceVersion.bodyID, actual: edge.bodyID)
        }
        try AxisPointMath.validate(bodyTransform)
        let localDirection = try AxisPointMath.unit(edge.direction, "edge direction")
        let worldDirection = simd_normalize(bodyTransform.rotation.act(localDirection))
        let worldOrigin = bodyTransform.applying(to: edge.origin)
        let position = worldOrigin + worldDirection * offset.value
        try AxisPointMath.requireFinite(position, "resolved point")
        return ResolvedDatumPointGeometry(position: position)
    }
}

// MARK: - Two-point midpoint

/// A datum point at the midpoint of two persisted point identities.
nonisolated struct TwoPointMidpointDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let points: [DatumPointSource]

    init(
        version: Int = TwoPointMidpointDefinition.supportedVersion,
        points: [DatumPointSource]
    ) {
        self.version = version
        self.points = points
    }

    private enum CodingKeys: String, CodingKey {
        case version, points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        points = try container.decode([DatumPointSource].self, forKey: .points)
        try TwoPointMidpointDefinition.validate(points: points)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        try Self.validate(points: points)
    }

    private static func validate(points: [DatumPointSource]) throws {
        guard points.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a midpoint must carry exactly two points")
        }
        guard Set(points.map(\.diagnosticKey)).count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "a midpoint must name two distinct points")
        }
    }

    /// Coincident sources are legal (the midpoint is that same point), but a
    /// non-finite one is not.
    static func resolvedPoint(first: SIMD3<Double>, second: SIMD3<Double>) throws
        -> ResolvedDatumPointGeometry {
        try AxisPointMath.requireFinite(first, "first point")
        try AxisPointMath.requireFinite(second, "second point")
        return ResolvedDatumPointGeometry(position: (first + second) / 2)
    }

    func resolvedPoint(worldPoints: [SIMD3<Double>]) throws -> ResolvedDatumPointGeometry {
        try validate()
        guard worldPoints.count == 2 else {
            throw AssociativeAxisPointError.invalidDefinitionShape(
                "two resolved points are required")
        }
        return try Self.resolvedPoint(first: worldPoints[0], second: worldPoints[1])
    }
}

// MARK: - Axis point

/// A datum point on an associative construction axis at a signed world-
/// millimetre offset from that axis's resolved origin. This is the editable
/// offset on a point that follows an axis.
nonisolated struct AxisPointDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let axis: ConstructionAxisID
    var offset: Expr

    init(
        version: Int = AxisPointDefinition.supportedVersion,
        axis: ConstructionAxisID,
        offset: Expr
    ) {
        self.version = version
        self.axis = axis
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case version, axis, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        axis = try container.decode(ConstructionAxisID.self, forKey: .axis)
        offset = try container.decode(Expr.self, forKey: .offset)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        guard offset.value.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue("point offset")
        }
    }

    func resolvedPoint(axis: ResolvedAxisGeometry) throws -> ResolvedDatumPointGeometry {
        try validate()
        let position = axis.origin + axis.direction * offset.value
        try AxisPointMath.requireFinite(position, "resolved point")
        return ResolvedDatumPointGeometry(position: position)
    }
}

// MARK: - Axis × plane point

/// A datum point where an associative construction axis crosses a construction
/// plane. A parallel axis or a coincident pair refuses: there is no unique
/// point to pick.
nonisolated struct AxisPlanePointDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let axis: ConstructionAxisID
    let plane: ConstructionPlaneID

    init(
        version: Int = AxisPlanePointDefinition.supportedVersion,
        axis: ConstructionAxisID,
        plane: ConstructionPlaneID
    ) {
        self.version = version
        self.axis = axis
        self.plane = plane
    }

    private enum CodingKeys: String, CodingKey {
        case version, axis, plane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
        self.version = version
        axis = try container.decode(ConstructionAxisID.self, forKey: .axis)
        plane = try container.decode(ConstructionPlaneID.self, forKey: .plane)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeAxisPointError.unsupportedSemanticVersion(version)
        }
    }

    func resolvedPoint(axis: ResolvedAxisGeometry, plane: SketchPlane) throws
        -> ResolvedDatumPointGeometry {
        try validate()
        let normal = try AxisPointMath.unit(plane.normal, "plane normal")
        let denominator = simd_dot(axis.direction, normal)
        guard abs(denominator) > 1e-9 else {
            throw AssociativeAxisPointError.parallelSources(
                "the axis is parallel to the plane")
        }
        let t = simd_dot(plane.origin - axis.origin, normal) / denominator
        guard t.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue("plane intersection distance")
        }
        let position = axis.origin + axis.direction * t
        try AxisPointMath.requireFinite(position, "resolved point")
        return ResolvedDatumPointGeometry(position: position)
    }
}

// MARK: - Datum point definition

/// The persistent datum-point definition. Each case has its own explicit
/// semantic version, so a payload this build cannot read is a decode failure
/// (opaque read-only document) rather than a cached absolute point.
nonisolated enum DatumPointDefinition: Codable, Equatable, Sendable {
    case faceCenter(FaceCenterPointDefinition)
    case edgePoint(EdgePointDefinition)
    case twoPointMidpoint(TwoPointMidpointDefinition)
    case axisPoint(AxisPointDefinition)
    case axisPlane(AxisPlanePointDefinition)

    nonisolated enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case faceCenter
        case edgePoint
        case twoPointMidpoint
        case axisPoint
        case axisPlane
    }

    var kind: Kind {
        switch self {
        case .faceCenter: return .faceCenter
        case .edgePoint: return .edgePoint
        case .twoPointMidpoint: return .twoPointMidpoint
        case .axisPoint: return .axisPoint
        case .axisPlane: return .axisPlane
        }
    }

    var semanticVersion: Int {
        switch self {
        case let .faceCenter(definition): return definition.version
        case let .edgePoint(definition): return definition.version
        case let .twoPointMidpoint(definition): return definition.version
        case let .axisPoint(definition): return definition.version
        case let .axisPlane(definition): return definition.version
        }
    }

    var supportedSemanticVersion: Int {
        switch self {
        case .faceCenter: return FaceCenterPointDefinition.supportedVersion
        case .edgePoint: return EdgePointDefinition.supportedVersion
        case .twoPointMidpoint: return TwoPointMidpointDefinition.supportedVersion
        case .axisPoint: return AxisPointDefinition.supportedVersion
        case .axisPlane: return AxisPlanePointDefinition.supportedVersion
        }
    }

    var isSupportedSemanticVersion: Bool {
        semanticVersion == supportedSemanticVersion
    }

    /// The frozen body version a face/edge source resolves against, if any.
    var writerVersion: GeometryVersionRef? {
        switch self {
        case let .faceCenter(definition): return definition.sourceVersion
        case let .edgePoint(definition): return definition.sourceVersion
        case .twoPointMidpoint, .axisPoint, .axisPlane: return nil
        }
    }

    /// The construction axis this point follows, if any.
    var axisID: ConstructionAxisID? {
        switch self {
        case let .axisPoint(definition): return definition.axis
        case let .axisPlane(definition): return definition.axis
        default: return nil
        }
    }

    /// The construction plane this point follows, if any.
    var planeID: ConstructionPlaneID? {
        if case let .axisPlane(definition) = self { return definition.plane }
        return nil
    }

    /// The point identities this definition depends on, if any.
    var pointSources: [DatumPointSource] {
        switch self {
        case let .twoPointMidpoint(definition): return definition.points
        default: return []
        }
    }

    var expressionSlots: [AssociativeDatumExpressionSlot] {
        switch self {
        case let .edgePoint(definition):
            return [AssociativeDatumExpressionSlot(
                name: "offset", unit: "mm", expr: definition.offset)]
        case let .axisPoint(definition):
            return [AssociativeDatumExpressionSlot(
                name: "offset", unit: "mm", expr: definition.offset)]
        case .faceCenter, .twoPointMidpoint, .axisPlane:
            return []
        }
    }

    func settingExpression(named name: String, to expr: Expr) -> DatumPointDefinition? {
        switch self {
        case var .edgePoint(definition) where name == "offset":
            definition.offset = expr
            return .edgePoint(definition)
        case var .axisPoint(definition) where name == "offset":
            definition.offset = expr
            return .axisPoint(definition)
        default:
            return nil
        }
    }

    func reevaluated(with variables: [String: Double]) -> DatumPointDefinition? {
        var changed = false
        var result = self
        for slot in expressionSlots {
            guard let formula = slot.expr.formula,
                  let value = ExpressionEvaluator.evaluate(formula, variables: variables),
                  value.isFinite, value != slot.expr.value else { continue }
            var expr = slot.expr
            expr.value = value
            guard let updated = result.settingExpression(named: slot.name, to: expr) else { continue }
            result = updated
            changed = true
        }
        return changed ? result : nil
    }

    func rewritingFormulas(_ transform: (String) -> String?) -> DatumPointDefinition? {
        var changed = false
        var result = self
        for slot in expressionSlots {
            guard let formula = slot.expr.formula,
                  let rewritten = transform(formula), rewritten != formula else { continue }
            var expr = slot.expr
            expr.formula = rewritten
            guard let updated = result.settingExpression(named: slot.name, to: expr) else { continue }
            result = updated
            changed = true
        }
        return changed ? result : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, faceCenter, edgePoint, twoPointMidpoint, axisPoint, axisPlane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.faceCenter.rawValue:
            self = .faceCenter(try container.decode(FaceCenterPointDefinition.self, forKey: .faceCenter))
        case Kind.edgePoint.rawValue:
            self = .edgePoint(try container.decode(EdgePointDefinition.self, forKey: .edgePoint))
        case Kind.twoPointMidpoint.rawValue:
            self = .twoPointMidpoint(
                try container.decode(TwoPointMidpointDefinition.self, forKey: .twoPointMidpoint))
        case Kind.axisPoint.rawValue:
            self = .axisPoint(try container.decode(AxisPointDefinition.self, forKey: .axisPoint))
        case Kind.axisPlane.rawValue:
            self = .axisPlane(try container.decode(AxisPlanePointDefinition.self, forKey: .axisPlane))
        default:
            throw AssociativeAxisPointError.unsupportedDefinitionKind(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .faceCenter(definition):
            try container.encode(Kind.faceCenter, forKey: .kind)
            try container.encode(definition, forKey: .faceCenter)
        case let .edgePoint(definition):
            try container.encode(Kind.edgePoint, forKey: .kind)
            try container.encode(definition, forKey: .edgePoint)
        case let .twoPointMidpoint(definition):
            try container.encode(Kind.twoPointMidpoint, forKey: .kind)
            try container.encode(definition, forKey: .twoPointMidpoint)
        case let .axisPoint(definition):
            try container.encode(Kind.axisPoint, forKey: .kind)
            try container.encode(definition, forKey: .axisPoint)
        case let .axisPlane(definition):
            try container.encode(Kind.axisPlane, forKey: .kind)
            try container.encode(definition, forKey: .axisPlane)
        }
    }
}

// MARK: - Numeric helpers

/// One private home for the finite/unit/basis checks this file needs. The
/// tolerances match `PlaneAttachmentFrame` so an axis and a plane built from
/// the same face agree bit-for-bit on what "orthonormal" means.
nonisolated private enum AxisPointMath {
    static var unitTolerance: Double { 1e-6 }
    static var minimumDirectionLength: Double { 1e-9 }

    static func requireFinite(_ value: SIMD3<Double>, _ label: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw AssociativeAxisPointError.nonFiniteValue(label)
        }
    }

    static func unit(_ vector: SIMD3<Double>, _ label: String) throws -> SIMD3<Double> {
        try requireFinite(vector, label)
        let length = simd_length(vector)
        guard length.isFinite, length > minimumDirectionLength else {
            throw AssociativeAxisPointError.degenerateDirection("\(label) has no usable direction")
        }
        return vector / length
    }

    static func validate(_ transform: Transform3D) throws {
        guard transform.scale.isFinite, transform.scale > 0 else {
            throw AssociativeAxisPointError.invalidBodyTransform(
                "scale must be positive and finite")
        }
        try requireFinite(transform.translation, "body translation")
        let rotation = transform.rotation.vector
        guard rotation.x.isFinite, rotation.y.isFinite,
              rotation.z.isFinite, rotation.w.isFinite else {
            throw AssociativeAxisPointError.invalidBodyTransform(
                "the rotation is not finite")
        }
        let length = simd_length(rotation)
        guard length.isFinite, length > 0 else {
            throw AssociativeAxisPointError.invalidBodyTransform(
                "the rotation has no direction")
        }
        guard abs(length - 1) <= unitTolerance else {
            throw AssociativeAxisPointError.invalidBodyTransform(
                "the rotation is not a unit quaternion")
        }
    }
}

// MARK: - Stored axis frame bridge

nonisolated extension ConstructionAxis {
    /// The resolved world line this axis currently represents. A definition
    /// axis is kept up to date by the resolver; an absolute axis is exactly
    /// what it stores.
    var resolvedLine: ResolvedAxisGeometry {
        ResolvedAxisGeometry(origin: origin, direction: direction, extent: length)
    }
}

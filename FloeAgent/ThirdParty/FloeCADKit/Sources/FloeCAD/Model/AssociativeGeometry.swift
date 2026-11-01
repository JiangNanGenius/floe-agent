//
//  AssociativeGeometry.swift
//  FloeCAD
//
//  M07 (associative construction planes) — the persistent value model plus
//  the pure geometric adapters for the three datum kinds:
//
//      OffsetPlaneDefinition.resolvedPlane(face:bodyTransform:)
//      AnglePlaneDefinition.resolvedPlane(face:bodyTransform:)
//      ThreePointPlaneDefinition.resolvedPlane(worldPoints:)
//
//  This file deliberately contains NO feature-graph replay, named-face lookup,
//  dependency walker, topological naming or resolved-geometry cache. Those
//  live in AssociativeGeometryResolver.
//
//  The adapter is bounded by existing conventions: a face contributes a
//  body-local centroid and outward normal, `SketchPlane` carries the result
//  basis, and `Transform3D.applying`/`rotation` place it in the world. The
//  source face is supplied BY THE CALLER from the frozen geometry version; a
//  cached `ConstructionPlane.plane` is never accepted as an input, so a stale
//  resolved plane cannot become the authority after a rebuild.
//
//  Persistence rules that package C must honour:
//    * `ConstructionPlane.definition` and `Sketch.support` are optional and
//      omitted when nil, so a legacy value keeps its exact stored shape.
//    * A PRESENT definition with an unknown kind or semantic version throws
//      `AssociativeGeometryError` from `init(from:)`. It must never decode to
//      nil (which would silently restore absolute-plane behavior). The store
//      must preserve the original plane/sketch blob bytes and open the
//      document opaque and read-only.
//

import Foundation
import simd

// MARK: - Errors

/// A value-level reason an associative definition cannot be decoded or
/// resolved. The unsupported-kind/version cases are DECODE failures; the
/// remaining cases are resolution failures that package B reports as a broken
/// reference (never as a fallback to the cached plane).
nonisolated enum AssociativeGeometryError: Error, LocalizedError, Equatable, Sendable {
    /// A definition payload names a kind this build does not implement.
    case unsupportedDefinitionKind(String)
    /// A definition payload has a semantic version this build cannot read.
    case unsupportedSemanticVersion(Int)
    /// The definition's own `source.body.bodyID` and frozen `sourceVersion`
    /// name different bodies — the value is internally inconsistent.
    case sourceVersionBodyMismatch(source: BodyID, version: BodyID)
    /// The caller resolved a face on a different body than the frozen source.
    case faceBodyMismatch(expected: BodyID, actual: BodyID)
    /// A numeric input was NaN or infinite.
    case nonFiniteValue(String)
    /// The current face geometry cannot produce a stable in-plane frame.
    case degenerateFaceGeometry(String)
    /// A stored attachment frame is not a finite orthonormal right-handed
    /// basis.
    case invalidAttachmentFrame(String)
    /// The snapshot body transform is not a positive finite similarity
    /// transform.
    case invalidBodyTransform(String)
    /// The stored hinge direction is finite but has no usable in-plane
    /// direction, or is not unit length.
    case invalidHingeAxis(String)
    /// A stored definition is structurally unreadable at a KNOWN semantic
    /// version (for example a three-point payload that does not carry exactly
    /// three distinct anchors).
    case invalidDefinitionShape(String)
    /// Three resolved anchor points are coincident or collinear, so they do
    /// not define a plane. This is a broken reference, never a nearest-fit.
    case degenerateAnchorPoints(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedDefinitionKind(kind):
            return "Unsupported construction-plane definition kind '\(kind)'."
        case let .unsupportedSemanticVersion(version):
            return "Unsupported associative construction-plane definition version \(version)."
        case let .sourceVersionBodyMismatch(source, version):
            return "The associative definition names source body \(source.raw.uuidString) "
                + "but freezes geometry for body \(version.raw.uuidString)."
        case let .faceBodyMismatch(expected, actual):
            return "The resolved face belongs to body \(actual.raw.uuidString), "
                + "but the associative definition is frozen to body \(expected.raw.uuidString)."
        case let .nonFiniteValue(label):
            return "\(label) is not finite."
        case let .degenerateFaceGeometry(reason):
            return "Cannot derive a stable attachment frame: \(reason)."
        case let .invalidAttachmentFrame(reason):
            return "Invalid plane attachment frame: \(reason)."
        case let .invalidBodyTransform(reason):
            return "Invalid body transform: \(reason)."
        case let .invalidHingeAxis(reason):
            return "Invalid plane hinge axis: \(reason)."
        case let .invalidDefinitionShape(reason):
            return "Invalid construction-plane definition: \(reason)."
        case let .degenerateAnchorPoints(reason):
            return "Cannot derive a plane from the three source points: \(reason)."
        }
    }

    /// True only for a PRESENT definition written to a newer/other semantic
    /// contract. Package C's load boundary must catch this case, keep the
    /// original blob bytes, and open the document opaque and read-only; it is
    /// not a corrupt-row or a broken-reference case that may fall back to the
    /// cached absolute plane.
    var requiresOpaqueReadOnlyDocument: Bool {
        switch self {
        case .unsupportedDefinitionKind, .unsupportedSemanticVersion:
            return true
        default:
            return false
        }
    }
}

// MARK: - Frozen source geometry version

/// The exact evaluation of a body a datum's source face was frozen against.
///
/// `writer` is the feature node whose evaluation actually put `bodyID` during
/// the replay that minted the datum. It is deliberately NOT
/// `BodyRef.producer`: producer is naming provenance, and a later transform or
/// boolean can rewrite the same BodyID after that producer. The two contracts
/// are different, and a datum created on writer A keeps resolving A's output
/// even after writer B appears.
nonisolated struct GeometryVersionRef: Codable, Hashable, Sendable {
    var bodyID: BodyID
    var writer: FeatureID

    init(bodyID: BodyID, writer: FeatureID) {
        self.bodyID = bodyID
        self.writer = writer
    }
}

// MARK: - Current face geometry

/// The current geometry of the named source face, in the source body's LOCAL
/// space. Package B resolves the frozen version's element name to this value;
/// this type never performs naming or lookup itself.
nonisolated struct SourceFaceGeometry: Equatable, Sendable {
    var bodyID: BodyID
    var centroid: SIMD3<Double>
    /// Outward face normal in body-local space. It need not be exactly unit;
    /// resolution normalizes it once and rejects a zero/near-zero direction.
    var normal: SIMD3<Double>

    init(bodyID: BodyID, centroid: SIMD3<Double>, normal: SIMD3<Double>) {
        self.bodyID = bodyID
        self.centroid = centroid
        self.normal = normal
    }
}

// MARK: - Attachment frame

/// The frozen attachment of an offset datum to one face.
///
/// `normal` and `xAxis` are the source face's body-local unit normal and
/// in-plane axis at creation time; `yAxis` completes the right-handed frame
/// (`x × y = normal`). `anchorOffset` is the in-plane, centroid-relative
/// anchor in those two axes, in body-local millimetres. It is NOT a vertex,
/// edge or UV constraint: if an asymmetric size change moves the face
/// centroid, the anchor moves with it.
///
/// Resolution projects the stored `xAxis` into the CURRENT face plane and
/// re-orthonormalizes it. The projection is a pure function of the stored
/// frame and the current normal — no world-axis "readable" heuristic, no
/// previous resolved plane, no cold/hot cache. If the stored x axis lies on
/// the current normal the in-plane direction is not uniquely determined and
/// resolution refuses rather than flipping or guessing.
nonisolated struct PlaneAttachmentFrame: Codable, Equatable, Sendable {
    /// Body-local unit outward normal of the source face at creation.
    var normal: SIMD3<Double>
    /// Body-local unit in-plane x axis at creation, orthogonal to `normal`.
    var xAxis: SIMD3<Double>
    /// In-plane offset from the source face centroid, in `xAxis`/`yAxis` mm.
    var anchorOffset: SIMD2<Double>

    init(normal: SIMD3<Double>, xAxis: SIMD3<Double>, anchorOffset: SIMD2<Double>) {
        self.normal = normal
        self.xAxis = xAxis
        self.anchorOffset = anchorOffset
    }

    /// y = n × x, so (x, y, n) is right-handed: x × y = n.
    var yAxis: SIMD3<Double> {
        simd_cross(normal, xAxis)
    }

    // MARK: Creation

    /// Freeze an attachment from the current source face.
    ///
    /// - Parameters:
    ///   - faceCentroid: Face centroid in body-local mm — the anchor's origin.
    ///   - faceNormal: Body-local outward normal; normalized here.
    ///   - referenceXAxis: body-local direction used only to choose the
    ///     initial in-plane x axis. Out-of-plane components are projected.
    ///   - anchorPoint: Optional picked point in body-local mm. Only its
    ///     in-plane components relative to the centroid are stored; an
    ///     out-of-plane pick error is projected, never kept as authority.
    static func make(
        faceCentroid: SIMD3<Double>,
        faceNormal: SIMD3<Double>,
        referenceXAxis: SIMD3<Double>,
        anchorPoint: SIMD3<Double>? = nil
    ) throws -> PlaneAttachmentFrame {
        try requireFinite(faceCentroid, "face centroid")
        try requireFinite(referenceXAxis, "reference x axis")
        let n = try unitDirection(faceNormal, label: "face normal")

        let projectedX = referenceXAxis - n * simd_dot(referenceXAxis, n)
        guard simd_length(projectedX) > Self.minimumInPlaneLength else {
            throw AssociativeGeometryError.degenerateFaceGeometry(
                "the reference x axis is parallel to the face normal")
        }
        let x = simd_normalize(projectedX)

        var anchorOffset = SIMD2<Double>(0, 0)
        if let anchorPoint {
            try requireFinite(anchorPoint, "anchor point")
            let delta = anchorPoint - faceCentroid
            anchorOffset = SIMD2(
                simd_dot(delta, x),
                simd_dot(delta, simd_cross(n, x))
            )
        }

        let frame = PlaneAttachmentFrame(
            normal: n,
            xAxis: x,
            anchorOffset: anchorOffset
        )
        try frame.validate()
        return frame
    }

    // MARK: Validation

    /// The stored frame must already be finite, unit length, orthogonal and
    /// right-handed. A corrupted basis is never repaired silently.
    func validate() throws {
        try Self.requireFinite(normal, "attachment normal")
        try Self.requireFinite(xAxis, "attachment x axis")
        guard anchorOffset.x.isFinite, anchorOffset.y.isFinite else {
            throw AssociativeGeometryError.invalidAttachmentFrame(
                "the anchor offset is not finite")
        }
        guard abs(simd_length(normal) - 1) <= Self.unitTolerance else {
            throw AssociativeGeometryError.invalidAttachmentFrame(
                "the normal is not unit length")
        }
        guard abs(simd_length(xAxis) - 1) <= Self.unitTolerance else {
            throw AssociativeGeometryError.invalidAttachmentFrame(
                "the x axis is not unit length")
        }
        guard abs(simd_dot(normal, xAxis)) <= Self.unitTolerance else {
            throw AssociativeGeometryError.invalidAttachmentFrame(
                "the x axis is not orthogonal to the normal")
        }
        let y = yAxis
        try Self.validateBasis(normal: normal, xAxis: xAxis, yAxis: y)
    }

    // MARK: Resolution

    /// Resolve the attached sketch plane in world space.
    ///
    /// 1. Take the CURRENT named face centroid/normal, both body-local.
    /// 2. Project the frozen x axis into that plane and orthonormalize.
    /// 3. Rebuild the anchor from the new centroid plus the frozen in-plane
    ///    offset — never from a previously resolved plane.
    /// 4. Apply the snapshot `bodyTransform` (translation, rotation and
    ///    uniform scale) to the anchor and basis.
    /// 5. Offset along the resulting UNIT world normal by `offsetMM`.
    ///
    /// The offset is added in world millimetres AFTER the transform, so a
    /// body scale is applied exactly once (to the body-local anchor), never
    /// again to the offset distance.
    func resolvedPlane(
        face: SourceFaceGeometry,
        bodyTransform: Transform3D,
        offsetMM: Double
    ) throws -> SketchPlane {
        try validate()
        try Self.requireFinite(face.centroid, "face centroid")
        guard offsetMM.isFinite else {
            throw AssociativeGeometryError.nonFiniteValue("offset distance")
        }
        let currentNormal = try Self.unitDirection(face.normal, label: "face normal")

        // Deterministic projection of the FROZEN reference axis onto the
        // CURRENT plane. No world "up" test and no previous resolved result.
        let projectedX = xAxis - currentNormal * simd_dot(xAxis, currentNormal)
        guard simd_length(projectedX) > Self.minimumInPlaneLength else {
            throw AssociativeGeometryError.degenerateFaceGeometry(
                "the frozen x axis is parallel to the resolved face normal")
        }
        let localX = simd_normalize(projectedX)
        let localY = simd_cross(currentNormal, localX)
        try Self.validateBasis(normal: currentNormal, xAxis: localX, yAxis: localY)

        let localAnchor = face.centroid
            + localX * anchorOffset.x
            + localY * anchorOffset.y
        try Self.requireFinite(localAnchor, "resolved anchor")

        try Self.validate(bodyTransform)

        let worldNormal = simd_normalize(bodyTransform.rotation.act(currentNormal))
        let worldX = simd_normalize(bodyTransform.rotation.act(localX))
        let worldY = simd_cross(worldNormal, worldX)
        try Self.validateBasis(normal: worldNormal, xAxis: worldX, yAxis: worldY)

        // `Transform3D.applying` is the existing placement math: scale,
        // rotate, translate. Reusing it keeps this adapter from growing a
        // second transform implementation.
        let worldAnchor = bodyTransform.applying(to: localAnchor)
        let origin = worldAnchor + worldNormal * offsetMM
        try Self.requireFinite(origin, "resolved plane origin")

        return SketchPlane(origin: origin, xAxis: worldX, yAxis: worldY)
    }

    /// Resolve an angle datum: the CURRENT named source face supplies the
    /// centroid/normal, the frozen in-plane axis is projected as for an offset
    /// plane, and the resulting frame is rotated ONCE about the explicit local
    /// hinge direction by `angleRadians`.
    ///
    /// The hinge lives in the same stored attachment frame as `anchorOffset`
    /// (`hinge.x` along the frozen x axis, `hinge.y` along `n × x`), so a
    /// later face-normal change carries the hinge with the face instead of
    /// silently rotating about a world axis. The angle is supplied in radians
    /// by the definition, which converts the public degree expression exactly
    /// once.
    func resolvedRotatedPlane(
        face: SourceFaceGeometry,
        bodyTransform: Transform3D,
        hinge: SIMD2<Double>,
        angleRadians: Double
    ) throws -> SketchPlane {
        try validate()
        try Self.requireFinite(face.centroid, "face centroid")
        guard angleRadians.isFinite else {
            throw AssociativeGeometryError.nonFiniteValue("angle")
        }
        guard abs(simd_length(hinge) - 1) <= Self.unitTolerance else {
            throw AssociativeGeometryError.invalidHingeAxis("the hinge is not unit length")
        }
        let currentNormal = try Self.unitDirection(face.normal, label: "face normal")

        let projectedX = xAxis - currentNormal * simd_dot(xAxis, currentNormal)
        guard simd_length(projectedX) > Self.minimumInPlaneLength else {
            throw AssociativeGeometryError.degenerateFaceGeometry(
                "the frozen x axis is parallel to the resolved face normal")
        }
        let localX = simd_normalize(projectedX)
        let localY = simd_cross(currentNormal, localX)
        try Self.validateBasis(normal: currentNormal, xAxis: localX, yAxis: localY)

        let localAnchor = face.centroid
            + localX * anchorOffset.x
            + localY * anchorOffset.y
        try Self.requireFinite(localAnchor, "resolved anchor")

        // Explicit local hinge: a unit direction in the current face plane.
        let hingeLocal = simd_normalize(localX * hinge.x + localY * hinge.y)
        let rotation = simd_quatd(angle: angleRadians, axis: hingeLocal)
        let rotatedNormal = simd_normalize(rotation.act(currentNormal))
        let rotatedX = simd_normalize(rotation.act(localX))
        let rotatedY = simd_cross(rotatedNormal, rotatedX)
        try Self.validateBasis(normal: rotatedNormal, xAxis: rotatedX, yAxis: rotatedY)

        try Self.validate(bodyTransform)
        let worldNormal = simd_normalize(bodyTransform.rotation.act(rotatedNormal))
        let worldX = simd_normalize(bodyTransform.rotation.act(rotatedX))
        let worldY = simd_cross(worldNormal, worldX)
        try Self.validateBasis(normal: worldNormal, xAxis: worldX, yAxis: worldY)
        let worldAnchor = bodyTransform.applying(to: localAnchor)
        try Self.requireFinite(worldAnchor, "resolved angle-plane origin")
        return SketchPlane(origin: worldAnchor, xAxis: worldX, yAxis: worldY)
    }

    // MARK: Numeric helpers

    /// Loose enough for a basis that has crossed JSON, tight enough that a
    /// non-orthonormal or non-unit stored frame is refused rather than
    /// silently repaired.
    private static var unitTolerance: Double { 1e-6 }
    /// A direction shorter than this cannot define an axis.
    private static var minimumDirectionLength: Double { 1e-9 }
    /// A projected in-plane axis shorter than this is considered collapsed.
    private static var minimumInPlaneLength: Double { 1e-6 }

    private static func requireFinite(_ value: SIMD3<Double>, _ label: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw AssociativeGeometryError.nonFiniteValue(label)
        }
    }

    private static func unitDirection(
        _ vector: SIMD3<Double>,
        label: String
    ) throws -> SIMD3<Double> {
        try requireFinite(vector, label)
        let length = simd_length(vector)
        guard length.isFinite, length > minimumDirectionLength else {
            throw AssociativeGeometryError.degenerateFaceGeometry(
                "\(label) has no usable direction")
        }
        return vector / length
    }

    private static func validateBasis(
        normal: SIMD3<Double>,
        xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>
    ) throws {
        guard abs(simd_length(xAxis) - 1) <= unitTolerance,
              abs(simd_length(yAxis) - 1) <= unitTolerance,
              abs(simd_dot(xAxis, normal)) <= unitTolerance,
              abs(simd_dot(yAxis, normal)) <= unitTolerance,
              abs(simd_dot(xAxis, yAxis)) <= unitTolerance,
              simd_length(simd_cross(xAxis, yAxis) - normal) <= unitTolerance
        else {
            throw AssociativeGeometryError.degenerateFaceGeometry(
                "the rebuilt basis is not a right-handed orthonormal frame")
        }
    }

    private static func validate(_ transform: Transform3D) throws {
        guard transform.scale.isFinite, transform.scale > 0 else {
            throw AssociativeGeometryError.invalidBodyTransform(
                "scale must be positive and finite")
        }
        try requireFinite(transform.translation, "body translation")
        let rotation = transform.rotation.vector
        guard rotation.x.isFinite, rotation.y.isFinite,
              rotation.z.isFinite, rotation.w.isFinite
        else {
            throw AssociativeGeometryError.invalidBodyTransform(
                "the rotation is not finite")
        }
        let length = simd_length(rotation)
        guard length.isFinite, length > 0 else {
            throw AssociativeGeometryError.invalidBodyTransform(
                "the rotation has no direction")
        }
        guard abs(length - 1) <= unitTolerance else {
            throw AssociativeGeometryError.invalidBodyTransform(
                "the rotation is not a unit quaternion")
        }
    }
}

// MARK: - Offset definition

/// One associative offset construction plane.
///
/// `source` keeps the existing `FaceRef` provenance/name/signature contract;
/// `sourceVersion` freezes WHICH evaluation of that body the face came from.
/// `distance` is a signed millimetre `Expr`: `.value` is the resolved length
/// and `.formula` remains owned by the existing expression system. Positive
/// distance follows the face's outward normal; negative and zero are legal.
nonisolated struct OffsetPlaneDefinition: Codable, Equatable, Sendable {
    /// Semantic version of this definition's shape/meaning, not a body or
    /// document format version.
    static var supportedVersion: Int { 1 }

    /// Frozen with the value: a re-source or version upgrade constructs a new
    /// definition rather than mutating this one in place.
    let version: Int
    let source: FaceRef
    let sourceVersion: GeometryVersionRef
    /// Editable numeric input of the SAME frozen attachment/source.
    var distance: Expr
    let attachment: PlaneAttachmentFrame

    init(
        version: Int = OffsetPlaneDefinition.supportedVersion,
        source: FaceRef,
        sourceVersion: GeometryVersionRef,
        distance: Expr,
        attachment: PlaneAttachmentFrame
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
        self.distance = distance
        self.attachment = attachment
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion, distance, attachment
    }

    /// Decode the semantic version FIRST, so a future payload is reported as
    /// an unsupported version even when its other fields no longer match this
    /// build's shape. A present but unreadable definition never decodes to a
    /// value that a caller could mistake for legacy absolute geometry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(FaceRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        distance = try container.decode(Expr.self, forKey: .distance)
        attachment = try container.decode(PlaneAttachmentFrame.self, forKey: .attachment)
    }

    // MARK: Validation

    /// A known-version definition can still be internally inconsistent (body
    /// mismatch, non-finite distance, corrupt frame). Those are resolution
    /// failures reported as broken references, not decode failures.
    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeGeometryError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard distance.value.isFinite else {
            throw AssociativeGeometryError.nonFiniteValue("offset distance")
        }
        try attachment.validate()
    }

    // MARK: Resolution

    /// Resolve from the CURRENT named face geometry plus the FROZEN source
    /// body's snapshot transform. `face` must come from the same body as the
    /// frozen `sourceVersion`; the cached `ConstructionPlane.plane` is not an
    /// input and is never consulted.
    func resolvedPlane(
        face: SourceFaceGeometry,
        bodyTransform: Transform3D
    ) throws -> SketchPlane {
        try validate()
        guard face.bodyID == sourceVersion.bodyID else {
            throw AssociativeGeometryError.faceBodyMismatch(
                expected: sourceVersion.bodyID, actual: face.bodyID)
        }
        return try attachment.resolvedPlane(
            face: face,
            bodyTransform: bodyTransform,
            offsetMM: distance.value
        )
    }
}

// MARK: - Sketch anchor references (three-point datums)

/// One addressable point on a persisted sketch entity.
///
/// The pair (entity UUID, `PointRole`) is the SAME semantic point identity the
/// constraint solver uses; a three-point datum stores three of them, never a
/// world coordinate copy. A replacement entity with identical coordinates gets
/// a new UUID and therefore a broken reference — it is never rebound by
/// position or index.
nonisolated struct SketchAnchorRef: Codable, Hashable, Sendable {
    var sketchID: SketchID
    var entityID: UUID
    var role: PointRole

    init(sketchID: SketchID, entityID: UUID, role: PointRole) {
        self.sketchID = sketchID
        self.entityID = entityID
        self.role = role
    }

    /// Identity of the addressed point, for duplicate/order diagnostics.
    var key: String {
        "\(sketchID.raw.uuidString):\(entityID.uuidString):\(role.rawValue)"
    }
}

nonisolated extension SketchEntity {
    /// The persisted semantic point roles this entity actually exposes.
    /// Mirrors the solver's point-addressable slots: line/rect endpoints,
    /// shape centres, and an open spline's first/last fit points. Rect
    /// endpoints are its normalized min/max diagonal corners, exactly as the
    /// existing constraint vocabulary addresses them. Arc rim points and
    /// index-only spline control points are deliberately absent.
    var anchorRoles: [PointRole] {
        switch self {
        case .line, .rect:
            return [.endpointA, .endpointB]
        case .circle, .arc, .ellipse, .polygon:
            return [.center]
        case let .spline(_, points, closed):
            return !closed && points.count >= 2 ? [.endpointA, .endpointB] : []
        }
    }

    /// Current plane-local position of one persisted semantic point, or nil
    /// when this entity does not expose that role.
    func anchorPoint(for role: PointRole) -> SIMD2<Double>? {
        guard anchorRoles.contains(role) else { return nil }
        switch (self, role) {
        case let (.line(_, a, _), .endpointA): return a
        case let (.line(_, _, b), .endpointB): return b
        case let (.rect(_, min, _), .endpointA): return min
        case let (.rect(_, _, max), .endpointB): return max
        case let (.circle(_, center, _), .center): return center
        case let (.arc(_, center, _, _, _), .center): return center
        case let (.ellipse(_, center, _, _, _), .center): return center
        case let (.polygon(_, center, _, _, _), .center): return center
        case let (.spline(_, points, _), .endpointA): return points.first
        case let (.spline(_, points, _), .endpointB): return points.last
        case (.spline(_, _, true), _), (_, .whole), (_, .radiusOnly): return nil
        default: return nil
        }
    }
}

// MARK: - Angle definition

/// One associative angle construction plane.
///
/// The source is the same exact named planar face + frozen writer snapshot as
/// an offset datum. `attachment` stores the face's frozen in-plane frame;
/// `hinge` is an explicit UNIT direction inside that frame (x along the frame's
/// x axis, y along `normal × x`). `angle` is a public DEGREE expression:
/// resolution converts it to radians exactly once. Positive angles follow the
/// right-hand rule about the hinge.
nonisolated struct AnglePlaneDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    let source: FaceRef
    let sourceVersion: GeometryVersionRef
    /// Unit in-plane hinge direction in the stored attachment frame.
    let hinge: SIMD2<Double>
    /// Public degrees. The stored `.value` is the resolved degree value.
    var angle: Expr
    let attachment: PlaneAttachmentFrame

    init(
        version: Int = AnglePlaneDefinition.supportedVersion,
        source: FaceRef,
        sourceVersion: GeometryVersionRef,
        hinge: SIMD2<Double>,
        angle: Expr,
        attachment: PlaneAttachmentFrame
    ) {
        self.version = version
        self.source = source
        self.sourceVersion = sourceVersion
        self.hinge = hinge
        self.angle = angle
        self.attachment = attachment
    }

    private enum CodingKeys: String, CodingKey {
        case version, source, sourceVersion, hinge, angle, attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        self.version = version
        source = try container.decode(FaceRef.self, forKey: .source)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        hinge = try container.decode(SIMD2<Double>.self, forKey: .hinge)
        angle = try container.decode(Expr.self, forKey: .angle)
        attachment = try container.decode(PlaneAttachmentFrame.self, forKey: .attachment)
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw AssociativeGeometryError.sourceVersionBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard hinge.x.isFinite, hinge.y.isFinite,
              abs(simd_length(hinge) - 1) <= 1e-6 else {
            throw AssociativeGeometryError.invalidHingeAxis(
                "the hinge must be a finite unit direction in the source-face frame")
        }
        guard angle.value.isFinite else {
            throw AssociativeGeometryError.nonFiniteValue("angle")
        }
        try attachment.validate()
    }

    /// Resolve from the CURRENT named face plus the frozen writer snapshot.
    /// The public degree value is converted to radians once here.
    func resolvedPlane(face: SourceFaceGeometry, bodyTransform: Transform3D) throws -> SketchPlane {
        try validate()
        guard face.bodyID == sourceVersion.bodyID else {
            throw AssociativeGeometryError.faceBodyMismatch(
                expected: sourceVersion.bodyID, actual: face.bodyID)
        }
        return try attachment.resolvedRotatedPlane(
            face: face,
            bodyTransform: bodyTransform,
            hinge: hinge,
            angleRadians: angle.value * .pi / 180
        )
    }
}

// MARK: - Three-point definition

/// One associative three-point construction plane.
///
/// Exactly three `SketchAnchorRef`s name semantic points on persisted sketch
/// entities. Resolution reads the CURRENT resolved plane/entities of those
/// sketches (including their own associative supports), maps the three points
/// to world millimetres, and builds the plane from the first point toward the
/// second with the third on the positive normal side. No world coordinate is
/// stored, so a parent edit moves the datum; a deleted/replaced identity is a
/// broken reference.
nonisolated struct ThreePointPlaneDefinition: Codable, Equatable, Sendable {
    static var supportedVersion: Int { 1 }

    let version: Int
    /// Creation order: point 1 is the origin, point 2 defines +x, point 3 the
    /// positive normal side.
    let points: [SketchAnchorRef]

    init(
        version: Int = ThreePointPlaneDefinition.supportedVersion,
        points: [SketchAnchorRef]
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
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        self.version = version
        points = try container.decode([SketchAnchorRef].self, forKey: .points)
        guard points.count == 3 else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "a three-point definition must carry exactly three anchors")
        }
        guard Set(points.map(\.key)).count == 3 else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "a three-point definition must name three distinct anchors")
        }
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
        guard points.count == 3 else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "a three-point definition must carry exactly three anchors")
        }
        guard Set(points.map(\.key)).count == 3 else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "a three-point definition must name three distinct anchors")
        }
        guard points.allSatisfy({ $0.role != .whole && $0.role != .radiusOnly }) else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "a three-point anchor must be an endpoint or centre, not a whole entity")
        }
    }

    /// Build the plane from three WORLD-millimetre points. Deterministic in
    /// argument order: origin = first, +x toward the second, normal toward the
    /// third. Coincident or collinear input refuses instead of fitting.
    static func resolvedPlane(
        first: SIMD3<Double>,
        second: SIMD3<Double>,
        third: SIMD3<Double>
    ) throws -> SketchPlane {
        for (value, label) in [(first, "first point"), (second, "second point"),
                               (third, "third point")] {
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
                throw AssociativeGeometryError.nonFiniteValue(label)
            }
        }
        let xVector = second - first
        guard simd_length(xVector) > 1e-9 else {
            throw AssociativeGeometryError.degenerateAnchorPoints(
                "the first two points coincide")
        }
        let normalVector = simd_cross(second - first, third - first)
        guard simd_length(normalVector) > 1e-9 else {
            throw AssociativeGeometryError.degenerateAnchorPoints(
                "the three points are collinear")
        }
        let xAxis = simd_normalize(xVector)
        let normal = simd_normalize(normalVector)
        let yAxis = simd_cross(normal, xAxis)
        return SketchPlane(origin: first, xAxis: xAxis, yAxis: yAxis)
    }

    func resolvedPlane(worldPoints: [SIMD3<Double>]) throws -> SketchPlane {
        try validate()
        guard worldPoints.count == 3 else {
            throw AssociativeGeometryError.invalidDefinitionShape(
                "three resolved points are required")
        }
        return try Self.resolvedPlane(
            first: worldPoints[0], second: worldPoints[1], third: worldPoints[2])
    }
}

// MARK: - Stored expressions

/// One formula-capable scalar owned by a construction-plane definition.
nonisolated struct ConstructionPlaneExpressionSlot: Equatable, Sendable {
    var name: String
    /// Public authoring unit: `mm` for a distance, `deg` for an angle.
    var unit: String
    var expr: Expr
}

// MARK: - Definition kind

/// The persistent construction-plane definition. Each case has an explicit
/// semantic version; a present definition never falls back to the cached
/// absolute plane when it cannot be read or resolved.
nonisolated enum ConstructionPlaneDefinition: Codable, Equatable, Sendable {
    case offset(OffsetPlaneDefinition)
    case angle(AnglePlaneDefinition)
    case threePoints(ThreePointPlaneDefinition)

    nonisolated enum Kind: String, Codable, Sendable {
        case offset
        case angle
        case threePoints
    }

    var kind: Kind {
        switch self {
        case .offset: return .offset
        case .angle: return .angle
        case .threePoints: return .threePoints
        }
    }

    /// The payload's semantic version, e.g. for a dependency fingerprint.
    var semanticVersion: Int {
        switch self {
        case let .offset(definition): return definition.version
        case let .angle(definition): return definition.version
        case let .threePoints(definition): return definition.version
        }
    }

    /// The semantic version this build can read for this kind.
    var supportedSemanticVersion: Int {
        switch self {
        case .offset: return OffsetPlaneDefinition.supportedVersion
        case .angle: return AnglePlaneDefinition.supportedVersion
        case .threePoints: return ThreePointPlaneDefinition.supportedVersion
        }
    }

    var isSupportedSemanticVersion: Bool {
        semanticVersion == supportedSemanticVersion
    }

    /// Formula-capable scalars in their public authoring units. A three-point
    /// definition has none; it follows geometry only.
    var expressionSlots: [ConstructionPlaneExpressionSlot] {
        switch self {
        case let .offset(definition):
            return [ConstructionPlaneExpressionSlot(
                name: "distance", unit: "mm", expr: definition.distance)]
        case let .angle(definition):
            return [ConstructionPlaneExpressionSlot(
                name: "angle", unit: "deg", expr: definition.angle)]
        case .threePoints:
            return []
        }
    }

    /// Return a copy with one named expression replaced, or nil when this kind
    /// has no such slot.
    func settingExpression(named name: String, to expr: Expr) -> ConstructionPlaneDefinition? {
        switch self {
        case var .offset(definition) where name == "distance":
            definition.distance = expr
            return .offset(definition)
        case var .angle(definition) where name == "angle":
            definition.angle = expr
            return .angle(definition)
        default:
            return nil
        }
    }

    /// Re-evaluate every formula against `variables`, updating only changed
    /// `.value` caches. Angle formulas are authored in degrees and stay in
    /// degrees here; the resolver converts once. A missing/non-finite formula
    /// leaves the definition untouched so the resolver reports it, matching
    /// the existing offset behavior.
    func reevaluated(with variables: [String: Double]) -> ConstructionPlaneDefinition? {
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

    /// Rewrite formula text in every expression slot. Returns nil when no
    /// formula changed. Used by variable rename so distance and angle formulas
    /// travel through one token-aware path.
    func rewritingFormulas(_ transform: (String) -> String?) -> ConstructionPlaneDefinition? {
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
        case kind, offset, angle, threePoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.offset.rawValue:
            self = .offset(try container.decode(OffsetPlaneDefinition.self, forKey: .offset))
        case Kind.angle.rawValue:
            self = .angle(try container.decode(AnglePlaneDefinition.self, forKey: .angle))
        case Kind.threePoints.rawValue:
            self = .threePoints(try container.decode(ThreePointPlaneDefinition.self, forKey: .threePoints))
        default:
            throw AssociativeGeometryError.unsupportedDefinitionKind(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .offset(definition):
            try container.encode(Kind.offset, forKey: .kind)
            try container.encode(definition, forKey: .offset)
        case let .angle(definition):
            try container.encode(Kind.angle, forKey: .kind)
            try container.encode(definition, forKey: .angle)
        case let .threePoints(definition):
            try container.encode(Kind.threePoints, forKey: .kind)
            try container.encode(definition, forKey: .threePoints)
        }
    }
}

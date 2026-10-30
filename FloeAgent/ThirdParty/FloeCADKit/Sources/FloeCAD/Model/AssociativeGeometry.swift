//
//  AssociativeGeometry.swift
//  FloeCAD
//
//  M07 (associative offset construction planes) — package A: the persistent
//  value model plus the one pure geometric adapter.
//
//  This file deliberately contains NO feature-graph replay, named-face lookup,
//  dependency walker, topological naming or resolved-geometry cache. Those
//  belong to package B/C. It freezes the stored shape and answers exactly one
//  question for them:
//
//      OffsetPlaneDefinition.resolvedPlane(face:bodyTransform:)
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

    var errorDescription: String? {
        switch self {
        case let .unsupportedDefinitionKind(kind):
            return "Unsupported construction-plane definition kind '\(kind)'."
        case let .unsupportedSemanticVersion(version):
            return "Unsupported associative construction-plane definition version \(version)."
        case let .sourceVersionBodyMismatch(source, version):
            return "The offset definition names source body \(source.raw.uuidString) "
                + "but freezes geometry for body \(version.raw.uuidString)."
        case let .faceBodyMismatch(expected, actual):
            return "The resolved face belongs to body \(actual.raw.uuidString), "
                + "but the offset definition is frozen to body \(expected.raw.uuidString)."
        case let .nonFiniteValue(label):
            return "\(label) is not finite."
        case let .degenerateFaceGeometry(reason):
            return "Cannot derive a stable attachment frame: \(reason)."
        case let .invalidAttachmentFrame(reason):
            return "Invalid plane attachment frame: \(reason)."
        case let .invalidBodyTransform(reason):
            return "Invalid body transform: \(reason)."
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

// MARK: - Definition kind

/// The persistent construction-plane definition. The enum is the extension
/// point for later kinds; only `.offset` exists in the first slice.
nonisolated enum ConstructionPlaneDefinition: Codable, Equatable, Sendable {
    case offset(OffsetPlaneDefinition)

    nonisolated enum Kind: String, Codable, Sendable {
        case offset
    }

    var kind: Kind {
        switch self {
        case .offset: return .offset
        }
    }

    /// The payload's semantic version, e.g. for a dependency fingerprint.
    var semanticVersion: Int {
        switch self {
        case let .offset(definition): return definition.version
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == Kind.offset.rawValue else {
            throw AssociativeGeometryError.unsupportedDefinitionKind(kind)
        }
        self = .offset(try container.decode(OffsetPlaneDefinition.self, forKey: .offset))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .offset(definition):
            try container.encode(Kind.offset, forKey: .kind)
            try container.encode(definition, forKey: .offset)
        }
    }
}

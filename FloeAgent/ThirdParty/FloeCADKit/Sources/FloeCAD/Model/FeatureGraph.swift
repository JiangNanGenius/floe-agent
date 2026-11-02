//
//  FeatureGraph.swift
//  openshape3d
//
//  Phase D (Task B1) — the parametric history ENGINE. A `FeatureGraph` is an
//  ordered list of editable `FeatureNode`s; `evaluate` replays them in order into
//  a live set of bodies + per-body `FaceTable`s, reproducing exactly the geometry
//  the live tools build (primitive → mesh, profile → extrude → boolean, planar
//  face push/pull) so that editing any step's parameter and re-evaluating
//  rebuilds everything downstream — including re-resolving a persisted `FaceRef`
//  against the freshly rebuilt geometry (the topological-naming payoff).
//
//  Everything here is `nonisolated` pure geometry, replayed off the main actor
//  and round-tripped through the SwiftData store as JSON. Model space is Double;
//  every emitted `Body` gets a FRESH `meshRevision` from `nextRevision()` so the
//  GPU cache invalidates, and reuses `node.outputBodyIDs` (never mints a new
//  `BodyID` on rebuild) so selection / transform / material survive an edit.
//
//  Tranche 1 EVALUATES `.primitive`, `.extrude`, `.boolean`, and
//  `.pushPull(.planarAxial)`. The remaining kinds are DEFINED (so the graph type
//  is total and Codable) but return `.kernelFailure` from `evaluate` rather than
//  building geometry — they are recorded/evaluated in tranche 2.
//

import OCCTShim
import Foundation
import simd
import Euclid

// MARK: - Placeholder value types (tranche-2 payloads)

/// Linear/circular 3D body-pattern descriptor (tranche 4). `count` is the TOTAL
/// number of instances including the original, so a pattern EMITS `count − 1`
/// copies; `axis` is the linear direction or the circular rotation axis (world);
/// `totalAngle` is the circular first→last sweep in RADIANS.
nonisolated struct PatternSpec: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case linear, circular, curve }
    var kind: Kind
    var axis: SIMD3<Double>       // linear: direction; circular: rotation axis (world)
    /// Circular only: a point ON the rotation axis. Was implicitly the world
    /// origin before construction axes existed (spec §6.2), which is why it
    /// decodes to `.zero` when absent — every pattern written before this
    /// field spun about the origin, and must keep doing so.
    var center: SIMD3<Double>
    var count: Int                // TOTAL instances incl. the original (>=1)
    var spacing: Double           // linear: adjacent-center distance
    var totalAngle: Double        // circular: first->last sweep in RADIANS
    var rotateInstances: Bool
    /// M08: the associative construction axis a circular pattern spins about.
    /// When present, replay resolves that axis's CURRENT line through the
    /// document resolver and `axis`/`center` become only the last resolved
    /// cache — the same relationship a construction-plane consumer already
    /// keeps. Nil keeps every document written before this field byte-
    /// identical and keeps spinning about the stored absolute line.
    var axisRef: ConstructionAxisRef?
    var curvePath: CurvePatternPathDefinition?
    var featureSeed: PatternFeatureSeed?

    init(
        kind: Kind = .linear,
        axis: SIMD3<Double> = SIMD3(1, 0, 0),
        center: SIMD3<Double> = .zero,
        count: Int = 1,
        spacing: Double = 0,
        totalAngle: Double = 2 * .pi,
        rotateInstances: Bool = true,
        axisRef: ConstructionAxisRef? = nil,
        curvePath: CurvePatternPathDefinition? = nil,
        featureSeed: PatternFeatureSeed? = nil
    ) {
        self.kind = kind
        self.axis = axis
        self.center = center
        self.count = count
        self.spacing = spacing
        self.totalAngle = totalAngle
        self.rotateInstances = rotateInstances
        self.axisRef = axisRef
        self.curvePath = curvePath
        self.featureSeed = featureSeed
    }

    private enum CodingKeys: String, CodingKey {
        case kind, axis, center, count, spacing, totalAngle, rotateInstances, axisRef, curvePath, featureSeed
    }

    /// Hand-written because a synthesized `init(from:)` ignores property
    /// defaults: a stored spec with no `center` key would fail to decode
    /// outright, taking the whole feature node with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        axis = try c.decode(SIMD3<Double>.self, forKey: .axis)
        center = try c.decodeIfPresent(SIMD3<Double>.self, forKey: .center) ?? .zero
        count = try c.decode(Int.self, forKey: .count)
        spacing = try c.decode(Double.self, forKey: .spacing)
        totalAngle = try c.decode(Double.self, forKey: .totalAngle)
        rotateInstances = try c.decode(Bool.self, forKey: .rotateInstances)
        // A present but unreadable axis reference THROWS (Codable) rather than
        // silently dropping the relationship and leaving a decorative pattern.
        axisRef = try c.decodeIfPresent(ConstructionAxisRef.self, forKey: .axisRef)
        curvePath = try c.decodeIfPresent(CurvePatternPathDefinition.self, forKey: .curvePath)
        featureSeed = try c.decodeIfPresent(PatternFeatureSeed.self, forKey: .featureSeed)
    }

    func validate() throws {
        guard (1...10_000).contains(count), spacing.isFinite, (kind != .curve || spacing >= 0),
              totalAngle.isFinite, [axis, center].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              simd_length(axis) > 1e-9 else {
            throw SweepPathDefinition.Failure(message: "The pattern parameters are invalid.")
        }
        guard (kind == .curve) == (curvePath != nil), kind != .curve || axisRef == nil else {
            throw SweepPathDefinition.Failure(message: "A curve pattern needs its path and no separate axis.")
        }
        try curvePath?.validate()
        try featureSeed?.validate()
    }
}

/// The selected operation, never the whole already-modified body. Only
/// operations publishing a verified exact tool can supply a feature seed.
nonisolated struct PatternFeatureSeed: Codable, Hashable, Sendable {
    static var supportedVersion: Int { 1 }
    var version: Int = 1
    var featureID: FeatureID
    init(featureID: FeatureID) { self.featureID = featureID }
    func validate() throws {
        guard version == Self.supportedVersion else {
            throw AssociativeGeometryError.unsupportedSemanticVersion(version)
        }
    }
}

/// A Codable/Hashable wrapper around a 3D point so `FeatureKind.sweep`'s spine is
/// a plain `[PointWrapper]` (kept a struct so tranche-2 can extend it).
nonisolated struct PointWrapper: Codable, Hashable, Sendable {
    var point: SIMD3<Double>
    init(_ point: SIMD3<Double>) { self.point = point }
}

/// An EXACT helical spine for a sweep — threads, springs, wire inserts.
/// The sweep node still stores its sampled polyline `spine` (what the render
/// mesh follows and what a kernel without the spec would use); when this is
/// present the B-rep is swept along the true helix instead: a 2D line on a
/// cylindrical surface is an exact helix edge, so the wall is the true
/// helicoid and, by Pappus, the volume is section area × true helix length.
///
/// `referenceDirection` (perpendicular to the axis) is where angle 0 points,
/// so the caller's sampled polyline and the kernel's cylinder frame agree on
/// where the helix starts. Positive `pitch` rises along `axisDirection` per
/// turn, right-handed about it; negative pitch descends.
nonisolated struct HelixSpec: Codable, Hashable, Sendable {
    var axisPoint: SIMD3<Double>
    var axisDirection: SIMD3<Double>
    var referenceDirection: SIMD3<Double>
    var radius: Double
    var pitch: Double
    var turns: Double
    var startAngle: Double = 0
    /// Plane-local attachment captured when an existing helix radius is
    /// edited. Keeping the section at the OLD world position cancels the
    /// new pipe radius. This anchor moves only the evaluation frame, never
    /// the source sketch or its support relationship. Nil preserves legacy
    /// placement until a real radius edit establishes the attachment.
    var profileAnchor: SIMD3<Double>? = nil

    /// The helix point at angle `theta` (radians from `referenceDirection`).
    func point(at theta: Double) -> SIMD3<Double> {
        let n = simd_normalize(axisDirection)
        let x = simd_normalize(referenceDirection - simd_dot(referenceDirection, n) * n)
        let y = simd_cross(n, x)
        return axisPoint + (x * cos(theta) + y * sin(theta)) * radius + n * (pitch * theta / (2 * .pi))
    }

    /// The unit tangent at angle `theta`.
    func tangent(at theta: Double) -> SIMD3<Double> {
        let n = simd_normalize(axisDirection)
        let x = simd_normalize(referenceDirection - simd_dot(referenceDirection, n) * n)
        let y = simd_cross(n, x)
        return simd_normalize((-x * sin(theta) + y * cos(theta)) * radius + n * (pitch / (2 * .pi)))
    }

    /// Sampled polyline from `startAngle` over `turns`, `perTurn` chords each.
    ///
    /// This is the legacy convenience form: a request that would trap in
    /// `Int(turns × perTurn)` or allocate an unbounded buffer returns an empty
    /// path instead. Valid requests are byte-identical to the previous
    /// implementation. Callers that must explain a refusal use
    /// `checkedSampledSpine(perTurn:)` or `samplingError(perTurn:)`.
    func sampledSpine(
        perTurn: Int = HelixSamplingLimits.defaultSamplesPerTurn
    ) -> [SIMD3<Double>] {
        (try? checkedSampledSpine(perTurn: perTurn)) ?? []
    }

    /// The reason one sampling request is unsafe, or nil when it fits the
    /// explicit sampling budget. This validates every value and the
    /// `turns × perTurn` arithmetic BEFORE an `Int` conversion, buffer
    /// allocation or kernel call. It does not clamp or truncate anything.
    func samplingError(
        perTurn: Int = HelixSamplingLimits.defaultSamplesPerTurn
    ) -> HelixSamplingError? {
        guard Self.isFinite(axisPoint) else {
            return .invalid("helix.axisPoint must be finite.")
        }
        guard Self.isFinite(axisDirection) else {
            return .invalid("helix.axisDirection must be finite.")
        }
        let axisLength = simd_length(axisDirection)
        guard axisLength.isFinite, axisLength > 1e-9 else {
            return .invalid("helix.axisDirection must be non-zero.")
        }
        let n = simd_normalize(axisDirection)
        guard Self.isFinite(referenceDirection) else {
            return .invalid("helix.referenceDirection must be finite.")
        }
        let projected = referenceDirection - simd_dot(referenceDirection, n) * n
        let referenceLength = simd_length(projected)
        guard referenceLength.isFinite, referenceLength > 1e-9 else {
            return .invalid("helix.referenceDirection must not be parallel to axisDirection.")
        }
        guard radius.isFinite, radius > 0 else {
            return .invalid("helix.radius must be a finite positive number.")
        }
        guard turns.isFinite, turns > 0 else {
            return .invalid("helix.turns must be a finite positive number.")
        }
        guard pitch.isFinite, abs(pitch) > 1e-9 else {
            return .invalid("helix.pitch must be finite and non-zero.")
        }
        guard startAngle.isFinite else {
            return .invalid("helix.startAngle must be finite.")
        }
        if let profileAnchor, !Self.isFinite(profileAnchor) {
            return .invalid("helix.profileAnchor must be finite.")
        }
        guard perTurn > 0 else { return .invalidPerTurn }
        guard HelixSamplingLimits.checkedSegmentCount(turns: turns, perTurn: perTurn) != nil else {
            let requested = turns * Double(perTurn)
            return requested.isFinite
                ? .sampleLimit(requestedSegments: requested,
                               maximumSegments: HelixSamplingLimits.maximumSpineSegments)
                : .invalid("helix turns are too large to sample safely.")
        }
        // A modest segment count does not make a huge radius/pitch/axis point
        // safe: the point arithmetic below can still overflow a finite Double.
        // Bound the worst-case reach once, before generating any point.
        let sweepAngle = abs(startAngle) + 2 * Double.pi * turns
        let lift = abs(pitch) * sweepAngle / (2 * Double.pi)
        let reach = abs(radius) + lift
        let axisReach = max(abs(axisPoint.x), abs(axisPoint.y), abs(axisPoint.z))
        guard sweepAngle.isFinite, lift.isFinite, reach.isFinite, axisReach.isFinite,
              axisReach <= Double.greatestFiniteMagnitude - reach else {
            return .invalid("helix parameters overflow the coordinate range.")
        }
        return nil
    }

    /// Checked sampling. A valid request returns exactly the points the
    /// original `sampledSpine` expression produced (same chord count, angle
    /// expression and `point(at:)`). An invalid request throws before the
    /// `Int` conversion or `reserveCapacity`, and every generated point is
    /// checked for finiteness before it enters the returned buffer.
    func checkedSampledSpine(
        perTurn: Int = HelixSamplingLimits.defaultSamplesPerTurn
    ) throws -> [SIMD3<Double>] {
        if let error = samplingError(perTurn: perTurn) { throw error }
        guard let count = HelixSamplingLimits.checkedSegmentCount(
            turns: turns, perTurn: perTurn) else {
            throw HelixSamplingError.sampleLimit(
                requestedSegments: turns * Double(perTurn),
                maximumSegments: HelixSamplingLimits.maximumSpineSegments)
        }
        var points = [SIMD3<Double>]()
        points.reserveCapacity(count + 1)   // `count` is checked and bounded above.
        for i in 0...count {
            let point = self.point(
                at: startAngle + 2 * .pi * turns * Double(i) / Double(count))
            guard Self.isFinite(point) else { throw HelixSamplingError.nonFiniteSample }
            points.append(point)
        }
        return points
    }

    private static func isFinite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    /// True helix length: turns × √((2πr)² + pitch²).
    var length: Double { turns * ((2 * .pi * radius) * (2 * .pi * radius) + pitch * pitch).squareRoot() }
}

/// Why a helix sampling request was refused. The messages are agent-facing:
/// they name the invalid value or the exceeded budget and the next action.
nonisolated enum HelixSamplingError: Error, Equatable, Sendable {
    case invalid(String)
    case invalidPerTurn
    case sampleLimit(requestedSegments: Double, maximumSegments: Int)
    case nonFiniteSample

    var message: String {
        switch self {
        case .invalid(let reason):
            return reason
        case .invalidPerTurn:
            return "helix sampling needs a positive samples-per-turn count."
        case let .sampleLimit(requested, maximum):
            return "helix requests \(requested) sampled segments; the safety limit is "
                 + "\(maximum). Reduce turns or split the sweep."
        case .nonFiniteSample:
            return "helix sampling produced a non-finite point; check radius, pitch, "
                 + "turns and axis values."
        }
    }
}

/// Explicit safety bounds for a helix's generated polyline and swept render
/// mesh. These are NOT modelling tolerances, tessellation quality settings or a
/// clamp: a valid request keeps its requested radius/pitch/turns/start angle and
/// its exact analytic B-rep unchanged; a request outside the budget is refused
/// with an actionable message. ShapeScript's triangle cap, CADMeshService's
/// mesh-input cap and the presentation scene budget are different scopes and
/// are deliberately not reused here.
nonisolated enum HelixSamplingLimits {
    /// The existing parser density; callers that do not name a density have
    /// always used 36 chords per turn.
    static let defaultSamplesPerTurn = 36

    /// One generated spine may contain at most this many chords. At the
    /// default density that is ~2,777 turns; the qualified thread fixtures use
    /// 10 turns at 16 samples/turn. The sample buffer is therefore bounded at
    /// 100,001 points (~2.4 MB at 24 B/point) before any mesh exists.
    static let maximumSpineSegments = 100_000

    /// A swept render mesh emits one wall quad per (spine segment × profile or
    /// hole vertex). Capping that product at 250,000 quads (≈500,000 triangles
    /// before the two caps) bounds the intermediate `Euclid.Polygon` array to
    /// one body's share of the 8M-triangle presentation scene. The renderer
    /// budget alone does not bound these transient polygons, which carry their
    /// own vertices/planes and are built before the final mesh.
    static let maximumSweepMeshQuads = 250_000

    /// The checked chord count for one sampling request, or nil when the
    /// arithmetic is non-finite or the rounded result is outside
    /// `maximumSpineSegments`. No `Int` conversion occurs until the Double has
    /// been compared to the integer budget, so neither an out-of-range value
    /// nor a huge-but-representable value can trap or over-allocate.
    static func checkedSegmentCount(
        turns: Double,
        perTurn: Int,
        rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Int? {
        guard turns.isFinite, turns > 0, perTurn > 0 else { return nil }
        let scaled = turns * Double(perTurn)
        guard scaled.isFinite else { return nil }
        let rounded = scaled.rounded(rule)
        guard rounded.isFinite, rounded >= 0,
              rounded <= Double(maximumSpineSegments) else { return nil }
        // Preserve the legacy `max(1, ...)` floor for tiny positive requests.
        return max(1, Int(rounded))
    }

    /// Why a helix sweep's wall mesh does not fit
    /// `maximumSweepMeshQuads`, or nil when it fits. Division (not
    /// multiplication) keeps the check itself from overflowing.
    static func sweepMeshError(spinePointCount: Int, loopVertexCount: Int) -> String? {
        let segments = max(spinePointCount - 1, 0)
        guard loopVertexCount > 0 else { return nil }   // downstream reports empty geometry
        guard segments <= maximumSweepMeshQuads / loopVertexCount else {
            return "it would generate \(segments) × \(loopVertexCount) wall quads; "
                 + "the safety limit is \(maximumSweepMeshQuads). Reduce turns or use a "
                 + "simpler profile."
        }
        return nil
    }
}

// MARK: - Feature kinds / nodes / graph (frozen contract)

/// One editable operation in the history. Tranche 1 records/evaluates
/// `primitive`, `extrude`, `boolean`, `pushPull(.planarAxial)`; the rest are
/// defined for schema stability and evaluated in tranche 2.
nonisolated enum FeatureKind: Codable, Sendable {
    case primitive(spec: PrimitiveSpec, placement: Transform3D)
    /// Immutable exact root captured before editing a non-feature import.
    /// Stores the original once; downstream edits never use their own output
    /// as an implicit input. No model-authored source bytes are accepted.
    case baseSolid(source: NativeBodySource)
    case extrude(
        profile: ProfileRef,
        plane: PlaneRef,
        distance: Expr,
        symmetric: Bool,
        boolean: BooleanIntent,
        extraProfiles: [ProfileRef],
        termination: ExtrudeEndDefinition? = nil
    )
    /// Draft/taper extrude (playbook M1): the profile is lofted to an OFFSET
    /// copy of itself `distance` away, offset = tan(`taperAngle`)·distance, so
    /// the walls slope by the draft angle (cast/mould release). A distinct kind
    /// because it is a genuinely different construction — a loft between two
    /// sections, not a straight prism. `taperAngle` is degrees (converted at
    /// eval); a zero angle would be a plain extrude and is never recorded here.
    case draftExtrude(profile: ProfileRef, plane: PlaneRef, distance: Expr,
                      taperAngle: Expr, symmetric: Bool, boolean: BooleanIntent)
    case revolve(profile: ProfileRef, plane: PlaneRef, axis: AxisRef, angle: Expr, boolean: BooleanIntent)
    /// M12 mechanical hole: one locating circle in `profile` owns centre and
    /// pilot diameter; `spec` owns the typed depth/recess/cone and direction.
    /// The tool solid is the existing exact OCCT revolve of a small axial
    /// section, subtracted with the existing exact boolean. Never mesh.
    case hole(target: BodyRef, profile: ProfileRef, plane: PlaneRef, spec: HoleSpec)
    case thread(target: BodyRef, spec: ThreadSpec)
    /// `helix`, when present, is the EXACT spine the B-rep follows; `spine`
    /// stays the sampled polyline the render mesh sweeps along (and is what
    /// documents written before helices carried — they decode with `helix`
    /// absent, i.e. nil). See `HelixSpec`.
    case sweep(profile: ProfileRef, plane: PlaneRef, spine: [PointWrapper], boolean: BooleanIntent,
               helix: HelixSpec?, path: SweepPathDefinition? = nil)
    case loft(sections: [ProfileRef], boolean: BooleanIntent)
    case boolean(kind: BooleanKind, target: BodyRef, tools: [BodyRef])
    /// Two deterministic outputs. The first preserves target.bodyID and the
    /// second is minted once in outputBodyIDs, never during replay.
    case split(target: BodyRef, cutter: SplitCutterDefinition)
    case transform(body: BodyRef, delta: Transform3D)
    case mirror(body: BodyRef, plane: PlaneRef, keepOriginal: Bool)
    case pattern(body: BodyRef, spec: PatternSpec)
    case pushPull(face: FaceRef, distance: Expr, mode: PushPullMode)
    /// Spec §5 (face move): translate the referenced planar face by `delta`,
    /// deforming the solid (a lateral move shears it). `delta` is stored in the
    /// face's own basis — (u, v, n) along basisX / basisY / normal — so it is
    /// intrinsic to the face and replays correctly after an upstream edit.
    case moveFace(face: FaceRef, delta: PointWrapper)
    /// Spec §5 (face scale): uniformly scale the referenced planar face about its
    /// centre by `factor`, tapering the solid. Intrinsic (a pure ratio), so it
    /// replays against the re-resolved face after an upstream edit.
    case scaleFace(face: FaceRef, factor: Expr)
    /// Spec §5 (face rotate): rotate the referenced planar face by `angle`
    /// (radians) about a line through its centre. `axis` is stored in the face's
    /// own basis — (u, v, n) along basisX / basisY / normal — so it is intrinsic
    /// to the face and replays correctly after an upstream edit (an in-plane axis
    /// tilts the solid, the normal axis twists it).
    case rotateFace(face: FaceRef, angle: Expr, axis: PointWrapper)
    /// Draft (taper) an EXISTING face by `angle` degrees about the line where
    /// it meets the neutral plane — SOLIDWORKS' Draft, the "ALL DRAFT 5°" of a
    /// cast part. Positive narrows the body away from the neutral plane.
    /// Distinct from `draftExtrude`, which tapers as it CREATES the prism.
    case draftFace(face: FaceRef, neutralOrigin: PointWrapper,
                   neutralNormal: PointWrapper, angle: Expr,
                   planeReference: FeaturePlaneReference? = nil)
    /// Phase E: bevel the referenced convex edges of `body` by a flat `setback`.
    case chamfer(body: BodyRef, edges: [EdgeRef], setback: Expr)
    /// Phase E: round the referenced convex edges of `body` to `radius`.
    case fillet(body: BodyRef, edges: [EdgeRef], radius: Expr)
    /// Phase E: hollow `body` to a wall of `thickness`, cutting the referenced
    /// faces open (empty = fully enclosed hollow). Exact solids support flat
    /// and cylindrical openings; the mesh approximation remains planar.
    case shell(body: BodyRef, openFaces: [FaceRef], thickness: Expr)
    /// Spec §4.16: remove the referenced faces and HEAL the surrounding
    /// surfaces back together, deleting the feature (hole, pocket, boss) they
    /// belong to. B-rep only — a mesh has no surfaces to extend.
    case deleteFace(body: BodyRef, faces: [FaceRef])
    /// Replace Face (spec §4.12): extend or trim `face` until it lies on the
    /// plane given by `targetOrigin`/`targetNormal`, `flip` choosing which
    /// side when both readings are valid.
    ///
    /// Nil reference preserves the legacy absolute plane. A present reference
    /// follows its datum/sketch/named face and cannot fall back to these cached
    /// world coordinates after deletion, suppression or an invalid rebuild.
    case replaceFace(
        face: FaceRef, targetOrigin: PointWrapper, targetNormal: PointWrapper, flip: Bool,
        planeReference: FeaturePlaneReference? = nil)
}

nonisolated extension FeatureKind {
    var operationPlaneReference: FeaturePlaneReference? {
        switch self {
        case let .draftFace(_, _, _, _, reference), let .replaceFace(_, _, _, _, reference):
            return reference
        case let .split(_, cutter): return FeaturePlaneReference(source: .plane(cutter.plane))
        default: return nil
        }
    }
}

/// A node in the feature graph: stable identity, display name, its operation, a
/// suppress flag, and the `BodyID`s it owns (minted once, reused every rebuild).
nonisolated struct FeatureNode: Codable, Identifiable, Sendable {
    let id: FeatureID
    var name: String
    var kind: FeatureKind
    var suppressed: Bool
    var outputBodyIDs: [BodyID]

    init(
        id: FeatureID = FeatureID(),
        name: String,
        kind: FeatureKind,
        suppressed: Bool = false,
        outputBodyIDs: [BodyID]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.suppressed = suppressed
        self.outputBodyIDs = outputBodyIDs
    }
}

nonisolated extension FeatureNode {
    /// Every sketch this node reads — the union of its profile/extra-profile/loft-
    /// section `ProfileRef.sketchID`s, its `PlaneRef.sketch(sid)` build plane, and
    /// its `AxisRef.sketchLine(sid,_)` axis. `DocumentSession.rebuildForSketchChange`
    /// uses this to skip nodes a given sketch edit does not touch.
    var referencedSketchIDs: Set<SketchID> {
        var ids = Set<SketchID>()
        func addPlane(_ ref: PlaneRef) {
            if case let .sketch(sid) = ref.source { ids.insert(sid) }
        }
        func addAxis(_ ref: AxisRef) {
            if case let .sketchLine(sid, _) = ref.source { ids.insert(sid) }
        }
        switch kind {
        case let .extrude(profile, plane, _, _, _, extraProfiles, _):
            ids.insert(profile.sketchID)
            for extra in extraProfiles { ids.insert(extra.sketchID) }
            addPlane(plane)
        case let .draftExtrude(profile, plane, _, _, _, _):
            ids.insert(profile.sketchID)
            addPlane(plane)
        case let .revolve(profile, plane, axis, _, _):
            ids.insert(profile.sketchID)
            addPlane(plane)
            addAxis(axis)
        case let .hole(_, profile, plane, _):
            ids.insert(profile.sketchID)
            addPlane(plane)
        case let .sweep(profile, plane, _, _, _, path):
            ids.insert(profile.sketchID)
            for segment in path?.segments ?? [] { ids.insert(segment.sketchID) }
            addPlane(plane)
        case let .loft(sections, _):
            for ref in sections { ids.insert(ref.sketchID) }
        case let .mirror(_, plane, _):
            addPlane(plane)
        case let .pattern(_, spec):
            for segment in spec.curvePath?.segments ?? [] { ids.insert(segment.sketchID) }
        case let .split(_, cutter):
            addPlane(cutter.plane)
            if let profile = cutter.profile { ids.insert(profile.sketchID) }
        case .primitive, .baseSolid, .thread, .boolean, .transform, .pushPull, .moveFace,
             .scaleFace, .rotateFace, .draftFace, .chamfer, .fillet, .shell,
             .deleteFace, .replaceFace:
            break
        }
        if case let .plane(ref)? = kind.operationPlaneReference?.source { addPlane(ref) }
        return ids
    }

    /// Every construction plane this node builds on — the other sketch-side
    /// input a memo fingerprint must cover (docs/INCREMENTAL_EVAL_DESIGN.md).
    var referencedConstructionPlaneIDs: Set<ConstructionPlaneID> {
        var ids = Set<ConstructionPlaneID>()
        func add(_ ref: PlaneRef) {
            if case let .construction(cid) = ref.source { ids.insert(cid) }
        }
        switch kind {
        case let .extrude(_, plane, _, _, _, _, _), let .draftExtrude(_, plane, _, _, _, _),
             let .revolve(_, plane, _, _, _), let .sweep(_, plane, _, _, _, _),
             let .hole(_, _, plane, _), let .mirror(_, plane, _):
            add(plane)
        case let .split(_, cutter): add(cutter.plane)
        case .primitive, .baseSolid, .thread, .loft, .boolean, .transform, .pattern, .pushPull, .moveFace,
             .scaleFace, .rotateFace, .draftFace, .chamfer, .fillet, .shell,
             .deleteFace, .replaceFace:
            break
        }
        if case let .plane(ref)? = kind.operationPlaneReference?.source { add(ref) }
        return ids
    }

    /// Every construction axis this node consumes — the M08 consumer contract.
    /// A circular pattern stores the axis IDENTITY; the replay resolves its
    /// current line, so the consumer must be fingerprinted by that resolution.
    /// A revolve does the same (M08 R2): the kernel spins about the axis's
    /// CURRENT line projected into the revolve plane, so the node's memo entry
    /// must change when that resolution changes.
    var referencedConstructionAxisIDs: Set<ConstructionAxisID> {
        var ids = Set<ConstructionAxisID>()
        func add(_ ref: AxisRef) {
            if case let .constructionAxis(id) = ref.source { ids.insert(id) }
        }
        switch kind {
        case let .pattern(_, spec):
            if let ref = spec.axisRef { ids.insert(ref.axisID) }
        case let .revolve(_, _, axis, _, _):
            add(axis)
        default:
            break
        }
        return ids
    }

    /// Every body this node CONSUMES, read straight off its refs — the
    /// identity layer the memoised replay stamps. A node whose output could
    /// depend on a body NOT listed here must add it, or be evaluated uncached;
    /// the memo is only as correct as this enumeration.
    var consumedBodyIDs: [BodyID] {
        switch kind {
        case .primitive, .baseSolid:
            return []
        case let .extrude(_, _, _, _, boolean, _, termination):
            return Array(Set(boolean.resolvedTargets.map(\.bodyID) + (termination?.targets.map(\.bodyID) ?? [])))
        case let .draftExtrude(_, _, _, _, _, boolean),
             let .revolve(_, _, _, _, boolean), let .sweep(_, _, _, boolean, _, _),
             let .loft(_, boolean):
            return boolean.resolvedTargets.map(\.bodyID)
        case let .boolean(_, target, tools):
            return [target.bodyID] + tools.map(\.bodyID)
        case let .hole(target, _, _, _), let .thread(target, _):
            return [target.bodyID]
        case let .split(target, _): return [target.bodyID]
        case let .transform(body, _), let .mirror(body, _, _), let .pattern(body, _),
             let .chamfer(body, _, _), let .fillet(body, _, _), let .shell(body, _, _),
             let .deleteFace(body, _):
            return [body.bodyID]
        case let .pushPull(face, _, _), let .moveFace(face, _), let .scaleFace(face, _),
             let .rotateFace(face, _, _), let .draftFace(face, _, _, _, _),
             let .replaceFace(face, _, _, _, _):
            return [face.body.bodyID]
        }
    }
}

/// The ordered feature history. `evaluate` is a pure function of the graph plus
/// the sketches/planes the profiles/planes reference.
nonisolated struct FeatureGraph: Codable, Sendable {
    var nodes: [FeatureNode]
    /// Rollback marker: the number of ACTIVE (leading) nodes. `nil` = every node
    /// active; `k` = `nodes[0..<k]` active, nodes at/after `k` rolled back (not
    /// evaluated → their bodies are removed). Synthesized Codable decodes this via
    /// `decodeIfPresent`, so pre-rollback blobs load with `rollbackIndex == nil`.
    var rollbackIndex: Int? = nil

    init(nodes: [FeatureNode] = [], rollbackIndex: Int? = nil) {
        self.nodes = nodes
        self.rollbackIndex = rollbackIndex
    }

    /// The node with `id`, if present.
    func node(_ id: FeatureID) -> FeatureNode? {
        nodes.first { $0.id == id }
    }

    /// Index of the node with `id`, if present.
    func index(of id: FeatureID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }
}

// MARK: - Evaluation result

/// Why a node failed to build. `evaluate` records these per node and keeps
/// going; a failed node simply emits no geometry (the graph stays total).
nonisolated enum FeatureError: Sendable, Equatable {
    /// A referenced body / profile / plane / face could not be resolved.
    case brokenRef(String)
    /// The operation ran but produced an empty mesh.
    case emptyGeometry
    /// The kernel op failed or is not implemented in this tranche.
    case kernelFailure(String)
}

/// The output of replaying a `FeatureGraph`: the live bodies (in creation order),
/// their face tables, and any per-node errors.
nonisolated struct EvalResult: Sendable {
    var bodies: [Body]
    var faceTables: [BodyID: FaceTable]
    /// Per-body kernel-face name maps (step 3/4) — retained by
    /// `DocumentSession` so live picks can mint edge identities.
    var kernelNames: [BodyID: [Int: ElementName]]
    /// Step 5b: kinds whose legacy refs earned names this replay. Advisory —
    /// only `performRebuild` acts on them, inside its own undo step.
    var proposedUpgrades: [FeatureID: FeatureKind]
    var errors: [FeatureID: FeatureError]
    /// Pure derived-coordinate proposals; only the rebuild transaction applies them.
    var resolvedPlaneUpdates: [ConstructionPlaneID: SketchPlane]
    var resolvedSketchSupportUpdates: [SketchID: SketchPlane]
    /// M08 derived-coordinate proposals for associative axes and datum points.
    /// Display caches only; the definition stays the source of truth.
    var resolvedAxisUpdates: [ConstructionAxisID: ResolvedAxisGeometry]
    var resolvedDatumPointUpdates: [DatumPointID: ResolvedDatumPointGeometry]
    /// M05: re-projected external entities per sketch; applied set-by-id by
    /// the rebuild transaction, never written mid-replay.
    var resolvedSketchEntityUpdates: [SketchID: [SketchEntity]]
    var referenceErrors: [AssociativeReferenceKey: AssociativeReferenceError]
    /// Actual successful live PUT writers; independent of BodyRef provenance.
    var lastBodyWriters: [BodyID: FeatureID]
    /// Only requested historical versions (including every datum source).
    var geometryVersions: [GeometryVersionRef: GeometryVersionSnapshot]
    /// Derived cache proposals; only the owning rebuild transaction writes
    /// these values, alongside its geometry and the original semantic edit.
    var resolvedExtrudeDistances: [FeatureID: Double]

    init(
        bodies: [Body] = [],
        faceTables: [BodyID: FaceTable] = [:],
        kernelNames: [BodyID: [Int: ElementName]] = [:],
        proposedUpgrades: [FeatureID: FeatureKind] = [:],
        errors: [FeatureID: FeatureError] = [:],
        resolvedPlaneUpdates: [ConstructionPlaneID: SketchPlane] = [:],
        resolvedSketchSupportUpdates: [SketchID: SketchPlane] = [:],
        resolvedAxisUpdates: [ConstructionAxisID: ResolvedAxisGeometry] = [:],
        resolvedDatumPointUpdates: [DatumPointID: ResolvedDatumPointGeometry] = [:],
        resolvedSketchEntityUpdates: [SketchID: [SketchEntity]] = [:],
        referenceErrors: [AssociativeReferenceKey: AssociativeReferenceError] = [:],
        lastBodyWriters: [BodyID: FeatureID] = [:],
        geometryVersions: [GeometryVersionRef: GeometryVersionSnapshot] = [:],
        resolvedExtrudeDistances: [FeatureID: Double] = [:]
    ) {
        self.bodies = bodies
        self.faceTables = faceTables
        self.kernelNames = kernelNames
        self.proposedUpgrades = proposedUpgrades
        self.errors = errors
        self.resolvedPlaneUpdates = resolvedPlaneUpdates
        self.resolvedSketchSupportUpdates = resolvedSketchSupportUpdates
        self.resolvedAxisUpdates = resolvedAxisUpdates
        self.resolvedDatumPointUpdates = resolvedDatumPointUpdates
        self.resolvedSketchEntityUpdates = resolvedSketchEntityUpdates
        self.referenceErrors = referenceErrors
        self.lastBodyWriters = lastBodyWriters
        self.geometryVersions = geometryVersions
        self.resolvedExtrudeDistances = resolvedExtrudeDistances
    }
}

// MARK: - The replay engine

nonisolated extension FeatureGraph {

    /// Replay-side guard for an operation that needs a closed solid. Imported
    /// open surfaces are not graph inputs today (replay builds bodies from
    /// feature nodes, not document bodies), but a future seeded or
    /// surface-producing node must never fall into the legacy Euclid mesh
    /// fallbacks: those would consume the exact sheet and emit a mesh-only
    /// body. Recording the error leaves the input body in `state` untouched
    /// and the graph total; no history is changed by replay itself.
    private func refuseExactSurface(_ node: FeatureNode, _ operation: String,
                                    body: Body, into state: inout EvalState) -> Bool {
        guard body.surfaceBRep != nil else { return false }
        state.errors[node.id] = .kernelFailure(
            ExactSurfaceBoundary.refusal(operation, bodyName: body.name))
        return true
    }

    /// Replay every non-suppressed node in order, building the document geometry.
    ///
    /// - Parameters:
    ///   - sketches: sketches the `ProfileRef`/`PlaneRef`s resolve against.
    ///   - planes: construction planes a `PlaneRef.construction` resolves against.
    ///   - naming: the topological-naming strategy (labels faces, propagates
    ///     labels through booleans/push-pull, re-resolves persisted `FaceRef`s).
    ///   - nextRevision: mints a monotonically fresh `meshRevision` per emitted
    ///     body so the GPU/render caches invalidate.
    func evaluate(
        sketches: [Sketch],
        planes: [ConstructionPlane],
        naming: TopoNaming,
        variables: [String: Double] = [:],
        requestedVersions: Set<GeometryVersionRef> = [],
        axes: [ConstructionAxis] = [],
        datumPoints: [DatumPoint] = [],
        nextRevision: () -> UInt64
    ) -> EvalResult {
        // Uncached: every node runs. The behaviour from before the memo, and
        // what the pure-value tests and any caller that has not opted into a
        // cache get.
        var scratch = EvalCache()
        return evaluate(sketches: sketches, planes: planes, naming: naming,
                        nextRevision: nextRevision, cache: &scratch,
                        variables: variables, requestedVersions: requestedVersions,
                        axes: axes, datumPoints: datumPoints)
    }

    /// Memoised replay (docs/INCREMENTAL_EVAL_DESIGN.md).
    ///
    /// Each node is fingerprinted from its inputs — its kind, the sketches and
    /// construction planes it references, and the STAMPS of the bodies it
    /// consumes (a stamp is the fingerprint of the node that last put that
    /// body, so the chain is Merkle-like and never leans on `meshRevision`).
    /// A node whose fingerprint matches `cache` is spliced back in by
    /// re-applying its recorded delta — no kernel work, and its bodies keep
    /// their revisions, so nothing downstream (the GPU included) rebuilds.
    /// Everything else runs exactly as before and is journaled for next time.
    /// `cache` is rewritten to describe THIS replay, which prunes nodes that
    /// left the graph for free.
    func evaluate(
        sketches: [Sketch],
        planes: [ConstructionPlane],
        naming: TopoNaming,
        nextRevision: () -> UInt64,
        cache: inout EvalCache,
        variables: [String: Double] = [:],
        requestedVersions: Set<GeometryVersionRef> = [],
        axes: [ConstructionAxis] = [],
        datumPoints: [DatumPoint] = []
    ) -> EvalResult {
        var state = EvalState(
            sketches: sketches, planes: planes, naming: naming,
            associative: AssociativeGeometryResolver(
                graph: self, sketches: sketches, planes: planes,
                axes: axes, datumPoints: datumPoints,
                variables: variables, requestedVersions: requestedVersions))
        // Input hashes once per replay, not once per node.
        let sketchHash = Dictionary(sketches.map { ($0.id, EvalFingerprint.hash($0)) },
                                    uniquingKeysWith: { first, _ in first })
        let planeHash = Dictionary(planes.map { ($0.id, EvalFingerprint.hash($0)) },
                                   uniquingKeysWith: { first, _ in first })
        let axisHash = Dictionary(axes.map { ($0.id, EvalFingerprint.hash($0)) },
                                  uniquingKeysWith: { first, _ in first })
        var next = EvalCache()

        // Replay only the active prefix: nodes at/after the rollback marker are not
        // evaluated (their bodies never enter the live set). `prefix` clamps to the
        // node count, so an out-of-range marker is safe. `nil` = all nodes active.
        state.threadVariables = variables
        state.requestedFeatureTools = Set(nodes.prefix(rollbackIndex ?? nodes.count).compactMap { node in
            guard !node.suppressed, case let .pattern(_, spec) = node.kind else { return nil }
            return spec.featureSeed?.featureID
        })
        var toolContext = EvalFingerprint()
        for id in state.requestedFeatureTools.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            toolContext.combine(Data(id.raw.uuidString.utf8))
        }
        for node in nodes.prefix(rollbackIndex ?? nodes.count) where !node.suppressed {
            state.associative.begin(node)
            let prepared = state.associative.prepare(node)
            let fingerprint = Self.fingerprint(
                of: node, sketchHash: sketchHash, planeHash: planeHash,
                axisHash: axisHash, stamps: state.stamps,
                resolvedSketchHash: prepared.sketches, resolvedPlaneHash: prepared.planes,
                resolvedAxisHash: prepared.axes, operationPlaneStamp: prepared.operationPlaneStamp,
                variables: variables, publishTool: state.requestedFeatureTools.contains(node.id),
                toolContext: toolContext.value)
            let delta: EvalNodeDelta
            if let hit = cache.entries[node.id], hit.fingerprint == fingerprint {
                state.apply(hit.delta, for: node.id)
                delta = hit.delta
                next.lastSkipped += 1
            } else {
                state.currentNode = node.id
                state.journal[node.id] = EvalNodeDelta()
                if let error = prepared.error {
                    state.errors[node.id] = .brokenRef(error.message)
                } else {
                    evaluate(node, operationPlane: prepared.operationPlane?.plane,
                             into: &state, nextRevision: nextRevision)
                }
                state.currentNode = nil
                var recorded = state.journal[node.id] ?? EvalNodeDelta()
                // Ops write kernel-face names AFTER their put; capture each
                // body's final map now that the node is done.
                recorded.ops = recorded.ops.map { op in
                    guard case let .put(body, table, _) = op else { return op }
                    return .put(body, table, kernelNames: state.kernelNames[body.id])
                }
                recorded.error = state.errors[node.id]
                if recorded.error != nil { recorded.featureTools = [:] }
                delta = recorded
                next.lastRan += 1
            }
            next.entries[node.id] = EvalCacheEntry(fingerprint: fingerprint, delta: delta)
            state.associative.finish(node, delta: delta, stamp: fingerprint)
            // Whatever this node put now carries its fingerprint as its stamp;
            // whatever it consumed loses one.
            for op in delta.ops {
                switch op {
                case let .put(body, _, _): state.stamps[body.id] = fingerprint
                case let .remove(id): state.stamps[id] = nil
                }
            }
        }
        cache = next
        state.associative.finishDisplayReferences()

        return EvalResult(
            bodies: state.order.compactMap { state.bodies[$0] },
            faceTables: state.faceTables,
            kernelNames: state.kernelNames,
            // A signature seen before a failed kernel operation did not earn
            // a persistent identity. Apply this to every face/edge consumer,
            // including the older operations that propose before execution.
            proposedUpgrades: state.proposedUpgrades.filter { state.errors[$0.key] == nil },
            errors: state.errors,
            resolvedPlaneUpdates: state.associative.resolvedPlaneUpdates,
            resolvedSketchSupportUpdates: state.associative.resolvedSketchSupportUpdates,
            resolvedAxisUpdates: state.associative.resolvedAxisUpdates,
            resolvedDatumPointUpdates: state.associative.resolvedDatumPointUpdates,
            resolvedSketchEntityUpdates: state.associative.resolvedSketchEntityUpdates,
            referenceErrors: state.associative.referenceErrors,
            lastBodyWriters: state.associative.lastBodyWriters,
            geometryVersions: state.associative.snapshots,
            resolvedExtrudeDistances: state.resolvedExtrudeDistances
        )
    }

    /// The memo key for `node` at this point of the replay.
    private static func fingerprint(
        of node: FeatureNode,
        sketchHash: [SketchID: UInt64],
        planeHash: [ConstructionPlaneID: UInt64],
        axisHash: [ConstructionAxisID: UInt64],
        stamps: [BodyID: UInt64],
        resolvedSketchHash: [SketchID: UInt64],
        resolvedPlaneHash: [ConstructionPlaneID: UInt64],
        resolvedAxisHash: [ConstructionAxisID: UInt64],
        operationPlaneStamp: UInt64?,
        variables: [String: Double], publishTool: Bool, toolContext: UInt64
    ) -> UInt64 {
        var f = EvalFingerprint()
        f.combine(publishTool ? 1 : 0)
        f.combine(toolContext)
        let semanticKind: FeatureKind
        if case let .extrude(profile, plane, _, symmetric, boolean, extras, termination?) = node.kind {
            semanticKind = .extrude(profile: profile, plane: plane, distance: Expr(value: 0),
                symmetric: symmetric, boolean: boolean, extraProfiles: extras, termination: termination)
        } else { semanticKind = node.kind }
        if case let .baseSolid(source) = semanticKind {
            // Do not base64 encode/hash an immutable multi-megabyte BRep on
            // every mouse move. Its verified digest is the content identity.
            f.combine(Data(source.sha256.utf8))
            f.combine(Data(source.faceWitnessSHA256.utf8))
            f.combine(Data(source.name.utf8))
            f.combine(UInt64(source.version))
            f.combine(EvalFingerprint.hash(source.placement))
        } else if let kind = EvalFingerprint.json(semanticKind) {
            f.combine(kind)
        } else {
            // An unencodable kind (a non-finite parameter): salt so it never
            // falsely matches — it re-runs every replay, exactly as before.
            f.combine(UInt64.random(in: .min ... .max))
        }
        if case .thread = node.kind {
            for key in variables.keys.sorted() {
                f.combine(Data(key.utf8)); f.combine(EvalFingerprint.hash(variables[key]))
            }
        }
        for sid in node.referencedSketchIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            f.combine(resolvedSketchHash[sid] ?? sketchHash[sid] ?? 0)
        }
        for cid in node.referencedConstructionPlaneIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            f.combine(resolvedPlaneHash[cid] ?? planeHash[cid] ?? 0)
        }
        for aid in node.referencedConstructionAxisIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            f.combine(resolvedAxisHash[aid] ?? axisHash[aid] ?? 0)
        }
        for bid in node.consumedBodyIDs.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            f.combine(stamps[bid] ?? 0)
        }
        if let operationPlaneStamp { f.combine(operationPlaneStamp) }
        return f.value
    }

    // MARK: Per-node dispatch

    private func evaluate(
        _ node: FeatureNode,
        operationPlane: SketchPlane?,
        into state: inout EvalState,
        nextRevision: () -> UInt64
    ) {
        let localOperationPlane: SketchPlane?
        if let operationPlane {
            guard let bodyID = node.consumedBodyIDs.first, let body = state.bodies[bodyID],
                  body.transform.scale.isFinite, body.transform.scale > 1e-12 else {
                state.errors[node.id] = .brokenRef("The edit body or its placement is unavailable.")
                return
            }
            let inverseRotation = body.transform.rotation.inverse
            localOperationPlane = SketchPlane(
                origin: inverseRotation.act(operationPlane.origin - body.transform.translation) / body.transform.scale,
                xAxis: inverseRotation.act(operationPlane.xAxis),
                yAxis: inverseRotation.act(operationPlane.yAxis))
        } else { localOperationPlane = nil }
        switch node.kind {
        case let .baseSolid(source):
            evalBaseSolid(node, source: source, into: &state, next: nextRevision)
        case let .primitive(spec, placement):
            evalPrimitive(node, spec: spec, placement: placement, into: &state, next: nextRevision)
        case let .extrude(profile, plane, distance, symmetric, boolean, extraProfiles, termination):
            evalExtrude(
                node, profileRef: profile, planeRef: plane, distance: distance,
                symmetric: symmetric, boolean: boolean, extraProfileRefs: extraProfiles, termination: termination,
                into: &state, next: nextRevision)
        case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean):
            evalDraftExtrude(
                node, profileRef: profile, planeRef: plane, distance: distance,
                taperAngle: taperAngle, symmetric: symmetric, boolean: boolean,
                into: &state, next: nextRevision)
        case let .boolean(kind, target, tools):
            evalBoolean(node, kind: kind, target: target, tools: tools, into: &state, next: nextRevision)
        case let .split(target, cutter):
            evalSplit(node, target: target, cutter: cutter, plane: operationPlane,
                      into: &state, next: nextRevision)
        case let .pushPull(face, distance, mode):
            evalPushPull(node, face: face, distance: distance, mode: mode, into: &state, next: nextRevision)
        case let .moveFace(face, delta):
            evalMoveFace(node, face: face, delta: delta.point, into: &state, next: nextRevision)
        case let .scaleFace(face, factor):
            evalScaleFace(node, face: face, factor: factor.value, into: &state, next: nextRevision)
        case let .rotateFace(face, angle, axis):
            evalRotateFace(node, face: face, angle: angle.value, axis: axis.point,
                           into: &state, next: nextRevision)
        case let .draftFace(face, neutralOrigin, neutralNormal, angle, _):
            evalDraftFace(node, face: face, neutralOrigin: localOperationPlane?.origin ?? neutralOrigin.point,
                          neutralNormal: localOperationPlane?.normal ?? neutralNormal.point, degrees: angle.value,
                          into: &state, next: nextRevision)
        case let .revolve(profile, plane, axis, angle, boolean):
            evalRevolve(
                node, profileRef: profile, planeRef: plane, axisRef: axis,
                angle: angle, boolean: boolean, into: &state, next: nextRevision)
        case let .hole(target, profile, plane, spec):
            evalHole(
                node, targetRef: target, profileRef: profile, planeRef: plane,
                spec: spec, into: &state, next: nextRevision)
        case let .thread(target, spec):
            evalThread(node, target: target, spec: spec, into: &state, next: nextRevision)
        case let .sweep(profile, plane, spine, boolean, helix, path):
            evalSweep(
                node, profileRef: profile, planeRef: plane, spine: spine,
                boolean: boolean, helix: helix, path: path, into: &state, next: nextRevision)
        case let .loft(sections, boolean):
            evalLoft(node, sectionRefs: sections, boolean: boolean, into: &state, next: nextRevision)
        case let .mirror(body, plane, keepOriginal):
            evalMirror(
                node, bodyRef: body, planeRef: plane, keepOriginal: keepOriginal,
                into: &state, next: nextRevision)
        case let .pattern(body, spec):
            evalPattern(node, bodyRef: body, spec: spec, into: &state, next: nextRevision)
        case let .chamfer(body, edges, setback):
            evalEdgeBlend(
                node, bodyRef: body, edgeRefs: edges, amount: setback.value,
                isFillet: false, into: &state, next: nextRevision)
        case let .fillet(body, edges, radius):
            evalEdgeBlend(
                node, bodyRef: body, edgeRefs: edges, amount: radius.value,
                isFillet: true, into: &state, next: nextRevision)
        case let .shell(body, openFaces, thickness):
            evalShell(
                node, bodyRef: body, openFaceRefs: openFaces,
                thickness: thickness.value, into: &state, next: nextRevision)
        case let .deleteFace(body, faces):
            evalDeleteFace(
                node, bodyRef: body, faceRefs: faces, into: &state, next: nextRevision)
        case let .replaceFace(face, targetOrigin, targetNormal, flip, _):
            evalReplaceFace(
                node, faceRef: face, targetOrigin: localOperationPlane?.origin ?? targetOrigin.point,
                targetNormal: localOperationPlane?.normal ?? targetNormal.point, flip: flip,
                into: &state, next: nextRevision)

        case let .transform(body, delta):
            evalTransform(node, bodyRef: body, delta: delta, into: &state, next: nextRevision)
        }
    }

    private func evalThread(_ node: FeatureNode, target targetRef: BodyRef, spec authored: ThreadSpec,
                            into state: inout EvalState, next: () -> UInt64) {
        do {
            let spec = try authored.resolved(variables: state.threadVariables)
            guard targetRef.bodyID == spec.sourceVersion.bodyID,
                  let target = state.bodies[targetRef.bodyID], let brep = target.brep,
                  target.surfaceBRep == nil,
                  let worldTarget = OCCTKernel.transformed(brep, by: target.transform) else {
                throw CADThreadError.invalid("A thread needs its original exact solid source.")
            }
            let cylinder = try state.associative.threadCylinder(spec)
            let result = try ThreadKit.apply(spec, cylinder: cylinder, target: worldTarget,
                targetNames: state.kernelNames[target.id] ?? [:], operation: node.id)
            if spec.representation == .schematic {
                // An annotation must preserve authored UVs, material bindings,
                // the exact handle, placement and render bytes verbatim.
                let names = state.kernelNames[target.id] ?? [:]
                let table = state.faceTables[target.id]
                    ?? state.naming.faceTable(for: target, createdBy: targetRef.producer, scheme: .generic)
                state.put(target, table: table)
                if !names.isEmpty { state.kernelNames[target.id] = names }
                return
            }
            var body = Body(id: target.id, name: target.name, transform: .identity,
                primitive: nil, euclidMesh: Euclid.Mesh([]), revision: next())
            guard body.adoptBRep(result.shape) else { throw CADThreadError.invalid("Thread geometry could not be read.") }
            var table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .generic)
            if !result.names.isEmpty {
                table = ElementNaming.attach(result.names, to: table,
                    channel: OCCTKernel.renderMeshFaceChannel(from: result.shape), body: body)
            }
            state.put(body, table: table)
            if !result.names.isEmpty { state.kernelNames[body.id] = result.names }
        } catch { state.errors[node.id] = .kernelFailure("thread: \(error.localizedDescription)") }
    }

    // MARK: Transform

    /// Moves a body IN PLACE: the delta (rotation, uniform scale, translation)
    /// is composed onto its placement, the geometry stays body-local (no
    /// kernel call — the analytic solid and its element names survive,
    /// exactly as a pattern instance's do) and the body keeps its id, so
    /// everything downstream that referenced it still resolves. Rotation and
    /// scale are about the world origin; "about a point" is folded into the
    /// delta by the caller (T·R·T⁻¹, see `parseTransform`).
    private func evalTransform(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        delta: Transform3D,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let input = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("transform body unresolved")
            return
        }
        guard delta.scale > 1e-12 else {
            state.errors[node.id] = .kernelFailure("transform: scale must be positive (\(delta.scale))")
            return
        }
        var body = input
        // Scale rides in the placement too: the renderer's matrix, the B-rep
        // placement (`OCCTKernel.transformed`, a uniform-scale gp_Trsf) and
        // the volume (cubic) all honour `transform.scale` already.
        body.transform = delta.composed(onto: input.transform)
        // A new revision even though the local mesh is unchanged: the session
        // skips replacing a body whose revision did not move, and this one did.
        body.meshRevision = nextRevision()
        let names = state.kernelNames[input.id]
        let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .generic)
        state.put(body, table: table)
        // An isometry keeps every face: the names carry over unchanged.
        if let names, !names.isEmpty {
            state.kernelNames[input.id] = names
        }
        // Keep an upstream feature's exact tool in the same world frame as
        // its target, including cached transform steps and uniform scale.
        for (feature, var tool) in state.featureTools where tool.targetBodyID == input.id {
            tool.body.transform = delta.composed(onto: tool.body.transform)
            state.featureTools[feature] = tool
            state.journal[node.id, default: EvalNodeDelta()].featureTools[feature] = tool
        }
    }

    // MARK: Primitive

    private func evalBaseSolid(_ node: FeatureNode, source: NativeBodySource,
                               into state: inout EvalState, next: () -> UInt64) {
        guard node.outputBodyIDs.count == 1, let id = node.outputBodyIDs.first else {
            state.errors[node.id] = .brokenRef("An exact source must own one body.")
            return
        }
        do {
            let body = try source.restoredBody(id: id, revision: next())
            guard let solid = body.brep else { throw KernelOps.ExactEditError.refused }
            let names = Dictionary(uniqueKeysWithValues: OCCTKernel.faceInfo(solid).map {
                ($0.index, ElementName(creator: node.id,
                    source: .immutableSourceFace(version: 1, sha256: source.sha256, index: $0.index)))
            })
            let table = ElementNaming.attach(names,
                to: state.naming.faceTable(for: body, createdBy: node.id, scheme: .generic),
                channel: OCCTKernel.renderMeshFaceChannel(from: solid), body: body)
            state.put(body, table: table)
            state.kernelNames[id] = names
        } catch { state.errors[node.id] = .kernelFailure(error.localizedDescription) }
    }

    private func evalPrimitive(
        _ node: FeatureNode,
        spec: PrimitiveSpec,
        placement: Transform3D,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let id = node.outputBodyIDs.first else {
            state.errors[node.id] = .brokenRef("primitive node has no output BodyID")
            return
        }
        // Same path the app uses (Euclid.Mesh.primitive), then bake the placement
        // so body-local space == the coordinate space every downstream op (and the
        // face signatures) works in. Body transform stays identity in tranche 1.
        var mesh = Euclid.Mesh.primitive(spec)
        if placement != .identity {
            mesh = mesh.transformed(by: placement.euclid)
        }
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        var body = Body(
            id: id, name: node.name, transform: .identity,
            primitive: placement == .identity ? spec : nil,
            euclidMesh: mesh, revision: nextRevision())
        // Give primitives an analytic B-rep too, so booleans that mix a primitive
        // with a cylinder stay analytic (and round). Only CURVED primitives take
        // the OCCT render mesh — a box looks identical either way, so it keeps the
        // Euclid render and existing coverage is unperturbed.
        var adoptedHandle: BRepHandle?
        var boxFaces: OCCTKernel.PrimitiveBoxFaceIndices?
        if OCCTKernel.useOCCTAsSourceOfTruth,
           let built = OCCTKernel.primitiveShapeWithBoxFaces(spec, placement: placement) {
            if OCCTKernel.hasCurvedFaces(spec) {
                // Curved primitive: OCCT owns render AND CSG (one tessellation).
                if body.adoptBRep(built.handle) { adoptedHandle = built.handle }
            } else {
                // A box looks identical either way — keep the Euclid mesh it was
                // built with, but still carry the brep so booleans stay analytic.
                body.brep = built.handle
                boxFaces = built.boxFaces
            }
        }
        // A primitive's role IS its identity, so its entries are named
        // outright — no kernel channel needed, which also covers the box's
        // deliberately-Euclid render (TOPO_NAMING_HISTORY_DESIGN step 2).
        let table = ElementNaming.namePrimitiveEntries(
            state.naming.faceTable(for: body, createdBy: node.id,
                                   scheme: .primitive(spec)),
            creator: node.id)
        state.put(body, table: table)
        // The composable layer booleans inherit through. Curved primitives
        // recover it through the tessellation channel because their render IS
        // the OCCT mesh. The box keeps its Euclid render, so its map comes
        // from the kernel's OWN named construction faces of the same handle
        // (never Euclid entry/triangle indices or face ordinals).
        //
        // The named-association identity is LOCAL construction. The render
        // roles for cylinder caps and box faces are chosen in the BAKED
        // world frame, so a non-identity baked rotation can relabel them.
        // Refuse the exact kernel map for every primitive in that case
        // (display roles stay); translation and positive uniform scale keep
        // the construction axes intact and stay supported.
        if Self.primitivePlacementKeepsLocalRoles(placement) {
            if let adoptedHandle {
                state.kernelNames[body.id] = ElementNaming.kernelNames(
                    from: table,
                    channel: OCCTKernel.renderMeshFaceChannel(from: adoptedHandle))
            } else if let boxFaces {
                state.kernelNames[body.id] = Self.primitiveBoxKernelNames(
                    table: table, faces: boxFaces)
            }
        }
    }

    /// A primitive's named roles are LOCAL construction identities (a box's
    /// `boxFace(.px)` is its XMax face; a cylinder's cap `top` is its +Y
    /// construction cap). `SignatureNaming.rolesForBox`/`rolesForCylinder`
    /// derive render-side roles in the BAKED world frame, so a baked rotation
    /// can relabel the same face relative to its construction identity.
    /// Rotation therefore refuses name association entirely rather than
    /// inventing a mapping; translation and a positive uniform scale leave
    /// every construction axis intact and are safe.
    private static func primitivePlacementKeepsLocalRoles(_ placement: Transform3D) -> Bool {
        guard placement.scale.isFinite, placement.scale > 0 else { return false }
        let q = placement.rotation
        guard abs(simd_length(q) - 1) <= 1e-9 else { return false }
        return abs(abs(q.real) - 1) <= 1e-12
            && abs(q.imag.x) <= 1e-12
            && abs(q.imag.y) <= 1e-12
            && abs(q.imag.z) <= 1e-12
    }

    /// Map the box's exact construction-face indices to the names the render
    /// table already minted for those same roles. No geometry is compared here:
    /// the kernel face index comes from `BRepPrimAPI_MakeBox`'s named faces,
    /// and the role→name comes from ElementNaming. A partial or contradictory
    /// claim yields no map at all, so the resolver refuses instead of guessing.
    private static func primitiveBoxKernelNames(
        table: FaceTable,
        faces: OCCTKernel.PrimitiveBoxFaceIndices
    ) -> [Int: ElementName] {
        let indexByRole: [BoxFace: Int] = [
            .nx: faces.xMin, .px: faces.xMax,
            .ny: faces.yMin, .py: faces.yMax,
            .nz: faces.zMin, .pz: faces.zMax
        ]
        var namesByRole: [BoxFace: ElementName] = [:]
        for entry in table.entries {
            guard let name = entry.elementName,
                  case let .primitiveFace(.boxFace(role)) = name.source else { continue }
            if let existing = namesByRole[role], existing != name { return [:] }
            namesByRole[role] = name
        }
        var out: [Int: ElementName] = [:]
        var namesByFace: [Int: ElementName] = [:]
        for (role, name) in namesByRole {
            guard let index = indexByRole[role] else { return [:] }
            if let existing = namesByFace[index], existing != name { return [:] }
            namesByFace[index] = name
            out[index] = name
        }
        // A valid box has exactly six planar faces, one per role. Anything
        // less means the table or the construction metadata is incomplete.
        guard out.count == 6, Set(out.values).count == 6 else { return [:] }
        return out
    }

    // MARK: Extrude

    private func evalExtrude(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        distance: Expr,
        symmetric: Bool,
        boolean: BooleanIntent,
        extraProfileRefs: [ProfileRef],
        termination: ExtrudeEndDefinition? = nil,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("extrude plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("extrude profile unresolved")
            return
        }
        let resolvedDistance: Expr
        if let termination {
            let inputs = termination.targets.compactMap { ref -> ExtrudeEndDefinition.Input? in
                guard let body = state.bodies[ref.bodyID] else { return nil }
                return .init(body: body, reference: ref, table: state.faceTables[body.id])
            }
            do {
                let value = try termination.resolvedDistance(plane: plane,
                    seed: profileRef.seedPoint ?? outer.interiorPoint, symmetric: symmetric,
                    inputs: inputs, naming: state.naming)
                resolvedDistance = Expr(value: value)
                state.resolvedExtrudeDistances[node.id] = value
            } catch {
                state.errors[node.id] = .brokenRef("extrusion end: \(error.localizedDescription)")
                return
            }
        } else { resolvedDistance = distance }

        // Resolve extra profiles once; both the new-body and the cut paths use them.
        var extras: [(profile: Profile, holes: [Profile])] = []
        for ref in extraProfileRefs {
            guard let (extra, extraHoles) = state.resolveProfile(ref) else {
                state.errors[node.id] = .brokenRef("extrude extra profile unresolved")
                return
            }
            extras.append((profile: extra, holes: extraHoles))
        }

        if boolean.op == .newBody {
            guard let id = node.outputBodyIDs.first else {
                state.errors[node.id] = .brokenRef("extrude node has no output BodyID")
                return
            }
            // B-rep source of truth for EVERY extrude: circles become an
            // analytic cylinder (round), circular HOLES an analytic bore, other
            // profiles an exact polygonal prism, and extra regions fuse in.
            // The kernel goes FIRST and, when its solid tessellates, the body
            // is built from that tessellation alone — the Euclid prism below
            // is the fallback, never a prerequisite: cutting holes through it
            // is a BSP CSG, quadratic-plus on a spline outline's thousand
            // samples, and a 72-point cam with a bore wedged the eval for
            // minutes that way (gotcha 24).
            var names: [Int: ElementName] = [:]
            var channel: [UInt32] = []
            var adopted: Body? = nil
            if OCCTKernel.useOCCTAsSourceOfTruth {
                let z = OCCTKernel.extrudeZRange(distance: resolvedDistance.value, symmetric: symmetric)
                let history: OCCTShapeHistory? = extras.isEmpty ? OCCTShapeHistory() : nil
                if let handle = OCCTKernel.extrudeSolid(
                    outer: outer, holes: holes, extras: extras,
                    zMin: z.zMin, zMax: z.zMax,
                    origin: plane.origin, xAxis: plane.xAxis,
                    yAxis: plane.yAxis, normal: plane.normal,
                    history: history) {
                    var candidate = Body(
                        id: id, name: node.name, transform: .identity, primitive: nil,
                        euclidMesh: Euclid.Mesh([]), revision: nextRevision())
                    // Names attach through the per-triangle channel, which
                    // only aligns when the OCCT tessellation IS the render —
                    // so only when adoption succeeded (step 2 wiring).
                    if candidate.adoptBRep(handle) {
                        if let history {
                            names = ElementNaming.extrudeNames(
                                creator: node.id, ancestry: ShapeAncestry(history),
                                outer: outer, holes: holes)
                            channel = OCCTKernel.renderMeshFaceChannel(from: handle)
                        }
                        adopted = candidate
                    }
                }
            }
            var body: Body
            if let adopted {
                body = adopted
            } else {
                if termination != nil, OCCTKernel.useOCCTAsSourceOfTruth {
                    state.errors[node.id] = .kernelFailure("The associated extrusion could not build an exact solid.")
                    return
                }
                // Fallback: FLUSH prisms unioned — exact as-drawn geometry.
                var solid = KernelOps.extrude(
                    profile: outer, holes: holes, in: plane, distance: resolvedDistance.value, symmetric: symmetric)
                for extra in extras {
                    solid = solid.union(KernelOps.extrude(
                        profile: extra.profile, holes: extra.holes, in: plane,
                        distance: resolvedDistance.value, symmetric: symmetric))
                }
                guard !solid.polygons.isEmpty else {
                    state.errors[node.id] = .emptyGeometry
                    return
                }
                body = Body(
                    id: id, name: node.name, transform: .identity, primitive: nil,
                    euclidMesh: solid, revision: nextRevision())
            }
            var table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .extrude(outer))
            table = ElementNaming.attach(names, to: table, channel: channel, body: body)
            state.put(body, table: table)
            if !names.isEmpty { state.kernelNames[id] = names }
            return
        }

        // Boolean-into-target: the extrude modifies an existing body in place.
        guard let kind = boolean.op.kernelKind else {
            state.errors[node.id] = .kernelFailure("unsupported boolean op")
            return
        }
        guard let targetRef = boolean.resolvedTargets.first,
              let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("extrude boolean target unresolved")
            return
        }
        // A boolean-into-target extrude is a solid operation. Falling into the
        // padded Euclid cut below on an exact open surface would silently
        // replace the sheet with a mesh body; refuse and leave it untouched.
        if refuseExactSurface(node, "Extrude boolean", body: target, into: &state) { return }
        // The tool body is built LAZILY: from the kernel tool's own
        // tessellation when OCCT owns the boolean (below), else the padded
        // Euclid prism in the fallback. The Euclid prism used to be built
        // here unconditionally, holes and all — a BSP subtract, quadratic-plus
        // on a spline outline's thousand samples, that wedged the eval on a
        // 72-point cam with a bore (gotcha 24) — and then thrown away.
        var toolBody: Body? = nil
        var featureToolNames: [Int: ElementName] = [:]
        // OCCT FIRST, Euclid only when OCCT declines — the same §3b decision
        // evalBoolean got, applied late to this branch: the Euclid CSG here
        // ran UNCONDITIONALLY and was thrown away whenever OCCT succeeded,
        // and on a dense adopted tessellation it is not merely slow but
        // UNBOUNDED (the Motorcycle-cover nub union wedged the MainActor
        // here at 99% CPU, past every kernel deadline, because the spin was
        // never in the kernel).
        //
        // B-rep source of truth: when the target is analytic and the tool is
        // a single-profile extrude, compose the boolean in OCCT, so a cut
        // into a cylinder stays round. This branch previously rebuilt the
        // target mesh-only, and the next save silently dropped its brep — a
        // PERMANENT smooth→faceted degrade (2026-08-25 review, C4). The OCCT
        // tool is the EXACT prism (no overlap padding — analytic booleans
        // merge coincident faces robustly without it).
        var result = Body(
            id: target.id, name: target.name, transform: .identity, primitive: nil,
            euclidMesh: Euclid.Mesh([]), revision: nextRevision())
        var resultNames: [Int: ElementName] = [:]
        var resultHandle: BRepHandle?
        var occtOwned = false
        if OCCTKernel.useOCCTAsSourceOfTruth,
           let targetBrep = target.brep,
           let a = OCCTKernel.transformed(targetBrep, by: target.transform) {
            let z = OCCTKernel.extrudeZRange(distance: resolvedDistance.value, symmetric: symmetric)
            let history: OCCTShapeHistory? = extras.isEmpty ? OCCTShapeHistory() : nil
            if let toolBrep = OCCTKernel.extrudeSolid(
                   outer: outer, holes: holes, extras: extras,
                   zMin: z.zMin, zMax: z.zMax,
                   origin: plane.origin, xAxis: plane.xAxis,
                   yAxis: plane.yAxis, normal: plane.normal,
                   history: history) {
                // The transient tool's identities: its walls and caps belong
                // to THIS extrude node — the cut's trench walls are "wall of
                // sketch entity X, created by extrude N" exactly like a
                // new-body extrude's would be (step 3, cut branch).
                let toolNames = history.map {
                    ElementNaming.extrudeNames(
                        creator: node.id, ancestry: ShapeAncestry($0),
                        outer: outer, holes: holes)
                } ?? [:]
                featureToolNames = toolNames
                switch OCCTKernel.booleanResultWithAncestry(
                    a, toolBrep, op: OCCTKernel.booleanOp(kind)) {
                case let .success((outcome, ancestry)):
                    if result.adoptBRep(outcome.handle) {
                        occtOwned = true
                        resultHandle = outcome.handle
                        resultNames = ElementNaming.composeNames(
                            operation: node.id, ancestry: ancestry,
                            inputNames: [state.kernelNames[target.id] ?? [:],
                                         toolNames])
                        // The tool's face table from the SAME tessellator as
                        // the result, for the signature-propagation layer.
                        var occtTool = Body(
                            id: BodyID(), name: "\(node.name) tool", transform: .identity,
                            primitive: nil, euclidMesh: Euclid.Mesh([]), revision: 0)
                        if occtTool.adoptBRep(toolBrep) { toolBody = occtTool }
                    }
                case let .failure(error):
                    // Both operands were analytic; a mesh-only result here
                    // would silently drop the target's brep on the next save
                    // (C4). Surface the failure instead.
                    state.errors[node.id] = .kernelFailure("boolean: \(error.message)")
                    return
                }
            }
        }
        if !occtOwned {
            if termination != nil, target.brep != nil {
                state.errors[node.id] = .kernelFailure("The associated extrusion could not retain the target's exact geometry.")
                return
            }
            // Either the target is mesh-only or OCCT declined the tool
            // (multi-profile with a failed piece, holed loft…). Euclid
            // legitimately owns the result. Use the OVERLAPPED (padded) tool
            // — exactly what the live extrude-cut uses — so coplanar / flush
            // cut faces merge cleanly instead of leaving hanging thin walls;
            // wrapped identity so KernelOps.boolean bakes no extra transform.
            let toolMesh = KernelOps.overlapExtrudeTool(
                profile: outer, holes: holes, extraProfiles: extras,
                in: plane, distance: resolvedDistance.value, symmetric: symmetric)
            guard !toolMesh.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            let euclidTool = Body(
                id: BodyID(), name: "\(node.name) tool", transform: .identity, primitive: nil,
                euclidMesh: toolMesh, revision: 0)
            toolBody = euclidTool
            let resultMesh = KernelOps.boolean(kind, target: target, tool: euclidTool)
            guard !resultMesh.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            result = Body(
                id: target.id, name: target.name, transform: .identity, primitive: nil,
                euclidMesh: resultMesh, revision: nextRevision())
        }
        let toolTable = toolBody.map {
            state.naming.faceTable(for: $0, createdBy: node.id, scheme: .extrude(outer))
        }
        let inputTables = [state.faceTables[target.id], toolTable].compactMap { $0 }
        var table = state.naming.propagate(inputs: inputTables, output: result, op: .boolean(kind))
        if let resultHandle, !resultNames.isEmpty {
            table = ElementNaming.attach(
                resultNames, to: table,
                channel: OCCTKernel.renderMeshFaceChannel(from: resultHandle), body: result)
        }
        if let toolBody {
            state.publishTool(for: node.id, body: toolBody, names: featureToolNames, operation: kind, target: target.id)
        }
        state.put(result, table: table)
        if !resultNames.isEmpty { state.kernelNames[result.id] = resultNames }
    }

    // MARK: Boolean

    private func evalBoolean(
        _ node: FeatureNode,
        kind: BooleanKind,
        target targetRef: BodyRef,
        tools toolRefs: [BodyRef],
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("boolean target unresolved")
            return
        }
        // A boolean is defined on closed solids. Refuse an exact open surface
        // up front instead of letting the mesh fallback below re-tessellate
        // it and drop the exact handle on the next save.
        if refuseExactSurface(node, "Boolean", body: target, into: &state) { return }
        var acc = target
        var inputTables: [FaceTable] = state.faceTables[target.id].map { [$0] } ?? []
        var consumed: [BodyID] = []
        // The composable identity layer (step 3): the running result's
        // kernel-face names, re-derived through each tool's ancestry. The
        // Euclid fallback clears them — mesh-only results carry no names.
        var accNames = state.kernelNames[target.id] ?? [:]
        var accHandle: BRepHandle?

        for toolRef in toolRefs {
            guard let tool = state.bodies[toolRef.bodyID] else {
                state.errors[node.id] = .brokenRef("boolean tool unresolved")
                return
            }
            if refuseExactSurface(node, "Boolean", body: tool, into: &state) { return }
            if let t = state.faceTables[tool.id] { inputTables.append(t) }
            // Capture the pre-boolean operand for the brep composition below
            // (acc is replaced by `next` after each tool).
            let operand = acc

            // OCCT FIRST, and only fall back to Euclid if it declines.
            //
            // When both operands are analytic, `adoptBRep` replaces render,
            // edges AND euclid from OCCT's tessellation — so the Euclid CSG
            // that used to run first was computed in full and then thrown away
            // entirely. It is not a cheap thing to throw away: for a 10 mm box
            // minus a Ø4 cylinder the Euclid subtract takes 4,877 ms against
            // the OCCT boolean's 1 ms, and it is why a drilled box took ~7 s to
            // evaluate. Nothing about the resulting body changes here; only the
            // work that produced it does.
            var next: Body?
            switch OCCTKernel.composedBooleanResultWithAncestry(kind, target: operand, tool: tool) {
            case let .success((outcome, ancestry)):
                var body = Body(
                    id: target.id, name: target.name, transform: .identity,
                    primitive: nil, euclidMesh: Euclid.Mesh([]), revision: nextRevision())
                if body.adoptBRep(outcome.handle) {
                    next = body
                    accHandle = outcome.handle
                    // Inherit / mint through this hop's ancestry; a face
                    // with no named ancestors stays unnamed and signatures
                    // remain its fallback.
                    accNames = ElementNaming.composeNames(
                        operation: node.id, ancestry: ancestry,
                        inputNames: [accNames,
                                     state.kernelNames[tool.id] ?? [:]],
                        adjacency: OCCTKernel.edgeFaceAdjacency(outcome.handle))
                }
            case let .failure(error):
                // OCCT owned this boolean (both operands analytic) and failed
                // for cause. Falling through to Euclid here was how "corrupt"
                // booleans appeared: the mesh subtract still succeeds on the
                // tessellations, the brep is dropped, and the body silently
                // goes faceted forever. Surface the failure instead.
                state.errors[node.id] = .kernelFailure("boolean: \(error.message)")
                return
            case nil:
                break  // an operand is mesh-only — Euclid legitimately owns it
            }
            if next == nil {
                // Either operand is mesh-only, or OCCT produced something that
                // would not tessellate. Euclid owns the result — and a
                // mesh-only result has no kernel faces to name.
                accNames = [:]
                accHandle = nil
                let mesh = KernelOps.boolean(kind, target: acc, tool: tool)
                guard !mesh.polygons.isEmpty else {
                    state.errors[node.id] = .emptyGeometry
                    return
                }
                next = Body(
                    id: target.id, name: target.name, transform: .identity,
                    primitive: nil, euclidMesh: mesh, revision: nextRevision())
            }
            guard let resolved = next else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            acc = resolved
            consumed.append(tool.id)
        }

        // Remove the consumed tool bodies from the live set.
        for id in consumed { state.remove(id) }

        var table = state.naming.propagate(inputs: inputTables, output: acc, op: .boolean(kind))
        if let accHandle, !accNames.isEmpty {
            table = ElementNaming.attach(
                accNames, to: table,
                channel: OCCTKernel.renderMeshFaceChannel(from: accHandle), body: acc)
        }
        state.put(acc, table: table)
        if !accNames.isEmpty { state.kernelNames[acc.id] = accNames }
    }

    // MARK: Opportunistic ref upgrade (step 5b)

    /// Record an upgrade proposal when this resolution EARNED one. Layered
    /// onto any earlier proposal for the same node, so multi-ref kinds
    /// (shell, deleteFace) accumulate per-ref upgrades into one edit.
    private func proposeUpgrade(_ node: FeatureNode, ref: FaceRef,
                                resolved: ResolvedFace,
                                into state: inout EvalState) {
        guard let upgraded = ElementNaming.upgraded(ref, from: resolved) else { return }
        let base = state.proposedUpgrades[node.id] ?? node.kind
        guard let kind = Self.kind(base, replacing: ref, with: upgraded) else { return }
        state.proposedUpgrades[node.id] = kind
    }

    /// `kind` with one FaceRef swapped for its upgraded copy — the central
    /// switch, so a new ref-carrying kind that forgets to appear here simply
    /// never upgrades (safe) rather than upgrading wrongly.
    private static func kind(_ kind: FeatureKind, replacing ref: FaceRef,
                             with upgraded: FaceRef) -> FeatureKind? {
        switch kind {
        case let .pushPull(face, distance, mode) where face == ref:
            return .pushPull(face: upgraded, distance: distance, mode: mode)
        case let .moveFace(face, delta) where face == ref:
            return .moveFace(face: upgraded, delta: delta)
        case let .scaleFace(face, factor) where face == ref:
            return .scaleFace(face: upgraded, factor: factor)
        case let .rotateFace(face, angle, axis) where face == ref:
            return .rotateFace(face: upgraded, angle: angle, axis: axis)
        case let .draftFace(face, origin, normal, angle, support) where face == ref:
            return .draftFace(face: upgraded, neutralOrigin: origin,
                              neutralNormal: normal, angle: angle, planeReference: support)
        case let .replaceFace(face, origin, normal, flip, support) where face == ref:
            return .replaceFace(face: upgraded, targetOrigin: origin,
                                targetNormal: normal, flip: flip, planeReference: support)
        case let .shell(body, openFaces, thickness) where openFaces.contains(ref):
            return .shell(body: body,
                          openFaces: openFaces.map { $0 == ref ? upgraded : $0 },
                          thickness: thickness)
        case let .deleteFace(body, faces) where faces.contains(ref):
            return .deleteFace(body: body,
                               faces: faces.map { $0 == ref ? upgraded : $0 })
        default:
            return nil
        }
    }

    /// Step 5b for edges: record an upgrade proposal when a legacy blend
    /// `EdgeRef` earned its crease name during a rebuild. Layers onto any
    /// earlier proposal for the same node, so a multi-edge fillet accumulates
    /// per-edge upgrades into one edit.
    private func proposeEdgeUpgrade(_ node: FeatureNode, ref: EdgeRef,
                                    faceNames: EdgeName,
                                    into state: inout EvalState) {
        guard let upgraded = ElementNaming.upgraded(ref, faceNames: faceNames) else { return }
        let base = state.proposedUpgrades[node.id] ?? node.kind
        guard let kind = Self.kind(base, replacingEdge: ref, with: upgraded) else { return }
        state.proposedUpgrades[node.id] = kind
    }

    /// `kind` with one blend `EdgeRef` swapped for its upgraded copy — the
    /// edge twin of `kind(_:replacing:with:)`. Only fillet/chamfer carry
    /// EdgeRefs; a kind missing here simply never upgrades (safe).
    private static func kind(_ kind: FeatureKind, replacingEdge ref: EdgeRef,
                             with upgraded: EdgeRef) -> FeatureKind? {
        switch kind {
        case let .fillet(body, edges, radius) where edges.contains(ref):
            return .fillet(body: body,
                           edges: edges.map { $0 == ref ? upgraded : $0 },
                           radius: radius)
        case let .chamfer(body, edges, setback) where edges.contains(ref):
            return .chamfer(body: body,
                            edges: edges.map { $0 == ref ? upgraded : $0 },
                            setback: setback)
        default:
            return nil
        }
    }

    // MARK: Push/pull

    private func evalPushPull(
        _ node: FeatureNode,
        face: FaceRef,
        distance: Expr,
        mode: PushPullMode,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("pushPull body unresolved")
            return
        }
        if refuseExactSurface(node, "Push/Pull", body: body, into: &state) { return }
        // Re-resolve the persisted FaceRef against the (possibly rebuilt) body —
        // this is the topological-naming step that lets the pushed face follow the
        // geometry after an upstream edit.
        let table = state.faceTables[body.id]
        if mode == .cylinderRadial {
            guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
                  let cylinder = resolved.cylinder else {
                state.errors[node.id] = .brokenRef("The original cylindrical face no longer resolves.")
                return
            }
            do {
                let index = try KernelOps.radialFaceIndex(body: body, triangles: cylinder.triangles)
                let (result, ancestry) = try KernelOps.exactRadialOffset(body: body, faceIndex: index,
                    distance: distance.value, revision: nextRevision())
                let names = ElementNaming.composeNames(operation: node.id, ancestry: ancestry,
                    inputNames: [state.kernelNames[body.id] ?? [:]],
                    adjacency: result.brep.map(OCCTKernel.edgeFaceAdjacency) ?? [])
                var outputTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
                if let solid = result.brep, !names.isEmpty {
                    outputTable = ElementNaming.attach(names, to: outputTable,
                        channel: OCCTKernel.renderMeshFaceChannel(from: solid), body: result)
                }
                state.put(result, table: outputTable)
                state.kernelNames[result.id] = names
                proposeUpgrade(node, ref: face, resolved: resolved, into: &state)
            } catch {
                state.errors[node.id] = .kernelFailure((error as? OCCTOpError)?.message
                    ?? (error as? KernelOps.ExactEditError)?.message ?? error.localizedDescription)
            }
            return
        }
        guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("pushPull face did not resolve")
            return
        }
        proposeUpgrade(node, ref: face, resolved: resolved, into: &state)
        if body.brep != nil {
            do {
                let result = try KernelOps.exactPushPull(body: body, face: planar, distance: distance.value, revision: nextRevision())
                let newTable = table.map { state.naming.propagate(inputs: [$0], output: result, op: .pushPull) }
                    ?? state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
                state.put(result, table: newTable)
            } catch {
                state.errors[node.id] = .kernelFailure((error as? KernelOps.ExactEditError)?.message
                    ?? "Exact geometry operation failed; original body preserved.")
            }
            return
        }

        let mesh = KernelOps.pushPullPlanarFace(
            mesh: body.euclidMesh(), face: planar, distance: distance.value)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        // Carry the old labels forward through the push/pull.
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    // MARK: Move face

    /// Replay a face move: re-resolve the persisted `FaceRef` against the
    /// rebuilt body (topological naming), reconstruct the world/local delta from
    /// the stored face-basis components, and deform via `KernelOps.moveFace`.
    private func evalMoveFace(
        _ node: FeatureNode,
        face: FaceRef,
        delta components: SIMD3<Double>,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("moveFace body unresolved")
            return
        }
        if refuseExactSurface(node, "Move Face", body: body, into: &state) { return }
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("moveFace face did not resolve")
            return
        }
        proposeUpgrade(node, ref: face, resolved: resolved, into: &state)
        // (u, v, n) in the resolved face's own basis → a local-space delta, so
        // the move is intrinsic to the face even after the geometry shifted.
        let bx = simd_normalize(planar.basisX)
        let by = simd_normalize(planar.basisY)
        let n = simd_normalize(SIMD3<Double>(
            Double(planar.normal.x), Double(planar.normal.y), Double(planar.normal.z)))
        let localDelta = bx * components.x + by * components.y + n * components.z

        if body.brep != nil {
            do {
                let result = try KernelOps.exactMoveFace(body: body, face: planar, delta: localDelta, revision: nextRevision())
                let newTable = table.map { state.naming.propagate(inputs: [$0], output: result, op: .pushPull) }
                    ?? state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
                state.put(result, table: newTable)
            } catch {
                state.errors[node.id] = .kernelFailure((error as? KernelOps.ExactEditError)?.message
                    ?? "Exact geometry operation failed; original body preserved.")
            }
            return
        }

        let mesh = KernelOps.moveFace(
            mesh: body.euclidMesh(), face: planar, delta: localDelta)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    // MARK: Scale face

    /// Replay a face scale: re-resolve the persisted `FaceRef` and taper the
    /// solid via `KernelOps.scaleFace`. The factor is intrinsic (a ratio), so no
    /// basis reconstruction is needed.
    private func evalScaleFace(
        _ node: FeatureNode,
        face: FaceRef,
        factor: Double,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("scaleFace body unresolved")
            return
        }
        if refuseExactSurface(node, "Scale Face", body: body, into: &state) { return }
        guard body.brep == nil else {
            state.errors[node.id] = .kernelFailure(KernelOps.ExactEditError.unsupported("Face scaling").message)
            return
        }
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("scaleFace face did not resolve")
            return
        }
        proposeUpgrade(node, ref: face, resolved: resolved, into: &state)
        let mesh = KernelOps.scaleFace(
            mesh: body.euclidMesh(), face: planar, factor: factor)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    // MARK: Rotate face

    /// Replay a face rotation: re-resolve the persisted `FaceRef` and reconstruct
    /// the rotation axis from its stored face-basis components (so an in-plane
    /// tilt / normal twist stays intrinsic to the face after an upstream edit),
    /// then deform via `KernelOps.rotateFace`.
    private func evalRotateFace(
        _ node: FeatureNode,
        face: FaceRef,
        angle: Double,
        axis components: SIMD3<Double>,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("rotateFace body unresolved")
            return
        }
        if refuseExactSurface(node, "Rotate Face", body: body, into: &state) { return }
        guard body.brep == nil else {
            state.errors[node.id] = .kernelFailure(KernelOps.ExactEditError.unsupported("Face rotation").message)
            return
        }
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("rotateFace face did not resolve")
            return
        }
        proposeUpgrade(node, ref: face, resolved: resolved, into: &state)
        // (u, v, n) in the resolved face's own basis → a world-space axis.
        let bx = simd_normalize(planar.basisX)
        let by = simd_normalize(planar.basisY)
        let n = simd_normalize(SIMD3<Double>(
            Double(planar.normal.x), Double(planar.normal.y), Double(planar.normal.z)))
        let axis = bx * components.x + by * components.y + n * components.z

        let mesh = KernelOps.rotateFace(
            mesh: body.euclidMesh(), face: planar, angle: angle, axis: axis)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    /// Draft an existing face: resolve the ref, then shear the face about its
    /// intersection with the neutral plane (`KernelOps.draftFace`). The neutral
    /// plane is stored as a WORLD plane rather than a `FaceRef` — the same v1
    /// simplification `replaceFace` makes, and for the same reason: a parting
    /// line is usually a datum, not a face this body owns.
    private func evalDraftFace(
        _ node: FeatureNode,
        face: FaceRef,
        neutralOrigin: SIMD3<Double>,
        neutralNormal: SIMD3<Double>,
        degrees: Double,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[face.body.bodyID] else {
            state.errors[node.id] = .brokenRef("draftFace body unresolved")
            return
        }
        if refuseExactSurface(node, "Draft Face", body: body, into: &state) { return }
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolvePersisted(face, in: body, table: table),
              resolved.planar != nil || resolved.cylinder != nil else {
            state.errors[node.id] = .brokenRef("draftFace face did not resolve")
            return
        }
        proposeUpgrade(node, ref: face, resolved: resolved, into: &state)

        // B-rep draft first (2026-09-04): `BRepOffsetAPI_DraftAngle` tilts the
        // real face about its intersection with the neutral plane, so a
        // drafted casting stays analytic — filletable, shellable, exportable —
        // where the mesh path below only shears render polygons and left the
        // body mesh-only (the Level 12/13 practice sheets stopped there). The
        // picked face is handed to OCCT by a point on it, like the shell's
        // openings. Kernel refusal preserves an exact body; only mesh-only
        // bodies use the deformation fallback below.
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = body.brep,
           let point = Self.pointOnFace(resolved, mesh: body.render) {
            // The exact shape is body-local. New reference-based edits also
            // resolve their plane into that same frame; legacy absolute
            // documents keep their original stored coordinate convention.
            let worldPoint = node.kind.operationPlaneReference == nil
                ? body.transform.applying(to: point) : point
            if case let .success(drafted) = OCCTKernel.draftResult(
                brep, facesAt: [worldPoint], degrees: degrees,
                neutralOrigin: neutralOrigin, neutralNormal: neutralNormal,
                tolerance: OCCTKernel.matchTolerance(for: brep)) {
                var result = Body(
                    id: body.id, name: body.name, transform: body.transform, primitive: nil,
                    euclidMesh: body.euclidMesh(), revision: nextRevision())
                if result.adoptBRep(drafted) {
                    let newTable: FaceTable
                    if let table {
                        newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
                    } else {
                        newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
                    }
                    state.put(result, table: newTable)
                    return
                }
            }
        }

        guard body.brep == nil else {
            state.errors[node.id] = .kernelFailure("Exact draft failed; original body preserved.")
            return
        }

        // The mesh shear only knows planar faces; a curved face that the
        // kernel declined stays an honest error rather than a guess.
        guard let planar = resolved.planar else {
            state.errors[node.id] = .kernelFailure("draft: the kernel declined to draft this curved face")
            return
        }
        let mesh = KernelOps.draftFace(
            mesh: body.euclidMesh(), face: planar,
            neutralOrigin: neutralOrigin, neutralNormal: neutralNormal, degrees: degrees)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        let newTable: FaceTable
        if let table {
            newTable = state.naming.propagate(inputs: [table], output: result, op: .pushPull)
        } else {
            newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        }
        state.put(result, table: newTable)
    }

    /// A body-local point ON the resolved face, to hand the face to the
    /// kernel by proximity: a planar face's outline centroid; for a
    /// cylindrical face the centroid of its facets pushed radially onto the
    /// true surface (the facet centroid itself sits a hair inside the
    /// cylinder, and a whole-wall centroid would sit on the axis).
    static func pointOnFace(_ resolved: ResolvedFace, mesh: RenderMesh) -> SIMD3<Double>? {
        if let planar = resolved.planar {
            return pointOnPlanarFace(planar, mesh: mesh)
        }
        guard let cyl = resolved.cylinder, !cyl.triangles.isEmpty else { return nil }
        // ONE facet's centroid, pushed out to the true radius — never the
        // centroid of the whole face: a full 360° cylinder's facets average
        // to a point ON the axis, whose radial direction is undefined, and
        // every cylindrical draft in the app was silently skipped that way
        // (found by the Level 12/13 casting sheets, 2026-09-04).
        let axis = simd_normalize(cyl.axisDir)
        for t in cyl.triangles where t * 3 + 2 < mesh.indices.count {
            var sum = SIMD3<Double>.zero
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[t * 3 + k])]
                sum += SIMD3(Double(p.x), Double(p.y), Double(p.z))
            }
            let centroid = sum / 3
            let along = simd_dot(centroid - cyl.axisPoint, axis)
            let onAxis = cyl.axisPoint + axis * along
            let radial = centroid - onAxis
            guard simd_length(radial) > 1e-9 else { continue }
            return onAxis + simd_normalize(radial) * cyl.radius
        }
        return nil
    }

    /// A point guaranteed to lie ON a planar face: the centroid of its
    /// largest facet (well inside, away from edges and tolerance bands). The
    /// outline centroid is only a fallback for a face with no facets.
    static func pointOnPlanarFace(_ planar: FaceTopology.PlanarFace, mesh: RenderMesh) -> SIMD3<Double> {
        var best: (area: Double, centroid: SIMD3<Double>)?
        for t in planar.triangles where t * 3 + 2 < mesh.indices.count {
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[t * 3])])
            let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[t * 3 + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[t * 3 + 2])])
            let area = simd_length(simd_cross(b - a, c - a))
            if best == nil || area > best!.area { best = (area, (a + b + c) / 3) }
        }
        if let best { return best.centroid }
        let count = Double(max(planar.outline.count, 1))
        let c = planar.outline.reduce(SIMD2<Double>.zero, +) / count
        return planar.origin + planar.basisX * c.x + planar.basisY * c.y
    }

    // MARK: Chamfer / Fillet (edge blends)

    /// Resolve each persisted `EdgeRef` against the input body's rebuilt edges
    /// and remove/round the corner. Refs resolve against the INPUT body because
    /// the blend destroys the very edges it names. Every operand must resolve
    /// before the kernel is allowed to change any part of the selection.
    private func evalEdgeBlend(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        edgeRefs: [EdgeRef],
        amount: Double,
        isFillet: Bool,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard amount.isFinite, amount > 1e-6 else {
            state.errors[node.id] = .kernelFailure("blend amount must be finite and positive")
            return
        }
        guard !edgeRefs.isEmpty,
              edgeRefs.allSatisfy({ $0.body.bodyID == bodyRef.bodyID }) else {
            state.errors[node.id] = .brokenRef("blend needs edges on its target body")
            return
        }
        guard let body = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("blend body unresolved")
            return
        }
        if refuseExactSurface(node, isFillet ? "Fillet" : "Chamfer",
                              body: body, into: &state) { return }

        let names = state.kernelNames[body.id] ?? [:]
        let context = EdgeTopology.ReferenceContext(body: body, kernelNames: names)
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = body.brep {
            let edgeNames = context.names
            var indices: [Int] = []
            var upgrades: [(EdgeRef, EdgeName)] = []
            for (offset, ref) in edgeRefs.enumerated() {
                guard let resolved = context.resolve(ref), let index = resolved.nativeIndex else {
                    state.errors[node.id] = .brokenRef(
                        "blend edge \(offset + 1) identity is missing or ambiguous; no edges were blended")
                    return
                }
                indices.append(index)
                if let name = resolved.name { upgrades.append((ref, name)) }
            }
            do {
                // MANY refs can name ONE kernel edge: the picker selects mesh
                // segments, and a tessellated rim is a long chain of them over
                // a single OCCT edge, so every segment mints the same EdgeName.
                // Blend each crease once — duplicates are the same edge, the
                // kernel dedupes them anyway, and `edgeParents` below is keyed
                // BY INDEX (a repeat used to trap the whole app on rebuild).
                var seen = Set<Int>()
                let unique = indices.filter { seen.insert($0).inserted }
                let blended = isFillet
                    ? OCCTKernel.filletResultWithAncestry(
                        brep, edgeIndices: unique, radius: amount)
                    : OCCTKernel.chamferResultWithAncestry(
                        brep, edgeIndices: unique, distance: amount)
                switch blended {
                case let .success((handle, ancestry)):
                    var result = Body(
                        id: body.id, name: body.name, transform: body.transform,
                        primitive: nil, euclidMesh: body.euclidMesh(),
                        revision: nextRevision())
                    guard result.adoptBRep(handle) else {
                        state.errors[node.id] = .emptyGeometry
                        return
                    }
                    // Names survive the blend (step 5): untouched faces
                    // inherit, and each blend face is named FOR ITS CREASE —
                    // opFace(parents: the crease's two face names).
                    let edgeParents = Dictionary(uniqueKeysWithValues:
                        unique.compactMap { index -> (Int, [ElementName])? in
                            edgeNames[index].map { (index, [$0.faceA, $0.faceB]) }
                        })
                    let outNames = ElementNaming.composeNames(
                        operation: node.id, ancestry: ancestry,
                        inputNames: [names], edgeParents: edgeParents)
                    var table = state.naming.faceTable(
                        for: result, createdBy: node.id, scheme: .generic)
                    if !outNames.isEmpty {
                        table = ElementNaming.attach(
                            outNames, to: table,
                            channel: OCCTKernel.renderMeshFaceChannel(from: handle), body: result)
                    }
                    state.put(result, table: table)
                    if !outNames.isEmpty {
                        state.kernelNames[result.id] = outNames
                    }
                    for (ref, name) in upgrades {
                        proposeEdgeUpgrade(node, ref: ref, faceNames: name, into: &state)
                    }
                    return
                case let .failure(error):
                    // The named edges EXIST — the blend itself failed
                    // (radius too big, invalid result). Same typed surfacing
                    // as the point path; no silent fallback that would
                    // report a different edge's failure.
                    let verb = isFillet ? "fillet" : "chamfer"
                    state.errors[node.id] = .kernelFailure("\(verb): \(error.message)")
                    return
                }
            }
        }

        func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }

        var specs = [BlendEdgeSpec]()
        for (offset, ref) in edgeRefs.enumerated() {
            guard let edge = context.resolve(ref)?.edge
            else {
                state.errors[node.id] = .brokenRef(
                    "blend edge \(offset + 1) did not resolve; no edges were blended")
                return
            }
            let spec = BlendEdgeSpec(
                p0: d3(edge.start), p1: d3(edge.end),
                normalA: d3(edge.normalA), normalB: d3(edge.normalB),
                isConvex: edge.isConvex)
            specs.append(spec)
        }
        guard !specs.isEmpty else {
            state.errors[node.id] = .brokenRef("no blend edge resolved")
            return
        }
        // The exact path returned above on both success and refusal. Only an
        // actually mesh-owned body may use the legacy approximation here.
        let mesh = KernelOps.blendEdges(
            mesh: body.euclidMesh(), edges: specs, amount: amount, isFillet: isFillet)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        // A blend changes face count/areas; relabel by geometry. Downstream
        // FaceRefs re-resolve by signature scoring against the surviving faces.
        let table = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        state.put(result, table: table)
    }

    // MARK: Shell

    /// Hollow the body to `thickness`, opening the faces named by
    /// `openFaceRefs`. Refs resolve against the INPUT body (the shell rebuilds
    /// every face). An unresolved ref errors the node — silently shipping a
    /// closed hollow instead of the asked-for opening would be worse.
    private func evalShell(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        openFaceRefs: [FaceRef],
        thickness: Double,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        // Signed: positive hollows inward, negative grows the wall outward.
        guard thickness.isFinite, abs(thickness) > 1e-6 else {
            state.errors[node.id] = .kernelFailure("shell thickness must be finite and non-zero")
            return
        }
        guard let body = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("shell body unresolved")
            return
        }
        if refuseExactSurface(node, "Shell", body: body, into: &state) { return }
        let table = state.faceTables[body.id]
        var openFaces = [ResolvedFace]()
        var upgrades = [(FaceRef, ResolvedFace)]()
        for ref in openFaceRefs {
            guard ref.body.bodyID == bodyRef.bodyID,
                  let resolved = state.naming.resolvePersisted(ref, in: body, table: table),
                  !resolved.triangles.isEmpty else {
                state.errors[node.id] = .brokenRef("shell open face did not resolve")
                return
            }
            upgrades.append((ref, resolved))
            if !openFaces.contains(where: { Set($0.triangles) == Set(resolved.triangles) }) {
                openFaces.append(resolved)
            }
        }
        // B-rep shell: when the body is analytic, hollow it with
        // BRepOffsetAPI_MakeThickSolid so CURVED walls are correct — the mesh
        // path insets a planar face outline, which is only honest on prismatic
        // bodies (a shelled cylinder must end up with two concentric walls).
        //
        // A brep body whose OCCT shell fails ERRORS rather than degrading to
        // the mesh inset — the same decision the blends made (see
        // evalEdgeBlend): ShellKit clamps its mitre on corners sharper than
        // ~14.5° and ships thin walls that pass every downstream validity
        // check (review R3-E). The mesh path below stays for brep-less bodies.
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = body.brep {
            // A point ON each open face identifies it to OCCT — a facet's
            // centroid, not the outline's: an annular or L-shaped face's
            // outline centroid lies in its hole or outside it, and the shell
            // of every ring-topped hub was refused with "no face within
            // tolerance of the pick" (Level 13 practice sheets, 2026-09-04).
            let openPoints = openFaces.compactMap {
                Self.pointOnFace($0, mesh: body.render)
            }
            guard openPoints.count == openFaces.count else {
                state.errors[node.id] = .brokenRef("shell opening has no point on its surface")
                return
            }
            switch OCCTKernel.shellResultWithAncestry(
                brep, openingAt: openPoints, thickness: thickness,
                tolerance: OCCTKernel.matchTolerance(for: brep)) {
            case let .success((hollow, ancestry)):
                var result = Body(
                    id: body.id, name: body.name, transform: body.transform, primitive: nil,
                    euclidMesh: body.euclidMesh(), revision: nextRevision())
                guard result.adoptBRep(hollow) else {
                    state.errors[node.id] = .emptyGeometry
                    return
                }
                // Surviving outer faces keep their identities through the
                // hollow (step 5); the new inner faces mint from their
                // parents or stay honestly unnamed.
                let outNames = ElementNaming.composeNames(
                    operation: node.id, ancestry: ancestry,
                    inputNames: [state.kernelNames[body.id] ?? [:]])
                var newTable = state.naming.faceTable(
                    for: result, createdBy: node.id, scheme: .generic)
                if !outNames.isEmpty {
                    newTable = ElementNaming.attach(
                        outNames, to: newTable,
                        channel: OCCTKernel.renderMeshFaceChannel(from: hollow), body: result)
                }
                state.put(result, table: newTable)
                if !outNames.isEmpty { state.kernelNames[result.id] = outNames }
                for (ref, resolved) in upgrades {
                    proposeUpgrade(node, ref: ref, resolved: resolved, into: &state)
                }
            case let .failure(error):
                state.errors[node.id] = .kernelFailure("shell: \(error.message)")
            }
            return
        }

        let planarFaces = openFaces.compactMap(\.planar)
        guard planarFaces.count == openFaces.count else {
            state.errors[node.id] = .kernelFailure("curved shell openings require an analytic solid")
            return
        }
        let mesh = KernelOps.shell(
            mesh: body.euclidMesh(), thickness: thickness, openFaces: planarFaces)
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: mesh, revision: nextRevision())
        // Shelling rebuilds every face; relabel by geometry like the blends.
        let newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        state.put(result, table: newTable)
        for (ref, resolved) in upgrades {
            proposeUpgrade(node, ref: ref, resolved: resolved, into: &state)
        }
    }

    // MARK: Delete Face (direct modeling, spec §4.16)

    /// Remove the referenced faces and let the neighbouring surfaces extend to
    /// re-close the body — the direct-modeling gesture that deletes a hole or
    /// pocket without unwinding the history that made it.
    ///
    /// This is B-rep-only on purpose. Healing means EXTENDING the adjacent
    /// surfaces to their new intersections; a triangle soup has no surfaces to
    /// extend, so a mesh fallback would silently produce a hole-shaped dent
    /// instead of a clean solid. Without a `brep` the node errors and the input
    /// body passes through untouched.
    private func evalDeleteFace(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        faceRefs: [FaceRef],
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("delete-face body unresolved")
            return
        }
        if refuseExactSurface(node, "Delete Face", body: body, into: &state) { return }
        guard !faceRefs.isEmpty else {
            state.errors[node.id] = .kernelFailure("delete face needs at least one face")
            return
        }
        guard OCCTKernel.useOCCTAsSourceOfTruth, let brep = body.brep else {
            state.errors[node.id] = .kernelFailure(
                "delete face needs a B-rep body — surfaces cannot heal on a mesh")
            return
        }

        let table = state.faceTables[body.id]
        var points = [SIMD3<Double>]()
        var upgrades = [(FaceRef, ResolvedFace)]()
        for ref in faceRefs {
            guard ref.body.bodyID == bodyRef.bodyID,
                  let resolved = state.naming.resolvePersisted(ref, in: body, table: table),
                  let point = Self.pointOnFace(resolved, mesh: body.render) else {
                state.errors[node.id] = .brokenRef("delete-face target did not resolve")
                return
            }
            upgrades.append((ref, resolved))
            points.append(point)
        }

        let healed: BRepHandle
        let ancestry: ShapeAncestry
        switch OCCTKernel.removingFacesResultWithAncestry(
            brep, at: points, tolerance: OCCTKernel.matchTolerance(for: brep)) {
        case let .success((handle, history)):
            healed = handle
            ancestry = history
        case let .failure(error):
            // Defeaturing legitimately fails when the neighbours cannot close
            // (§4.16: those deletions leave sheet bodies). Report rather than
            // ship a broken solid.
            state.errors[node.id] = .kernelFailure("delete face: \(error.message)")
            return
        }
        var result = Body(
            id: body.id, name: body.name, transform: body.transform, primitive: nil,
            euclidMesh: body.euclidMesh(), revision: nextRevision())
        guard result.adoptBRep(healed) else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        // Every remaining face may have been re-trimmed; relabel roles by
        // geometry — but IDENTITIES survive through the defeaturing history
        // (step 5; OCCT reports it, FreeCAD drops it, we keep it).
        let outNames = ElementNaming.composeNames(
            operation: node.id, ancestry: ancestry,
            inputNames: [state.kernelNames[body.id] ?? [:]])
        var newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        if !outNames.isEmpty {
            newTable = ElementNaming.attach(
                outNames, to: newTable,
                channel: OCCTKernel.renderMeshFaceChannel(from: healed), body: result)
        }
        state.put(result, table: newTable)
        if !outNames.isEmpty { state.kernelNames[result.id] = outNames }
        for (ref, resolved) in upgrades {
            proposeUpgrade(node, ref: ref, resolved: resolved, into: &state)
        }
    }

    // MARK: Split Body

    private func evalSplit(_ node: FeatureNode, target: BodyRef, cutter: SplitCutterDefinition,
                           plane: SketchPlane?, into state: inout EvalState,
                           next nextRevision: () -> UInt64) {
        guard node.outputBodyIDs.count == 2, node.outputBodyIDs[0] == target.bodyID,
              node.outputBodyIDs[1] != target.bodyID,
              state.bodies[node.outputBodyIDs[1]] == nil,
              let body = state.bodies[target.bodyID], body.brep != nil,
              let plane else {
            state.errors[node.id] = .brokenRef("Split source, cutter or result identities are unavailable.")
            return
        }
        do {
            try cutter.validate()
            var profile: Profile?
            var holes: [Profile] = []
            if let reference = cutter.profile {
                guard let sketch = state.sketch(reference.sketchID) else {
                    throw CADDocumentFormatError.malformedAssociation("split-sketch")
                }
                let ids = Set(sketch.entities.map(\.id))
                let required = Set(reference.entityIDs + reference.holeEntityIDs.flatMap { $0 })
                // Do not let resolveProfile's legacy seed fallback replace a
                // deleted cutter with another region occupying that point.
                guard required.isSubset(of: ids), let resolved = state.resolveProfile(reference) else {
                    throw CADDocumentFormatError.malformedAssociation("split-profile")
                }
                profile = resolved.outer
                holes = resolved.holes
            }
            let halves = try KernelOps.exactSplitWithAncestry(body: body, plane: plane, profile: profile,
                holes: holes, secondID: node.outputBodyIDs[1])
            let inputNames = state.kernelNames[body.id] ?? [:]
            var first = halves.first, second = halves.second
            first.name = body.name; second.name = body.name + " B"
            first.meshRevision = nextRevision(); second.meshRevision = nextRevision()
            // Both halves are ready before either PUT. Names derive only
            // from actual OCCT input ancestry; the temporary cutter has none.
            for (output, ancestry) in [(first, halves.firstAncestry), (second, halves.secondAncestry)] {
                guard let solid = output.brep else { throw KernelOps.ExactEditError.refused }
                let names = ElementNaming.composeNames(operation: node.id, ancestry: ancestry,
                    inputNames: [inputNames, [:]], adjacency: OCCTKernel.edgeFaceAdjacency(solid))
                var table = state.naming.faceTable(for: output, createdBy: node.id, scheme: .generic)
                table = ElementNaming.attach(names, to: table,
                    channel: OCCTKernel.renderMeshFaceChannel(from: solid), body: output)
                state.put(output, table: table)
                state.kernelNames[output.id] = names
            }
        } catch {
            state.errors[node.id] = .kernelFailure("Split: \(error.localizedDescription)")
        }
    }

    // MARK: Replace Face (direct modeling, spec §4.12)

    /// Extend or trim the referenced face until it lies on the target plane.
    ///
    /// Unlike Delete Face this has a mesh fallback, because the operation is a
    /// boolean with a prism and Euclid can do that honestly. But a body that
    /// HAS a brep takes the analytic route: running it through the mesh path
    /// would hand back a body with no `brep`, and the next save would write the
    /// tessellation as if it were the truth (2026-08-25 review, C4).
    private func evalReplaceFace(
        _ node: FeatureNode,
        faceRef: FaceRef,
        targetOrigin: SIMD3<Double>,
        targetNormal: SIMD3<Double>,
        flip: Bool,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let body = state.bodies[faceRef.body.bodyID] else {
            state.errors[node.id] = .brokenRef("replace-face body unresolved")
            return
        }
        if refuseExactSurface(node, "Replace Face", body: body, into: &state) { return }
        let table = state.faceTables[body.id]
        guard let resolved = state.naming.resolvePersisted(faceRef, in: body, table: table),
              let planar = resolved.planar else {
            state.errors[node.id] = .brokenRef("replace-face target did not resolve")
            return
        }
        proposeUpgrade(node, ref: faceRef, resolved: resolved, into: &state)
        let plan: ReplaceFaceKit.Plan
        do {
            plan = try ReplaceFaceKit.plan(
                face: planar, targetOrigin: targetOrigin,
                targetNormal: targetNormal, flip: flip)
        } catch {
            // A rebuild can move the face onto (or past) its own target — the
            // refusals are the honest outcome, not a crash.
            state.errors[node.id] = .kernelFailure(Self.replaceRefusalText(error))
            return
        }

        var result: Body
        var outNames: [Int: ElementName] = [:]
        var outHandle: BRepHandle?
        if OCCTKernel.useOCCTAsSourceOfTruth, let brep = body.brep,
           let (replaced, ancestry) = ReplaceFaceKit.applyBRepWithAncestry(
                to: brep, face: planar, plan: plan) {
            result = Body(
                id: body.id, name: body.name, transform: body.transform, primitive: nil,
                render: body.render, revision: nextRevision())
            guard result.adoptBRep(replaced) else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            outHandle = replaced
            // Replace-face is a boolean (body ⊕ prism): the body's untouched
            // faces keep their identities through the ancestry; the moved face
            // and any new walls descend only from the unnamed prism and mint
            // fresh. Input ordinal 0 = body, 1 = prism (no names).
            outNames = ElementNaming.composeNames(
                operation: node.id, ancestry: ancestry,
                inputNames: [state.kernelNames[body.id] ?? [:], [:]])
        } else {
            guard let mesh = ReplaceFaceKit.apply(
                to: body.euclidMesh(), face: planar, plan: plan),
                !mesh.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            result = Body(
                id: body.id, name: body.name, transform: body.transform, primitive: nil,
                euclidMesh: mesh, revision: nextRevision())
        }
        // Roles relabel by geometry; the IDENTITIES that survived the boolean
        // are attached on top so a fillet/name upstream of the replace holds.
        var newTable = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        if let outHandle, !outNames.isEmpty {
            newTable = ElementNaming.attach(
                outNames, to: newTable,
                channel: OCCTKernel.renderMeshFaceChannel(from: outHandle), body: result)
        }
        state.put(result, table: newTable)
        if !outNames.isEmpty { state.kernelNames[result.id] = outNames }
    }

    /// User-facing text for a `ReplaceFaceKit.Refusal`, shared by replay and
    /// the live tool so both say the same thing.
    static func replaceRefusalText(_ error: Error) -> String {
        switch error as? ReplaceFaceKit.Refusal {
        case .targetNotParallel:
            return "the target face isn't parallel to the one being replaced"
        case .noChange:
            return "the target plane passes through the face — nothing to replace"
        case .degenerateFace:
            return "that face has no usable outline"
        case nil:
            return "replace face failed"
        }
    }

    // MARK: Revolve / Sweep / Loft (full-solid ops)

    /// Emit a freshly built world-space `mesh` as either a NEW body or a boolean
    /// into an existing target. Unlike extrude's cut (which uses a padded overlap
    /// prism), revolve/sweep/loft merge the FULL solid: the tool is `mesh` wrapped
    /// in an identity `Body` and fed straight to `KernelOps.boolean`.
    /// Emit a whole-solid feature's result.
    ///
    /// `brep` is the exact solid when the operation could build one. Sweep
    /// adopts its native render so face materials and History use the actual
    /// same partitions; other operations retain their existing render policy.
    /// Nil keeps the mesh-only path, including unsupported paths/holed lofts.
    private func emitFullSolid(
        _ node: FeatureNode,
        mesh: Euclid.Mesh,
        brep: BRepHandle? = nil,
        kernelNames: [Int: ElementName] = [:],
        nativeRender: Bool = false,
        boolean: BooleanIntent,
        scheme: FaceScheme,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard !mesh.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }

        if boolean.op == .newBody {
            guard let id = node.outputBodyIDs.first else {
                state.errors[node.id] = .brokenRef("node has no output BodyID")
                return
            }
            var body = Body(
                id: id, name: node.name, transform: .identity, primitive: nil,
                euclidMesh: mesh, revision: nextRevision())
            if OCCTKernel.useOCCTAsSourceOfTruth, let brep {
                if nativeRender {
                    guard body.adoptBRep(brep) else {
                        state.errors[node.id] = .kernelFailure("native solid could not be tessellated")
                        return
                    }
                } else {
                    // Preserve the existing revolve/loft tessellation policy;
                    // it cannot claim a native face-to-render channel.
                    body.brep = brep
                }
            }
            var table = state.naming.faceTable(for: body, createdBy: node.id, scheme: scheme)
            if nativeRender, let brep = body.brep {
                table = ElementNaming.attach(kernelNames, to: table,
                    channel: OCCTKernel.renderMeshFaceChannel(from: brep), body: body)
            }
            state.put(body, table: table)
            // The COMPOSABLE identity layer (kernel-face indices → names).
            // Non-native renders keep only the composable map; their triangle
            // indices cannot borrow the kernel tessellation's face channel.
            if body.brep != nil, !kernelNames.isEmpty {
                state.kernelNames[id] = kernelNames
            }
            return
        }

        guard let kind = boolean.op.kernelKind else {
            state.errors[node.id] = .kernelFailure("unsupported boolean op")
            return
        }
        guard let targetRef = boolean.resolvedTargets.first,
              let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("boolean target unresolved")
            return
        }
        // Revolve/sweep/loft booleans are solid operations; their Euclid
        // fallback below would consume an exact open surface as a mesh.
        if refuseExactSurface(node, "\(node.name) boolean", body: target,
                              into: &state) { return }
        // The full solid, wrapped identity so KernelOps.boolean bakes no extra
        // transform (mesh already lives in the shared world space). The brep,
        // when there is one, rides along so the OCCT composition below sees
        // the tool exactly as a boolean node would.
        var toolBody = Body(
            id: BodyID(), name: "\(node.name) tool", transform: .identity, primitive: nil,
            euclidMesh: mesh, revision: 0)
        toolBody.brep = brep
        let toolTable = state.naming.faceTable(for: toolBody, createdBy: node.id, scheme: scheme)

        // OCCT FIRST, Euclid only when OCCT declines — the same order
        // `evalExtrude`'s boolean branch and `evalBoolean` already follow.
        // This branch used to run the Euclid CSG unconditionally and then
        // ASSIGN the OCCT result's brep over it, which was not merely wasted
        // work: it KILLED the app. A loft whose top section sits exactly on
        // the target's bottom face (the BEG 55 motor end cap, 2026-09-02)
        // hands the Euclid union two coincident coplanar caps whose edges
        // disagree at the 1e-6 level — the target's CSG mesh is rebuilt from
        // Float32 render buffers, the tool's is Double — and the BSP clip
        // leaves a wall polygon with four vertices 5e-7 mm apart. Its
        // triangulation drops the sliver, the mesh is no longer watertight,
        // and Euclid's own `assert` on the carried watertight claim trapped
        // the process with no crash report. Adopting OCCT's fused solid
        // (render, edges AND euclid from its tessellation) never touches
        // the Euclid CSG for the analytic case at all. When OCCT OWNS the op
        // (both sides analytic) and fails for cause, surface it: shipping
        // the mesh result would silently drop the brep on the next save.
        var result: Body?
        var resultHandle: BRepHandle?
        var resultNames: [Int: ElementName] = [:]
        switch OCCTKernel.composedBooleanResultWithAncestry(kind, target: target, tool: toolBody) {
        case let .success((outcome, ancestry)):
            var body = Body(
                id: target.id, name: target.name, transform: .identity, primitive: nil,
                euclidMesh: Euclid.Mesh([]), revision: nextRevision())
            if body.adoptBRep(outcome.handle) {
                result = body
                resultHandle = outcome.handle
                // Inherit / mint through the boolean's ancestry: the target's
                // own names and the tool's (this node's walls and caps).
                resultNames = ElementNaming.composeNames(
                    operation: node.id, ancestry: ancestry,
                    inputNames: [state.kernelNames[target.id] ?? [:], kernelNames],
                    adjacency: OCCTKernel.edgeFaceAdjacency(outcome.handle))
            }
        case let .failure(error):
            state.errors[node.id] = .kernelFailure("boolean: \(error.message)")
            return
        case nil:
            break  // an operand is mesh-only — Euclid legitimately owns it
        }
        if result == nil {
            // Either operand is mesh-only (a holed loft, an imported mesh), or
            // OCCT produced something that would not tessellate.
            let resultMesh = KernelOps.boolean(kind, target: target, tool: toolBody)
            guard !resultMesh.polygons.isEmpty else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            result = Body(
                id: target.id, name: target.name, transform: .identity, primitive: nil,
                euclidMesh: resultMesh, revision: nextRevision())
        }
        guard let result else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        let inputTables = [state.faceTables[target.id], toolTable].compactMap { $0 }
        var table = state.naming.propagate(inputs: inputTables, output: result, op: .boolean(kind))
        if let resultHandle, !resultNames.isEmpty {
            table = ElementNaming.attach(
                resultNames, to: table,
                channel: OCCTKernel.renderMeshFaceChannel(from: resultHandle), body: result)
        }
        state.publishTool(for: node.id, body: toolBody, names: kernelNames, operation: kind, target: target.id)
        state.put(result, table: table)
        if !resultNames.isEmpty { state.kernelNames[result.id] = resultNames }
    }

    private func evalRevolve(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        axisRef: AxisRef,
        angle: Expr,
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("revolve plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("revolve profile unresolved")
            return
        }
        // M08 R2: a construction-axis revolve resolves that axis's CURRENT
        // line through the document resolver on every replay and converts it
        // into this plane's basis. A broken source or a non-coplanar axis
        // refuses the feature; it must never reuse the line the axis had when
        // the revolve was authored (that would silently keep old geometry).
        let axis: RevolveAxis
        switch state.resolveAxis(axisRef, plane: plane) {
        case let .success(resolved):
            axis = resolved
        case let .failure(error):
            state.errors[node.id] = .brokenRef("revolve axis unresolved: \(error.message)")
            return
        }
        // KernelOps.revolve returns an EMPTY mesh when the profile crosses/collapses
        // onto the axis — emitFullSolid maps that to .emptyGeometry.
        let mesh = KernelOps.revolve(
            profile: outer, holes: holes, in: plane, axis: axis, angle: angle.value)
        // Analytic revolve: a revolved circle is a torus, not 48 flat strips —
        // and until this landed, a revolve was the commonest way to end up with
        // a brep-less body, which then took the slow mesh path for every fillet
        // and could not be exported to STEP at all.
        // `RevolveAxis` is 2D IN THE SKETCH PLANE, while OCCT wants a world
        // axis — lift it through the plane's own basis rather than assuming
        // the two agree.
        let axisWorldOrigin = plane.origin
            + plane.xAxis * axis.point.x + plane.yAxis * axis.point.y
        let axisWorldDirection =
            plane.xAxis * axis.direction.x + plane.yAxis * axis.direction.y
        let history: OCCTShapeHistory? =
            OCCTKernel.useOCCTAsSourceOfTruth ? OCCTShapeHistory() : nil
        let brep = OCCTKernel.useOCCTAsSourceOfTruth
            ? OCCTKernel.revolveSolid(
                outer: outer, holes: holes, plane: plane,
                axisOrigin: axisWorldOrigin, axisDirection: axisWorldDirection,
                angleRadians: angle.value * .pi / 180,
                history: history)
            : nil
        let names = (brep != nil ? history : nil).map {
            ElementNaming.extrudeNames(creator: node.id,
                                       ancestry: ShapeAncestry($0),
                                       outer: outer, holes: holes)
        } ?? [:]
        emitFullSolid(node, mesh: mesh, brep: brep, kernelNames: names,
                      boolean: boolean, scheme: .revolve,
                      into: &state, next: nextRevision)
    }

    // MARK: - Mechanical hole (M12)

    /// Cut one typed hole with the existing exact revolve + boolean.
    ///
    /// The locating circle owns centre and pilot diameter. The tool is the
    /// axial (r, t) section revolved 360°; `t = 0` is the placement plane,
    /// positive t points along `+plane.normal` unless `reversed`. Through reach
    /// projects the target's world AABB onto that axis — never a fixed depth.
    /// Any refusal (non-circle profile, mesh target, invalid spec, invalid
    /// tool, no material removed, non-single/ill solid) emits no body and
    /// leaves the input untouched. There is deliberately NO mesh fallback.
    private func evalHole(
        _ node: FeatureNode,
        targetRef: BodyRef,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        spec: HoleSpec,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("hole plane unresolved")
            return
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("hole profile unresolved")
            return
        }
        guard holes.isEmpty, case let .circle(center, radius) = outer.kind else {
            state.errors[node.id] = .kernelFailure(
                "hole placement needs exactly one circular profile with no inner loops")
            return
        }
        let pilotDiameter = radius * 2
        if let issue = HoleKit.validationIssue(spec, pilotDiameter: pilotDiameter) {
            state.errors[node.id] = .kernelFailure("hole: \(issue)")
            return
        }
        guard let target = state.bodies[targetRef.bodyID] else {
            state.errors[node.id] = .brokenRef("hole target unresolved")
            return
        }
        if refuseExactSurface(node, "Hole", body: target, into: &state) { return }
        guard let targetBrep = target.brep else {
            state.errors[node.id] = .kernelFailure(
                "hole requires a B-rep target; a mesh body cannot host an exact hole")
            return
        }
        guard let worldTarget = OCCTKernel.transformed(targetBrep, by: target.transform) else {
            state.errors[node.id] = .kernelFailure("hole target could not be placed in world space")
            return
        }
        let normal = plane.normal
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite,
              simd_length(normal) > 1e-9 else {
            state.errors[node.id] = .kernelFailure("hole placement plane has no usable normal")
            return
        }
        let unitNormal = simd_normalize(normal)
        let inward = spec.reversed ? -unitNormal : unitNormal
        var radial = plane.xAxis - simd_dot(plane.xAxis, inward) * inward
        guard radial.x.isFinite, radial.y.isFinite, radial.z.isFinite,
              simd_length(radial) > 1e-9 else {
            state.errors[node.id] = .kernelFailure("hole placement plane has no stable radial axis")
            return
        }
        radial = simd_normalize(radial)
        let entry = plane.toWorld(center)
        guard let box = MeasureKit.boundingBox(bodies: [target]),
              let range = HoleKit.projectedRange(
                minimum: box.min, maximum: box.max, entry: entry, inward: inward) else {
            state.errors[node.id] = .kernelFailure("hole target has no measurable extent along the drill axis")
            return
        }
        // The chosen drill direction must actually point into the material:
        // a plane on the far side whose normal points AWAY would otherwise
        // only shave the 1 mm lead-in disc. This is direction validation, not
        // a material-side guess — the caller chose the direction explicitly.
        guard range.upperBound > 1e-7 else {
            state.errors[node.id] = .kernelFailure(
                "hole direction points away from the target material")
            return
        }
        guard let cutter = HoleKit.cutterProfile(
            pilotRadius: radius, spec: spec, worldRange: range) else {
            state.errors[node.id] = .kernelFailure("hole produced no valid cutter profile")
            return
        }
        let axialPlane = SketchPlane(origin: entry, xAxis: radial, yAxis: inward)
        let toolProfile = Profile(loop: cutter.points, kind: .polygonal, sourceEntityIDs: [])
        let toolHistory = OCCTShapeHistory()
        guard let tool = OCCTKernel.revolveSolid(
            outer: toolProfile, holes: [], plane: axialPlane,
            axisOrigin: entry, axisDirection: inward,
            angleRadians: 2 * .pi, history: toolHistory) else {
            state.errors[node.id] = .kernelFailure("hole cutter revolve was refused")
            return
        }
        let toolHealth = OCCTKernel.healthReport(for: tool)
        guard toolHealth.error == nil, toolHealth.isValid,
              toolHealth.counts["solids"] == 1, toolHealth.openFreeWires == 0 else {
            state.errors[node.id] = .kernelFailure("hole cutter is not a valid solid: \(toolHealth.findingsSummary)")
            return
        }
        let toolNames = ElementNaming.holeToolNames(
            creator: node.id, ancestry: ShapeAncestry(toolHistory), roles: cutter.roles)
        switch OCCTKernel.booleanResultWithAncestry(
            worldTarget, tool, op: OCCTKernel.booleanOp(.subtract)) {
        case let .success((outcome, ancestry)):
            guard outcome.solidCount == 1 else {
                state.errors[node.id] = .kernelFailure(
                    "hole subtraction produced \(outcome.solidCount) solids")
                return
            }
            let before = OCCTKernel.volume(worldTarget)
            let after = OCCTKernel.volume(outcome.handle)
            let tolerance = max(1e-7, max(abs(before), 1) * 1e-9)
            guard before > 0, after > 0, after < before - tolerance else {
                state.errors[node.id] = .kernelFailure(
                    "hole removes no material from the target (check the target and drill direction)")
                return
            }
            let health = OCCTKernel.healthReport(for: outcome.handle)
            guard health.error == nil, health.isValid,
                  health.counts["solids"] == 1, health.openFreeWires == 0 else {
                state.errors[node.id] = .kernelFailure(
                    "hole result is not a valid single solid: \(health.findingsSummary)")
                return
            }
            var result = Body(
                id: target.id, name: target.name, transform: .identity, primitive: nil,
                euclidMesh: Euclid.Mesh([]), revision: nextRevision())
            guard result.adoptBRep(outcome.handle) else {
                state.errors[node.id] = .emptyGeometry
                return
            }
            let names = ElementNaming.holeNames(
                operation: node.id, ancestry: ancestry,
                targetNames: state.kernelNames[target.id] ?? [:], toolNames: toolNames)
            var table = state.naming.faceTable(
                for: result, createdBy: node.id, scheme: .generic)
            if !names.isEmpty {
                table = ElementNaming.attach(
                    names, to: table,
                    channel: OCCTKernel.renderMeshFaceChannel(from: outcome.handle), body: result)
            }
            if state.requestedFeatureTools.contains(node.id) {
                var sourceTool = Body(name: "Hole tool", euclidMesh: Euclid.Mesh([]), revision: 0)
                sourceTool.brep = tool
                state.publishTool(for: node.id, body: sourceTool, names: toolNames, operation: .subtract, target: target.id)
            }
            state.put(result, table: table)
            if !names.isEmpty { state.kernelNames[result.id] = names }
        case let .failure(error):
            state.errors[node.id] = .kernelFailure("hole: \(error.message)")
        }
    }

    private func evalSweep(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        spine: [PointWrapper],
        boolean: BooleanIntent,
        helix: HelixSpec? = nil,
        path: SweepPathDefinition? = nil,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        // The saved-document path. A store, merge or import can hand the
        // evaluator any helix values without passing through `parseHelix`;
        // reject a malformed/oversized spec HERE, before resolving geometry,
        // sampling or calling the exact-helix kernel. The existing per-node
        // error/checkpoint path then keeps the original body/history intact.
        if let helix, let helixError = helix.samplingError() {
            state.errors[node.id] = .kernelFailure(
                "sweep helix refused: \(helixError.message)")
            return
        }
        let resolvedSpine: [PointWrapper]
        if let path {
            guard helix == nil else {
                state.errors[node.id] = .brokenRef("A sweep cannot use both a helix and sketch-edge path.")
                return
            }
            do {
                resolvedSpine = try path.resolvedSpine { id in
                    state.sketch(id)
                }.map(PointWrapper.init)
            } catch {
                state.errors[node.id] = .brokenRef("sweep path: \(error.localizedDescription)")
                return
            }
        } else { resolvedSpine = spine }
        guard var plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("sweep plane unresolved")
            return
        }
        if let helix, let anchor = helix.profileAnchor {
            // Keep the original normal offset as well as the two planar
            // coordinates. Projecting it away would move a valid section
            // when the helix starts at a non-zero angle.
            let attached = plane.toWorld(SIMD2(anchor.x, anchor.y)) + plane.normal * anchor.z
            let shift = helix.point(at: helix.startAngle) - attached
            let origin = plane.origin + shift
            guard shift.x.isFinite, shift.y.isFinite, shift.z.isFinite,
                  origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else {
                state.errors[node.id] = .kernelFailure("The helix section attachment is outside the coordinate range.")
                return
            }
            plane.origin = origin
        }
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("sweep profile unresolved")
            return
        }
        // The render mesh follows the sampled polyline either way; the B-rep
        // follows the EXACT helix when the node carries one (`HelixSpec`).
        // Check the profile × spine multiplication before copying/deduplicating
        // the spine or building any polygon: a short helix can still generate
        // an unusable wall mesh for a dense profile.
        if helix != nil || path != nil {
            let loopVertices = outer.loop.count
                + holes.reduce(0) { $0 + $1.loop.count }
            if let meshError = HelixSamplingLimits.sweepMeshError(
                spinePointCount: resolvedSpine.count, loopVertexCount: loopVertices) {
                state.errors[node.id] = .kernelFailure(
                    "sweep helix refused: \(meshError)")
                return
            }
        }
        let spinePts = resolvedSpine.map(\.point)   // WORLD-space 3D points
        let mesh = SweepLoftKit.sweep(profile: outer, holes: holes, in: plane, alongPath: spinePts)
        var brep: BRepHandle? = nil
        var names: [Int: ElementName] = [:]
        if OCCTKernel.useOCCTAsSourceOfTruth {
            // Sweep the OUTER alone, named from its profile; then each hole as
            // its own tube, named from ITS hole entity, subtracted with
            // ancestry and composed — exactly as the drafted bore does. The
            // bridge's own in-sweep cut would leave the bore walls nameless
            // (its history covers the outer sweep only), so a holed sweep's
            // bore could only be found by geometry, never by identity.
            let history = OCCTShapeHistory()
            guard var solid = OCCTKernel.sweepSolid(outer: outer, holes: [], plane: plane,
                                                    spine: spinePts, helix: helix, history: history) else {
                if path != nil || helix != nil {
                    state.errors[node.id] = .kernelFailure("The associated sweep could not build an exact solid.")
                    return
                }
                emitFullSolid(node, mesh: mesh, brep: nil, kernelNames: [:],
                              boolean: boolean, scheme: .generic,
                              into: &state, next: nextRevision)
                return
            }
            names = ElementNaming.extrudeNames(creator: node.id, ancestry: ShapeAncestry(history),
                                               outer: outer, holes: [])
            for hole in holes {
                let boreHistory = OCCTShapeHistory()
                guard let bore = OCCTKernel.sweepSolid(outer: hole, holes: [], plane: plane,
                                                       spine: spinePts, helix: helix, history: boreHistory) else {
                    state.errors[node.id] = .kernelFailure("sweep hole tube failed")
                    return
                }
                let boreNames = ElementNaming.extrudeNames(creator: node.id, ancestry: ShapeAncestry(boreHistory),
                                                           outer: hole, holes: [])
                switch OCCTKernel.booleanResultWithAncestry(solid, bore, op: OCCTKernel.booleanOp(.subtract)) {
                case let .success((outcome, ancestry)):
                    solid = outcome.handle
                    names = ElementNaming.composeNames(operation: node.id, ancestry: ancestry,
                                                       inputNames: [names, boreNames])
                case let .failure(error):
                    state.errors[node.id] = .kernelFailure("sweep hole cut: \(error.message)")
                    return
                }
            }
            brep = solid
        }
        emitFullSolid(node, mesh: mesh, brep: brep, kernelNames: names,
                      nativeRender: true,
                      boolean: boolean, scheme: .generic,
                      into: &state, next: nextRevision)
    }

    private func evalLoft(
        _ node: FeatureNode,
        sectionRefs: [ProfileRef],
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        // Resolve each section's profile (outer + holes) AND its plane, in order.
        // ANY unresolvable section is a broken reference: error out rather than
        // silently lofting a subset (e.g. deleting a middle section's sketch must
        // surface a broken-ref badge, not reshape the body into an A->C loft the
        // user never authored). Matches revolve/sweep/mirror's error contract.
        var sections: [(profile: Profile, holes: [Profile], plane: SketchPlane)] = []
        for ref in sectionRefs {
            guard let (outer, holes) = state.resolveProfile(ref),
                  let plane = state.resolvePlane(PlaneRef(source: .sketch(ref.sketchID))) else {
                state.errors[node.id] = .brokenRef("loft section profile/plane unresolved")
                return
            }
            sections.append((outer, holes, plane))
        }
        guard sections.count >= 2 else {
            state.errors[node.id] = .brokenRef("loft needs >= 2 sections")
            return
        }
        let mesh = SweepLoftKit.loft(profiles: sections)
        // OCCT's ThruSections takes ONE wire per section, so a section with
        // holes cannot be expressed; those keep the mesh result rather than
        // silently losing their inner loops.
        let analytic = OCCTKernel.useOCCTAsSourceOfTruth
            && sections.allSatisfy { $0.holes.isEmpty }
        let history: OCCTShapeHistory? = analytic ? OCCTShapeHistory() : nil
        let brep = analytic
            ? OCCTKernel.loftSolid(sections: sections.map { ($0.profile, $0.plane) },
                                   history: history)
            : nil
        // Walls are named for the FIRST section's profile edges (ThruSections
        // makes one lateral face per corresponding edge column); the two caps
        // come from FirstShape/LastShape. Later sections' identities are not
        // separately expressible — a wall spans them all — which is the
        // deferred half of loft naming the design doc records.
        let names = (brep != nil ? history : nil).map {
            ElementNaming.extrudeNames(creator: node.id,
                                       ancestry: ShapeAncestry($0),
                                       outer: sections[0].profile, holes: [])
        } ?? [:]
        emitFullSolid(node, mesh: mesh, brep: brep, kernelNames: names,
                      boolean: boolean, scheme: .loftCaps(
                        start: sections[0].plane, end: sections[sections.count - 1].plane),
                      into: &state, next: nextRevision)
    }

    // MARK: Draft / taper extrude (playbook M1)

    /// Extrude with draft: loft the profile to an OFFSET copy of itself
    /// `distance` away, so the walls slope by `taperAngle`. A positive angle
    /// CONTRACTS the section along the extrude direction (mould-release draft —
    /// wider at the base); offset = −tan(angle)·distance. Slice 1: hole-free
    /// profiles, single direction (see `docs/DRAFT_TAPER_DESIGN.md`).
    private func evalDraftExtrude(
        _ node: FeatureNode,
        profileRef: ProfileRef,
        planeRef: PlaneRef,
        distance: Expr,
        taperAngle: Expr,
        symmetric: Bool,
        boolean: BooleanIntent,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let (outer, holes) = state.resolveProfile(profileRef) else {
            state.errors[node.id] = .brokenRef("draft-extrude profile unresolved")
            return
        }
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("draft-extrude plane unresolved")
            return
        }
        let d = distance.value
        guard abs(d) > 1e-9 else {
            state.errors[node.id] = .kernelFailure("draft-extrude distance must be non-zero")
            return
        }
        // The outer boundary contracts along the extrude by `offsetDistance`;
        // every HOLE offsets the OPPOSITE way (a bore widens toward the far
        // end, so a core pin releases), keeping the wall's draft consistent.
        // `symmetric` drafts BOTH ways from the sketch plane (±d), so the base
        // profile is the widest section in the middle and both ends taper.
        let offsetDistance = -tan(taperAngle.value * .pi / 180) * d
        func polyProfile(_ loop: [SIMD2<Double>], from src: Profile) -> Profile {
            // POLYLINE sections so the loft matches edge-for-edge (a conic base
            // against a polygonal top would desync ThruSections).
            Profile(loop: loop, kind: .polygonal,
                    sourceEntityIDs: src.sourceEntityIDs, edgeEntityIDs: src.edgeEntityIDs)
        }
        // A concentric circle at `radius`, kept as an exact conic so the loft
        // reads its `.circle` kind and builds a single conic wire.
        func circleProfile(center: SIMD2<Double>, radius: Double, from src: Profile) -> Profile {
            let n = ProfileDetector.circleSegments
            let loop = (0..<n).map { i -> SIMD2<Double> in
                let a = Double(i) / Double(n) * 2 * Double.pi
                return center + SIMD2(cos(a), sin(a)) * radius
            }
            return Profile(loop: loop, kind: .circle(center: center, radius: radius),
                           sourceEntityIDs: src.sourceEntityIDs)
        }
        // For a profile, the base (at the sketch plane) and its offset copy.
        func sections(_ p: Profile, offsetBy dist: Double) -> (base: Profile, offset: Profile)? {
            // A circle's offset is EXACT — a concentric circle of radius ± dist.
            // This sidesteps OCC's single-edge-wire 2D offset (the gotcha
            // FreeCAD flags) AND lofts conic→conic, so a drafted circle becomes
            // a true cone frustum with ONE conical wall, not a 48-facet shell.
            if case let .circle(center, radius) = p.kind {
                let newRadius = radius + dist          // +dist expands, −dist contracts
                guard newRadius > 1e-6 else { return nil }
                return (p, circleProfile(center: center, radius: newRadius, from: p))
            }
            // A boundary WITH arcs (rounded rectangle, slot): offset the exact
            // segments — lines shift, arcs stay concentric — and loft both
            // sections on the segments channel, so a drafted arc wall is a true
            // cone. Both sections are tessellated by the same sampler so the
            // render loft pairs points 1:1. A joint that is not exactly
            // offsettable (nil) falls through to the polygon path below.
            if p.segments.contains(where: { $0.mid != nil }),
               let off = SegmentOffset.offset(p.segments, by: dist) {
                func exact(_ segs: [Profile.Segment]) -> Profile {
                    Profile(loop: SegmentOffset.loop(from: segs), kind: .polygonal,
                            sourceEntityIDs: p.sourceEntityIDs, segments: segs,
                            segmentEntityIDs: p.segmentEntityIDs)
                }
                return (exact(p.segments), exact(off))
            }
            guard let off = ProfileOffset.offsetLoop(p.loop, by: dist) else { return nil }
            return (polyProfile(p.loop, from: p), polyProfile(off, from: p))
        }
        guard let outerS = sections(outer, offsetBy: offsetDistance) else {
            state.errors[node.id] = .kernelFailure(
                "the taper offsets the profile into itself — reduce the angle or the depth")
            return
        }
        var holeS: [(base: Profile, offset: Profile)] = []
        for hole in holes {
            guard let s = sections(hole, offsetBy: -offsetDistance) else {
                state.errors[node.id] = .kernelFailure(
                    "the taper offsets a hole into itself — reduce the angle or the depth")
                return
            }
            holeS.append(s)
        }

        let n = simd_normalize(plane.normal)
        func planeAt(_ t: Double) -> SketchPlane {
            SketchPlane(origin: plane.origin + n * t,
                        xAxis: plane.xAxis, yAxis: plane.yAxis)
        }
        // The stack of section planes and whether each uses the OFFSET profile:
        // symmetric drafts an offset end at ±d with the base in the middle.
        let stack: [(plane: SketchPlane, offset: Bool)] = symmetric
            ? [(planeAt(-d), true), (planeAt(0), false), (planeAt(d), true)]
            : [(planeAt(0), false), (planeAt(d), true)]

        func pick(_ s: (base: Profile, offset: Profile), _ useOffset: Bool) -> Profile {
            useOffset ? s.offset : s.base
        }
        // Render mesh: one lofted shell with the holes carried per section.
        let mesh = SweepLoftKit.loft(profiles: stack.map { step in
            (pick(outerS, step.offset), holeS.map { pick($0, step.offset) }, step.plane)
        })

        // B-rep: loft the outer through the stack, then subtract each hole's
        // own loft, composing names through each subtraction so the result is
        // identity-named throughout — outer walls by the outer entity, bore
        // walls by their hole entity, caps by the outer loft.
        var brep: BRepHandle?
        var names: [Int: ElementName] = [:]
        if OCCTKernel.useOCCTAsSourceOfTruth {
            let history = OCCTShapeHistory()
            // RULED: a symmetric draft's three sections must be two frustums
            // back to back; ThruSections' smooth surface bulges through the
            // middle section (found against the wheel's conical cutters).
            guard var solid = OCCTKernel.loftSolid(
                sections: stack.map { (pick(outerS, $0.offset), $0.plane) },
                ruled: symmetric, history: history) else {
                state.errors[node.id] = .kernelFailure("draft-extrude loft failed")
                return
            }
            // Name the outer loft from its profile. With holes, name each bore
            // loft from ITS hole profile — so a bore wall carries the hole
            // entity's identity — and compose through every subtraction
            // exactly as evalBoolean does. A drafted bore's walls then resolve
            // by identity for downstream edits, not by geometry.
            names = ElementNaming.extrudeNames(
                creator: node.id, ancestry: ShapeAncestry(history),
                outer: pick(outerS, stack[0].offset), holes: [])
            for hs in holeS {
                let boreHistory = OCCTShapeHistory()
                guard let bore = OCCTKernel.loftSolid(
                        sections: stack.map { (pick(hs, $0.offset), $0.plane) },
                        ruled: symmetric, history: boreHistory) else {
                    state.errors[node.id] = .kernelFailure("draft-extrude hole loft failed")
                    return
                }
                let boreNames = ElementNaming.extrudeNames(
                    creator: node.id, ancestry: ShapeAncestry(boreHistory),
                    outer: pick(hs, stack[0].offset), holes: [])
                switch OCCTKernel.booleanResultWithAncestry(
                    solid, bore, op: OCCTKernel.booleanOp(.subtract)) {
                case let .success((outcome, ancestry)):
                    solid = outcome.handle
                    names = ElementNaming.composeNames(
                        operation: node.id, ancestry: ancestry,
                        inputNames: [names, boreNames])
                case let .failure(error):
                    state.errors[node.id] = .kernelFailure("draft-extrude hole cut: \(error.message)")
                    return
                }
            }
            brep = solid
        }
        emitFullSolid(node, mesh: mesh, brep: brep, kernelNames: names,
                      boolean: boolean, scheme: .generic,
                      into: &state, next: nextRevision)
    }

    // MARK: Mirror

    private func evalMirror(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        planeRef: PlaneRef,
        keepOriginal: Bool,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        guard let input = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("mirror body unresolved")
            return
        }
        guard let plane = state.resolvePlane(planeRef) else {
            state.errors[node.id] = .brokenRef("mirror plane unresolved")
            return
        }
        // Reflect the input in world space (its transform is identity in replay,
        // but bake it in to stay correct if that ever changes).
        let worldInput = input.euclidMesh().transformed(by: input.transform.euclid)
        let mirrored = KernelOps.mirror(mesh: worldInput, across: plane)
        guard !mirrored.polygons.isEmpty else {
            state.errors[node.id] = .emptyGeometry
            return
        }
        guard let id = node.outputBodyIDs.first else {
            state.errors[node.id] = .brokenRef("mirror node has no output BodyID")
            return
        }
        // The mirror node ADDS its own output body; with keepOriginal false the
        // source is consumed as well (removed below, after the copy is placed),
        // so "mirror to the other side" leaves one body, not two.
        var body = Body(
            id: id, name: node.name, transform: .identity, primitive: nil,
            euclidMesh: mirrored, revision: nextRevision())
        // Reflect the solid alongside the mesh. The mirrored body's transform
        // is identity, so its local space IS world space — the source's own
        // transform is baked in first, exactly as the mesh above does it.
        // `brep` is assigned rather than adopted so the render mesh stays the
        // Euclid mirror that existing coverage measures; the brep is what
        // downstream fillets, booleans and STEP will read.
        if OCCTKernel.useOCCTAsSourceOfTruth, let sourceBrep = input.brep,
           let placed = OCCTKernel.transformed(sourceBrep, by: input.transform) {
            body.brep = OCCTKernel.mirrored(
                placed, origin: plane.origin, normal: simd_normalize(plane.normal))
        } else if input.surfaceBRep != nil {
            // A reflected open sheet is still exact. Falling through to the
            // Euclid mesh would silently drop the source's surfaceBRep from
            // the copy; refuse instead of shipping a mesh-only reflection.
            guard let surface = input.surfaceBRep,
                  let placed = OCCTKernel.transformed(surface, by: input.transform),
                  let reflected = OCCTKernel.mirrored(
                    placed, origin: plane.origin, normal: simd_normalize(plane.normal))
            else {
                state.errors[node.id] = .kernelFailure(
                    "mirror: the exact open surface could not be reflected; "
                        + "the original was preserved.")
                return
            }
            body.surfaceBRep = reflected
        }
        let table = state.naming.faceTable(for: body, createdBy: node.id, scheme: .generic)
        state.put(body, table: table)
        // A mirror is a copying isometry: the reflected shape is
        // subshape-for-subshape isomorphic to its source, so element names
        // carry over BY INDEX (pinned by the centroid-reflection test).
        // Names are body-scoped, so the copy sharing the source's names is
        // unambiguous.
        if body.brep != nil, let sourceNames = state.kernelNames[bodyRef.bodyID],
           !sourceNames.isEmpty {
            state.kernelNames[id] = sourceNames
        }
        if !keepOriginal {
            state.remove(bodyRef.bodyID)
        }
    }

    // MARK: Pattern

    /// Linear/circular body pattern. The source body (already in `state`) stays
    /// PUT; the pattern only ADDS `count − 1` copies. Each copy reuses one of the
    /// node's pre-allocated `outputBodyIDs` (the recording/edit layer owns id
    /// allocation — never mint here), carries the composed instance transform, and
    /// reuses the source's LOCAL mesh (the app's live pattern does the same:
    /// copy transform = composed(instanceₙ, base: source.transform), mesh = source
    /// local mesh). If fewer `outputBodyIDs` are supplied than copies are needed,
    /// only the ids we have are emitted.
    private func evalPattern(
        _ node: FeatureNode,
        bodyRef: BodyRef,
        spec: PatternSpec,
        into state: inout EvalState,
        next nextRevision: () -> UInt64
    ) {
        do { try spec.validate() } catch { state.errors[node.id] = .brokenRef(error.localizedDescription); return }
        guard let source = state.bodies[bodyRef.bodyID] else {
            state.errors[node.id] = .brokenRef("pattern body unresolved")
            return
        }
        // M08: an associative pattern resolves its axis's CURRENT line from the
        // document resolver on every replay. A broken/missing source refuses
        // explicitly and emits no copy — it never falls back to the cached
        // `spec.axis`/`spec.center`, which would silently keep spinning about a
        // stale line after the user moved the axis source.
        var line = (direction: spec.axis, center: spec.center)
        if let ref = spec.axisRef {
            guard let resolved = try? state.associative.axis(ref.axisID) else {
                state.errors[node.id] = .brokenRef("pattern axis unresolved")
                return
            }
            line = (resolved.geometry.direction, resolved.geometry.origin)
        }
        // Instance transforms; element 0 is identity (the original / source body,
        // which is NOT re-emitted). Matches EditorViewModel.patternTransforms.
        let transforms: [Transform3D]
        switch spec.kind {
        case .linear:
            transforms = PatternKit.linearTransforms(
                direction: line.direction, spacing: spec.spacing, count: max(1, spec.count))
        case .circular:
            transforms = PatternKit.circularTransforms(
                center: line.center, axis: line.direction, count: max(1, spec.count),
                totalAngle: spec.totalAngle, rotateInstances: spec.rotateInstances)
        case .curve:
            guard let path = spec.curvePath, spec.axisRef == nil else {
                state.errors[node.id] = .brokenRef("Select the curve pattern's path without a separate axis.")
                return
            }
            do {
                transforms = try path.transforms(count: spec.count, spacing: spec.spacing,
                    rotate: spec.rotateInstances, sketch: { state.sketch($0) })
            } catch {
                state.errors[node.id] = .brokenRef(error.localizedDescription)
                return
            }
        }

        if let seed = spec.featureSeed {
            do { try seed.validate() } catch {
                state.errors[node.id] = .brokenRef(error.localizedDescription); return
            }
            guard state.errors[seed.featureID] == nil, let tool = state.featureTools[seed.featureID],
                  tool.targetBodyID == bodyRef.bodyID, source.brep != nil,
                  node.outputBodyIDs == [bodyRef.bodyID] else {
                state.errors[node.id] = .brokenRef("The selected feature has no usable exact tool on this target. Use its original retained split output or select another seed explicitly.")
                return
            }
            evalFeaturePattern(node, target: source, tool: tool, transforms: transforms, into: &state, next: nextRevision)
            return
        }

        let localMesh = source.euclidMesh()  // source stays put; copies reuse its local mesh
        for i in 1..<transforms.count {
            let idIndex = i - 1
            guard idIndex < node.outputBodyIDs.count else { break } // never mint ids in eval
            var copy = Body(
                id: node.outputBodyIDs[idIndex],
                name: node.name,
                transform: Self.composePatternTransform(transforms[i], base: source.transform),
                primitive: nil,
                euclidMesh: localMesh,
                revision: nextRevision())
            // A pattern copy is the SAME body-local geometry at a different
            // placement, and `brep` — like `render` — is body-local with the
            // placement held in `transform`. So the copy shares the source's
            // solid outright: no OCCT call, and no reason for patterning to be
            // the step that costs a part its analytic geometry. (`BRepHandle`
            // is a reference type and nothing mutates one in place; every
            // kernel op returns a new handle.)
            copy.brep = source.brep
            copy.surfaceBRep = source.surfaceBRep
            let table = state.naming.faceTable(for: copy, createdBy: node.id, scheme: .generic)
            state.put(copy, table: table)
            // The copy IS the source solid (shared handle, placement in
            // `transform`), so its element names are the source's, verbatim.
            if copy.brep != nil,
               let sourceNames = state.kernelNames[bodyRef.bodyID],
               !sourceNames.isEmpty {
                state.kernelNames[copy.id] = sourceNames
            }
        }
    }

    private func evalFeaturePattern(_ node: FeatureNode, target: Body, tool: PatternToolSnapshot,
                                    transforms: [Transform3D], into state: inout EvalState,
                                    next nextRevision: () -> UInt64) {
        var result = target
        var names = state.kernelNames[target.id] ?? [:]
        for i in 1..<transforms.count {
            var instance = tool.body
            instance.transform = transforms[i].composed(onto: tool.body.transform)
            guard let outcome = OCCTKernel.composedBooleanResultWithAncestry(tool.operation,
                target: result, tool: instance) else {
                state.errors[node.id] = .kernelFailure("Feature pattern requires exact solid operands."); return
            }
            switch outcome {
            case let .failure(error):
                state.errors[node.id] = .kernelFailure("Pattern instance \(i + 1): \(error.message)"); return
            case let .success((shape, ancestry)):
                let health = OCCTKernel.healthReport(for: shape.handle)
                guard shape.solidCount == 1, health.error == nil, health.isValid, health.openFreeWires == 0 else {
                    state.errors[node.id] = .kernelFailure("Pattern instance \(i + 1) does not produce one valid solid."); return
                }
                guard let prior = result.brep, let world = OCCTKernel.transformed(prior, by: result.transform) else {
                    state.errors[node.id] = .kernelFailure("The pattern target could not be placed."); return
                }
                let before = abs(OCCTKernel.volume(world)), after = abs(OCCTKernel.volume(shape.handle))
                let tolerance = max(1, before) * 1e-9
                let changed = tool.operation == .subtract ? after < before - tolerance : after > before + tolerance
                guard changed, after > tolerance else {
                    state.errors[node.id] = .kernelFailure("Pattern instance \(i + 1) changes no target material. Adjust its placement."); return
                }
                var next = Body(id: target.id, name: target.name, euclidMesh: Euclid.Mesh([]), revision: nextRevision())
                guard next.adoptBRep(shape.handle) else {
                    state.errors[node.id] = .emptyGeometry; return
                }
                let instanceNames = tool.names.mapValues {
                    ElementName(creator: node.id, source: .patternInstance(version: 1, pattern: node.id, index: i, source: $0))
                }
                names = ElementNaming.composeNames(operation: node.id, ancestry: ancestry,
                    inputNames: [names, instanceNames], adjacency: OCCTKernel.edgeFaceAdjacency(shape.handle))
                result = next.keepingAppearance(of: target)
            }
        }
        var table = state.naming.faceTable(for: result, createdBy: node.id, scheme: .generic)
        if let solid = result.brep {
            table = ElementNaming.attach(names, to: table,
                channel: OCCTKernel.renderMeshFaceChannel(from: solid), body: result)
        }
        state.put(result, table: table)
        if !names.isEmpty { state.kernelNames[result.id] = names }
    }

    /// Compose a pattern instance transform onto the source's base transform:
    /// world = pattern.rotation.act(base(x)) + pattern.translation, so rotation
    /// and translation pre-compose. Mirrors
    /// `EditorViewModel.composedPatternTransform` (kept here so eval stays
    /// `nonisolated` and free of the Editor layer).
    private static func composePatternTransform(
        _ pattern: Transform3D, base: Transform3D
    ) -> Transform3D {
        var result = base
        result.rotation = simd_normalize(pattern.rotation * base.rotation)
        result.translation = pattern.rotation.act(base.translation) + pattern.translation
        return result
    }
}

// MARK: - Live evaluation state

/// Mutable replay state: the live bodies (with a stable creation order), their
/// face tables, accumulated errors, and the sketch/plane inputs + resolvers.
private nonisolated struct EvalState {
    let sketches: [Sketch]
    let planes: [ConstructionPlane]
    let naming: TopoNaming
    var threadVariables: [String: Double] = [:]
    var requestedFeatureTools: Set<FeatureID> = []
    var featureTools: [FeatureID: PatternToolSnapshot] = [:]
    mutating func publishTool(for feature: FeatureID, body: Body, names: [Int: ElementName],
                              operation: BooleanKind, target: BodyID) {
        guard requestedFeatureTools.contains(feature), body.brep != nil,
              operation != .intersect else { return }
        featureTools[feature] = PatternToolSnapshot(body: body, names: names, operation: operation, targetBodyID: target)
        if let currentNode { journal[currentNode, default: EvalNodeDelta()].featureTools[feature] = featureTools[feature] }
    }
    var associative: AssociativeGeometryResolver

    var bodies: [BodyID: Body] = [:]
    var order: [BodyID] = []
    var faceTables: [BodyID: FaceTable] = [:]
    /// Per-body kernel-face name maps (1-based OCCT face index →
    /// ElementName) — the COMPOSABLE identity layer booleans inherit
    /// through (step 3). Transient like `faceTables`; `put` clears a
    /// replaced body's map so staleness is impossible by construction.
    var kernelNames: [BodyID: [Int: ElementName]] = [:]
    /// Step 5b: kinds whose legacy refs EARNED names this replay — applied
    /// by `DocumentSession.performRebuild` as `EditFeatureCommand`s inside
    /// the rebuild's own undo step, and deliberately ignored by the
    /// load/undo error replay, which must never mutate the document.
    var proposedUpgrades: [FeatureID: FeatureKind] = [:]
    var errors: [FeatureID: FeatureError] = [:]
    var resolvedExtrudeDistances: [FeatureID: Double] = [:]

    // MARK: Memo instrumentation (docs/INCREMENTAL_EVAL_DESIGN.md)

    /// The node being evaluated: `put`/`remove` journal against it. Nil while
    /// a cached delta is being re-applied, so a splice is never re-recorded.
    var currentNode: FeatureID? = nil
    var journal: [FeatureID: EvalNodeDelta] = [:]
    /// Per live body, the fingerprint of the node that last put it — what a
    /// consumer's own fingerprint reads, so a changed input changes the key.
    var stamps: [BodyID: UInt64] = [:]

    /// Insert or replace a body (keeping its slot on replace) with its face table.
    ///
    /// Always clears the body's kernel-face names: any op that replaces a
    /// body without composing names must not leave a STALE map behind — a
    /// wrong name is worse than none. Ops that did compose (creation ops,
    /// booleans) write `kernelNames[body.id]` back after this call.
    mutating func put(_ body: Body, table: FaceTable) {
        if bodies[body.id] == nil { order.append(body.id) }
        bodies[body.id] = body
        faceTables[body.id] = table
        kernelNames[body.id] = nil
        if let node = currentNode {
            journal[node, default: EvalNodeDelta()].ops.append(.put(body, table, kernelNames: nil))
        }
    }

    /// Remove a consumed body from the live set.
    mutating func remove(_ id: BodyID) {
        bodies[id] = nil
        faceTables[id] = nil
        kernelNames[id] = nil
        order.removeAll { $0 == id }
        if let node = currentNode {
            journal[node, default: EvalNodeDelta()].ops.append(.remove(id))
        }
    }

    /// Re-apply a recorded delta — the memo's splice. Does exactly what the
    /// node's own puts and removes did, in order, then restores the kernel
    /// names each put was back-filled with, and the node's error.
    mutating func apply(_ delta: EvalNodeDelta, for node: FeatureID) {
        for (feature, tool) in delta.featureTools { featureTools[feature] = tool }
        for op in delta.ops {
            switch op {
            case let .put(body, table, names):
                put(body, table: table)
                kernelNames[body.id] = names
            case let .remove(id):
                remove(id)
            }
        }
        if let error = delta.error { errors[node] = error }
    }

    // MARK: Reference resolution

    /// A `PlaneRef` → concrete `SketchPlane`.
    mutating func resolvePlane(_ ref: PlaneRef) -> SketchPlane? {
        switch ref.source {
        case let .sketch(sid):
            return sketch(sid)?.plane
        case let .construction(cid):
            guard let record = planes.first(where: { $0.id == cid }) else { return nil }
            if record.definition != nil { return try? associative.plane(ref).plane }
            return record.plane
        case .ground:
            return .ground
        case let .explicit(plane):
            return plane
        }
    }

    /// A `ProfileRef` → the outer `Profile` plus its hole profiles, detected from
    /// the referenced sketch. Matches the outer loop by entity ids (falling back
    /// to the seed point) and each hole loop by its recorded entity ids.
    mutating func resolveProfile(_ ref: ProfileRef) -> (outer: Profile, holes: [Profile])? {
        guard let sketch = sketch(ref.sketchID) else { return nil }
        let detected = ProfileDetector.detectProfiles(in: sketch)
        guard !detected.isEmpty else { return nil }

        let wanted = Set(ref.entityIDs)
        var outer: Profile?
        if !wanted.isEmpty {
            // Several regions can be bounded by the SAME entities — a circle
            // crossed by a rectangle's edge splits into two regions that both
            // list {circle, rect} — so the recorded seed decides between id
            // matches before the first match is taken on faith (practice
            // problem 4.38's counterbore, 2026-09-04: the wrong region replayed
            // and the touch commit fell back to a broken mesh).
            let exact = detected.filter { $0.sourceEntityIDs == wanted }
            let supersets = detected.filter { wanted.isSubset(of: $0.sourceEntityIDs) }
            if let seed = ref.seedPoint {
                outer = exact.first { $0.contains(seed) } ?? supersets.first { $0.contains(seed) }
            }
            outer = outer ?? exact.first ?? supersets.first
        }
        if outer == nil, let seed = ref.seedPoint {
            // Innermost enclosing region at the seed point.
            outer = ProfileDetector.profiles(at: seed, in: sketch).first
        }
        guard let outer else { return nil }

        var holes: [Profile] = []
        if ref.holeEntityIDs.isEmpty {
            // No explicit holes recorded — nothing to punch.
            holes = []
        } else {
            for group in ref.holeEntityIDs {
                let ids = Set(group)
                if let hole = detected.first(where: { $0.sourceEntityIDs == ids })
                    ?? detected.first(where: { ids.isSubset(of: $0.sourceEntityIDs) && $0.id != outer.id }) {
                    holes.append(hole)
                }
            }
        }
        return (outer, holes)
    }

    /// An `AxisRef` → a plane-local `RevolveAxis`. `.explicit` passes through;
    /// `.sketchLine` finds the named `.line` entity in the referenced sketch and
    /// builds an axis from its endpoints: point = a, direction = b − a.
    ///
    /// `.constructionAxis` resolves the axis IDENTITY through the document
    /// resolver on THIS replay and converts the real world line into the
    /// revolve plane's basis. A missing/broken source, or a line that is not in
    /// the plane, is an explicit failure — never the line the axis had when the
    /// revolve was created.
    mutating func resolveAxis(
        _ ref: AxisRef, plane: SketchPlane
    ) -> Result<RevolveAxis, AssociativeReferenceError> {
        switch ref.source {
        case let .explicit(axis):
            return .success(axis)
        case let .sketchLine(sid, entityID):
            guard let sketch = sketch(sid) else {
                return .failure(.invalidDefinition("the revolve axis sketch is missing"))
            }
            for entity in sketch.entities {
                if case let .line(id, a, b) = entity, id == entityID {
                    return .success(RevolveAxis(point: a, direction: b - a))
                }
            }
            return .failure(.invalidDefinition("the revolve axis sketch line is missing"))
        case let .constructionAxis(id):
            let resolved: ResolvedAssociativeAxis
            do {
                resolved = try associative.axis(id)
            } catch let error as AssociativeReferenceError {
                return .failure(error)
            } catch {
                return .failure(.invalidDefinition(error.localizedDescription))
            }
            do {
                return .success(try RevolveAxisBinding.planeLocal(
                    resolved.geometry, plane: plane))
            } catch let error as AssociativeAxisPointError {
                switch error {
                case let .axisNotInPlane(reason):
                    return .failure(.degenerateAxis(reason))
                case let .degenerateDirection(reason), let .degenerateReference(reason):
                    return .failure(.degenerateAxis(reason))
                default:
                    return .failure(.invalidDefinition(error.localizedDescription))
                }
            } catch {
                return .failure(.invalidDefinition(error.localizedDescription))
            }
        }
    }

    fileprivate mutating func sketch(_ id: SketchID) -> Sketch? {
        guard let record = sketches.first(where: { $0.id == id }) else { return nil }
        // M05: linked sketches resolve the same way supported ones do — the
        // resolver re-projects external entities and stamps the result, so
        // profile detection below sees current geometry, not a stale cache.
        if record.support != nil || record.hasExternalReferences {
            return try? associative.sketch(id).sketch
        }
        return record
    }
}

// MARK: - Small mappings

private nonisolated extension BooleanIntent.Op {
    /// The kernel boolean for this intent, or nil for `.newBody`.
    var kernelKind: BooleanKind? {
        switch self {
        case .newBody: return nil
        case .union: return .union
        case .subtract: return .subtract
        case .intersect: return .intersect
        }
    }
}

// MARK: - Conformance bridge for a reused kernel type
//
// `FeatureKind.boolean(kind: BooleanKind, …)` needs `BooleanKind` (a String raw
// enum in EditorMode.swift) to be Codable so `FeatureKind` synthesizes Codable.
// RawRepresentable-with-Codable-RawValue gives the encode/decode for free; the
// conformance just has to be stated. (It is already Sendable-usable — TopoOp
// wraps it — so only Codable is added here.)
nonisolated extension BooleanKind: Codable {}

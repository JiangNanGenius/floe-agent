//
//  OCCTKernel.swift
//  openshape3d — OCCT B-rep port, Milestone 1
//
//  Thin Swift-native wrapper over the Obj-C++ `OCCTBridge` facade. Everything
//  in the app (and `@testable` tests) talks to OCCT through this type, so the
//  Obj-C surface never leaks into feature/kernel code. As real ops are ported
//  (extrude, boolean, …) they land here, routed behind the `OS3D_BREP` flag
//  from `KernelOps`. For now it exposes the Milestone-0 spike surface so the
//  wiring is verifiable in-suite.
//

import OCCTShim
import Foundation
import simd

/// Owns an OCCT solid handle (`TopoDS_Shape`), world-space. Freed when the
/// handle is released.
///
/// `@unchecked Sendable` — CAVEAT (2026-08-25 review, S1): the shape is NOT
/// deeply immutable. `renderMesh(from:)` runs `BRepMesh_IncrementalMesh`,
/// which stores triangulations into the faces' shared `TShape`, and handles
/// are aliased (undo snapshots retain the same instance; identity transforms
/// return `self`). This is only safe because every OCCT call currently runs
/// on the MainActor. Before moving any OCCT work off-main, all access to
/// handles MUST be serialized on one executor — do not rely on this
/// annotation for actual thread safety.
nonisolated final class BRepHandle: @unchecked Sendable {
    let shape: OCCTShape
    init(_ shape: OCCTShape) { self.shape = shape }
}

/// Typed failure from an OCCT op — the bridge's `OCCTOpStatus` lifted into
/// Swift, so callers can finally say WHY an op failed instead of guessing
/// from a nil ("radius too large" was a guess covering six distinct causes).
/// `message` is ready-made copy for `EvalError.kernelFailure`.
nonisolated enum OCCTOpError: Error, Equatable {
    /// Nothing pickable within tolerance (or nothing usable — the string
    /// says which: seam edge, tangent edge, degenerate…).
    case noTargetMatched(String)
    /// The op succeeded on `requested - failed` targets and failed on the
    /// rest. The partial shape was DISCARDED, never returned.
    case partialResult(failed: Int, requested: Int)
    /// The op "succeeded" but its result failed validity checking (after one
    /// healing attempt) or a sanity check (a shell that removed no material).
    case invalidResult(String)
    /// The kernel declined the inputs or threw.
    case kernelRefused(String)

    init(_ status: OCCTOpStatus) {
        let detail = status.detail ?? "no diagnostic"
        switch status.code {
        case .noTargetMatched: self = .noTargetMatched(detail)
        case .partialResult:
            self = .partialResult(failed: status.failedCount,
                                  requested: status.requestedCount)
        case .invalidResult: self = .invalidResult(detail)
        default: self = .kernelRefused(detail)
        }
    }

    /// One user-facing sentence, specific enough to act on.
    var message: String {
        switch self {
        case let .noTargetMatched(detail):
            return detail
        case let .partialResult(failed, requested):
            return requested > 1
                ? "\(failed) of \(requested) edges can't take this size — "
                  + "try a smaller value or fewer edges"
                : "this size is too large for the local geometry — "
                  + "try a smaller value"
        case let .invalidResult(detail):
            return detail
        case let .kernelRefused(detail):
            return detail
        }
    }
}

/// What an IGES read actually contained, with solids and non-solid surfaces
/// kept apart. IGES files commonly carry only shells or isolated faces; a
/// shell is NOT a solid and must not enter the boolean/blend/shell paths, so
/// callers must be able to tell the two apart without re-inspecting topology.
/// Every item here already passed the bridge's finite-bounds gate and one
/// heal-and-validate pass; invalid roots were dropped before this result.
nonisolated struct IGESImport {
    /// Closed solids, one handle per TopAbs_SOLID.
    var solids: [BRepHandle]
    /// Shells/faces/compounds with no solid — exact geometry, but not solids.
    var surfaces: [BRepHandle]
    /// Parallel to `solids`: each solid's TopAbs_FACE count.
    var solidFaceCounts: [Int]
    /// Parallel to `surfaces`: each surface's TopAbs_FACE count.
    var surfaceFaceCounts: [Int]
    /// False when the reader refused the bytes outright (format/IO error).
    var readSucceeded: Bool
    /// Root shapes the reader transferred, before validation dropped any.
    /// 0 with `readSucceeded` means "parsed, but nothing to transfer".
    var rootCount: Int
}

/// Namespace for OCCT-backed geometry. `nonisolated` — kernel work runs off the
/// main actor, same contract as `KernelOps`.
nonisolated enum OCCTKernel {

    /// Tessellation quality for B-rep render meshes. Angular deflection (radians)
    /// governs facets-around-a-curve → roundness; it's size-independent.
    static let renderAngularDeflection = 0.08
    static let renderLinearDeflection = 0.1

    /// Master switch for the B-rep path. When true, solids that OCCT can build
    /// (extrudes, primitives, and booleans between them) carry an analytic
    /// `Body.brep` and derive BOTH their render and CSG meshes from it. Flip to
    /// false to fall back to the pure-Euclid kernel everywhere.
    static let useOCCTAsSourceOfTruth = true

    /// The linked OCCT version (proves the xcframework is present + linked).
    static var version: String { OCCTBridge.occtVersion() }

    /// A smooth, world-space render mesh for an extruded circle. The cylinder is
    /// built analytically in plane-local space (circle `center`/`radius`, spanning
    /// plane-local z ∈ [`zMin`,`zMax`]) then mapped to world through the sketch
    /// plane's orthonormal basis — matching where `KernelOps.extrude` places the
    /// Euclid solid, so geometry and display coincide.
    static func cylinderRenderMesh(
        center: SIMD2<Double>, radius: Double, zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>
    ) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        // ~0.08 rad angular deflection ≈ 80 facets around the circle (visually
        // round); linear deflection bounds chord error to a fraction of the size.
        let ang = 0.08
        let lin = max(radius, zMax - zMin) * 0.002
        let mesh = OCCTBridge.cylinderRenderMesh(
            withCenterX: center.x, centerY: center.y, radius: radius,
            zMin: zMin, zMax: zMax, angularDeflection: ang, linearDeflection: lin)

        let localPos = mesh.positions.floatArray()
        let localNrm = mesh.normals.floatArray()
        let indices = mesh.indices.uint32Array()

        let ox = SIMD3<Float>(Float(xAxis.x), Float(xAxis.y), Float(xAxis.z))
        let oy = SIMD3<Float>(Float(yAxis.x), Float(yAxis.y), Float(yAxis.z))
        let oz = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        let org = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))

        // Rotate a plane-local vector into world by the orthonormal basis.
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let a: SIMD3<Float> = ox * p.x
            let b: SIMD3<Float> = oy * p.y
            let c: SIMD3<Float> = oz * p.z
            return a + b + c
        }

        let n = mesh.vertexCount
        var positions = [SIMD3<Float>](); positions.reserveCapacity(n)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(n)
        for v in 0..<n {
            let lp = SIMD3<Float>(localPos[3*v], localPos[3*v+1], localPos[3*v+2])
            let ln = SIMD3<Float>(localNrm[3*v], localNrm[3*v+1], localNrm[3*v+2])
            positions.append(org + rotate(lp))
            normals.append(simd_normalize(rotate(ln)))
        }
        return (positions, normals, indices)
    }

    /// Plane-local z-span an extrude occupies, matching `KernelOps.extrude`'s
    /// placement: one-sided sits on the plane (`[min(0,d), max(0,d)]`), symmetric
    /// straddles it (`[-|d|, +|d|]`).
    static func extrudeZRange(distance d: Double, symmetric: Bool) -> (zMin: Double, zMax: Double) {
        symmetric ? (-abs(d), abs(d)) : (min(0, d), max(0, d))
    }

    // MARK: - B-rep source of truth (extrude → boolean → render)

    /// Build a world-space OCCT solid for an extruded profile. `outerLoop` is the
    /// plane-local boundary; when `isCircle` an analytic circle is used (true
    /// cylinder). `holes` are polygonal inner boundaries. Returns nil on failure.
    /// A true circle, in plane-local coordinates.
    /// An exact conic boundary: a circle or an ellipse.
    ///
    /// One type rather than two, because to every caller these are the same
    /// thing — "this whole loop is a curve OCCT can build exactly, so ignore
    /// the polyline". A circle is just the case where the semi-axes are equal,
    /// and the bridge picks `gp_Circ` or `gp_Elips` from that.
    nonisolated struct ConicSpec: Sendable, Equatable {
        var center: SIMD2<Double>
        /// Semi-axes BEFORE `rotation`; either may be the larger one.
        var radiusX: Double
        var radiusY: Double
        var rotation: Double

        init(center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double) {
            self.center = center
            self.radiusX = radiusX
            self.radiusY = radiusY
            self.rotation = rotation
        }

        init(center: SIMD2<Double>, radius: Double) {
            self.init(center: center, radiusX: radius, radiusY: radius, rotation: 0)
        }

        /// The conic a profile names, if it names one.
        init?(_ kind: Profile.Kind) {
            switch kind {
            case .polygonal:
                return nil
            case let .circle(center, radius):
                self.init(center: center, radius: radius)
            case let .ellipse(center, radiusX, radiusY, rotation):
                self.init(center: center, radiusX: radiusX,
                          radiusY: radiusY, rotation: rotation)
            }
        }
    }

    /// One inner boundary of an extrude profile.
    ///
    /// `circle` present = an analytic cylindrical wall; absent = the polyline
    /// it was drawn as. Carrying this per HOLE (rather than the single
    /// outer-loop `isCircle` flag the port shipped with) is what stops a plate
    /// with a Ø8 hole coming back with a 64-sided bore.
    nonisolated struct ExtrudeHole: Sendable {
        var loop: [SIMD2<Double>]
        /// The whole boundary as one exact curve, when it is one.
        var conic: ConicSpec?
        /// Exact boundary when the hole is neither a conic nor all-straight —
        /// a slot punched through a plate. See `Profile.Segment`.
        var segments: [Profile.Segment]

        init(loop: [SIMD2<Double>], conic: ConicSpec? = nil,
             segments: [Profile.Segment] = []) {
            self.loop = loop
            self.conic = conic
            self.segments = segments
        }
    }

    static func extrudeShape(
        outerLoop: [SIMD2<Double>], outerConic: ConicSpec? = nil,
        holes: [ExtrudeHole], zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>,
        outerSegments: [Profile.Segment] = [],
        history: OCCTShapeHistory? = nil
    ) -> BRepHandle? {
        let basis = OCCTPlaneBasis(
            originX: origin.x, originY: origin.y, originZ: origin.z,
            xAxisX: xAxis.x, xAxisY: xAxis.y, xAxisZ: xAxis.z,
            yAxisX: yAxis.x, yAxisY: yAxis.y, yAxisZ: yAxis.z,
            normalX: normal.x, normalY: normal.y, normalZ: normal.z)
        let conicData = packConics(holes.map(\.conic))
        guard let shape = OCCTBridge.extrudedShape(
            withOuterLoop: packLoop(outerLoop),
            outerConic: packConics([outerConic]),
            holes: holes.map { packLoop($0.loop) },
            holeConics: conicData,
            outerSegments: packSegments(outerSegments),
            holeSegments: holes.map { packSegments($0.segments) },
            zMin: zMin, zMax: zMax, basis: basis,
            history: history) else { return nil }
        return BRepHandle(shape)
    }

    /// Plain polyline boundaries, for callers with no analytic information
    /// about their holes — `ReplaceFaceKit`'s swept prism takes its
    /// boundaries from a tessellated `PlanarFace`, which has no idea which of
    /// them were circles. Deliberately a NAMED helper rather than an overload
    /// of `extrudeShape`: an overload makes the common `holes: []` ambiguous.
    static func polylineHoles(_ loops: [[SIMD2<Double>]]) -> [ExtrudeHole] {
        loops.map { ExtrudeHole(loop: $0) }
    }

    /// The analytic solid for a whole extrude: the outer profile plus any
    /// EXTRA profiles fused into it.
    ///
    /// Multi-profile extrudes used to skip the B-rep path entirely (the call
    /// sites read `extras.isEmpty`), so selecting two regions and pulling them
    /// produced a mesh-only body — no analytic fillets, no exact STEP, and a
    /// silent degrade the moment a second region joined the selection. A union
    /// of prisms is just a union of prisms; there was no reason for it to be a
    /// cliff.
    ///
    /// Nil when any piece fails to build, so callers fall back to Euclid as a
    /// whole rather than shipping a partial solid.
    static func extrudeSolid(
        outer: Profile, holes: [Profile],
        extras: [(profile: Profile, holes: [Profile])],
        zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>,
        history: OCCTShapeHistory? = nil
    ) -> BRepHandle? {
        func prism(_ profile: Profile, _ profileHoles: [Profile],
                   history: OCCTShapeHistory? = nil) -> BRepHandle? {
            extrudeShape(
                outerLoop: profile.loop, outerConic: ConicSpec(profile.kind),
                holes: extrudeHoles(profileHoles), zMin: zMin, zMax: zMax,
                origin: origin, xAxis: xAxis, yAxis: yAxis, normal: normal,
                outerSegments: profile.segments, history: history)
        }
        // Ancestry only for the single-profile case: fusing extras rebuilds
        // the face set, and un-composed rows would name the WRONG faces —
        // exactly what element naming must never do.
        guard var solid = prism(outer, holes,
                                history: extras.isEmpty ? history : nil)
        else { return nil }
        for extra in extras {
            guard let piece = prism(extra.profile, extra.holes),
                  let fused = boolean(solid, piece, op: 0) else { return nil }
            // Touching regions meet on shared faces; without this the fuse
            // leaves both of them plus a seam edge (same trap Replace Face
            // hit — see `unified`).
            solid = unified(fused)
        }
        return solid
    }

    /// One profile's packed arguments, shared by every profile-driven op so
    /// they cannot drift apart. Extrude, revolve, sweep and loft must all start
    /// from the SAME wires — a circle that stays round when extruded and goes
    /// faceted when revolved is exactly the inconsistency this avoids.
    private static func packedProfile(_ profile: Profile, holes: [Profile])
        -> (loop: Data, conic: Data, holeLoops: [Data], holeConics: Data,
            segments: Data, holeSegments: [Data]) {
        let extrudeHoles = extrudeHoles(holes)
        return (packLoop(profile.loop),
                packConics([ConicSpec(profile.kind)]),
                extrudeHoles.map { packLoop($0.loop) },
                packConics(extrudeHoles.map(\.conic)),
                packSegments(profile.segments),
                extrudeHoles.map { packSegments($0.segments) })
    }

    private static func planeBasis(_ plane: SketchPlane) -> OCCTPlaneBasis {
        let n = simd_normalize(simd_cross(plane.xAxis, plane.yAxis))
        return OCCTPlaneBasis(
            originX: plane.origin.x, originY: plane.origin.y, originZ: plane.origin.z,
            xAxisX: plane.xAxis.x, xAxisY: plane.xAxis.y, xAxisZ: plane.xAxis.z,
            yAxisX: plane.yAxis.x, yAxisY: plane.yAxis.y, yAxisZ: plane.yAxis.z,
            normalX: n.x, normalY: n.y, normalZ: n.z)
    }

    /// Revolve a profile about a world-space axis. Nil when OCCT refuses —
    /// most often a profile that crosses the axis, which is a real modelling
    /// error and which the mesh path reports as empty geometry.
    ///
    /// `angleRadians` is named for its units on purpose: the feature graph
    /// stores revolve angles in DEGREES (`KernelOps.revolve` ends with
    /// `intersectWithWedge(solid, degrees:)`), while OCCT wants radians. Passing
    /// 360 straight through would not fail loudly — a 360-radian revolve still
    /// closes into a full solid — so the mistake would have looked correct.
    static func revolveSolid(outer: Profile, holes: [Profile], plane: SketchPlane,
                             axisOrigin: SIMD3<Double>, axisDirection: SIMD3<Double>,
                             angleRadians: Double,
                             history: OCCTShapeHistory? = nil) -> BRepHandle? {
        let p = packedProfile(outer, holes: holes)
        let axis = [axisOrigin.x, axisOrigin.y, axisOrigin.z,
                    axisDirection.x, axisDirection.y, axisDirection.z]
        let axisData = axis.withUnsafeBytes { Data($0) }
        return OCCTBridge.revolvedShape(
            withOuterLoop: p.loop, outerConic: p.conic, holes: p.holeLoops,
            holeConics: p.holeConics, outerSegments: p.segments,
            holeSegments: p.holeSegments, basis: planeBasis(plane),
            axis: axisData, angle: angleRadians,
            history: history).map(BRepHandle.init)
    }

    /// Loft through ordered sections. Holes are dropped: OCCT's ThruSections
    /// takes ONE wire per section, so a section with inner loops cannot be
    /// expressed here — callers must fall back to the mesh for those.
    /// `ruled`: straight bands between consecutive sections — what a
    /// symmetric draft needs (two frustums), never what a user loft wants.
    static func loftSolid(sections: [(profile: Profile, plane: SketchPlane)],
                          ruled: Bool = false,
                          history: OCCTShapeHistory? = nil) -> BRepHandle? {
        guard sections.count >= 2 else { return nil }
        var loops: [Data] = [], conics: [Data] = [], segments: [Data] = []
        var bases: [OCCTPlaneBasis] = []
        for section in sections {
            let p = packedProfile(section.profile, holes: [])
            loops.append(p.loop)
            conics.append(p.conic)
            segments.append(p.segments)
            bases.append(planeBasis(section.plane))
        }
        return OCCTBridge.loftedShape(
            withOuterLoops: loops, outerConics: conics,
            outerSegments: segments, bases: bases, ruled: ruled,
            history: history).map(BRepHandle.init)
    }

    /// Sweep a profile along a world-space polyline spine — or, when `helix`
    /// is given, along that EXACT helix (the polyline then only seeds the
    /// section's placement and serves callers without the spec).
    static func sweepSolid(outer: Profile, holes: [Profile], plane: SketchPlane,
                           spine: [SIMD3<Double>], helix: HelixSpec? = nil,
                           history: OCCTShapeHistory? = nil) -> BRepHandle? {
        guard spine.count >= 2 else { return nil }
        let p = packedProfile(outer, holes: holes)
        var flat = [Double](); flat.reserveCapacity(spine.count * 3)
        for point in spine { flat.append(point.x); flat.append(point.y); flat.append(point.z) }
        let spineData = flat.withUnsafeBytes { Data($0) }
        // 13 doubles: axis point, axis direction, reference direction, radius,
        // pitch, turns, start angle — matching OS3DHelixWire in the bridge.
        var helixData: Data?
        if let h = helix {
            let n = simd_normalize(h.axisDirection)
            let x = simd_normalize(h.referenceDirection - simd_dot(h.referenceDirection, n) * n)
            let v: [Double] = [h.axisPoint.x, h.axisPoint.y, h.axisPoint.z, n.x, n.y, n.z,
                               x.x, x.y, x.z, h.radius, h.pitch, h.turns, h.startAngle]
            helixData = v.withUnsafeBytes { Data($0) }
        }
        return OCCTBridge.sweptShape(
            withOuterLoop: p.loop, outerConic: p.conic, holes: p.holeLoops,
            holeConics: p.holeConics, outerSegments: p.segments,
            holeSegments: p.holeSegments, basis: planeBasis(plane),
            spine: spineData, helix: helixData, history: history).map(BRepHandle.init)
    }

    /// Turn resolved profile holes into extrude boundaries, keeping the ones
    /// that are circles analytic. One place, because both the new-body and the
    /// boolean-into-target paths need it and they must not disagree.
    static func extrudeHoles(_ profiles: [Profile]) -> [ExtrudeHole] {
        profiles.map { profile in
            if let conic = ConicSpec(profile.kind) {
                return ExtrudeHole(loop: profile.loop, conic: conic)
            }
            return ExtrudeHole(loop: profile.loop, segments: profile.segments)
        }
    }

    /// Build the analytic OCCT solid for a primitive, matching Euclid's placement
    /// conventions so B-rep and CSG mesh coincide. `placement` is baked in.
    static func primitiveShape(_ spec: PrimitiveSpec, placement: Transform3D) -> BRepHandle? {
        let kind: Int, a: Double, b: Double, c: Double
        switch spec {
        case let .box(width, depth, height): kind = 0; a = width; b = depth; c = height
        case let .cylinder(radius, height):  kind = 1; a = radius; b = height; c = 0
        case let .sphere(radius):            kind = 2; a = radius; b = 0; c = 0
        }
        var data: Data?
        if placement != .identity {
            let m = placement.matrix  // simd is column-major: m[col][row]
            var flat = [Double]()
            for r in 0..<3 { for col in 0..<4 { flat.append(m[col][r]) } }
            data = flat.withUnsafeBytes { Data($0) }
        }
        return OCCTBridge.primitiveShape(ofKind: kind, a: a, b: b, c: c, transform: data)
            .map(BRepHandle.init)
    }

    /// True when a primitive has curved faces worth re-rendering through OCCT.
    /// A box looks identical either way, so it keeps the Euclid render mesh.
    static func hasCurvedFaces(_ spec: PrimitiveSpec) -> Bool {
        switch spec {
        case .box: return false
        case .cylinder, .sphere: return true
        }
    }

    /// Bake a `Body.transform` into a solid. A body's `brep` lives in the SAME
    /// space as its `render` mesh (body-local), so any op combining two bodies
    /// must place both into a common space first — exactly what
    /// `KernelOps.boolean` does for the Euclid meshes. Identity is a no-op.
    static func transformed(_ handle: BRepHandle, by transform: Transform3D) -> BRepHandle? {
        guard transform != .identity else { return handle }
        let m = transform.matrix  // simd is column-major: m[col][row]
        var flat = [Double]()
        for r in 0..<3 { for col in 0..<4 { flat.append(m[col][r]) } }
        let data = flat.withUnsafeBytes { Data($0) }
        return OCCTBridge.transformedShape(handle.shape, matrix: data).map(BRepHandle.init)
    }

    /// Reflect a solid in the plane through `origin` with `normal`.
    ///
    /// Deliberately not routed through `transformed(_:by:)`: `Transform3D` is
    /// translation + rotation + a single uniform scale and cannot represent a
    /// plane reflection at all. (A negative uniform scale is a point
    /// reflection — a different transform, and not what Mirror means.)
    static func mirrored(_ handle: BRepHandle,
                         origin: SIMD3<Double>, normal: SIMD3<Double>) -> BRepHandle? {
        OCCTBridge.mirroredShape(
            handle.shape,
            originX: origin.x, originY: origin.y, originZ: origin.z,
            normalX: normal.x, normalY: normal.y, normalZ: normal.z
        ).map(BRepHandle.init)
    }

    /// OCCT boolean of two solids. op: 0 = union, 1 = subtract (a − b), 2 = intersect.
    /// Map a `BooleanKind` to `OCCTBridge`'s op code (0 union, 1 subtract,
    /// 2 intersect).
    static func booleanOp(_ kind: BooleanKind) -> Int {
        switch kind {
        case .union: 0
        case .subtract: 1
        case .intersect: 2
        }
    }

    /// Compose two bodies' analytic solids with an OCCT boolean, in world
    /// space (each body's transform applied first, mirroring what
    /// `KernelOps.boolean` does for the Euclid meshes). Nil when either body
    /// is mesh-only or OCCT fails — the caller keeps the Euclid result.
    /// Shared by feature replay AND the live boolean tool, so both paths make
    /// the same kernel decision (2026-08-25 review, C4).
    static func composedBoolean(
        _ kind: BooleanKind, target: Body, tool: Body
    ) -> BRepHandle? {
        guard let outcome = composedBooleanResult(kind, target: target, tool: tool)
        else { return nil }
        return try? outcome.get().handle
    }

    /// `composedBoolean` with the reason when OCCT fails. Nil means OCCT
    /// DECLINED the op (an operand is mesh-only, or the B-rep flag is off) —
    /// the Euclid fallback is then legitimate. A `.failure` means OCCT owned
    /// the op and failed for cause; callers surface that instead of silently
    /// degrading to the mesh result (which drops the brep and goes faceted
    /// forever — the "corrupt-looking boolean" class).
    static func composedBooleanResult(
        _ kind: BooleanKind, target: Body, tool: Body
    ) -> Result<BooleanOutcome, OCCTOpError>? {
        guard useOCCTAsSourceOfTruth,
              let a0 = target.brep, let b0 = tool.brep,
              let a = transformed(a0, by: target.transform),
              let b = transformed(b0, by: tool.transform)
        else { return nil }
        return booleanResult(a, b, op: booleanOp(kind))
    }

    /// Merge faces sharing one underlying surface (and the seams between
    /// them). A fuse against a coplanar face otherwise leaves BOTH faces and
    /// the seam edge — right shape, wrong topology, and the extra edges are
    /// selectable and blendable. Returns the input unchanged when OCCT
    /// declines, since the un-unified solid is still valid.
    static func unified(_ handle: BRepHandle) -> BRepHandle {
        OCCTBridge.unifiedShape(handle.shape).map(BRepHandle.init) ?? handle
    }

    /// A boolean's result plus how many disjoint solids it holds. The shape
    /// is unwrapped/unified/validated by the bridge; `solidCount > 1` means a
    /// cut split the body apart — a legitimate geometric outcome the caller
    /// decides how to present, not a silent one (review R4-O3).
    nonisolated struct BooleanOutcome {
        let handle: BRepHandle
        let solidCount: Int
    }

    static func booleanResult(_ a: BRepHandle, _ b: BRepHandle, op: Int)
        -> Result<BooleanOutcome, OCCTOpError> {
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.boolean(of: a.shape, with: b.shape,
                                             op: op, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(op: "boolean",
                                        inputs: [("a", a), ("b", b)],
                                        params: ["op": op], error: error)
            return .failure(error)
        }
        let solids = status.code == .multiSolid ? status.solidCount : 1
        return .success(BooleanOutcome(handle: BRepHandle(shape),
                                       solidCount: solids))
    }

    static func boolean(_ a: BRepHandle, _ b: BRepHandle, op: Int) -> BRepHandle? {
        try? booleanResult(a, b, op: op).get().handle
    }

    /// Remove the faces nearest `points` and heal the solid (spec §4.16 Delete
    /// Face). Failure says whether nothing matched or OCCT couldn't close the
    /// result — the caller surfaces it rather than mutating the body.
    static func removingFacesResult(
        _ handle: BRepHandle, at points: [SIMD3<Double>], tolerance: Double
    ) -> Result<BRepHandle, OCCTOpError> {
        guard !points.isEmpty else {
            return .failure(.noTargetMatched("no face was picked"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.defeaturedShape(
            handle.shape, atWorldPoints: pack(points),
            tolerance: tolerance, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "removeFaces", inputs: [("shape", handle)],
                params: ["tolerance": tolerance,
                         "points": points.map { [$0.x, $0.y, $0.z] }],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    static func removingFaces(_ handle: BRepHandle, at points: [SIMD3<Double>],
                              tolerance: Double) -> BRepHandle? {
        try? removingFacesResult(handle, at: points, tolerance: tolerance).get()
    }

    /// The poles of the B-spline edge the kernel builds for a sketch spline —
    /// the cross-language pin for `CatmullRomBezier` (a test compares them
    /// pole for pole with the Swift conversion). Nil if the edge fails.
    static func splineEdgePoles(_ points: [SIMD2<Double>], closed: Bool) -> [SIMD2<Double>]? {
        var flat = [Double](); flat.reserveCapacity(points.count * 2)
        for p in points { flat.append(p.x); flat.append(p.y) }
        let data = flat.withUnsafeBytes { Data($0) }
        guard let out = OCCTBridge.splineEdgePoles(forPoints: data, closed: closed) else { return nil }
        let values: [Double] = out.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        return stride(from: 0, to: values.count - 1, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }
    }

    /// Analytic face-type histogram of a solid — how we assert that geometry
    /// stayed exact through an operation.
    static func faceTypeCounts(_ handle: BRepHandle)
        -> (planar: Int, cylindrical: Int, other: Int) {
        let c = OCCTBridge.faceTypeCounts(of: handle.shape)
        return (c.planar, c.cylindrical, c.other)
    }

    /// One kernel face's geometry, straight from the shape — the identity
    /// source when the body's RENDER is not the kernel tessellation
    /// (revolve/sweep/loft assign their brep), where the mesh-table channel
    /// votes garbage against a different tessellation.
    nonisolated struct KernelFaceInfo: Sendable {
        let index: Int
        /// Nil for surface kinds `FaceSignature` cannot express (torus,
        /// sphere, swept surfaces) — listed for discovery, not
        /// referenceable by a FaceRef.
        let signature: FaceSignature?
        let normal: SIMD3<Double>
        let centroid: SIMD3<Double>
        let area: Double
    }

    /// Per-kernel-face geometry in the shared 1-based numbering. Planar
    /// normals point OUT of the solid; a cylindrical face's "normal" is its
    /// axis direction, matching `FaceSignature` conventions.
    /// The plane's intersection with the solid as world-space polylines, one
    /// per kernel section edge (a line as its two ends, a curve sampled at
    /// `deflection` mm chord error), unordered. `SectionKit.loops` chains
    /// them into the closed loops a drawing shows.
    static func sectionPolylines(_ handle: BRepHandle, origin: SIMD3<Double>,
                                 normal: SIMD3<Double>, deflection: Double = 0.05) -> [[SIMD3<Double>]] {
        var plane: [Double] = [origin.x, origin.y, origin.z, normal.x, normal.y, normal.z]
        let data = Data(bytes: &plane, count: 6 * MemoryLayout<Double>.size)
        guard let out = OCCTBridge.section(of: handle.shape, plane: data, deflection: deflection) else { return [] }
        let values: [Double] = out.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        var result: [[SIMD3<Double>]] = []
        var i = 0
        while i < values.count {
            let count = Int(values[i]); i += 1
            guard count >= 1, i + count * 3 <= values.count else { break }
            var pts: [SIMD3<Double>] = []
            pts.reserveCapacity(count)
            for k in 0..<count {
                pts.append(SIMD3(values[i + 3 * k], values[i + 3 * k + 1], values[i + 3 * k + 2]))
            }
            i += count * 3
            result.append(pts)
        }
        return result
    }

    static func faceInfo(_ handle: BRepHandle) -> [KernelFaceInfo] {
        guard let data = OCCTBridge.faceInfo(of: handle.shape) else { return [] }
        let values: [Double] = data.withUnsafeBytes {
            Array($0.bindMemory(to: Double.self))
        }
        var out: [KernelFaceInfo] = []
        out.reserveCapacity(values.count / 10)
        for base in stride(from: 0, to: (values.count / 10) * 10, by: 10) {
            let normal = SIMD3(values[base + 2], values[base + 3], values[base + 4])
            let centroid = SIMD3(values[base + 5], values[base + 6], values[base + 7])
            let area = values[base + 8]
            let signature: FaceSignature?
            switch values[base + 1] {
            case 0:
                signature = FaceSignature(kind: .planar, normal: normal,
                                          centroid: centroid, area: area,
                                          planeOffset: values[base + 9])
            case 1:
                signature = FaceSignature(kind: .cylindrical(radius: values[base + 9]),
                                          normal: normal, centroid: centroid,
                                          area: area,
                                          planeOffset: simd_dot(normal, centroid))
            default:
                signature = nil
            }
            out.append(KernelFaceInfo(index: Int(values[base]),
                                      signature: signature, normal: normal,
                                      centroid: centroid, area: area))
        }
        return out
    }

    /// Round the analytic edges nearest `points` to `radius`. `points` are
    /// world positions on the edges to blend (mesh-edge midpoints from the
    /// picker); pass `matchTolerance(for:)` as `tolerance`.
    ///
    /// The failure says what actually went wrong: nothing near the pick, the
    /// pick was a seam/tangent edge, the radius is too large for N of M
    /// edges (a partial build is DISCARDED, never returned — review R4-O4),
    /// or the result failed validation.
    static func filletResult(_ handle: BRepHandle, at points: [SIMD3<Double>],
                             radius: Double, tolerance: Double)
        -> Result<BRepHandle, OCCTOpError> {
        guard !points.isEmpty, radius > 0 else {
            return .failure(.kernelRefused("nothing to fillet"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.filletedShape(
            handle.shape, atWorldPoints: pack(points),
            radius: radius, tolerance: tolerance, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "fillet", inputs: [("shape", handle)],
                params: ["radius": radius, "tolerance": tolerance,
                         "points": points.map { [$0.x, $0.y, $0.z] }],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    static func fillet(_ handle: BRepHandle, at points: [SIMD3<Double>],
                       radius: Double, tolerance: Double) -> BRepHandle? {
        try? filletResult(handle, at: points, radius: radius,
                          tolerance: tolerance).get()
    }

    /// Bevel the analytic edges nearest `points` by `distance` (spec §4.3
    /// chamfer). Same contract as `filletResult`.
    static func chamferResult(_ handle: BRepHandle, at points: [SIMD3<Double>],
                              distance: Double, tolerance: Double)
        -> Result<BRepHandle, OCCTOpError> {
        guard !points.isEmpty, distance > 0 else {
            return .failure(.kernelRefused("nothing to chamfer"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.chamferedShape(
            handle.shape, atWorldPoints: pack(points),
            distance: distance, tolerance: tolerance, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "chamfer", inputs: [("shape", handle)],
                params: ["distance": distance, "tolerance": tolerance,
                         "points": points.map { [$0.x, $0.y, $0.z] }],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    static func chamfer(_ handle: BRepHandle, at points: [SIMD3<Double>],
                        distance: Double, tolerance: Double) -> BRepHandle? {
        try? chamferResult(handle, at: points, distance: distance,
                           tolerance: tolerance).get()
    }

    // MARK: Identity-addressed blends (TOPO_NAMING_HISTORY_DESIGN step 4b)

    /// Every edge with exactly two distinct adjacent faces: `(edge, faceA,
    /// faceB)` in the shared 1-based indexed-map numbering. Seams/borders
    /// are omitted — no pair identity, and the blend pre-qualifier vetoes
    /// them anyway.
    static func edgeFaceAdjacency(_ handle: BRepHandle)
        -> [(edge: Int, faceA: Int, faceB: Int)] {
        guard let data = OCCTBridge.edgeFaceAdjacency(of: handle.shape) else { return [] }
        let values = data.int32Array()
        var out: [(edge: Int, faceA: Int, faceB: Int)] = []
        out.reserveCapacity(values.count / 3)
        for base in stride(from: 0, to: (values.count / 3) * 3, by: 3) {
            out.append((Int(values[base]), Int(values[base + 1]),
                        Int(values[base + 2])))
        }
        return out
    }

    /// The kernel edge nearest a world point — the mint-time bridge from a
    /// picked mesh edge to its kernel identity. Same matching the
    /// point-based blends use; nil when nothing is within tolerance.
    static func nearestEdgeIndex(_ handle: BRepHandle, to point: SIMD3<Double>,
                                 tolerance: Double) -> Int? {
        let index = OCCTBridge.nearestEdgeIndex(
            of: handle.shape, toPointX: point.x, y: point.y, z: point.z,
            tolerance: tolerance)
        return index > 0 ? Int(index) : nil
    }

    /// Each kernel edge's point halfway along its curve by arc length, keyed
    /// by the shared 1-based edge index. Degenerate edges, and any whose
    /// length the kernel cannot compute, are absent.
    static func edgeMidpoints(_ handle: BRepHandle) -> [Int: SIMD3<Double>] {
        guard let data = OCCTBridge.edgeMidpoints(of: handle.shape) else { return [:] }
        let values: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        var out: [Int: SIMD3<Double>] = [:]
        for i in 0..<(values.count / 3) {
            let p = SIMD3(values[3 * i], values[3 * i + 1], values[3 * i + 2])
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            out[i + 1] = p
        }
        return out
    }

    /// What `/v1/edges` reports for one kernel edge, besides its index and
    /// faces. Body-local, like the brep and the render mesh.
    nonisolated struct EdgeGeometry: Equatable, Sendable {
        /// Halfway along the kernel curve by arc length.
        var midpoint: SIMD3<Double>
        /// Sum of the mesh segments that map to the edge (chords, for a
        /// curve).
        var length: Double
        var isConvex: Bool
    }

    /// Per kernel edge, the geometry `/v1/edges` reports. The MESH side still
    /// decides which edges get any: each selectable mesh edge maps to its
    /// nearest kernel edge, so an edge with no crease (a tangent join) has
    /// no entry. Nothing depends on the order of `meshEdges`, which comes
    /// out of `EdgeTopology` in per-process dictionary order: the midpoint
    /// is the kernel's, the lengths are summed in sorted order, and the
    /// convexity comes from the segment nearest that midpoint. Keeping the
    /// FIRST segment's midpoint made a curved edge's midpoint change from one
    /// launch to the next (2026-09-16).
    static func edgeGeometry(_ handle: BRepHandle, meshEdges: [SelectableEdge],
                             tolerance: Double) -> [Int: EdgeGeometry] {
        func d3(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }
        var segments: [Int: [SelectableEdge]] = [:]
        for edge in meshEdges {
            guard let index = nearestEdgeIndex(handle, to: d3(edge.midpoint),
                                               tolerance: tolerance) else { continue }
            segments[index, default: []].append(edge)
        }
        let kernelMidpoints = edgeMidpoints(handle)
        var out: [Int: EdgeGeometry] = [:]
        for (index, group) in segments {
            let reference = kernelMidpoints[index]
            // Nearest the kernel midpoint, ties (and a missing midpoint)
            // broken by coordinates, so the choice is a function of the set.
            let representative = group.min { a, b in
                let ma = d3(a.midpoint), mb = d3(b.midpoint)
                if let r = reference {
                    let da = simd_distance(ma, r), db = simd_distance(mb, r)
                    if da != db { return da < db }
                }
                return (ma.x, ma.y, ma.z) < (mb.x, mb.y, mb.z)
            }!
            out[index] = EdgeGeometry(
                midpoint: reference ?? d3(representative.midpoint),
                length: group.map { Double($0.length) }.sorted().reduce(0, +),
                isConvex: representative.isConvex)
        }
        return out
    }

    /// Blend BY IDENTITY: edges chosen by index, not by proximity to a
    /// point — same qualification and validation as the point path (they
    /// share one implementation).
    static func filletResult(_ handle: BRepHandle, edgeIndices: [Int],
                             radius: Double) -> Result<BRepHandle, OCCTOpError> {
        guard !edgeIndices.isEmpty, radius > 0 else {
            return .failure(.kernelRefused("nothing to fillet"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.filletedShape(
            handle.shape, edgeIndices: packIndices(edgeIndices),
            radius: radius, status: status, history: nil) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "fillet", inputs: [("shape", handle)],
                params: ["radius": radius, "edgeIndices": edgeIndices],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    static func chamferResult(_ handle: BRepHandle, edgeIndices: [Int],
                              distance: Double) -> Result<BRepHandle, OCCTOpError> {
        guard !edgeIndices.isEmpty, distance > 0 else {
            return .failure(.kernelRefused("nothing to chamfer"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.chamferedShape(
            handle.shape, edgeIndices: packIndices(edgeIndices),
            distance: distance, status: status, history: nil) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "chamfer", inputs: [("shape", handle)],
                params: ["distance": distance, "edgeIndices": edgeIndices],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    /// Internal (not private): the ancestry variants in ShapeAncestry.swift
    /// share these packers.
    static func packIndices(_ indices: [Int]) -> Data {
        indices.map(Int32.init).withUnsafeBytes { Data($0) }
    }

    /// Hollow a solid to `thickness`, opening the faces nearest `points` (spec
    /// §4.4 Shell). Empty `points` = fully-enclosed hollow. Correct on curved
    /// walls, unlike the mesh inset. The failure distinguishes "no face near
    /// the pick" from "thickness out of range" from "result didn't validate"
    /// (including a shell that removed no material — the silent sealed-body
    /// case).
    /// `thickness` is SIGNED: positive hollows inward, negative grows the
    /// wall outward (the original surface becomes the cavity).
    static func shellResult(_ handle: BRepHandle, openingAt points: [SIMD3<Double>],
                            thickness: Double, tolerance: Double)
        -> Result<BRepHandle, OCCTOpError> {
        guard abs(thickness) > 0 else {
            return .failure(.kernelRefused("thickness must be non-zero"))
        }
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.shelledShape(
            handle.shape, atWorldPoints: pack(points),
            thickness: thickness, tolerance: tolerance, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "shell", inputs: [("shape", handle)],
                params: ["thickness": thickness, "tolerance": tolerance,
                         "points": points.map { [$0.x, $0.y, $0.z] }],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    /// Exact face draft (`BRepOffsetAPI_DraftAngle`): the faces nearest the
    /// picked points tilt by `degrees` about their intersection with the
    /// neutral plane, pulled along `neutralNormal`. Positive narrows the
    /// body away from the neutral plane — the mesh path's sign
    /// (`KernelOps.draftFace`), so a node evaluates the same either way.
    static func draftResult(_ handle: BRepHandle, facesAt points: [SIMD3<Double>],
                            degrees: Double, neutralOrigin: SIMD3<Double>,
                            neutralNormal: SIMD3<Double>, tolerance: Double)
        -> Result<BRepHandle, OCCTOpError> {
        guard !points.isEmpty, abs(degrees) > 1e-9, simd_length(neutralNormal) > 1e-9 else {
            return .failure(.kernelRefused("nothing to draft"))
        }
        let n = simd_normalize(neutralNormal)
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.draftedShape(
            handle.shape, atWorldPoints: pack(points),
            angleRadians: degrees * .pi / 180,
            directionX: n.x, directionY: n.y, directionZ: n.z,
            neutralOriginX: neutralOrigin.x, neutralOriginY: neutralOrigin.y, neutralOriginZ: neutralOrigin.z,
            neutralNormalX: n.x, neutralNormalY: n.y, neutralNormalZ: n.z,
            tolerance: tolerance, status: status) else {
            let error = OCCTOpError(status)
            KernelCapture.recordFailure(
                op: "draftFace", inputs: [("shape", handle)],
                params: ["degrees": degrees, "tolerance": tolerance,
                         "points": points.map { [$0.x, $0.y, $0.z] },
                         "neutralOrigin": [neutralOrigin.x, neutralOrigin.y, neutralOrigin.z],
                         "neutralNormal": [n.x, n.y, n.z]],
                error: error)
            return .failure(error)
        }
        return .success(BRepHandle(shape))
    }

    static func shell(_ handle: BRepHandle, openingAt points: [SIMD3<Double>],
                      thickness: Double, tolerance: Double) -> BRepHandle? {
        try? shellResult(handle, openingAt: points, thickness: thickness,
                         tolerance: tolerance).get()
    }

    /// Exact solid volume in mm³ (`BRepGProp`); 0 on failure.
    static func volume(_ handle: BRepHandle) -> Double {
        OCCTBridge.volume(of: handle.shape)
    }

    /// The largest fillet radius the edges nearest `points` can actually
    /// take — bisection over real, fully-checked `BRepFilletAPI` builds, so
    /// the drag clamp and the commit agree by construction
    /// (docs/FREECAD_PLAYBOOK.md F3). Costs a handful of fillet builds:
    /// compute once per drag, never per tick. 0 when nothing blendable is
    /// near the points.
    static func maxFilletRadius(_ handle: BRepHandle, at points: [SIMD3<Double>],
                                tolerance: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        return OCCTBridge.maxFilletRadius(for: handle.shape,
                                          atWorldPoints: pack(points),
                                          tolerance: tolerance)
    }

    /// Pick-matching tolerance for a B-rep body — docs/FREECAD_PLAYBOOK.md T1.
    ///
    /// The points the pickers hand the bridge are midpoints of the OCCT
    /// tessellation's own mesh edges/faces, so their distance from the
    /// analytic geometry is bounded by the tessellation deflection — NOT by
    /// the body's size. Scaling tolerance to the AABB diagonal was how a
    /// 100×100×1 mm plate got a millimetre-scale pick ball against a 1 mm
    /// wall: shelling the top also opened the bottom (review S5). The second
    /// term grows the ball only when the shape itself carries fat tolerances
    /// (a healed import), which is the one case geometry legitimately sits
    /// farther from where the mesh says it is.
    static func matchTolerance(for handle: BRepHandle) -> Double {
        max(4 * renderLinearDeflection,
            10 * OCCTBridge.maxTolerance(of: handle.shape))
    }

    static func pack(_ points: [SIMD3<Double>]) -> Data {
        var flat = [Double](); flat.reserveCapacity(points.count * 3)
        for p in points { flat.append(p.x); flat.append(p.y); flat.append(p.z) }
        return flat.withUnsafeBytes { Data($0) }
    }

    // MARK: - STEP interchange (spec §12.1 / §12.2)

    /// Write solids to a STEP AP214 file. Unlike STL/OBJ/3MF (which export
    /// triangles), STEP carries the EXACT B-rep, so analytic surfaces survive
    /// into other CAD. False if any transfer or the write fails.
    @discardableResult
    static func writeSTEP(_ handles: [BRepHandle], to url: URL) -> Bool {
        guard !handles.isEmpty else { return false }
        return OCCTBridge.writeSTEP(handles.map(\.shape), toPath: url.path)
    }

    /// Read every solid from a STEP file; empty when the file is unreadable or
    /// holds no solids, so the caller surfaces a recoverable import error.
    static func readSTEP(from url: URL) -> [BRepHandle] {
        OCCTBridge.readSTEP(fromPath: url.path).map(BRepHandle.init)
    }

    /// Serialize a solid so the analytic geometry survives a document reload.
    static func serialize(_ handle: BRepHandle) -> Data? {
        OCCTBridge.serializedShape(handle.shape)
    }

    /// Restore a solid from `serialize(_:)`. Nil on any failure — callers keep
    /// the persisted render mesh, so a bad/incompatible blob degrades to the
    /// pre-B-rep behaviour instead of breaking the document.
    static func deserialize(_ data: Data) -> BRepHandle? {
        OCCTBridge.shape(fromSerialized: data).map(BRepHandle.init)
    }

    // MARK: - IGES interchange (spec §12.1 / §12.2, import only)

    /// Read an IGES payload through OCCT's IGES reader. Solids and non-solid
    /// surfaces come back SEPARATELY (`IGESImport`): IGES routinely carries
    /// only shells or faces, and those are exact geometry but not solids — a
    /// body built from one must not be marked analytic or fed to boolean /
    /// fillet / shell. The bridge healed and validated every root; a shape
    /// that survived here can still fail to tessellate, which callers handle
    /// per item (see `nativeImportData`). There is no IGES writer anywhere in
    /// the product, so this type is read-only by design.
    static func readIGES(_ data: Data) -> IGESImport {
        guard let imported = OCCTBridge.readIGES(from: data) else {
            return IGESImport(solids: [], surfaces: [],
                              solidFaceCounts: [], surfaceFaceCounts: [],
                              readSucceeded: false, rootCount: 0)
        }
        let solids = imported.solids.map(BRepHandle.init)
        let surfaces = imported.surfaces.map(BRepHandle.init)
        // A parse that transfers NO shape is not a successful import (the IGES
        // reader is tolerant of garbage and reports success with zero roots);
        // callers turn this into a structured refusal instead of an empty body.
        return IGESImport(
            solids: solids,
            surfaces: surfaces,
            solidFaceCounts: imported.solidFaceCounts.map(\.intValue),
            surfaceFaceCounts: imported.surfaceFaceCounts.map(\.intValue),
            readSucceeded: imported.readSucceeded && (solids.count + surfaces.count) > 0,
            rootCount: imported.rootCount)
    }

#if DEBUG
    /// DEBUG-only test support: the first face of `handle` as a standalone
    /// shape, so a fixture can carry a solid AND a loose surface in one IGES
    /// file (mixed-root classification coverage).
    static func debugStandaloneFace(from handle: BRepHandle) -> BRepHandle? {
        guard let face = OCCTBridge.debugStandaloneFace(from: handle.shape) else { return nil }
        return BRepHandle(face)
    }

    /// Test support only: write `handles` to an IGES file through OCCT's own
    /// writer; see the bridge for the mode semantics. Debug builds only.
    static func debugWriteIGES(_ handles: [BRepHandle], to url: URL,
                               brepMode: Bool) -> Bool {
        guard !handles.isEmpty else { return false }
        return OCCTBridge.debugWriteIGESShapes(handles.map(\.shape),
                                               toPath: url.path,
                                               brepMode: brepMode)
    }
#endif

    /// Smooth world-space render mesh for a B-rep solid.
    static func renderMesh(from handle: BRepHandle)
        -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        let mesh = OCCTBridge.renderMesh(
            from: handle.shape,
            angularDeflection: renderAngularDeflection,
            linearDeflection: renderLinearDeflection)
        let p = mesh.positions.floatArray()
        let nn = mesh.normals.floatArray()
        let indices = mesh.indices.uint32Array()
        let n = mesh.vertexCount
        var positions = [SIMD3<Float>](); positions.reserveCapacity(n)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(n)
        for v in 0..<n {
            positions.append(SIMD3<Float>(p[3*v], p[3*v+1], p[3*v+2]))
            normals.append(SIMD3<Float>(nn[3*v], nn[3*v+1], nn[3*v+2]))
        }
        return (positions, normals, indices)
    }

    /// Per-triangle OCCT face channel for a B-rep render mesh: entry i is the
    /// 1-based indexed-map face number triangle i tessellates (0 = unknown) —
    /// the same numbering the health report's "Face3" findings use. Step 1 of
    /// docs/TOPO_NAMING_HISTORY_DESIGN.md: element naming attaches kernel
    /// identities to mesh-derived face groups by majority vote over this.
    /// Cheap to call after `renderMesh(from:)` — the triangulation is cached
    /// on the shape, so the mesher does not run twice.
    static func renderMeshFaceChannel(from handle: BRepHandle) -> [UInt32] {
        OCCTBridge.renderMesh(
            from: handle.shape,
            angularDeflection: renderAngularDeflection,
            linearDeflection: renderLinearDeflection).faceIndices.uint32Array()
    }

    /// 5 doubles per entry — `cx, cy, rx, ry, rotation` — parallel to the
    /// loops they describe. A non-positive `rx` means "no conic here, use the
    /// polyline", which is how one flat array carries the absent case too.
    private static func packConics(_ conics: [ConicSpec?]) -> Data {
        var flat = [Double](); flat.reserveCapacity(conics.count * 5)
        for conic in conics {
            flat.append(conic?.center.x ?? 0)
            flat.append(conic?.center.y ?? 0)
            flat.append(conic?.radiusX ?? 0)
            flat.append(conic?.radiusY ?? 0)
            flat.append(conic?.rotation ?? 0)
        }
        return flat.withUnsafeBytes { Data($0) }
    }

    /// Segment records for `SegWire`, which walks them by KIND. A line or arc
    /// is 7 doubles — `kind (0 line / 1 arc), x1, y1, x2, y2, midX, midY` —
    /// and a spline is `kind (2 open / 3 closed), count, then count x,y
    /// control points` (docs/SPLINE_PROFILE_DESIGN.md), so lines and arcs are
    /// byte-for-byte what they always were. Empty in, empty out: an all-
    /// straight loop has nothing to say here that its polyline does not
    /// already say exactly.
    private static func packSegments(_ segments: [Profile.Segment]) -> Data {
        guard !segments.isEmpty else { return Data() }
        var flat = [Double](); flat.reserveCapacity(segments.count * 7)
        for s in segments {
            if let points = s.controlPoints {
                flat.append(s.closed ? 3 : 2)
                flat.append(Double(points.count))
                for p in points { flat.append(p.x); flat.append(p.y) }
                continue
            }
            flat.append(s.mid == nil ? 0 : 1)
            flat.append(s.start.x); flat.append(s.start.y)
            flat.append(s.end.x); flat.append(s.end.y)
            flat.append(s.mid?.x ?? 0); flat.append(s.mid?.y ?? 0)
        }
        return flat.withUnsafeBytes { Data($0) }
    }

    private static func packLoop(_ pts: [SIMD2<Double>]) -> Data {
        var flat = [Double](); flat.reserveCapacity(pts.count * 2)
        for p in pts { flat.append(p.x); flat.append(p.y) }
        return flat.withUnsafeBytes { Data($0) }
    }

    /// Tessellate a box; returns (triangleCount, exact volume).
    static func meshBox(size: Double) -> (triangles: Int, volume: Double) {
        let r = OCCTBridge.meshBox(withSize: size)
        return (r.triangleCount, r.volume)
    }

    /// Face-type histogram of an extruded circle. A true cylinder is
    /// (planar: 2 caps, cylindrical: 1 wall, other: 0) — the analytic-surface
    /// guarantee the Euclid mesh path can't give.
    static func extrudedCircleFaceCounts(radius: Double, height: Double)
        -> (planar: Int, cylindrical: Int, other: Int) {
        let c = OCCTBridge.extrudeCircleFaceCounts(withRadius: radius, height: height)
        return (c.planar, c.cylindrical, c.other)
    }
}

nonisolated extension Body {
    /// Adopt an OCCT solid as this body's SOURCE OF TRUTH.
    ///
    /// Both the render mesh and the CSG (`euclid`) mesh are derived from the same
    /// OCCT tessellation, so what you see and what booleans/blends actually cut
    /// can never disagree. Ops not yet ported to OCCT keep working — they just
    /// operate on the accurate tessellation of the analytic solid instead of a
    /// coarse 48-gon. Returns false (leaving the body untouched) if the solid
    /// fails to tessellate, so callers fall back to the Euclid path.
    @discardableResult
    mutating func adoptBRep(_ handle: BRepHandle) -> Bool {
        let m = OCCTKernel.renderMesh(from: handle)
        guard !m.positions.isEmpty, !m.indices.isEmpty else { return false }
        let mesh = RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
        brep = handle
        render = mesh
        edges = FeatureEdgeExtractor.edges(from: mesh)
        euclid = EuclidBridge.euclidMesh(from: mesh)
        return true
    }
}

private nonisolated extension Data {
    /// Reinterpret the packed bytes as tightly-packed `Float`s.
    func floatArray() -> [Float] {
        withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    /// Reinterpret the packed bytes as tightly-packed `UInt32`s.
    func uint32Array() -> [UInt32] {
        withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
    /// Reinterpret the packed bytes as tightly-packed `Int32`s.
    func int32Array() -> [Int32] {
        withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    }
}

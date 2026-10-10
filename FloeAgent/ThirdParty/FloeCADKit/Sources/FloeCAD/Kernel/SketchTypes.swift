//
//  SketchTypes.swift
//  openshape3d
//
//  2D sketching data. Entities live in plane-local coordinates (Double);
//  SketchPlane maps between plane space and world space.
//

import Foundation
import simd

nonisolated struct SketchPlane: Codable, Equatable, Sendable {
    var origin: SIMD3<Double>
    var xAxis: SIMD3<Double>
    var yAxis: SIMD3<Double>

    var normal: SIMD3<Double> { simd_cross(xAxis, yAxis) }

    /// Ground plane (XZ, Y up): sketch X → world X, sketch Y → world -Z so the
    /// sketch reads right-handed when viewed from +Y (top-down).
    static let ground = SketchPlane(
        origin: .zero,
        xAxis: SIMD3(1, 0, 0),
        yAxis: SIMD3(0, 0, -1)
    )

    static func offsetGround(y: Double) -> SketchPlane {
        SketchPlane(origin: SIMD3(0, y, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1))
    }

    func toWorld(_ p: SIMD2<Double>) -> SIMD3<Double> {
        origin + xAxis * p.x + yAxis * p.y
    }

    func toLocal(_ world: SIMD3<Double>) -> SIMD2<Double> {
        let delta = world - origin
        return SIMD2(simd_dot(delta, xAxis), simd_dot(delta, yAxis))
    }
}

nonisolated enum SketchEntity: Identifiable, Codable, Equatable, Sendable {
    case line(id: UUID, a: SIMD2<Double>, b: SIMD2<Double>)
    case rect(id: UUID, min: SIMD2<Double>, max: SIMD2<Double>)
    case circle(id: UUID, center: SIMD2<Double>, radius: Double)
    /// Circular arc swept counterclockwise from `startAngle` to `endAngle`
    /// (radians; sweep normalized into [0, 2π)).
    case arc(id: UUID, center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double)
    /// Axis-aligned radii rotated by `rotation` (radians) about `center`.
    case ellipse(id: UUID, center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double)
    /// Regular n-gon: `sides` vertices on the circumscribed circle of `radius`,
    /// first vertex at angle `rotation`.
    case polygon(id: UUID, center: SIMD2<Double>, radius: Double, sides: Int, rotation: Double)
    /// Fit spline (spec §1.4): a smooth curve INTERPOLATING `points` in order.
    /// `closed` joins the last point back to the first. Two points degenerate to
    /// a straight line, which is what the Shapr3D fit spline does too.
    case spline(id: UUID, points: [SIMD2<Double>], closed: Bool)

    var id: UUID {
        switch self {
        case let .line(id, _, _), let .rect(id, _, _), let .circle(id, _, _),
             let .arc(id, _, _, _, _), let .ellipse(id, _, _, _, _),
             let .polygon(id, _, _, _, _), let .spline(id, _, _):
            id
        }
    }
}

// MARK: - Shared point generation (tessellation + snapping)

nonisolated extension SketchEntity {
    /// CCW sweep from `startAngle` to `endAngle`, normalized into [0, 2π).
    static func arcSweep(startAngle: Double, endAngle: Double) -> Double {
        var sweep = (endAngle - startAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 { sweep += 2 * .pi }
        return sweep
    }

    static func arcPoint(center: SIMD2<Double>, radius: Double, angle: Double) -> SIMD2<Double> {
        center + SIMD2(cos(angle), sin(angle)) * radius
    }

    /// Polyline along the arc, both endpoints included; density is
    /// `segmentsPerTurn` scaled by the swept fraction of a full turn.
    /// Empty for degenerate arcs (zero sweep or radius).
    static func arcPoints(
        center: SIMD2<Double>, radius: Double,
        startAngle: Double, endAngle: Double,
        segmentsPerTurn: Int
    ) -> [SIMD2<Double>] {
        let sweep = arcSweep(startAngle: startAngle, endAngle: endAngle)
        guard sweep > 1e-9, radius > 1e-9 else { return [] }
        let count = max(2, Int((Double(segmentsPerTurn) * sweep / (2 * .pi)).rounded(.up)))
        return (0...count).map { i in
            arcPoint(center: center, radius: radius, angle: startAngle + sweep * Double(i) / Double(count))
        }
    }

    /// Closed CCW loop (first point not repeated at the end).
    static func ellipsePoints(
        center: SIMD2<Double>, radiusX: Double, radiusY: Double,
        rotation: Double, segments: Int
    ) -> [SIMD2<Double>] {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return (0..<segments).map { i in
            let t = Double(i) / Double(segments) * 2 * .pi
            let local = SIMD2(cos(t) * radiusX, sin(t) * radiusY)
            return center + SIMD2(local.x * cosR - local.y * sinR, local.x * sinR + local.y * cosR)
        }
    }

    /// Polyline along a FIT spline through `points` (spec §1.4).
    ///
    /// Uses centripetal Catmull–Rom: it interpolates every control point (what
    /// "fit" means to the user) and, unlike the uniform variant, will not form
    /// cusps or self-intersections when points are unevenly spaced — the exact
    /// failure a hand-drawn sketch produces.
    ///
    /// Returns the control points unchanged when there are fewer than three, so
    /// a 2-point spline is simply a line. For `closed`, the first point is NOT
    /// repeated at the end (same convention as `ellipsePoints`).
    static func splinePoints(
        _ points: [SIMD2<Double>], closed: Bool, segmentsPerSpan: Int = 16
    ) -> [SIMD2<Double>] {
        guard points.count >= 3 else { return points }
        let n = points.count
        let spans = closed ? n : n - 1
        let steps = max(2, segmentsPerSpan)
        var out = [SIMD2<Double>]()
        out.reserveCapacity(spans * steps + 1)

        func control(_ i: Int) -> SIMD2<Double> {
            if closed { return points[((i % n) + n) % n] }
            return points[min(max(i, 0), n - 1)]
        }

        for span in 0..<spans {
            let p0 = control(span - 1), p1 = control(span)
            let p2 = control(span + 1), p3 = control(span + 2)

            // Centripetal parameterisation (alpha = 0.5).
            func knot(_ t: Double, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
                t + sqrt(simd_length(b - a))
            }
            let t0 = 0.0
            let t1 = knot(t0, p0, p1)
            let t2 = knot(t1, p1, p2)
            let t3 = knot(t2, p2, p3)
            // Degenerate (duplicate points) → fall back to the straight span.
            guard t1 > t0, t2 > t1, t3 > t2 else {
                out.append(p1)
                continue
            }

            for step in 0..<steps {
                let t = t1 + (t2 - t1) * Double(step) / Double(steps)
                let a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
                let a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
                let a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
                let b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
                let b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
                out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
            }
        }
        if !closed, let last = points.last { out.append(last) }
        return out
    }

    /// Vertices of the regular n-gon, CCW (first point not repeated).
    static func polygonPoints(
        center: SIMD2<Double>, radius: Double, sides: Int, rotation: Double
    ) -> [SIMD2<Double>] {
        guard sides >= 3 else { return [] }
        return (0..<sides).map { i in
            let angle = rotation + Double(i) / Double(sides) * 2 * .pi
            return center + SIMD2(cos(angle), sin(angle)) * radius
        }
    }
}

/// Creation intent, not a permanent geometry lock. Corner names refer to the
/// current normalized bounds, so translating a rectangle cannot stale its anchor.
nonisolated enum RectangleSizingAnchor: String, Codable, Equatable, Sendable {
    case center, minMin, minMax, maxMin, maxMax
    // Center sizing remains center-preserving. These variants only retain the
    // creation-direction corner for default dimension leader placement.
    case centerMinMin, centerMinMax, centerMaxMin, centerMaxMax

    static func centered(from center: SIMD2<Double>, to corner: SIMD2<Double>) -> Self {
        switch diagonal(first: center, min: SIMD2(min(center.x, corner.x), min(center.y, corner.y))) {
        case .minMin: .centerMinMin
        case .minMax: .centerMinMax
        case .maxMin: .centerMaxMin
        default: .centerMaxMax
        }
    }

    // Center rectangles put width opposite the vertical drag direction and
    // height toward the horizontal drag direction; diagonal creation differs.
    var annotationCornerUsesMax: (x: Bool, y: Bool)? {
        switch self {
        case .centerMinMin: (false, false)
        case .centerMinMax: (true, false)
        case .centerMaxMin: (false, true)
        case .centerMaxMax: (true, true)
        default: cornerUsesMax
        }
    }

    static func diagonal(first: SIMD2<Double>, min: SIMD2<Double>) -> Self {
        if first.x <= min.x + 1e-9 {
            return first.y <= min.y + 1e-9 ? .minMin : .minMax
        }
        return first.y <= min.y + 1e-9 ? .maxMin : .maxMax
    }

    var cornerUsesMax: (x: Bool, y: Bool)? {
        switch self {
        case .center, .centerMinMin, .centerMinMax, .centerMaxMin, .centerMaxMax: nil
        case .minMin: (false, false)
        case .minMax: (false, true)
        case .maxMin: (true, false)
        case .maxMax: (true, true)
        }
    }
}

nonisolated struct Sketch: Identifiable, Codable, Equatable, Sendable {
    let id: SketchID
    var name: String
    var plane: SketchPlane
    var entities: [SketchEntity]
    /// Items Manager visibility (spec §11); sketches auto-hide once an
    /// extrude/revolve consumes them.
    var isHidden: Bool
    /// IDs of entities flagged as construction (reference) geometry
    /// (spec §3.3): rendered dashed and excluded from profile detection.
    /// Kept as a side set so `SketchEntity`'s Codable wire format (and every
    /// fixed-arity pattern match on it) stays unchanged.
    var constructionEntityIDs: Set<UUID>
    /// Symbolic geometric constraints (spec §3) lowered by `SketchSolverBridge`.
    var constraints: [SketchConstraint]
    /// Driving dimensions (spec §2.2) lowered by `SketchSolverBridge`.
    var dimensions: [SketchDimension]
    /// Live pattern links (spec §2.5): each keeps its instances slaved to a
    /// seed, so editing the seed re-generates them. Auto-created by the Pattern
    /// tool, never by hand.
    var patternLinks: [SketchPatternLink]
    var rectangleSizingAnchors: [UUID: RectangleSizingAnchor]
    /// Ordered edges of a migrated center rectangle; independent of later branches.
    var rotatedRectangleEdges: [UUID: [UUID]]
    /// Endpoints explicitly detached by Disconnect must not silently proximity-
    /// weld again. Explicit Coincident still reconnects them. Legacy sketches
    /// retain proximity welding through the empty decode default.
    var disconnectedEndpoints: [ConstraintRef]
    /// Radius-construction annotation direction; presentation only, never solved.
    var circleRadiusDirections: [UUID: SIMD2<Double>]
    /// Undriven line readout projection. Presentation only; never a solver input.
    var lineDimensionKinds: [UUID: DimensionKind]

    init(
        id: SketchID = SketchID(),
        name: String = "Sketch",
        plane: SketchPlane,
        entities: [SketchEntity] = [],
        isHidden: Bool = false,
        constructionEntityIDs: Set<UUID> = [],
        constraints: [SketchConstraint] = [],
        dimensions: [SketchDimension] = [],
        patternLinks: [SketchPatternLink] = [],
        rectangleSizingAnchors: [UUID: RectangleSizingAnchor] = [:],
        rotatedRectangleEdges: [UUID: [UUID]] = [:],
        disconnectedEndpoints: [ConstraintRef] = [],
        circleRadiusDirections: [UUID: SIMD2<Double>] = [:],
        lineDimensionKinds: [UUID: DimensionKind] = [:]
    ) {
        self.id = id
        self.name = name
        self.plane = plane
        self.entities = entities
        self.isHidden = isHidden
        self.constructionEntityIDs = constructionEntityIDs
        self.constraints = constraints
        self.dimensions = dimensions
        self.patternLinks = patternLinks
        self.rotatedRectangleEdges = rotatedRectangleEdges
        self.rectangleSizingAnchors = rectangleSizingAnchors
        self.disconnectedEndpoints = disconnectedEndpoints
        self.circleRadiusDirections = circleRadiusDirections
        self.lineDimensionKinds = lineDimensionKinds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, plane, entities, isHidden, constructionEntityIDs
        case constraints, dimensions, patternLinks, rectangleSizingAnchors
        case disconnectedEndpoints, rotatedRectangleEdges, circleRadiusDirections
        case lineDimensionKinds
    }

    /// `name`/`isHidden`/`constructionEntityIDs`/`constraints`/`dimensions`
    /// are optional on decode so pre-A8 / pre-B9 / pre-C documents load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SketchID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Sketch"
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        entities = try container.decode([SketchEntity].self, forKey: .entities)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        constructionEntityIDs =
            try container.decodeIfPresent(Set<UUID>.self, forKey: .constructionEntityIDs) ?? []
        constraints =
            try container.decodeIfPresent([SketchConstraint].self, forKey: .constraints) ?? []
        dimensions =
            try container.decodeIfPresent([SketchDimension].self, forKey: .dimensions) ?? []
        rectangleSizingAnchors = try container.decodeIfPresent(
            [UUID: RectangleSizingAnchor].self, forKey: .rectangleSizingAnchors) ?? [:]
        rotatedRectangleEdges = try container.decodeIfPresent(
            [UUID: [UUID]].self, forKey: .rotatedRectangleEdges) ?? [:]
        patternLinks =
            try container.decodeIfPresent([SketchPatternLink].self, forKey: .patternLinks) ?? []
        disconnectedEndpoints = try container.decodeIfPresent(
            [ConstraintRef].self, forKey: .disconnectedEndpoints) ?? []
        circleRadiusDirections = try container.decodeIfPresent(
            [UUID: SIMD2<Double>].self, forKey: .circleRadiusDirections) ?? [:]
        lineDimensionKinds = try container.decodeIfPresent(
            [UUID: DimensionKind].self, forKey: .lineDimensionKinds) ?? [:]
        RectangleConstruction.recoverLegacyGroups(in: &self)
    }
}

// MARK: - Constraint integrity

nonisolated extension Sketch {
    /// Every constraint/dimension ref points at a live entity. The delete and
    /// trim commands maintain this invariant (review R2-2 — a dangling ref
    /// meant the solver silently dropped the residual while the dimension
    /// kept displaying a value it no longer drove); tests assert it after
    /// every mutation.
    func validateConstraintRefs() -> Bool {
        let ids = Set(entities.map(\.id))
        if disconnectedEndpoints.contains(where: { !ids.contains($0.entityID) }) { return false }
        for constraint in constraints
        where constraint.refs.contains(where: { !ids.contains($0.entityID) }) {
            return false
        }
        for dimension in dimensions
        where dimension.refs.contains(where: { !ids.contains($0.entityID) }) {
            return false
        }
        return true
    }
}

// MARK: - Construction geometry (spec §3.3)

nonisolated extension Sketch {
    func isConstruction(_ entityID: UUID) -> Bool {
        constructionEntityIDs.contains(entityID)
    }

    /// Make Construction (`true`) / Make Regular (`false`) for a batch of entities.
    mutating func setConstruction(_ flag: Bool, forEntityIDs ids: some Sequence<UUID>) {
        if flag {
            constructionEntityIDs.formUnion(ids)
        } else {
            constructionEntityIDs.subtract(ids)
        }
    }

    /// Entities that participate in profile detection (non-construction).
    var regularEntities: [SketchEntity] {
        constructionEntityIDs.isEmpty
            ? entities
            : entities.filter { !constructionEntityIDs.contains($0.id) }
    }
}

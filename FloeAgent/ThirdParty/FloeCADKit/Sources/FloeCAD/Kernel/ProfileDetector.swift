//
//  ProfileDetector.swift
//  openshape3d
//
//  Finds closed profiles in a sketch: circles/rects/ellipses/polygons directly,
//  and simple closed loops walked from line segments and arc chains (degree-2
//  nodes only in v1 — branching arrangements are a v2 problem). Nested profiles
//  are reported so the caller can treat them as holes.
//

import Foundation
import simd

nonisolated struct Profile: Identifiable {
    enum Kind {
        case polygonal
        case circle(center: SIMD2<Double>, radius: Double)
        /// `radiusX`/`radiusY` are the semi-axes BEFORE `rotation` is applied,
        /// matching `SketchEntity.ellipsePoints` — which of them is the major
        /// axis is not fixed, so a consumer must not assume `radiusX >= radiusY`.
        case ellipse(center: SIMD2<Double>, radiusX: Double, radiusY: Double,
                     rotation: Double)
    }

    /// One boundary edge, for callers that can use an EXACT curve.
    ///
    /// `loop` is the tessellated truth every mesh-side consumer reads, and it
    /// stays that way — area, centroid, `contains` and the face signatures all
    /// keep working untouched. This is a side-channel the B-rep path consults
    /// instead, which is why a slot could become analytic without the sketch →
    /// profile → kernel chain changing representation.
    ///
    /// `mid` present = a circular arc THROUGH that point; absent = a straight
    /// line. Three points on a circle determine it uniquely and say which way
    /// round the arc goes, so no centre, radius, angle pair or winding flag is
    /// carried here — those are exactly the things that get sign-flipped on a
    /// reversed traversal.
    struct Segment: Equatable {
        var start: SIMD2<Double>
        var end: SIMD2<Double>
        var mid: SIMD2<Double>?
        /// A spline run (docs/SPLINE_PROFILE_DESIGN.md): the centripetal
        /// Catmull–Rom control points from `start` to `end` in traversal
        /// order, for which the kernel builds ONE B-spline edge — the same
        /// curve `SketchEntity.splinePoints` draws. `closed` marks a closed
        /// spline (the curve returns to its first point; `start == end`).
        /// Nil for lines and arcs.
        var controlPoints: [SIMD2<Double>]? = nil
        var closed: Bool = false

        init(start: SIMD2<Double>, end: SIMD2<Double>, mid: SIMD2<Double>? = nil,
             controlPoints: [SIMD2<Double>]? = nil, closed: Bool = false) {
            self.start = start
            self.end = end
            self.mid = mid
            self.controlPoints = controlPoints
            self.closed = closed
        }
    }

    let id = UUID()
    /// Closed CCW polygon in plane-local coordinates (circles tessellated).
    var loop: [SIMD2<Double>]
    var kind: Kind
    var sourceEntityIDs: Set<UUID>
    /// Exact boundary, in `loop` order — EMPTY when there is nothing to gain.
    ///
    /// Only populated for loops that actually contain an arc. A polygon is
    /// already exact as a polyline (OCCT builds the same wire either way), so
    /// filling this in for one would add a second description of identical
    /// geometry and a second thing to keep in step.
    var segments: [Segment] = []

    /// Which sketch entity owns each boundary edge, in order — the identity
    /// `sourceEntityIDs` throws away by being a set. `edgeEntityIDs` is
    /// parallel to `loop`'s edges (edge i spans `loop[i] → loop[i+1]`);
    /// `segmentEntityIDs` is parallel to `segments`. Both EMPTY for the
    /// single-entity profiles (circle/rect/ellipse/polygon), where the one
    /// entity in `sourceEntityIDs` owns everything. Element naming reads
    /// these through `boundaryIdentity(wireEdge:wireEdgeCount:)` — nothing
    /// else should, because which array applies depends on how the kernel
    /// built the wire.
    var edgeEntityIDs: [UUID] = []
    var segmentEntityIDs: [UUID] = []

    /// The sketch entity that owns wire edge `j` (1-based, construction
    /// order) of this profile's boundary, plus how many earlier wire edges
    /// the same entity owns (the `occurrence` disambiguator — derived from
    /// the profile arrays alone, so a dropped history row can't shift it).
    ///
    /// `wireEdgeCount` is how many wall edges the kernel actually built for
    /// this loop; it selects WHICH boundary description the wire came from —
    /// one edge per exact segment, one per polyline point, or one for a
    /// conic. Nil when no description matches: refusing to guess is the
    /// contract, because a wrong identity is worse than a missing one.
    func boundaryIdentity(wireEdge j: Int, wireEdgeCount: Int)
        -> (entity: UUID, occurrence: Int)? {
        guard j >= 1, j <= wireEdgeCount else { return nil }
        if sourceEntityIDs.count == 1, let only = sourceEntityIDs.first {
            return (only, j - 1)
        }
        func lookup(_ ids: [UUID]) -> (UUID, Int)? {
            guard j <= ids.count else { return nil }
            let entity = ids[j - 1]
            return (entity, ids[..<(j - 1)].count(where: { $0 == entity }))
        }
        if !segmentEntityIDs.isEmpty, wireEdgeCount == segmentEntityIDs.count {
            return lookup(segmentEntityIDs)
        }
        // The kernel splits an OPEN spline where its straight end spans meet
        // the curve (a crease may not sit inside one face — offsets refuse
        // it): three edges for four or more points, two for three. The wire
        // then has more edges than segments; expand the entity list the same
        // way so every piece still names its spline.
        if !segmentEntityIDs.isEmpty, segmentEntityIDs.count == segments.count {
            var expanded: [UUID] = []
            for (segment, entity) in zip(segments, segmentEntityIDs) {
                var pieces = 1
                if let points = segment.controlPoints, !segment.closed {
                    pieces = points.count >= 4 ? 3 : (points.count == 3 ? 2 : 1)
                }
                expanded.append(contentsOf: repeatElement(entity, count: pieces))
            }
            if expanded.count != segmentEntityIDs.count, wireEdgeCount == expanded.count {
                return lookup(expanded)
            }
        }
        if wireEdgeCount == loop.count, edgeEntityIDs.count == loop.count {
            return lookup(edgeEntityIDs)
        }
        return nil
    }

    /// Signed area (positive for CCW).
    var area: Double {
        Profile.signedArea(loop)
    }

    var centroid: SIMD2<Double> {
        guard !loop.isEmpty else { return .zero }
        return loop.reduce(SIMD2<Double>.zero, +) / Double(loop.count)
    }

    /// A point guaranteed to lie INSIDE the region, for seeding a later
    /// re-detection. The vertex average (`centroid`) is not one: on a ring,
    /// a C or an L it falls in the hole or outside the arm — building a
    /// counterbore whose annulus a rectangular cut had bitten into (practice
    /// problem 4.38, 2026-09-04), the recorded seed landed in the through
    /// hole, replay resolved the wrong region and the cut fell back to a
    /// mesh of half the body. Nudging an edge midpoint toward the interior
    /// (the loop is CCW, so the interior is on the left) always finds one.
    var interiorPoint: SIMD2<Double> {
        let c = centroid
        if contains(c) { return c }
        guard loop.count >= 3 else { return c }
        var lo = loop[0], hi = loop[0]
        for p in loop { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let step = max(simd_length(hi - lo) * 1e-3, 1e-6)
        for i in 0..<loop.count {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            let d = b - a
            let len = simd_length(d)
            guard len > 1e-12 else { continue }
            let leftNormal = SIMD2(-d.y, d.x) / len
            let candidate = (a + b) / 2 + leftNormal * step
            if contains(candidate) { return candidate }
        }
        return c
    }

    func contains(_ p: SIMD2<Double>) -> Bool {
        // Ray casting.
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let a = loop[i]
            let b = loop[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func signedArea(_ loop: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        var j = loop.count - 1
        for i in 0..<loop.count {
            sum += (loop[j].x * loop[i].y) - (loop[i].x * loop[j].y)
            j = i
        }
        return sum / 2
    }
}

nonisolated enum ProfileDetector {
    static let circleSegments = 48
    private static let quantum: Double = 1e-6
    /// Chain endpoints closer than this are one junction (see `lineLoops`).
    static let endpointWeldTolerance: Double = 1e-3

    static func detectProfiles(in sketch: Sketch) -> [Profile] {
        var profiles: [Profile] = []
        // Construction (reference) geometry never bounds a profile (spec §3.3).
        let regular = sketch.regularEntities
        // A circle, rect or polygon crossed by other outlines is re-expressed
        // as the arcs and lines the face walker splits and joins, so two
        // overlapping circles give a lens and two crescents. Everything else
        // (and every shape crossed nowhere) is emitted as before.
        let crossed = splitCrossedClosedShapes(regular)
        let entities = regular.filter { !crossed.ids.contains($0.id) }

        // Circles are always closed profiles.
        for entity in entities {
            if case let .circle(id, center, radius) = entity, radius > 1e-6 {
                let loop = (0..<circleSegments).map { i -> SIMD2<Double> in
                    let angle = Double(i) / Double(circleSegments) * 2 * .pi
                    return center + SIMD2(cos(angle), sin(angle)) * radius
                }
                profiles.append(Profile(
                    loop: loop, // CCW by construction
                    kind: .circle(center: center, radius: radius),
                    sourceEntityIDs: [id]
                ))
            }
        }

        // Closed splines are closed profiles too, carried as ONE exact segment
        // holding the control points, so the kernel builds a single B-spline
        // edge and the wall it sweeps is one face (docs/SPLINE_PROFILE_DESIGN.md).
        // Reversing the control points reverses the curve, so a CW spline is
        // normalised by re-sampling them reversed — loop and segment agree.
        for entity in entities {
            if case let .spline(id, points, closed) = entity, closed, points.count >= 3 {
                var control = points
                var loop = SketchEntity.splinePoints(control, closed: true)
                if Profile.signedArea(loop) < 0 {
                    control.reverse()
                    loop = SketchEntity.splinePoints(control, closed: true)
                }
                guard Profile.signedArea(loop) > 1e-9, !isSelfIntersecting(loop) else { continue }
                profiles.append(Profile(
                    loop: loop, kind: .polygonal, sourceEntityIDs: [id],
                    segments: [Profile.Segment(start: control[0], end: control[0],
                                               controlPoints: control, closed: true)],
                    segmentEntityIDs: [id]))
            }
        }

        // Rects are closed by definition; emit directly (CCW).
        for entity in entities {
            if case let .rect(id, lo, hi) = entity {
                let loop = [
                    lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y),
                ]
                profiles.append(Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [id]))
            }
        }

        // Ellipses and polygons are closed profiles too (loops CCW by construction).
        for entity in entities {
            switch entity {
            case let .ellipse(id, center, radiusX, radiusY, rotation)
                where radiusX > 1e-6 && radiusY > 1e-6:
                let loop = SketchEntity.ellipsePoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    rotation: rotation, segments: circleSegments
                )
                profiles.append(Profile(
                    loop: loop,
                    kind: .ellipse(center: center, radiusX: radiusX,
                                   radiusY: radiusY, rotation: rotation),
                    sourceEntityIDs: [id]))
            case let .polygon(id, center, radius, sides, rotation)
                where radius > 1e-6 && sides >= 3:
                let loop = SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                )
                profiles.append(Profile(loop: loop, kind: .polygonal, sourceEntityIDs: [id]))
            default:
                break
            }
        }

        // Walk loops from line segments and arc chains (including the pieces
        // of any crossed closed shape).
        profiles.append(contentsOf: lineLoops(in: entities + crossed.pieces))
        return profiles
    }

    /// Profiles fully containing `point`, smallest area first (innermost region).
    ///
    /// A profile whose boundary crosses an ellipse or a closed spline is left
    /// out: those curves are not split into regions, so the region under the
    /// point is not the profile's loop, and extruding it would build the wrong
    /// solid. Leaving it out makes the pick (and a rebuild) refuse instead.
    static func profiles(at point: SIMD2<Double>, in sketch: Sketch) -> [Profile] {
        let all = detectProfiles(in: sketch)
        return all
            .filter { $0.contains(point) && !isCrossedByUnsplitCurve($0, among: all) }
            .sorted { abs($0.area) < abs($1.area) }
    }

    /// Profiles from `all` nested inside `outer` (used as holes).
    ///
    /// Nested means a point inside the candidate lies inside `outer` and the
    /// two boundaries don't cross. Until 2026-09-16 this tested only the
    /// candidate's centroid, which took a circle CROSSING the outer boundary
    /// for a hole: the face got an inner wire through its outer one, an
    /// invalid solid with the whole circle subtracted. Crossing lines, arcs,
    /// circles, rects and polygons are now split into regions, so only a
    /// boundary with an ellipse or a spline in it can still cross another.
    /// Touching is not crossing: a hole tangent to the outer boundary stays
    /// a hole, as it always was (checking every tessellation vertex, or
    /// chord crossings, would drop it).
    static func holes(of outer: Profile, among all: [Profile]) -> [Profile] {
        all.filter { candidate in
            candidate.id != outer.id
                && abs(candidate.area) < abs(outer.area)
                && outer.contains(candidate.interiorPoint)
                && !((hasUnsplitCurve(outer) || hasUnsplitCurve(candidate))
                     && loopsCross(outer.loop, candidate.loop))
        }
    }

    /// True when `profile`'s boundary crosses one with an ellipse or a spline
    /// in it: the curves `splitCrossedClosedShapes` and the face walker do
    /// not split.
    private static func isCrossedByUnsplitCurve(_ profile: Profile, among all: [Profile]) -> Bool {
        all.contains { other in
            other.id != profile.id
                && (hasUnsplitCurve(profile) || hasUnsplitCurve(other))
                && loopsCross(profile.loop, other.loop)
        }
    }

    private static func hasUnsplitCurve(_ profile: Profile) -> Bool {
        if case .ellipse = profile.kind { return true }
        return profile.segments.contains { $0.controlPoints != nil }
    }

    // MARK: - Loop walking over line segments

    private struct NodeKey: Hashable {
        let x, y: Int64
        init(_ p: SIMD2<Double>) {
            x = MeshQuantize.key64(p.x, quantum: ProfileDetector.quantum)
            y = MeshQuantize.key64(p.y, quantum: ProfileDetector.quantum)
        }
    }

    private static func lineLoops(in entities: [SketchEntity]) -> [Profile] {
        // A chain starts as one entity exploded to a polyline. Straight chains
        // are split where they cross each other; arcs are split where they
        // cross lines or other arcs (both below). Splines use only their
        // endpoints as junctions, retaining their tessellated interior.
        struct Chain {
            let entityID: UUID
            var points: [SIMD2<Double>]
            /// True when `points` is a TESSELLATION of a real curve, so the
            /// analytic boundary should describe it as an arc rather than as
            /// the polyline standing in for it.
            let isArc: Bool
            /// An OPEN spline's control points, in the order of `points`, so a
            /// loop can carry it as one exact segment (one B-spline edge).
            var spline: [SIMD2<Double>]? = nil
            /// An arc's exact geometry (CCW from `start` through `sweep`), so a
            /// crossing can be found and the arc split without going through
            /// its tessellation.
            var arc: ArcGeometry? = nil
        }

        var chains: [Chain] = []
        for entity in entities {
            switch entity {
            case let .line(id, a, b) where simd_length(b - a) > 1e-9:
                chains.append(Chain(entityID: id, points: [a, b], isArc: false))
            case let .arc(id, center, radius, startAngle, endAngle):
                let points = SketchEntity.arcPoints(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    segmentsPerTurn: circleSegments
                )
                if points.count >= 2 {
                    chains.append(Chain(
                        entityID: id, points: points, isArc: true,
                        arc: ArcGeometry(center: center, radius: radius, start: startAngle,
                                         sweep: SketchEntity.arcSweep(startAngle: startAngle,
                                                                      endAngle: endAngle))))
                }
            case let .spline(id, points, closed) where !closed && points.count >= 2:
                // An open spline joins loops like any chain: its endpoints are
                // the junction candidates, its samples the polyline, and its
                // control points ride along for the exact edge.
                let samples = SketchEntity.splinePoints(points, closed: false)
                if samples.count >= 2, simd_length(samples.last! - samples.first!) > 1e-9 {
                    chains.append(Chain(entityID: id, points: samples, isArc: false, spline: points))
                }
            default:
                break
            }
        }
        guard chains.count >= 2 else { return [] }

        // Weld near-coincident chain ENDPOINTS before they become nodes. The
        // node key quantises to 1e-6 mm, which is exact-arithmetic territory:
        // an arc whose angles were derived from a line's rounded endpoint
        // lands 2e-5 mm away from it, and a perfectly good line/arc/line loop
        // (practice sheet 7.2's spherical cap) came back "profile unresolved".
        // Anything within a micron is the same junction; a real gap is orders
        // of magnitude larger than that.
        do {
            var representatives: [SIMD2<Double>] = []
            func weld(_ p: SIMD2<Double>) -> SIMD2<Double> {
                for r in representatives where simd_length(r - p) <= endpointWeldTolerance { return r }
                representatives.append(p)
                return p
            }
            for i in chains.indices {
                chains[i].points[0] = weld(chains[i].points[0])
                chains[i].points[chains[i].points.count - 1] = weld(chains[i].points[chains[i].points.count - 1])
            }
        }

        // Interior straight-line crossings are junctions too. Split only the
        // temporary graph: the original entities, constraints and boundary
        // ownership remain unchanged. Curves retain their analytic chains.
        let straightIndices = chains.indices.filter {
            !chains[$0].isArc && chains[$0].spline == nil && chains[$0].points.count == 2
        }
        var cuts: [Int: [(t: Double, point: SIMD2<Double>)]] = [:]
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            a.x * b.y - a.y * b.x
        }
        for (offset, i) in straightIndices.enumerated() {
            let a = chains[i].points[0], r = chains[i].points[1] - a
            for j in straightIndices.dropFirst(offset + 1) {
                let c = chains[j].points[0], v = chains[j].points[1] - c
                let denominator = cross(r, v)
                let length = simd_length(r)
                // Normalize numerically collinear overlaps into matching
                // subsegments before deduplication. Solver roundoff can put a
                // partial duplicate a few ulps off its boundary; angle sorting
                // must not turn that into a spur that swallows the whole face.
                // Use node precision, not the much broader endpoint weld.
                if abs(cross(c - a, r)) / length <= quantum,
                   abs(cross(c + v - a, r)) / length <= quantum {
                    let rr = simd_length_squared(r)
                    let t0 = simd_dot(c - a, r) / rr
                    let t1 = simd_dot(c + v - a, r) / rr
                    let lo = max(0, min(t0, t1)), hi = min(1, max(t0, t1))
                    if hi > lo {
                        for t in [lo, hi] {
                            let point = a + r * t
                            let u = min(1, max(0, simd_dot(point - c, v) / simd_length_squared(v)))
                            cuts[i, default: []].append((t, point))
                            cuts[j, default: []].append((u, point))
                        }
                    }
                    continue
                }
                guard abs(denominator) > 1e-12 * length * simd_length(v) else { continue }
                let t = cross(c - a, v) / denominator
                let u = cross(c - a, r) / denominator
                guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                let point = a + r * t
                cuts[i, default: []].append((t, point))
                cuts[j, default: []].append((u, point))
            }
        }

        // Arcs split where they cross lines and other arcs, including the
        // pieces of a crossed circle (`splitCrossedClosedShapes`). An arc's
        // cut parameter is the fraction of its sweep. A computed crossing
        // snaps to an existing chain endpoint within the weld tolerance, so
        // every chain through one crossing gets the same exact point: two
        // separately computed copies a few ulps apart can quantise to
        // different nodes and leave the face open.
        //
        // Only where the other curve CROSSES or ends on it, though; see
        // `splits(at:side:others:)`. A curve that only touches the arc
        // stays whole there.
        let arcIndices = chains.indices.filter { chains[$0].arc != nil }
        if !arcIndices.isEmpty {
            var anchors = chains.flatMap { [$0.points[0], $0.points[$0.points.count - 1]] }
            func anchored(_ p: SIMD2<Double>) -> SIMD2<Double> {
                for q in anchors where simd_length(p - q) <= endpointWeldTolerance { return q }
                anchors.append(p)
                return p
            }
            let pieces: [CurvePiece?] = chains.map { chain in
                if let arc = chain.arc { return .arc(arc) }
                if chain.spline == nil, chain.points.count == 2 {
                    return .segment(chain.points[0], chain.points[1])
                }
                return nil
            }
            func splits(_ index: Int, at point: SIMD2<Double>) -> Bool {
                guard let own = pieces[index] else { return false }
                let others = pieces.indices.compactMap { $0 == index ? nil : pieces[$0] }
                return ProfileDetector.splits(at: point, side: side(of: own), others: others)
            }
            for i in arcIndices {
                guard let arc = chains[i].arc else { continue }
                for j in straightIndices {
                    let a = chains[j].points[0], b = chains[j].points[1]
                    for hit in segmentCircleHits(a, b, center: arc.center, radius: arc.radius) {
                        guard let u = arc.parameter(of: hit.point) else { continue }
                        let cutsArc = splits(i, at: hit.point), cutsLine = splits(j, at: hit.point)
                        guard cutsArc || cutsLine else { continue }
                        let point = anchored(hit.point)
                        if cutsLine { cuts[j, default: []].append((hit.t, point)) }
                        if cutsArc { cuts[i, default: []].append((u, point)) }
                    }
                }
            }
            for (offset, i) in arcIndices.enumerated() {
                guard let first = chains[i].arc else { continue }
                for j in arcIndices.dropFirst(offset + 1) {
                    guard let second = chains[j].arc else { continue }
                    for hit in circleCircleHits(first.center, first.radius, second.center, second.radius) {
                        guard let u = first.parameter(of: hit), let v = second.parameter(of: hit) else { continue }
                        let cutsFirst = splits(i, at: hit), cutsSecond = splits(j, at: hit)
                        guard cutsFirst || cutsSecond else { continue }
                        let point = anchored(hit)
                        if cutsFirst { cuts[i, default: []].append((u, point)) }
                        if cutsSecond { cuts[j, default: []].append((v, point)) }
                    }
                }
            }
        }

        var splitChains: [Chain] = []
        for (index, chain) in chains.enumerated() {
            guard let interior = cuts[index] else {
                splitChains.append(chain)
                continue
            }
            if let arc = chain.arc {
                // Each piece is re-sampled over its own angular range, with
                // its ends pinned to the exact crossing points.
                let ordered = ([(t: 0.0, point: chain.points[0])] + interior
                    + [(t: 1.0, point: chain.points[chain.points.count - 1])]).sorted { $0.t < $1.t }
                var previous = ordered[0]
                for cut in ordered.dropFirst() where NodeKey(cut.point) != NodeKey(previous.point) {
                    let start = arc.start + arc.sweep * previous.t
                    let sweep = arc.sweep * (cut.t - previous.t)
                    var points = SketchEntity.arcPoints(
                        center: arc.center, radius: arc.radius,
                        startAngle: start, endAngle: start + sweep,
                        segmentsPerTurn: circleSegments)
                    if points.count >= 2 {
                        points[0] = previous.point
                        points[points.count - 1] = cut.point
                        splitChains.append(Chain(
                            entityID: chain.entityID, points: points, isArc: true,
                            arc: ArcGeometry(center: arc.center, radius: arc.radius,
                                             start: start, sweep: sweep)))
                    }
                    previous = cut
                }
                continue
            }
            let ordered = ([(t: 0.0, point: chain.points[0])] + interior
                + [(t: 1.0, point: chain.points[1])]).sorted { $0.t < $1.t }
            var previous = ordered[0].point
            for cut in ordered.dropFirst() where NodeKey(cut.point) != NodeKey(previous) {
                splitChains.append(Chain(entityID: chain.entityID,
                                         points: [previous, cut.point], isArc: false))
                previous = cut.point
            }
        }
        chains = splitChains

        // A repeated straight stroke is still an editable entity, but it is
        // only one geometric boundary. Parallel coincident half-edges create
        // zero-area cycles and can swallow an otherwise closed face. Keep the
        // first entity as the stable boundary owner; do not mutate the sketch.
        // Only straight chains qualify: arcs/splines with the same endpoints
        // may enclose a real region and must remain distinct.
        var straightBoundaries = Set<Set<NodeKey>>()
        chains = chains.filter { chain in
            guard !chain.isArc, chain.spline == nil, chain.points.count == 2 else { return true }
            return straightBoundaries.insert(Set(chain.points.map(NodeKey.init))).inserted
        }

        // Planar FACE TRAVERSAL over half-edges.
        //
        // The previous walker followed a chain and gave up at any node whose
        // degree wasn't 2, so a single shared endpoint made every loop through
        // it undetectable — draw a divider across a rectangle, or mirror one
        // about a shared edge, and BOTH cells and the outer boundary vanished
        // at once. That is not merely "no new profile": `resolveProfile`
        // re-runs detection on every rebuild and treats nil as a hard failure,
        // so an already-built body disappeared the moment its sketch gained a
        // junction (2026-08-25 review round 3, finding R3-B).
        //
        // Face traversal handles junctions of any degree: at each arrival node
        // take the outgoing half-edge one step CLOCKWISE from the twin, which
        // traces every interior face counter-clockwise (positive area) and the
        // outer face clockwise (negative — discarded by the area test).
        struct HalfEdge {
            let chain: Int
            let forward: Bool
            let to: NodeKey
            /// Direction leaving the tail (see `outAngles`).
            let outAngle: Double
        }

        /// The directions leaving a chain's first and last point. A line's is
        /// its own. An arc's is taken along the EXACT arc a short step from
        /// the end, not along its first tessellation chord: that chord leans
        /// half a tessellation step (3.75° at 48 per turn) off the tangent,
        /// enough to swap two curves leaving a node nearly together. A hull
        /// of tube chords touching its Ø200 outer circle at three points came
        /// out as one region covering the whole disc (practice problem 13.9,
        /// 2026-09-16). The step is short but not zero, so the order keeps
        /// curvature: of two tangent curves, the tighter one turns away first.
        func outAngles(of chain: Chain) -> (first: Double, last: Double) {
            let pts = chain.points, n = pts.count
            let chords = (first: atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x),
                          last: atan2(pts[n - 2].y - pts[n - 1].y, pts[n - 2].x - pts[n - 1].x))
            guard let arc = chain.arc, arc.radius > 1e-9, arc.sweep > 1e-12 else { return chords }
            let step = min(arc.sweep / 2, 1e-3 / arc.radius)
            func point(_ angle: Double) -> SIMD2<Double> {
                arc.center + SIMD2(cos(angle), sin(angle)) * arc.radius
            }
            let start = point(arc.start), afterStart = point(arc.start + step)
            let end = point(arc.start + arc.sweep), beforeEnd = point(arc.start + arc.sweep - step)
            let fromStart = atan2(afterStart.y - start.y, afterStart.x - start.x)
            let fromEnd = atan2(beforeEnd.y - end.y, beforeEnd.x - end.x)
            return simd_length(pts[0] - start) <= simd_length(pts[0] - end)
                ? (fromStart, fromEnd) : (fromEnd, fromStart)
        }

        var halfEdges: [HalfEdge] = []
        var outgoing: [NodeKey: [Int]] = [:]
        for (index, chain) in chains.enumerated() {
            let pts = chain.points
            let ka = NodeKey(pts.first!)
            let kb = NodeKey(pts.last!)
            guard ka != kb else { continue }
            let (aOut, bOut) = outAngles(of: chain)
            // Appended in pairs, so a half-edge's twin is always `index ^ 1`.
            outgoing[ka, default: []].append(halfEdges.count)
            halfEdges.append(HalfEdge(chain: index, forward: true, to: kb, outAngle: aOut))
            outgoing[kb, default: []].append(halfEdges.count)
            halfEdges.append(HalfEdge(chain: index, forward: false, to: ka, outAngle: bOut))
        }
        guard !halfEdges.isEmpty else { return [] }
        for (node, ring) in outgoing {
            outgoing[node] = ring.sorted { halfEdges[$0].outAngle < halfEdges[$1].outAngle }
        }

        var visited = Set<Int>()
        var profiles: [Profile] = []

        // Start from each half-edge in index order, so output order depends on
        // entity order alone — never on hash order.
        for start in halfEdges.indices where !visited.contains(start) {
            var cycle: [Int] = []
            var edge = start
            while !visited.contains(edge) {
                visited.insert(edge)
                cycle.append(edge)
                let twin = edge ^ 1
                guard let ring = outgoing[halfEdges[edge].to],
                      let position = ring.firstIndex(of: twin)
                else { break }
                // One step clockwise from the twin.
                edge = ring[(position + ring.count - 1) % ring.count]
                if cycle.count > halfEdges.count { break }
            }
            // A clean face returns to the half-edge it started from.
            guard edge == start, cycle.count >= 2 else { continue }

            var loop: [SIMD2<Double>] = []
            var chainIDs: [Int] = []
            var segments: [Profile.Segment] = []
            var edgeEntityIDs: [UUID] = []
            var segmentEntityIDs: [UUID] = []
            var sawCurve = false   // an arc or a spline: an exact boundary worth carrying
            var spur = false
            for index in cycle {
                let half = halfEdges[index]
                if chainIDs.contains(half.chain) { spur = true; break }
                chainIDs.append(half.chain)
                let chain = chains[half.chain]
                let pts = half.forward ? chain.points : Array(chain.points.reversed())
                loop.append(contentsOf: pts.dropLast())
                // Each appended point starts one loop edge, so the chain owns
                // the next pts.count-1 edges — identity in traversal order,
                // which the set below cannot carry.
                edgeEntityIDs.append(contentsOf: Array(
                    repeating: chain.entityID, count: max(0, pts.count - 1)))
                segmentEntityIDs.append(chain.entityID)
                // The chain occupies one contiguous run of `loop`, so its
                // exact boundary is one segment spanning the same ground.
                // An interior SAMPLE serves as the arc's third point: it is on
                // the true arc by construction, whichever way the face
                // traversal happened to walk this chain.
                if let control = chain.spline {
                    // The control points in THIS traversal's order: a reversed
                    // Catmull–Rom is the same curve walked backwards.
                    sawCurve = true
                    segments.append(Profile.Segment(
                        start: pts[0], end: pts[pts.count - 1],
                        controlPoints: half.forward ? control : control.reversed()))
                } else if chain.isArc, pts.count >= 3 {
                    sawCurve = true
                    segments.append(Profile.Segment(
                        start: pts[0], end: pts[pts.count - 1], mid: pts[pts.count / 2]))
                } else if let first = pts.first, let last = pts.last {
                    segments.append(Profile.Segment(start: first, end: last))
                }
            }
            // A dangling edge is walked out and back inside the same face,
            // producing a zero-width slit. Legal as a region, but the mesh
            // extruder wants simple polygons — skip, as the old walker did.
            guard !spur, loop.count >= 3 else { continue }

            // Interior faces come out CCW; the single outer face is CW and is
            // dropped here, which is what keeps a plain rectangle to ONE
            // profile rather than two.
            guard Profile.signedArea(loop) > 1e-9 else { continue }
            guard !isSelfIntersecting(loop) else { continue }

            profiles.append(Profile(
                loop: loop,
                kind: .polygonal,
                sourceEntityIDs: Set(chainIDs.map { chains[$0].entityID }),
                // Nothing to gain on an all-straight loop; see `segments`.
                segments: sawCurve ? segments : [],
                edgeEntityIDs: edgeEntityIDs,
                // Parallel to `segments`, so it follows the same emptiness.
                segmentEntityIDs: sawCurve ? segmentEntityIDs : []
            ))
        }
        return profiles
    }

    private static func isSelfIntersecting(_ loop: [SIMD2<Double>]) -> Bool {
        let n = loop.count
        guard n > 3 else { return false }
        for i in 0..<n {
            let a1 = loop[i]
            let a2 = loop[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip adjacent segments (shared endpoints).
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = loop[j]
                let b2 = loop[(j + 1) % n]
                if segmentsIntersect(a1, a2, b1, b2) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ p1: SIMD2<Double>, _ p2: SIMD2<Double>,
        _ p3: SIMD2<Double>, _ p4: SIMD2<Double>
    ) -> Bool {
        func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// True when any edge of loop `p` properly crosses any edge of loop `q`.
    /// Touching and collinear overlap don't count, so regions that share a
    /// boundary (split pieces of one arrangement) never report crossing.
    static func loopsCross(_ p: [SIMD2<Double>], _ q: [SIMD2<Double>]) -> Bool {
        guard p.count >= 2, q.count >= 2 else { return false }
        func bounds(_ loop: [SIMD2<Double>]) -> (SIMD2<Double>, SIMD2<Double>) {
            var lo = loop[0], hi = loop[0]
            for v in loop { lo = simd_min(lo, v); hi = simd_max(hi, v) }
            return (lo, hi)
        }
        let (plo, phi) = bounds(p), (qlo, qhi) = bounds(q)
        guard plo.x <= qhi.x, qlo.x <= phi.x, plo.y <= qhi.y, qlo.y <= phi.y else { return false }
        for i in p.indices {
            let a1 = p[i], a2 = p[(i + 1) % p.count]
            for j in q.indices where segmentsIntersect(a1, a2, q[j], q[(j + 1) % q.count]) {
                return true
            }
        }
        return false
    }

    // MARK: - Crossing outlines

    /// An arc's exact geometry: CCW from `start` (radians) through `sweep`,
    /// where a full circle has `sweep` 2π.
    struct ArcGeometry {
        let center: SIMD2<Double>
        let radius: Double
        let start: Double
        let sweep: Double

        /// Where `point` (assumed on the circle) falls along the arc, as a
        /// fraction of the sweep; nil when it lies outside the arc.
        func parameter(of point: SIMD2<Double>) -> Double? {
            let tolerance = 1e-9
            let angle = atan2(point.y - center.y, point.x - center.x)
            var delta = (angle - start).truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            if delta > 2 * .pi - tolerance { delta = 0 }
            guard sweep > 1e-12, delta <= sweep + tolerance else { return nil }
            return min(1, delta / sweep)
        }
    }

    /// One straight or circular piece of an entity's outline, for finding
    /// where outlines cross.
    private enum CurvePiece {
        case segment(SIMD2<Double>, SIMD2<Double>)
        case arc(ArcGeometry)
    }

    /// The splittable pieces of an entity's outline. Ellipses and splines
    /// have none: they are never split (see `profiles(at:)`).
    private static func curvePieces(of entity: SketchEntity) -> [CurvePiece] {
        switch entity {
        case let .line(_, a, b) where simd_length(b - a) > 1e-9:
            return [.segment(a, b)]
        case let .arc(_, center, radius, startAngle, endAngle) where radius > 1e-6:
            let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
            guard sweep > 1e-9 else { return [] }
            return [.arc(ArcGeometry(center: center, radius: radius, start: startAngle, sweep: sweep))]
        case let .circle(_, center, radius) where radius > 1e-6:
            return [.arc(ArcGeometry(center: center, radius: radius, start: 0, sweep: 2 * .pi))]
        case let .rect(_, lo, hi):
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            return (0..<4).map { .segment(corners[$0], corners[($0 + 1) % 4]) }
        case let .polygon(_, center, radius, sides, rotation) where radius > 1e-6 && sides >= 3:
            let corners = SketchEntity.polygonPoints(center: center, radius: radius,
                                                     sides: sides, rotation: rotation)
            return corners.indices.map { .segment(corners[$0], corners[($0 + 1) % corners.count]) }
        default:
            return []
        }
    }

    /// Circles, rects and polygons that other outlines cross, or end on, at
    /// two or more distinct points, re-expressed as arcs (a circle, split at
    /// those angles) or lines (a rect's or polygon's sides) under the same
    /// entity id, for `lineLoops` to split further and walk.
    ///
    /// A shape split at one point or none stays a standalone profile, and so
    /// does one that other outlines only touch (`splits(at:side:others:)`),
    /// so a sketch without crossings keeps exactly the profiles and
    /// identities it had. Before 2026-09-16 no closed shape was ever split:
    /// two overlapping circles gave two full circles, and `holes(of:)` then
    /// took the smaller one for a hole of the larger — an invalid solid with
    /// the wrong volume.
    private static func splitCrossedClosedShapes(_ entities: [SketchEntity])
        -> (ids: Set<UUID>, pieces: [SketchEntity]) {
        let outlines = entities.map { curvePieces(of: $0) }
        var ids = Set<UUID>()
        var pieces: [SketchEntity] = []
        for (index, entity) in entities.enumerated() {
            switch entity {
            case .circle, .rect, .polygon: break
            default: continue
            }
            let own = outlines[index]
            guard !own.isEmpty, let inside = closedSide(of: entity) else { continue }
            let others = outlines.indices.flatMap { $0 == index ? [] : outlines[$0] }
            var hits: [SIMD2<Double>] = []
            for a in own {
                for b in others {
                    for p in crossings(a, b)
                    where !hits.contains(where: { simd_length($0 - p) <= endpointWeldTolerance }) {
                        hits.append(p)
                    }
                }
            }
            // Touching points don't split it; see `splits(at:side:others:)`.
            hits = hits.filter { splits(at: $0, side: inside, others: others) }
            guard hits.count >= 2 else { continue }
            ids.insert(entity.id)
            switch entity {
            case let .circle(id, center, radius):
                let angles = hits.map { atan2($0.y - center.y, $0.x - center.x) }.sorted()
                for (i, start) in angles.enumerated() {
                    pieces.append(.arc(id: id, center: center, radius: radius,
                                       startAngle: start, endAngle: angles[(i + 1) % angles.count]))
                }
            default:
                for case let .segment(a, b) in own {
                    pieces.append(.line(id: entity.id, a: a, b: b))
                }
            }
        }
        return (ids, pieces)
    }

    /// Whether the outlines in `others` split a curve at `point`, a point
    /// on it; `side` is positive on one side of the curve and negative on
    /// the other. They split it where they CROSS it (some arrive from each
    /// side) or where an odd number of their ends and passes meet it (a line
    /// ending on a circle, which is how a pie slice or a slot drawn from
    /// circles closes). An even number arriving from one side only touch it:
    /// a hole tangent to its boundary, or a hull of tube chords with a vertex
    /// on its outer circle (practice problem 13.9). A touching point stays
    /// unsplit, as it was before crossings were split: the region between
    /// two curves meeting there tapers to a cusp, the two tessellations cross
    /// inside the cusp, and the self-intersecting loop would be dropped,
    /// taking a region the sketch had always had with it.
    private static func splits(
        at point: SIMD2<Double>, side: (SIMD2<Double>) -> Double, others: [CurvePiece]
    ) -> Bool {
        var count = 0, fromInside = false, fromOutside = false
        for piece in others {
            for probe in probes(of: piece, near: point) {
                count += 1
                let s = side(probe)
                if s > 1e-10 { fromInside = true } else if s < -1e-10 { fromOutside = true }
            }
        }
        return (fromInside && fromOutside) || count % 2 == 1
    }

    /// Points a short step (0.1 µm) along `piece` each way from `point`,
    /// leaving out a way in which the piece ends at `point`; none when the
    /// piece doesn't pass through `point`.
    private static func probes(of piece: CurvePiece, near point: SIMD2<Double>) -> [SIMD2<Double>] {
        let step = 1e-4, tolerance = endpointWeldTolerance
        switch piece {
        case let .segment(a, b):
            let length = simd_length(b - a)
            guard length > 1e-12 else { return [] }
            let direction = (b - a) / length
            let along = simd_dot(point - a, direction)
            guard along >= -tolerance, along <= length + tolerance,
                  simd_length(point - (a + direction * along)) <= tolerance else { return [] }
            var out: [SIMD2<Double>] = []
            if along > tolerance { out.append(point - direction * min(step, along / 2)) }
            if length - along > tolerance { out.append(point + direction * min(step, (length - along) / 2)) }
            return out
        case let .arc(arc):
            guard arc.radius > 1e-9,
                  abs(simd_length(point - arc.center) - arc.radius) <= tolerance else { return [] }
            let angle = atan2(point.y - arc.center.y, point.x - arc.center.x)
            func at(_ offset: Double) -> SIMD2<Double> {
                arc.center + SIMD2(cos(angle + offset), sin(angle + offset)) * arc.radius
            }
            if arc.sweep >= 2 * .pi - 1e-12 {
                return [at(-step / arc.radius), at(step / arc.radius)]
            }
            var delta = (angle - arc.start).truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            // Past the end but nearer the start than the end: before the start.
            if delta > arc.sweep + (2 * .pi - arc.sweep) / 2 { delta -= 2 * .pi }
            let fromStart = delta * arc.radius, toEnd = (arc.sweep - delta) * arc.radius
            guard fromStart >= -tolerance, toEnd >= -tolerance else { return [] }
            var out: [SIMD2<Double>] = []
            if fromStart > tolerance { out.append(at(-min(step, fromStart / 2) / arc.radius)) }
            if toEnd > tolerance { out.append(at(min(step, toEnd / 2) / arc.radius)) }
            return out
        }
    }

    /// Which side of a piece's line or circle a point is on (positive to the
    /// left of a segment, inside a circle).
    private static func side(of piece: CurvePiece) -> (SIMD2<Double>) -> Double {
        switch piece {
        case let .segment(a, b):
            let length = max(simd_length(b - a), 1e-12)
            return { p in ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / length }
        case let .arc(arc):
            return { p in arc.radius - simd_length(p - arc.center) }
        }
    }

    /// Positive inside a circle, rect or polygon, negative outside; nil for
    /// other entities.
    private static func closedSide(of entity: SketchEntity) -> ((SIMD2<Double>) -> Double)? {
        let corners: [SIMD2<Double>]
        switch entity {
        case let .circle(_, center, radius):
            return { p in radius - simd_length(p - center) }
        case let .rect(_, lo, hi):
            corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
        case let .polygon(_, center, radius, sides, rotation) where sides >= 3:
            corners = SketchEntity.polygonPoints(center: center, radius: radius,
                                                 sides: sides, rotation: rotation)
        default:
            return nil
        }
        // Convex: inside every edge. The distance to the nearest edge line,
        // signed by the winding so inside is positive.
        let winding: Double = Profile.signedArea(corners) < 0 ? -1 : 1
        return { p in
            var nearest = Double.infinity
            for i in corners.indices {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                let length = simd_length(b - a)
                guard length > 1e-12 else { continue }
                nearest = min(nearest, winding * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / length)
            }
            return nearest
        }
    }

    /// Points where two outline pieces meet (touching included).
    private static func crossings(_ p: CurvePiece, _ q: CurvePiece) -> [SIMD2<Double>] {
        switch (p, q) {
        case let (.segment(a, b), .segment(c, d)):
            return segmentSegmentPoint(a, b, c, d).map { [$0] } ?? []
        case let (.segment(a, b), .arc(arc)), let (.arc(arc), .segment(a, b)):
            return segmentCircleHits(a, b, center: arc.center, radius: arc.radius)
                .map { $0.point }
                .filter { arc.parameter(of: $0) != nil }
        case let (.arc(first), .arc(second)):
            return circleCircleHits(first.center, first.radius, second.center, second.radius)
                .filter { first.parameter(of: $0) != nil && second.parameter(of: $0) != nil }
        }
    }

    /// The point where segments ab and cd meet, ends included; nil when they
    /// don't meet or are parallel (collinear overlap is `lineLoops`' job).
    private static func segmentSegmentPoint(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>
    ) -> SIMD2<Double>? {
        let r = b - a, v = d - c
        let denominator = r.x * v.y - r.y * v.x
        guard abs(denominator) > 1e-12 * simd_length(r) * simd_length(v) else { return nil }
        let w = c - a
        let t = (w.x * v.y - w.y * v.x) / denominator
        let u = (w.x * r.y - w.y * r.x) / denominator
        guard t >= -1e-12, t <= 1 + 1e-12, u >= -1e-12, u <= 1 + 1e-12 else { return nil }
        return a + r * min(1, max(0, t))
    }

    /// Where segment ab meets the circle, with each point's fraction `t`
    /// along the segment (ends included; a tangent gives one point).
    private static func segmentCircleHits(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, center: SIMD2<Double>, radius: Double
    ) -> [(t: Double, point: SIMD2<Double>)] {
        let d = b - a, f = a - center
        let qa = simd_dot(d, d)
        guard qa > 1e-18 else { return [] }
        let qb = 2 * simd_dot(f, d)
        let qc = simd_dot(f, f) - radius * radius
        let discriminant = qb * qb - 4 * qa * qc
        let slack = 1e-12 * max(1, qb * qb)
        guard discriminant >= -slack else { return [] }
        let root = sqrt(max(0, discriminant))
        let ts = root <= 1e-9 * max(1, abs(qb)) ? [-qb / (2 * qa)]
            : [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)]
        return ts.compactMap { t in
            guard t >= -1e-12, t <= 1 + 1e-12 else { return nil }
            let clamped = min(1, max(0, t))
            return (clamped, a + d * clamped)
        }
    }

    /// Where two circles meet: none, one (tangent) or two points. Concentric
    /// circles (including a circle and itself) meet nowhere.
    private static func circleCircleHits(
        _ c1: SIMD2<Double>, _ r1: Double, _ c2: SIMD2<Double>, _ r2: Double
    ) -> [SIMD2<Double>] {
        let delta = c2 - c1
        let distance = simd_length(delta)
        guard distance > 1e-12 else { return [] }
        let slack = 1e-9 * max(1, r1 + r2)
        guard distance <= r1 + r2 + slack, distance >= abs(r1 - r2) - slack else { return [] }
        let along = (r1 * r1 - r2 * r2 + distance * distance) / (2 * distance)
        let height = sqrt(max(0, r1 * r1 - along * along))
        let base = c1 + delta * (along / distance)
        guard height > 1e-9 else { return [base] }
        let perpendicular = SIMD2(-delta.y, delta.x) / distance
        return [base + perpendicular * height, base - perpendicular * height]
    }
}

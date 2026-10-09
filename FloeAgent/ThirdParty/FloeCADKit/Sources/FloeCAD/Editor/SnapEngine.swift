//
//  SnapEngine.swift
//  openshape3d
//
//  Sketch-space snapping: existing endpoints/centers first, then the grid.
//

import Foundation
import simd

/// What a snap latched onto. Shapr3D names the snap on screen while you draw
/// ("Endpoint", "Midpoint", …), which is how you know the point you are about
/// to commit is the one you meant rather than a near miss.
nonisolated enum SnapKind: String, Sendable, Equatable, CaseIterable {
    case endpoint, midpoint, center, edge, grid, free

    /// User-facing name, or nil for snaps not worth announcing — the grid is
    /// too frequent to label on every stroke.
    var label: String? {
        switch self {
        case .endpoint: "Endpoint"
        case .midpoint: "Midpoint"
        case .center: "Center"
        case .edge: "Edge"
        case .grid, .free: nil
        }
    }
}

nonisolated struct SnapResult {
    var point: SIMD2<Double>
    var kind: SnapKind

    /// True when the point came from existing geometry rather than the grid.
    var snappedToPoint: Bool {
        switch kind {
        case .endpoint, .midpoint, .center, .edge: true
        case .grid, .free: false
        }
    }
}

/// One snappable point on existing geometry, with what it is.
nonisolated struct SnapCandidate {
    var point: SIMD2<Double>
    var kind: SnapKind
}

/// Acquisition preferences, independent of whether inferred constraints are stored.
nonisolated struct SnapOptions: Equatable, Sendable {
    var grid = true
    var sketchGuidepoints = true
    var faceGuidepoints = true
}

nonisolated enum SnapEngine {
    static let gridSpacing: Double = 0.5
    static let pointTolerance: Double = 0.35

    /// Viewport acquisition is screen-relative; the legacy default remains for
    /// geometry-only callers without a camera. This is a UI-point radius, not
    /// simulator screenshot pixels or model millimetres.
    static func screenPointTolerance(worldUnitsPerPoint: Double) -> Double {
        max(1e-9, worldUnitsPerPoint * 12)
    }

    /// Ranking when several candidates are in range. An endpoint is a harder
    /// commitment than a midpoint, and both beat a centre, so a tie near a
    /// corner resolves the way the user expects instead of by float noise.
    private static func priority(_ kind: SnapKind) -> Int {
        switch kind {
        case .endpoint: 4
        case .midpoint: 3
        case .center: 2
        // Sliding along an edge is the weakest commitment — any named point on
        // that edge should win a tie, or you could never land exactly on a
        // corner while tracing the boundary.
        case .edge: 1
        case .grid, .free: 0
        }
    }

    /// `faceLoops` are the boundary loops (outer + holes) of the solid face the
    /// sketch plane lies on, in sketch 2D coordinates. Sketching on a blank face
    /// otherwise has NOTHING to snap to but the grid, which is why a rectangle
    /// drawn on a face lands wherever the finger happened to be — off the edge,
    /// off centre. These give the face's own corners, edge midpoints, centre and
    /// edges the same status as existing sketch geometry.
    static func snap(
        _ p: SIMD2<Double>, in sketch: Sketch?, faceLoops: [[SIMD2<Double>]] = [],
        options: SnapOptions = .init(), tolerance: Double = pointTolerance
    ) -> SnapResult {
        var best: (candidate: SnapCandidate, distance: Double)?
        func consider(_ candidate: SnapCandidate) {
            let d = simd_length(candidate.point - p)
            guard d <= tolerance else { return }
            if let current = best {
                let better = priority(candidate.kind) > priority(current.candidate.kind)
                    || (priority(candidate.kind) == priority(current.candidate.kind)
                        && d < current.distance)
                if !better { return }
            }
            best = (candidate, d)
        }

        // 1. Existing sketch points and the underlying face compete together, so
        //    a face corner isn't shadowed by a farther sketch endpoint.
        if options.sketchGuidepoints, let sketch {
            for candidate in snapCandidates(of: sketch) { consider(candidate) }
        }
        if options.faceGuidepoints {
            for candidate in faceSnapCandidates(loops: faceLoops, near: p, grid: options.grid) {
                consider(candidate)
            }
        }
        if let best {
            return SnapResult(point: best.candidate.point, kind: best.candidate.kind)
        }

        guard options.grid else { return SnapResult(point: p, kind: .free) }

        // 2. Grid.
        let snapped = SIMD2(
            (p.x / gridSpacing).rounded() * gridSpacing,
            (p.y / gridSpacing).rounded() * gridSpacing
        )
        return SnapResult(point: snapped, kind: .grid)
    }

    /// Snappable points from the face's boundary: every corner, every edge
    /// midpoint, the centre of each loop, plus the closest point ON each edge
    /// (so you can slide along a boundary and stay exactly on it).
    static func faceSnapCandidates(
        loops: [[SIMD2<Double>]], near p: SIMD2<Double>, grid: Bool = true
    ) -> [SnapCandidate] {
        var out: [SnapCandidate] = []
        for loop in loops where loop.count >= 2 {
            var sum = SIMD2<Double>.zero
            for corner in loop {
                out.append(SnapCandidate(point: corner, kind: .endpoint))
                sum += corner
            }
            // Loop centre — the point you want when centring a cut on a face.
            if loop.count >= 3 {
                out.append(SnapCandidate(point: sum / Double(loop.count), kind: .center))
            }
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                out.append(SnapCandidate(point: (a + b) / 2, kind: .midpoint))
                if let onEdge = closestPointOnSegment(p, a, b) {
                    out.append(SnapCandidate(point: grid ? gridAlongEdge(onEdge, a, b) : onEdge, kind: .edge))
                }
            }
        }
        return out
    }

    /// The edge point moved to a grid step measured from the NEARER corner.
    /// A raw projection kept whatever along-edge coordinate the finger had
    /// (10.025 mm, not 10), so a rectangle ended on a face edge came out
    /// 0.25 % oversize while every other corner sat on the 0.5 mm grid. On a
    /// face whose corners are themselves off-grid this still gives whole
    /// steps from the corner, which is the dimension the user is after.
    static func gridAlongEdge(
        _ onEdge: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let ab = b - a
        let length = simd_length(ab)
        guard length > 1e-9 else { return onEdge }
        let dir = ab / length
        let s = min(max(simd_dot(onEdge - a, dir), 0), length)
        let snapped: Double
        if s <= length / 2 {
            snapped = (s / gridSpacing).rounded() * gridSpacing
        } else {
            snapped = length - ((length - s) / gridSpacing).rounded() * gridSpacing
        }
        return a + dir * min(max(snapped, 0), length)
    }

    /// Closest point to `p` on segment a→b, or nil if the segment is degenerate.
    private static func closestPointOnSegment(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> SIMD2<Double>? {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        guard len2 > 1e-12 else { return nil }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return a + ab * t
    }

    /// Every snappable point, untyped — kept for callers that only need
    /// positions (hit-testing, tests).
    static func snapPoints(of sketch: Sketch) -> [SIMD2<Double>] {
        snapCandidates(of: sketch).map(\.point)
    }

    /// Every snappable point with what it is.
    static func snapCandidates(of sketch: Sketch) -> [SnapCandidate] {
        var out: [SnapCandidate] = []
        func add(_ p: SIMD2<Double>, _ kind: SnapKind) {
            out.append(SnapCandidate(point: p, kind: kind))
        }
        for entity in sketch.entities {
            switch entity {
            case let .line(_, a, b):
                add(a, .endpoint)
                add(b, .endpoint)
                add((a + b) / 2, .midpoint)
            case let .rect(_, lo, hi):
                let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
                for corner in corners { add(corner, .endpoint) }
                // Edge midpoints: Shapr3D snaps to them, and centring geometry
                // on a face is the common reason to reach for one.
                for i in 0..<corners.count {
                    add((corners[i] + corners[(i + 1) % corners.count]) / 2, .midpoint)
                }
                add((lo + hi) / 2, .center)
            case let .circle(_, center, _):
                add(center, .center)
            case let .arc(_, center, radius, startAngle, endAngle):
                add(center, .center)
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle), .endpoint)
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle), .endpoint)
                let mid = startAngle + SketchEntity.arcSweep(
                    startAngle: startAngle, endAngle: endAngle) / 2
                add(SketchEntity.arcPoint(center: center, radius: radius, angle: mid), .midpoint)
            case let .ellipse(_, center, _, _, _):
                add(center, .center)
            case let .polygon(_, center, radius, sides, rotation):
                add(center, .center)
                for vertex in SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                ) { add(vertex, .endpoint) }
            case let .spline(_, splinePoints, _):
                // Snap to the FIT points the user placed, not the tessellation —
                // those are the notable points of a spline (spec §2.7).
                for point in splinePoints { add(point, .endpoint) }
            }
        }
        return out
    }
}

//
//  EdgeOffsetKit.swift
//  openshape3d
//
//  Spec §4.13 Offset Edge (3D). Pick edges on a body's planar face, set a
//  distance, and get SKETCH geometry on that face's plane — the standard way to
//  derive a gasket outline, a clearance boundary, or a toolpath from an existing
//  solid without re-drawing it.
//
//  The offset itself is 2D: a planar face already carries its boundary in plane
//  coordinates, so this flattens the selection into that basis, hands it to the
//  same `SketchOffset` the sketch tool uses (identical mitre / collapse rules),
//  and hands back a `SketchPlane` the caller can host the result on.
//

import Foundation
import simd

nonisolated enum EdgeOffsetKit {

    /// Spec's Single | Chain selector.
    nonisolated enum Mode: String, Codable, Sendable {
        /// Offset only the picked segments, as an open polyline.
        case single
        /// Offset the face's whole outer boundary, as a closed loop.
        case chain
    }

    /// Sketch geometry produced by an offset, plus the plane it belongs on.
    nonisolated struct Result: Sendable {
        var plane: SketchPlane
        var entities: [SketchEntity]
    }

    /// The sketch plane a face's offset output is hosted on: the face's own
    /// plane, so the generated entities line up with the face they came from.
    static func plane(of face: PlanarFace) -> SketchPlane {
        SketchPlane(origin: face.origin, xAxis: face.basisX, yAxis: face.basisY)
    }

    /// Offset edges of `face` by `distance`, in the body's LOCAL space.
    ///
    /// `pickedPoints` are points near the edges the user tapped (local space);
    /// each snaps to the nearest boundary segment. In `.chain` mode the picks
    /// only identify the face — the entire outer loop is offset, which is what
    /// the spec's Chain means for a closed boundary.
    ///
    /// Sign follows `SketchOffset`: on a CCW outline positive grows outward,
    /// negative inward. Returns nil when nothing survives (an inward offset can
    /// legitimately consume the whole face).
    static func offset(
        face: PlanarFace, pickedPoints: [SIMD3<Double>],
        distance: Double, mode: Mode
    ) -> Result? {
        guard face.outline.count >= 2, abs(distance) > 1e-9 else { return nil }
        let hostPlane = plane(of: face)

        let source: [SketchEntity]
        switch mode {
        case .chain:
            source = loopEntities(face.outline)
        case .single:
            let picks = pickedPoints.map { hostPlane.toLocal($0) }
            let segments = nearestSegments(to: picks, in: face.outline)
            guard !segments.isEmpty else { return nil }
            source = segments.map { .line(id: UUID(), a: $0.a, b: $0.b) }
        }

        let entities = SketchOffset.offset(entities: source, by: distance)
        guard !entities.isEmpty else { return nil }
        return Result(plane: hostPlane, entities: entities)
    }

    // MARK: - Helpers

    /// The closed outline as line entities, last point joined back to the first.
    private static func loopEntities(_ outline: [SIMD2<Double>]) -> [SketchEntity] {
        (0..<outline.count).map { i in
            .line(id: UUID(), a: outline[i], b: outline[(i + 1) % outline.count])
        }
    }

    /// One boundary segment per pick, de-duplicated and kept in outline order so
    /// adjacent picks form a connected chain rather than a scattered set.
    private static func nearestSegments(
        to picks: [SIMD2<Double>], in outline: [SIMD2<Double>]
    ) -> [(a: SIMD2<Double>, b: SIMD2<Double>)] {
        var indices = Set<Int>()
        for pick in picks {
            var best: (d: Double, i: Int)?
            for i in 0..<outline.count {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                let d = distance(from: pick, toSegment: a, b)
                if best == nil || d < best!.d { best = (d, i) }
            }
            if let best { indices.insert(best.i) }
        }
        return indices.sorted().map { (outline[$0], outline[($0 + 1) % outline.count]) }
    }

    private static func distance(
        from p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> Double {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-18 else { return simd_length(p - a) }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return simd_length(p - (a + ab * t))
    }
}

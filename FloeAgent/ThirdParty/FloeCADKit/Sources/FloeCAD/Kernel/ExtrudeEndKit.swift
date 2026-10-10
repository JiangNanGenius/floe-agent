//
//  ExtrudeEndKit.swift
//  openshape3d
//
//  Extrude END CONDITIONS beyond a typed distance — SOLIDWORKS' "Through
//  All" and "Up To Next", which every rib and most through-cuts are drawn
//  with. The app's extrude node stays a distance; this kit turns an end
//  condition into that distance at commit time from the bodies in the
//  document, so the History row keeps a plain editable number and nothing
//  downstream changes. (A live, re-evaluating end condition is a later
//  step; this closes the gap where a person had to measure the part by
//  hand and type the answer.)
//
//  Geometry is read from the bodies' RENDER meshes in world space: planar
//  faces are exact there, curved faces carry the tessellation's chord
//  error (well under 0.1 mm at the app's default density), which is the
//  right precision for a distance a person then sees in the field.
//

import Foundation
import simd

nonisolated enum ExtrudeEnd: String, Codable, CaseIterable, Sendable {
    case blind
    case throughAll
    case upToNext

    var title: String {
        switch self {
        case .blind: "Blind"
        case .throughAll: "Through All"
        case .upToNext: "Up To Next"
        }
    }
}

nonisolated enum ExtrudeEndKit {

    /// Margin past the farthest face for Through All, so the cut clears
    /// the body instead of leaving a coincident skin.
    static let throughAllMargin = 1.0

    /// Faces closer than this along the ray are the face the sketch sits
    /// on (or its tessellation), not the "next" one.
    static let upToNextSkip = 1e-3

    /// Möller–Trumbore ray/triangle intersection. Returns the ray
    /// parameter t (distance for a unit direction) or nil for a miss.
    static func rayTriangle(origin o: SIMD3<Double>, direction d: SIMD3<Double>,
                            a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) -> Double? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        if u < -1e-9 || u > 1 + 1e-9 { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        if v < -1e-9 || u + v > 1 + 1e-9 { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 0 ? t : nil
    }

    /// World-space triangles of a body (its placement applied).
    static func worldTriangles(of body: Body) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
        let mesh = body.render
        let pts = mesh.positions.map { body.transform.applying(to: SIMD3(Double($0.x), Double($0.y), Double($0.z))) }
        var out: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        out.reserveCapacity(mesh.triangleCount)
        var i = 0
        while i + 2 < mesh.indices.count {
            out.append((pts[Int(mesh.indices[i])], pts[Int(mesh.indices[i + 1])], pts[Int(mesh.indices[i + 2])]))
            i += 3
        }
        return out
    }

    /// Nearest face hit along `direction` from `origin`, ignoring hits
    /// within `skip` (the sketch's own face). nil when nothing is ahead.
    static func firstHit(bodies: [Body], origin: SIMD3<Double>, direction: SIMD3<Double>,
                         skip: Double = upToNextSkip) -> Double? {
        let d = simd_normalize(direction)
        var best: Double?
        for body in bodies {
            for (a, b, c) in worldTriangles(of: body) {
                if let t = rayTriangle(origin: origin, direction: d, a: a, b: b, c: c), t > skip {
                    if best == nil || t < best! { best = t }
                }
            }
        }
        return best
    }

    /// How far the bodies reach along `direction` from `origin` (the
    /// farthest vertex projection); nil when there are no bodies.
    static func extent(bodies: [Body], origin: SIMD3<Double>, direction: SIMD3<Double>) -> Double? {
        let d = simd_normalize(direction)
        var best: Double?
        for body in bodies {
            for p in body.render.positions {
                let w = body.transform.applying(to: SIMD3(Double(p.x), Double(p.y), Double(p.z)))
                let t = simd_dot(w - origin, d)
                if best == nil || t > best! { best = t }
            }
        }
        return best
    }

    /// The distance an end condition stands for, or nil when the document
    /// gives it nothing to end at (no bodies ahead). `plane` is the sketch
    /// plane, `seed` a sketch-local point inside the profile (the ray for
    /// Up To Next starts there), `direction` the extrude direction in
    /// world space (the plane normal or its opposite), `symmetric` makes
    /// Through All reach the farther side in both directions.
    static func resolve(_ end: ExtrudeEnd, plane: SketchPlane, seed: SIMD2<Double>,
                        direction: SIMD3<Double>, symmetric: Bool, bodies: [Body]) -> Double? {
        let start = plane.toWorld(seed)
        let d = simd_normalize(direction)
        switch end {
        case .blind:
            return nil
        case .throughAll:
            guard let ahead = extent(bodies: bodies, origin: start, direction: d) else { return nil }
            if symmetric {
                guard let behind = extent(bodies: bodies, origin: start, direction: -d) else { return nil }
                return max(ahead, behind) + throughAllMargin
            }
            return max(ahead, 0) + throughAllMargin
        case .upToNext:
            return firstHit(bodies: bodies, origin: start, direction: d)
        }
    }
}

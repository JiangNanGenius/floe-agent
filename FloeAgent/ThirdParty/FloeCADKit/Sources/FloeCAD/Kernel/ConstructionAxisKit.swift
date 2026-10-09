//
//  ConstructionAxisKit.swift
//  openshape3d
//
//  Spec §6.2 (Construction axis) — the geometry half. The corpus documents five
//  ways to define an axis; this derives all five as pure values so the document
//  entity, History parameters and UI can be layered on without re-deriving math.
//
//  Axes feed Revolve (§4.10), circular patterns (§5.7) and transforms (§5.3),
//  which today can only revolve/rotate about a sketch line or an explicit axis.
//

import Foundation
import simd

nonisolated struct ConstructionAxisID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

/// An infinite construction axis: a point plus a unit direction. `length` is the
/// display extent (the History parameter the spec calls "Length"); it never
/// affects the math.
///
/// Unlike planes — where `ConstructionPlane` wraps a separate `SketchPlane`
/// because sketching needs the geometry on its own — the axis geometry has no
/// second consumer, so identity lives directly on this type rather than in a
/// wrapper. The kit's constructors mint a fresh `id` for every axis they build.
nonisolated struct ConstructionAxis: Identifiable, Codable, Equatable, Sendable {
    let id: ConstructionAxisID
    var origin: SIMD3<Double>
    /// Always unit length.
    var direction: SIMD3<Double>
    var length: Double = 100
    /// Items Manager display name (spec §11); defaulted on decode so a
    /// document written before axes existed still loads.
    var name: String
    /// Items Manager visibility (spec §11).
    var isHidden: Bool

    /// Nil when `direction` is degenerate — callers surface "can't build an axis
    /// from this selection" rather than propagating NaNs.
    init?(
        id: ConstructionAxisID = ConstructionAxisID(),
        origin: SIMD3<Double>,
        direction: SIMD3<Double>,
        length: Double = 100,
        name: String = "Axis",
        isHidden: Bool = false
    ) {
        let n = simd_length(direction)
        guard n > 1e-9, n.isFinite else { return nil }
        // A non-finite origin or length would poison every downstream
        // projection the same way a NaN direction would.
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              length.isFinite, length > 0
        else { return nil }
        self.id = id
        self.origin = origin
        self.direction = direction / n
        self.length = length
        self.name = name
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, origin, direction, length, name, isHidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ConstructionAxisID.self, forKey: .id)
        origin = try c.decode(SIMD3<Double>.self, forKey: .origin)
        direction = try c.decode(SIMD3<Double>.self, forKey: .direction)
        length = try c.decode(Double.self, forKey: .length)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Axis"
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    /// The drawn segment, centred on `origin`.
    var endpoints: (start: SIMD3<Double>, end: SIMD3<Double>) {
        let half = direction * (length / 2)
        return (origin - half, origin + half)
    }

    /// Closest point on the axis to `p` — the basis for snapping and for
    /// measuring a revolve radius.
    func closestPoint(to p: SIMD3<Double>) -> SIMD3<Double> {
        origin + direction * simd_dot(p - origin, direction)
    }

    func distance(to p: SIMD3<Double>) -> Double {
        simd_length(p - closestPoint(to: p))
    }
}

nonisolated enum ConstructionAxisKit {

    /// **Axis Through 2 Points** — nil if the points coincide.
    static func through(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> ConstructionAxis? {
        ConstructionAxis(origin: a, direction: b - a,
                         length: max(simd_length(b - a), 1e-6))
    }

    /// **Axis Along Edge** — same as two points, but sized to the edge and
    /// centred on it so the drawn axis straddles the edge.
    static func alongEdge(start: SIMD3<Double>, end: SIMD3<Double>) -> ConstructionAxis? {
        let mid = (start + end) / 2
        return ConstructionAxis(origin: mid, direction: end - start,
                                length: max(simd_length(end - start), 1e-6))
    }

    /// **Axis Perpendicular to Face at Point** — the face normal through `point`.
    static func perpendicular(
        toFaceNormal normal: SIMD3<Double>, at point: SIMD3<Double>
    ) -> ConstructionAxis? {
        ConstructionAxis(origin: point, direction: normal)
    }

    /// **Axis Through 2 Planes** — the intersection line of two planes, each
    /// given as a point + normal. Nil when the planes are parallel (no unique
    /// line), which is the case the UI must report rather than silently fail.
    static func intersection(
        planeAOrigin: SIMD3<Double>, planeANormal: SIMD3<Double>,
        planeBOrigin: SIMD3<Double>, planeBNormal: SIMD3<Double>
    ) -> ConstructionAxis? {
        let nA = simd_normalize(planeANormal)
        let nB = simd_normalize(planeBNormal)
        let dir = simd_cross(nA, nB)
        guard simd_length(dir) > 1e-9 else { return nil }  // parallel planes

        // A point on both planes: solve the 2x2 system in the plane spanned by
        // the two normals (standard plane-plane intersection).
        let dA = simd_dot(nA, planeAOrigin)
        let dB = simd_dot(nB, planeBOrigin)
        let nAnB = simd_dot(nA, nB)
        let det = 1 - nAnB * nAnB
        guard abs(det) > 1e-12 else { return nil }
        let c1 = (dA - dB * nAnB) / det
        let c2 = (dB - dA * nAnB) / det
        return ConstructionAxis(origin: nA * c1 + nB * c2, direction: dir)
    }

    /// **Axis of Cylinder/Cone** fitted from a set of points known to lie on a
    /// surface of revolution, plus the outward normals at those points.
    ///
    /// The normals of a cylinder/cone are all perpendicular to the axis, so the
    /// axis direction is the null direction of the normal set: the eigenvector
    /// of `Σ nᵢnᵢᵀ` with the smallest eigenvalue. Solved here by testing the
    /// candidate directions from pairwise cross products and keeping whichever
    /// is most perpendicular to every normal — cheap, allocation-free, and
    /// robust for the handful of samples a picked face provides.
    ///
    /// Nil when the samples don't determine an axis (all normals parallel — a
    /// planar face, not a cylinder).
    static func axisOfRevolution(
        points: [SIMD3<Double>], normals: [SIMD3<Double>]
    ) -> ConstructionAxis? {
        guard points.count >= 3, points.count == normals.count else { return nil }
        let unit = normals.compactMap { n -> SIMD3<Double>? in
            let l = simd_length(n)
            return l > 1e-9 ? n / l : nil
        }
        guard unit.count >= 3 else { return nil }

        var best: SIMD3<Double>?
        var bestScore = Double.greatestFiniteMagnitude
        for i in 0..<unit.count {
            for j in (i + 1)..<unit.count {
                let c = simd_cross(unit[i], unit[j])
                let len = simd_length(c)
                guard len > 1e-6 else { continue }   // parallel normals
                let dir = c / len
                // Perfect axis ⇒ every normal is perpendicular to it.
                let score = unit.reduce(0.0) { $0 + abs(simd_dot($1, dir)) }
                if score < bestScore { bestScore = score; best = dir }
            }
        }
        guard let direction = best,
              bestScore / Double(unit.count) < 0.1 else { return nil }

        // Axis POSITION. Work in the plane perpendicular to the axis, where the
        // face is a circle: the centre `c` lies along every point's normal, i.e.
        //   cross(nᵢ, c − pᵢ) = 0  ⇒  nᵢ.x·(c.y − pᵢ.y) − nᵢ.y·(c.x − pᵢ.x) = 0
        // Two unknowns, one linear equation per sample → least squares.
        let u = Self.anyPerpendicular(to: direction)
        let v = simd_cross(direction, u)
        func project(_ p: SIMD3<Double>) -> SIMD2<Double> {
            SIMD2(simd_dot(p, u), simd_dot(p, v))
        }

        var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
        for (p3, n3) in zip(points, unit) {
            let p = project(p3)
            var n = project(n3)
            let l = simd_length(n)
            guard l > 1e-9 else { continue }
            n /= l
            // Row (−n.y, n.x) · c = (−n.y, n.x) · p
            let rx = -n.y, ry = n.x
            let rhs = rx * p.x + ry * p.y
            a11 += rx * rx; a12 += rx * ry; a22 += ry * ry
            b1 += rx * rhs; b2 += ry * rhs
        }
        let det = a11 * a22 - a12 * a12
        guard abs(det) > 1e-12 else { return nil }
        let c = SIMD2((b1 * a22 - b2 * a12) / det, (a11 * b2 - a12 * b1) / det)

        // Lift the 2-D centre back to 3-D, keeping the samples' mean height so
        // the drawn axis sits on the face rather than at the world origin.
        let meanHeight = points.reduce(0.0) { $0 + simd_dot($1, direction) } / Double(points.count)
        let origin = u * c.x + v * c.y + direction * meanHeight
        return ConstructionAxis(origin: origin, direction: direction)
    }

    /// Any unit vector perpendicular to `d` (picks the smallest component to
    /// stay numerically stable).
    private static func anyPerpendicular(to d: SIMD3<Double>) -> SIMD3<Double> {
        let a = abs(d.x) < abs(d.y)
            ? (abs(d.x) < abs(d.z) ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1))
            : (abs(d.y) < abs(d.z) ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(0, 0, 1))
        return simd_normalize(simd_cross(d, a))
    }
}

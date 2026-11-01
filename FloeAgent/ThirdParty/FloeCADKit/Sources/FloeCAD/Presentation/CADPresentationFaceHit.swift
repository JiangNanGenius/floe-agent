//
//  CADPresentationFaceHit.swift
//  FloeCADKit
//
//  Value-only refinement from a real Present collision hit to the live face
//  triangles. RealityKit's CollisionCastHit exposes a position/entity/normal,
//  not a triangle index, so the hit point is correlated with the body's actual
//  render buffer under the hit entity. The document's face table for the same
//  mesh revision is the first authority; connected topology is the measured
//  fallback. Nothing here creates a second selection, face id or geometry
//  store, and nothing mutates the document.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import simd

/// Present tap granularity. This is not a filter over the current selection:
/// changing it never edits the document or clears an existing target.
nonisolated enum CADPresentationSelectionMode: String, CaseIterable, Identifiable, Sendable {
    case body
    case face

    var id: String { rawValue }

    var title: String {
        switch self {
        case .body:
            return FloeCADStrings.text("cad.present.selection.body", "Body")
        case .face:
            return FloeCADStrings.text("cad.present.selection.face", "Face")
        }
    }

    var symbolName: String {
        switch self {
        case .body: return "cube"
        case .face: return "square.on.square"
        }
    }
}

/// The exact render region a genuine Present hit resolved to. `triangles` are
/// ordinals into the live body's `RenderMesh`, which is the same ordered
/// buffer the presentation mesh was built from.
nonisolated struct CADPresentationFaceRegion: Equatable, Sendable {
    var triangles: [Int]
    /// The region is one smooth curved surface rather than one plane.
    var curved: Bool
    /// True only when the range came from the session's authoritative face
    /// table for this exact mesh revision. Topology fallbacks still name
    /// measured triangles, but not a kernel face identity.
    var authoritative: Bool
}

nonisolated enum CADPresentationFaceHit {
    /// Collision coordinates are floats in millimetres here. The tolerance is
    /// deliberately far below a visible feature: only a tap exactly on a
    /// shared edge/vertex can admit more than one candidate triangle.
    static func tolerance(diagonalMM: Float) -> Float {
        guard diagonalMM.isFinite, diagonalMM > 0 else { return 0.01 }
        // 0.1 mm remains far below a visible feature even for a large model,
        // while leaving room for the float precision of a metre-space
        // RealityKit hit converted back into a millimetre body buffer.
        return min(max(diagonalMM * 1e-5, 1e-4), 0.1)
    }

    /// Resolve a body-local hit point (millimetres) to exactly one face
    /// region. Nil means the point is not on this surface, or two distinct
    /// faces meet exactly at the hit; callers select the whole body instead
    /// of guessing between them.
    static func resolve(mesh: RenderMesh,
                        meshRevision: UInt64,
                        point: SIMD3<Float>,
                        tolerance: Float,
                        faceTable: FaceTable?,
                        faceTableRevision: UInt64?) -> CADPresentationFaceRegion? {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        let seeds = nearestTriangles(in: mesh, at: point, tolerance: tolerance)
        guard !seeds.isEmpty else { return nil }
        var regions: [CADPresentationFaceRegion] = []
        for seed in seeds {
            if Task.isCancelled { return nil }
            guard let region = region(in: mesh, seed: seed,
                                      meshRevision: meshRevision,
                                      faceTable: faceTable,
                                      faceTableRevision: faceTableRevision) else { continue }
            if !regions.contains(where: { $0.triangles == region.triangles }) {
                regions.append(region)
            }
        }
        // Several candidate triangles on the same planar face or smooth region
        // are one face. Two different regions are a real ambiguous edge.
        return regions.count == 1 ? regions[0] : nil
    }

    /// The live face table is the first authority. Only when it has no single
    /// entry for this mesh generation do we measure connected topology. This
    /// mirrors the editor and the material inspector; a prior material face
    /// group or its display name is never consulted.
    static func region(in mesh: RenderMesh,
                       seed: Int,
                       meshRevision: UInt64,
                       faceTable: FaceTable?,
                       faceTableRevision: UInt64?) -> CADPresentationFaceRegion? {
        guard seed >= 0, seed < mesh.triangleCount else { return nil }

        if let faceTable, faceTableRevision == meshRevision {
            var matched: FaceTable.Entry?
            for entry in faceTable.entries where entry.triangles.contains(seed) {
                if matched != nil {
                    // Overlapping table ranges cannot name one authoritative
                    // face; keep looking at measured topology instead.
                    matched = nil
                    break
                }
                matched = entry
            }
            if let entry = matched, !entry.triangles.isEmpty,
               entry.triangles.allSatisfy({ $0 >= 0 && $0 < mesh.triangleCount }) {
                return CADPresentationFaceRegion(
                    triangles: entry.triangles.sorted(),
                    curved: !isPlanar(entry.signature),
                    authoritative: true)
            }
        }

        let smooth = FaceTopology.smoothRegion(in: mesh, seedTriangle: seed)
        if let smooth, smooth.isCurved {
            return CADPresentationFaceRegion(triangles: smooth.triangles,
                                             curved: true,
                                             authoritative: false)
        }
        if let planar = FaceTopology.planarFace(in: mesh, seedTriangle: seed) {
            return CADPresentationFaceRegion(triangles: planar.triangles,
                                             curved: false,
                                             authoritative: false)
        }
        if let smooth {
            return CADPresentationFaceRegion(triangles: smooth.triangles,
                                             curved: false,
                                             authoritative: false)
        }
        return nil
    }

    private static func isPlanar(_ signature: FaceSignature) -> Bool {
        if case .planar = signature.kind { return true }
        return false
    }

    /// Triangles whose actual surface is closest to the point. The AABB test
    /// is only a cheap per-triangle rejection; the distance uses the exact
    /// triangle, so a bore or concave pocket cannot select empty space.
    static func nearestTriangles(in mesh: RenderMesh, at point: SIMD3<Float>,
                                 tolerance: Float) -> [Int] {
        let positions = mesh.positions
        let indices = mesh.indices
        guard !positions.isEmpty, indices.count >= 3 else { return [] }
        let padding = SIMD3<Float>(repeating: max(tolerance, 0))
        let limit = max(tolerance, 0) * max(tolerance, 0)
        var best = Float.greatestFiniteMagnitude
        var seeds: [Int] = []

        for triangle in 0..<mesh.triangleCount {
            if triangle % 4096 == 0, Task.isCancelled { return [] }
            let base = triangle * 3
            guard base + 2 < indices.count else { continue }
            let i0 = Int(indices[base])
            let i1 = Int(indices[base + 1])
            let i2 = Int(indices[base + 2])
            guard i0 < positions.count, i1 < positions.count,
                  i2 < positions.count else { continue }
            let a = positions[i0]
            let b = positions[i1]
            let c = positions[i2]
            let lo = simd_min(a, simd_min(b, c)) - padding
            let hi = simd_max(a, simd_max(b, c)) + padding
            if point.x < lo.x || point.y < lo.y || point.z < lo.z
                || point.x > hi.x || point.y > hi.y || point.z > hi.z {
                continue
            }
            let closest = closestPoint(on: point, a, b, c)
            let distance = simd_length_squared(closest - point)
            guard distance.isFinite else { continue }
            if distance < best - 1e-12 {
                best = distance
                seeds = [triangle]
            } else if distance <= min(limit, best + limit) {
                seeds.append(triangle)
            }
        }
        // A point that is not actually on this surface must not resolve to
        // whichever triangle merely sat in its padded AABB.
        guard best <= limit else { return [] }
        return seeds
    }

    /// Closest point on a triangle (Ericson, Real-Time Collision Detection).
    /// Degenerate triangles fall back to their nearest endpoint rather than
    /// dividing by zero.
    static func closestPoint(on point: SIMD3<Float>,
                             _ a: SIMD3<Float>,
                             _ b: SIMD3<Float>,
                             _ c: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return a }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let denominator = d1 - d3
            guard abs(denominator) > 1e-20 else { return a }
            return a + ab * (d1 / denominator)
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let denominator = d2 - d6
            guard abs(denominator) > 1e-20 else { return a }
            return a + ac * (d2 / denominator)
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let denominator = (d4 - d3) + (d5 - d6)
            guard abs(denominator) > 1e-20 else { return b }
            return b + (c - b) * ((d4 - d3) / denominator)
        }

        let denominator = va + vb + vc
        guard abs(denominator) > 1e-20 else {
            let da = simd_length_squared(point - a)
            let db = simd_length_squared(point - b)
            let dc = simd_length_squared(point - c)
            if da <= db, da <= dc { return a }
            return db <= dc ? b : c
        }
        let v = vb / denominator
        let w = vc / denominator
        return a + ab * v + ac * w
    }

    /// Area-weighted normal of a measured region, used only to lift the
    /// render-only selection patch a tiny amount off its coincident body
    /// surface. It never decides which face is selected.
    static func averageNormal(in mesh: CADPresentationMesh,
                              triangles: [Int]) -> SIMD3<Float> {
        let positions = mesh.positions
        let indices = mesh.indices
        var normal = SIMD3<Float>.zero
        for triangle in triangles {
            guard triangle >= 0, triangle * 3 + 2 < indices.count else { continue }
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count,
                  i2 < positions.count else { continue }
            let cross = simd_cross(positions[i1] - positions[i0],
                                   positions[i2] - positions[i0])
            if cross.x.isFinite, cross.y.isFinite, cross.z.isFinite {
                normal += cross
            }
        }
        let length = simd_length(normal)
        return length > 1e-12 ? normal / length : SIMD3<Float>(0, 1, 0)
    }
}
#endif

//
//  FeatureEdges.swift
//  openshape3d
//
//  Extracts CAD-style feature edges from a triangle mesh: edges whose two
//  adjacent faces meet at more than a threshold dihedral angle (plus any
//  boundary edges, defensively — solids shouldn't have them).
//

import Foundation
import simd

nonisolated enum FeatureEdgeExtractor {
    /// Position welding quantum. Coarser than render welding — here we only
    /// care about topology, not normals.
    private static let quantum: Float = 1e-5

    private struct PositionKey: Hashable {
        let x, y, z: Int64
        init(_ p: SIMD3<Float>) {
            let inv = 1 / FeatureEdgeExtractor.quantum
            // key64: a raw Int32/Int64(_: Float) traps on NaN, and an Int32
            // key at this quantum saturates at ±21 m — which silently WELDED
            // far-apart vertices together instead. Int64 + NaN guard.
            x = MeshQuantize.key64(p.x, inverseQuantum: inv)
            y = MeshQuantize.key64(p.y, inverseQuantum: inv)
            z = MeshQuantize.key64(p.z, inverseQuantum: inv)
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: Int
        init(_ i: Int, _ j: Int) {
            if i < j { a = i; b = j } else { a = j; b = i }
        }
    }

    static func edges(from mesh: RenderMesh, angleThresholdDegrees: Float = 20) -> FeatureEdgeSet {
        guard mesh.triangleCount > 0 else { return FeatureEdgeSet(segments: []) }

        // 1. Weld positions into topological vertex IDs (render vertices are
        //    split along hard edges, which would hide adjacency).
        var topoID = [Int](repeating: 0, count: mesh.positions.count)
        var lookup = [PositionKey: Int]()
        var topoPositions = [SIMD3<Float>]()
        for (i, p) in mesh.positions.enumerated() {
            let key = PositionKey(p)
            if let existing = lookup[key] {
                topoID[i] = existing
            } else {
                let id = topoPositions.count
                lookup[key] = id
                topoPositions.append(p)
                topoID[i] = id
            }
        }

        // 2. Map each undirected edge to its adjacent face normals.
        var edgeFaces = [EdgeKey: [SIMD3<Float>]]()
        var triangle = 0
        while triangle < mesh.triangleCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            triangle += 1

            let p0 = mesh.positions[i0]
            let p1 = mesh.positions[i1]
            let p2 = mesh.positions[i2]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(cross)
            guard area > 1e-12 else { continue } // skip degenerate slivers
            let normal = cross / area

            let t0 = topoID[i0]
            let t1 = topoID[i1]
            let t2 = topoID[i2]
            guard t0 != t1, t1 != t2, t2 != t0 else { continue }
            edgeFaces[EdgeKey(t0, t1), default: []].append(normal)
            edgeFaces[EdgeKey(t1, t2), default: []].append(normal)
            edgeFaces[EdgeKey(t2, t0), default: []].append(normal)
        }

        // 3. Emit feature edges. Coplanar triangulation diagonals (dot ≈ 1)
        //    stay hidden; creases and boundaries show.
        let cosThreshold = cos(angleThresholdDegrees * .pi / 180)
        var segments = [SIMD3<Float>]()
        for (edge, normals) in edgeFaces {
            let isFeature: Bool
            switch normals.count {
            case 1:
                isFeature = true // boundary edge
            case 2:
                isFeature = simd_dot(normals[0], normals[1]) < cosThreshold
            default:
                isFeature = true // non-manifold — always show
            }
            if isFeature {
                segments.append(topoPositions[edge.a])
                segments.append(topoPositions[edge.b])
            }
        }
        return FeatureEdgeSet(segments: segments)
    }
}

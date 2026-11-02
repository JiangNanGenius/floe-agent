// SPDX-License-Identifier: MPL-2.0
// Inspection of actual simplification output. Distances use the body's scale;
// sampling and conservative bounds are labelled separately, never exact CAD.
import Foundation
import simd

nonisolated enum CADMeshSimplificationQuality {
    struct Position: Hashable {
        let x, y, z: Float
        init(_ p: SIMD3<Float>) { x = p.x; y = p.y; z = p.z }
    }
    struct Edge: Hashable {
        let a, b: Position
        init(_ a: Position, _ b: Position) {
            if (a.x, a.y, a.z) < (b.x, b.y, b.z) { self.a = a; self.b = b }
            else { self.a = b; self.b = a }
        }
    }
    struct Protection: Sendable {
        let vertices: Set<Int>
        let boundaryEdges: [(SIMD3<Float>, SIMD3<Float>)]
        let eulerCharacteristic: Int
    }
    struct Report: Sendable {
        let sampledDistanceMM: Double
        let distanceUpperBoundMM: Double
        let sampledTriangles, totalTriangles: Int
        let boundaryDistanceMM: Double?
        let signedVolumeBeforeMM3: Double
        let signedVolumeAfterMM3: Double
        let closedOrientedVolumes: Bool
        let topologyPreserved: Bool
        let boundaryEdgesBefore, boundaryEdgesAfter: Int
        let eulerBefore, eulerAfter: Int
        let appearancePreserved: Bool
        let protectedVertices: Int

        var payload: [String: Any] {
            var p: [String: Any] = [
                "surfaceSampledMaxDistanceMM": sampledDistanceMM,
                "surfaceDistanceUpperBoundMM": distanceUpperBoundMM,
                "distanceMethod": "bidirectional_deterministic_triangle_samples_vertices_edge_midpoints_centroids",
                "sampledTriangleCount": sampledTriangles,
                "totalTriangleCount": totalTriangles,
                "distanceIsExactHausdorff": false,
                "upperBoundMethod": "sample_centroid_distance_plus_complete_triangle_block_cover_radius",
                "signedVolumeBeforeMM3": signedVolumeBeforeMM3,
                "signedVolumeAfterMM3": signedVolumeAfterMM3,
                "signedVolumeDeltaMM3": signedVolumeAfterMM3 - signedVolumeBeforeMM3,
                "closedOrientedVolumes": closedOrientedVolumes,
                "volumeIsValidatedSolid": false,
                "topologyPreserved": topologyPreserved,
                "boundaryEdgeCountBefore": boundaryEdgesBefore,
                "boundaryEdgeCountAfter": boundaryEdgesAfter,
                "eulerCharacteristicBefore": eulerBefore,
                "eulerCharacteristicAfter": eulerAfter,
                "uvAndHardEdgeSeamsPreserved": appearancePreserved,
                "protectedVertexCount": protectedVertices,
            ]
            if let boundaryDistanceMM {
                p["boundarySampledMaxDistanceMM"] = boundaryDistanceMM
                p["boundaryDistanceMethod"] = "bidirectional_endpoints_and_midpoints_to_segments"
            } else { p["boundaryDistanceUnavailable"] = "a boundary was created or removed" }
            return p
        }
    }

    /// Preserve real open boundaries and coincident vertices with distinct
    /// normals/UVs. Interior smooth vertices remain eligible for clustering.
    static func protection(_ mesh: RenderMesh, shouldStop: () -> Bool) -> Protection? {
        var attributes: [Position: (SIMD3<Float>, SIMD2<Float>?)] = [:]
        var seams: Set<Position> = []
        for i in mesh.positions.indices {
            if shouldStop() { return nil }
            let p = Position(mesh.positions[i]), n = mesh.normals[i], uv = mesh.texcoords?[i]
            if let previous = attributes[p] {
                if previous.0 != n || previous.1 != uv { seams.insert(p) }
            } else { attributes[p] = (n, uv) }
        }
        var edges: [Edge: Int] = [:]
        var usedPositions: Set<Position> = []
        for t in 0..<mesh.triangleCount {
            if shouldStop() { return nil }
            let a = Position(mesh.positions[Int(mesh.indices[t * 3])])
            let b = Position(mesh.positions[Int(mesh.indices[t * 3 + 1])])
            let c = Position(mesh.positions[Int(mesh.indices[t * 3 + 2])])
            usedPositions.formUnion([a,b,c])
            for (u, v) in [(a,b),(b,c),(c,a)] where u != v { edges[Edge(u,v), default: 0] += 1 }
        }
        var boundary: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (edge, count) in edges {
            if shouldStop() { return nil }
            if count != 2 { seams.insert(edge.a); seams.insert(edge.b) }
            if count == 1 {
                boundary.append((SIMD3(edge.a.x,edge.a.y,edge.a.z), SIMD3(edge.b.x,edge.b.y,edge.b.z)))
            }
        }
        var vertices: Set<Int> = []
        for i in mesh.positions.indices {
            if shouldStop() { return nil }
            if seams.contains(Position(mesh.positions[i])) { vertices.insert(i) }
        }
        return Protection(vertices: vertices, boundaryEdges: boundary,
                          eulerCharacteristic: usedPositions.count - edges.count + mesh.triangleCount)
    }

    static func inspect(before: RenderMesh, after: RenderMesh, protection: Protection, scale: Double = 1,
                        sampleTriangleBudget: Int = 4096,
                        shouldStop: () -> Bool) -> Report? {
        let a = CADInterferenceMeshGeometry.build(positions: before.positions, indices: before.indices)
        let b = CADInterferenceMeshGeometry.build(positions: after.positions, indices: after.indices)
        guard scale.isFinite, scale > 0, sampleTriangleBudget > 0, a.isValid, b.isValid, !shouldStop(),
              let ab = directed(a, b, sampleBudget:sampleTriangleBudget, shouldStop: shouldStop),
              let ba = directed(b, a, sampleBudget:sampleTriangleBudget, shouldStop: shouldStop),
              let afterProtection = self.protection(after, shouldStop: shouldStop) else { return nil }
        let topologyPreserved = sameTopology(a.topology, b.topology)
            && protection.eulerCharacteristic == afterProtection.eulerCharacteristic
        let boundary: Double?
        if protection.boundaryEdges.isEmpty && afterProtection.boundaryEdges.isEmpty { boundary = 0 }
        else if protection.boundaryEdges.isEmpty || afterProtection.boundaryEdges.isEmpty { boundary = nil }
        else {
            guard let forward = boundaryDistance(protection.boundaryEdges, afterProtection.boundaryEdges, shouldStop),
                  let reverse = boundaryDistance(afterProtection.boundaryEdges, protection.boundaryEdges, shouldStop) else { return nil }
            boundary = max(forward, reverse)
        }
        // Attribute identity for protected vertices, including both sides of
        // UV seams, rather than merely checking that a UV buffer exists.
        struct Attribute: Hashable {
            let position: Position
            let normal: SIMD3<Float>
            let uv: SIMD2<Float>?
        }
        var afterAttributes: Set<Attribute> = []
        for i in after.positions.indices {
            if shouldStop() { return nil }
            afterAttributes.insert(Attribute(position: Position(after.positions[i]), normal: after.normals[i], uv: after.texcoords?[i]))
        }
        var appearance = (before.texcoords == nil) == (after.texcoords == nil)
        let used = Set(after.indices.map(Int.init))
        var usedAttributes: Set<Attribute> = []
        for i in used { usedAttributes.insert(Attribute(position: Position(after.positions[i]), normal: after.normals[i], uv: after.texcoords?[i])) }
        for i in protection.vertices {
            if shouldStop() { return nil }
            let attribute = Attribute(position: Position(before.positions[i]), normal: before.normals[i], uv: before.texcoords?[i])
            if !afterAttributes.contains(attribute) || !usedAttributes.contains(attribute) { appearance = false }
        }
        guard let va = signedVolume(a, shouldStop), let vb = signedVolume(b, shouldStop) else { return nil }
        return Report(sampledDistanceMM: max(ab.sample, ba.sample) * scale, distanceUpperBoundMM: max(ab.bound, ba.bound) * scale,
                      sampledTriangles: ab.samples + ba.samples, totalTriangles: a.triangleCount + b.triangleCount,
                      boundaryDistanceMM: boundary.map { $0 * scale }, signedVolumeBeforeMM3: va * pow(scale,3), signedVolumeAfterMM3: vb * pow(scale,3),
                      closedOrientedVolumes: a.topology.isWatertight && b.topology.isWatertight,
                      topologyPreserved: topologyPreserved, boundaryEdgesBefore: a.topology.boundaryEdgeCount,
                      boundaryEdgesAfter: b.topology.boundaryEdgeCount,
                      eulerBefore: protection.eulerCharacteristic, eulerAfter: afterProtection.eulerCharacteristic,
                      appearancePreserved: appearance,
                      protectedVertices: protection.vertices.count)
    }

    static func sameTopology(_ a: CADInterferenceMeshTopology, _ b: CADInterferenceMeshTopology) -> Bool {
        a.boundaryEdgeCount == b.boundaryEdgeCount && a.nonManifoldEdgeCount == b.nonManifoldEdgeCount
            && a.componentCount == b.componentCount && a.isClosed == b.isClosed
            && a.isOriented == b.isOriented && a.inwardComponentCount == b.inwardComponentCount
    }

    private static func nearest(_ point: SIMD3<Double>, _ geometry: CADInterferenceMeshGeometry,
                                _ stop: () -> Bool) -> Double? {
        var best = Double.infinity, stack = [0]
        let box = CADInterferenceAABB(points: [point])
        while let nodeIndex = stack.popLast() {
            if stop() { return nil }
            let node = geometry.bvh.nodes[nodeIndex]
            if node.bounds.distanceSquared(to: box) > best { continue }
            if node.count == 0 {
                // Visit the closest child first so the exact point query's
                // bound prunes distant leaves instead of scanning the mesh.
                let left = Int(node.left), right = Int(node.right)
                if geometry.bvh.nodes[left].bounds.distanceSquared(to:box) < geometry.bvh.nodes[right].bounds.distanceSquared(to:box) {
                    stack.append(right); stack.append(left)
                } else { stack.append(left); stack.append(right) }
            } else {
                for offset in Int(node.start)..<Int(node.start + node.count) {
                    if stop() { return nil }
                    let t = geometry.triangle(Int(geometry.bvh.order[offset]))
                    let q = CADInterferenceGeometry.closestPointOnTriangle(point, t.0, t.1, t.2)
                    best = min(best, simd_length_squared(q - point))
                }
            }
        }
        return best.isFinite ? sqrt(max(0,best)) : nil
    }
    private static func directed(_ source: CADInterferenceMeshGeometry, _ target: CADInterferenceMeshGeometry,
                                 sampleBudget:Int, shouldStop: () -> Bool) -> (sample: Double, bound: Double, samples:Int)? {
        var maximum = 0.0, upper = 0.0
        let stride = max(1,(source.triangleCount + sampleBudget - 1)/sampleBudget)
        var i = 0, samples = 0
        while i < source.triangleCount {
            if shouldStop() { return nil }
            let (a,b,c) = source.triangle(i), center = (a+b+c)/3
            guard let distance = nearest(center, target, shouldStop) else { return nil }
            maximum = max(maximum, distance)
            // Every triangle, including unsampled ones, contributes to its
            // block's cover radius. Distance-to-surface is 1-Lipschitz, so
            // d(center,target)+radius bounds every point in this whole block.
            var radius = 0.0
            let end = min(source.triangleCount,i+stride)
            for triangle in i..<end {
                if shouldStop() { return nil }
                let t = source.triangle(triangle)
                radius = max(radius,max(simd_length(t.0-center),max(simd_length(t.1-center),simd_length(t.2-center))))
            }
            upper = max(upper,distance+radius)
            for point in [a,b,c,(a+b)/2,(b+c)/2,(c+a)/2] {
                guard let value = nearest(point, target, shouldStop) else { return nil }
                maximum = max(maximum, value)
            }
            i = end; samples += 1
        }
        return (maximum, upper, samples)
    }
    private static func signedVolume(_ geometry: CADInterferenceMeshGeometry, _ stop: () -> Bool) -> Double? {
        let origin = geometry.bounds.min
        var volume = 0.0
        for i in 0..<geometry.triangleCount {
            if stop() { return nil }
            let t = geometry.triangle(i)
            volume += simd_dot(t.0-origin, simd_cross(t.1-origin,t.2-origin))/6
        }
        return volume.isFinite ? volume : nil
    }
    private static func boundaryDistance(_ source: [(SIMD3<Float>,SIMD3<Float>)],
                                         _ target: [(SIMD3<Float>,SIMD3<Float>)], _ stop: () -> Bool) -> Double? {
        var maximum = 0.0
        for edge in source {
            for point in [SIMD3<Double>(edge.0),SIMD3<Double>(edge.1),(SIMD3<Double>(edge.0)+SIMD3<Double>(edge.1))/2] {
                var best = Double.infinity
                for other in target {
                    if stop() { return nil }
                    let a = SIMD3<Double>(other.0), delta = SIMD3<Double>(other.1)-a
                    let fraction = max(0,min(1,simd_dot(point-a,delta)/max(1e-30,simd_length_squared(delta))))
                    best = min(best,simd_length(point-(a+delta*fraction)))
                }
                maximum = max(maximum,best)
            }
        }
        return maximum.isFinite ? maximum : nil
    }
}

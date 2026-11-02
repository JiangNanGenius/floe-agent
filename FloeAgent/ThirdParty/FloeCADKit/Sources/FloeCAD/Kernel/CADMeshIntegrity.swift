// SPDX-License-Identifier: MPL-2.0
// Value-only inspection of the actual triangles before/after mesh cleanup.
// This does not fill holes, guess cavity orientation, or rewrite topology.
import Foundation
import simd

nonisolated enum CADMeshIntegrity {
    struct Report: Sendable {
        let boundaryEdges: Int
        let nonManifoldEdges: Int
        let inconsistentWinding: Bool
        let reversedClosedShell: Bool
        let ambiguousShellOrientation: Bool
        let degenerateTriangles: Int
        let selfIntersectionPairs: Int
        let witnesses: [[Int]]

        var unresolved: Bool {
            boundaryEdges > 0 || nonManifoldEdges > 0 || inconsistentWinding
                || reversedClosedShell || ambiguousShellOrientation
                || degenerateTriangles > 0 || selfIntersectionPairs > 0
        }
        var payload: [String: Any] {
            ["boundaryEdgeCount": boundaryEdges, "nonManifoldEdgeCount": nonManifoldEdges,
             "inconsistentWinding": inconsistentWinding, "reversedClosedShell": reversedClosedShell,
             "orientationNeedsReview": ambiguousShellOrientation,
             "degenerateTriangleCount": degenerateTriangles,
             "selfIntersectionPairCount": selfIntersectionPairs,
             "selfIntersectionWitnesses": witnesses,
             "selfIntersectionWitnessesAreSampled": selfIntersectionPairs > witnesses.count,
             "complete": !unresolved]
        }
        func requiresUnsupportedRepair(_ request: CADMeshRepairRequest) -> Bool {
            switch request {
            case .cleanup: false
            case .holes: boundaryEdges > 0
            case .nonManifold: nonManifoldEdges > 0
            case .selfIntersections: selfIntersectionPairs > 0
            case .orientation: inconsistentWinding || reversedClosedShell || ambiguousShellOrientation
            case .all:
                boundaryEdges > 0 || nonManifoldEdges > 0 || inconsistentWinding
                    || reversedClosedShell || ambiguousShellOrientation || selfIntersectionPairs > 0
            }
        }
    }

    /// Nil means inspection did not finish. Never publish an incomplete scan
    /// as a zero-defect report. Runs only on the existing service compute path.
    static func inspect(_ mesh: RenderMesh, shouldStop: () -> Bool) -> Report? {
        guard !shouldStop(), mesh.triangleCount > 0, mesh.indices.count % 3 == 0,
              mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else { return nil }
        var indices: [UInt32] = [], originals: [Int] = []
        indices.reserveCapacity(mesh.indices.count)
        var degenerate = 0
        for index in 0..<mesh.triangleCount {
            if shouldStop() { return nil }
            let at = index * 3
            let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[at])])
            let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[at + 1])])
            let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[at + 2])])
            if simd_length(simd_cross(b - a, c - a)) <= 1e-12 { degenerate += 1; continue }
            indices.append(contentsOf: mesh.indices[at..<(at + 3)])
            originals.append(index)
        }
        if indices.isEmpty {
            return Report(boundaryEdges: 0, nonManifoldEdges: 0, inconsistentWinding: false,
                          reversedClosedShell: false, ambiguousShellOrientation: false,
                          degenerateTriangles: degenerate, selfIntersectionPairs: 0, witnesses: [])
        }
        // Signed zero has one geometric position, even across split normals.
        let positions = mesh.positions.map { SIMD3<Float>($0.x == 0 ? 0 : $0.x,
            $0.y == 0 ? 0 : $0.y, $0.z == 0 ? 0 : $0.z) }
        let geometry = CADInterferenceMeshGeometry.build(positions: positions, indices: indices)
        guard geometry.isValid, !shouldStop() else { return nil }
        let epsilon = max(1e-9, geometry.bounds.diagonal * 1e-10)
        var count = 0, witnesses: [[Int]] = []
        for triangle in 0..<geometry.triangleCount {
            var stack: [Int] = [0]
            while let index = stack.popLast() {
                if shouldStop() { return nil }
                let node = geometry.bvh.nodes[index]
                guard node.bounds.overlaps(geometry.bvh.triangleBounds[triangle], tolerance: epsilon) else { continue }
                if node.count == 0 {
                    stack.append(Int(node.left)); stack.append(Int(node.right))
                } else {
                    for offset in Int(node.start)..<Int(node.start + node.count) {
                        if shouldStop() { return nil }
                        let other = Int(geometry.bvh.order[offset])
                        guard other > triangle,
                              geometry.bvh.triangleBounds[triangle].overlaps(
                                geometry.bvh.triangleBounds[other], tolerance: epsilon),
                              CADInterferenceGeometry.selfIntersection(
                                geometry.triangle(triangle), geometry.triangle(other), tolerance: epsilon) else { continue }
                        count += 1
                        if witnesses.count < 8 { witnesses.append([originals[triangle], originals[other]]) }
                    }
                }
            }
        }
        guard !shouldStop() else { return nil }
        let topology = geometry.topology
        // A negative inner shell can be a valid cavity. Only an isolated,
        // closed shell has an unambiguous global inward winding here.
        return Report(boundaryEdges: topology.boundaryEdgeCount,
                      nonManifoldEdges: topology.nonManifoldEdgeCount,
                      inconsistentWinding: !topology.isOriented,
                      reversedClosedShell: topology.isClosed && topology.componentCount == 1
                        && topology.inwardComponentCount == 1,
                      ambiguousShellOrientation: !topology.isClosed || topology.componentCount > 1,
                      degenerateTriangles: degenerate, selfIntersectionPairs: count, witnesses: witnesses)
    }
}

nonisolated enum CADMeshRepairRequest: String, Sendable {
    case cleanup, holes, selfIntersections, orientation, nonManifold, all
}

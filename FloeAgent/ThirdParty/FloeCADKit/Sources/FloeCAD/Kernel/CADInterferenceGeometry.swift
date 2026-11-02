//
//  CADInterferenceGeometry.swift
//  FloeCADKit
//
//  Pure, bounded triangle geometry for assembly inspection.
//
//  This is deliberately NOT a second collision service or editor: it is the
//  numeric kernel used by `CADAssemblyService` for mesh-only pairs. The exact
//  OCCT B-rep common remains the authority when both instances carry one; this
//  file only answers the question the render mesh can actually answer — the
//  minimum surface distance between two triangle sets in millimetres, whether
//  the surfaces cross, and (for validated watertight meshes) whether one closed
//  material volume contains the other. AABB is used only as a BVH broadphase
//  bound; it is never reported as a solid overlap volume.
//
//  Everything here is value math over `Sendable` snapshots. No document, body,
//  kernel handle or UI state is touched.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

// MARK: - AABB

nonisolated struct CADInterferenceAABB: Sendable, Equatable {
    var min: SIMD3<Double>
    var max: SIMD3<Double>

    static let empty = CADInterferenceAABB(
        min: SIMD3<Double>(repeating: .infinity),
        max: SIMD3<Double>(repeating: -.infinity))

    init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    init(points: [SIMD3<Double>]) {
        guard let first = points.first else {
            self = .empty
            return
        }
        var lo = first
        var hi = first
        for point in points.dropFirst() {
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        self.init(min: lo, max: hi)
    }

    var isEmpty: Bool {
        !(min.x.isFinite && min.y.isFinite && min.z.isFinite
          && max.x.isFinite && max.y.isFinite && max.z.isFinite)
            || min.x > max.x || min.y > max.y || min.z > max.z
    }

    var center: SIMD3<Double> { (min + max) * 0.5 }
    var extent: SIMD3<Double> { max - min }
    var diagonal: Double { simd_length(extent) }
    var maxAbsCoordinate: Double {
        let a = simd_max(simd_abs(min), simd_abs(max))
        return Swift.max(a.x, Swift.max(a.y, a.z))
    }

    func union(_ other: CADInterferenceAABB) -> CADInterferenceAABB {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        return CADInterferenceAABB(min: simd_min(min, other.min),
                                   max: simd_max(max, other.max))
    }

    func expanded(by amount: Double) -> CADInterferenceAABB {
        guard amount.isFinite, amount >= 0 else { return self }
        let delta = SIMD3<Double>(repeating: amount)
        return CADInterferenceAABB(min: min - delta, max: max + delta)
    }

    func overlaps(_ other: CADInterferenceAABB, tolerance: Double) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        let pad = Swift.max(0, tolerance)
        for axis in 0..<3 {
            if max[axis] + pad < other.min[axis] { return false }
            if other.max[axis] + pad < min[axis] { return false }
        }
        return true
    }

    func contains(_ other: CADInterferenceAABB, tolerance: Double) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        let pad = Swift.max(0, tolerance)
        for axis in 0..<3 {
            if other.min[axis] + pad < min[axis] { return false }
            if other.max[axis] - pad > max[axis] { return false }
        }
        return true
    }

    /// Intersection volume. This is a broadphase diagnostic only; it is never
    /// reported as a mesh solid-overlap result.
    func overlapVolume(with other: CADInterferenceAABB) -> Double {
        guard !isEmpty, !other.isEmpty else { return 0 }
        let overlap = simd_max(SIMD3<Double>.zero,
                               simd_min(max, other.max) - simd_max(min, other.min))
        return Swift.max(0, overlap.x) * Swift.max(0, overlap.y) * Swift.max(0, overlap.z)
    }

    /// Squared Euclidean gap. Zero when the boxes overlap.
    func distanceSquared(to other: CADInterferenceAABB) -> Double {
        guard !isEmpty, !other.isEmpty else { return .infinity }
        var sum = 0.0
        for axis in 0..<3 {
            let gap = Swift.max(0,
                                Swift.max(min[axis] - other.max[axis],
                                          other.min[axis] - max[axis]))
            sum += gap * gap
        }
        return sum
    }

    func transformed(by transform: CADInterferenceTransform) -> CADInterferenceAABB {
        guard !isEmpty else { return .empty }
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for index in 0..<8 {
            let corner = SIMD3<Double>(
                (index & 1) == 0 ? min.x : max.x,
                (index & 2) == 0 ? min.y : max.y,
                (index & 4) == 0 ? min.z : max.z)
            let world = transform.applying(to: corner)
            lo = simd_min(lo, world)
            hi = simd_max(hi, world)
        }
        return CADInterferenceAABB(min: lo, max: hi)
    }
}

// MARK: - Similarity transform

/// Uniform scale + rotation + translation, the only placement the CAD kernel
/// accepts. Kept independent of `Transform3D` so the numeric core can be
/// compiled and exercised on its own.
nonisolated struct CADInterferenceTransform: Sendable, Equatable {
    var rotation: simd_quatd
    var scale: Double
    var translation: SIMD3<Double>

    static let identity = CADInterferenceTransform(
        rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
        scale: 1,
        translation: .zero)

    init(rotation: simd_quatd, scale: Double, translation: SIMD3<Double>) {
        let length = simd_length(SIMD4<Double>(rotation.imag.x, rotation.imag.y,
                                               rotation.imag.z, rotation.real))
        self.rotation = length > 1e-15
            ? simd_quatd(ix: rotation.imag.x / length,
                         iy: rotation.imag.y / length,
                         iz: rotation.imag.z / length,
                         r: rotation.real / length)
            : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        self.scale = scale
        self.translation = translation
    }

    var isFinite: Bool {
        scale.isFinite && scale > 0
            && translation.x.isFinite && translation.y.isFinite && translation.z.isFinite
            && rotation.imag.x.isFinite && rotation.imag.y.isFinite
            && rotation.imag.z.isFinite && rotation.real.isFinite
    }

    func applying(to point: SIMD3<Double>) -> SIMD3<Double> {
        rotation.act(point * scale) + translation
    }

    /// Apply `base` first, then `self` (`self ∘ base`).
    func composed(onto base: CADInterferenceTransform) -> CADInterferenceTransform {
        CADInterferenceTransform(
            rotation: simd_normalize(rotation * base.rotation),
            scale: scale * base.scale,
            translation: rotation.act(base.translation * scale) + translation)
    }

    func inverse() -> CADInterferenceTransform {
        let inverseRotation = rotation.inverse
        let inverseScale = 1 / max(scale, 1e-300)
        return CADInterferenceTransform(
            rotation: inverseRotation,
            scale: inverseScale,
            translation: inverseRotation.act(-translation) * inverseScale)
    }
}

// MARK: - Mesh topology

/// What the indexed render mesh proves about itself. A RenderMesh welds by
/// (position, normal), so hard edges duplicate positions; topology is therefore
/// evaluated after welding positions by exact identity. A mesh that fails this
/// check still gets a real surface distance, but it is never used to claim
/// material containment.
nonisolated struct CADInterferenceMeshTopology: Sendable, Equatable {
    var weldedVertexCount: Int
    var triangleCount: Int
    var degenerateTriangleCount: Int
    var boundaryEdgeCount: Int
    var nonManifoldEdgeCount: Int
    var componentCount: Int
    var inwardComponentCount: Int
    var isClosed: Bool
    var isOriented: Bool

    var isWatertight: Bool { isClosed && isOriented && componentCount > 0 }

    var summary: String {
        if isWatertight {
            return inwardComponentCount > 0
                ? "closed, consistently oriented, \(componentCount) shell(s), "
                    + "\(inwardComponentCount) inward-facing cavity shell(s)"
                : "closed, consistently oriented, \(componentCount) shell(s)"
        }
        if !isClosed {
            return "open or non-manifold mesh "
                + "(\(boundaryEdgeCount) boundary, \(nonManifoldEdgeCount) non-manifold edge(s)); "
                + "container parity not evaluated"
        }
        return "closed mesh with inconsistent triangle orientation; "
            + "container parity not evaluated"
    }
}

// MARK: - BVH

/// Bounding-volume hierarchy over triangle indices. Node bounds are in mesh
/// local coordinates; a pair query transforms one node at a time into the
/// reference frame. This keeps one immutable geometry per body definition
/// instead of copying a dense world mesh per instance or per pair.
nonisolated struct CADInterferenceBVH: Sendable {
    struct Node: Sendable {
        var bounds: CADInterferenceAABB
        var left: Int32
        var right: Int32
        var start: Int32
        var count: Int32
    }

    let nodes: [Node]
    let order: [Int32]
    let triangleBounds: [CADInterferenceAABB]
    let triangleCount: Int

    static func build(triangleBounds: [CADInterferenceAABB],
                      centroids: [SIMD3<Double>]) -> CADInterferenceBVH {
        let count = triangleBounds.count
        guard count > 0 else {
            return CADInterferenceBVH(nodes: [], order: [], triangleBounds: [],
                                      triangleCount: 0)
        }
        var order = Array(0..<count).map(Int32.init)
        var nodes: [Node] = []
        nodes.reserveCapacity(max(1, count * 2))

        func buildNode(_ start: Int, _ end: Int) -> Int32 {
            let nodeIndex = Int32(nodes.count)
            var bounds = triangleBounds[Int(order[start])]
            for index in (start + 1)..<end {
                bounds = bounds.union(triangleBounds[Int(order[index])])
            }
            nodes.append(Node(bounds: bounds, left: -1, right: -1,
                              start: Int32(start), count: Int32(end - start)))
            guard end - start > 8 else { return nodeIndex }

            let extent = bounds.extent
            var axis = 0
            if extent.y > extent.x { axis = 1 }
            if extent.z > extent[axis] { axis = 2 }
            let slice = order[start..<end]
            let sorted = slice.sorted {
                centroids[Int($0)][axis] < centroids[Int($1)][axis]
            }
            order.replaceSubrange(start..<end, with: sorted)

            var split = (start + end) / 2
            let mid = (start + end) / 2
            let midValue = centroids[Int(order[mid])][axis]
            var low = start
            while low < end && centroids[Int(order[low])][axis] < midValue { low += 1 }
            if low > start && low < end { split = low }
            if split <= start || split >= end { split = mid }

            let left = buildNode(start, split)
            let right = buildNode(split, end)
            nodes[Int(nodeIndex)].left = left
            nodes[Int(nodeIndex)].right = right
            nodes[Int(nodeIndex)].count = 0
            return nodeIndex
        }

        _ = buildNode(0, count)
        return CADInterferenceBVH(nodes: nodes, order: order,
                                  triangleBounds: triangleBounds,
                                  triangleCount: count)
    }
}

// MARK: - Geometry

nonisolated struct CADInterferenceMeshGeometry: Sendable {
    let vertices: [SIMD3<Double>]
    let indices: [UInt32]
    let triangleCount: Int
    let bounds: CADInterferenceAABB
    let topology: CADInterferenceMeshTopology
    let bvh: CADInterferenceBVH
    let invalidReason: String?

    var isValid: Bool { invalidReason == nil && triangleCount > 0 }

    static func build(positions: [SIMD3<Float>], indices: [UInt32]) -> CADInterferenceMeshGeometry {
        let vertices = positions.map { SIMD3<Double>($0) }
        let emptyTopology = CADInterferenceMeshTopology(
            weldedVertexCount: 0, triangleCount: 0, degenerateTriangleCount: 0,
            boundaryEdgeCount: 0, nonManifoldEdgeCount: 0, componentCount: 0,
            inwardComponentCount: 0, isClosed: false, isOriented: false)
        let emptyBVH = CADInterferenceBVH.build(triangleBounds: [], centroids: [])
        guard !vertices.isEmpty else {
            return CADInterferenceMeshGeometry(
                vertices: [], indices: [], triangleCount: 0, bounds: .empty,
                topology: emptyTopology, bvh: emptyBVH,
                invalidReason: "the mesh has no vertices")
        }
        guard indices.count >= 3, indices.count % 3 == 0 else {
            return CADInterferenceMeshGeometry(
                vertices: vertices, indices: indices, triangleCount: 0, bounds: .empty,
                topology: emptyTopology, bvh: emptyBVH,
                invalidReason: "the mesh index buffer is not a whole number of triangles")
        }
        for vertex in vertices {
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else {
                return CADInterferenceMeshGeometry(
                    vertices: vertices, indices: indices, triangleCount: indices.count / 3,
                    bounds: .empty, topology: emptyTopology, bvh: emptyBVH,
                    invalidReason: "the mesh contains a non-finite vertex")
            }
        }
        for index in indices {
            guard Int(index) < vertices.count else {
                return CADInterferenceMeshGeometry(
                    vertices: vertices, indices: indices, triangleCount: indices.count / 3,
                    bounds: .empty, topology: emptyTopology, bvh: emptyBVH,
                    invalidReason: "the mesh index buffer references a missing vertex")
            }
        }

        let bounds = CADInterferenceAABB(points: vertices)
        let triangleCount = indices.count / 3
        var triangleBounds: [CADInterferenceAABB] = []
        var centroids: [SIMD3<Double>] = []
        triangleBounds.reserveCapacity(triangleCount)
        centroids.reserveCapacity(triangleCount)
        for triangle in 0..<triangleCount {
            let base = triangle * 3
            let a = vertices[Int(indices[base])]
            let b = vertices[Int(indices[base + 1])]
            let c = vertices[Int(indices[base + 2])]
            triangleBounds.append(CADInterferenceAABB(points: [a, b, c]))
            centroids.append((a + b + c) / 3)
        }
        let bvh = CADInterferenceBVH.build(triangleBounds: triangleBounds,
                                           centroids: centroids)
        let topology = analyseTopology(vertices: vertices, indices: indices,
                                       triangleBounds: triangleBounds,
                                       triangleCount: triangleCount)
        return CADInterferenceMeshGeometry(
            vertices: vertices, indices: indices, triangleCount: triangleCount,
            bounds: bounds, topology: topology, bvh: bvh, invalidReason: nil)
    }

    func triangle(_ index: Int) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let base = index * 3
        return (vertices[Int(indices[base])],
                vertices[Int(indices[base + 1])],
                vertices[Int(indices[base + 2])])
    }

    // MARK: Topology analysis

    private struct VertexKey: Hashable {
        var x: UInt64
        var y: UInt64
        var z: UInt64
    }

    private static func analyseTopology(vertices: [SIMD3<Double>],
                                        indices: [UInt32],
                                        triangleBounds: [CADInterferenceAABB],
                                        triangleCount: Int) -> CADInterferenceMeshTopology {
        var keyToWelded: [VertexKey: Int] = [:]
        keyToWelded.reserveCapacity(min(vertices.count, 1 << 18))
        var weldedIndices: [Int] = []
        weldedIndices.reserveCapacity(indices.count)
        for index in indices {
            let point = vertices[Int(index)]
            let key = VertexKey(x: point.x.bitPattern,
                                y: point.y.bitPattern,
                                z: point.z.bitPattern)
            if let welded = keyToWelded[key] {
                weldedIndices.append(welded)
            } else {
                let next = keyToWelded.count
                keyToWelded[key] = next
                weldedIndices.append(next)
            }
        }

        struct EdgeUse {
            var forward = 0
            var reverse = 0
            var total: Int { forward + reverse }
        }
        var edges: [UInt64: EdgeUse] = [:]
        edges.reserveCapacity(triangleCount * 3)
        var degenerate = 0
        var validTriangles: [(a: Int, b: Int, c: Int, triangle: Int)] = []
        validTriangles.reserveCapacity(triangleCount)

        func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
            let lo = UInt64(min(a, b))
            let hi = UInt64(max(a, b))
            return (lo << 32) | hi
        }
        func addEdge(_ a: Int, _ b: Int) {
            guard a != b else { return }
            let key = edgeKey(a, b)
            var use = edges[key] ?? EdgeUse()
            if a < b { use.forward += 1 } else { use.reverse += 1 }
            edges[key] = use
        }

        for triangle in 0..<triangleCount {
            let base = triangle * 3
            let a = weldedIndices[base]
            let b = weldedIndices[base + 1]
            let c = weldedIndices[base + 2]
            if a == b || b == c || c == a || triangleBounds[triangle].diagonal < 1e-14 {
                degenerate += 1
                continue
            }
            validTriangles.append((a, b, c, triangle))
            addEdge(a, b)
            addEdge(b, c)
            addEdge(c, a)
        }

        var boundary = 0
        var nonManifold = 0
        var oriented = true
        for use in edges.values {
            if use.total == 1 { boundary += 1 }
            if use.total > 2 { nonManifold += 1 }
            if use.total == 2 && !(use.forward == 1 && use.reverse == 1) {
                oriented = false
            }
        }

        // Union-find over the welded vertices used by non-degenerate
        // triangles, so a hollow body's outer shell and cavity shell are
        // separate material components rather than one ambiguous surface.
        var parent: [Int] = Array(0..<keyToWelded.count)
        func find(_ value: Int) -> Int {
            var value = value
            while parent[value] != value {
                parent[value] = parent[parent[value]]
                value = parent[value]
            }
            return value
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        for triangle in validTriangles {
            union(triangle.a, triangle.b)
            union(triangle.b, triangle.c)
            union(triangle.c, triangle.a)
        }

        var componentRoots = Set<Int>()
        var componentVolume: [Int: Double] = [:]
        for triangle in validTriangles {
            let root = find(triangle.a)
            componentRoots.insert(root)
            let base = triangle.triangle * 3
            let pa = vertices[Int(indices[base])]
            let pb = vertices[Int(indices[base + 1])]
            let pc = vertices[Int(indices[base + 2])]
            componentVolume[root, default: 0] += simd_dot(pa, simd_cross(pb, pc)) / 6
        }
        let volumeEpsilon = max(1e-12, boundsScale(vertices) * 1e-12)
        let inward = componentVolume.values.filter { $0 < -volumeEpsilon }.count
        let isClosed = boundary == 0 && nonManifold == 0 && !validTriangles.isEmpty
        return CADInterferenceMeshTopology(
            weldedVertexCount: keyToWelded.count,
            triangleCount: triangleCount,
            degenerateTriangleCount: degenerate,
            boundaryEdgeCount: boundary,
            nonManifoldEdgeCount: nonManifold,
            componentCount: componentRoots.count,
            inwardComponentCount: inward,
            isClosed: isClosed,
            isOriented: oriented && !validTriangles.isEmpty)
    }

    private static func boundsScale(_ vertices: [SIMD3<Double>]) -> Double {
        guard let first = vertices.first else { return 1 }
        var lo = first
        var hi = first
        for point in vertices.dropFirst() {
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        return max(simd_length(hi - lo), 1)
    }
}

// MARK: - Placed mesh

nonisolated struct CADInterferencePlacedMesh: Sendable {
    let geometry: CADInterferenceMeshGeometry
    let placement: CADInterferenceTransform

    var isValid: Bool { geometry.isValid && placement.isFinite }
}

// MARK: - Pair result

nonisolated struct CADInterferenceMeshPairResult: Sendable {
    enum Classification: String, Sendable {
        case penetrating
        case contact
        case separated
        case unresolved
    }

    var classification: Classification
    var minimumDistanceMM: Double?
    /// True when the triangle surfaces actually cross transversally.
    var surfaceCrossing: Bool
    /// True when the triangle surfaces touch (including coplanar overlap).
    var surfaceTouching: Bool
    /// `bInsideA`, `aInsideB`, `none`, `notEvaluatedOpenMesh` or
    /// `indeterminate`.
    var containment: String
    var witnessAWorld: SIMD3<Double>?
    var witnessBWorld: SIMD3<Double>?
    var triangleA: Int?
    var triangleB: Int?
    /// Precision of the reported distance from the Float mesh input, in mm.
    var precisionMM: Double?
    /// Extra quantization bound of the world vertices, in mm.
    var vertexPrecisionMM: Double?
    var aabbGapMM: Double?
    var topologyA: CADInterferenceMeshTopology
    var topologyB: CADInterferenceMeshTopology
    var notes: [String]
    var unresolvedReason: String?
}

// MARK: - Solver

nonisolated enum CADInterferenceGeometry {
    private static let floatEpsilon = 1.1920928955078125e-7
    private static let numericEpsilon = 1e-12

    // MARK: Pair entry

    static func surfacePair(a: CADInterferencePlacedMesh,
                            b: CADInterferencePlacedMesh,
                            toleranceMM: Double) -> CADInterferenceMeshPairResult {
        let topologyA = a.geometry.topology
        let topologyB = b.geometry.topology
        let tolerance = max(0, toleranceMM.isFinite ? toleranceMM : 0)

        func unresolved(_ reason: String) -> CADInterferenceMeshPairResult {
            CADInterferenceMeshPairResult(
                classification: .unresolved, minimumDistanceMM: nil,
                surfaceCrossing: false, surfaceTouching: false,
                containment: "notEvaluated", witnessAWorld: nil, witnessBWorld: nil,
                triangleA: nil, triangleB: nil, precisionMM: nil,
                vertexPrecisionMM: nil, aabbGapMM: nil,
                topologyA: topologyA, topologyB: topologyB,
                notes: [reason], unresolvedReason: reason)
        }

        if let reason = a.geometry.invalidReason { return unresolved(reason) }
        if let reason = b.geometry.invalidReason { return unresolved(reason) }
        guard a.geometry.isValid, b.geometry.isValid else {
            return unresolved("a mesh has no usable triangles")
        }
        guard a.placement.isFinite else { return unresolved("the first placement is not finite") }
        guard b.placement.isFinite else { return unresolved("the second placement is not finite") }

        // Work in A's local frame. A similarity's inverse keeps distances
        // proportional: world distance = local distance × A.scale.
        let relative = a.placement.inverse().composed(onto: b.placement)
        let bBoundsInA = b.geometry.bounds.transformed(by: relative)
        let aabbGapLocal = sqrt(max(0, a.geometry.bounds.distanceSquared(to: bBoundsInA)))
        let aabbGapMM = aabbGapLocal * a.placement.scale
        let aabbOverlap = a.geometry.bounds.overlaps(bBoundsInA, tolerance: tolerance)

        var state = QueryState()
        queryClosest(a: a.geometry, b: b.geometry, relative: relative,
                     toleranceLocal: tolerance / max(a.placement.scale, 1e-300),
                     state: &state)

        let precision = precisionMM(a: a, b: b)
        guard let localDistance = state.bestDistance else {
            return unresolved("no triangle pair produced a finite distance")
        }
        let distanceMM = localDistance * a.placement.scale
        let witnessA = state.bestA.map { a.placement.applying(to: $0) }
        let witnessB = state.bestB.map { a.placement.applying(to: $0) }

        var classification: CADInterferenceMeshPairResult.Classification = .separated
        var containment = "none"
        var notes: [String] = []

        if state.crossing {
            classification = .penetrating
            containment = "surfaceCrossing"
            notes.append("triangle surfaces cross")
        } else if distanceMM <= tolerance {
            classification = .contact
            containment = "none"
            if state.touching {
                notes.append("triangle surfaces touch within the contact tolerance")
            } else {
                notes.append("surfaces are within the contact tolerance but do not cross")
            }
        } else if aabbOverlap, topologyA.isWatertight, topologyB.isWatertight {
            let containmentResult = containmentBetween(
                a: a, b: b, relative: relative, toleranceMM: tolerance)
            containment = containmentResult.code
            if containmentResult.contained {
                classification = .penetrating
                notes.append(containmentResult.note)
            } else if containmentResult.indeterminate {
                classification = .unresolved
                notes.append(containmentResult.note)
            } else {
                notes.append("AABBs overlap but the closed surfaces are separate; "
                             + "no material containment")
            }
        } else if aabbOverlap {
            containment = "notEvaluatedOpenMesh"
            notes.append("AABBs overlap; at least one mesh is not a validated closed solid, "
                         + "so container parity was not claimed")
        } else {
            containment = "none_disjointBounds"
        }

        if topologyA.degenerateTriangleCount > 0 || topologyB.degenerateTriangleCount > 0 {
            notes.append("degenerate triangles were handled as point/segment features")
        }

        return CADInterferenceMeshPairResult(
            classification: classification,
            minimumDistanceMM: classification == .penetrating && state.crossing ? 0 : distanceMM,
            surfaceCrossing: state.crossing,
            surfaceTouching: state.touching,
            containment: containment,
            witnessAWorld: witnessA,
            witnessBWorld: witnessB,
            triangleA: state.bestTriangleA,
            triangleB: state.bestTriangleB,
            precisionMM: precision,
            vertexPrecisionMM: precision,
            aabbGapMM: aabbGapMM,
            topologyA: topologyA,
            topologyB: topologyB,
            notes: notes,
            unresolvedReason: classification == .unresolved
                ? notes.last ?? "the mesh pair could not be resolved" : nil)
    }

    // MARK: Query state and traversal

    private struct QueryState {
        var bestDistanceSquared: Double = .infinity
        var bestDistance: Double? {
            bestDistanceSquared.isFinite ? sqrt(max(0, bestDistanceSquared)) : nil
        }
        var bestA: SIMD3<Double>?
        var bestB: SIMD3<Double>?
        var bestTriangleA: Int?
        var bestTriangleB: Int?
        var crossing = false
        var touching = false
    }

    private struct StackEntry {
        var a: Int32
        var b: Int32
    }

    private static func queryClosest(a: CADInterferenceMeshGeometry,
                                     b: CADInterferenceMeshGeometry,
                                     relative: CADInterferenceTransform,
                                     toleranceLocal: Double,
                                     state: inout QueryState) {
        guard !a.bvh.nodes.isEmpty, !b.bvh.nodes.isEmpty else { return }
        var stack: [StackEntry] = [StackEntry(a: 0, b: 0)]
        stack.reserveCapacity(128)
        let toleranceSquared = toleranceLocal * toleranceLocal

        while let entry = stack.popLast() {
            let nodeA = a.bvh.nodes[Int(entry.a)]
            let nodeB = b.bvh.nodes[Int(entry.b)]
            let bBounds = nodeB.bounds.transformed(by: relative)
            let lowerSquared = nodeA.bounds.distanceSquared(to: bBounds)
            if lowerSquared > state.bestDistanceSquared + numericEpsilon { continue }

            if nodeA.count > 0 && nodeB.count > 0 {
                let aStart = Int(nodeA.start)
                let aEnd = aStart + Int(nodeA.count)
                let bStart = Int(nodeB.start)
                let bEnd = bStart + Int(nodeB.count)
                for aOrder in aStart..<aEnd {
                    let triangleA = Int(a.bvh.order[aOrder])
                    let triA = a.triangle(triangleA)
                    let boundsA = a.bvh.triangleBounds[triangleA]
                    for bOrder in bStart..<bEnd {
                        let triangleB = Int(b.bvh.order[bOrder])
                        let boundsB = b.bvh.triangleBounds[triangleB].transformed(by: relative)
                        if boundsA.distanceSquared(to: boundsB)
                            > state.bestDistanceSquared + numericEpsilon {
                            continue
                        }
                        let triB = b.triangle(triangleB)
                        let transformedB = (relative.applying(to: triB.0),
                                            relative.applying(to: triB.1),
                                            relative.applying(to: triB.2))
                        let result = triangleDistance(triA, transformedB)
                        if result.distanceSquared < state.bestDistanceSquared {
                            state.bestDistanceSquared = result.distanceSquared
                            state.bestA = result.pointA
                            state.bestB = result.pointB
                            state.bestTriangleA = triangleA
                            state.bestTriangleB = triangleB
                        }
                        if result.distanceSquared <= toleranceSquared + numericEpsilon {
                            let relation = triangleRelation(
                                triA, transformedB,
                                tolerance: max(toleranceLocal, numericEpsilon))
                            if relation == .crossing { state.crossing = true }
                            if relation != .none { state.touching = true }
                        }
                    }
                }
                continue
            }

            if nodeA.count == 0 && nodeB.count == 0 {
                let leftA = nodeA.left
                let rightA = nodeA.right
                let leftB = nodeB.left
                let rightB = nodeB.right
                if leftA < 0 || leftB < 0 { continue }
                stack.append(StackEntry(a: leftA, b: leftB))
                stack.append(StackEntry(a: leftA, b: rightB))
                stack.append(StackEntry(a: rightA, b: leftB))
                stack.append(StackEntry(a: rightA, b: rightB))
            } else if nodeA.count == 0 {
                if nodeA.left < 0 { continue }
                stack.append(StackEntry(a: nodeA.left, b: entry.b))
                stack.append(StackEntry(a: nodeA.right, b: entry.b))
            } else {
                if nodeB.left < 0 { continue }
                stack.append(StackEntry(a: entry.a, b: nodeB.left))
                stack.append(StackEntry(a: entry.a, b: nodeB.right))
            }
        }
    }

    // MARK: Containment

    private struct ContainmentResult {
        var code: String
        var contained: Bool
        var indeterminate: Bool
        var note: String
    }

    private static func containmentBetween(a: CADInterferencePlacedMesh,
                                           b: CADInterferencePlacedMesh,
                                           relative: CADInterferenceTransform,
                                           toleranceMM: Double)
        -> ContainmentResult {
        let samplesA = samplePoints(a.geometry)
        let samplesB = samplePoints(b.geometry)
        let inverseRelative = relative.inverse()

        var aInsideB = !samplesA.isEmpty
        for point in samplesA {
            let localB = inverseRelative.applying(to: point)
            guard pointInMaterial(localB, geometry: b.geometry) == true else {
                aInsideB = false
                break
            }
        }
        if aInsideB {
            return ContainmentResult(
                code: "aInsideB", contained: true, indeterminate: false,
                note: "A's validated closed surface lies inside B's material volume")
        }

        var bInsideA = !samplesB.isEmpty
        for point in samplesB {
            let localA = relative.applying(to: point)
            guard pointInMaterial(localA, geometry: a.geometry) == true else {
                bInsideA = false
                break
            }
        }
        if bInsideA {
            return ContainmentResult(
                code: "bInsideA", contained: true, indeterminate: false,
                note: "B's validated closed surface lies inside A's material volume")
        }

        var anyInside = false
        var anyOutside = false
        for point in samplesB {
            let localA = relative.applying(to: point)
            switch pointInMaterial(localA, geometry: a.geometry) {
            case .some(true): anyInside = true
            case .some(false): anyOutside = true
            case .none: break
            }
        }
        if anyInside && anyOutside {
            return ContainmentResult(
                code: "indeterminate", contained: false, indeterminate: true,
                note: "watertight samples disagree on containment; the pair is unresolved")
        }
        return ContainmentResult(
            code: "none", contained: false, indeterminate: false,
            note: "validated closed surfaces are separate and neither contains the other")
    }

    private static func samplePoints(_ geometry: CADInterferenceMeshGeometry) -> [SIMD3<Double>] {
        guard geometry.triangleCount > 0 else { return [] }
        var points: [SIMD3<Double>] = []
        let target = 12
        let step = max(1, geometry.triangleCount / target)
        var triangle = 0
        while triangle < geometry.triangleCount && points.count < target {
            let (a, b, c) = geometry.triangle(triangle)
            points.append((a + b + c) / 3)
            triangle += step
        }
        let last = geometry.triangle(geometry.triangleCount - 1)
        points.append((last.0 + last.1 + last.2) / 3)
        return points
    }

    /// Parity of a ray cast through a closed triangle mesh. `nil` means the
    /// three independent directions disagreed (numerical ambiguity), which the
    /// caller must not turn into a containment claim.
    private static func pointInMaterial(_ point: SIMD3<Double>,
                                        geometry: CADInterferenceMeshGeometry) -> Bool? {
        guard geometry.topology.isWatertight else { return nil }
        let directions: [SIMD3<Double>] = [
            SIMD3(0.5734623443633283, 0.5734623443633283, 0.5847831303818837),
            SIMD3(-0.3123475237772121, 0.8110322489579861, -0.4944031186575211),
            SIMD3(0.2672612419124244, -0.5345224838248488, 0.8017837257372732),
        ]
        var parities: [Bool] = []
        for direction in directions {
            if let parity = rayParity(point: point, direction: direction, geometry: geometry) {
                parities.append(parity)
            }
        }
        guard let first = parities.first else { return nil }
        return parities.allSatisfy { $0 == first } ? first : nil
    }

    private static func rayParity(point: SIMD3<Double>, direction: SIMD3<Double>,
                                  geometry: CADInterferenceMeshGeometry) -> Bool? {
        let scale = max(geometry.bounds.diagonal, 1)
        let eps = max(1e-9, scale * 1e-10)
        var hits: [Double] = []
        hits.reserveCapacity(16)
        for triangle in 0..<geometry.triangleCount {
            let tri = geometry.triangle(triangle)
            if let t = rayTriangle(point: point, direction: direction, triangle: tri,
                                   epsilon: eps), t > eps {
                hits.append(t)
            }
        }
        guard !hits.isEmpty else { return false }
        hits.sort()
        var unique = 0
        var previous = -Double.infinity
        let merge = max(1e-9, scale * 1e-9)
        for hit in hits {
            if hit - previous > merge {
                unique += 1
                previous = hit
            }
        }
        return unique % 2 == 1
    }

    // MARK: Triangles

    /// Actual self-contact beyond a shared mesh vertex/edge. Uses the same
    /// segment/triangle predicates as assembly inspection; normal adjacent
    /// facets are not counted as intersecting merely because they touch.
    static func selfIntersection(
        _ a: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
        _ b: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>), tolerance: Double
    ) -> Bool {
        let ap = [a.0, a.1, a.2], bp = [b.0, b.1, b.2]
        let na = simd_cross(a.1 - a.0, a.2 - a.0), nb = simd_cross(b.1 - b.0, b.2 - b.0)
        guard simd_length(na) > 1e-18, simd_length(nb) > 1e-18 else { return false }
        let normal = simd_normalize(na)
        if simd_length(simd_cross(normal, simd_normalize(nb))) < 1e-10 {
            guard abs(simd_dot(b.0 - a.0, normal)) <= tolerance else { return false }
            var dropped = 0
            for axis in 1..<3 where abs(normal[axis]) > abs(normal[dropped]) { dropped = axis }
            let keep = [0, 1, 2].filter { $0 != dropped }
            let aa = ap.map { SIMD2($0[keep[0]], $0[keep[1]]) }
            let bb = bp.map { SIMD2($0[keep[0]], $0[keep[1]]) }
            // Strict separating-axis overlap rejects mere shared boundaries
            // but catches duplicate triangles and overlap next to a shared edge.
            for points in [aa, bb] {
                for i in 0..<3 {
                    let edge = points[(i + 1) % 3] - points[i]
                    guard simd_length(edge) > 1e-18 else { return false }
                    let axis = simd_normalize(SIMD2(-edge.y, edge.x))
                    let av = aa.map { simd_dot($0, axis) }, bv = bb.map { simd_dot($0, axis) }
                    if min(av.max()!, bv.max()!) - max(av.min()!, bv.min()!) <= tolerance { return false }
                }
            }
            return true
        }
        let shared = ap.filter { p in bp.contains { simd_length(p - $0) <= tolerance } }
        let longestEdge = (0..<3).map { max(simd_length(ap[($0 + 1) % 3] - ap[$0]),
                                             simd_length(bp[($0 + 1) % 3] - bp[$0])) }.max() ?? 1
        let relativeTolerance = max(1e-12, min(1e-8, tolerance / max(longestEdge, 1e-12)))
        func isSharedBoundary(_ point: SIMD3<Double>) -> Bool {
            if shared.contains(where: { simd_length(point - $0) <= tolerance }) { return true }
            if shared.count >= 2 {
                let delta = shared[1] - shared[0], length = simd_length_squared(delta)
                if length > 0 {
                    let t = max(0, min(1, simd_dot(point - shared[0], delta) / length))
                    return simd_length(point - shared[0] - delta * t) <= tolerance
                }
            }
            return false
        }
        for i in 0..<3 {
            if let hit = segmentTriangle(ap[i], ap[(i + 1) % 3], bp, epsilon: relativeTolerance),
               !isSharedBoundary(hit.point) { return true }
            if let hit = segmentTriangle(bp[i], bp[(i + 1) % 3], ap, epsilon: relativeTolerance),
               !isSharedBoundary(hit.point) { return true }
        }
        return false
    }

    private struct TriangleDistance {
        var distanceSquared: Double
        var pointA: SIMD3<Double>
        var pointB: SIMD3<Double>
    }

    private enum TriangleRelation {
        case none
        case touching
        case crossing
    }

    private static func triangleDistance(
        _ a: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
        _ b: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
    ) -> TriangleDistance {
        let aPoints = [a.0, a.1, a.2]
        let bPoints = [b.0, b.1, b.2]

        // Feature-to-feature distances alone miss an edge that passes through
        // the interior of the other triangle: no vertex is closest, but the
        // sets touch. Test the segment/triangle intersection explicitly.
        for index in 0..<3 {
            let a0 = aPoints[index]
            let a1 = aPoints[(index + 1) % 3]
            if let hit = segmentTriangle(a0, a1, bPoints, epsilon: 1e-9) {
                return TriangleDistance(distanceSquared: 0,
                                        pointA: hit.point, pointB: hit.point)
            }
            let b0 = bPoints[index]
            let b1 = bPoints[(index + 1) % 3]
            if let hit = segmentTriangle(b0, b1, aPoints, epsilon: 1e-9) {
                return TriangleDistance(distanceSquared: 0,
                                        pointA: hit.point, pointB: hit.point)
            }
        }

        var best = Double.infinity
        var bestA = a.0
        var bestB = b.0

        func consider(_ pa: SIMD3<Double>, _ pb: SIMD3<Double>) {
            let d = simd_length_squared(pa - pb)
            if d < best {
                best = d
                bestA = pa
                bestB = pb
            }
        }

        for indexA in 0..<3 {
            let a0 = aPoints[indexA]
            let a1 = aPoints[(indexA + 1) % 3]
            for indexB in 0..<3 {
                let b0 = bPoints[indexB]
                let b1 = bPoints[(indexB + 1) % 3]
                let pair = closestSegmentSegment(a0, a1, b0, b1)
                consider(pair.0, pair.1)
                if best <= 0 { break }
            }
            if best <= 0 { break }
        }
        if best > 0 {
            for point in aPoints {
                let closest = closestPointOnTriangle(point, b.0, b.1, b.2)
                consider(point, closest)
            }
            for point in bPoints {
                let closest = closestPointOnTriangle(point, a.0, a.1, a.2)
                consider(closest, point)
            }
        }
        return TriangleDistance(distanceSquared: max(0, best), pointA: bestA, pointB: bestB)
    }

    /// Closest points between two finite segments (Ericson, Real-Time
    /// Collision Detection §5.1.9), with explicit degenerate handling.
    private static func closestSegmentSegment(
        _ p1: SIMD3<Double>, _ q1: SIMD3<Double>,
        _ p2: SIMD3<Double>, _ q2: SIMD3<Double>
    ) -> (SIMD3<Double>, SIMD3<Double>) {
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = simd_dot(d1, d1)
        let e = simd_dot(d2, d2)
        let f = simd_dot(d2, r)
        let eps = 1e-24

        if a <= eps && e <= eps { return (p1, p2) }
        if a <= eps {
            let t = clamp(f / e, 0, 1)
            return (p1, p2 + d2 * t)
        }
        if e <= eps {
            let s = clamp(-simd_dot(d1, r) / a, 0, 1)
            return (p1 + d1 * s, p2)
        }

        let c = simd_dot(d1, r)
        let b = simd_dot(d1, d2)
        let denominator = a * e - b * b
        var s = denominator > eps ? clamp((b * f - c * e) / denominator, 0, 1) : 0
        var t = (b * s + f) / e
        if t < 0 {
            t = 0
            s = clamp(-c / a, 0, 1)
        } else if t > 1 {
            t = 1
            s = clamp((b - c) / a, 0, 1)
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    // Shared with simplification inspection; the BVH and distance predicate
    // remain the same geometry used by interference queries.
    static func closestPointOnTriangle(
        _ point: SIMD3<Double>,
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>
    ) -> SIMD3<Double> {
        let ab = b - a
        let ac = c - a
        let normal = simd_cross(ab, ac)
        if simd_length_squared(normal) <= 1e-24 {
            // Degenerate triangle: closest point on its longest edge or vertex.
            let candidates = [
                closestPointOnSegment(point, a, b),
                closestPointOnSegment(point, b, c),
                closestPointOnSegment(point, c, a),
            ]
            return candidates.min {
                simd_length_squared(point - $0) < simd_length_squared(point - $1)
            } ?? a
        }
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / max(d1 - d3, 1e-30)
            return a + ab * clamp(v, 0, 1)
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / max(d2 - d6, 1e-30)
            return a + ac * clamp(w, 0, 1)
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / max((d4 - d3) + (d5 - d6), 1e-30)
            return b + (c - b) * clamp(w, 0, 1)
        }

        let denominator = 1 / max(va + vb + vc, 1e-30)
        let v = vb * denominator
        let w = vc * denominator
        return a + ab * v + ac * w
    }

    private static func closestPointOnSegment(
        _ point: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>
    ) -> SIMD3<Double> {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 1e-24 else { return a }
        let t = clamp(simd_dot(point - a, ab) / lengthSquared, 0, 1)
        return a + ab * t
    }

    private static func triangleRelation(
        _ a: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
        _ b: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
        tolerance: Double
    ) -> TriangleRelation {
        let aPoints = [a.0, a.1, a.2]
        let bPoints = [b.0, b.1, b.2]
        let normalA = simd_cross(a.1 - a.0, a.2 - a.0)
        let normalB = simd_cross(b.1 - b.0, b.2 - b.0)
        let areaA = simd_length(normalA)
        let areaB = simd_length(normalB)
        guard areaA > 1e-18, areaB > 1e-18 else { return .touching }

        let unitA = normalA / areaA
        let unitB = normalB / areaB
        let parallel = simd_length(simd_cross(unitA, unitB)) < 1e-10
        if parallel {
            let planeDistance = abs(simd_dot(b.0 - a.0, unitA))
            if planeDistance <= max(tolerance, 1e-9) {
                return coplanarTriangleRelation(aPoints, bPoints, normal: unitA,
                                                tolerance: max(tolerance, 1e-9))
            }
            return .none
        }

        // Both planes straddled means the triangles cross transversally even
        // when the intersection segment happens to lie on a triangulation seam
        // (the common, exact-alignment case for two boxes). Restricting this
        // test to a strict two-sided straddle keeps an edge/vertex touch, where
        // one side sits at distance zero, in the contact class.
        let planeEpsilon = max(tolerance, 1e-9)
        let bDistances = bPoints.map { simd_dot($0 - a.0, unitA) }
        let aDistances = aPoints.map { simd_dot($0 - b.0, unitB) }
        let bStraddles = (bDistances.min() ?? 0) < -planeEpsilon
            && (bDistances.max() ?? 0) > planeEpsilon
        let aStraddles = (aDistances.min() ?? 0) < -planeEpsilon
            && (aDistances.max() ?? 0) > planeEpsilon
        if aStraddles && bStraddles { return .crossing }

        var touching = false
        for index in 0..<3 {
            let a0 = aPoints[index]
            let a1 = aPoints[(index + 1) % 3]
            if segmentTriangle(a0, a1, bPoints, epsilon: planeEpsilon) != nil {
                touching = true
            }
            let b0 = bPoints[index]
            let b1 = bPoints[(index + 1) % 3]
            if segmentTriangle(b0, b1, aPoints, epsilon: planeEpsilon) != nil {
                touching = true
            }
        }
        return touching ? .touching : .none
    }

    private struct SegmentHit {
        var point: SIMD3<Double>
        var interior: Bool
    }

    private static func segmentTriangle(
        _ start: SIMD3<Double>, _ end: SIMD3<Double>,
        _ triangle: [SIMD3<Double>],
        epsilon: Double
    ) -> SegmentHit? {
        let a = triangle[0]
        let b = triangle[1]
        let c = triangle[2]
        let direction = end - start
        let edge1 = b - a
        let edge2 = c - a
        let pvec = simd_cross(direction, edge2)
        let det = simd_dot(edge1, pvec)
        guard abs(det) > 1e-20 else { return nil }
        let inverse = 1 / det
        let tvec = start - a
        let u = simd_dot(tvec, pvec) * inverse
        guard u >= -epsilon && u <= 1 + epsilon else { return nil }
        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * inverse
        guard v >= -epsilon && u + v <= 1 + epsilon else { return nil }
        let t = simd_dot(edge2, qvec) * inverse
        guard t >= -epsilon && t <= 1 + epsilon else { return nil }
        let boundary = u <= epsilon || v <= epsilon || u + v >= 1 - epsilon
            || t <= epsilon || t >= 1 - epsilon
        return SegmentHit(point: start + direction * clamp(t, 0, 1), interior: !boundary)
    }

    private static func coplanarTriangleRelation(
        _ a: [SIMD3<Double>], _ b: [SIMD3<Double>],
        normal: SIMD3<Double>, tolerance: Double
    ) -> TriangleRelation {
        var axis = 0
        let absolute = simd_abs(normal)
        if absolute.y > absolute[axis] { axis = 1 }
        if absolute.z > absolute[axis] { axis = 2 }
        let keep: [Int] = axis == 0 ? [1, 2] : (axis == 1 ? [0, 2] : [0, 1])

        func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
            SIMD2(point[keep[0]], point[keep[1]])
        }
        let a2 = a.map(project)
        let b2 = b.map(project)

        var axes: [SIMD2<Double>] = []
        for points in [a2, b2] {
            for index in 0..<3 {
                let p = points[index]
                let q = points[(index + 1) % 3]
                let edge = q - p
                axes.append(SIMD2(-edge.y, edge.x))
            }
        }

        var sawAxis = false
        for axis in axes {
            let length = simd_length(axis)
            guard length > 1e-18 else { continue }
            sawAxis = true
            let unit = axis / length
            let aValues = a2.map { simd_dot($0, unit) }
            let bValues = b2.map { simd_dot($0, unit) }
            let aMin = aValues.min() ?? 0
            let aMax = aValues.max() ?? 0
            let bMin = bValues.min() ?? 0
            let bMax = bValues.max() ?? 0
            let overlap = min(aMax, bMax) - max(aMin, bMin)
            if overlap < -tolerance { return .none }
        }
        return sawAxis ? .touching : .none
    }

    private static func rayTriangle(point: SIMD3<Double>, direction: SIMD3<Double>,
                                    triangle: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>),
                                    epsilon: Double) -> Double? {
        let edge1 = triangle.1 - triangle.0
        let edge2 = triangle.2 - triangle.0
        let pvec = simd_cross(direction, edge2)
        let det = simd_dot(edge1, pvec)
        guard abs(det) > 1e-20 else { return nil }
        let inverse = 1 / det
        let tvec = point - triangle.0
        let u = simd_dot(tvec, pvec) * inverse
        guard u >= -epsilon && u <= 1 + epsilon else { return nil }
        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * inverse
        guard v >= -epsilon && u + v <= 1 + epsilon else { return nil }
        return simd_dot(edge2, qvec) * inverse
    }

    // MARK: Precision

    private static func precisionMM(a: CADInterferencePlacedMesh,
                                     b: CADInterferencePlacedMesh) -> Double {
        let vertexA = max(1, a.geometry.bounds.maxAbsCoordinate)
            * a.placement.scale * floatEpsilon
        let vertexB = max(1, b.geometry.bounds.maxAbsCoordinate)
            * b.placement.scale * floatEpsilon
        let numeric = max(a.geometry.bounds.diagonal * a.placement.scale,
                          b.geometry.bounds.diagonal * b.placement.scale) * numericEpsilon
        return max(vertexA, max(vertexB, numeric))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

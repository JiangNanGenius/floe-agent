// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A node of a tetrahedral mesh. Position in millimetres.
public struct MeshNode: Codable, Sendable, Equatable {
    public var position: Vector3
    public init(_ position: Vector3) { self.position = position }
}

/// A 4-node tetrahedron referencing mesh nodes by 0-based index.
public struct Tetrahedron: Codable, Sendable, Equatable {
    /// Node indices (n0, n1, n2, n3). Must be distinct and in range.
    /// Orientation convention: the signed volume computed from
    /// (n1-n0, n2-n0, n3-n0) must be positive.
    public var nodes: [Int]
    public init(_ n0: Int, _ n1: Int, _ n2: Int, _ n3: Int) {
        self.nodes = [n0, n1, n2, n3]
    }
}

/// Budgets applied to a mesh and to the assembled systems.
public struct EngineeringBudget: Codable, Sendable, Equatable {
    public var maxNodes: Int
    public var maxElements: Int
    /// Cap on stored off-diagonal nonzeros of one assembled sparse matrix.
    public var maxNonzeros: Int
    /// Cap on preconditioned CG iterations per solve.
    public var maxIterations: Int
    /// Wall-clock budget in seconds, checked per iteration and per element batch.
    public var maxWallSeconds: Double
    /// Soft cap on estimated solver working memory in bytes.
    public var maxEstimatedBytes: Int

    public init(maxNodes: Int = 100_000, maxElements: Int = 200_000,
                maxNonzeros: Int = 20_000_000, maxIterations: Int = 20_000,
                maxWallSeconds: Double = 60, maxEstimatedBytes: Int = 1 << 30) {
        self.maxNodes = maxNodes
        self.maxElements = maxElements
        self.maxNonzeros = maxNonzeros
        self.maxIterations = maxIterations
        self.maxWallSeconds = maxWallSeconds
        self.maxEstimatedBytes = maxEstimatedBytes
    }

    public func validate() throws {
        guard maxNodes > 0, maxElements > 0, maxNonzeros > 0, maxIterations > 0 else {
            throw EngineeringError.invalidInput("budgets must be positive")
        }
        guard maxWallSeconds.isFinite, maxWallSeconds > 0 else {
            throw EngineeringError.invalidInput("maxWallSeconds must be finite and > 0")
        }
        guard maxEstimatedBytes > 0 else {
            throw EngineeringError.invalidInput("maxEstimatedBytes must be positive")
        }
    }
}

/// Numerical tolerances for solves and balance checks.
public struct EngineeringTolerance: Codable, Sendable, Equatable {
    /// Relative residual tolerance for CG: ||r|| <= max(relative * ||b||, absoluteFloor).
    public var relativeResidual: Double
    /// Absolute residual floor (N for structural, W-equivalent for thermal).
    public var absoluteResidualFloor: Double
    /// Relative tolerance for the thermal energy-balance report.
    public var energyBalance: Double

    public init(relativeResidual: Double = 1e-8, absoluteResidualFloor: Double = 1e-6,
                energyBalance: Double = 1e-6) {
        self.relativeResidual = relativeResidual
        self.absoluteResidualFloor = absoluteResidualFloor
        self.energyBalance = energyBalance
    }

    public func validate() throws {
        guard relativeResidual.isFinite, relativeResidual > 0, relativeResidual < 1 else {
            throw EngineeringError.invalidInput("relativeResidual must be finite and in (0, 1)")
        }
        guard absoluteResidualFloor.isFinite, absoluteResidualFloor > 0 else {
            throw EngineeringError.invalidInput("absoluteResidualFloor must be finite and > 0")
        }
        guard energyBalance.isFinite, energyBalance > 0 else {
            throw EngineeringError.invalidInput("energyBalance must be finite and > 0")
        }
    }
}

/// Per-element derived geometry of a validated tetrahedron: signed volume, shape
/// function gradients dN/dx, and outward face data for traction/flux loads.
public struct TetraGeometry: Sendable, Equatable {
    /// 6 * signed volume = det of the Jacobian; positive for valid orientation.
    public let jacobianDeterminant: Double
    public let volume: Double
    /// dN_i/dx for i in 0...3 (index 0 corresponds to node n0).
    public let gradients: [Vector3]
    /// Face f is opposite node f. `faceArea[f]` and `outwardNormal[f]` describe it.
    public let faceArea: [Double]
    public let outwardNormal: [Vector3]
}

/// A mesh validated for analysis. Construction is deterministic and throws
/// `.invalidMesh`/`.budgetExceeded` on any contract violation.
public struct ValidatedTetraMesh: Sendable {
    public let nodes: [MeshNode]
    public let elements: [Tetrahedron]
    public let geometry: [TetraGeometry]
    public let totalVolume: Double

    /// Validates the raw mesh, computing per-element geometry.
    /// - Parameters:
    ///   - minimumSignedVolume: rejects tets whose signed volume is below this
    ///     (degenerate). Default 1e-12 mm^3.
    public init(nodes: [MeshNode], elements: [Tetrahedron],
                budget: EngineeringBudget, minimumSignedVolume: Double = 1e-12) throws {
        try budget.validate()
        guard !nodes.isEmpty else { throw EngineeringError.invalidMesh("mesh has no nodes") }
        guard !elements.isEmpty else { throw EngineeringError.invalidMesh("mesh has no elements") }
        guard nodes.count <= budget.maxNodes else {
            throw EngineeringError.budgetExceeded("nodes \(nodes.count) exceed budget \(budget.maxNodes)")
        }
        guard elements.count <= budget.maxElements else {
            throw EngineeringError.budgetExceeded("elements \(elements.count) exceed budget \(budget.maxElements)")
        }
        guard minimumSignedVolume.isFinite, minimumSignedVolume > 0 else {
            throw EngineeringError.invalidInput("minimumSignedVolume must be finite and > 0")
        }
        for (i, n) in nodes.enumerated() {
            guard n.position.isFinite, n.position.magnitude <= 1e9 else {
                throw EngineeringError.invalidMesh("node \(i) position is not finite or is unreasonably large")
            }
        }
        var geoms: [TetraGeometry] = []
        geoms.reserveCapacity(elements.count)
        var total = 0.0
        for (e, tet) in elements.enumerated() {
            guard tet.nodes.count == 4 else {
                throw EngineeringError.invalidMesh("element \(e) must reference exactly 4 nodes")
            }
            let idx = tet.nodes
            for j in 0..<4 {
                guard idx[j] >= 0, idx[j] < nodes.count else {
                    throw EngineeringError.invalidMesh("element \(e) references node \(idx[j]) out of range 0..<\(nodes.count)")
                }
                for k in (j + 1)..<4 where idx[j] == idx[k] {
                    throw EngineeringError.invalidMesh("element \(e) repeats node index \(idx[j])")
                }
            }
            let p = [nodes[idx[0]].position, nodes[idx[1]].position,
                     nodes[idx[2]].position, nodes[idx[3]].position]
            let a = p[1] - p[0], b = p[2] - p[0], c = p[3] - p[0]
            var det = 0.0
            guard let inv = Mat3.inverse(columns: a, b, c, det: &det), det.isFinite else {
                throw EngineeringError.invalidMesh("element \(e) has a singular Jacobian (coincident/coplanar nodes)")
            }
            let signedVolume = det / 6.0
            guard signedVolume > minimumSignedVolume else {
                if signedVolume <= 0 {
                    throw EngineeringError.invalidMesh("element \(e) is inverted or degenerate: signed volume \(signedVolume) mm^3 (expected positive; fix node ordering)")
                }
                throw EngineeringError.invalidMesh("element \(e) is degenerate: signed volume \(signedVolume) mm^3 below minimum \(minimumSignedVolume)")
            }
            // dN/dx: rows of J^-1 give gradients of shape functions N1..N3; N0 = -sum.
            let g1 = Mat3.row(inv, 0), g2 = Mat3.row(inv, 1), g3 = Mat3.row(inv, 2)
            let g0 = (g1 + g2 + g3) * -1.0
            let gradients = [g0, g1, g2, g3]
            // Faces opposite each node; outward normal verified against the tet centre.
            var faceArea = [Double](repeating: 0, count: 4)
            var outward = [Vector3](repeating: .zero, count: 4)
            for f in 0..<4 {
                var others: [Int] = []
                for j in 0..<4 where j != f { others.append(j) }
                others.sort()
                let v0 = p[others[0]], v1 = p[others[1]], v2 = p[others[2]]
                var areaVec = (v1 - v0).cross(v2 - v0) * 0.5
                let faceCentroid = ((v0 + v1) + v2) * (1.0 / 3.0)
                // Outward = away from the opposite node.
                if areaVec.dot(p[f] - faceCentroid) > 0 { areaVec = areaVec * -1.0 }
                let area = areaVec.magnitude
                guard area > 0, areaVec.isFinite else {
                    throw EngineeringError.invalidMesh("element \(e) face \(f) has zero area")
                }
                faceArea[f] = area
                outward[f] = areaVec * (1.0 / area)
            }
            geoms.append(TetraGeometry(jacobianDeterminant: det, volume: signedVolume,
                                       gradients: gradients, faceArea: faceArea, outwardNormal: outward))
            total += signedVolume
        }
        self.nodes = nodes
        self.elements = elements
        self.geometry = geoms
        self.totalVolume = total
    }

    /// Distinct node pairs sharing at least one element edge; used by
    /// manufacturability checks. Deterministic order.
    public func elementEdges() -> [(Int, Int)] {
        var seen = Set<Int>()
        var edges: [(Int, Int)] = []
        for tet in elements {
            let n = tet.nodes
            for i in 0..<4 {
                for j in (i + 1)..<4 {
                    let key = min(n[i], n[j]) * 1_000_000 + max(n[i], n[j])
                    if seen.insert(key).inserted {
                        edges.append((min(n[i], n[j]), max(n[i], n[j])))
                    }
                }
            }
        }
        edges.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return edges
    }
}

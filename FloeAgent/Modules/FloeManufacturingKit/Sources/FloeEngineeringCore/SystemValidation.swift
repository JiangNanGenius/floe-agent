// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Load-independent support validation for the reduced (free-DOF) systems.
///
/// These checks run before any CG iteration and do not depend on the right-hand
/// side: a zero load or an unexcited rigid mode can never produce a vacuous
/// "converged" answer, because singularity is decided by the constrained
/// topology and stiffness alone.
enum SystemValidation {
    /// Union-find over mesh elements; two elements share a component when they
    /// share a node.
    static func components(elementNodes: [[Int]], nodeCount: Int) -> [[Int]] {
        var parent = [Int](0..<elementNodes.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var firstElementOfNode = [Int?](repeating: nil, count: nodeCount)
        for (e, nodes) in elementNodes.enumerated() {
            for n in nodes {
                if let other = firstElementOfNode[n] { union(e, other) }
                else { firstElementOfNode[n] = e }
            }
        }
        var buckets: [Int: [Int]] = [:]
        for e in 0..<elementNodes.count { buckets[find(e), default: []].append(e) }
        return buckets.values.sorted { $0[0] < $1[0] }
    }

    /// Every connected component of the mesh must be anchored by at least one
    /// supported node; otherwise that component floats free and the reduced
    /// system is singular regardless of loads.
    static func requireSupportInEveryComponent(elementNodes: [[Int]], nodeCount: Int,
                                               isSupported: (Int) -> Bool, kind: String) throws {
        let comps = components(elementNodes: elementNodes, nodeCount: nodeCount)
        for comp in comps {
            let supported = comp.contains { e in
                elementNodes[e].contains(where: isSupported)
            }
            guard supported else {
                throw EngineeringError.singular("mesh component of \(comp.count) element(s) (first element \(comp[0])) has no supported nodes: \(kind) problem is singular independent of loads")
            }
        }
    }

    /// Diagonal of the reduced matrix must be finite and positive: a zero entry
    /// means a DOF with no stiffness (isolated node or unsupported component).
    static func requirePositiveDiagonal(_ diag: [Double], label: String) throws {
        for (i, d) in diag.enumerated() {
            guard d.isFinite, d > 0 else {
                throw EngineeringError.singular("\(label): zero or negative reduced stiffness at \(label) index \(i) (value \(d)) — unsupported DOF or invalid support set")
            }
        }
    }

    /// Working-memory estimate for one assembled symmetric matrix.
    static func estimatedBytes(diagCount: Int, offDiagonalNonzeros: Int) -> Int {
        // diag: Double x n; rowStart: Int x (n+1); column: Int x nnz; value: Double x nnz
        diagCount * 8 + (diagCount + 1) * 8 + offDiagonalNonzeros * (8 + 8)
    }

    static func requireMemoryBudget(diagCount: Int, offDiagonalNonzeros: Int,
                                    budget: EngineeringBudget, label: String) throws {
        let bytes = estimatedBytes(diagCount: diagCount, offDiagonalNonzeros: offDiagonalNonzeros)
        guard bytes <= budget.maxEstimatedBytes else {
            throw EngineeringError.budgetExceeded("\(label) estimated memory \(bytes) bytes exceeds budget \(budget.maxEstimatedBytes)")
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Symmetric sparse matrix in compressed-row storage of the upper triangle
/// (diagonal stored separately). Values accumulate additively during assembly.
struct SymmetricSparseMatrix: Sendable {
    let size: Int
    var diag: [Double]
    var rowStart: [Int]
    var column: [Int]
    var value: [Double]

    /// Assembles a dense square contribution block into the sparse structure.
    mutating func addBlock(_ dense: [Double], indices: [Int]) {
        for (li, gi) in indices.enumerated() {
            diag[gi] += dense[li * indices.count + li]
            for (lj, gj) in indices.enumerated() where gj > gi {
                var lo = rowStart[gi], hi = rowStart[gi + 1]
                // Binary search column index.
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if column[mid] < gj { lo = mid + 1 } else { hi = mid }
                }
                if lo < rowStart[gi + 1], column[lo] == gj {
                    value[lo] += dense[li * indices.count + lj]
                }
            }
        }
    }

    /// y = A x exploiting symmetry (upper triangle stored).
    func multiply(_ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: size)
        for i in 0..<size {
            var s = diag[i] * x[i]
            for k in rowStart[i]..<rowStart[i + 1] {
                let j = column[k]
                s += value[k] * x[j]
                y[j] += value[k] * x[i]
            }
            y[i] += s
        }
        return y
    }
}

/// Builds the sparsity pattern and returns an empty matrix ready for assembly.
/// Deterministic: column indices per row are sorted ascending.
enum SparseAssembler {
    static func makeMatrix(size: Int, blocks: [[Int]]) -> SymmetricSparseMatrix {
        var rowSets = [Set<Int>](repeating: [], count: size)
        for block in blocks {
            for gi in block {
                for gj in block where gj > gi {
                    rowSets[gi].insert(gj)
                }
            }
        }
        var rowStart = [Int](repeating: 0, count: size + 1)
        for i in 0..<size {
            rowStart[i + 1] = rowStart[i] + rowSets[i].count
        }
        var column = [Int](repeating: 0, count: rowStart[size])
        for i in 0..<size {
            let sorted = rowSets[i].sorted()
            for (k, j) in sorted.enumerated() {
                column[rowStart[i] + k] = j
            }
        }
        return SymmetricSparseMatrix(size: size,
                                     diag: [Double](repeating: 0, count: size),
                                     rowStart: rowStart, column: column,
                                     value: [Double](repeating: 0, count: column.count))
    }
}

/// Preconditioned conjugate gradient for SPD systems with a diagonal (Jacobi)
/// preconditioner. Convergence is judged on the residual norm, never on iteration
/// count alone.
enum ConjugateGradientSolver {
    struct Outcome: Sendable {
        var solution: [Double]
        var relativeResidual: Double
        var iterations: Int
    }

    /// Solves A x = b. Throws `.singular` on non-positive pivots (rigid modes /
    /// invalid supports), `.cancelled`, `.budgetExceeded` on iteration or wall time,
    /// `.illConditioned` when the requested residual is not reached.
    static func solve(_ a: SymmetricSparseMatrix, b: [Double],
                      tolerance: EngineeringTolerance, budget: EngineeringBudget,
                      control: EngineeringSolveControl) throws -> Outcome {
        let n = a.size
        let normB = (b.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
        let threshold = max(tolerance.relativeResidual * normB, tolerance.absoluteResidualFloor)
        var x = [Double](repeating: 0, count: n)
        if normB <= threshold {
            // The zero iterate satisfies the absolute criterion for tiny RHS.
            // Keep its actual relative residual; do not label it zero unless
            // the load is exactly zero. The caller already certified SPD.
            return Outcome(solution: x, relativeResidual: normB == 0 ? 0 : 1, iterations: 0)
        }
        // Jacobi preconditioner; a zero diagonal means an unconstrained/rigid DOF.
        var precond = [Double](repeating: 0, count: n)
        for i in 0..<n {
            guard a.diag[i].isFinite, a.diag[i] > 0 else {
                throw EngineeringError.singular("zero or negative stiffness at DOF \(i): rigid body mode or invalid support set")
            }
            precond[i] = 1.0 / a.diag[i]
        }
        var r = b
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n { z[i] = r[i] * precond[i] }
        var p = z
        var rz = 0.0
        for i in 0..<n { rz += r[i] * z[i] }
        let start = Date()
        var iterations = 0
        while true {
            if iterations > 0 {
                let res = (r.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
                if res <= threshold {
                    let ax = a.multiply(x)
                    let actual = zip(b,ax).map(-)
                    let actualNorm = actual.reduce(0.0) { $0+$1*$1 }.squareRoot()
                    guard actualNorm <= threshold else {
                        throw EngineeringError.illConditioned("CG recursive residual met tolerance but true residual \(actualNorm) exceeds \(threshold)")
                    }
                    return Outcome(solution: x, relativeResidual: actualNorm / normB, iterations: iterations)
                }
            }
            guard iterations < budget.maxIterations else {
                let res = (r.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
                throw EngineeringError.illConditioned("CG did not converge: \(iterations) iterations, relative residual \(res / normB) above tolerance \(tolerance.relativeResidual) — system likely ill-conditioned or under-constrained")
            }
            try control.checkCancelled()
            if Date().timeIntervalSince(start) > budget.maxWallSeconds {
                throw EngineeringError.budgetExceeded("CG wall-time budget \(budget.maxWallSeconds)s exceeded after \(iterations) iterations")
            }
            let ap = a.multiply(p)
            var pAp = 0.0, pp = 0.0
            for i in 0..<n { pAp += p[i] * ap[i]; pp += p[i] * p[i] }
            guard pAp.isFinite, pAp > 1e-30 * max(pp, 1e-300) else {
                throw EngineeringError.singular("non-positive curvature p^T A p = \(pAp): system is not positive definite (rigid modes or invalid supports likely)")
            }
            let alpha = rz / pAp
            for i in 0..<n {
                x[i] += alpha * p[i]
                r[i] -= alpha * ap[i]
                z[i] = r[i] * precond[i]
            }
            let rzNew = (0..<n).reduce(0.0) { $0 + r[$1] * z[$1] }
            let beta = rzNew / rz
            rz = rzNew
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
            iterations += 1
        }
    }
}

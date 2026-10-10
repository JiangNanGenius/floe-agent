//
//  Solver.swift
//  openshape3d
//
//  Pure-Swift 2D geometric constraint solver core. A Levenberg–Marquardt
//  least-squares minimiser over a flat Double variable vector, driving a
//  stack of `ConstraintResidual`s to zero. This is the numerical engine
//  behind the `ConstraintSolver` facade; the sketch layer maps entities and
//  dimensions onto residuals and reads solved variables back out.
//
//  Design notes:
//    • Numerical Jacobian via central differences, sparsity-aware (only the
//      constraints touching a variable are re-evaluated for its column).
//    • `fixed` variables are held constant — their Jacobian columns are never
//      formed and their values never move.
//    • Damped normal equations (JᵀJ + λ·diag) Δ = −Jᵀr, solved by Cholesky.
//      λ adapts (down on improvement, up on failure); steps are length-limited
//      and every candidate is guarded so the solver never returns NaN/Inf — a
//      conflicting system settles on the least-squares best fit instead.
//    • Remaining DOF = (#variables − #fixed) − rank(J) at the solution, with
//      the rank taken from the Jacobian's singular values.
//

import Foundation

/// A single scalar-valued (or vector-valued) constraint expressed as residuals
/// that are exactly zero when the constraint is satisfied. Implementations read
/// only their `variableIndices` out of the full variable vector.
nonisolated protocol ConstraintResidual {
    /// Indices into the flat variable vector this constraint reads.
    var variableIndices: [Int] { get }
    /// Residuals: each equals 0 exactly when the constraint is satisfied.
    /// `vars` is the full variable vector; read only your indices.
    func residuals(_ vars: [Double]) -> [Double]
    /// Number of scalar residuals (== `residuals(_:).count`), for sizing.
    var residualCount: Int { get }
}

/// Outcome of a solve: the solved variable vector plus convergence diagnostics.
nonisolated struct SolveResult {
    var variables: [Double]     // solved values
    var converged: Bool
    var residualNorm: Double
    var degreesOfFreedom: Int   // remaining DOF (0 = fully constrained)
    var iterations: Int
}

nonisolated enum ConstraintSolver {

    /// Solves the stacked residual system with Levenberg–Marquardt.
    ///
    /// - Parameters:
    ///   - initial: full variable vector (starting point).
    ///   - fixed: indices held constant (columns removed, values never moved).
    ///   - constraints: residual providers over the shared variable vector.
    ///   - maxIterations: LM iteration cap per attempt (at most one stalled-solve retry).
    ///   - tolerance: convergence threshold on the gradient / relative step.
    ///   - diagonalDamping: normal diagonal scaling; false is the internal isotropic retry.
    /// - Returns: solved variables plus convergence + DOF diagnostics. Never
    ///   returns NaN/Inf; on a conflicting system it returns the best fit found.
    static func solve(initial: [Double],
                      fixed: Set<Int>,
                      constraints: [any ConstraintResidual],
                      maxIterations: Int = 200,
                      tolerance: Double = 1e-9,
                      diagonalDamping: Bool = true) -> SolveResult {
        let n = initial.count

        // Free variable index map (globals that may move).
        var free: [Int] = []
        free.reserveCapacity(n)
        for i in 0..<n where !fixed.contains(i) { free.append(i) }
        let nFree = free.count

        // Residual layout: offsets[c] is the first row of constraint c.
        var offsets = [Int](); offsets.reserveCapacity(constraints.count)
        var m = 0
        for c in constraints {
            offsets.append(m)
            m += max(0, c.residualCount)
        }

        // Trivial cases: nothing to solve.
        if m == 0 {
            return SolveResult(variables: initial, converged: true,
                               residualNorm: 0, degreesOfFreedom: max(0, nFree),
                               iterations: 0)
        }

        // Which constraints depend on each global variable (Jacobian sparsity).
        var affects = [[Int]](repeating: [], count: n)
        for (ci, c) in constraints.enumerated() {
            for vi in c.variableIndices where vi >= 0 && vi < n {
                if affects[vi].last != ci && !affects[vi].contains(ci) {
                    affects[vi].append(ci)
                }
            }
        }

        // Stacked residual vector at x.
        func residualVector(_ x: [Double]) -> [Double] {
            var r = [Double](repeating: 0, count: m)
            for (ci, c) in constraints.enumerated() {
                let rc = c.residuals(x)
                let off = offsets[ci]
                let count = c.residualCount
                var t = 0
                while t < count {
                    r[off + t] = t < rc.count ? rc[t] : 0
                    t += 1
                }
            }
            return r
        }

        func sumSquares(_ v: [Double]) -> Double {
            var s = 0.0
            for e in v { s += e * e }
            return s
        }
        func isFiniteVector(_ v: [Double]) -> Bool {
            for e in v where !e.isFinite { return false }
            return true
        }

        // Dense Jacobian J (row-major m×nFree), sparsity-aware central diff.
        // A single scratch vector is perturbed one coordinate at a time.
        func jacobian(_ x: [Double]) -> [Double] {
            var J = [Double](repeating: 0, count: m * nFree)
            var xw = x
            for f in 0..<nFree {
                let k = free[f]
                let saved = xw[k]
                let h = 1e-7 * max(1.0, abs(saved))
                xw[k] = saved + h
                var plus = [[Double]](repeating: [], count: constraints.count)
                for ci in affects[k] { plus[ci] = constraints[ci].residuals(xw) }
                xw[k] = saved - h
                for ci in affects[k] {
                    let c = constraints[ci]
                    let rm = c.residuals(xw)
                    let rp = plus[ci]
                    let off = offsets[ci]
                    let count = c.residualCount
                    let inv = 1.0 / (2 * h)
                    var t = 0
                    while t < count {
                        let a = t < rp.count ? rp[t] : 0
                        let b = t < rm.count ? rm[t] : 0
                        J[(off + t) * nFree + f] = (a - b) * inv
                        t += 1
                    }
                }
                xw[k] = saved
            }
            return J
        }

        var x = initial
        var r = residualVector(x)
        var cost = sumSquares(r)   // = ‖r‖² (½ factor cancels in comparisons)

        // Guard a NaN/Inf starting point: fall back to zeros-in-place is worse,
        // so just report the (finite-ised) state without moving anything.
        if !isFiniteVector(r) {
            let dof = estimateDOF(jacobian(x), m: m, nFree: nFree)
            return SolveResult(variables: x, converged: false,
                               residualNorm: safeNorm(r),
                               degreesOfFreedom: dof, iterations: 0)
        }

        // Nothing free to move: evaluate DOF and return.
        if nFree == 0 {
            return SolveResult(variables: x, converged: sumSquares(r) <= tolerance * tolerance,
                               residualNorm: r.map { $0 * $0 }.reduce(0, +).squareRoot(),
                               degreesOfFreedom: 0, iterations: 0)
        }

        var lambda = 1e-3
        let lambdaMax = 1e12
        let lambdaMin = 1e-12
        let absFloor = 1e-9
        var converged = false
        var iterations = 0

        for iter in 1...maxIterations {
            iterations = iter
            let J = jacobian(x)

            // g = Jᵀr  and  A = JᵀJ  (nFree×nFree, row-major).
            var g = [Double](repeating: 0, count: nFree)
            var A = [Double](repeating: 0, count: nFree * nFree)
            for row in 0..<m {
                let rr = r[row]
                let base = row * nFree
                for a in 0..<nFree {
                    let ja = J[base + a]
                    if ja == 0 { continue }
                    g[a] += ja * rr
                    let ab = a * nFree
                    for b in a..<nFree {
                        A[ab + b] += ja * J[base + b]
                    }
                }
            }
            // Mirror upper → lower to complete the symmetric matrix.
            for a in 0..<nFree {
                for b in (a + 1)..<nFree {
                    A[b * nFree + a] = A[a * nFree + b]
                }
            }

            // Gradient convergence.
            var gInf = 0.0
            for v in g { gInf = max(gInf, abs(v)) }
            if gInf < tolerance {
                converged = true
                break
            }

            let largestDiagonal = (0..<nFree).map { A[$0 * nFree + $0] }.max() ?? 0
            // Try damped steps, growing λ until one improves (or λ blows up).
            var stepTaken = false
            while lambda <= lambdaMax {
                // Damped matrix: A + positive diagonal → guaranteed SPD.
                var Ad = A
                for i in 0..<nFree {
                    let d = A[i * nFree + i]
                    Ad[i * nFree + i] = d + lambda * ((diagonalDamping ? d : largestDiagonal) + absFloor)
                }
                var neg = g
                for i in 0..<nFree { neg[i] = -neg[i] }

                guard let delta = LinearAlgebra.solveSPD(Ad, neg, n: nFree),
                      isFiniteVector(delta) else {
                    lambda = min(lambda * 10, lambdaMax * 10)
                    if lambda > lambdaMax { break }
                    continue
                }

                // Length-limit the step as a blow-up safety net.
                var stepNorm = 0.0
                for d in delta { stepNorm += d * d }
                stepNorm = stepNorm.squareRoot()
                var scale = 1.0
                var xNorm = 0.0
                for f in 0..<nFree { let v = x[free[f]]; xNorm += v * v }
                xNorm = xNorm.squareRoot()
                let maxStep = 1e3 * (1 + xNorm)
                if stepNorm > maxStep { scale = maxStep / stepNorm }

                var xNew = x
                for f in 0..<nFree { xNew[free[f]] += delta[f] * scale }

                let rNew = residualVector(xNew)
                let costNew = sumSquares(rNew)

                if isFiniteVector(rNew) && costNew < cost {
                    // Accept.
                    x = xNew
                    r = rNew
                    let scaledStep = stepNorm * scale
                    cost = costNew
                    lambda = max(lambda * 0.3, lambdaMin)
                    stepTaken = true
                    if scaledStep < tolerance * (1 + xNorm) {
                        converged = true
                    }
                    break
                } else {
                    // Reject; damp harder.
                    lambda = min(lambda * 10, lambdaMax * 10)
                    if lambda > lambdaMax { break }
                }
            }

            if converged { break }
            if !stepTaken {
                // Could not improve — best fit reached (or stuck). If the
                // gradient is already tiny call it converged.
                converged = gInf < max(tolerance, 1e-7 * (1 + cost.squareRoot()))
                break
            }
        }

        // Final residual norm and DOF at the solution.
        let residualNorm = safeNorm(r)
        let dof = estimateDOF(jacobian(x), m: m, nFree: nFree)

        // Near-axis free geometry can make diagonal preconditioning amplify
        // an almost-zero derivative into a huge transverse step. Preserve all
        // successful solves; only retry a stalled solve from its original state
        // with isotropic LM damping, accepting it only when residual improves.
        if !converged, diagonalDamping {
            let retry = solve(initial: initial, fixed: fixed, constraints: constraints,
                              maxIterations: maxIterations, tolerance: tolerance,
                              diagonalDamping: false)
            if retry.residualNorm < residualNorm {
                return SolveResult(variables: retry.variables, converged: retry.converged,
                                   residualNorm: retry.residualNorm,
                                   degreesOfFreedom: retry.degreesOfFreedom,
                                   iterations: iterations + retry.iterations)
            }
        }

        return SolveResult(variables: x, converged: converged,
                           residualNorm: residualNorm,
                           degreesOfFreedom: dof, iterations: iterations)
    }

    // MARK: - Helpers

    /// 2-norm that never yields NaN (drops non-finite entries).
    private static func safeNorm(_ v: [Double]) -> Double {
        var s = 0.0
        for e in v where e.isFinite { s += e * e }
        return s.squareRoot()
    }

    /// DOF = nFree − rank(J), clamped ≥ 0. Rank from the Jacobian's singular
    /// values (one-sided Jacobi SVD).
    private static func estimateDOF(_ J: [Double], m: Int, nFree: Int) -> Int {
        if nFree == 0 { return 0 }
        if m == 0 { return nFree }
        let sv = LinearAlgebra.singularValues(J, m: m, n: nFree)
        let rank = LinearAlgebra.rank(singularValues: sv)
        return max(0, nFree - rank)
    }
}

//
//  LinearAlgebra.swift
//  openshape3d
//
//  Dense linear-algebra helpers for the 2D constraint solver. The kernels
//  run on Accelerate's LAPACK through the C shim `OS3DLinearAlgebra` (new
//  interface, stable ABI); the pure-Swift routines below them are the
//  FALLBACKS, kept because they are simple and because LAPACK can refuse
//  (a non-convergent SVD, a non-finite input). "Tiny matrices, pure Swift"
//  was the original stance; a 150-line welded sketch has 600 free
//  variables, and its Cholesky and Jacobi SVD in nested Swift loops cost
//  0.9 s per drag tick in Debug (`DragSolveProbe`, 2026-09-02).
//
//  Three primitives the Levenberg–Marquardt core and the DOF analysis need:
//    • Cholesky solve of the damped normal equations (always SPD, so this
//      never hits the non-positive-definite branch in practice).
//    • Singular values of the Jacobian, used only to estimate numeric rank
//      → remaining degrees of freedom.
//    • Symmetric eigen-decomposition of JᵀJ (the null-space analysis).
//

import OCCTShim
import Accelerate // links the framework the C shim calls into
import Foundation

nonisolated enum LinearAlgebra {

    // MARK: - Cholesky solve (SPD)

    /// Solves `A x = b` for a symmetric positive-definite `A` (row-major,
    /// `n`×`n`) via Cholesky factorisation. Returns `nil` if `A` is not
    /// positive-definite (a non-positive pivot appears), which the caller
    /// treats as a failed LM step.
    static func solveSPD(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        if n == 0 { return [] }
        guard A.count == n * n, b.count == n, A.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite)
        else { return nil }
        var x = b
        let ok = A.withUnsafeBufferPointer { a in
            x.withUnsafeMutableBufferPointer { xb in
                os3d_solve_spd(a.baseAddress!, Int32(n), xb.baseAddress!)
            }
        }
        guard ok else { return nil }
        for v in x where !v.isFinite { return nil }
        return x
    }

    /// The pure-Swift Cholesky `solveSPD` used to be; kept as the reference
    /// the LAPACK path is tested against.
    static func solveSPDReference(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
        if n == 0 { return [] }
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i * n + j]
                var k = 0
                while k < j {
                    sum -= L[i * n + k] * L[j * n + k]
                    k += 1
                }
                if i == j {
                    if !(sum > 0) || !sum.isFinite { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    let d = L[j * n + j]
                    if d == 0 || !d.isFinite { return nil }
                    L[i * n + j] = sum / d
                }
            }
        }

        // Forward solve  L y = b.
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            var k = 0
            while k < i {
                sum -= L[i * n + k] * y[k]
                k += 1
            }
            y[i] = sum / L[i * n + i]
        }

        // Back solve  Lᵀ x = y.
        var x = [Double](repeating: 0, count: n)
        var i = n - 1
        while i >= 0 {
            var sum = y[i]
            var k = i + 1
            while k < n {
                sum -= L[k * n + i] * x[k]
                k += 1
            }
            x[i] = sum / L[i * n + i]
            i -= 1
        }

        for v in x where !v.isFinite { return nil }
        return x
    }

    // MARK: - Singular values (one-sided Jacobi SVD)

    /// Singular values of an `m`×`n` matrix (row-major), sorted descending.
    /// The count returned is `n` (one per column); rank-deficient directions
    /// come back as ~0 singular values (LAPACK reports min(m, n) values; the
    /// rest are zero by definition and padded here). Falls back to the
    /// one-sided Jacobi SVD when LAPACK does not converge.
    static func singularValues(_ A: [Double], m: Int, n: Int) -> [Double] {
        if m == 0 || n == 0 { return [] }
        if A.count == m * n, A.allSatisfy(\.isFinite) {
            var s = [Double](repeating: 0, count: min(m, n))
            let ok = A.withUnsafeBufferPointer { a in
                s.withUnsafeMutableBufferPointer { sb in
                    os3d_singular_values(a.baseAddress!, Int32(m), Int32(n), sb.baseAddress!)
                }
            }
            if ok { return s + [Double](repeating: 0, count: n - s.count) }
        }
        return singularValuesReference(A, m: m, n: n)
    }

    /// Eigen-decomposition of a symmetric `n`×`n` matrix (row-major):
    /// eigenvalues ASCENDING and `vectors[k]` the unit eigenvector of
    /// `values[k]`. Falls back to cyclic Jacobi when LAPACK fails.
    static func symmetricEigen(_ A: [Double], n: Int) -> (values: [Double], vectors: [[Double]]) {
        if n == 0 { return ([], []) }
        if A.count == n * n, A.allSatisfy(\.isFinite) {
            var w = [Double](repeating: 0, count: n)
            var v = [Double](repeating: 0, count: n * n)
            let ok = A.withUnsafeBufferPointer { a in
                w.withUnsafeMutableBufferPointer { wb in
                    v.withUnsafeMutableBufferPointer { vb in
                        os3d_symmetric_eigen(a.baseAddress!, Int32(n), wb.baseAddress!, vb.baseAddress!)
                    }
                }
            }
            if ok {
                return (w, (0..<n).map { k in Array(v[(k * n)..<((k + 1) * n)]) })
            }
        }
        return symmetricEigenReference(A, n: n)
    }

    /// Cyclic Jacobi eigen-decomposition (the pre-LAPACK routine, now the
    /// fallback and the test reference). Same contract as `symmetricEigen`.
    static func symmetricEigenReference(_ input: [Double], n: Int) -> (values: [Double], vectors: [[Double]]) {
        guard n > 0 else { return ([], []) }
        var A = input
        var V = [Double](repeating: 0, count: n * n)
        for i in 0..<n { V[i * n + i] = 1 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += A[p * n + q] * A[p * n + q] } }
            if off < 1e-30 { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = A[p * n + q]
                    if abs(apq) < 1e-300 { continue }
                    let tau = (A[q * n + q] - A[p * n + p]) / (2 * apq)
                    let sgn = tau >= 0 ? 1.0 : -1.0
                    let t = sgn / (abs(tau) + (tau * tau + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for i in 0..<n {
                        let aip = A[i * n + p], aiq = A[i * n + q]
                        A[i * n + p] = c * aip - s * aiq
                        A[i * n + q] = s * aip + c * aiq
                    }
                    for j in 0..<n {
                        let apj = A[p * n + j], aqj = A[q * n + j]
                        A[p * n + j] = c * apj - s * aqj
                        A[q * n + j] = s * apj + c * aqj
                    }
                    for i in 0..<n {
                        let vip = V[i * n + p], viq = V[i * n + q]
                        V[i * n + p] = c * vip - s * viq
                        V[i * n + q] = s * vip + c * viq
                    }
                }
            }
        }
        let order = (0..<n).sorted { A[$0 * n + $0] < A[$1 * n + $1] }
        let values = order.map { A[$0 * n + $0] }
        let vectors = order.map { k in (0..<n).map { j in V[j * n + k] } }
        return (values, vectors)
    }

    /// One-sided Jacobi SVD (the pre-LAPACK routine, now the fallback and
    /// the test reference). Same contract as `singularValues`.
    static func singularValuesReference(_ A: [Double], m: Int, n: Int) -> [Double] {
        if m == 0 || n == 0 { return [] }

        // Store columns contiguously: cols[c * m + r].
        var cols = [Double](repeating: 0, count: n * m)
        for r in 0..<m {
            for c in 0..<n {
                cols[c * m + r] = A[r * n + c]
            }
        }

        let tiny = 1e-300
        let maxSweeps = 60
        for _ in 0..<maxSweeps {
            var rotated = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var alpha = 0.0, beta = 0.0, gamma = 0.0
                    let bi = i * m, bj = j * m
                    for r in 0..<m {
                        let ci = cols[bi + r]
                        let cj = cols[bj + r]
                        alpha += ci * ci
                        beta += cj * cj
                        gamma += ci * cj
                    }
                    let denom = (alpha * beta).squareRoot()
                    if denom <= tiny { continue }
                    // Off-diagonal already negligible for this pair.
                    if abs(gamma) <= 1e-15 * denom { continue }

                    let zeta = (beta - alpha) / (2 * gamma)
                    let sign = zeta >= 0 ? 1.0 : -1.0
                    let t = sign / (abs(zeta) + (1 + zeta * zeta).squareRoot())
                    let cs = 1 / (1 + t * t).squareRoot()
                    let sn = cs * t

                    for r in 0..<m {
                        let cik = cols[bi + r]
                        let cjk = cols[bj + r]
                        cols[bi + r] = cs * cik - sn * cjk
                        cols[bj + r] = sn * cik + cs * cjk
                    }
                    rotated = true
                }
            }
            if !rotated { break }
        }

        var sv = [Double](repeating: 0, count: n)
        for c in 0..<n {
            var s = 0.0
            let base = c * m
            for r in 0..<m { s += cols[base + r] * cols[base + r] }
            sv[c] = s.squareRoot()
        }
        sv.sort(by: >)
        return sv
    }

    /// Numeric rank from singular values: counts those above a threshold that
    /// scales with the largest singular value (with a small absolute floor so a
    /// genuinely empty system reports rank 0). `relativeTolerance` defaults are
    /// chosen to sit comfortably above central-difference Jacobian noise
    /// (~1e-7 relative) yet well below the O(1) singular values of independent
    /// constraints.
    static func rank(singularValues sv: [Double],
                     relativeTolerance: Double = 1e-6,
                     absoluteFloor: Double = 1e-9) -> Int {
        guard let sigmaMax = sv.first, sigmaMax > 0 else { return 0 }
        let threshold = max(sigmaMax * relativeTolerance, absoluteFloor)
        var r = 0
        for s in sv where s > threshold { r += 1 }
        return r
    }
}

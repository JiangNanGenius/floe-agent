// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bounded profile (skyline) LDL^T certification of the reduced matrix.
///
/// This is the load-independent SPD proof: by Sylvester's criterion a symmetric
/// matrix is positive definite iff its LDL^T factorization exists with every
/// pivot D(j) > 0. Any unsupported rigid mode, hinge mechanism, disconnected
/// floating component, or arbitrary-point support that leaves a free null mode
/// produces a zero (or negative) pivot — the factorization catches them all,
/// independent of the right-hand side. The factorization is discarded; the
/// certified matrix is then solved by CG.
///
/// Storage is the classical fill-confining row envelope of the lower triangle:
/// row i stores L(i, lo(i)..i-1) where lo(i) is the smallest column index with
/// A(i, lo(i)) != 0. Envelope storage is bounded by the memory budget; meshes
/// whose profile exceeds the budget fail closed with `.budgetExceeded` rather
/// than being silently certified by an incomplete method.
enum LDLCertification {
    struct Outcome: Sendable {
        var minPivot: Double
        var maxPivot: Double
        var profileEntries: Int
    }

    static func certifySPD(_ a: SymmetricSparseMatrix, budget: EngineeringBudget,
                           control: EngineeringSolveControl, start: Date) throws -> Outcome {
        let n = a.size
        if n == 0 { return Outcome(minPivot: 1, maxPivot: 1, profileEntries: 0) }

        // lo(i) = smallest lower-triangle column adjacent to row i, derived from
        // the upper-triangle CSR by transposition (symmetric pattern).
        var lo = [Int](0..<n)
        for i in 0..<n {
            for p in a.rowStart[i]..<a.rowStart[i + 1] {
                lo[a.column[p]] = min(lo[a.column[p]], i)
            }
        }
        var rowOffset = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            rowOffset[i + 1] = rowOffset[i] + (i - lo[i])
        }
        let profile = rowOffset[n]
        try SystemValidation.requireMemoryBudget(diagCount: 2 * n,
                                                 offDiagonalNonzeros: profile,
                                                 budget: budget,
                                                 label: "LDL^T certification profile")
        guard profile < (1 << 62) else {
            throw EngineeringError.budgetExceeded("LDL^T profile too large to index")
        }
        var lstore = [Double](repeating: 0, count: max(profile, 1))
        var d = [Double](repeating: 0, count: n)
        var scale = 0.0
        for i in 0..<n { scale = max(scale, abs(a.diag[i])) }
        guard scale > 0, scale.isFinite else {
            throw EngineeringError.singular("zero or non-finite diagonal scale: matrix is not positive definite")
        }
        var minPivot = Double.greatestFiniteMagnitude
        var maxPivot = 0.0
        for i in 0..<n {
            if i & 0xFF == 0xFF { try control.checkCancelled() }
            if Date().timeIntervalSince(start) > budget.maxWallSeconds {
                throw EngineeringError.budgetExceeded("LDL^T certification wall-time budget \(budget.maxWallSeconds)s exceeded at row \(i)/\(n)")
            }
            let li = lo[i]
            for j in li..<i {
                // s = A(i,j) - sum_{k in max(lo_i, lo_j)..<j} L(i,k) D(k) L(j,k)
                var s = 0.0
                let rowJ = j
                let loj = lo[j]
                let m = max(li, loj)
                // A(i,j) with i>j lives in CSR row j (upper triangle).
                var aij = 0.0
                var p = a.rowStart[rowJ], pEnd = a.rowStart[rowJ + 1]
                while p < pEnd {
                    if a.column[p] == i { aij = a.value[p]; break }
                    if a.column[p] > i { break }
                    p += 1
                }
                s = aij
                for k in m..<j {
                    let lik = lstore[rowOffset[i] + (k - li)]
                    let ljk = lstore[rowOffset[j] + (k - loj)]
                    s -= lik * d[k] * ljk
                }
                let dj = d[j]
                guard dj > scale * 1e-14 else {
                    throw EngineeringError.singular("non-positive pivot D(\(j)) = \(dj) at row \(i): reduced matrix is not positive definite (rigid mode, hinge mechanism, or unsupported component)")
                }
                let lij = s / dj
                lstore[rowOffset[i] + (j - li)] = lij
            }
            var di = a.diag[i]
            for k in li..<i {
                let lik = lstore[rowOffset[i] + (k - li)]
                di -= lik * lik * d[k]
            }
            guard di.isFinite else {
                throw EngineeringError.illConditioned("non-finite pivot at row \(i): numerically unstable factorization")
            }
            if di <= scale * 1e-12 {
                if di <= 0 {
                    throw EngineeringError.singular("pivot D(\(i)) = \(di) <= 0: reduced matrix is not positive definite (unsupported rigid mode or mechanism)")
                }
                throw EngineeringError.singular("near-zero pivot D(\(i)) = \(di) (scale \(scale)): system is numerically singular (unsupported or ill-conditioned supports)")
            }
            d[i] = di
            minPivot = min(minPivot, di)
            maxPivot = max(maxPivot, di)
        }
        return Outcome(minPivot: minPivot, maxPivot: maxPivot, profileEntries: profile)
    }
}

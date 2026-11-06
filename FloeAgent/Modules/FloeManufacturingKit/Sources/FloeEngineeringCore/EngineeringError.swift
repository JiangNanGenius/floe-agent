// SPDX-License-Identifier: MPL-2.0
import Foundation

/// All recoverable failures produced by FloeEngineeringCore.
///
/// The solver never reports success for unsupported geometry, failed convergence,
/// singular systems or exceeded budgets; every such condition surfaces as one of
/// these cases.
public enum EngineeringError: Error, Equatable, Sendable {
    /// Request-level contract violation (missing material property, bad tolerance, ...).
    case invalidInput(String)
    /// Mesh contract violation (out-of-range indices, inverted/degenerate tetrahedron, ...).
    case invalidMesh(String)
    /// Material contract violation (non-positive modulus, nu out of range, missing conductivity).
    case invalidMaterial(String)
    /// The constrained system is singular (rigid body modes, invalid/missing supports,
    /// non-positive-definite reduced stiffness).
    case singular(String)
    /// The system is numerically solvable in principle but did not converge to the
    /// requested residual (ill conditioning, insufficient iteration budget).
    case illConditioned(String)
    /// The requested analysis kind is outside the implemented domain
    /// (see `EngineeringUnsupported` for the explicit ledger).
    case unsupportedAnalysis(String)
    /// A node/element/nonzero/iteration/time/memory budget was exceeded.
    case budgetExceeded(String)
    /// Synchronous cancellation requested via `EngineeringSolveControl.isCancelled`.
    case cancelled
}

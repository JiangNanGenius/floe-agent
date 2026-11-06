// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit ledger of analysis domains this module does NOT implement.
/// Callers building UI or routing must consult this list instead of assuming
/// coverage; `EngineeringError.unsupportedAnalysis` guards the API boundary.
public enum EngineeringUnsupported: String, Codable, Sendable, CaseIterable {
    case plasticity = "plasticity / nonlinear material"
    case largeDeformation = "large deformation / geometric nonlinearity"
    case dynamics = "dynamics / modal / transient"
    case contact = "contact mechanics"
    case buckling = "linearized buckling"
    case thermalStress = "thermomechanical coupling / thermal stress"
    case cfd = "computational fluid dynamics"
    case multiphysics = "full multiphysics"
    case meshFromSurface = "tetrahedral volume meshing from STL/surface input"
    case anisotropicMaterials = "anisotropic / orthotropic constitutive laws"
    case certifiedMaterialData = "certified material allowables"

    /// One-line justification kept next to the entry so product copy can quote it.
    public var note: String {
        switch self {
        case .plasticity: return "linear-elastic constitutive only; no yield surfaces or hardening"
        case .largeDeformation: return "small-strain kinematics only"
        case .dynamics: return "static solves only; no mass matrix or time integration"
        case .contact: return "no contact constraints or gap elements"
        case .buckling: return "no geometric stiffness or eigenvalue solve"
        case .thermalStress: return "thermal and structural solves are separate; no coupling"
        case .cfd: return "no flow solver of any kind"
        case .multiphysics: return "single-physics solves only"
        case .meshFromSurface: return "requires a real volume mesher; FE from STL is not claimed"
        case .anisotropicMaterials: return "isotropic records only; other symmetries are rejected, never approximated"
        case .certifiedMaterialData: return "library values are typicals with provenance, never certified allowables"
        }
    }

    /// Every unimplemented domain, for save/export metadata.
    public static let ledger: [EngineeringUnsupported] = allCases
}

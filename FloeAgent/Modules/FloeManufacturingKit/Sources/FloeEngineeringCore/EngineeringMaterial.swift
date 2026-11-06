// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Constitutive symmetry of a material record.
///
/// Only `.isotropic` is implemented. Anything else is rejected by the solvers with
/// `.invalidMaterial` — the module never silently treats an arbitrary material as
/// isotropic.
public enum MaterialSymmetry: String, Codable, Sendable, CaseIterable {
    case isotropic
    case orthotropic
    case anisotropic
}

/// A single material record with explicit units and provenance.
///
/// All mechanical properties are required for structural analysis except
/// `yieldStrengthMPa` (only needed for factor-of-safety output). Thermal analysis
/// additionally requires `thermalConductivityWPerMMK`.
public struct EngineeringMaterial: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var symmetry: MaterialSymmetry
    /// Elastic modulus E, MPa. Must be finite and > 0.
    public var elasticModulusMPa: Double
    /// Poisson ratio nu, dimensionless. Must be finite and in (-1, 0.5).
    public var poissonRatio: Double
    /// Mass density, kg/mm^3 (e.g. steel ~7.83e-6). Optional; used only for
    /// gravity-style body loads supplied by the caller, not by the solver itself.
    public var massDensityKgPerMM3: Double?
    /// Yield strength, MPa. Optional. When present, factor of safety is reported;
    /// when absent the result carries `factorOfSafety: nil` instead of a bogus value.
    public var yieldStrengthMPa: Double?
    /// Thermal conductivity k, W/(mm·K). Required for thermal analysis.
    public var thermalConductivityWPerMMK: Double?
    /// Human-readable provenance: source document/datasheet and typical-vs-certified
    /// status. Library records are never certified.
    public var provenance: String
    /// Always false for library records; retained so downstream UIs cannot mistake
    /// predevelopment data for certified allowables.
    public var certified: Bool

    public init(id: String, name: String, symmetry: MaterialSymmetry = .isotropic,
                elasticModulusMPa: Double, poissonRatio: Double,
                massDensityKgPerMM3: Double? = nil, yieldStrengthMPa: Double? = nil,
                thermalConductivityWPerMMK: Double? = nil,
                provenance: String, certified: Bool = false) {
        self.id = id
        self.name = name
        self.symmetry = symmetry
        self.elasticModulusMPa = elasticModulusMPa
        self.poissonRatio = poissonRatio
        self.massDensityKgPerMM3 = massDensityKgPerMM3
        self.yieldStrengthMPa = yieldStrengthMPa
        self.thermalConductivityWPerMMK = thermalConductivityWPerMMK
        self.provenance = provenance
        self.certified = certified
    }

    /// Structural validation. Throws `.invalidMaterial` with a specific reason.
    public func validateForStructural() throws {
        guard symmetry == .isotropic else {
            throw EngineeringError.invalidMaterial("material '\(id)' has symmetry '\(symmetry.rawValue)'; only isotropic is implemented")
        }
        guard elasticModulusMPa.isFinite, elasticModulusMPa > 0 else {
            throw EngineeringError.invalidMaterial("material '\(id)': elasticModulusMPa must be finite and > 0")
        }
        guard poissonRatio.isFinite, poissonRatio > -1, poissonRatio < 0.5 else {
            throw EngineeringError.invalidMaterial("material '\(id)': poissonRatio must be finite and in (-1, 0.5)")
        }
        if let yieldStrengthMPa {
            guard yieldStrengthMPa.isFinite, yieldStrengthMPa > 0 else {
                throw EngineeringError.invalidMaterial("material '\(id)': yieldStrengthMPa must be finite and > 0 when present")
            }
        }
    }

    /// Thermal validation. Throws `.invalidMaterial` when conductivity is missing.
    public func validateForThermal() throws {
        try validateForStructural()
        guard let thermalConductivityWPerMMK, thermalConductivityWPerMMK.isFinite, thermalConductivityWPerMMK > 0 else {
            throw EngineeringError.invalidMaterial("material '\(id)': thermalConductivityWPerMMK must be finite and > 0 for thermal analysis")
        }
    }
}

/// Small built-in library of isotropic metal records with explicit provenance.
///
/// Each record names a concrete primary datasheet identity (standard designation
/// plus a public datasheet entry) so Root and users can trace every number.
/// Values are typical published numbers for predevelopment use only: they are
/// NOT certified allowables and must not be presented as such.
public enum MaterialLibrary {
    private static let caveat = ". Typical published values for predevelopment only; NOT certified allowables."

    /// ASTM A36 structural steel.
    /// - Standard: ASTM A36/A36M-19 (UNS K02600).
    /// - Datasheet identities: AZoM "ASTM A36 Mild/Low Carbon Steel" (azom.com,
    ///   ArticleId 6117); MakeItFrom "ASTM A36 (SS400, S275) Structural Carbon
    ///   Steel" (makeitfrom.com).
    /// - E=200 GPa, nu=0.26 (AZoM), Sy=250 MPa (A36/A36M-19 min, <=200 mm),
    ///   k=50 W/(m·K) (AZoM typical for carbon steel).
    public static let structuralSteelA36 = EngineeringMaterial(
        id: "steel-a36", name: "Structural Steel ASTM A36",
        elasticModulusMPa: 200_000, poissonRatio: 0.26,
        massDensityKgPerMM3: 7.83e-6, yieldStrengthMPa: 250,
        thermalConductivityWPerMMK: 50.0e-3,
        provenance: "ASTM A36/A36M-19 (UNS K02600); AZoM ArticleId 6117 'ASTM A36 Mild/Low Carbon Steel'; MakeItFrom 'ASTM A36 (SS400, S275)'. E=200 GPa, nu=0.26, Sy=250 MPa (spec minimum <=200 mm), k=50 W/(m·K)" + caveat)

    /// Aluminum 6061-T6.
    /// - Standard: UNS A96061, AMS 4027 / ASTM B209 product forms.
    /// - Datasheet identities: MatWeb "Aluminum 6061-T6, 6061-T651"
    ///   (matweb.com, ASM/MatWeb data sheet); 6061-T6 material notes datasheet
    ///   (Aluminum Association 'AA; Typical' annotations).
    /// - E=68.9 GPa, nu=0.33, Sy=276 MPa (AA typical tensile yield, T6),
    ///   k=167 W/(m·K) (AA typical at 25 degC).
    public static let aluminum6061T6 = EngineeringMaterial(
        id: "aluminum-6061-t6", name: "Aluminum 6061-T6",
        elasticModulusMPa: 68_900, poissonRatio: 0.33,
        massDensityKgPerMM3: 2.70e-6, yieldStrengthMPa: 276,
        thermalConductivityWPerMMK: 167.0e-3,
        provenance: "UNS A96061 / AMS 4027; MatWeb 'Aluminum 6061-T6, 6061-T651' (ASM data sheet, AA; Typical annotations). E=68.9 GPa, nu=0.33, Sy=276 MPa (T6 typical), k=167 W/(m·K)" + caveat)

    /// Titanium Ti-6Al-4V, annealed (Grade 5).
    /// - Standard: UNS R56400, AMS 4911 / ASTM B265 product forms.
    /// - Datasheet identities: MatWeb "Titanium Ti-6Al-4V (Grade 5), Annealed"
    ///   (matweb.com); AZoM "Titanium Ti6Al4V (Grade 5)".
    /// - E=113.8 GPa, nu=0.342, Sy=880 MPa (annealed typical; AMS 4911 min
    ///   827 MPa), k=6.7 W/(m·K).
    public static let titaniumTi6Al4V = EngineeringMaterial(
        id: "titanium-ti6al4v", name: "Titanium Ti-6Al-4V Annealed",
        elasticModulusMPa: 113_800, poissonRatio: 0.342,
        massDensityKgPerMM3: 4.43e-6, yieldStrengthMPa: 880,
        thermalConductivityWPerMMK: 6.7e-3,
        provenance: "UNS R56400 / AMS 4911; MatWeb 'Titanium Ti-6Al-4V (Grade 5), Annealed'; AZoM Titanium Ti6Al4V (Grade 5). E=113.8 GPa, nu=0.342, Sy=880 MPa (annealed typical), k=6.7 W/(m·K)" + caveat)

    /// All built-in records.
    public static let all: [EngineeringMaterial] = [
        structuralSteelA36, aluminum6061T6, titaniumTi6Al4V,
    ]

    public static func record(_ id: String) -> EngineeringMaterial? {
        all.first { $0.id == id }
    }
}

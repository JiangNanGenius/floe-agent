// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit unit system for every quantity FloeEngineeringCore accepts or returns.
///
/// There is no implicit unit conversion anywhere in the module: inputs are in these
/// units and results are reported in these units. Callers converting from SI
/// (metre/newton/pascal/watt-per-metre-kelvin) must scale at their own boundary,
/// e.g. conductivity W/(m·K) -> W/(mm·K) by dividing by 1000.
public enum EngineeringUnit: String, Codable, Sendable, CaseIterable {
    /// Geometry: millimetres.
    case lengthMM
    /// Mechanical loads and reactions: newtons.
    case forceN
    /// Stress, pressure, elastic modulus, yield strength: megapascals (N/mm^2).
    case stressMPa
    /// Body loads: newtons per cubic millimetre.
    case bodyLoadNPerMM3
    /// Temperature: degrees Celsius (differences equal kelvin differences).
    case temperatureCelsius
    /// Thermal conductivity: watts per millimetre per kelvin.
    /// Conversion from SI: W/(m·K) / 1000.
    case conductivityWPerMMK
    /// Thermal sources: watts per cubic millimetre. Conversion from SI: W/m^3 / 1e9.
    case sourceWPerMM3
    /// Heat flux: watts per square millimetre.
    case fluxWPerMM2
    /// Solver time accounting: seconds.
    case timeSecond

    public var summary: String {
        switch self {
        case .lengthMM: return "mm"
        case .forceN: return "N"
        case .stressMPa: return "MPa (N/mm^2)"
        case .bodyLoadNPerMM3: return "N/mm^3"
        case .temperatureCelsius: return "degC"
        case .conductivityWPerMMK: return "W/(mm·K)"
        case .sourceWPerMM3: return "W/mm^3"
        case .fluxWPerMM2: return "W/mm^2"
        case .timeSecond: return "s"
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Mesh-based manufacturability screening. These are real, bounded geometric
/// estimates over the analysis mesh — not process simulation — and are reported
/// as such.
public struct ElementThicknessFinding: Codable, Sendable, Equatable {
    public var element: Int
    /// Inradius proxy r = 3V / maxFaceArea, mm. For a regular tetrahedron this is
    /// the true inradius; for distorted elements it is a lower-bound-ish proxy.
    public var inradiusProxyMM: Double
}

public struct WallThicknessReport: Codable, Sendable {
    /// Requested minimum local thickness, mm.
    public var requestedMinimumMM: Double
    /// Elements whose inradius proxy falls below the requested minimum.
    public var belowMinimum: [ElementThicknessFinding]
    public var minimumInradiusProxyMM: Double
    public var meshTotalVolumeMM3: Double
    /// Explicit note that this is a mesh-resolution-limited proxy, not a true
    /// wall-thickness measurement against CAD geometry.
    public var isMeshProxy: Bool = true
}

public struct CuttingForceEstimate: Codable, Sendable {
    /// Tangential cutting force estimate, N (Kienzle form).
    public var cuttingForceN: Double
    public var widthMM: Double
    public var chipThicknessMM: Double
    /// Specific cutting force at unit chip thickness, N/mm^2.
    public var specificCuttingForceNPerMM2: Double
    /// Kienzle exponent mc (dimensionless).
    public var kienzleExponentMc: Double
    public var provenance: String
}

public struct ManufacturabilityReport: Codable, Sendable {
    public var wallThickness: WallThicknessReport?
    public var cuttingForce: CuttingForceEstimate?
}

/// Public entry points for mesh-based manufacturability screening. These are
/// real, bounded geometric estimates over the analysis mesh — not process
/// simulation — and are reported as such.
public enum ManufacturabilityCheck {
    /// Inradius proxy per element; flags elements below the requested minimum.
    /// Throws `.invalidInput` when the mesh is empty-by-construction (cannot
    /// happen for a validated mesh) or the request is non-positive.
    public static func wallThickness(mesh: ValidatedTetraMesh, minimumMM: Double) throws -> WallThicknessReport {
        guard minimumMM.isFinite, minimumMM > 0 else {
            throw EngineeringError.invalidInput("wall thickness minimum must be finite and > 0")
        }
        var below: [ElementThicknessFinding] = []
        var minR = Double.greatestFiniteMagnitude
        for (e, g) in mesh.geometry.enumerated() {
            let maxFace = g.faceArea.max() ?? 0
            let r = 3 * g.volume / maxFace
            minR = min(minR, r)
            if r < minimumMM {
                below.append(ElementThicknessFinding(element: e, inradiusProxyMM: r))
            }
        }
        return WallThicknessReport(requestedMinimumMM: minimumMM, belowMinimum: below,
                                   minimumInradiusProxyMM: minR == .greatestFiniteMagnitude ? 0 : minR,
                                   meshTotalVolumeMM3: mesh.totalVolume)
    }

    /// Kienzle tangential cutting force: Fc = kc1.1 * b * h^(1 - mc).
    /// Coefficients for steel are handbook typicals (Kienzle & Victor 1952 form,
    /// e.g. kc1.1 ≈ 1500-1700 N/mm^2, mc ≈ 0.25 for low-alloy steel at typical
    /// cutting speeds); an estimate only — no tool wear, speed correction, or
    /// built-up-edge behaviour is modelled.
    public static func cuttingForce(widthMM: Double, chipThicknessMM: Double,
                                    specificCuttingForceNPerMM2: Double = 1_600,
                                    kienzleExponentMc: Double = 0.25) throws -> CuttingForceEstimate {
        guard widthMM.isFinite, widthMM > 0,
              chipThicknessMM.isFinite, chipThicknessMM > 0 else {
            throw EngineeringError.invalidInput("cutting force estimate needs positive finite width and chip thickness")
        }
        guard specificCuttingForceNPerMM2.isFinite, specificCuttingForceNPerMM2 > 0,
              kienzleExponentMc.isFinite, kienzleExponentMc >= 0, kienzleExponentMc < 1 else {
            throw EngineeringError.invalidInput("cutting force coefficients out of range")
        }
        let force = specificCuttingForceNPerMM2 * widthMM * pow(chipThicknessMM, 1 - kienzleExponentMc)
        return CuttingForceEstimate(
            cuttingForceN: force, widthMM: widthMM, chipThicknessMM: chipThicknessMM,
            specificCuttingForceNPerMM2: specificCuttingForceNPerMM2,
            kienzleExponentMc: kienzleExponentMc,
            provenance: "Kienzle-Victor specific-cutting-force form Fc = kc1.1 * b * h^(1-mc); steel coefficients are handbook typicals; estimate only, no speed/wear correction.")
    }
}

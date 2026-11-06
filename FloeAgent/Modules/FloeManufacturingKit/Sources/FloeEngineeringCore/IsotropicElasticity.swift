// SPDX-License-Identifier: MPL-2.0
import Foundation

/// 3D isotropic linear-elastic constitutive law and 4-node tetrahedron element
/// matrices. Row-major flattened storage; everything derives from the validated
/// per-element geometry so inverted/degenerate elements can never contribute.
public struct IsotropicElasticity: Sendable {
    /// Constitutive matrix D (6x6 row-major) for normal strain/stress ordering
    /// [exx, eyy, ezz, gyz, gxz, gxy].
    public let constitutiveD: [Double]
    /// Shear modulus G = E / (2 (1 + nu)), MPa.
    public let shearModulusMPa: Double
    public let material: EngineeringMaterial

    public init(material: EngineeringMaterial) throws {
        try material.validateForStructural()
        let e = material.elasticModulusMPa
        let nu = material.poissonRatio
        let factor = e / ((1 + nu) * (1 - 2 * nu))
        let c1 = factor * (1 - nu)
        let c2 = factor * nu
        let g = e / (2 * (1 + nu))
        self.constitutiveD = [
            c1, c2, c2, 0, 0, 0,
            c2, c1, c2, 0, 0, 0,
            c2, c2, c1, 0, 0, 0,
            0, 0, 0, g, 0, 0,
            0, 0, 0, 0, g, 0,
            0, 0, 0, 0, 0, g,
        ]
        self.shearModulusMPa = g
        self.material = material
    }

    /// Strain-displacement matrix B (6x12 row-major) from shape function gradients.
    public static func strainDisplacementMatrix(_ gradients: [Vector3]) -> [Double] {
        // Node i occupies columns 3i...3i+2; row order exx, eyy, ezz, gyz, gxz, gxy.
        var b = [Double](repeating: 0, count: 6 * 12)
        for i in 0..<4 {
            let gx = gradients[i].x, gy = gradients[i].y, gz = gradients[i].z
            let c = i * 3
            b[0 * 12 + c] = gx                 // exx
            b[1 * 12 + c + 1] = gy             // eyy
            b[2 * 12 + c + 2] = gz             // ezz
            b[3 * 12 + c + 1] = gz             // gyz
            b[3 * 12 + c + 2] = gy
            b[4 * 12 + c] = gz                 // gxz
            b[4 * 12 + c + 2] = gx
            b[5 * 12 + c] = gy                 // gxy
            b[5 * 12 + c + 1] = gx
        }
        return b
    }

    /// Element stiffness Ke = V * B^T D B (12x12 row-major) for one tetrahedron.
    public func elementStiffness(geometry: TetraGeometry) -> [Double] {
        let b = IsotropicElasticity.strainDisplacementMatrix(geometry.gradients)
        var db = [Double](repeating: 0, count: 6 * 12)
        // db = D(6x6) * B(6x12)
        for r in 0..<6 {
            for cB in 0..<12 {
                var s = 0.0
                for k in 0..<6 { s += constitutiveD[r * 6 + k] * b[k * 12 + cB] }
                db[r * 12 + cB] = s
            }
        }
        var ke = [Double](repeating: 0, count: 144)
        for r in 0..<12 {
            for cB in 0..<12 {
                var s = 0.0
                for k in 0..<6 { s += b[k * 12 + r] * db[k * 12 + cB] }
                ke[r * 12 + cB] = s * geometry.volume
            }
        }
        return ke
    }

    /// Constant strain/stress over one element for a nodal displacement vector
    /// (4 nodes x 3 components). Strain then stress, each length 6, ordering
    /// [exx, eyy, ezz, gyz, gxz, gxy] / [sxx, syy, szz, tyz, txz, txy].
    public func elementStrainStress(geometry: TetraGeometry,
                                    nodalDisplacement u: [Double]) -> (strain: [Double], stress: [Double]) {
        let b = IsotropicElasticity.strainDisplacementMatrix(geometry.gradients)
        var strain = [Double](repeating: 0, count: 6)
        for r in 0..<6 {
            var s = 0.0
            for cB in 0..<12 { s += b[r * 12 + cB] * u[cB] }
            strain[r] = s
        }
        var stress = [Double](repeating: 0, count: 6)
        for r in 0..<6 {
            var s = 0.0
            for k in 0..<6 { s += constitutiveD[r * 6 + k] * strain[k] }
            stress[r] = s
        }
        return (strain, stress)
    }
}

/// Public von Mises stress (MPa) from a 6-component stress vector with the
/// ordering used above.
public func vonMisesStressMPa(_ stress: [Double]) -> Double {
    let s = stress
    let term = 0.5 * ((s[0] - s[1]) * (s[0] - s[1])
                    + (s[1] - s[2]) * (s[1] - s[2])
                    + (s[2] - s[0]) * (s[2] - s[0]))
               + 3 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5])
    return term.squareRoot()
}

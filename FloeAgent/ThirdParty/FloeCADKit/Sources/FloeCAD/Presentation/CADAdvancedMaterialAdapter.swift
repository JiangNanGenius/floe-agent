// SPDX-License-Identifier: MPL-2.0
#if canImport(RealityKit) && canImport(UIKit)
import RealityKit
import UIKit

@MainActor enum CADAdvancedMaterialAdapter {
    /// Concrete built-in PBR fields, shared by production and object tests.
    /// Sheen uses RealityKit's built-in lobe; no unsupported roughness control.
    static func apply(_ value:CADAdvancedMaterial?,to material:inout PhysicallyBasedMaterial,hasUVs:Bool) {
        guard let value,(try? value.validate()) != nil else { return }
        material.clearcoat = .init(scale:Float(value.clearcoat))
        material.clearcoatRoughness = .init(scale:Float(value.coatRoughness))
        material.specular = .init(scale:Float(value.specular))
        material.anisotropyLevel = .init(scale:hasUVs ? Float(value.anisotropyLevel):0)
        material.anisotropyAngle = .init(scale:Float(value.anisotropyAngle))
        material.sheen = .init(tint:UIColor(red:CGFloat(value.sheen.x),green:CGFloat(value.sheen.y),blue:CGFloat(value.sheen.z),alpha:1))
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SceneKit
import UIKit
import FloeManufacturingCore

@MainActor enum ToolAssemblyGeometry {
    /// Local +Y is tool tip -> spindle. The viewport maps that axis to the
    /// actual pose; profile distances are never interpreted as a second gauge.
    static func install(_ assembly:MillingToolAssembly,cuttingLengthMM:Double,on root:SCNNode) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        do { try assembly.validate(cuttingLengthMM:cuttingLengthMM) } catch { return }
        let start = assembly.holderProfile[0].axialMM
        if start > cuttingLengthMM {
            let shape = SCNCylinder(radius:assembly.shankDiameterMM/2,height:start-cuttingLengthMM)
            shape.radialSegmentCount = 48
            shape.firstMaterial = material(.systemGray2)
            let node = SCNNode(geometry:shape); node.position.y = Float((start+cuttingLengthMM)/2)
            root.addChildNode(node)
        }
        for (a,b) in zip(assembly.holderProfile,assembly.holderProfile.dropFirst()) where b.axialMM > a.axialMM {
            let shape = SCNCone(topRadius:b.radiusMM,bottomRadius:a.radiusMM,height:b.axialMM-a.axialMM)
            shape.radialSegmentCount = 48
            shape.firstMaterial = material(.systemGray)
            let node = SCNNode(geometry:shape); node.position.y = Float((a.axialMM+b.axialMM)/2)
            root.addChildNode(node)
        }
    }
    private static func material(_ color:UIColor) -> SCNMaterial {
        let material = SCNMaterial(); material.diffuse.contents = color
        material.lightingModel = .physicallyBased; material.metalness.contents = 0.4; material.roughness.contents = 0.6
        return material
    }
}
#endif

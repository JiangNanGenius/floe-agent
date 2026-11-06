// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
@preconcurrency import SceneKit

@MainActor enum CAMPreviewMaterials {
    static let background = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white:0.13,alpha:1):UIColor(white:0.96,alpha:1) }
    static func metal(_ color:UIColor,roughness:Double = 0.5,metalness:Double = 0.35)->SCNMaterial {
        let m = SCNMaterial();m.lightingModel = .physicallyBased;m.diffuse.contents = color
        m.metalness.contents = metalness;m.roughness.contents = max(0.38,roughness)
        m.isDoubleSided = true;m.transparencyMode = .dualLayer;return m
    }
    static func make(role:String)->SCNMaterial {
        switch role {
        case "stock":metal(UIColor(red:0.59,green:0.63,blue:0.66,alpha:1),roughness:0.52,metalness:0.3)
        case "cutter":metal(UIColor(red:0.69,green:0.55,blue:0.23,alpha:1),roughness:0.42)
        case "holder","shank":metal(UIColor(white:0.23,alpha:1),roughness:0.52,metalness:0.18)
        case "chuck","jaw","fixture":metal(UIColor(white:0.63,alpha:1),roughness:0.48)
        default:metal(UIColor(white:0.51,alpha:1),roughness:0.7,metalness:0.12)
        }
    }
    static func configureLighting(_ scene:SCNScene) {
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity = 280
        scene.rootNode.addChildNode(ambient)
        for (angle,power) in [(SCNVector3(-0.7,-0.6,0),900.0),(SCNVector3(-0.25,2.3,0),380.0)] {
            let node = SCNNode();node.light = SCNLight();node.light?.type = .directional;node.light?.intensity = power;node.eulerAngles = angle;scene.rootNode.addChildNode(node)
        }
    }
}
#endif

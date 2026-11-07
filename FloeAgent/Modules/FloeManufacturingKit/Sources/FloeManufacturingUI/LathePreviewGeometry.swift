// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
@preconcurrency import SceneKit
import FloeManufacturingCore
import simd

/// Generic machine bodies are presentation geometry. They never enter a native
/// safety query. The cutting tip, insert settings and supplied assembly retain
/// their actual source dimensions and poses.
@MainActor enum LathePreviewGeometry {
    static func metal(_ color:UIColor,roughness:Double = 0.45)->SCNMaterial {
        CAMPreviewMaterials.metal(color,roughness:roughness)
    }
    private static func box(_ size:[Double],_ position:[Double],_ material:SCNMaterial,bevel:Double = 0.4)->SCNNode {
        let g = SCNBox(width:size[0],height:size[1],length:size[2],chamferRadius:bevel);g.materials = [material]
        let n = SCNNode(geometry:g);n.position = .init(position[0],position[1],position[2]);return n
    }
    private static func axialCylinder(_ radius:Double,_ length:Double,_ x:Double,_ material:SCNMaterial)->SCNNode {
        let g = SCNCylinder(radius:radius,height:length);g.radialSegmentCount = 128;g.materials = [material]
        let n = SCNNode(geometry:g);n.eulerAngles.z = -.pi/2;n.position.x = Float(x);return n
    }
    static func spindle(stockRadius r:Double)->SCNNode {
        let root = SCNNode(),paint = metal(.systemGray3,roughness:0.75),steel = metal(.lightGray),dark = metal(.darkGray)
        let outer = max(r+7,18.0)
        root.addChildNode(CAMSceneDisplay.tag(box([32,outer*2.5,outer*2.3],[-40,0,0],paint,bevel:2),.structure))
        root.addChildNode(CAMSceneDisplay.tag(axialCylinder(outer*1.08,14,-19,dark),.spindle))
        root.addChildNode(CAMSceneDisplay.tag(axialCylinder(outer*0.65,7,-10,steel),.spindle))
        let rotor = CAMSceneDisplay.tag(SCNNode(),.workholding);rotor.name = "spindle-rotor"
        rotor.addChildNode(axialCylinder(outer,15,-10,steel))
        rotor.addChildNode(axialCylinder(outer*0.96,2,-2,metal(.gray)))
        // Jaws close on the supplied blank radius; their grips face the stock.
        for i in 0..<3 {
            let jaw = SCNNode();jaw.eulerAngles.x = Float(Double(i)*2*Double.pi/3)
            jaw.addChildNode(box([9,6,6],[-4.5,r+3,0],metal(.systemGray2),bevel:0.25))
            jaw.addChildNode(box([5,3,5],[-2.5,r+1.5,0],steel,bevel:0.15))
            rotor.addChildNode(jaw)
        }
        // A real marker on the rotor makes commanded rotation observable.
        rotor.addChildNode(box([0.6,3,2],[-0.8,outer*0.8,0],metal(.systemYellow),bevel:0))
        root.addChildNode(rotor);return root
    }
    static func signature(_ tool:CAMPreviewTool)->String {
        let t = tool.definition,s = tool.insertSetup
        return "\(tool.turning):\(t?.id ?? "turning"):\(t?.kind ?? ""):\(t?.diameterMM ?? 0):\(t?.cuttingLengthMM ?? 0):\(t?.tipAngleDegrees ?? 0):\(tool.gaugeLengthMM ?? 0):\(s?.insertShape ?? "D"):\(s?.insertEdgeLengthMM ?? 0):\(s?.insertRotationDegrees ?? 0):\(tool.turningApproach?.rawValue ?? "positiveZ")"
    }
    static func tool(_ tool:CAMPreviewTool)->SCNNode {
        if tool.turning { return turning(tool) }
        return milling(tool)
    }
    private static func plate(_ input:[[Double]],bottom:Double,top:Double,material:SCNMaterial)->SCNNode {
        guard let mesh = ManufacturingDisplaySurface.extrudedOutline(input,bottom:bottom,top:top) else { return SCNNode() }
        let blade = SCNGeometry(sources:[SCNGeometrySource(vertices:mesh.vertices.map { .init($0[0],$0[1],$0[2]) }),SCNGeometrySource(normals:mesh.normals.map { .init($0[0],$0[1],$0[2]) })],elements:[SCNGeometryElement(indices:mesh.triangles.flatMap { $0.map(Int32.init) },primitiveType:.triangles)])
        blade.materials = [material];return SCNNode(geometry:blade)
    }
    private static func turning(_ tool:CAMPreviewTool)->SCNNode {
        let root = SCNNode(),setup = tool.insertSetup ?? .init(),edge = setup.insertEdgeLengthMM
        let hand = tool.turningApproach == .negativeZ ? -1.0 : 1.0
        let outline = tool.insertOutline ?? insertOutline(setup).map { [$0[0],$0[1]*hand] }
        let thickness = max(0.8,edge*0.18),top = 0.0
        // The cutting corner is exactly the declared TCP at local (0,0,0).
        root.addChildNode(plate(outline,bottom:-thickness,top:top,
            material:metal(.init(red:0.83,green:0.65,blue:0.18,alpha:1),roughness:0.38)))
        let count = outline.count
        let cx = outline.map { $0[0] }.reduce(0,+)/Double(max(1,count)),cz = outline.map { $0[1] }.reduce(0,+)/Double(max(1,count))
        let screw = SCNCylinder(radius:max(0.5,edge*0.12),height:0.45);screw.radialSegmentCount = 32;screw.materials = [metal(.darkGray)]
        let screwNode = SCNNode(geometry:screw);screwNode.position = .init(cx,top+0.16,cz);root.addChildNode(screwNode)
        root.addChildNode(box([edge*0.13,0.05,edge*0.025],[cx,top+0.4,cz],metal(.black),bevel:0))
        let holder = CAMSceneDisplay.tag(SCNNode(),.holder);holder.name = "tool-head"
        let rear = outline.max(by:{ $0[0]<$1[0] }) ?? [edge*1.8,0]
        let offset = rear[1]+hand*edge*0.3,start = rear[0]+2,width = max(6,edge*1.25),length = 26.0
        let steel = metal(.init(white:0.19,alpha:1),roughness:0.6)
        // A dog-leg insert pocket joins a square tool shank. The shank stays
        // below the insert face instead of hiding its rear half and screw.
        let seatOutline = [[edge*0.28,cz-edge*0.24],[start+2,offset-width/2],
                           [start+2,offset+width/2],[edge*0.28,cz+edge*0.24]]
        holder.addChildNode(plate(seatOutline,bottom:top-thickness-4,top:top-thickness,material:steel))
        holder.addChildNode(box([length,width,width],[start+length/2,top-thickness-width/2,offset],steel,bevel:0.35))
        // A short clamping block and bolts identify the cross-slide/tool-post
        // mounting, rather than a spindle cap on top of a vertical stick.
        holder.addChildNode(CAMSceneDisplay.tag(box([9,width+5,width+5],[start+length-3,top-thickness-width/2,offset],metal(.systemGray2),bevel:0.5),.structure))
        for z in [-width*0.28,width*0.28] {
            let bolt = SCNCylinder(radius:0.7,height:0.5);bolt.radialSegmentCount = 20;bolt.materials = [metal(.darkGray)]
            let n = SCNNode(geometry:bolt);n.position = .init(start+length-3,top-thickness+2.6,offset+z);holder.addChildNode(CAMSceneDisplay.tag(n,.structure))
        }
        root.addChildNode(holder);return root
    }
    private static func milling(_ tool:CAMPreviewTool)->SCNNode {
        let root = SCNNode(),definition = tool.definition
        let radius = (definition?.diameterMM ?? 4)/2,length = definition?.cuttingLengthMM ?? 12
        // Existing cutters use +Y; align that convention with local radial X.
        let cutting = SCNNode();cutting.name = "cutter-rotor";let cutter = SCNNode()
        CutterGeometry.install(kind:definition?.kind ?? "flatEndMill",radius:radius,length:length,tipAngle:definition?.tipAngleDegrees,on:cutter)
        cutter.geometry?.materials = [metal(.init(red:0.68,green:0.56,blue:0.23,alpha:1),roughness:0.6)];cutter.eulerAngles.z = -.pi/2;cutting.addChildNode(cutter)
        let marker = box([max(1,length*0.35),0.3,0.3],[length*0.6,radius,0],metal(.darkGray),bevel:0)
        cutting.addChildNode(marker);root.addChildNode(cutting)
        let head = CAMSceneDisplay.tag(SCNNode(),.holder);head.name = "tool-head"
        var end = max(length,tool.gaugeLengthMM ?? length+12)
        if let assembly = definition?.assembly {
            let n = SCNNode();ToolAssemblyGeometry.install(assembly,cuttingLengthMM:length,on:n);n.eulerAngles.z = -.pi/2;head.addChildNode(n)
            let suppliedEnd = assembly.holderProfile.last?.axialMM ?? end
            end = max(suppliedEnd,tool.gaugeLengthMM ?? suppliedEnd)
            if end>suppliedEnd { head.addChildNode(axialCylinder(assembly.shankDiameterMM/2,end-suppliedEnd,(end+suppliedEnd)/2,metal(.gray))) }
        } else { head.addChildNode(axialCylinder(radius,end-length,(end+length)/2,metal(.gray))) }
        head.addChildNode(CAMSceneDisplay.tag(axialCylinder(max(radius*2.5,6),18,end+9,metal(.systemGray2)),.spindle))
        head.addChildNode(CAMSceneDisplay.tag(box([12,18,18],[end+24,0,0],metal(.systemGray3),bevel:1),.structure))
        root.addChildNode(head);return root
    }
    private static func insertOutline(_ setup:TurningSetup)->[[Double]] {
        let l = setup.insertEdgeLengthMM
        let raw:[[Double]]
        if setup.insertShape == "R" {
            // Same circle centre and tip-origin as the native receipt, including
            // rotation. The old fallback used a different centre and skipped it.
            raw = (0..<180).map { i in let a = -Double.pi/2+Double(i)*2*Double.pi/180;return [l/2*cos(a),l/2+l/2*sin(a)] }
        } else {
        let shapeAngles:[String:Double] = ["C":80,"D":55,"V":35,"S":90,"T":60]
        let angle = shapeAngles[setup.insertShape] ?? 55
        let theta = angle*Double.pi/360,x = l*cos(theta),z = l*sin(theta)
        raw = setup.insertShape == "T" ? [[0,0],[x,-z],[x,z]] : [[0,0],[x,-z],[2*x,0],[x,z]]
        }
        let a = setup.insertRotationDegrees*Double.pi/180,c = cos(a),s = sin(a)
        return raw.map { [c*$0[0]-s*$0[1],s*$0[0]+c*$0[1]] }
    }
}
#endif

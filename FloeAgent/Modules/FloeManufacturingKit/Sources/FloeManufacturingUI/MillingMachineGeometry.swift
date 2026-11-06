// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
@preconcurrency import SceneKit
import simd
import FloeManufacturingCore

/// Generic machining-centre context; not manufacturer or collision geometry.
/// All dimensions/poses here use machine XYZ, with +Z vertically upward.
@MainActor enum MillingMachineGeometry {
    static func point(_ p:[Double])->SCNVector3 { .init(p[0],p[2],-p[1]) }
    static func frame(_ f:CellRigidTransform)->simd_float4x4 {
        let r = f.rotation,t = f.translationMM
        return .init(columns:(.init(Float(r[0]),Float(r[6]),Float(-r[3]),0),.init(Float(r[2]),Float(r[8]),Float(-r[5]),0),
            .init(Float(-r[1]),Float(-r[7]),Float(r[4]),0),.init(Float(t[0]),Float(t[2]),Float(-t[1]),1)))
    }
    private static func box(_ size:[Double],at p:[Double],color:UIColor,bevel:Double = 0.5)->SCNNode {
        let g = SCNBox(width:size[0],height:size[2],length:size[1],chamferRadius:bevel);g.materials = [LathePreviewGeometry.metal(color)]
        let n = SCNNode(geometry:g);n.position = point(p);return n
    }
    private static func cylinder(_ r:Double,_ h:Double,at p:[Double],color:UIColor,xAxis:Bool = false)->SCNNode {
        let g = SCNCylinder(radius:r,height:h);g.radialSegmentCount = 96;g.materials = [LathePreviewGeometry.metal(color)]
        let n = SCNNode(geometry:g);n.position = point(p);if xAxis { n.eulerAngles.z = -.pi/2 };return n
    }
    static func install(_ machine:CAMMachinePresentation,fixtureBaseZ:Double,on root:SCNNode) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        let lo = machine.stockMinMM,hi = machine.stockMaxMM,span = max(32,hi[0]-lo[0],hi[1]-lo[1]),base = lo[2]-23,columnY = span*0.95
        root.addChildNode(box([span*2,span*1.9,7],at:[0,span*0.3,base],color:.systemGray3,bevel:1.5))
        let height = max(70,hi[2]+(machine.gaugeLengthMM ?? 30)+40-base)
        root.addChildNode(box([span*0.8,12,height],at:[0,columnY,base+height/2],color:.systemGray2,bevel:1.5))
        for x in [-span*0.22,span*0.22] { root.addChildNode(box([2,2,height-12],at:[x,columnY-7,base+height/2],color:.lightGray,bevel:0.1)) }
        let bridge = box([12,columnY+8,8],at:[0,columnY/2,hi[2]+40],color:.systemGray2,bevel:1);bridge.name = "head-bridge";root.addChildNode(bridge)
        if machine.kind == .acTableTable {
            for sign in [-1.0,1.0] {
                let x = sign*span*0.68
                root.addChildNode(CAMSceneDisplay.tag(box([9,18,abs(base)+4],at:[x,0,base/2],color:.systemGray2),.workholding))
                root.addChildNode(CAMSceneDisplay.tag(cylinder(8,11,at:[x,0,0],color:.systemGray2,xAxis:true),.workholding))
            }
            let cradle = CAMSceneDisplay.tag(SCNNode(),.workholding);cradle.name = "a-cradle"
            cradle.addChildNode(box([span*1.3,10,5],at:[0,0,fixtureBaseZ-7],color:.darkGray))
            root.addChildNode(cradle)
            let table = CAMSceneDisplay.tag(SCNNode(),.workholding);table.name = "c-table"
            table.addChildNode(cylinder(span*0.59,4,at:[0,0,fixtureBaseZ-2],color:.lightGray))
            table.addChildNode(box([span*0.35,1,0.15],at:[span*0.28,0,fixtureBaseZ+0.08],color:.systemYellow,bevel:0))
            for y in [-span*0.25,0,span*0.25] { table.addChildNode(box([span*0.88,0.6,0.1],at:[0,y,fixtureBaseZ+0.03],color:.darkGray,bevel:0)) }
            root.addChildNode(table)
        } else {
            root.addChildNode(CAMSceneDisplay.tag(box([span*1.55,span*1.3,5],at:[0,0,fixtureBaseZ-2.5],color:.lightGray),.workholding))
            root.addChildNode(CAMSceneDisplay.tag(box([span*1.2,span,10],at:[0,0,fixtureBaseZ-10],color:.systemGray2),.workholding))
            for y in [-span*0.4,-span*0.2,0,span*0.2,span*0.4] { root.addChildNode(CAMSceneDisplay.tag(box([span*1.4,0.7,0.1],at:[0,y,fixtureBaseZ+0.03],color:.darkGray,bevel:0),.workholding)) }
        }
    }
    static func update(_ machine:CAMMachinePresentation,tools:[CAMPreviewTool],on root:SCNNode) {
        root.childNode(withName:"a-cradle",recursively:false)?.simdTransform = frame(machine.aAxisFrame)
        root.childNode(withName:"c-table",recursively:false)?.simdTransform = frame(machine.worldFromWorkpiece)
        guard let tool = tools.first,let bridge = root.childNode(withName:"head-bridge",recursively:false),let box = bridge.geometry as? SCNBox else { return }
        let p = machine.machineToolTipMM ?? tool.tipMM,gauge = machine.gaugeLengthMM ?? tool.gaugeLengthMM ?? tool.definition?.assembly?.holderProfile.last?.axialMM ?? ((tool.definition?.cuttingLengthMM ?? 12)+12)
        let span = max(32,machine.stockMaxMM[0]-machine.stockMinMM[0],machine.stockMaxMM[1]-machine.stockMinMM[1]),columnY = span*0.95
        box.length = abs(columnY-p[1])+8;bridge.position = point([p[0],(columnY+p[1])/2,p[2]+gauge+24])
    }
}
#endif

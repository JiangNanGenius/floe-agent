// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import SceneKit
import UIKit
import simd
import FloeBiologyCore

@MainActor struct BiologyMeshScene:UIViewRepresentable {
    let scene:SCNScene
    var atoms:[StructureAtom]=[]
    var selectedAtoms:Set<Int>=[]
    var resetToken=0
    var onSelect:((Int)->Void)?
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeUIView(context:Context)->BiologySceneView {
        let view=BiologySceneView(frame:.zero,options:[SCNView.Option.preferredRenderingAPI.rawValue:SCNRenderingAPI.metal.rawValue])
        view.allowsCameraControl=true
        view.antialiasingMode = .multisampling4X
        view.isTemporalAntialiasingEnabled=true
        view.isJitteringEnabled=true
        view.preferredFramesPerSecond=60
        view.rendersContinuously=false
        view.autoenablesDefaultLighting=false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = !UIAccessibility.isReduceMotionEnabled
        view.defaultCameraController.automaticTarget=false
        view.defaultCameraController.target=SCNVector3Zero
        view.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.selectAtom(_:))))
        return view
    }
    func updateUIView(_ view:BiologySceneView,context:Context) {
        if view.scene !== scene {view.scene=scene;view.fitModel();context.coordinator.resetSelection()}
        if context.coordinator.resetToken != resetToken {view.fitModel();context.coordinator.resetToken=resetToken}
        context.coordinator.atoms=atoms;context.coordinator.onSelect=onSelect
        context.coordinator.highlight(selectedAtoms,in:scene)
    }
    @MainActor final class Coordinator:NSObject {
        var atoms:[StructureAtom]=[]
        var onSelect:((Int)->Void)?
        var resetToken=0
        private var selected:Set<Int>=[]
        private var baseGeometries:[Int:SCNGeometry]=[:]
        func resetSelection(){selected=[];baseGeometries=[:]}
        func highlight(_ next:Set<Int>,in scene:SCNScene) {
            guard let model=scene.rootNode.childNode(withName:"biology.model",recursively:false) else{return}
            for id in selected.symmetricDifference(next) {
                guard let node=model.childNode(withName:"atom.\(id)",recursively:false),let base=baseGeometries[id] ?? node.geometry else{continue}
                baseGeometries[id]=base
                if next.contains(id),let copy=base.copy() as? SCNGeometry,let material=base.firstMaterial?.copy() as? SCNMaterial {
                    material.diffuse.contents=UIColor.systemOrange;material.emission.contents=UIColor.systemOrange.withAlphaComponent(0.2);copy.materials=[material];node.geometry=copy
                }else{node.geometry=base}
            };selected=next
        }
        @objc func selectAtom(_ tap:UITapGestureRecognizer) {
            guard let view=tap.view as? SCNView,let hit=view.hitTest(tap.location(in:view),options:nil).first else{return}
            if let name=hit.node.name,name.hasPrefix("atom."),let id=Int(name.dropFirst(5)){onSelect?(id);return}
            guard let model=view.scene?.rootNode.childNode(withName:"biology.model",recursively:false) else{return}
            let p=hit.node.convertPosition(hit.localCoordinates,to:model)
            let q=SIMD3(Double(p.x),Double(p.y),Double(p.z))
            if let atom=atoms.min(by:{simd_length_squared(SIMD3($0.x,$0.y,$0.z)-q)<simd_length_squared(SIMD3($1.x,$1.y,$1.z)-q)}){onSelect?(atom.id)}
        }
    }
    static func makeScene(_ mesh:BiologyTriangleMesh)->SCNScene {BiologySceneFactory.mesh(mesh)}
}

@MainActor final class BiologySceneView:SCNView {
    private var fittedSize=CGSize.zero
    override func layoutSubviews(){super.layoutSubviews();if bounds.size != fittedSize,bounds.width>0,bounds.height>0{fittedSize=bounds.size;fitModel()}}
    func fitModel() {
        guard let model=scene?.rootNode.childNode(withName:"biology.model",recursively:false),
              let camera=scene?.rootNode.childNode(withName:"biology.camera",recursively:false),bounds.width>0,bounds.height>0 else{return}
        let radius=max(Float(0.5),Float(model.boundingSphere.radius)),aspect=Float(bounds.width/bounds.height)
        let vertical:Float = .pi*38/360,horizontal=atan(tan(vertical)*aspect),distance=radius/max(0.1,sin(min(vertical,horizontal)))*1.12
        camera.position=SCNVector3(0,0,distance);camera.eulerAngles=SCNVector3Zero
        camera.camera?.zNear=Double(max(radius*0.001,0.001));camera.camera?.zFar=Double(distance+radius*8)
        pointOfView=camera;defaultCameraController.target=SCNVector3Zero
        defaultCameraController.stopInertia()
        setNeedsDisplay()
    }
}

@MainActor enum BiologySceneFactory {
    private struct VertexKey:Hashable {
        let x:Int64,y:Int64,z:Int64
        let kind:UInt8
        init(_ p:SIMD3<Float>,_ kind:UInt8){x=Int64((Double(p.x)*100000).rounded());y=Int64((Double(p.y)*100000).rounded());z=Int64((Double(p.z)*100000).rounded());self.kind=kind}
    }
    private static func material(_ color:UIColor)->SCNMaterial {
        let material=SCNMaterial();material.diffuse.contents=color;material.isDoubleSided=true
        material.lightingModel = .lambert;material.specular.contents=UIColor.black
        return material
    }
    static func mesh(_ mesh:BiologyTriangleMesh)->SCNScene {
        guard !mesh.vertices.isEmpty else{return SCNScene()}
        // Area-weighted shared normals affect lighting only. Every measured
        // vertex stays unchanged; we do not smooth away density or coordinates.
        var sums:[VertexKey:SIMD3<Float>]=[:]
        for i in Swift.stride(from:0,to:mesh.vertices.count,by:3) {
            let normal=simd_cross(mesh.vertices[i+1]-mesh.vertices[i],mesh.vertices[i+2]-mesh.vertices[i])
            for j in i..<i+3 {sums[VertexKey(mesh.vertices[j],mesh.classes[j]),default:.zero]+=normal}
        }
        let normals=mesh.vertices.indices.map{i->SCNVector3 in
            let n=sums[VertexKey(mesh.vertices[i],mesh.classes[i])] ?? .zero
            let unit=simd_length(n)>1e-10 ? simd_normalize(n):SIMD3<Float>(0,0,1)
            return SCNVector3(unit.x,unit.y,unit.z)
        }
        var groups=[[Int32]](repeating:[],count:4)
        for i in Swift.stride(from:0,to:mesh.vertices.count,by:3){groups[min(3,Int(mesh.classes[i]))] += [Int32(i),Int32(i+1),Int32(i+2)]}
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:mesh.vertices.map{SCNVector3($0.x,$0.y,$0.z)}),SCNGeometrySource(normals:normals)],elements:groups.map{SCNGeometryElement(indices:$0,primitiveType:.triangles)})
        geometry.materials=[UIColor.systemTeal,.systemOrange,.systemBlue,.systemIndigo].map(material)
        return finish(SCNNode(geometry:geometry))
    }
    static func molecule(_ atoms:[StructureAtom],backbone:Bool)->SCNScene {
        let shown=Array((backbone ? atoms.filter{$0.name=="CA" && !$0.hetero}:atoms).prefix(5000)),model=SCNNode()
        var geometries:[String:SCNGeometry]=[:]
        for atom in shown {
            let key=backbone ? "CA":atom.element
            let geometry:SCNGeometry
            if let saved=geometries[key]{geometry=saved}else{
                let sphere=SCNSphere(radius:backbone ? 0.34:atom.element=="H" ? 0.22:0.42);sphere.segmentCount=18
                let color:UIColor=atom.element=="O" ? .systemRed:atom.element=="N" ? .systemBlue:atom.element=="S" ? .systemOrange:atom.element=="H" ? .systemGray3:.systemTeal
                sphere.materials=[material(color)];geometries[key]=sphere;geometry=sphere
            }
            let node=SCNNode(geometry:geometry);node.name="atom.\(atom.id)";node.position=SCNVector3(Float(atom.x),Float(atom.y),Float(atom.z))
            model.addChildNode(node)
        }
        if backbone {
            let lineMaterial=material(.systemTeal)
            for (a,b) in zip(shown,shown.dropFirst()) where a.chain==b.chain && a.model==b.model && abs(a.residueNumber-b.residueNumber)==1 {
                let p=SIMD3<Float>(Float(a.x),Float(a.y),Float(a.z)),q=SIMD3<Float>(Float(b.x),Float(b.y),Float(b.z)),delta=q-p,length=simd_length(delta)
                guard length>0.001,length<5 else{continue}
                let cylinder=SCNCylinder(radius:0.15,height:CGFloat(length));cylinder.radialSegmentCount=12;cylinder.materials=[lineMaterial]
                let node=SCNNode(geometry:cylinder);node.simdPosition=(p+q)/2;node.simdOrientation=simd_quatf(from:SIMD3<Float>(0,1,0),to:delta/length);model.addChildNode(node)
            }
        }
        return finish(model)
    }
    private static func finish(_ model:SCNNode)->SCNScene {
        let scene=SCNScene();model.name="biology.model"
        let (low,high)=model.boundingBox
        model.position=SCNVector3(-(low.x+high.x)/2,-(low.y+high.y)/2,-(low.z+high.z)/2)
        scene.rootNode.addChildNode(model)
        let camera=SCNNode();camera.name="biology.camera";camera.camera=SCNCamera();camera.camera?.fieldOfView=38
        camera.camera?.screenSpaceAmbientOcclusionIntensity=0.35;camera.camera?.screenSpaceAmbientOcclusionRadius=1
        scene.rootNode.addChildNode(camera)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=360;scene.rootNode.addChildNode(ambient)
        let key=SCNNode();key.light=SCNLight();key.light?.type = .directional;key.light?.intensity=950;key.eulerAngles=SCNVector3(-0.6,-0.7,0);scene.rootNode.addChildNode(key)
        let fill=SCNNode();fill.light=SCNLight();fill.light?.type = .directional;fill.light?.intensity=250;fill.eulerAngles=SCNVector3(0.7,1.8,0);scene.rootNode.addChildNode(fill)
        return scene
    }
}
#endif

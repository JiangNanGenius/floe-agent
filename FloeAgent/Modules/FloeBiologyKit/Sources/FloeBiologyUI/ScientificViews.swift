// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import SceneKit
import simd
import FloeBiologyCore
import FloeBiologyEngine

private func biologyViewCompute<T:Sendable>(_ body:@escaping @Sendable ()throws->T) async throws -> T {
    let task=Task.detached(priority:.userInitiated){try body()}
    return try await withTaskCancellationHandler{try await task.value}onCancel:{task.cancel()}
}

@MainActor struct BiologyRibbonView:View {
    let asset:BiologyAsset
    let structure:ProteinStructure
    @Binding var selectedAtoms:[Int]
    @Binding var modelNumber:Int
    @Binding var chain:String
    @State private var ribbon=false
    @State private var scene:SCNScene?
    @State private var error:String?
    var body:some View {
        VStack(spacing:0) {
            Picker(biologyText("Structure view","结构视图"),selection:$ribbon) {
                Text(biologyText("Atoms & backbone","原子与主链")).tag(false)
                Text(biologyText("Ribbon","带状模型")).tag(true)
            }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("biology.structureRepresentation")
            if ribbon {
                if let scene {BiologyMeshScene(scene:scene,atoms:structure.atoms.filter{$0.model==modelNumber && (chain.isEmpty || $0.chain==chain)},onSelect:{id in selectedAtoms=Array((selectedAtoms+[id]).suffix(2))}).accessibilityIdentifier("biology.ribbonViewport")}
                else if let error {ContentUnavailableView(biologyText("Unable to draw ribbon","无法显示带状模型"),systemImage:"exclamationmark.triangle",description:Text(error))}
                else {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
                Text(biologyText("Drag to rotate · pinch to zoom · helix: orange, sheet: blue, unassigned: teal","拖动旋转 · 捏合缩放 · 螺旋为橙色，折叠为蓝色，未标注区为青色")).font(.caption).foregroundStyle(.secondary).padding()
                if !selectedAtoms.isEmpty {Text(biologyText("Selected atoms: ","选中原子：")+selectedAtoms.map(String.init).joined(separator:", ")).font(.caption).padding(.horizontal)}
            } else {BiologyStructureView(structure:structure,selectedAtoms:$selectedAtoms,modelNumber:$modelNumber,chain:$chain)}
        }.task(id:"\(asset.revision):\(modelNumber):\(chain):\(ribbon)") {
            guard ribbon else {return}
            scene=nil;error=nil
            do {
                let structure=structure,model=modelNumber,chain=chain,data=asset.originalData,format=asset.originalFormat
                let mesh=try await biologyViewCompute{
                    let deposited=try ["cif","mmcif"].contains(format) ? BiologyImporter.cifSecondaryClasses(String(decoding:data,as:UTF8.self)):BiologyProteinRibbon.depositedClasses(pdb:data)
                    return try BiologyProteinRibbon.build(structure,model:model,chain:chain.isEmpty ? nil:chain,deposited:deposited)
                }
                try Task.checkCancellation();scene=BiologyMeshScene.makeScene(mesh)
            }catch is CancellationError {}catch{self.error=error.localizedDescription}
        }
    }
}
@MainActor private struct BiologyMeshScene:UIViewRepresentable {
    let scene:SCNScene
    var atoms:[StructureAtom]=[]
    var onSelect:((Int)->Void)?
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeUIView(context:Context)->SCNView {
        let view=SCNView();view.allowsCameraControl=true;view.autoenablesDefaultLighting=true;view.backgroundColor = .secondarySystemBackground
        view.scene=scene;view.antialiasingMode = .multisampling4X
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.selectAtom(_:)));view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view:SCNView,context:Context) {if view.scene !== scene {view.scene=scene};context.coordinator.atoms=atoms;context.coordinator.onSelect=onSelect}
    @MainActor final class Coordinator:NSObject {
        var atoms:[StructureAtom]=[]
        var onSelect:((Int)->Void)?
        @objc func selectAtom(_ tap:UITapGestureRecognizer) {
            guard let view=tap.view as? SCNView,let hit=view.hitTest(tap.location(in:view),options:nil).first else {return}
            let p=hit.localCoordinates
            if let atom=atoms.min(by:{a,b in pow(a.x-Double(p.x),2)+pow(a.y-Double(p.y),2)+pow(a.z-Double(p.z),2)<pow(b.x-Double(p.x),2)+pow(b.y-Double(p.y),2)+pow(b.z-Double(p.z),2)}) {onSelect?(atom.id)}
        }
    }
    static func makeScene(_ mesh:BiologyTriangleMesh)->SCNScene {
        let scene=SCNScene();guard !mesh.vertices.isEmpty else {return scene}
        let source=SCNGeometrySource(vertices:mesh.vertices.map{SCNVector3($0.x,$0.y,$0.z)})
        var normals:[SCNVector3]=[];normals.reserveCapacity(mesh.vertices.count)
        for i in Swift.stride(from:0,to:mesh.vertices.count,by:3) {let cross=simd_cross(mesh.vertices[i+1]-mesh.vertices[i],mesh.vertices[i+2]-mesh.vertices[i]);let n=simd_length(cross)>1e-10 ? simd_normalize(cross):SIMD3<Float>(0,0,1);normals += [SCNVector3(n.x,n.y,n.z),SCNVector3(n.x,n.y,n.z),SCNVector3(n.x,n.y,n.z)]}
        var groups=[[Int32]](repeating:[],count:4)
        for i in Swift.stride(from:0,to:mesh.vertices.count,by:3) {let kind=min(3,Int(mesh.classes.indices.contains(i) ? mesh.classes[i]:0));groups[kind] += [Int32(i),Int32(i+1),Int32(i+2)]}
        let elements=groups.map{SCNGeometryElement(indices:$0,primitiveType:.triangles)}
        let geometry=SCNGeometry(sources:[source,SCNGeometrySource(normals:normals)],elements:elements)
        geometry.materials=[UIColor.systemTeal,.systemOrange,.systemBlue,.systemPurple].map{color in let material=SCNMaterial();material.diffuse.contents=color;material.isDoubleSided=true;material.lightingModel = .lambert;return material}
        let node=SCNNode(geometry:geometry),low=mesh.vertices.reduce(mesh.vertices[0]){simd_min($0,$1)},high=mesh.vertices.reduce(mesh.vertices[0]){simd_max($0,$1)},center=(low+high)/2
        node.position=SCNVector3(-center.x,-center.y,-center.z);scene.rootNode.addChildNode(node)
        let camera=SCNNode();camera.camera=SCNCamera();let span=max(1,max(high.x-low.x,max(high.y-low.y,high.z-low.z)))
        camera.position=SCNVector3(0,0,span*2.2);camera.camera?.zNear=0.01;camera.camera?.zFar=Double(span*20);scene.rootNode.addChildNode(camera)
        return scene
    }
}

@MainActor struct BiologyTreeView:View {
    let data:Data
    var selection:JSONValue?
    @State private var tree:BiologyTree?
    @State private var lengths=true
    @State private var selected:Int?
    @State private var page=0
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading) {
            Toggle(biologyText("Use branch lengths","使用分支长度"),isOn:$lengths).padding(.horizontal)
            if let tree {
                let positions=tree.layout(useLengths:lengths),span=max(positions.map(\.x).max() ?? 1,1e-12),height=max(260,Double(min(100,tree.leaves.count-page*100))*32),pageOffset=Double(page*100),selectedNode=selected
                if tree.leaves.count>100 {HStack{Button(biologyText("Previous","上一页")){page-=1}.disabled(page==0);Spacer();Text("\(page+1) / \((tree.leaves.count+99)/100)");Spacer();Button(biologyText("Next","下一页")){page+=1}.disabled((page+1)*100>=tree.leaves.count)}.padding(.horizontal)}
                ScrollView([.horizontal,.vertical]) {
                    Canvas {context,size in
                        func point(_ id:Int)->CGPoint {.init(x:20+positions[id].x/span*520,y:20+(positions[id].y-pageOffset)*32)}
                        for node in tree.nodes {
                            let p=point(node.id)
                            for child in node.children {let q=point(child);if max(p.y,q.y)>=0 && min(p.y,q.y)<=size.height {var line=Path();line.move(to:p);line.addLine(to:.init(x:p.x,y:q.y));line.addLine(to:q);context.stroke(line,with:.color(.secondary),lineWidth:1.5)}}
                            guard p.y>=0,p.y<=size.height else {continue}
                            if selectedNode==node.id {context.fill(Path(ellipseIn:.init(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.orange))}
                            if node.children.isEmpty || !node.label.isEmpty {context.draw(Text(node.label.isEmpty ? "#\(node.id)":node.label).font(.callout),at:.init(x:p.x+10,y:p.y),anchor:.leading)}
                        }
                    }.frame(width:820,height:height+40)
                    .gesture(SpatialTapGesture().onEnded{value in selected=positions.indices.min{a,b in hypot(20+positions[a].x/span*520-value.location.x,20+(positions[a].y-Double(page*100))*32-value.location.y)<hypot(20+positions[b].x/span*520-value.location.x,20+(positions[b].y-Double(page*100))*32-value.location.y)}})
                }.accessibilityIdentifier("biology.treeViewport")
                if let selected,tree.nodes.indices.contains(selected) {let node=tree.nodes[selected];Text(node.label+" · "+(node.length.map{String($0)} ?? biologyText("No branch length","无分支长度"))).textSelection(.enabled).padding(.horizontal)}
                Text("\(tree.leaves.count) "+biologyText("leaves · topology from the saved Newick file","个叶节点 · 拓扑来自保存的 Newick 文件")).font(.caption).foregroundStyle(.secondary).padding()
            } else if let error {Text(error).padding()}else{ProgressView()}
        }.task {do {tree=try await biologyViewCompute{try BiologyTree.parse(data)};applySelection()}catch{self.error=error.localizedDescription}}
        .onChange(of:selection){_,_ in applySelection()}
    }
    private func applySelection(){selected=selection?["nodeID"]?.string.flatMap(Int.init);if let tree,let selected,tree.nodes.indices.contains(selected){page=Int(tree.layout()[selected].y)/100}}
}

@MainActor struct BiologyDensityView:View {
    let data:Data
    var selection:JSONValue?
    @State private var volume:BiologyDensityVolume?
    @State private var axis=2
    @State private var index=0
    @State private var surface=false
    @State private var isovalue=0.0
    @State private var stride=2
    @State private var image:MicroscopyImage?
    @State private var scene:SCNScene?
    @State private var error:String?
    var body:some View {
        VStack {
            Picker(biologyText("Density view","密度视图"),selection:$surface) {Text(biologyText("Slice","切片")).tag(false);Text(biologyText("Surface","等值面")).tag(true)}.pickerStyle(.segmented).padding(.horizontal)
            if let volume {
                if surface {
                    HStack {Text(biologyText("Isovalue","等值"));TextField("",value:$isovalue,format:.number).textFieldStyle(.roundedBorder).frame(maxWidth:180);Stepper(biologyText("Stride ","采样间隔 ")+String(stride),value:$stride,in:1...32)}.padding(.horizontal)
                    if let scene {BiologyMeshScene(scene:scene).accessibilityIdentifier("biology.densitySurface")}
                    else {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
                } else {
                    HStack {Picker(biologyText("Axis","轴"),selection:$axis){Text("X").tag(0);Text("Y").tag(1);Text("Z").tag(2)}.pickerStyle(.segmented);Stepper("\(index+1) / \(volume.dimensions[axis])",value:$index,in:0...volume.dimensions[axis]-1)}.padding(.horizontal)
                    if let image {BiologyMicroscopyView(image:image,result:nil,channel:.constant(0),slice:.constant(0),frame:.constant(0))}
                }
                Text("\(volume.dimensions.x) × \(volume.dimensions.y) × \(volume.dimensions.z) · "+biologyText("coordinates in Å","坐标单位为埃")).font(.caption).foregroundStyle(.secondary).padding()
            }else{ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
            if let error {Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding()}
        }.task(id:data) {
            do {let parsed=try await biologyViewCompute{try BiologyDensityVolume.parse(data)};volume=parsed;axis=Int(selection?["axis"]?.number ?? 2);axis=min(2,max(0,axis));index=min(parsed.dimensions[axis]-1,max(0,Int(selection?["index"]?.number ?? Double(parsed.dimensions[axis]/2))));isovalue=parsed.values.reduce(0,+)/Double(parsed.values.count);await redraw()}
            catch {self.error=error.localizedDescription}
        }.task(id:"\(surface):\(axis):\(index):\(isovalue):\(stride)"){await redraw()}
        .onChange(of:axis){_,_ in if let volume{index=min(index,volume.dimensions[axis]-1)}}
        .onChange(of:selection){_,s in if let volume{axis=min(2,max(0,Int(s?["axis"]?.number ?? 2)));index=min(volume.dimensions[axis]-1,max(0,Int(s?["index"]?.number ?? 0)))}}
    }
    private func redraw() async {
        guard let volume else {return};error=nil
        do {
            if surface {
                scene=nil;let value=isovalue,step=stride
                let mesh=try await biologyViewCompute{try volume.isosurface(value:value,stride:step)}
                try Task.checkCancellation();scene=BiologyMeshScene.makeScene(mesh)
            } else {let slice=try volume.slice(axis:axis,index:index);image=MicroscopyImage(width:slice.width,height:slice.height,samples:slice.values)}
        }catch is CancellationError {}catch{self.error=error.localizedDescription}
    }
}
#endif
